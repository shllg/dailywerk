---
type: rfc
title: Agent Configuration Interface
created: 2026-03-31
updated: 2026-04-01
status: done
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

[RFC 002](./2026-03-29-simple-chat-conversation.md) implemented a minimal Agent model with 7 columns (slug, name, model_id, instructions, temperature, is_default, active) and a hardcoded default agent. The PRD target ([01 §5.3](../prd/01-platform-and-infrastructure.md#53-agent-tables), [03 §2](../prd/03-agentic-system.md#2-agent-model)) defines 22+ columns including soul, identity, thinking config, tool bindings, and memory isolation.

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
- Validation for new fields (length limits, jsonb schema, provider allowlist)
- `Session.model_record_for` updated to accept per-agent provider

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
# db/migrate/20260331100000_add_config_columns_to_agents.rb
class AddConfigColumnsToAgents < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      change_table :agents, bulk: true do |t|
        t.text :soul
        t.jsonb :identity, default: {}
        t.string :provider
        t.jsonb :params, default: {}
        t.jsonb :thinking, default: {}
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
    identity: {}.freeze,
    params: {}.freeze,
    thinking: {}.freeze
  }.freeze

  CONFIGURABLE_FIELDS = %i[
    name model_id provider temperature instructions soul identity params thinking
  ].freeze

  class << self
    # @return [Hash] the configurable default values exposed by the API
    def defaults
      CONFIGURABLE_FIELDS.index_with { |field| default_for(field) }
    end

    # Resets the agent's configurable fields to their factory defaults.
    #
    # @param agent [Agent]
    # @return [Agent]
    def reset!(agent)
      agent.update!(defaults)
      agent
    end

    private

    # @param field [Symbol]
    # @return [Object]
    def default_for(field)
      VALUES.fetch(field).deep_dup
    end
  end
end
```

### Seed Data Update

```ruby
# db/seeds.rb (replace existing agent seed)
workspace.agents.find_or_create_by!(slug: AgentDefaults::VALUES[:slug]) do |agent|
  AgentDefaults::VALUES.except(:slug).each do |field, value|
    agent.public_send(:"#{field}=", value.deep_dup)
  end
  agent.is_default = true
end
```

---

## 3. Prompt Builder

Extracted from the model per single responsibility. Assembles the system prompt from multiple agent fields in priority order.

```ruby
# app/services/prompt_builder.rb

# Assembles the system prompt from an agent's stored configuration.
class PromptBuilder
  IDENTITY_SECTIONS = {
    "persona" => "Persona",
    "tone" => "Tone",
    "constraints" => "Constraints"
  }.freeze

  # @param agent [Agent]
  def initialize(agent)
    @agent = agent
  end

  # @return [String] the combined system prompt for the agent
  def build
    sections = []
    sections << @agent.instructions if @agent.instructions.present?
    sections << soul_section if @agent.soul.present?

    assembled_identity = identity_sections
    sections << assembled_identity if assembled_identity.present?

    sections.join("\n\n")
  end

  private

  # @return [String]
  def soul_section
    "## Soul\n\n#{@agent.soul}"
  end

  # @return [String]
  def identity_sections
    normalized_identity = @agent.identity.is_a?(Hash) ? @agent.identity.deep_stringify_keys : {}

    IDENTITY_SECTIONS.filter_map do |key, title|
      value = normalized_identity[key]
      next if value.blank?

      "## #{title}\n\n#{value}"
    end.join("\n\n")
  end
end
```

### Agent Model Update

```ruby
# app/models/agent.rb
class Agent < ApplicationRecord
  include WorkspaceScoped

  ALLOWED_PROVIDERS = %w[openai openai_responses anthropic google].freeze
  IDENTITY_ALLOWED_KEYS = %w[persona tone constraints].freeze
  THINKING_ALLOWED_KEYS = %w[enabled budget_tokens].freeze
  PARAMS_ALLOWED_KEYS = %w[max_tokens top_p frequency_penalty presence_penalty stop].freeze
  MAX_CONFIG_TEXT_LENGTH = 50_000
  MAX_IDENTITY_VALUE_LENGTH = 20_000
  MAX_PARAMS_JSON_BYTESIZE = 10.kilobytes
  DEFAULT_THINKING_BUDGET_TOKENS = 10_000

  has_many :sessions, dependent: :destroy, inverse_of: :agent

  validates :slug, presence: true, uniqueness: { scope: :workspace_id }
  validates :name, presence: true
  validates :model_id, presence: true
  validates :soul, length: { maximum: MAX_CONFIG_TEXT_LENGTH }, allow_nil: true
  validates :instructions, length: { maximum: MAX_CONFIG_TEXT_LENGTH }, allow_nil: true
  validates :provider, inclusion: { in: ALLOWED_PROVIDERS }, allow_blank: true
  validate :validate_identity_schema
  validate :validate_thinking_schema
  validate :validate_params_schema

  scope :active, -> { where(active: true) }

  # @return [String] the system instructions passed to the LLM
  def resolved_instructions
    PromptBuilder.new(self).build
  end

  # @return [Symbol, nil] the configured provider, if present
  def resolved_provider
    provider.presence&.to_sym
  end

  # @return [Hash] the provider thinking config, or an empty hash when disabled
  def thinking_config
    normalized_thinking = thinking_hash
    return {} unless normalized_thinking["enabled"] == true

    {
      thinking: {
        budget_tokens: normalized_thinking.fetch(
          "budget_tokens",
          DEFAULT_THINKING_BUDGET_TOKENS
        )
      }
    }
  end

  private

  # @return [Hash]
  def identity_hash
    identity.is_a?(Hash) ? identity.deep_stringify_keys : {}
  end

  # @return [Hash]
  def thinking_hash
    thinking.is_a?(Hash) ? thinking.deep_stringify_keys : {}
  end

  # @return [Hash]
  def params_hash
    self.params.is_a?(Hash) ? self.params.deep_stringify_keys : {}
  end

  # @return [void]
  def validate_identity_schema
    return if identity.nil? || identity == {}

    unless identity.is_a?(Hash)
      errors.add(:identity, "must be an object")
      return
    end

    unknown_keys = identity_hash.keys - IDENTITY_ALLOWED_KEYS
    errors.add(:identity, "contains unknown keys: #{unknown_keys.join(', ')}") if unknown_keys.any?

    identity_hash.each_value do |value|
      unless value.is_a?(String)
        errors.add(:identity, "values must be strings")
        break
      end

      if value.length > MAX_IDENTITY_VALUE_LENGTH
        errors.add(:identity, "values must be #{MAX_IDENTITY_VALUE_LENGTH} characters or fewer")
        break
      end
    end
  end

  # @return [void]
  def validate_thinking_schema
    return if thinking.nil? || thinking == {}

    unless thinking.is_a?(Hash)
      errors.add(:thinking, "must be an object")
      return
    end

    unknown_keys = thinking_hash.keys - THINKING_ALLOWED_KEYS
    errors.add(:thinking, "contains unknown keys: #{unknown_keys.join(', ')}") if unknown_keys.any?

    if thinking_hash.key?("enabled") && ![ true, false ].include?(thinking_hash["enabled"])
      errors.add(:thinking, "enabled must be true or false")
    end

    return unless thinking_hash.key?("budget_tokens")

    budget_tokens = thinking_hash["budget_tokens"]
    unless budget_tokens.is_a?(Integer) && budget_tokens.between?(1, 100_000)
      errors.add(:thinking, "budget_tokens must be an integer between 1 and 100,000")
    end
  end

  # @return [void]
  def validate_params_schema
    return if self.params.nil? || self.params == {}

    unless self.params.is_a?(Hash)
      errors.add(:params, "must be an object")
      return
    end

    unknown_keys = params_hash.keys - PARAMS_ALLOWED_KEYS
    errors.add(:params, "contains unknown keys: #{unknown_keys.join(', ')}") if unknown_keys.any?

    return unless ActiveSupport::JSON.encode(params_hash).bytesize > MAX_PARAMS_JSON_BYTESIZE

    errors.add(:params, "must be 10 KB or smaller")
  end
end
```

**Key differences from the original RFC draft:**
- `resolved_provider` uses `provider.presence&.to_sym` (not `provider&.to_sym`) — empty string `""` returns `nil` instead of crashing with `:""`
- Provider validation: `validates :provider, inclusion: { in: ALLOWED_PROVIDERS }, allow_blank: true` — rejects unknown providers at save time (422) instead of at LLM call time (500)
- Identity allowed keys: `persona`, `tone`, `constraints` only — `examples` removed (accepted but never rendered by PromptBuilder)
- Identity values must be strings — non-string values (arrays, hashes) are rejected, preventing validation bypass
- Thinking validation: `enabled` must be boolean (`true`/`false`), `budget_tokens` must be 1-100,000, unknown keys rejected
- Params validation: key allowlist (`max_tokens`, `top_p`, `frequency_penalty`, `presence_penalty`, `stop`) + 10KB bytesize cap

---

## 4. Controller

```ruby
# app/controllers/api/v1/agents_controller.rb
module Api
  module V1
    # Manages the editable configuration for a workspace agent.
    class AgentsController < ApplicationController
      # Returns the current agent configuration plus factory defaults.
      def show
        render json: response_payload
      end

      # Updates the editable agent fields.
      def update
        if agent.update(agent_params)
          render json: response_payload
        else
          render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Restores the agent's configurable fields to their defaults.
      def reset
        AgentDefaults.reset!(agent)
        render json: response_payload
      end

      private

      def response_payload
        {
          agent: agent_json(agent),
          defaults: AgentDefaults.defaults
        }
      end

      def agent
        @agent ||= Current.workspace.agents.active.find(params[:id])
      end

      def agent_params
        params.require(:agent).permit(
          :name, :model_id, :provider, :temperature, :instructions, :soul,
          identity: %w[persona tone constraints],
          thinking: %w[enabled budget_tokens]
        )
      end

      def agent_json(agent)
        {
          id: agent.id,
          slug: agent.slug,
          name: agent.name,
          model_id: agent.model_id,
          provider: agent.provider,
          temperature: agent.temperature,
          instructions: agent.instructions,
          soul: agent.soul,
          identity: agent.identity || {},
          params: agent.params || {},
          thinking: agent.thinking || {},
          is_default: agent.is_default,
          active: agent.active
        }
      end
    end
  end
end
```

**Note:** `params` is not in the strong parameters permit list — it is validated at the model level only. The `params` column is not user-editable via the standard config UI; it is reserved for future programmatic use.

### Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
resources :agents, only: %i[show update] do
  post :reset, on: :member
end
```

---

## 5. Frontend

### 5.1 API Client

```typescript
// frontend/src/services/agentApi.ts
import type { AgentConfigResponse, AgentConfigUpdate } from '../types/agent'
import { apiRequest } from './api'

export function fetchAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}`)
}

