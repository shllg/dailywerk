---
type: rfc
title: Debugging Tools
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/01-platform-and-infrastructure
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-29-simple-chat-conversation
  - rfc/2026-03-31-agent-configuration
  - rfc/2026-03-31-agent-session-management
phase: 2
---

# RFC: Debugging Tools

## Context

[PRD 01 §8](../prd/01-platform-and-infrastructure.md#8-open-questions) identifies "session replay for debugging" as an open question. As the agentic system grows more complex (compaction, memory injection, tool execution), the ability to inspect what the LLM actually sees becomes essential.

This RFC adds developer-facing debugging tools hidden behind a "developer mode" toggle. When enabled, users can inspect sessions, view full message histories with raw data, monitor token usage, and see the assembled LLM context.

### Design Principles

- **Hidden by default**: Developer mode is a workspace setting, off by default. Most users never see it.
- **Read-only**: Debug tools only observe — they never modify sessions, messages, or agent state.
- **Full fidelity**: Show everything the LLM sees, including system prompts, compaction summaries, tool call arguments and results, token counts, and timing.
- **Performance-conscious**: Paginated APIs, lazy loading, no full-table scans.

### What This RFC Covers

- `developer_mode` boolean on workspaces
- `RequireDeveloperMode` controller concern gating debug endpoints
- Debug API namespace: sessions list, session detail, message inspection, context viewer
- Frontend: developer mode toggle, debug panel overlay, sessions explorer, message inspector

### What This RFC Does NOT Cover

- Real-time streaming monitor (live ActionCable debug events) — future enhancement
- Memory inspection (memory_entries, daily_logs) — ships when memory architecture ships
- Cost analytics dashboard (usage_records, credit_transactions) — ships when billing ships
- Production observability (metrics, alerting, health checks) — separate infrastructure concern

---

## 1. Database Schema

### Migration: Add Developer Mode to Workspaces

```ruby
# db/migrate/TIMESTAMP_add_developer_mode_to_workspaces.rb
class AddDeveloperModeToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :developer_mode, :boolean, default: false, null: false
  end
end
```

Single column, safe with `strong_migrations`.

---

## 2. Authorization

### RequireDeveloperMode Concern

All debug endpoints are gated behind this concern. Returns 403 when developer mode is off.

```ruby
# app/controllers/concerns/require_developer_mode.rb

# Gates controller actions behind the workspace's developer_mode flag.
#
# Include in any controller that exposes debug/diagnostic data.
# Returns 403 Forbidden when developer mode is not enabled.
module RequireDeveloperMode
  extend ActiveSupport::Concern

  included do
    before_action :verify_developer_mode
  end

  private

  # @return [void]
  def verify_developer_mode
    return if Current.workspace&.developer_mode?

    render json: { error: "Developer mode is not enabled" }, status: :forbidden
  end
end
```

**Future**: When multi-user workspaces ship, this concern should additionally check that the current user has `owner` or `admin` role on the workspace. Debug tools expose system prompts and raw tool results which are sensitive.

---

## 3. Controllers

### 3.1 Workspaces Controller

Exposes the developer mode toggle.

```ruby
# app/controllers/api/v1/workspaces_controller.rb
class Api::V1::WorkspacesController < ApplicationController
  # PATCH /api/v1/workspace
  def update
    workspace = Current.workspace

    if workspace.update(workspace_params)
      render json: workspace_json(workspace)
    else
      render json: { errors: workspace.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def workspace_params
    params.require(:workspace).permit(:developer_mode)
  end

  def workspace_json(w)
    {
      workspace: {
        id: w.id,
        name: w.name,
        developer_mode: w.developer_mode
      }
    }
  end
end
```

### 3.2 Debug Sessions Controller

Lists and shows sessions with full metadata.

```ruby
# app/controllers/api/v1/debug/sessions_controller.rb
class Api::V1::Debug::SessionsController < ApplicationController
  include RequireDeveloperMode

  # GET /api/v1/debug/sessions
  def index
    sessions = Current.workspace.sessions
                      .includes(:agent)
                      .order(last_activity_at: :desc)

    sessions = sessions.where(status: params[:status]) if params[:status].present?
    sessions = sessions.where(agent_id: params[:agent_id]) if params[:agent_id].present?

    # Cursor-based pagination (UUIDv7 is time-ordered)
    sessions = sessions.where("sessions.id < ?", params[:cursor]) if params[:cursor].present?
    sessions = sessions.limit(params.fetch(:limit, 25).to_i.clamp(1, 100))

    render json: {
      sessions: sessions.map { |s| session_summary_json(s) },
      next_cursor: sessions.last&.id
    }
  end

  # GET /api/v1/debug/sessions/:id
  def show
    session = Current.workspace.sessions
                     .includes(:agent)
                     .find(params[:id])

    render json: {
      session: session_detail_json(session)
    }
  end

  private

  def session_summary_json(s)
    {
      id: s.id,
      agent: { id: s.agent_id, slug: s.agent.slug, name: s.agent.name },
      gateway: s.gateway,
      status: s.status,
      message_count: s.message_count,
      total_tokens: s.total_tokens,
      model_id: s.agent.model_id,
      summary: s.summary&.truncate(200),
      started_at: s.started_at&.iso8601,
      last_activity_at: s.last_activity_at&.iso8601,
      context_window_usage: s.context_window_usage.round(3),
      active_message_count: s.messages.active.count,
      compacted_message_count: s.messages.compacted.count
    }
  end

  def session_detail_json(s)
    session_summary_json(s).merge(
      summary_full: s.summary,
      title: s.title,
      context_data: s.context_data,
      context_window_size: s.context_window_size,
      estimated_context_tokens: s.estimated_context_tokens,
      ended_at: s.ended_at&.iso8601,
      created_at: s.created_at.iso8601
    )
  end
end
```

### 3.3 Debug Messages Controller

Paginated messages with full detail including tool calls.

```ruby
# app/controllers/api/v1/debug/messages_controller.rb
class Api::V1::Debug::MessagesController < ApplicationController
  include RequireDeveloperMode

  # GET /api/v1/debug/sessions/:session_id/messages
  def index
    session = Current.workspace.sessions.find(params[:session_id])

    messages = session.messages
                      .includes(:tool_calls)
                      .order(:created_at)

    # Filter by compaction status
    case params[:filter]
    when "active"
      messages = messages.active
    when "compacted"
      messages = messages.compacted
    end

    # Cursor-based pagination
    messages = messages.where("messages.id > ?", params[:cursor]) if params[:cursor].present?
    messages = messages.limit(params.fetch(:limit, 50).to_i.clamp(1, 200))

    render json: {
      messages: messages.map { |m| message_detail_json(m) },
      next_cursor: messages.last&.id
    }
  end

  private

  def message_detail_json(m)
    {
      id: m.id,
      role: m.role,
      content: m.content,
      content_raw: m.content_raw,
      compacted: m.compacted,
      importance: m.importance,
      model_id: m.model_id,
      response_id: m.response_id,
      input_tokens: m.input_tokens,
      output_tokens: m.output_tokens,
      cached_tokens: m.cached_tokens,
      created_at: m.created_at.iso8601,
      tool_calls: m.tool_calls.map { |tc| tool_call_json(tc) }
    }
  end

  def tool_call_json(tc)
    {
      id: tc.id,
      tool_call_id: tc.tool_call_id,
      name: tc.name,
      arguments: tc.arguments
    }
  end
end
```

### 3.4 Debug Context Controller

Shows what the LLM actually receives — assembled from `ContextBuilder`.

```ruby
# app/controllers/api/v1/debug/context_controller.rb
class Api::V1::Debug::ContextController < ApplicationController
  include RequireDeveloperMode

  # GET /api/v1/debug/sessions/:session_id/context
  def show
    session = Current.workspace.sessions
                     .includes(:agent)
                     .find(params[:session_id])

    context = ContextBuilder.new(session:).build

    render json: {
      system_prompt: context[:system_prompt],
      session_summary: session.summary,
      active_message_count: context[:active_message_count],
      compacted_message_count: session.messages.compacted.count,
      total_message_count: session.messages.count,
      estimated_tokens: context[:estimated_tokens],
      context_window_size: session.context_window_size,
      context_window_usage: session.context_window_usage.round(3),
      model: {
        id: session.agent.model_id,
        provider: session.agent.resolved_provider&.to_s || SimpleChatService::PROVIDER.to_s,
        context_window: session.context_window_size
      }
    }
  end
end
```

**Note**: This endpoint depends on `ContextBuilder` from the session management RFC. If that RFC hasn't shipped yet, provide a simplified version that returns the system prompt from `PromptBuilder` and basic message counts.

---

## 4. Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)

# Workspace settings
resource :workspace, only: [:update]

# Debug namespace — gated by RequireDeveloperMode
namespace :debug do
  resources :sessions, only: [:index, :show] do
    resources :messages, only: [:index]
    resource :context, only: [:show], controller: "context"
  end
end
```

---

## 5. Frontend

### 5.1 React Router Setup

The current frontend has no router — just `AppShell` → `ChatContainer`. Debug tools require separate views (sessions explorer, session detail). Add React Router now.

```typescript
// frontend/src/App.tsx
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AppShell } from './components/layout/AppShell'
import { ChatContainer } from './components/chat/ChatContainer'
import { DebugSessionsPage } from './pages/DebugSessionsPage'
import { DebugSessionDetailPage } from './pages/DebugSessionDetailPage'

