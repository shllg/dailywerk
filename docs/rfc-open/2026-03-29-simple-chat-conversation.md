---
type: rfc
title: Simple Chat Conversation
created: 2026-03-29
updated: 2026-03-30
status: draft
implements:
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-30-workspace-isolation
phase: 1
---

# RFC: Simple Chat Conversation

## Context

DailyWerk's PRDs define a rich agentic system with tools, memory, multi-agent routing, and cross-channel messaging ([PRD 03](../prd/03-agentic-system.md)). This RFC extracts the **first implementable slice**: a simple, continuous conversation with a single "main" agent via the web frontend.

The goal is a working chat interface where a user can have a generic conversation with OpenAI's GPT-5.4 model. No tools, no memory, no handoffs — just a clean conversation loop with streaming responses.

### What This RFC Covers

- Database schema for agents, sessions, messages (workspace-scoped)
- ruby_llm + ruby_llm-responses_api integration (OpenAI Responses API)
- SimpleChatService for stateless LLM calls
- ChatStreamJob (GoodJob background job)
- ActionCable streaming (WebSocket output only)
- REST API controllers
- Frontend: single-chat view with top bar navigation (no sidebar conversation list)
- Session management: one active session per agent, auto-resolved
- Frontend bug fixes (stale closure, dual submission path)

### What This RFC Does NOT Cover (see PRDs)

