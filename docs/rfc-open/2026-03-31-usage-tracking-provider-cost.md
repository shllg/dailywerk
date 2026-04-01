---
type: rfc
title: Usage Tracking & Provider Cost Attribution
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/04-billing-and-operations
depends_on:
  - rfc/2026-03-29-simple-chat-conversation
implemented_by: []
phase: 2
---

# RFC: Usage Tracking & Provider Cost Attribution

## Context

[RFC: Simple Chat](../rfc-done/2026-03-29-simple-chat-conversation.md) implemented token tracking on messages (`input_tokens`, `output_tokens`, `thinking_tokens`, `cached_tokens`, `cache_creation_tokens`) and a `total_tokens` counter on sessions. The `ruby_llm_models` table has a `pricing` JSONB column that exists but is never populated.

No cost calculation, usage recording, or provider pricing data exists in code. [PRD 04 §2-4](../prd/04-billing-and-operations.md#2-provider-registry--llm-router) outlines a billing architecture, but this RFC refines it with three corrections:

1. **Always-on cost tracking** — `CostCalculator` returns real USD provider cost regardless of BYOK status. PRD 04 §6 says "CostCalculator returns `total_cost: 0` for BYOK" — this RFC supersedes that. Tracking must always reflect actual provider cost to enable dashboards, anomaly detection, and capacity planning.

2. **Decoupled provider tracking** — PRD 04 uses a single `UsageRecorder` service for all call types. This RFC introduces an adapter pattern where each provider type (LLM, search, embedding) has its own tracking adapter. This makes adding new providers (Brave, X API, MCP tools) a mechanical task.

3. **Background LLM calls can use BYOK** — PRD 04 §8 states background ops (compaction, summarization) "always use DailyWerk platform API keys." This RFC corrects that: workspaces can opt into using their BYOK keys for background ops, with platform keys as fallback.

This RFC answers: **"What does each tenant cost us?"** and **"What usage stats do we show users?"**

### What This RFC Covers

- Provider pricing configuration (YAML file → `ruby_llm_models.pricing` JSONB)
- `CostCalculator` service (tokens → USD provider cost)
- Provider tracking adapter architecture (`Tracking::Adapters::*`)
- `UsageRecorder` service (writes `usage_records`)
- `usage_records` and `usage_daily_summaries` database tables
- `ChatStreamJob` integration hook
- BYOK usage tracking (always on, flagged)
- Background LLM call cost attribution with BYOK option
- `AggregateUsageJob` for daily rollups
- Frontend usage stats API and minimal display

### What This RFC Does NOT Cover (→ RFC: Credit System & Billing)

- Credit pricing, credit balances, credit transactions (see [RFC: Credit System & Billing](./2026-03-31-credit-system-billing.md))
- Budget enforcement / credit reservation
- Stripe integration, subscription management
- Margin calculation
- Rate limiting ([PRD 04 §10.1](../prd/04-billing-and-operations.md#10-open-questions))

---

## 1. Provider Pricing Configuration

Provider costs are public knowledge (published on provider pricing pages). We store them in a YAML file checked into the repo and seed them into `ruby_llm_models.pricing` JSONB.

### 1.1 YAML Structure

```yaml
# config/provider_pricing.yml
#
# Source of truth for what providers charge us (USD).
# Updated when providers change their pricing.
# Seeded into ruby_llm_models.pricing via ProviderPricingSeeder.
#
# Structure:
#   LLM models:      per-token-type costs (per 1M tokens)
#   Search services:  per-query costs
#   Embedding models: per-token costs (per 1M tokens)

providers:
  anthropic:
    type: llm
    models:
      claude-opus-4-6:
        input_cost_per_1m: 15.00
        output_cost_per_1m: 75.00
        cached_input_cost_per_1m: 7.50
        thinking_cost_per_1m: 75.00          # Billed at output rate
        cache_creation_cost_per_1m: 18.75    # 1.25× input
      claude-sonnet-4-6:
        input_cost_per_1m: 3.00
        output_cost_per_1m: 15.00
        cached_input_cost_per_1m: 1.50
        thinking_cost_per_1m: 15.00
        cache_creation_cost_per_1m: 3.75
      claude-haiku-4-5:
        input_cost_per_1m: 0.80
        output_cost_per_1m: 4.00
        cached_input_cost_per_1m: 0.40
        thinking_cost_per_1m: 4.00
        cache_creation_cost_per_1m: 1.00

  openai:
    type: llm
    models:
      gpt-5.4:
        input_cost_per_1m: 2.50
        output_cost_per_1m: 10.00
        cached_input_cost_per_1m: 1.25
      gpt-5.4-pro:
        input_cost_per_1m: 10.00
        output_cost_per_1m: 40.00
        cached_input_cost_per_1m: 5.00
        thinking_cost_per_1m: 40.00
      gpt-5.3:
        input_cost_per_1m: 0.40
        output_cost_per_1m: 1.60
        cached_input_cost_per_1m: 0.20

  openai_embeddings:
    type: embedding
    models:
      text-embedding-3-small:
        input_cost_per_1m: 0.02

  brave:
    type: search
    cost_per_query: 0.005
```

### 1.2 ProviderPricingSeeder

Reads the YAML and writes pricing data into `ruby_llm_models.pricing` JSONB. Run via `bin/rails provider_pricing:seed` or automatically during `db:seed`.

```ruby
# app/services/provider_pricing_seeder.rb

# Seeds provider pricing from config/provider_pricing.yml into
# ruby_llm_models.pricing JSONB.
class ProviderPricingSeeder
  YAML_PATH = Rails.root.join("config/provider_pricing.yml").freeze

  # Loads pricing YAML and upserts into ruby_llm_models.pricing.
  #
  # @return [Integer] number of models updated
  def self.seed
    new.seed
  end

  # @return [Integer] number of models updated
  def seed
    config = YAML.load_file(YAML_PATH, symbolize_names: false)
    count = 0

    config["providers"].each do |_provider_name, provider_config|
      type = provider_config["type"]

      case type
      when "llm", "embedding"
        provider_config.fetch("models", {}).each do |model_id, pricing|
          count += 1 if update_model_pricing(model_id, pricing)
        end
      when "search"
        # Search pricing stored in app config, not in ruby_llm_models.
        # Adapters read directly from the YAML.
      end
    end

    count
  end

  private

  # @param model_id [String]
  # @param pricing [Hash]
  # @return [Boolean] true if a record was updated
  def update_model_pricing(model_id, pricing)
    records = RubyLLM::ModelRecord.where(model_id: model_id)
    return false if records.empty?

    records.update_all(pricing: pricing)
    true
  end
end
```

### 1.3 Rake Task

```ruby
# lib/tasks/provider_pricing.rake
namespace :provider_pricing do
  desc "Seed provider pricing from config/provider_pricing.yml into ruby_llm_models"
  task seed: :environment do
    count = ProviderPricingSeeder.seed
    puts "Updated pricing for #{count} model(s)"
  end
end
```

### 1.4 Seed Data Integration

```ruby
# db/seeds.rb (append after existing seeds)
ProviderPricingSeeder.seed
```

---

## 2. CostCalculator Service

Converts token counts into USD provider cost. BYOK-unaware — always returns real costs. Uses `BigDecimal` for precision.

### 2.1 Differences from PRD 04

| PRD 04 CostCalculator | This RFC |
|------------------------|----------|
| Ignores `thinking_tokens` | Handles all 5 token types |
| Ignores `cache_creation_tokens` | Handles cache creation cost |
| Returns `total_cost: 0` for BYOK | Always returns real USD cost |
| Uses `Float#round(8)` | Uses `BigDecimal` throughout |
| Reads from `model.metadata.dig("pricing", ...)` | Reads from `model.pricing` (direct JSONB column) |

### 2.2 Implementation

```ruby
# app/services/cost_calculator.rb

# Converts token counts into USD provider cost using model pricing data.
#
# BYOK-unaware: always returns real provider cost regardless of who pays.
# The credit layer (CreditPricer) handles BYOK exemption separately.
class CostCalculator
  TOKENS_PER_UNIT = BigDecimal("1_000_000")

  # Calculates provider cost in USD for a given LLM call.
  #
  # @param model_id [String] the LLM model identifier
  # @param input_tokens [Integer] prompt tokens
  # @param output_tokens [Integer] completion tokens
  # @param cached_tokens [Integer] prompt cache hit tokens (subtracted from input)
  # @param thinking_tokens [Integer] extended thinking tokens (Anthropic, OpenAI o-series)
  # @param cache_creation_tokens [Integer] prompt cache write tokens (Anthropic)
  # @return [Hash] { input_cost:, output_cost:, thinking_cost:, total_cost: } in USD
  def self.calculate(model_id:, input_tokens: 0, output_tokens: 0,
                     cached_tokens: 0, thinking_tokens: 0, cache_creation_tokens: 0)
    pricing = load_pricing(model_id)
    return zero_cost unless pricing

    input_price           = bd(pricing["input_cost_per_1m"])
    output_price          = bd(pricing["output_cost_per_1m"])
    cached_input_price    = bd(pricing["cached_input_cost_per_1m"] || input_price / 2)
    thinking_price        = bd(pricing["thinking_cost_per_1m"] || output_price)
    cache_creation_price  = bd(pricing["cache_creation_cost_per_1m"] || input_price)

    billable_input = [input_tokens - cached_tokens, 0].max

    input_cost          = (bd(billable_input) * input_price / TOKENS_PER_UNIT)
    cached_input_cost   = (bd(cached_tokens) * cached_input_price / TOKENS_PER_UNIT)
    output_cost         = (bd(output_tokens) * output_price / TOKENS_PER_UNIT)
    thinking_cost       = (bd(thinking_tokens) * thinking_price / TOKENS_PER_UNIT)
    cache_creation_cost = (bd(cache_creation_tokens) * cache_creation_price / TOKENS_PER_UNIT)

    total_input_cost = input_cost + cached_input_cost + cache_creation_cost

    {
      input_cost: total_input_cost.round(8),
      output_cost: output_cost.round(8),
      thinking_cost: thinking_cost.round(8),
      total_cost: (total_input_cost + output_cost + thinking_cost).round(8)
    }
  end

  # @return [Hash]
  def self.zero_cost
    { input_cost: BigDecimal("0"), output_cost: BigDecimal("0"),
      thinking_cost: BigDecimal("0"), total_cost: BigDecimal("0") }
  end

  # Calculates cost for a fixed per-query service (e.g. Brave search).
  #
  # @param cost_per_query [BigDecimal, Float] USD cost per query
  # @return [Hash]
  def self.calculate_per_query(cost_per_query:)
    cost = bd(cost_per_query)
    { input_cost: BigDecimal("0"), output_cost: BigDecimal("0"),
      thinking_cost: BigDecimal("0"), total_cost: cost }
  end

  class << self
    private

    # @param model_id [String]
    # @return [Hash, nil]
    def load_pricing(model_id)
      record = RubyLLM::ModelRecord.find_by(model_id: model_id)
      pricing = record&.pricing
      pricing if pricing.present? && pricing != {}
    end

    # @param value [Numeric, nil]
    # @return [BigDecimal]
    def bd(value)
      BigDecimal(value.to_s)
    end
  end
end
```

---

## 3. Provider Tracking Adapter Architecture

Each provider type has its own adapter that knows how to extract cost data from that provider's response format. All adapters produce a unified `Tracking::UsageEvent` value object.

### 3.1 Why Adapters?

Different services return cost data differently:
- **LLMs** return token counts in response headers/body → multiply by per-token price
- **Search APIs** (Brave) charge per query → fixed cost lookup
- **Embedding APIs** return token counts → per-token price (simpler than chat)
- **Future**: MCP tools, bridge operations, X API — each has its own cost model

The adapter pattern keeps provider-specific logic isolated. Adding a new provider is a mechanical task:
1. Create a new adapter class (copy an existing one)
2. Implement `#build_event` with the provider's cost logic
3. Add one entry to the registry

### 3.2 UsageEvent Value Object

```ruby
# app/models/tracking/usage_event.rb

# Immutable value object representing a single billable event.
# Produced by adapters, consumed by UsageRecorder.
# No database dependency — pure data, easy to test.
module Tracking
  UsageEvent = Data.define(
    :workspace_id,
    :session_id,       # nil for non-chat events (search, embedding)
    :message_id,       # nil for non-chat events
    :agent_slug,       # nil for non-agent events
    :provider,         # "anthropic", "openai", "brave", etc.
    :model_id,         # "claude-sonnet-4-6", "text-embedding-3-small", "brave-search"
    :request_type,     # "chat", "embedding", "search", "background", "mcp"
    :input_tokens,
    :output_tokens,
    :cached_tokens,
    :thinking_tokens,
    :cache_creation_tokens,
    :duration_ms,
    :provider_cost_usd,  # BigDecimal — real cost regardless of BYOK
    :byok,               # Boolean — true if user's own API key was used
    :metadata            # Hash — provider-specific extra data
  ) do
    # @return [Boolean]
    def token_based?
      %w[chat embedding background].include?(request_type)
    end
  end
end
```

### 3.3 Base Adapter

```ruby
# app/services/tracking/adapters/base.rb

# Base class for provider tracking adapters.
# Each adapter knows how to extract cost data from a specific provider type.
module Tracking
  module Adapters
    class Base
      # Builds a UsageEvent from provider-specific context.
      #
      # @param context [Hash] provider-specific data
      # @return [Tracking::UsageEvent]
      def build_event(context)
        raise NotImplementedError, "#{self.class}#build_event must be implemented"
      end

      private

      # @param value [Object]
      # @return [Integer]
      def to_i(value)
        value.to_i
      end
    end
  end
end
```

### 3.4 LLM Adapter

Used for chat completions and background LLM calls (compaction, summarization).

```ruby
# app/services/tracking/adapters/llm.rb

# Extracts token counts from a Message and calculates provider cost.
module Tracking
  module Adapters
    class Llm < Base
      # @param context [Hash] must include:
      #   :message    [Message]  — the assistant message with token counts
      #   :session    [Session]  — the chat session
      #   :workspace  [Workspace]
      #   :byok       [Boolean]  — whether BYOK key was used
      #   :request_type [String] — "chat" or "background"
      # @return [Tracking::UsageEvent]
      def build_event(context)
        message  = context.fetch(:message)
        session  = context.fetch(:session)
        workspace = context.fetch(:workspace)
        byok     = context.fetch(:byok, false)
        request_type = context.fetch(:request_type, "chat")

        model_id = session.chat_model_id || session.agent.model_id
        provider = (session.chat_model&.provider || session.agent.provider || "auto").to_s

        costs = CostCalculator.calculate(
          model_id: model_id,
          input_tokens: to_i(message.input_tokens),
          output_tokens: to_i(message.output_tokens),
          cached_tokens: to_i(message.cached_tokens),
          thinking_tokens: to_i(message.thinking_tokens),
          cache_creation_tokens: to_i(message.cache_creation_tokens)
        )

        Tracking::UsageEvent.new(
          workspace_id: workspace.id,
          session_id: session.id,
          message_id: message.id,
          agent_slug: session.agent&.slug,
          provider: provider,
          model_id: model_id,
          request_type: request_type,
          input_tokens: to_i(message.input_tokens),
          output_tokens: to_i(message.output_tokens),
          cached_tokens: to_i(message.cached_tokens),
          thinking_tokens: to_i(message.thinking_tokens),
          cache_creation_tokens: to_i(message.cache_creation_tokens),
          duration_ms: message.metadata&.dig("duration_ms"),
          provider_cost_usd: costs[:total_cost],
          byok: byok,
          metadata: {
            input_cost: costs[:input_cost],
            output_cost: costs[:output_cost],
            thinking_cost: costs[:thinking_cost]
          }
        )
      end
    end
  end
end
```

### 3.5 Search Adapter

Used for Brave search, future X API, and other per-query services.

```ruby
# app/services/tracking/adapters/search.rb

# Tracks per-query costs for search services.
module Tracking
  module Adapters
    class Search < Base
      # Per-query costs loaded once from provider_pricing.yml.
      PRICING = begin
        config = YAML.load_file(
          Rails.root.join("config/provider_pricing.yml"),
          symbolize_names: false
        )
        pricing = {}
        config["providers"].each do |name, provider|
          next unless provider["type"] == "search"
          pricing[name] = BigDecimal(provider["cost_per_query"].to_s)
        end
        pricing.freeze
      end

      # @param context [Hash] must include:
      #   :workspace    [Workspace]
      #   :provider     [String]  — "brave", "x", etc.
      #   :query_count  [Integer] — number of queries in this call (default 1)
      #   :byok         [Boolean]
      #   :metadata     [Hash]    — optional extra data
      # @return [Tracking::UsageEvent]
      def build_event(context)
        workspace = context.fetch(:workspace)
        provider  = context.fetch(:provider)
        query_count = context.fetch(:query_count, 1)
        byok = context.fetch(:byok, false)

        cost_per_query = PRICING.fetch(provider) do
          raise ArgumentError, "Unknown search provider: #{provider}. " \
                               "Add it to config/provider_pricing.yml under type: search."
        end
        total_cost = cost_per_query * query_count

        Tracking::UsageEvent.new(
          workspace_id: workspace.id,
          session_id: context[:session_id],
          message_id: context[:message_id],
          agent_slug: context[:agent_slug],
          provider: provider,
          model_id: "#{provider}-search",
          request_type: "search",
          input_tokens: 0,
          output_tokens: 0,
          cached_tokens: 0,
          thinking_tokens: 0,
          cache_creation_tokens: 0,
          duration_ms: context[:duration_ms],
          provider_cost_usd: total_cost,
          byok: byok,
          metadata: context.fetch(:metadata, {}).merge(query_count: query_count)
        )
      end
    end
  end
end
```

### 3.6 Embedding Adapter

Used for vault embedding generation and any other embedding calls.

```ruby
# app/services/tracking/adapters/embedding.rb

# Tracks token-based costs for embedding API calls.
module Tracking
  module Adapters
    class Embedding < Base
      # @param context [Hash] must include:
      #   :workspace    [Workspace]
      #   :model_id     [String]  — "text-embedding-3-small"
      #   :input_tokens [Integer] — total tokens embedded
      #   :byok         [Boolean]
      # @return [Tracking::UsageEvent]
      def build_event(context)
        workspace = context.fetch(:workspace)
        model_id  = context.fetch(:model_id)
        input_tokens = context.fetch(:input_tokens, 0)

        costs = CostCalculator.calculate(
          model_id: model_id,
          input_tokens: input_tokens
        )

        Tracking::UsageEvent.new(
          workspace_id: workspace.id,
          session_id: nil,
          message_id: nil,
          agent_slug: nil,
          provider: "openai",
          model_id: model_id,
          request_type: "embedding",
          input_tokens: input_tokens,
          output_tokens: 0,
          cached_tokens: 0,
          thinking_tokens: 0,
          cache_creation_tokens: 0,
          duration_ms: context[:duration_ms],
          provider_cost_usd: costs[:total_cost],
          byok: context.fetch(:byok, false),
          metadata: context.fetch(:metadata, {})
        )
      end
    end
  end
end
```

### 3.7 Adapter Registry

```ruby
# app/services/tracking/registry.rb

# Maps request types to their tracking adapters.
# To add a new provider: create an adapter, add one line here.
module Tracking
  REGISTRY = {
    "chat"       => Adapters::Llm.new,
    "background" => Adapters::Llm.new,
    "search"     => Adapters::Search.new,
    "embedding"  => Adapters::Embedding.new
  }.freeze

  # @param request_type [String]
  # @return [Tracking::Adapters::Base]
  # @raise [KeyError] if request_type is not registered
  def self.adapter_for(request_type)
    REGISTRY.fetch(request_type) do
      raise KeyError, "No tracking adapter for request_type '#{request_type}'. " \
                      "Register one in Tracking::REGISTRY."
    end
  end
end
```

---

## 4. UsageRecorder Service

Pure persistence layer. Receives a `Tracking::UsageEvent`, writes to `usage_records`. Separated from adapters so adapters are pure calculation (testable without DB).

```ruby
# app/services/usage_recorder.rb

# Persists a Tracking::UsageEvent to the usage_records table.
#
# This is a thin I/O layer — all cost calculation happens in adapters.
# Recording failures are logged but never propagated to callers.
class UsageRecorder
  # @param event [Tracking::UsageEvent]
  # @return [UsageRecord, nil] nil if recording fails
  def self.record(event)
    UsageRecord.create!(
      workspace_id: event.workspace_id,
      session_id: event.session_id,
      message_id: event.message_id,
      agent_slug: event.agent_slug,
      provider: event.provider,
      model_id: event.model_id,
      request_type: event.request_type,
      input_tokens: event.input_tokens,
      output_tokens: event.output_tokens,
      cached_tokens: event.cached_tokens,
      thinking_tokens: event.thinking_tokens,
      cache_creation_tokens: event.cache_creation_tokens,
      duration_ms: event.duration_ms,
      provider_cost_usd: event.provider_cost_usd,
      byok: event.byok,
      metadata: event.metadata
    )
  rescue StandardError => e
    Rails.logger.error(
      "[UsageRecorder] Failed to record usage: #{e.message} " \
      "(workspace=#{event.workspace_id} model=#{event.model_id} type=#{event.request_type})"
    )
    nil
  end
end
```

---

## 5. Database Migrations

### 5.1 Usage Records

Based on [PRD 01 §5.8](../prd/01-platform-and-infrastructure.md#58-credit--usage-tables) with additions: `cache_creation_tokens`, `byok`, `provider_cost_usd` as a named column (not split into input/output cost — total is sufficient for the usage layer; cost breakdown lives in `metadata`).

```ruby
# db/migrate/XXXXXXXX_create_usage_records.rb
class CreateUsageRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_records, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.references :message, type: :uuid, foreign_key: true
      t.string   :agent_slug
      t.string   :model_id,              null: false
      t.string   :provider,              null: false
      t.string   :request_type,          null: false, default: "chat"
      t.integer  :input_tokens,          default: 0
      t.integer  :output_tokens,         default: 0
      t.integer  :cached_tokens,         default: 0
      t.integer  :thinking_tokens,       default: 0
      t.integer  :cache_creation_tokens, default: 0
      t.decimal  :provider_cost_usd,     precision: 12, scale: 8, default: 0
      t.boolean  :byok,                  default: false
      t.integer  :duration_ms
      t.jsonb    :metadata,              default: {}
      t.timestamps

      t.index [:workspace_id, :created_at]
      t.index [:workspace_id, :model_id, :created_at], name: "idx_usage_records_workspace_model"
      t.index [:workspace_id, :request_type, :created_at], name: "idx_usage_records_workspace_type"
    end
  end
end
```

### 5.2 Usage Daily Summaries

```ruby
# db/migrate/XXXXXXXX_create_usage_daily_summaries.rb
class CreateUsageDailySummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_daily_summaries, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.date     :date,                  null: false
      t.string   :model_id,             null: false
      t.string   :provider,             null: false
      t.string   :request_type,         null: false, default: "chat"
      t.integer  :request_count,        default: 0
      t.integer  :total_input_tokens,   default: 0
      t.integer  :total_output_tokens,  default: 0
      t.integer  :total_thinking_tokens, default: 0
      t.decimal  :total_provider_cost_usd, precision: 12, scale: 6, default: 0
      t.integer  :byok_request_count,   default: 0
      t.timestamps

      t.index [:workspace_id, :date, :model_id, :provider, :request_type],
              unique: true, name: "idx_usage_daily_unique"
    end
  end
end
```

### 5.3 Models

```ruby
# app/models/usage_record.rb

# Per-call usage record. One row per LLM call, search query, or embedding request.
class UsageRecord < ApplicationRecord
  include WorkspaceScoped

  belongs_to :session, optional: true
  belongs_to :message, optional: true

  validates :model_id, presence: true
  validates :provider, presence: true
  validates :request_type, presence: true,
            inclusion: { in: %w[chat embedding search background mcp] }

  scope :for_period, ->(range) { where(created_at: range) }
  scope :platform_paid, -> { where(byok: false) }
  scope :byok_paid, -> { where(byok: true) }
end
```

```ruby
# app/models/usage_daily_summary.rb

# Daily aggregate of usage records. One row per (workspace, date, model, provider, type).
class UsageDailySummary < ApplicationRecord
  include WorkspaceScoped

  validates :date, presence: true
  validates :model_id, presence: true
  validates :provider, presence: true

  scope :for_period, ->(range) { where(date: range) }
end
```

### 5.4 RLS

Both tables inherit workspace-scoped RLS via `WorkspaceScoped`. The `enable_workspace_rls!` call in the migration ensures PostgreSQL-level isolation:

```ruby
# Add to each migration after create_table:
reversible do |dir|
  dir.up do
    execute "ALTER TABLE usage_records ENABLE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY workspace_isolation ON usage_records
        USING (workspace_id = current_setting('app.current_workspace_id')::uuid)
    SQL
  end
end
```

Same pattern for `usage_daily_summaries`.

---

## 6. ChatStreamJob Integration

### 6.1 Hook Point

In `ChatStreamJob#perform`, after `update_session_metadata` (line 45 of current code), add `record_usage`:

```ruby
# app/jobs/chat_stream_job.rb (updated perform method)
def perform(session_id, user_message, workspace_id:)
  session = Session.find(session_id)
  assistant_message = nil

  SimpleChatService.new(session:).call(user_message) do |chunk|
    next unless chunk.content.present?

    assistant_message ||= latest_assistant_message_for(session)
    ActionCable.server.broadcast(
      "session_#{session.id}",
      { type: "token", delta: chunk.content, message_id: assistant_message&.id }
    )
  end

  assistant_message = latest_assistant_message_for(session)
  ActionCable.server.broadcast(
    "session_#{session.id}",
    { type: "complete", content: assistant_message&.content, message_id: assistant_message&.id }
  )

  update_session_metadata(session, assistant_message)
  record_usage(session, assistant_message)                     # ← NEW
rescue StandardError => e
  # ... existing error handling unchanged ...
end
```

### 6.2 Usage Recording Method

```ruby
# app/jobs/chat_stream_job.rb (new private method)

# Records usage for the completed LLM call.
# Wrapped in rescue — tracking failure must never break the chat stream.
#
# @param session [Session]
# @param message [Message, nil]
# @return [void]
def record_usage(session, message)
  return unless message
  return unless message.input_tokens.to_i > 0 || message.output_tokens.to_i > 0

  workspace = Workspace.find(session.workspace_id)
  byok = workspace_uses_byok?(workspace, session)

  adapter = Tracking.adapter_for("chat")
  event = adapter.build_event(
    message: message,
    session: session,
    workspace: workspace,
    byok: byok,
    request_type: "chat"
  )
  UsageRecorder.record(event)
rescue StandardError => e
  Rails.logger.error("[ChatStream] Usage recording failed: #{e.message}")
end

# Checks whether the workspace has BYOK credentials for the session's provider.
#
# @param workspace [Workspace]
# @param session [Session]
# @return [Boolean]
def workspace_uses_byok?(workspace, session)
  provider = (session.chat_model&.provider || session.agent.provider).to_s
  # ApiCredential model ships with BYOK RFC — stub returns false until then.
  return false unless defined?(ApiCredential)

  ApiCredential.where(workspace: workspace, provider: provider, active: true).exists?
end
```

---

## 7. BYOK Usage Tracking

### 7.1 Principle

Usage tracking is **always on**. The `byok` boolean flag on `usage_records` distinguishes:
- `byok: false` — DailyWerk pays the provider (platform cost)
- `byok: true` — User pays the provider directly (no platform cost, but resource cost)

### 7.2 CostCalculator Behavior

`CostCalculator` always returns real USD provider cost regardless of BYOK. This is intentional:
- Dashboards show actual usage volume even for BYOK users
- Anomaly detection works on real cost data
- Capacity planning uses real numbers (BYOK users still consume server resources)

The credit layer (RFC: Credit System) is where BYOK exemption happens — `CreditPricer` returns 0 credits for `byok: true` events.

### 7.3 BYOK Detection

The `workspace_uses_byok?` check in §6.2 queries `ApiCredential` for the provider. This table ships with the BYOK RFC. Until then, the method returns `false` (all usage is platform-paid).

---

## 8. Background LLM Call Attribution

### 8.1 Correction to PRD 04

PRD 04 §8 states: "System operations always use DailyWerk platform API keys." This RFC corrects that — workspaces can opt into using BYOK keys for background operations.

### 8.2 Workspace Preference

```ruby
# Workspace settings JSONB field (existing column):
# { "background_key_source": "platform" }  # Default
# { "background_key_source": "byok" }      # Use workspace BYOK keys when available
```

### 8.3 Resolution Logic

Background jobs (compaction, summarization, memory extraction) use this resolution:

```ruby
# app/services/background_llm_resolver.rb

# Determines which API key to use for background LLM operations.
class BackgroundLlmResolver
  # @param workspace [Workspace]
  # @param provider [String] the LLM provider needed
  # @return [Hash] { byok: Boolean, context: RubyLLM::Context or nil }
  def self.resolve(workspace:, provider:)
    preference = workspace.settings&.dig("background_key_source") || "platform"

    if preference == "byok"
      credential = ApiCredential.resolve(workspace: workspace, provider: provider)
      if credential
        context = LlmContextBuilder.build(workspace: workspace)
        return { byok: true, context: context }
      end
      # Fallback to platform key if no BYOK credential for this provider
    end

    { byok: false, context: nil }
  end
end
```

### 8.4 Usage Recording for Background Calls

Background LLM calls use `request_type: "background"` and the same `Tracking::Adapters::Llm` adapter:

```ruby
# Example: in a compaction job
event = Tracking.adapter_for("background").build_event(
  message: compacted_message,
  session: session,
  workspace: workspace,
  byok: resolved[:byok],
  request_type: "background"
)
UsageRecorder.record(event)
```

---

## 9. AggregateUsageJob

Rolls up `usage_records` into `usage_daily_summaries` for fast dashboard queries. Runs daily at 00:15 via GoodJob cron (already registered in [PRD 04 §8](../prd/04-billing-and-operations.md#8-goodjob-configuration)).

### 9.1 Differences from PRD 04

| PRD 04 AggregateUsageJob | This RFC |
|--------------------------|----------|
| Groups by `(user_id, model_id, provider)` | Groups by `(workspace_id, date, model_id, provider, request_type)` |
| No BYOK tracking | Counts `byok_request_count` separately |
| No `request_type` grouping | Groups by `request_type` for per-category analytics |
| Uses `total_cost` | Uses `provider_cost_usd` |

### 9.2 Implementation

```ruby
# app/jobs/aggregate_usage_job.rb

# Rolls up usage_records into usage_daily_summaries.
# Runs daily at 00:15 for the previous day.
class AggregateUsageJob < ApplicationJob
  queue_as :maintenance

  # @param date [Date] the date to aggregate (default: yesterday)
  # @return [void]
  def perform(date = Date.yesterday)
    UsageRecord
      .where(created_at: date.all_day)
      .group(:workspace_id, :model_id, :provider, :request_type)
      .select(
        :workspace_id, :model_id, :provider, :request_type,
        "COUNT(*) as request_count",
        "SUM(input_tokens) as total_input_tokens",
        "SUM(output_tokens) as total_output_tokens",
        "SUM(thinking_tokens) as total_thinking_tokens",
        "SUM(provider_cost_usd) as total_provider_cost_usd",
        "COUNT(*) FILTER (WHERE byok = true) as byok_request_count"
      ).each do |row|
      UsageDailySummary.upsert(
        {
          workspace_id: row.workspace_id,
          date: date,
          model_id: row.model_id,
          provider: row.provider,
          request_type: row.request_type,
          request_count: row.request_count,
          total_input_tokens: row.total_input_tokens,
          total_output_tokens: row.total_output_tokens,
          total_thinking_tokens: row.total_thinking_tokens,
          total_provider_cost_usd: row.total_provider_cost_usd,
          byok_request_count: row.byok_request_count
        },
        unique_by: :idx_usage_daily_unique
      )
    end

    Rails.logger.info("[AggregateUsage] Aggregated usage for #{date}")
  end
end
```

---

## 10. Frontend: Usage Stats

### 10.1 API Endpoints

```ruby
# app/controllers/api/v1/usage_controller.rb

module Api
  module V1
    # Returns usage statistics for the current workspace.
    class UsageController < ApplicationController
      # Current period summary: totals by model and request type.
      #
      # GET /api/v1/usage/summary?period=30d
      def summary
        range = parse_period(params[:period] || "30d")

        records = UsageRecord
          .where(workspace: Current.workspace, created_at: range)
          .group(:model_id, :provider, :request_type)
          .select(
            :model_id, :provider, :request_type,
            "COUNT(*) as request_count",
            "SUM(input_tokens) as total_input_tokens",
            "SUM(output_tokens) as total_output_tokens",
            "SUM(thinking_tokens) as total_thinking_tokens",
            "SUM(provider_cost_usd) as total_provider_cost_usd",
            "COUNT(*) FILTER (WHERE byok = true) as byok_request_count"
          )

        render json: {
          period: params[:period] || "30d",
          models: records.map { |r| summary_json(r) }
        }
      end

      # Daily breakdown for charts.
      #
      # GET /api/v1/usage/daily?period=30d
      def daily
        range = parse_period(params[:period] || "30d")

        summaries = UsageDailySummary
          .where(workspace: Current.workspace, date: range)
          .order(:date)

        render json: {
          period: params[:period] || "30d",
          days: summaries.map { |s| daily_json(s) }
        }
      end

      private

      # @param period [String] "7d", "30d", "90d"
      # @return [Range<Time>]
      def parse_period(period)
        days = case period
               when "7d" then 7
               when "90d" then 90
               else 30
               end
        days.days.ago..Time.current
      end

      def summary_json(record)
        {
          model_id: record.model_id,
          provider: record.provider,
          request_type: record.request_type,
          request_count: record.request_count,
          total_input_tokens: record.total_input_tokens,
          total_output_tokens: record.total_output_tokens,
          total_thinking_tokens: record.total_thinking_tokens,
          total_provider_cost_usd: record.total_provider_cost_usd.to_f,
          byok_request_count: record.byok_request_count
        }
      end

      def daily_json(summary)
        {
          date: summary.date,
          model_id: summary.model_id,
          provider: summary.provider,
          request_type: summary.request_type,
          request_count: summary.request_count,
          total_input_tokens: summary.total_input_tokens,
          total_output_tokens: summary.total_output_tokens,
          total_provider_cost_usd: summary.total_provider_cost_usd.to_f,
          byok_request_count: summary.byok_request_count
        }
      end
    end
  end
end
```

### 10.2 Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
namespace :usage do
  get :summary
  get :daily
end
```

### 10.3 Frontend Types

```typescript
// frontend/src/types/usage.ts

export interface UsageModelSummary {
  model_id: string
  provider: string
  request_type: string
  request_count: number
  total_input_tokens: number
  total_output_tokens: number
  total_thinking_tokens: number
  total_provider_cost_usd: number
  byok_request_count: number
}

export interface UsageSummaryResponse {
  period: string
  models: UsageModelSummary[]
}

export interface UsageDailyEntry {
  date: string
  model_id: string
  provider: string
  request_type: string
  request_count: number
  total_input_tokens: number
  total_output_tokens: number
  total_provider_cost_usd: number
  byok_request_count: number
}

export interface UsageDailyResponse {
  period: string
  days: UsageDailyEntry[]
}
```

### 10.4 API Client

```typescript
// frontend/src/services/usageApi.ts
import type { UsageSummaryResponse, UsageDailyResponse } from '../types/usage'
import { apiRequest } from './api'

export function fetchUsageSummary(period = '30d'): Promise<UsageSummaryResponse> {
  return apiRequest<UsageSummaryResponse>(`/usage/summary?period=${period}`)
}

export function fetchUsageDaily(period = '30d'): Promise<UsageDailyResponse> {
  return apiRequest<UsageDailyResponse>(`/usage/daily?period=${period}`)
}
```

### 10.5 Usage Stats Component

A minimal stats display in the settings drawer (see [RFC: Agent Configuration](../rfc-done/2026-03-31-agent-configuration.md) §5.3). Detailed dashboards are deferred.

```
SettingsDrawer
  ├─ AgentConfigPanel (existing)
  └─ UsageStatsPanel (NEW)
     ├─ Period selector: 7d / 30d / 90d
     ├─ Total requests, total tokens, total provider cost
     ├─ Breakdown by model (table)
     └─ "BYOK" badge on rows where byok_request_count > 0
```

---

## 11. Implementation Phases

### Phase 1: Database (independently testable)
1. Migration: `usage_records` table with RLS
2. Migration: `usage_daily_summaries` table with RLS
3. `UsageRecord` model with validations and scopes
4. `UsageDailySummary` model

### Phase 2: Pricing & Cost Calculation
1. `config/provider_pricing.yml` with current pricing
2. `ProviderPricingSeeder` service + rake task
3. `CostCalculator` service
4. Update `db/seeds.rb` to call seeder
5. Tests: CostCalculator with all 5 token types, edge cases (zero tokens, missing pricing)

### Phase 3: Adapters & Recording
1. `Tracking::UsageEvent` value object
2. `Tracking::Adapters::Base` + `Llm` adapter
3. `Tracking::Adapters::Search` adapter
4. `Tracking::Adapters::Embedding` adapter
5. `Tracking::Registry`
6. `UsageRecorder` service
7. Tests: each adapter with mock data, UsageRecorder with DB

### Phase 4: Job Integration
1. `ChatStreamJob` hook: `record_usage` + `workspace_uses_byok?`
2. `BackgroundLlmResolver` service (stub until BYOK ships)
3. Integration test: send chat message → verify `usage_records` row created

### Phase 5: Aggregation
1. `AggregateUsageJob`
2. Tests: aggregation with mixed request_types and BYOK flags

### Phase 6: Frontend
1. `UsageController` with summary + daily endpoints
2. Routes
3. Frontend types + API client
4. `UsageStatsPanel` component
5. Wire into settings drawer

---

## 12. Security Considerations

- **No secrets in usage_records**: Token counts and costs are not sensitive. No API keys, no PII.
- **RLS workspace isolation**: Both tables use PostgreSQL RLS policies. Defense-in-depth with `WorkspaceScoped` concern.
- **Provider pricing is public**: YAML file checked into repo contains publicly available pricing data.
- **Cost recording failures are silent**: `UsageRecorder` catches all exceptions. A tracking bug must never break the user's chat experience.
- **No direct user input**: Usage records are written by server-side jobs only. No user-facing write endpoints for usage data.

---

## 13. Verification Checklist

1. `bin/rails db:migrate` succeeds — `usage_records` and `usage_daily_summaries` tables created with RLS
2. `bin/rails provider_pricing:seed` populates `ruby_llm_models.pricing` JSONB for known models
3. `CostCalculator.calculate(model_id: "claude-sonnet-4-6", input_tokens: 1000, output_tokens: 500)` returns correct USD costs
4. `CostCalculator.calculate` handles all 5 token types (input, output, cached, thinking, cache_creation)
5. `CostCalculator.calculate` returns `zero_cost` for unknown models (not an error)
6. Chat message → `usage_records` row created with correct token counts and provider cost
7. `UsageRecorder` failure does not break chat streaming
8. `AggregateUsageJob.perform_now(Date.yesterday)` creates correct daily summaries
9. `GET /api/v1/usage/summary` returns per-model breakdown for current workspace
10. `GET /api/v1/usage/daily` returns daily time series
11. `bundle exec rails test` passes
12. `bundle exec rubocop` passes
13. `bundle exec brakeman --quiet` shows no warnings
