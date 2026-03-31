---
type: rfc
title: Agent Configuration Interface
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/01-platform-and-infrastructure
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-29-simple-chat-conversation
implemented_by: []
phase: 2
---

# RFC: Agent Configuration Interface

## Context

[RFC 002](../rfc-done/2026-03-29-simple-chat-conversation.md) implemented a minimal Agent model with 7 columns (slug, name, model_id, instructions, temperature, is_default, active) and a hardcoded default agent. The PRD target ([01 §5.3](../prd/01-platform-and-infrastructure.md#53-agent-tables), [03 §2](../prd/03-agentic-system.md#2-agent-model)) defines 22+ columns including soul, identity, thinking config, tool bindings, and memory isolation.

This RFC adds the **first configuration layer**: soul, identity, provider, model params, and thinking config — the fields that shape how the agent behaves. It also provides a REST API for viewing and editing agent config, a "reset to defaults" mechanism, and a frontend settings drawer.

### Design Principles

- **Nearly hidden**: Good defaults so most users never touch configuration. Settings live in a drawer behind a gear icon, not a full page.
- **Progressive disclosure**: Basic settings (name, model) visible first. Soul, identity, and thinking config behind collapsible "Advanced" sections.
- **Reset to defaults**: Every configurable field can be reset to its factory value. The system tracks whether a field was customized.
- **No `instructions_path`**: ERB templates are deferred. ERB is a remote code execution surface; if prompt templates are needed later, use a sandboxed engine (Liquid).

### What This RFC Covers

- Database migration adding soul, identity, provider, params, thinking columns to agents
- `PromptBuilder` service assembling system prompt from multiple agent fields
- `AgentDefaults` service providing factory defaults and reset logic
- REST API for agent configuration (show, update, reset)
- Frontend settings drawer with agent config form
- Validation for new fields (length limits, jsonb schema)

### What This RFC Does NOT Cover

- Tool system and `tool_names` column (see [PRD 03 §6](../prd/03-agentic-system.md#6-tool-system))
- Memory isolation and `memory_isolation` column (see [PRD 03 §7](../prd/03-agentic-system.md#7-memory-architecture))
- Multi-agent management, handoffs, `handoff_targets` (see [PRD 03 §4](../prd/03-agentic-system.md#4-multi-agent-routing--handoffs))
- MCP server config, `enabled_mcps` (see [PRD 04 §7](../prd/04-billing-and-operations.md#7-mcp--model-context-protocol))
- `instructions_path` ERB templates (deferred — security risk)
- Sandbox level, vault access (deferred to later RFCs)

---

## 1. Database Schema

### 1.1 Migration: Add Configuration Columns to Agents

```ruby
# db/migrate/TIMESTAMP_add_config_columns_to_agents.rb
class AddConfigColumnsToAgents < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      change_table :agents, bulk: true do |t|
        t.text   :soul                         # Personality, tone, boundaries
        t.jsonb  :identity, default: {}        # Structured persona { persona, tone, constraints, examples }
        t.string :provider                     # nil = auto-detect from model_id
        t.jsonb  :params, default: {}          # Extra model params { max_tokens, top_p, etc. }
        t.jsonb  :thinking, default: {}        # Extended thinking { enabled: bool, budget_tokens: int }
      end
    end
  end
end
```

All columns are nullable text/jsonb with safe defaults. No NOT NULL constraints, no index changes. `strong_migrations` is satisfied — `ADD COLUMN` with constant defaults is non-locking in PostgreSQL 11+.

**Deferred columns** (added by future RFCs): `instructions_path`, `tool_names`, `handoff_targets`, `enabled_mcps`, `tool_configs`, `memory_isolation`, `sandbox_level`, `vault_access`, `metadata`.

---

## 2. Agent Defaults

Factory defaults are stored as a frozen Ruby constant. This is version-controlled, requires no I/O, and is the single source of truth for both seed data and the reset endpoint.

```ruby
# app/services/agent_defaults.rb

# Provides factory-default values for agent configuration.
#
# Used by db/seeds.rb for initial agent creation and by the reset
# API endpoint to restore fields to their defaults.
class AgentDefaults
  VALUES = {
    slug: "main",
    name: "DailyWerk",
    model_id: "gpt-5.4",
    provider: nil,
    temperature: 0.7,
    instructions: <<~PROMPT.strip,
      You are DailyWerk, a helpful personal AI assistant.
      Be concise, friendly, and direct. Use markdown for formatting when helpful.
      If you don't know something, say so honestly.
    PROMPT
    soul: nil,
    identity: {},
    params: {},
    thinking: {}
  }.freeze

  # Configurable fields that can be reset to defaults.
  CONFIGURABLE_FIELDS = %i[
    model_id provider temperature instructions soul identity params thinking
  ].freeze

  # Resets all configurable fields on the agent to factory defaults.
  #
  # @param agent [Agent]
  # @return [Agent]
  def self.reset!(agent)
    updates = CONFIGURABLE_FIELDS.each_with_object({}) do |field, hash|
      hash[field] = VALUES[field]
    end
    agent.update!(updates)
    agent
  end
end
```

### Seed Data Update

```ruby
# db/seeds.rb (replace existing agent seed)
workspace = Workspace.first

workspace.agents.find_or_create_by!(slug: AgentDefaults::VALUES[:slug]) do |a|
  AgentDefaults::VALUES.except(:slug).each { |k, v| a.public_send(:"#{k}=", v) }
  a.is_default = true
end
```

---

## 3. Prompt Builder

Extracted from the model per single responsibility. Assembles the system prompt from multiple agent fields in priority order.

```ruby
# app/services/prompt_builder.rb

# Assembles the LLM system prompt from an agent's configuration fields.
#
# Priority order:
#   1. instructions (free-text system prompt)
#   2. soul (appended as "## Soul" section)
#   3. identity (appended as structured sections)
class PromptBuilder
  # @param agent [Agent]
  def initialize(agent)
    @agent = agent
  end

  # @return [String] the assembled system prompt
  def build
    sections = []
    sections << @agent.instructions if @agent.instructions.present?
    sections << soul_section if @agent.soul.present?
    sections << identity_sections if @agent.identity.present? && @agent.identity.any?
    sections.compact.join("\n\n")
  end

  private

  # @return [String]
  def soul_section
    "## Soul\n\n#{@agent.soul}"
  end

  # @return [String, nil]
  def identity_sections
    parts = []
    parts << "## Persona\n\n#{@agent.identity['persona']}" if @agent.identity["persona"].present?
    parts << "## Tone\n\n#{@agent.identity['tone']}" if @agent.identity["tone"].present?
    parts << "## Constraints\n\n#{@agent.identity['constraints']}" if @agent.identity["constraints"].present?
    parts.any? ? parts.join("\n\n") : nil
  end
end
```

### Agent Model Update

```ruby
# app/models/agent.rb
class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :sessions, dependent: :destroy, inverse_of: :agent

  validates :slug, presence: true, uniqueness: { scope: :workspace_id }
  validates :name, presence: true
  validates :model_id, presence: true
  validates :soul, length: { maximum: 50_000 }, allow_nil: true
  validates :instructions, length: { maximum: 50_000 }, allow_nil: true
  validate :validate_identity_schema
  validate :validate_thinking_schema

  scope :active, -> { where(active: true) }

  # Assembles the full system prompt from all configuration fields.
  #
  # @return [String]
  def resolved_instructions
    PromptBuilder.new(self).build
  end

  # Returns the provider to use, falling back to auto-detection.
  #
  # @return [Symbol, nil]
  def resolved_provider
    provider&.to_sym
  end

  # Returns extended thinking parameters when enabled.
  #
  # @return [Hash] empty hash if thinking is disabled
  def thinking_config
    return {} unless thinking.is_a?(Hash) && thinking["enabled"]

    { thinking: { budget_tokens: thinking["budget_tokens"] || 10_000 } }
  end

  private

  IDENTITY_ALLOWED_KEYS = %w[persona tone constraints examples].freeze

  # @return [void]
  def validate_identity_schema
    return if identity.blank? || !identity.is_a?(Hash)

    unknown = identity.keys - IDENTITY_ALLOWED_KEYS
    errors.add(:identity, "contains unknown keys: #{unknown.join(', ')}") if unknown.any?

    identity.each_value do |v|
      next unless v.is_a?(String) && v.length > 20_000

      errors.add(:identity, "values must be under 20,000 characters each")
      break
    end
  end

  # @return [void]
  def validate_thinking_schema
    return if thinking.blank? || !thinking.is_a?(Hash)

    if thinking.key?("budget_tokens") && !thinking["budget_tokens"].is_a?(Integer)
      errors.add(:thinking, "budget_tokens must be an integer")
    end
  end
end
```

---

## 4. Controller

```ruby
# app/controllers/api/v1/agents_controller.rb
class Api::V1::AgentsController < ApplicationController
  # GET /api/v1/agents/:id
  def show
    render json: {
      agent: agent_json(agent),
      defaults: AgentDefaults::VALUES.slice(*AgentDefaults::CONFIGURABLE_FIELDS)
    }
  end

  # PATCH /api/v1/agents/:id
  def update
    if agent.update(agent_params)
      render json: {
        agent: agent_json(agent),
        defaults: AgentDefaults::VALUES.slice(*AgentDefaults::CONFIGURABLE_FIELDS)
      }
    else
      render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/agents/:id/reset
  def reset
    AgentDefaults.reset!(agent)
    render json: {
      agent: agent_json(agent),
      defaults: AgentDefaults::VALUES.slice(*AgentDefaults::CONFIGURABLE_FIELDS)
    }
  end

  private

  def agent
    @agent ||= Current.workspace.agents.active.find(params[:id])
  end

  def agent_params
    params.require(:agent).permit(
      :name, :model_id, :provider, :temperature,
      :instructions, :soul,
      identity: %w[persona tone constraints examples],
      params: {},
      thinking: %w[enabled budget_tokens]
    )
  end

  def agent_json(a)
    {
      id: a.id,
      slug: a.slug,
      name: a.name,
      model_id: a.model_id,
      provider: a.provider,
      temperature: a.temperature,
      instructions: a.instructions,
      soul: a.soul,
      identity: a.identity,
      params: a.params,
      thinking: a.thinking,
      is_default: a.is_default,
      active: a.active
    }
  end
end
```

### Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
resources :agents, only: [:show, :update] do
  post :reset, on: :member
end
```

---

## 5. Frontend

### 5.1 API Client

```typescript
// frontend/src/services/agentApi.ts
import { apiRequest } from './api'
import type { AgentConfig, AgentDefaults } from '../types/agent'

interface AgentConfigResponse {
  agent: AgentConfig
  defaults: AgentDefaults
}

export function fetchAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest(`/agents/${agentId}`)
}

export function updateAgentConfig(
  agentId: string,
  updates: Partial<AgentConfig>,
): Promise<AgentConfigResponse> {
  return apiRequest(`/agents/${agentId}`, {
    method: 'PATCH',
    body: JSON.stringify({ agent: updates }),
  })
}

export function resetAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest(`/agents/${agentId}/reset`, { method: 'POST' })
}
```

### 5.2 Types

```typescript
// frontend/src/types/agent.ts
export interface AgentConfig {
  id: string
  slug: string
  name: string
  model_id: string
  provider: string | null
  temperature: number
  instructions: string | null
  soul: string | null
  identity: AgentIdentity
  params: Record<string, unknown>
  thinking: AgentThinking
  is_default: boolean
  active: boolean
}

export interface AgentIdentity {
  persona?: string
  tone?: string
  constraints?: string
  examples?: string
}

export interface AgentThinking {
  enabled?: boolean
  budget_tokens?: number
}

export type AgentDefaults = Pick<
  AgentConfig,
  'model_id' | 'provider' | 'temperature' | 'instructions' | 'soul' | 'identity' | 'params' | 'thinking'
>
```

### 5.3 Settings Drawer

The settings drawer is triggered by a gear icon in the AppShell header. It contains the `AgentConfigPanel` as a collapsible section. The drawer uses DaisyUI's drawer component for consistent styling.

**Component tree:**
```
AppShell
  └─ header: gear icon button → opens SettingsDrawer
     └─ SettingsDrawer (DaisyUI drawer, right side)
        ├─ AgentConfigPanel
        │  ├─ Basic: name, model_id, temperature (always visible)
        │  ├─ Advanced (collapse): instructions textarea, soul textarea
        │  ├─ Identity (collapse): persona, tone, constraints textareas
        │  ├─ Thinking (collapse): enabled toggle, budget_tokens input
        │  └─ Footer: Save button, Reset to Defaults button (with confirm dialog)
        └─ (Future: DeveloperModeToggle from RFC debug-tools)
```

**Key UX decisions:**
- Textarea fields use monospace font for instructions/soul (prompt engineering)
- "Reset to Defaults" shows a DaisyUI confirm modal listing which fields will change
- Changes take effect on the next message (no mid-session hot-swap)
- Fields that differ from defaults are visually marked (subtle indicator)

---

## 6. SimpleChatService Update

`SimpleChatService` adopts `PromptBuilder` and the new agent fields:

```ruby
# app/services/simple_chat_service.rb
class SimpleChatService
  PROVIDER = :openai_responses

  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  def call(user_message, &stream_block)
    @session
      .with_model(@agent.model_id, provider: @agent.resolved_provider || PROVIDER)
      .with_instructions(@agent.resolved_instructions)
      .with_temperature(@agent.temperature || 0.7)
      .ask(user_message, &stream_block)
  end
end
```

The change is minimal: `resolved_instructions` now delegates to `PromptBuilder` instead of returning `instructions.to_s`. `resolved_provider` falls back to the default provider when nil.

---

## 7. Implementation Phases

### Phase 1: Backend (independently testable)
1. Migration: add columns to agents table
2. `AgentDefaults` service
3. `PromptBuilder` service
4. Agent model: new validations, `thinking_config`, `resolved_provider`
5. `AgentsController` + routes
6. Update `SimpleChatService` to use `resolved_provider`
7. Update seed data
8. Tests: model, services, controller

### Phase 2: Frontend (depends on Phase 1 API)
1. Agent API client + types
2. `SettingsDrawer` component
3. `AgentConfigPanel` component with form fields
4. AppShell: add gear icon trigger
5. Frontend tests

---

## 8. Security Considerations

- **No `instructions_path`**: ERB template rendering is deferred. ERB is full Ruby execution — even with an allowlist of template paths, user-editable fields interpolated via `<%= %>` create an RCE surface.
- **Content length limits**: `soul` and `instructions` validated at 50,000 characters max. `identity` values at 20,000 each. Prevents token budget abuse.
- **Strong parameters**: `agent_params` explicitly allows only known fields. `instructions_path` is NOT in the permit list.
- **`identity` key allowlist**: Only `persona`, `tone`, `constraints`, `examples` are accepted. Unknown keys are rejected by model validation.
- **Workspace isolation**: `AgentsController` scopes all queries through `Current.workspace.agents`. RLS provides defense-in-depth.

---

## 9. Verification Checklist

1. `bin/rails db:migrate` succeeds — new columns on agents table
2. `bin/rails db:seed` uses `AgentDefaults::VALUES`
3. `GET /api/v1/agents/:id` returns agent config with defaults comparison
4. `PATCH /api/v1/agents/:id` updates soul, identity, thinking — validated
5. `POST /api/v1/agents/:id/reset` restores all configurable fields to defaults
6. Chat still works — `resolved_instructions` returns assembled prompt
7. Settings drawer opens from gear icon, shows agent form
8. Reset to defaults works with confirmation dialog
9. `bundle exec rails test` passes
10. `bundle exec rubocop` passes
11. `bundle exec brakeman --quiet` shows no critical issues