export function updateAgentConfig(
  agentId: string,
  updates: Partial<AgentConfigUpdate>,
): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}`, {
    method: 'PATCH',
    body: JSON.stringify({ agent: updates }),
  })
}

export function resetAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}/reset`, {
    method: 'POST',
  })
}
```

### 5.2 Types

```typescript
// frontend/src/types/agent.ts
export interface AgentIdentity {
  persona?: string
  tone?: string
  constraints?: string
}

export interface AgentThinking {
  enabled?: boolean
  budget_tokens?: number
}

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

export type AgentConfigUpdate = Pick<
  AgentConfig,
  'name' | 'model_id' | 'provider' | 'temperature' | 'instructions' | 'soul' | 'identity' | 'thinking'
>

export type AgentDefaults = Pick<
  AgentConfig,
  'name' | 'model_id' | 'provider' | 'temperature' | 'instructions' | 'soul' | 'identity' | 'params' | 'thinking'
>

export interface AgentConfigResponse {
  agent: AgentConfig
  defaults: AgentDefaults
}
```

### 5.3 Settings Drawer

The settings drawer is triggered by a gear icon in the AppShell header. It contains the `AgentConfigPanel` as a collapsible section. The drawer uses DaisyUI's drawer component for consistent styling.

**Component tree:**
```
AppShell
  └─ header: gear icon button → opens SettingsDrawer
     └─ SettingsDrawer (DaisyUI drawer, right side)
        ├─ AgentConfigPanel
        │  ├─ Basic: name, model_id, provider, temperature (always visible)
        │  ├─ Advanced (collapse): instructions textarea, soul textarea
        │  ├─ Identity (collapse): persona, tone, constraints textareas
        │  ├─ Thinking (collapse): enabled toggle, budget_tokens input
        │  └─ Footer: Save button, Reset to Defaults button (with confirm dialog)
        └─ (Future: DeveloperModeToggle from RFC debug-tools)