function App() {
  return (
    <BrowserRouter>
      <AppShell>
        <Routes>
          <Route path="/" element={<ChatContainer />} />
          <Route path="/debug/sessions" element={<DebugSessionsPage />} />
          <Route path="/debug/sessions/:id" element={<DebugSessionDetailPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AppShell>
    </BrowserRouter>
  )
}
```

Debug routes are only navigable when developer mode is on — the nav links are conditionally rendered.

### 5.2 Types

```typescript
// frontend/src/types/debug.ts
export interface DebugSession {
  id: string
  agent: { id: string; slug: string; name: string }
  gateway: string
  status: 'active' | 'archived'
  message_count: number
  total_tokens: number
  model_id: string
  summary: string | null
  started_at: string | null
  last_activity_at: string | null
  context_window_usage: number
  active_message_count: number
  compacted_message_count: number
}

export interface DebugSessionDetail extends DebugSession {
  summary_full: string | null
  title: string | null
  context_data: Record<string, unknown>
  context_window_size: number
  estimated_context_tokens: number
  ended_at: string | null
  created_at: string
}

export interface DebugMessage {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string | null
  content_raw: string | null
  compacted: boolean
  importance: number | null
  model_id: string | null
  response_id: string | null
  input_tokens: number | null
  output_tokens: number | null
  cached_tokens: number | null
  created_at: string
  tool_calls: DebugToolCall[]
}

export interface DebugToolCall {
  id: string
  tool_call_id: string
  name: string
  arguments: Record<string, unknown>
}

export interface DebugContext {
  system_prompt: string
  session_summary: string | null
  active_message_count: number
  compacted_message_count: number
  total_message_count: number
  estimated_tokens: number
  context_window_size: number
  context_window_usage: number
  model: {
    id: string
    provider: string
    context_window: number
  }
}
```

### 5.3 API Client

```typescript
// frontend/src/services/debugApi.ts
import { apiRequest } from './api'
import type {
  DebugSession,
  DebugSessionDetail,
  DebugMessage,
  DebugContext,
} from '../types/debug'

interface PaginatedSessions {
  sessions: DebugSession[]
  next_cursor: string | null
}

interface PaginatedMessages {
  messages: DebugMessage[]
  next_cursor: string | null
}

export function fetchDebugSessions(params?: {
  status?: string
  agent_id?: string
  cursor?: string
  limit?: number
}): Promise<PaginatedSessions> {
  const query = new URLSearchParams()
  if (params?.status) query.set('status', params.status)
  if (params?.agent_id) query.set('agent_id', params.agent_id)
  if (params?.cursor) query.set('cursor', params.cursor)
  if (params?.limit) query.set('limit', String(params.limit))
  return apiRequest(`/debug/sessions?${query}`)
}

export function fetchDebugSession(id: string): Promise<{ session: DebugSessionDetail }> {
  return apiRequest(`/debug/sessions/${id}`)
}

export function fetchDebugMessages(
  sessionId: string,
  params?: { filter?: string; cursor?: string; limit?: number },
): Promise<PaginatedMessages> {
  const query = new URLSearchParams()
  if (params?.filter) query.set('filter', params.filter)
  if (params?.cursor) query.set('cursor', params.cursor)
  if (params?.limit) query.set('limit', String(params.limit))
  return apiRequest(`/debug/sessions/${sessionId}/messages?${query}`)
}

export function fetchDebugContext(sessionId: string): Promise<DebugContext> {
  return apiRequest(`/debug/sessions/${sessionId}/context`)
}
```

### 5.4 Developer Mode Hook

```typescript
// frontend/src/hooks/useDeveloperMode.ts
import { useState, useCallback } from 'react'
import { apiRequest } from '../services/api'

export function useDeveloperMode(initial: boolean) {
  const [enabled, setEnabled] = useState(initial)

  const toggle = useCallback(async () => {
    const next = !enabled
    await apiRequest('/workspace', {
      method: 'PATCH',
      body: JSON.stringify({ workspace: { developer_mode: next } }),
    })
    setEnabled(next)
  }, [enabled])

  return { developerMode: enabled, toggleDeveloperMode: toggle }
}
```

### 5.5 Component Tree

```
AppShell
  ├─ Header
  │  ├─ Logo + nav links
  │  ├─ [if developerMode] "Sessions" link → /debug/sessions
  │  ├─ Gear icon → SettingsDrawer (from RFC agent-configuration)
  │  │  └─ DeveloperModeToggle
  │  └─ User menu
  │
  ├─ Routes
  │  ├─ / → ChatContainer
  │  │      └─ [if developerMode] DebugPanel (overlay, bottom-right)
  │  │         ├─ TokenUsageBar (context window %)
  │  │         ├─ Model info (model_id, provider)
  │  │         ├─ Session metadata (message count, active/compacted)
  │  │         └─ "View Context" link → context modal
  │  │
  │  ├─ /debug/sessions → DebugSessionsPage
  │  │  └─ SessionsExplorer
  │  │     ├─ Filter bar (status, agent, search)
  │  │     ├─ Session cards (click to inspect)
  │  │     └─ Load more (cursor pagination)
  │  │
  │  └─ /debug/sessions/:id → DebugSessionDetailPage
  │     ├─ Session header (metadata, context usage)
  │     ├─ Tabs: Messages | Context
  │     ├─ MessageInspector
  │     │  ├─ Message list with role badges, timestamps
  │     │  ├─ [compacted] messages shown in muted style
  │     │  ├─ Expandable: raw content, token breakdown
  │     │  ├─ Tool calls: name, arguments, result (expandable)
  │     │  └─ Load more (cursor pagination)
  │     └─ ContextViewer
  │        ├─ System prompt (syntax highlighted)
  │        ├─ Session summary
  │        ├─ Token breakdown chart
  │        └─ Context window usage bar
```

### 5.6 Key UI Components

**TokenUsageBar** — Visual representation of context window usage:
```
[████████████░░░░░░░░] 62% (79,360 / 128,000 tokens)
```
- Green: < 50%
- Yellow: 50-75%
- Red: > 75% (compaction threshold)

**MessageInspector** — Each message shows:
- Role badge (user=blue, assistant=green, system=gray, tool=purple)
- Content (markdown rendered for assistant, plain for others)
- Expandable metadata: token counts, model_id, response_id, timing
- Compacted messages shown in muted gray with "compacted" badge
- Tool calls inline with expandable arguments/results

**ContextViewer** — Shows assembled LLM input:
- System prompt in a code block with syntax highlighting
- Session summary in a separate block
- Active message count vs total
- Token breakdown: system prompt estimate, summary estimate, messages estimate
- Visual comparison to context window limit

---

## 6. Implementation Phases

### Phase 1: Backend (independently testable)
1. Migration: developer_mode on workspaces
2. `RequireDeveloperMode` concern
3. `WorkspacesController` (PATCH for toggle)
4. Debug sessions controller (list + show)
5. Debug messages controller (paginated)
6. Debug context controller
7. Routes
8. Tests: concern gating, pagination, serialization

### Phase 2: Frontend — Settings Integration (depends on Phase 1 + RFC agent-configuration SettingsDrawer)
1. `useDeveloperMode` hook
2. `DeveloperModeToggle` component in SettingsDrawer
3. Debug API client + types
4. React Router setup in App.tsx

### Phase 3: Frontend — Debug UI (depends on Phase 2)
1. `DebugPanel` overlay in ChatContainer (token bar, session metadata)
2. `TokenUsageBar` component
3. `DebugSessionsPage` + `SessionsExplorer`
4. `DebugSessionDetailPage` + `MessageInspector`
5. `ContextViewer` component
6. AppShell navigation updates (conditional "Sessions" link)

---

## 7. Security Considerations

- **System prompt exposure**: Debug tools display the full system prompt (instructions, soul, identity). This is intentional for the workspace owner. When multi-user workspaces ship, gate debug tools behind `owner`/`admin` role — not just `developer_mode`.
- **Tool call data**: Future tool results (vault files, email content) may contain sensitive data. Debug views should display the same data the user already has access to — no privilege escalation.
- **No write operations**: All debug endpoints are read-only. No mutations are possible through the debug API.
- **Rate limiting**: Debug endpoints return potentially large payloads. Consider rate limiting (e.g., 60 requests/minute) to prevent abuse.

---

## 8. Performance Considerations

- **Cursor-based pagination**: UUIDv7 is time-ordered, so `WHERE id > cursor` is efficient with the primary key index. No offset-based pagination (which degrades at high page numbers).
- **`includes(:tool_calls)`**: Messages controller eager-loads tool calls to avoid N+1 queries.
- **`includes(:agent)`**: Sessions controller eager-loads agents to avoid N+1 on agent slug/name.
- **Session list uses `truncate(200)` on summary**: Prevents loading full summary text in list view.
- **Context endpoint reuses `ContextBuilder`**: Same code path as the runtime — no separate implementation to maintain.
- **Clamped limits**: `limit.to_i.clamp(1, 100)` prevents clients from requesting unbounded result sets.

---

## 9. Verification Checklist

1. `bin/rails db:migrate` succeeds — developer_mode on workspaces
2. `PATCH /api/v1/workspace` toggles developer_mode
3. Debug endpoints return 403 when developer_mode is off
4. Debug endpoints return data when developer_mode is on
5. `GET /debug/sessions` returns paginated session list
6. `GET /debug/sessions/:id` returns full session detail
7. `GET /debug/sessions/:id/messages` returns paginated messages with tool calls
8. `GET /debug/sessions/:id/context` returns assembled LLM context
9. Cursor pagination works correctly (next_cursor, load more)
10. Frontend: developer mode toggle works in settings drawer
11. Frontend: debug panel appears in chat when developer mode is on
12. Frontend: sessions explorer lists all sessions with click-to-inspect
13. Frontend: message inspector shows full detail including tool calls
14. `bundle exec rails test` passes
15. `bundle exec rubocop` passes
16. `bundle exec brakeman --quiet` shows no critical issues
