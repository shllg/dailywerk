---
type: prd
title: Billing & Operations
domain: billing
created: 2026-03-28
updated: 2026-03-28
status: canonical
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/02-integrations-and-channels
  - prd/03-agentic-system
---

# DailyWerk — Billing & Operations

> Payments, credit system, BYOK, MCP, cost tracking, provider management, and background job configuration.
> For database schema: see [01-platform-and-infrastructure.md §5](./01-platform-and-infrastructure.md#5-canonical-database-schema).
> For agent runtime hooks (cost recording, BYOK context, MCP tools): see [03-agentic-system.md](./03-agentic-system.md).
> For embedding cost tracking: see [02-integrations-and-channels.md §7](./02-integrations-and-channels.md#7-data-search--retrieval-layer).

---

## 1. Payments & Stripe Integration

- **Subscriptions**: Stripe Products/Prices. Upgrade/downgrade via Billing Portal.
- **Credit overage**: Stripe Usage Records (metered). Billed end of cycle if user enabled it.
- **Add-ons**: Managed Signal Bridge = separate Subscription Item (~€5/mo). Additional vaults = TBD.
- **Free tier**: No Stripe subscription. Internal credit grant. **Manual admin approval** — new users created as `pending` (see `users.status` in [01 §5.2](./01-platform-and-infrastructure.md#52-core-tables)). Admin unlocks before use.
- **Credit exhaustion**: Chat is **blocked** (not degraded). If overage billing enabled, additional credits charged per-credit.
- **Webhooks**: Stripe → Rails endpoint → update plan/credit/subscription state. Must use idempotency keys to prevent double-processing.
- **Webhook authentication**: Every Stripe webhook MUST verify the `Stripe-Signature` header via `Stripe::Webhook.construct_event(payload, sig_header, endpoint_secret)`. Without this, the endpoint is unauthenticated — attackers can forge subscription upgrades.
- **Idempotency**: Track processed events in a `processed_stripe_events` table with unique constraint on `stripe_event_id`. Prevents replay attacks and double-processing.

---

## 2. Provider Registry & LLM Router

Structured, versioned config (YAML initially, DB-backed later):

```yaml
providers:
  anthropic:
    base_url: "https://api.anthropic.com"
    auth_type: "api_key"
    models:
      claude-opus-4-6:
        input_cost_per_1m_tokens: 15.00
        output_cost_per_1m_tokens: 75.00
        context_window: 200000
        capabilities: [text, vision, tools]
        internal_credit_rate: 1.33
        tier: premium
      claude-sonnet-4-6:
        input_cost_per_1m_tokens: 3.00
        output_cost_per_1m_tokens: 15.00
        context_window: 200000
        capabilities: [text, vision, tools]
        internal_credit_rate: 1.33
        tier: standard
      claude-haiku-4-5:
        input_cost_per_1m_tokens: 0.80
        output_cost_per_1m_tokens: 4.00
        context_window: 200000
        capabilities: [text, vision, tools]
        internal_credit_rate: 1.33
        tier: economy
  openai:
    models:
      gpt-4o: { input_cost_per_1m_tokens: 2.50, output_cost_per_1m_tokens: 10.00, context_window: 128000, capabilities: [text, vision, tools] }
      text-embedding-3-small: { input_cost_per_1m_tokens: 0.02, type: embedding, dimensions: 1536 }
  openrouter:
    base_url: "https://openrouter.ai/api/v1"
    # Proxy to many providers. Models as provider/model (e.g. "anthropic/claude-sonnet-4")
    # Costs from OpenRouter pricing API, cached. Fallback when primary provider down.
  brave:
    type: search
    cost_per_query: 0.005
    internal_credit_rate: 1.40
```

### LLM Router

Routes by task type, user plan, agent config overrides, provider health. Falls back to OpenRouter if primary provider is down.

**Stats & measurement**: Every LLM call → `usage_records` (see [01 §5.8](./01-platform-and-infrastructure.md#58-credit--usage-tables)) with: provider, model, tokens_in, tokens_out, latency_ms, provider_cost, credits_charged. Enables per-user dashboards, per-model analysis, margin tracking, anomaly detection.

---

## 3. Credit Model

1 credit = $0.001. Pre-deduct estimated → reconcile actual async. Free tier: small monthly grant, no rollover. Embedding costs negligible (~$0.02/1M tokens) but tracked.

### Credit Lifecycle: Reserve → Execute → Reconcile

1. **Reserve**: Before each LLM call, estimate cost and atomically reserve credits:
   `UPDATE credit_balances SET balance = balance - estimated WHERE user_id = ? AND balance >= estimated`
   If the UPDATE affects 0 rows, the balance is insufficient — reject the request.
2. **Execute**: Proceed with the LLM call. Usage is recorded in `usage_records`.
3. **Reconcile**: `CreditReconcilerJob` (every 4 hours) compares reserved vs actual costs. Adjusts balance for over/under-estimates.

For high-concurrency scenarios, use Redis as an in-memory accumulator (`DECRBY user:{id}:balance estimated`) with periodic flush to PostgreSQL. This avoids row-level lock contention on `credit_balances`.

---

## 4. Token & Cost Tracking

### Cost Calculator

```ruby
# app/services/cost_calculator.rb
class CostCalculator
  def self.calculate(model_id:, input_tokens:, output_tokens:, cached_tokens: 0)
    model = RubyLLM.models.find(model_id)
    return zero_cost unless model

    input_price  = model.metadata.dig("pricing", "input")  || 0
    output_price = model.metadata.dig("pricing", "output") || 0
    cached_price = model.metadata.dig("pricing", "cached_input") || (input_price * 0.5)

    billable_input = [input_tokens - cached_tokens, 0].max
    input_cost  = (billable_input * input_price / 1_000_000.0)
    cached_cost = (cached_tokens * cached_price / 1_000_000.0)
    output_cost = (output_tokens * output_price / 1_000_000.0)

    {
      input_cost: (input_cost + cached_cost).round(8),
      output_cost: output_cost.round(8),
      total_cost: (input_cost + cached_cost + output_cost).round(8)
    }
  end

  def self.zero_cost
    { input_cost: 0, output_cost: 0, total_cost: 0 }
  end
end
```

### Dual Cost Tracking

DailyWerk tracks costs via two mechanisms:

1. **Token-based tracking** — For LLM calls: input/output/cached tokens × per-model pricing from the provider registry. Recorded in `usage_records` with `request_type: "chat"`.

2. **API/usage-based tracking** — For non-token services: web search (per-query, e.g., Brave at $0.005/query), embedding calls (per-call), MCP tool invocations, bridge operations. Recorded in `usage_records` with appropriate `request_type` values (`"search"`, `"embedding"`, `"mcp"`, `"bridge"`).

Both feed into the unified credit system. The `usage_records.request_type` field discriminates between tracking types. The provider registry defines pricing for both token-based and per-call services.

### Usage Recorder

Hooked into the [AgentRuntime](./03-agentic-system.md#3-agent-runtime-react-loop) post-processing step:

```ruby
# app/services/usage_recorder.rb
class UsageRecorder
  def self.record(message:, session:, user:)
    return unless message.input_tokens.to_i > 0 || message.output_tokens.to_i > 0

    model_id = session.model_id || session.agent.model_id
    provider = session.provider || session.agent.provider || "auto"

    costs = CostCalculator.calculate(
      model_id: model_id,
      input_tokens: message.input_tokens.to_i,
      output_tokens: message.output_tokens.to_i,
      cached_tokens: message.cached_tokens.to_i
    )

    UsageRecord.create!(
      user: user,
      session: session,
      message: message,
      agent_slug: message.agent_slug,
      model_id: model_id,
      provider: provider,
      input_tokens: message.input_tokens.to_i,
      output_tokens: message.output_tokens.to_i,
      cached_tokens: message.cached_tokens.to_i,
      thinking_tokens: message.thinking_tokens.to_i,
      duration_ms: message.metadata&.dig("duration_ms"),
      **costs
    )
  end
end
```

### Daily Aggregation

```ruby
# app/jobs/aggregate_usage_job.rb
class AggregateUsageJob < ApplicationJob
  queue_as :maintenance

  def perform(date = Date.yesterday)
    UsageRecord.where(created_at: date.all_day)
               .group(:user_id, :model_id, :provider)
               .select(
                 :user_id, :model_id, :provider,
                 "COUNT(*) as request_count",
                 "SUM(input_tokens) as total_input_tokens",
                 "SUM(output_tokens) as total_output_tokens",
                 "SUM(total_cost) as total_cost"
               ).each do |row|
      UsageDailySummary.upsert(
        {
          user_id: row.user_id,
          date: date, model_id: row.model_id, provider: row.provider,
          request_count: row.request_count,
          total_input_tokens: row.total_input_tokens,
          total_output_tokens: row.total_output_tokens,
          total_cost: row.total_cost
        },
        unique_by: :idx_usage_daily_unique
      )
    end
  end
end
```

---

## 5. Budget Enforcement

```ruby
# app/services/budget_enforcer.rb
class BudgetEnforcer
  class BudgetExceededError < StandardError; end

  def self.check_and_reserve!(user:, estimated_credits:)
    # Atomic reserve — prevents TOCTOU race
    rows = CreditBalance.where(user: user)
      .where("balance >= ?", estimated_credits)
      .update_all("balance = balance - #{estimated_credits.to_i}")

    raise BudgetExceededError,
      "Credit balance exhausted. Add credits or enable overage billing." if rows == 0
  end
end
```

The old `check!` method (read-only balance check) is replaced by `check_and_reserve!` which atomically reserves credits before the LLM call. Called at the start of every [AgentRuntime.run](./03-agentic-system.md#3-agent-runtime-react-loop) invocation, before any LLM calls.

---

## 6. BYOK — Bring Your Own Key

ruby_llm v1.3+ provides `RubyLLM.context` — an isolated configuration scope that inherits from the global config but overrides specific keys. This is the mechanism for per-user API key isolation.

For the `api_credentials` schema, see [01 §5.9](./01-platform-and-infrastructure.md#59-integration-tables).

### Model with Encryption

```ruby
# app/models/api_credential.rb
class ApiCredential < ApplicationRecord
  belongs_to :user

  encrypts :api_key_enc, deterministic: false  # Rails 8 encryption

  validates :provider, presence: true,
    inclusion: { in: %w[openai anthropic openrouter] }
  validates :provider, uniqueness: { scope: :user_id }

  scope :active, -> { where(active: true) }

  def self.resolve(user:, provider:)
    find_by(user: user, provider: provider, active: true)
  end

  def api_key
    api_key_enc  # Decrypted automatically by Rails
  end
end
```

### Context Builder

```ruby
# app/services/llm_context_builder.rb
class LlmContextBuilder
  PROVIDER_KEY_MAP = {
    "openai"     => :openai_api_key,
    "anthropic"  => :anthropic_api_key,
    "openrouter" => :openrouter_api_key
  }.freeze

  PROVIDER_BASE_MAP = {
    "openai"     => :openai_api_base,
    "anthropic"  => :anthropic_api_base,
    "openrouter" => :openrouter_api_base
  }.freeze

  def self.build(user:)
    RubyLLM.context do |config|
      %w[openai anthropic openrouter].each do |provider|
        cred = ApiCredential.resolve(user: user, provider: provider)
        next unless cred

        config.send(:"#{PROVIDER_KEY_MAP[provider]}=", cred.api_key)
        config.send(:"#{PROVIDER_BASE_MAP[provider]}=", cred.api_base) if cred.api_base.present?
      end
    end
  end
end
```

`RubyLLM.context` creates an isolated config copy. The global config remains untouched. Each fiber/thread gets its own context — safe under Falcon's concurrency model. **Note**: `RubyLLM.context` uses shallow dup internally — avoid mutating nested config objects inside context blocks; only assign new values to top-level attributes.

### Key Validation Endpoint

```ruby
# app/controllers/api/v1/api_credentials_controller.rb
class Api::V1::ApiCredentialsController < ApplicationController
  ALLOWED_API_BASES = %w[
    https://api.openai.com
    https://api.anthropic.com
    https://openrouter.ai/api
  ].freeze

  def create
    cred = current_user.api_credentials.build(credential_params)

    # SSRF protection: validate api_base against allowlist
    if cred.api_base.present?
      unless ALLOWED_API_BASES.any? { |base| cred.api_base.start_with?(base) }
        return render json: { error: "Custom API base not allowed. Contact admin." },
                      status: :unprocessable_entity
      end
    end

    # Validate the key actually works
    ctx = RubyLLM.context do |c|
      c.send(:"#{LlmContextBuilder::PROVIDER_KEY_MAP[cred.provider]}=", cred.api_key)
    end

    begin
      ctx.chat(model: test_model_for(cred.provider)).ask("ping")
      cred.save!
      render json: { status: "valid", id: cred.id }
    rescue RubyLLM::UnauthorizedError
      render json: { error: "Invalid API key" }, status: :unprocessable_entity
    end
  end

  private

  def test_model_for(provider)
    { "openai" => "gpt-4o-mini",
      "anthropic" => "claude-haiku-4-5",
      "openrouter" => "openai/gpt-4o-mini" }[provider]
  end
end
```

Custom `api_base` URLs (Azure, self-hosted) require admin approval — not user-settable via this endpoint. This prevents SSRF attacks where an attacker probes internal infrastructure via the key validation HTTP call.

---

## 7. MCP Support — User Configurable

`ruby_llm-mcp` provides MCP client integration with RubyLLM. It supports `stdio`, `streamable` (HTTP), and `sse` transports, plus OAuth 2.1.

For the `mcp_server_configs` schema, see [01 §5.9](./01-platform-and-infrastructure.md#59-integration-tables).

**Note on gem maturity**: `ruby_llm-mcp` is at v0.0.2 as of March 2026. The API surface may differ from the examples below. Verify compatibility before implementation.

```ruby
# User-configurable MCP servers: only remote transports allowed
validates :transport_type, inclusion: { in: %w[streamable sse] },
  message: "stdio transport is admin-only (security: prevents arbitrary command execution)"
```

**Security**: MCP `stdio` transport executes arbitrary commands on the server. It is restricted to admin-configured system integrations only. User-configurable MCP servers must use `streamable` or `sse` (HTTP-based) transports.

### MCP Client Manager

```ruby
# app/services/mcp_client_manager.rb
class McpClientManager
  # Cache clients per-process to reuse connections (MCP servers are stateful)
  # WARNING: This cache is process-scoped. Under Falcon (multi-process),
  # config invalidation only clears the current process's cache.
  # Use Redis pub/sub for cross-process invalidation in production.
  CLIENTS = Concurrent::Map.new

  def self.clients_for(user:)
    configs = McpServerConfig.where(user: user, active: true)

    configs.map do |config|
      cache_key = "#{config.id}:#{config.updated_at.to_i}"
      CLIENTS.compute_if_absent(cache_key) { build_client(config) }
    end
  end

  def self.tools_for(user:, agent: nil)
    configs = McpServerConfig.where(user: user, active: true)

    # Per-agent MCP access control
    if agent&.enabled_mcps.present?
      configs = configs.where(id: agent.enabled_mcps.keys)
    elsif agent
      return []  # Agent has no enabled MCPs — no MCP access
    end

    configs.flat_map do |config|
      cache_key = "#{config.id}:#{config.updated_at.to_i}"
      client = CLIENTS.compute_if_absent(cache_key) { build_client(config) }
      tools = client.tools

      # Apply allow/block lists
      if config.allowed_tools.any?
        tools = tools.select { |t| t.name.in?(config.allowed_tools) }
      end
      tools = tools.reject { |t| t.name.in?(config.blocked_tools) }

      tools
    end
  end

  def self.build_client(config)
    client_opts = { name: config.name, transport_type: config.transport_type.to_sym }

    case config.transport_type
    when "streamable", "sse"
      client_opts[:config] = { url: config.url }
      if config.oauth_token_enc.present?
        client_opts[:config][:headers] = {
          "Authorization" => "Bearer #{config.oauth_token}"
        }
      end
    when "stdio"
      client_opts[:config] = config.stdio_config.symbolize_keys
    end

    client = RubyLLM::MCP.client(**client_opts)
    client.instance_variable_set(:@_config, config)
    client
  end

  def self.invalidate(config_id)
    CLIENTS.each_pair do |key, _|
      CLIENTS.delete(key) if key.start_with?("#{config_id}:")
    end
  end
end
```

### Per-User OAuth Flow

```ruby
# app/controllers/mcp/oauth_controller.rb
class Mcp::OauthController < ApplicationController
  def initiate
    config = current_user.mcp_server_configs.find(params[:id])
    client = McpClientManager.build_client(config)
    state = SecureRandom.urlsafe_base64(32)
    session[:mcp_oauth_state] = state

    redirect_url = client.oauth(type: :web).authorization_url(
      redirect_uri: mcp_oauth_callback_url(config_id: config.id),
      state: state
    )
    redirect_to redirect_url, allow_other_host: true
  end

  def callback
    unless params[:state] == session.delete(:mcp_oauth_state)
      return redirect_to settings_integrations_path, alert: "OAuth CSRF detected"
    end

    config = current_user.mcp_server_configs.find(params[:config_id])
    client = McpClientManager.build_client(config)

    token = client.oauth(type: :web).exchange_code(
      code: params[:code],
      redirect_uri: mcp_oauth_callback_url(config_id: config.id)
    )

    config.update!(oauth_token_enc: token)
    McpClientManager.invalidate(config.id)

    redirect_to settings_integrations_path, notice: "Connected!"
  end
end
```

MCP tools returned by `ruby_llm-mcp` are `RubyLLM::Tool`-compatible — they plug directly into the [AgentRuntime](./03-agentic-system.md#3-agent-runtime-react-loop) tool resolution.

**Note for future RFC**: MCP security needs deeper treatment — sandboxing, transport security, tool-level authorization, and abuse prevention require a dedicated security-focused RFC.

---

## 8. GoodJob Configuration

**Canonical home for all background job configuration.** GoodJob runs in **external mode** (separate worker process) for production. See [01 §2](./01-platform-and-infrastructure.md#2-stack-decisions) for rationale.

```ruby
# Gemfile
gem "good_job", "~> 4.0"

# config/application.rb
config.active_job.queue_adapter = :good_job
```

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :external     # Separate worker process (NOT async with Falcon)
  config.good_job.max_threads = 10
  config.good_job.poll_interval = 5
  config.good_job.shutdown_timeout = 30

  config.good_job.queues = "llm:3;embeddings:2;maintenance:1;default:4"

  config.good_job.enable_cron = true
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 */6 * * *",            # Every 6 hours
      class: "ArchiveStaleSessionsJob",
      description: "Archive cold sessions (>7d inactive)"
    },
    synthesize_user_profiles: {
      cron: "0 3 * * *",              # Daily at 3am
      class: "SynthesizeUserProfilesJob",
      description: "Regenerate Layer 5 user knowledge synthesis"
    },
    consolidate_daily_logs: {
      cron: "0 4 * * *",              # Daily at 4am
      class: "ConsolidateDailyLogsJob",
      description: "Summarize yesterday's daily logs → promote to Tier 1 memory"
    },
    weekly_memory_consolidation: {
      cron: "0 2 * * 1",              # Weekly Monday 2am
      class: "ConsolidateMemoriesJob",
      description: "Review Tier 1 entries — deduplicate, prune stale facts"
    },
    prune_archived_messages: {
      cron: "30 2 * * 1",             # Weekly Monday 2:30am — staggered from weekly_memory_consolidation (2:00am) to avoid resource contention
      class: "PruneArchivedMessagesJob",
      description: "Delete messages from archived sessions >30d old"
    },
    aggregate_daily_usage: {
      cron: "15 0 * * *",             # Daily at 00:15
      class: "AggregateUsageJob",
      description: "Roll up usage records into daily summaries"
    },
    refresh_embeddings: {
      cron: "*/15 * * * *",           # Every 15 minutes
      class: "RefreshEmbeddingsJob",
      description: "Generate embeddings for records missing them"
    },
    renew_gmail_watch: {
      cron: "0 0 */6 * *",            # Every 6 days
      class: "RenewGmailWatchJob",
      description: "Renew Gmail push notification subscriptions"
    },
    todo_sync: {
      cron: "*/2 * * * *",            # Every 2 minutes
      class: "TodoSyncWorker",
      description: "Sync tasks with external providers (Todoist, Vikunja)"
    },
    bridge_health_check: {
      cron: "* * * * *",              # Every minute
      class: "BridgeHealthCheckJob",
      description: "Check health of managed Signal bridges"
    },
    credit_reconciliation: {
      cron: "0 */4 * * *",            # Every 4 hours
      class: "CreditReconcilerJob",
      description: "Reconcile pre-deducted credits with actual usage"
    }
  }

  config.good_job.enable_listen_notify = true  # Low-latency via LISTEN/NOTIFY
end
```

### Background LLM Policy

System operations (compaction, memory extraction, summarization) always use **DailyWerk platform API keys**, not user BYOK keys. Rationale:
- BYOK keys are for user-facing agent interactions only
- System ops run asynchronously and must not depend on user-provided credentials being valid
- System-op costs are platform overhead, attributed to operational cost, not user credits

### Concurrency Controls

```ruby
# Example: GenerateEmbeddingJob with GoodJob concurrency
class GenerateEmbeddingJob < ApplicationJob
  queue_as :embeddings

  include GoodJob::ActiveJobExtensions::Concurrency

  good_job_control_concurrency_with(
    total_limit: 10,
    key: -> { "embedding_generation" }
  )

  EMBEDDABLE_MODELS = %w[MemoryEntry Note VaultChunk ConversationArchive].freeze

  def perform(model_name, record_id, user_id:)
    unless model_name.in?(EMBEDDABLE_MODELS)
      Rails.logger.warn "[EmbeddingJob] Rejected non-allowlisted model: #{model_name}"
      return
    end

    record = model_name.constantize.find(record_id)
    content = extract_content(record)
    embedding = RubyLLM.embed(content.truncate(8000)).vectors
    record.update_column(:embedding, embedding)
  rescue ActiveRecord::RecordNotFound
    # Record deleted before job ran — safe to ignore
  end

  private

  def extract_content(record)
    case record
    when MemoryEntry then record.content
    when Note then "#{record.title}\n#{record.content}"
    when VaultChunk then record.content
    when ConversationArchive then record.summary
    end
  end
end
```

### GoodJob Dashboard

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :admin_user do
    mount GoodJob::Engine => "/good_job"
  end
end
```

---

## 9. Gemfile (Relevant Gems)

```ruby
# Gemfile
gem "rails", "~> 8.0"
gem "pg", "~> 1.5"
gem "redis", "~> 5.0"
gem "falcon", "~> 0.48"

# LLM
gem "ruby_llm", "~> 1.14"
gem "ruby_llm-mcp", "~> 1.0"          # v0.0.2 was pre-alpha; pin to stable release
gem "ruby_llm-responses_api", "~> 0.5"

# Background jobs
gem "good_job", "~> 4.0"

# Vector search
gem "neighbor", "~> 0.5"              # pgvector ActiveRecord integration

# Auth
gem "workos", "~> 5.0"

# Payments
gem "stripe", "~> 12.0"

# Telegram
gem "telegram-bot-ruby", "~> 2.0"

# Migration safety
gem "strong_migrations", "~> 2.0"

# Encryption: Rails 8 built-in ActiveRecord encryption — no extra gem needed
```

---

## 10. Open Questions

1. **Rate limiting** — Per-user request rate (requests/minute) in Redis. Per-provider rate limiting to respect API quotas. `BudgetEnforcer` handles cost caps but not request rate.
2. **Error handling / retry strategy** — LLM call failures, provider timeout, rate limit responses. GoodJob supports `retry_on` with backoff. Implement provider failover in LLM router. Handle partial streaming failures (if streaming fails at 80%, partial content may be lost).
3. **MCP client cross-process invalidation** — `Concurrent::Map` cache is process-scoped. Need Redis pub/sub for cross-process invalidation under Falcon multi-process.
4. **ReAct loop JSON failures** — When LLM outputs invalid tool JSON, need retry mechanism (feed parse error back to LLM, cap retries at 3).
5. **Dual cost tracking schema** — Decide whether to extend `usage_records` with `request_type` discrimination or create a separate `api_usage_records` table for non-token costs.
6. **Credit reservation Redis vs Postgres** — Evaluate whether Redis DECRBY is needed for concurrency, or if Postgres atomic UPDATE is sufficient for MVP scale.