```

**Key UX decisions:**
- Textarea fields use monospace font for instructions/soul (prompt engineering)
- "Reset to Defaults" shows a `window.confirm` dialog listing key defaults
- Changes take effect on the next message (no mid-session hot-swap)
- `ChatController#show` was updated to include `id` in the agent response, enabling the settings drawer to call the agents API

### 5.4 ChatController Update

`ChatController#show` now returns `id: agent.id` in the agent payload so the frontend settings drawer can call `GET /api/v1/agents/:id`. The `Agent` type in `frontend/src/types/chat.ts` was extended to include `id: string`.

---

## 6. SimpleChatService Update

`SimpleChatService` adopts `PromptBuilder` and the new agent fields. The constant was renamed from `PROVIDER` to `DEFAULT_PROVIDER` for clarity:

```ruby
# app/services/simple_chat_service.rb
class SimpleChatService
  DEFAULT_PROVIDER = :openai_responses

  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  def call(user_message, &stream_block)
    @session
      .with_model(@agent.model_id, provider: @agent.resolved_provider || DEFAULT_PROVIDER)
      .with_instructions(@agent.resolved_instructions)
      .with_temperature(@agent.temperature || 0.7)
      .ask(user_message, &stream_block)
  end
end
```

### Session.model_record_for Update