- Tool system, memory architecture, vault ([PRD 03 §6-7](../prd/03-agentic-system.md#6-tool-system))
- Multi-agent routing, handoffs ([PRD 03 §4](../prd/03-agentic-system.md#4-multi-agent-routing--handoffs))
- Compaction, archival ([PRD 03 §8](../prd/03-agentic-system.md#8-compaction))
- Channel adapters — telegram, signal, etc. ([PRD 02 §1-2](../prd/02-integrations-and-channels.md#1-messaging-gateway--bridge-protocol))
- BYOK, budget enforcement, credits ([PRD 04 §3-6](../prd/04-billing-and-operations.md#3-credit-model))
- Smart session rotation (time-based, topic-based) — future RFC
- Confidential/isolated sessions (diary agent privacy) — future RFC

---

## 1. Prerequisites

- **User + Workspace models** exist with authentication and workspace scoping (`Current.workspace`, `WorkspaceScoped` concern, RLS via `app.current_workspace_id`)
- **Valkey** running (docker-compose provides it on port 6399)
- **Gems added to Gemfile**: `ruby_llm ~> 1.14`, `ruby_llm-responses_api ~> 0.5`
- **OpenAI API key** in Rails credentials (`rails credentials:edit`): `openai_api_key: sk-...`

---

## 2. Session Management Philosophy

### No Conversation List — One Continuous Chat Per Agent

The traditional "conversation list" sidebar (ChatGPT-style) is an **antipattern** for a personal AI assistant. When a user opens DailyWerk, they should see their ongoing conversation with their agent — not a list of fragmented chats to choose from.

Each gateway (web, telegram, signal) maintains its own session with an agent. The user perceives **one continuous conversation per agent per gateway**. Sessions never cross gateways — web and telegram are separate conversation contexts.

### Session Resolution

For this RFC, session resolution is simple: one active session per agent per workspace. When the user opens the web chat, the system finds-or-creates the active session for their default agent.

```
User opens web chat
  → Find active session for (workspace, default_agent)
  → If none exists, create one
  → User continues where they left off
```

### Future: Smart Session Rotation

In later RFCs, sessions will rotate based on conditions:
- **Time-based**: After N hours of inactivity, archive the current session and start a fresh one (but the agent can access the archived summary)
- **Topic-based**: Agent detects a significant topic shift and initiates a new session
- **Explicit**: User can request a fresh context ("let's start fresh")

The main agent will be able to access other sessions' summaries for context continuity, **except** for sessions marked as confidential (e.g., diary agent sessions — privacy boundary enforced at the data layer).

### Future: Sidebar Shows Agents, Not Conversations

When multi-agent support ships, the sidebar will list **agents** (Main, Research, Diary, etc.), not individual conversations. Clicking an agent opens its current session. This is fundamentally different from a conversation list.

---

## 3. Database Schema

All tables use UUIDv7 primary keys. All workspace-scoped tables include `workspace_id` and use the `WorkspaceScoped` concern. Columns are a forward-compatible subset of the full PRD schema ([01 §5](../prd/01-platform-and-infrastructure.md#5-canonical-database-schema)) — future migrations add columns, never rename or remove.

### 3.1 Agents Table (Minimal)

```ruby
# db/migrate/xxx_create_agents.rb
class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string   :slug,         null: false
      t.string   :name,         null: false
      t.string   :model_id,     null: false, default: "gpt-5.4"
      t.text     :instructions                # System prompt
      t.float    :temperature,  default: 0.7
      t.boolean  :is_default,   default: false
      t.boolean  :active,       default: true
      t.timestamps

      t.index [:workspace_id, :slug], unique: true
      t.index [:workspace_id, :is_default]
    end
  end
end
```

Enable RLS on agents table (add to existing RLS migration pattern):

```ruby
execute "ALTER TABLE agents ENABLE ROW LEVEL SECURITY;"
execute "ALTER TABLE agents FORCE ROW LEVEL SECURITY;"
execute <<~SQL
  CREATE POLICY workspace_isolation ON agents
    FOR ALL TO app_user
    USING (workspace_id::text = current_setting('app.current_workspace_id', true))
    WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
SQL
execute "GRANT SELECT, INSERT, UPDATE, DELETE ON agents TO app_user;"
```

**Deferred columns** (added by future RFCs): `soul`, `identity` (jsonb), `instructions_path`, `provider`, `params` (jsonb), `thinking` (jsonb), `tool_names` (jsonb), `handoff_targets` (jsonb), `enabled_mcps` (jsonb), `tool_configs` (jsonb), `memory_isolation`, `sandbox_level`, `vault_access` (array), `metadata` (jsonb).

### 3.2 Sessions Table (Minimal)

```ruby
# db/migrate/xxx_create_sessions.rb
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :agent,     type: :uuid, null: false, foreign_key: true

      t.string   :gateway,       null: false, default: "web"  # web, telegram, signal, api
      t.string   :status,        default: "active"             # active, archived
      t.string   :model_id                                     # acts_as_chat: model reference
      t.integer  :message_count,  default: 0
      t.integer  :total_tokens,   default: 0
      t.datetime :last_activity_at
      t.timestamps

      t.index [:workspace_id, :agent_id, :gateway], unique: true, where: "status = 'active'",
              name: "idx_sessions_active_unique"
      t.index [:workspace_id, :status]
    end
  end
end
```

**Key design**: The unique index `[workspace_id, agent_id, gateway] WHERE status = 'active'` enforces exactly one active session per agent per gateway per workspace. This is the foundation for the "one continuous conversation" model.

**`gateway` instead of `channel_id` FK**: For this phase, a simple string enum replaces the full `channels` table. When external channels ship, a `channels` table can be added with the gateway as a denormalized field, or the gateway string can be kept as a lightweight routing key.

**Deferred columns**: `session_type`, `provider`, `summary`, `title`, `context_data` (jsonb), `metadata` (jsonb), `started_at`, `ended_at`.

### 3.3 Messages Table

Must include columns required by ruby_llm's `acts_as_message` (v1.14+).

```ruby
# db/migrate/xxx_create_messages.rb
class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :session,   type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS

      t.string   :role,          null: false          # user, assistant, system, tool
      t.text     :content                             # NOTE: no presence validation — ruby_llm creates blank records before streaming
      t.text     :content_raw                         # Provider-specific raw payload (ruby_llm v1.9+)
      t.string   :model_id                            # Which model produced this message
      t.string   :response_id                         # OpenAI Responses API: previous_response_id chaining

      # Token tracking (ruby_llm writes these automatically)
      t.integer  :input_tokens
      t.integer  :output_tokens
      t.integer  :cached_tokens                       # ruby_llm v1.9+

      t.timestamps

      t.index [:session_id, :created_at]
    end
  end
end
```

**Deferred columns**: `agent_slug`, `thinking_text`, `thinking_signature`, `thinking_tokens` (v1.10+), `compacted`, `importance`.

### 3.4 Tool Calls Table (Required by ruby_llm)

ruby_llm's `acts_as_message` expects a `tool_calls` association even if no tools are used. Create the table now to satisfy the gem.

```ruby
# db/migrate/xxx_create_tool_calls.rb
class CreateToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_calls, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :message, type: :uuid, null: false, foreign_key: true
      t.string   :tool_call_id
      t.string   :name
      t.jsonb    :arguments, default: {}
      t.timestamps
    end
  end
end
```

### 3.5 Models Table (ruby_llm v1.7+ DB-backed registry)

```ruby
# db/migrate/xxx_create_ruby_llm_models.rb
# Generated by: bin/rails generate ruby_llm:install
# This creates the models table for ruby_llm's DB-backed model registry.
# After migration, run: bin/rails ruby_llm:load_models
```

Use the generator output as-is. The models table stores provider metadata, pricing, context window sizes, and capabilities for all available LLM models.

---

## 4. Models

### 4.1 Agent

```ruby
# app/models/agent.rb
class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :sessions, dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :workspace_id }
  validates :name, presence: true
  validates :model_id, presence: true

  scope :active, -> { where(active: true) }

  def resolved_instructions
    instructions.to_s
  end
end
```

### 4.2 Session

```ruby
# app/models/session.rb
class Session < ApplicationRecord
  include WorkspaceScoped

  acts_as_chat messages: :messages, model: :model

  belongs_to :agent
  has_many :messages, dependent: :destroy

  scope :active, -> { where(status: "active") }

  # Find or create the active session for an agent + gateway combo
  def self.resolve(agent:, gateway: "web")
    create_or_find_by!(
      agent: agent,
      workspace: Current.workspace,
      gateway: gateway,
      status: "active"
    ) do |s|
      s.model_id = agent.model_id
      s.last_activity_at = Time.current
    end
  end
end
```

### 4.3 Message

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  include WorkspaceScoped

  acts_as_message chat: :session, tool_calls: :tool_calls, model: :model

  belongs_to :session
  has_many :tool_calls, dependent: :destroy

  # NOTE: Do NOT add `validates :content, presence: true`
  # ruby_llm creates blank assistant messages before streaming content into them.
end
```

### 4.4 ToolCall

```ruby
# app/models/tool_call.rb
class ToolCall < ApplicationRecord
  acts_as_tool_call message: :message

  belongs_to :message
end
```

---

## 5. Service Layer

### SimpleChatService

A thin wrapper around ruby_llm. No tools, no memory injection, no handoffs. Just: configure the chat, ask, stream.

```ruby
# app/services/simple_chat_service.rb
class SimpleChatService
  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  def call(user_message, &stream_block)
    chat = @session.chat
    chat.with_instructions(@agent.resolved_instructions)
        .with_temperature(@agent.temperature || 0.7)

    chat.ask(user_message, &stream_block)
  end
end
```

**How `acts_as_chat` works**: `@session.chat` returns a `RubyLLM::Chat` instance backed by the session's persisted messages. Prior messages are automatically loaded into context. When `chat.ask` is called, ruby_llm:
1. Creates a user message record (role: "user")
2. Creates a blank assistant message record (for DOM targeting during streaming)
3. Streams content into the assistant message, updating the record on completion
4. Returns the completed assistant message

The `response_id` column enables OpenAI Responses API session resumption — only the new message is sent each turn, with `previous_response_id` pointing to the last response.

---

## 6. Background Job

LLM calls run in GoodJob workers (separate process from Falcon), not in-process. This avoids blocking Falcon's fiber reactor and provides crash recovery.

```ruby
# app/jobs/chat_stream_job.rb
class ChatStreamJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :llm

  # No retries for LLM jobs — inform user on failure, don't duplicate calls
  discard_on ActiveRecord::RecordNotFound

  def perform(session_id, user_message, workspace_id:)
    session = Session.find(session_id)

    service = SimpleChatService.new(session: session)

    # Pre-capture the assistant message_id after ruby_llm creates it
    assistant_message = nil

    response = service.call(user_message) do |chunk|
      next unless chunk.content.present?

      # On first chunk, capture the message record ruby_llm created
      assistant_message ||= session.messages.where(role: "assistant").order(created_at: :desc).first

      ActionCable.server.broadcast("session_#{session.id}", {
        type: "token",
        delta: chunk.content,
        message_id: assistant_message&.id
      })
    end

    # Send complete event with full content (fixes stale closure bug in frontend)
    assistant_message ||= session.messages.where(role: "assistant").order(created_at: :desc).first

    ActionCable.server.broadcast("session_#{session.id}", {
      type: "complete",
      content: assistant_message&.content,
      message_id: assistant_message&.id
    })

    # Update session metadata
    update_session_metadata(session, assistant_message)
  rescue => e
    ActionCable.server.broadcast("session_#{session_id}", {
      type: "error",
      message: "Something went wrong. Please try again."
    })
    Rails.logger.error "[ChatStream] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  end

  private

  def update_session_metadata(session, message)
    return unless message

    updates = { last_activity_at: Time.current }
    updates[:message_count] = session.messages.count

    if message.input_tokens.present? || message.output_tokens.present?
      delta = message.input_tokens.to_i + message.output_tokens.to_i
      updates[:total_tokens] = session.total_tokens + delta
    end

    session.update!(**updates)
  end
end
```

**Cross-process broadcasting**: `ActionCable.server.broadcast` works from GoodJob workers because ActionCable uses Valkey pub/sub (Redis-compatible). The worker publishes to Valkey; Falcon's ActionCable process subscribes and pushes to WebSocket clients.

---

## 7. ActionCable

### 7.1 Connection

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      # Reuse the same token verification as the Authentication concern
      token = request.params[:token]
      return reject_unauthorized_connection unless token

      payload = ActiveSupport::MessageVerifier.new(
        Rails.application.secret_key_base
      ).verify(token)

      User.find(payload[:user_id])
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      reject_unauthorized_connection
    end
  end
end
```

### 7.2 Channel Base

```ruby
# app/channels/application_cable/channel.rb
module ApplicationCable
  class Channel < ActionCable::Channel::Base
  end
end
```

### 7.3 SessionChannel

```ruby
# app/channels/session_channel.rb
class SessionChannel < ApplicationCable::Channel
  def subscribed
    workspace = current_user.default_workspace
    session = Session.where(workspace: workspace).find_by(id: params[:session_id])
    if session
      stream_from "session_#{session.id}"
    else
      reject
    end
  end
end
```

**No `receive` method** — messages are sent via REST POST, not ActionCable. The channel is output-only.

### 7.4 Configuration

```ruby
# config/environments/development.rb (add)
config.action_cable.allowed_request_origins = [
  "http://localhost:5173",  # Vite dev server
  "http://localhost:3000"   # Falcon
]
```

---

## 8. Controllers

### 8.1 Chat Controller

A single controller — no sessions CRUD needed. The session is auto-resolved.

```ruby
# app/controllers/api/v1/chat_controller.rb
class Api::V1::ChatController < ApplicationController
  # GET /api/v1/chat — load current session + message history
  def show
    agent = default_agent
    session = Session.resolve(agent: agent, gateway: "web")

    render json: {
      session_id: session.id,
      agent: { slug: agent.slug, name: agent.name },
      messages: session.messages
        .where(role: %w[user assistant system])
        .order(:created_at)
        .map { |m| message_json(m) }
    }
  end

  # POST /api/v1/chat — send a message
  def create
    agent = default_agent
    session = Session.resolve(agent: agent, gateway: "web")
    content = message_params[:content]

    return render json: { error: "Content required" }, status: :unprocessable_entity if content.blank?

    ChatStreamJob.perform_later(
      session.id,
      content,
      workspace_id: Current.workspace.id
    )

    render json: { session_id: session.id }, status: :accepted
  end

  private

  def default_agent
    Current.workspace.agents.active.find_by!(is_default: true)
  end

  def message_params
    params.require(:message).permit(:content)
  end

  def message_json(msg)
    {
      id: msg.id,
      role: msg.role,
      content: msg.content,
      timestamp: msg.created_at.iso8601
    }
  end
end
```

### 8.2 Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
namespace :chat do
  # GET  /api/v1/chat  — current session + history
  # POST /api/v1/chat  — send message
  resource :conversation, only: [:show, :create], controller: "chat"
end
```

Wait — simpler. Since it's a singleton resource:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  mount GoodJob::Engine => "good_job"
  mount ActionCable.server => "/cable"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"

      # Chat is a singleton — one conversation, auto-resolved session
      resource :chat, only: [:show, :create], controller: "chat"
    end
  end
end
```

---

## 9. ruby_llm Configuration

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.dig(:openai_api_key)
end
```

```ruby
# config/application.rb (add before Application class)
# Required for ruby_llm v1.7+ model associations
RubyLLM.configure do |config|
  config.use_new_acts_as = true
end
```

After migration: `bin/rails ruby_llm:load_models` to populate the models table.

---

## 10. Frontend Changes

### 10.1 UX: Single Chat View, No Sidebar

The first version is a **single-chat interface** — no conversation list, no sidebar. The user opens the app and is immediately in their conversation with the main agent.

```
┌──────────────────────────────────────────────────┐
│  TopBar: logo, nav links, user menu              │
├──────────────────────────────────────────────────┤
│                                                  │
│              ChatContainer                       │
│              (centered, max-width)               │
│                                                  │
│              Messages...                         │
│                                                  │
│              [Message input]                     │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Later (multi-agent)**: The sidebar will list **agents** (Main, Research, Diary), not conversations. Clicking an agent opens its current session.

### 10.2 Simplify API Client

Replace session-based API with the singleton chat endpoint:

```typescript
// frontend/src/services/chatApi.ts
import { apiRequest } from './api'

interface ChatState {
  session_id: string
  agent: { slug: string; name: string }
  messages: Message[]
}

export function fetchChat(): Promise<ChatState> {
  return apiRequest('/chat')
}

export async function sendMessage(content: string): Promise<void> {
  await apiRequest('/chat', {
    method: 'POST',
    body: JSON.stringify({ message: { content } }),
  })
}
```

### 10.3 Simplify Chat Types

Remove `Session` type (no conversation list). Simplify `Message`:

```typescript
// frontend/src/types/chat.ts
export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system'
  content: string
  timestamp: string
  status: 'sending' | 'sent' | 'streaming' | 'error'
}

export interface Agent {
  slug: string
  name: string
}
```

### 10.4 Simplify ChatContainer

Remove session selection logic. The container loads the chat on mount and connects to the session's ActionCable channel:

```typescript
// Simplified flow:
// 1. On mount: fetchChat() → get session_id + messages
// 2. Subscribe to ActionCable with session_id
// 3. On send: POST /api/v1/chat → tokens stream via ActionCable
// 4. On page refresh: fetchChat() reloads everything
```

Remove `ConversationList` component and `ChatLayout` (replaced by `AppShell` with just chat).

### 10.5 Fix `useActionCableChat` — Stale Closure Bug

The `complete` handler reads `streamingContent` from a stale closure (always empty string). Fix by using a `useRef` alongside state:

```typescript
// Add ref to track accumulated content
const streamingContentRef = useRef('')

// In token handler, update both:
setStreamingContent((prev) => {
  const next = prev + delta
  streamingContentRef.current = next
  return next
})

// In complete handler, use ref:
const finalContent = (event.content as string) || streamingContentRef.current
```

### 10.6 Fix `sendMessage` — Use REST POST Instead of ActionCable

Change `sendMessage` in `useActionCableChat.ts` to call `chatApi.sendMessage()` instead of `subscription.perform('receive')`.

### 10.7 Add `disconnected` Callback

Add reconnection handling to `useActionCableChat.ts`:

```typescript
disconnected() {
  setIsStreaming(false)
  setStreamingContent('')
  streamingContentRef.current = ''
}
```

### 10.8 ActionCable Token Auth

Pass the auth token as a query param when creating the ActionCable consumer:

```typescript
// frontend/src/services/cable.ts
import { createConsumer } from '@rails/actioncable'

export function createAuthenticatedConsumer(token: string) {
  return createConsumer(`/cable?token=${encodeURIComponent(token)}`)
}
```

---

## 11. Seed Data

Extends the existing workspace seed:

```ruby
# db/seeds.rb (append to existing user/workspace seed)
workspace = Workspace.first

workspace.agents.find_or_create_by!(slug: "main") do |a|
  a.name = "DailyWerk"
  a.model_id = "gpt-5.4"
  a.instructions = <<~PROMPT
    You are DailyWerk, a helpful personal AI assistant.
    Be concise, friendly, and direct. Use markdown for formatting when helpful.
    If you don't know something, say so.
  PROMPT
  a.temperature = 0.7
  a.is_default = true
end
```

---

## 12. Implementation Phases

### Phase 1: Database + Models
1. Add gems to Gemfile: `ruby_llm`, `ruby_llm-responses_api`
2. `bundle install`
3. Run `bin/rails generate ruby_llm:install` (generates models table migration)
4. Create migrations for agents, sessions, messages, tool_calls (with RLS policies)
5. Create model files (Agent, Session, Message, ToolCall) with `WorkspaceScoped`
6. `bin/rails db:migrate`
7. `bin/rails ruby_llm:load_models`
8. Update seed data, `bin/rails db:seed`
9. **Verify**: `bin/rails console` — `Session.resolve(agent: Agent.first).chat.ask("Hello")`

### Phase 2: Service + Job + ActionCable
1. Create `SimpleChatService`
2. Create `ChatStreamJob` with `WorkspaceScopedJob`
3. Create ActionCable connection (token auth), channel base, SessionChannel
4. Configure ActionCable allowed origins
5. Add `mount ActionCable.server => "/cable"` to routes
6. **Verify**: In console, enqueue a `ChatStreamJob` and check Valkey pub/sub output

### Phase 3: Controller + Routes
1. Create `Api::V1::ChatController` (singleton resource)
2. Add routes
3. **Verify**: `curl` — GET /api/v1/chat (loads session), POST /api/v1/chat (sends message, returns 202)

### Phase 4: Frontend Wiring
1. Create `AppShell` component with top bar + centered chat (no sidebar)
2. Update `App.tsx` to use `AppShell`
3. Simplify `chatApi.ts` to singleton chat endpoint
4. Simplify `types/chat.ts`
5. Fix `useActionCableChat` stale closure bug
6. Fix `sendMessage` to use REST POST
7. Add ActionCable token auth
8. Add `disconnected` callback
9. Remove `ConversationList`, `ChatLayout` (superseded)
10. **Verify**: Full end-to-end — open browser, see chat, send message, see streaming response

### Phase 5: Tests
1. Model tests (validations, associations, scopes, `Session.resolve`)
2. Service test (SimpleChatService with mocked ruby_llm)
3. Job test (ChatStreamJob enqueues and broadcasts)
4. Controller test (GET/POST /api/v1/chat)
5. Frontend tests (hook behavior, API client)

---

## 13. Known Limitations

| Limitation | Impact | Future RFC |
|------------|--------|------------|
| No tools | Agent can only chat | Tools RFC |
| No memory | No cross-session context | Memory RFC |
| No compaction | Long conversations may hit context limit | Compaction RFC |
| No budget/credits | Unbounded API spend | Billing RFC |
| No error retry | Failed LLM calls show generic error | Error handling RFC |
| No session rotation | Single session grows forever | Session management RFC |
| No multi-agent | Single default agent only | Multi-agent RFC |
| No confidential sessions | All sessions accessible | Privacy RFC |

---

## 14. Verification Checklist

1. `bin/dev` starts Falcon, GoodJob worker, and Vite dev server
2. Browser shows app shell with top bar and chat interface (no sidebar)
3. Chat loads existing messages on page open (GET /api/v1/chat)
4. Typing and sending a message shows it immediately
5. Assistant response streams in token-by-token via WebSocket
6. Page refresh reloads conversation from REST API — continuity preserved
7. `bundle exec rails test` passes
8. `cd frontend && pnpm test` passes
9. `bundle exec rubocop` passes
10. `bundle exec brakeman --quiet` shows no critical issues