`Session.model_record_for` was updated to accept an optional `provider:` parameter (defaulting to `SimpleChatService::DEFAULT_PROVIDER`) so that per-agent providers are used when looking up model records:

```ruby
def self.model_record_for(model_id, provider: SimpleChatService::DEFAULT_PROVIDER.to_s)
  RubyLLM::ModelRecord.find_or_create_by!(
    model_id:,
    provider: provider.to_s
  ) { |model| ... }
end
```

`Session.resolve` passes the agent's resolved provider through to `model_record_for`.

---

## 7. Implementation Phases

### Phase 1: Backend (independently testable)
1. Migration: add columns to agents table
2. `AgentDefaults` service
3. `PromptBuilder` service
4. Agent model: new validations, `thinking_config`, `resolved_provider`
5. `AgentsController` + routes
6. Update `SimpleChatService` to use `resolved_provider`
7. Update `Session.model_record_for` to accept provider parameter
8. Update `ChatController` to include agent `id` in response
9. Update seed data
10. Tests: model, services, controller

### Phase 2: Frontend (depends on Phase 1 API)
1. Agent types + API client
2. Update `Agent` type in `chat.ts` to include `id`
3. `SettingsDrawer` component
4. `AgentConfigPanel` component with form fields
5. AppShell: add gear icon trigger, wire to ChatContainer agent state
6. Frontend tests

---

## 8. Security Considerations

- **No `instructions_path`**: ERB template rendering is deferred. ERB is full Ruby execution — even with an allowlist of template paths, user-editable fields interpolated via `<%= %>` create an RCE surface.
- **Content length limits**: `soul` and `instructions` validated at 50,000 characters max. `identity` values at 20,000 each. Prevents token budget abuse.
- **Strong parameters**: `agent_params` explicitly allows only known fields. `instructions_path` is NOT in the permit list. `params` is not in the permit list — validated at model level only.
- **`identity` key allowlist**: Only `persona`, `tone`, `constraints` are accepted. Values must be strings. Unknown keys are rejected by model validation.
- **`thinking` validation**: `enabled` must be boolean, `budget_tokens` must be integer 1-100,000, unknown keys rejected. Prevents financial DoS via unbounded budget tokens.
- **`params` validation**: Key allowlist (`max_tokens`, `top_p`, `frequency_penalty`, `presence_penalty`, `stop`) + 10KB bytesize cap. Prevents arbitrary JSON storage and DoS.
- **Provider allowlist**: `validates :provider, inclusion: { in: ALLOWED_PROVIDERS }, allow_blank: true`. Invalid providers rejected at save time (422) instead of crashing at LLM call time.
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
9. `bundle exec rails test` passes (39 tests, 0 failures)
10. `bundle exec rubocop` passes (no offenses)
11. `bundle exec brakeman --quiet` shows no warnings
