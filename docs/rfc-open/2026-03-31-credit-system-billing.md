---
type: rfc
title: Credit System & Billing
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/04-billing-and-operations
depends_on:
  - rfc/2026-03-31-usage-tracking-provider-cost
implemented_by: []
phase: 2
---

# RFC: Credit System & Billing

## Context

[RFC: Usage Tracking & Provider Cost Attribution](./2026-03-31-usage-tracking-provider-cost.md) provides the usage data pipeline: every billable action produces a `Tracking::UsageEvent` with real USD provider cost, persisted to `usage_records`. This RFC builds the credit and billing layer on top.

[PRD 04 §3-5](../prd/04-billing-and-operations.md#3-credit-model) outlines the credit model, budget enforcement, and Stripe integration. This RFC refines the approach with one key correction:

**Absolute credit pricing, not multipliers.** PRD 04 uses `internal_credit_rate: 1.33` (a multiplier applied to provider cost). This RFC replaces that with absolute credit amounts per model per token type. Benefits:
- Each model can have an independent margin (33% on premium, 50% on economy)
- No mental math — the YAML comment shows the margin percentage
- Two separate config files (provider pricing vs credit pricing) change for different reasons

This RFC answers: **"How many credits does usage consume?"** and **"What's our margin?"**

### What This RFC Covers

- Credit pricing configuration (absolute values, separate YAML file)
- `CreditPricer` service (usage event → integer credits)
- `credit_balances` and `credit_transactions` database tables
- `BudgetEnforcer` service (pre-flight credit check with BYOK bypass)
- `CreditReconcilerJob` (reconcile reserved vs actual credits)
- Stripe webhook handler (minimal MVP: `invoice.paid` → credit grant)
- `processed_stripe_events` idempotency table
- BYOK credit exemption flow (3 clean switch points)
- Margin tracking data model
- Frontend: credit balance display, transaction history

### What This RFC Does NOT Cover

- Advanced analytics dashboards, admin reporting
- Rate limiting ([PRD 04 §10.1](../prd/04-billing-and-operations.md#10-open-questions))
- Stripe Billing Portal integration (upgrade/downgrade flows)
- Overage billing (metered Stripe Usage Records)
- Multi-workspace billing (single workspace per user for MVP)

---

## 1. Credit Pricing Model

### 1.1 Core Concept

1 credit = $0.001 (unchanged from PRD 04).

Credits are the user-facing unit. Provider costs (USD) are the platform's internal cost. The difference is margin.

### 1.2 Absolute Credit Pricing

Credit amounts are defined as absolute integers — not derived from provider cost × multiplier. This decouples margin decisions from provider pricing changes.

```yaml
# config/credit_pricing.yml
#
# What we charge users (in credits) per model per token type.
# 1 credit = $0.001. Comments show provider cost and margin for transparency.
#
# Updated when we adjust margins. Provider cost changes go in provider_pricing.yml.

models:
  # --- Anthropic ---
  claude-opus-4-6:
    credits_per_1m_input: 19950         # Provider: $15.00 → $19.95. Margin: 33%
    credits_per_1m_output: 99750        # Provider: $75.00 → $99.75. Margin: 33%
    credits_per_1m_cached_input: 9975   # Provider: $7.50  → $9.975. Margin: 33%
    credits_per_1m_thinking: 99750      # Provider: $75.00 → $99.75. Margin: 33%
    credits_per_1m_cache_creation: 24938 # Provider: $18.75 → $24.94. Margin: 33%

  claude-sonnet-4-6:
    credits_per_1m_input: 3990          # Provider: $3.00 → $3.99. Margin: 33%
    credits_per_1m_output: 19950        # Provider: $15.00 → $19.95. Margin: 33%
    credits_per_1m_cached_input: 1995   # Provider: $1.50 → $1.995. Margin: 33%
    credits_per_1m_thinking: 19950      # Provider: $15.00 → $19.95. Margin: 33%
    credits_per_1m_cache_creation: 4988 # Provider: $3.75 → $4.99. Margin: 33%

  claude-haiku-4-5:
    credits_per_1m_input: 1200          # Provider: $0.80 → $1.20. Margin: 50%
    credits_per_1m_output: 6000         # Provider: $4.00 → $6.00. Margin: 50%
    credits_per_1m_cached_input: 600    # Provider: $0.40 → $0.60. Margin: 50%
    credits_per_1m_thinking: 6000       # Provider: $4.00 → $6.00. Margin: 50%
    credits_per_1m_cache_creation: 1500 # Provider: $1.00 → $1.50. Margin: 50%

  # --- OpenAI ---
  gpt-5.4:
    credits_per_1m_input: 3330          # Provider: $2.50 → $3.33. Margin: 33%
    credits_per_1m_output: 13300        # Provider: $10.00 → $13.30. Margin: 33%
    credits_per_1m_cached_input: 1665   # Provider: $1.25 → $1.665. Margin: 33%

  gpt-5.4-pro:
    credits_per_1m_input: 13300         # Provider: $10.00 → $13.30. Margin: 33%
    credits_per_1m_output: 53200        # Provider: $40.00 → $53.20. Margin: 33%
    credits_per_1m_cached_input: 6650   # Provider: $5.00 → $6.65. Margin: 33%
    credits_per_1m_thinking: 53200      # Provider: $40.00 → $53.20. Margin: 33%

  gpt-5.3:
    credits_per_1m_input: 600           # Provider: $0.40 → $0.60. Margin: 50%
    credits_per_1m_output: 2400         # Provider: $1.60 → $2.40. Margin: 50%
    credits_per_1m_cached_input: 300    # Provider: $0.20 → $0.30. Margin: 50%

  # --- Embeddings ---
  text-embedding-3-small:
    credits_per_1m_input: 30            # Provider: $0.02 → $0.03. Margin: 50%

# --- Non-LLM Services ---
services:
  brave-search:
    credits_per_query: 7                # Provider: $0.005 → $0.007. Margin: 40%
```

### 1.3 Why Two Config Files?

| File | Changes when... | Contains |
|------|-----------------|----------|
| `config/provider_pricing.yml` | Provider updates pricing | USD costs we pay |
| `config/credit_pricing.yml` | We adjust margins | Credits users pay |

A junior dev updating Anthropic's new pricing touches only `provider_pricing.yml`. A business decision to increase economy-tier margins touches only `credit_pricing.yml`.

---

## 2. CreditPricer Service

Converts a `Tracking::UsageEvent` (from RFC: Usage Tracking) into integer credits. Returns 0 for BYOK events.

```ruby
# app/services/credit_pricer.rb

# Converts a UsageEvent into integer credit cost.
#
# Separate from CostCalculator (which returns USD provider cost).
# CostCalculator answers "what did this cost us?"
# CreditPricer answers "what does the user pay?"
class CreditPricer
  CREDITS_PER_UNIT = BigDecimal("1_000_000")

  # Credit pricing loaded once from config/credit_pricing.yml.
  CONFIG = YAML.load_file(
    Rails.root.join("config/credit_pricing.yml"),
    symbolize_names: false
  ).freeze

  MODEL_PRICING = (CONFIG["models"] || {}).freeze
  SERVICE_PRICING = (CONFIG["services"] || {}).freeze

  # @param event [Tracking::UsageEvent]
  # @return [Integer] credits charged (0 for BYOK events)
  def self.price(event)
    return 0 if event.byok

    case event.request_type
    when "chat", "background"
      price_token_based(event)
    when "search"
      price_search(event)
    when "embedding"
      price_token_based(event)
    when "mcp"
      # MCP tool invocations: deferred pricing. Track as 0 credits for now.
      0
    else
      0
    end
  end

  # Estimates credits for a planned LLM call (for pre-flight reservation).
  # Uses model's typical input/output ratio as a heuristic.
  #
  # @param model_id [String]
  # @param estimated_input_tokens [Integer]
  # @return [Integer] estimated credits
  def self.estimate(model_id:, estimated_input_tokens:)
    pricing = MODEL_PRICING[model_id]
    return 0 unless pricing

    # Estimate: assume output ≈ input, no caching, no thinking
    input_credits = (bd(estimated_input_tokens) * bd(pricing["credits_per_1m_input"] || 0) / CREDITS_PER_UNIT)
    output_credits = (bd(estimated_input_tokens) * bd(pricing["credits_per_1m_output"] || 0) / CREDITS_PER_UNIT)

    (input_credits + output_credits).ceil.to_i
  end

  class << self
    private

    # @param event [Tracking::UsageEvent]
    # @return [Integer]
    def price_token_based(event)
      pricing = MODEL_PRICING[event.model_id]
      return 0 unless pricing

      input_credits = bd(event.input_tokens - event.cached_tokens) *
                      bd(pricing["credits_per_1m_input"] || 0) / CREDITS_PER_UNIT
      cached_credits = bd(event.cached_tokens) *
                       bd(pricing["credits_per_1m_cached_input"] || 0) / CREDITS_PER_UNIT
      output_credits = bd(event.output_tokens) *
                       bd(pricing["credits_per_1m_output"] || 0) / CREDITS_PER_UNIT
      thinking_credits = bd(event.thinking_tokens) *
                         bd(pricing["credits_per_1m_thinking"] || 0) / CREDITS_PER_UNIT
      cache_creation_credits = bd(event.cache_creation_tokens) *
                               bd(pricing["credits_per_1m_cache_creation"] || 0) / CREDITS_PER_UNIT

      total = input_credits + cached_credits + output_credits + thinking_credits + cache_creation_credits
      total.ceil.to_i
    end

    # @param event [Tracking::UsageEvent]
    # @return [Integer]
    def price_search(event)
      service_key = "#{event.provider}-search"
      pricing = SERVICE_PRICING[service_key]
      return 0 unless pricing

      query_count = event.metadata&.dig("query_count") || 1
      (pricing["credits_per_query"] * query_count).ceil.to_i
    end

    # @param value [Numeric]
    # @return [BigDecimal]
    def bd(value)
      BigDecimal(value.to_s)
    end
  end
end
```

---

## 3. Database Migrations

### 3.1 Credit Balances

Based on [PRD 01 §5.8](../prd/01-platform-and-infrastructure.md#58-credit--usage-tables). One row per workspace. Balance in integer credits (1 credit = $0.001).

```ruby
# db/migrate/XXXXXXXX_create_credit_balances.rb
class CreateCreditBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :credit_balances, id: false do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, primary_key: true
      t.bigint   :balance,    null: false, default: 0
      t.bigint   :reserved,   null: false, default: 0  # Credits reserved but not yet reconciled
      t.timestamps
    end
  end
end
```

### 3.2 Credit Transactions

Audit trail for all credit movements. Every balance change has a corresponding transaction.

```ruby
# db/migrate/XXXXXXXX_create_credit_transactions.rb
class CreateCreditTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :credit_transactions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :usage_record, type: :uuid, foreign_key: true  # Links to the triggering usage
      t.string   :transaction_type, null: false  # grant, purchase, usage, refund, adjustment, expiry
      t.bigint   :amount,           null: false  # Positive = credit, negative = debit
      t.bigint   :balance_after,    null: false  # Running balance for audit trail
      t.decimal  :provider_cost_usd, precision: 12, scale: 8  # What we paid the provider
      t.decimal  :margin_usd,        precision: 12, scale: 8  # credits_as_usd - provider_cost
      t.string   :description                                  # Human-readable note
      t.jsonb    :metadata,          default: {}
      t.timestamps

      t.index [:workspace_id, :created_at]
      t.index [:workspace_id, :transaction_type, :created_at], name: "idx_credit_tx_workspace_type"
    end
  end
end
```

### 3.3 Processed Stripe Events

Idempotency table for Stripe webhooks.

```ruby
# db/migrate/XXXXXXXX_create_processed_stripe_events.rb
class CreateProcessedStripeEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :processed_stripe_events, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type,      null: false
      t.timestamps

      t.index :stripe_event_id, unique: true
    end
  end
end
```

### 3.4 Models

```ruby
# app/models/credit_balance.rb

# Workspace credit balance. One row per workspace.
# Balance is in integer credits (1 credit = $0.001).
class CreditBalance < ApplicationRecord
  self.primary_key = :workspace_id

  belongs_to :workspace

  # Atomically reserves credits. Returns true if reservation succeeded.
  #
  # @param amount [Integer] credits to reserve
  # @return [Boolean]
  def self.reserve!(workspace_id:, amount:)
    rows = where(workspace_id: workspace_id)
      .where("balance - reserved >= ?", amount)
      .update_all(["reserved = reserved + ?", amount])
    rows > 0
  end

  # Returns credits after accounting for reservations.
  #
  # @return [Integer]
  def available_balance
    balance - reserved
  end
end
```

```ruby
# app/models/credit_transaction.rb

# Audit trail for credit movements. Every balance change has a transaction.
class CreditTransaction < ApplicationRecord
  include WorkspaceScoped

  TRANSACTION_TYPES = %w[grant purchase usage refund adjustment expiry].freeze

  belongs_to :usage_record, optional: true

  validates :transaction_type, presence: true, inclusion: { in: TRANSACTION_TYPES }
  validates :amount, presence: true
  validates :balance_after, presence: true

  scope :debits, -> { where("amount < 0") }
  scope :credits_added, -> { where("amount > 0") }
  scope :for_period, ->(range) { where(created_at: range) }
end
```

```ruby
# app/models/processed_stripe_event.rb

# Idempotency tracking for Stripe webhooks.
class ProcessedStripeEvent < ApplicationRecord
  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true

  # @param event_id [String]
  # @return [Boolean] true if this event was already processed
  def self.processed?(event_id)
    exists?(stripe_event_id: event_id)
  end
end
```

---

## 4. BudgetEnforcer

Pre-flight credit check before LLM calls. The single BYOK switch point for budget enforcement.

```ruby
# app/services/budget_enforcer.rb

# Checks workspace credit balance before executing billable actions.
# Atomically reserves estimated credits to prevent TOCTOU races.
class BudgetEnforcer
  class BudgetExceededError < StandardError; end

  # Checks balance and reserves credits. Raises if insufficient.
  # Skips enforcement entirely for BYOK workspaces (for the given provider).
  #
  # @param workspace [Workspace]
  # @param provider [String] the LLM provider being called
  # @param estimated_credits [Integer] estimated credit cost
  # @raise [BudgetExceededError] if balance is insufficient
  # @return [void]
  def self.check_and_reserve!(workspace:, provider:, estimated_credits:)
    # BYOK switch point: if workspace has its own key for this provider, skip.
    return if workspace_uses_byok?(workspace, provider)

    success = CreditBalance.reserve!(
      workspace_id: workspace.id,
      amount: estimated_credits
    )

    unless success
      raise BudgetExceededError,
        "Credit balance exhausted. Add credits or configure your own API key (BYOK)."
    end
  end

  # @param workspace [Workspace]
  # @param provider [String]
  # @return [Boolean]
  def self.workspace_uses_byok?(workspace, provider)
    return false unless defined?(ApiCredential)

    ApiCredential.where(workspace: workspace, provider: provider, active: true).exists?
  end
end
```

### 4.1 ChatStreamJob Integration

Budget check happens **before** the LLM call, in `ChatStreamJob#perform`:

```ruby
# app/jobs/chat_stream_job.rb (updated perform — additions marked)
def perform(session_id, user_message, workspace_id:)
  session = Session.find(session_id)
  workspace = Workspace.find(workspace_id)
  assistant_message = nil

  # Pre-flight budget check                                       ← NEW
  model_id = session.agent.model_id
  provider = (session.agent.resolved_provider || SimpleChatService::DEFAULT_PROVIDER).to_s
  estimated = CreditPricer.estimate(
    model_id: model_id,
    estimated_input_tokens: estimate_input_tokens(session, user_message)
  )
  BudgetEnforcer.check_and_reserve!(
    workspace: workspace,
    provider: provider,
    estimated_credits: estimated
  )

  SimpleChatService.new(session:).call(user_message) do |chunk|
    # ... streaming unchanged ...
  end

  # ... completion broadcast, metadata update, usage recording unchanged ...
rescue BudgetEnforcer::BudgetExceededError => e                   # ← NEW
  ActionCable.server.broadcast(
    "session_#{session_id}",
    { type: "error", message: e.message }
  )
rescue StandardError => e
  # ... existing error handling ...
end
```

### 4.2 Input Token Estimation

```ruby
# app/jobs/chat_stream_job.rb (new private method)

# Rough estimate of input tokens for budget reservation.
# Uses char/4 heuristic. Overestimates are fine — reconciliation adjusts.
#
# @param session [Session]
# @param user_message [String]
# @return [Integer]
def estimate_input_tokens(session, user_message)
  # System prompt + conversation history + new message
  instructions_tokens = (session.agent.resolved_instructions&.length || 0) / 4
  history_tokens = session.total_tokens.to_i  # Rough proxy
  message_tokens = user_message.length / 4
  instructions_tokens + history_tokens + message_tokens
end
```

---

## 5. Credit Reconciliation

### 5.1 Post-Call Credit Debit

After usage is recorded (in `ChatStreamJob#record_usage` from RFC: Usage Tracking), create the credit transaction:

```ruby
# app/services/credit_debiter.rb

# Creates a credit transaction for actual usage and adjusts the balance.
# Called after UsageRecorder persists the usage record.
class CreditDebiter
  # @param usage_record [UsageRecord]
  # @param event [Tracking::UsageEvent]
  # @return [CreditTransaction, nil]
  def self.debit(usage_record:, event:)
    return nil if event.byok

    actual_credits = CreditPricer.price(event)
    return nil if actual_credits == 0

    provider_cost = event.provider_cost_usd.to_f
    credit_value_usd = actual_credits * 0.001  # 1 credit = $0.001
    margin = credit_value_usd - provider_cost

    balance = CreditBalance.find_by(workspace_id: event.workspace_id)
    return nil unless balance

    # Debit actual credits, release any over-reservation
    new_balance = balance.balance - actual_credits
    balance.update!(
      balance: new_balance,
      reserved: [balance.reserved - actual_credits, 0].max  # Release reservation
    )

    CreditTransaction.create!(
      workspace_id: event.workspace_id,
      usage_record: usage_record,
      transaction_type: "usage",
      amount: -actual_credits,
      balance_after: new_balance,
      provider_cost_usd: provider_cost,
      margin_usd: margin,
      description: "#{event.model_id} #{event.request_type}",
      metadata: {
        model_id: event.model_id,
        provider: event.provider,
        input_tokens: event.input_tokens,
        output_tokens: event.output_tokens
      }
    )
  rescue StandardError => e
    Rails.logger.error("[CreditDebiter] Failed: #{e.message} (workspace=#{event.workspace_id})")
    nil
  end
end
```

### 5.2 CreditReconcilerJob

Runs every 4 hours (already registered in [PRD 04 §8](../prd/04-billing-and-operations.md#8-goodjob-configuration)). Catches any reservations that weren't properly released (e.g., due to job failures).

```ruby
# app/jobs/credit_reconciler_job.rb

# Reconciles reserved credits with actual usage.
# Catches orphaned reservations from failed jobs.
class CreditReconcilerJob < ApplicationJob
  queue_as :maintenance

  # @return [void]
  def perform
    # Find workspaces with stale reservations (reserved > 0 but no recent usage)
    CreditBalance.where("reserved > 0").find_each do |balance|
      recent_usage = UsageRecord
        .where(workspace_id: balance.workspace_id, byok: false)
        .where("created_at > ?", 4.hours.ago)
        .exists?

      # If no recent usage but still have reservations, release them
      unless recent_usage
        released = balance.reserved
        balance.update!(reserved: 0)

        Rails.logger.info(
          "[CreditReconciler] Released #{released} orphaned credits " \
          "for workspace #{balance.workspace_id}"
        )
      end
    end
  end
end
```

---

## 6. Stripe Webhook Handler

Minimal MVP: handle `invoice.paid` to grant credits. Other event types added as needed.

```ruby
# app/controllers/webhooks/stripe_controller.rb

module Webhooks
  # Handles Stripe webhook events.
  class StripeController < ActionController::API
    # POST /webhooks/stripe
    def create
      payload = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

      begin
        event = Stripe::Webhook.construct_event(
          payload, sig_header, Rails.application.credentials.stripe[:webhook_secret]
        )
      rescue JSON::ParserError, Stripe::SignatureVerificationError
        head :bad_request
        return
      end

      # Idempotency check
      return head :ok if ProcessedStripeEvent.processed?(event.id)

      handle_event(event)

      ProcessedStripeEvent.create!(stripe_event_id: event.id, event_type: event.type)
      head :ok
    end

    private

    def handle_event(event)
      case event.type
      when "invoice.paid"
        handle_invoice_paid(event.data.object)
      else
        Rails.logger.info("[StripeWebhook] Unhandled event type: #{event.type}")
      end
    end

    # @param invoice [Stripe::Invoice]
    def handle_invoice_paid(invoice)
      workspace = Workspace.find_by(stripe_customer_id: invoice.customer)
      return unless workspace

      # Determine credits from the subscription plan metadata
      credits = invoice.lines.data.sum do |line|
        line.metadata["credits"]&.to_i || 0
      end
      return if credits == 0

      balance = CreditBalance.find_or_create_by!(workspace: workspace)
      new_balance = balance.balance + credits
      balance.update!(balance: new_balance)

      CreditTransaction.create!(
        workspace: workspace,
        transaction_type: "purchase",
        amount: credits,
        balance_after: new_balance,
        description: "Stripe invoice #{invoice.id}",
        metadata: { stripe_invoice_id: invoice.id }
      )
    end
  end
end
```

### 6.1 Routes

```ruby
# config/routes.rb
namespace :webhooks do
  post :stripe, to: "stripe#create"
end
```

---

## 7. BYOK Credit Exemption — Complete Flow

Three switch points across both RFCs. Everything else is BYOK-unaware.

```
User sends message
│
├─ BudgetEnforcer.check_and_reserve!
│  └─ workspace_uses_byok?(workspace, provider)
│     ├─ true  → SKIP reservation, proceed                   ← Switch point 1
│     └─ false → Reserve estimated credits atomically
│
├─ LLM call executes (SimpleChatService / ruby_llm)
│
├─ ChatStreamJob#record_usage
│  └─ Sets byok flag on UsageEvent                           ← Switch point 2
│     └─ Tracking::Adapters::Llm builds event
│        └─ CostCalculator returns REAL USD cost (always)
│     └─ UsageRecorder writes to usage_records
│
└─ CreditDebiter.debit
   └─ CreditPricer.price(event)
      ├─ event.byok == true → returns 0 credits              ← Switch point 3
      └─ event.byok == false → returns actual credits
         └─ Creates credit_transaction with margin
```

### 7.1 What BYOK Users See

- Usage stats dashboard works (shows token counts, provider cost)
- Credit balance is not consumed
- No "balance exhausted" errors
- Background LLM calls respect `background_key_source` preference

### 7.2 What Platform-Paid Users See

- Usage stats dashboard works (same data)
- Credit balance decreases with each call
- "Balance exhausted" error when credits run out
- Can add credits via Stripe or contact admin

---

## 8. Margin Tracking

### 8.1 Per-Transaction Margin

Every `credit_transaction` with `transaction_type: "usage"` records:
- `provider_cost_usd` — what we paid the provider (from `CostCalculator`)
- `amount` — credits charged (negative integer, from `CreditPricer`)
- `margin_usd` — `(|amount| × $0.001) - provider_cost_usd`

### 8.2 Example

Claude Sonnet call: 1000 input tokens, 500 output tokens.

```
Provider cost:  (1000 × $3.00/1M) + (500 × $15.00/1M) = $0.003 + $0.0075 = $0.0105
Credits:        (1000 × 3990/1M) + (500 × 19950/1M)   = 3.99 + 9.975    = 14 credits (ceil)
Credit value:   14 × $0.001 = $0.014
Margin:         $0.014 - $0.0105 = $0.0035 (33%)
```

### 8.3 Admin Queries

No admin dashboard in this RFC — just example queries for ad-hoc analysis:

```sql
-- Monthly margin by model
SELECT
  DATE_TRUNC('month', created_at) AS month,
  metadata->>'model_id' AS model,
  COUNT(*) AS transactions,
  SUM(ABS(amount)) AS total_credits,
  SUM(provider_cost_usd) AS total_provider_cost,
  SUM(margin_usd) AS total_margin,
  ROUND(SUM(margin_usd) / NULLIF(SUM(provider_cost_usd), 0) * 100, 1) AS margin_pct
FROM credit_transactions
WHERE transaction_type = 'usage'
GROUP BY 1, 2
ORDER BY 1 DESC, total_margin DESC;

-- Per-workspace profitability (last 30 days)
SELECT
  workspace_id,
  SUM(ABS(amount)) AS credits_consumed,
  SUM(provider_cost_usd) AS our_cost,
  SUM(margin_usd) AS our_margin
FROM credit_transactions
WHERE transaction_type = 'usage'
  AND created_at > NOW() - INTERVAL '30 days'
GROUP BY workspace_id
ORDER BY our_margin DESC;
```

---

## 9. Frontend

### 9.1 Credit Balance API

```ruby
# app/controllers/api/v1/credits_controller.rb

module Api
  module V1
    # Credit balance and transaction history for the current workspace.
    class CreditsController < ApplicationController
      # GET /api/v1/credits/balance
      def balance
        credit_balance = CreditBalance.find_by(workspace: Current.workspace)
        render json: {
          balance: credit_balance&.available_balance || 0,
          reserved: credit_balance&.reserved || 0,
          credits_as_usd: (credit_balance&.available_balance || 0) * 0.001
        }
      end

      # GET /api/v1/credits/transactions?page=1
      def transactions
        txns = CreditTransaction
          .where(workspace: Current.workspace)
          .order(created_at: :desc)
          .page(params[:page])
          .per(50)

        render json: {
          transactions: txns.map { |t| transaction_json(t) },
          total_pages: txns.total_pages,
          current_page: txns.current_page
        }
      end

      private

      def transaction_json(txn)
        {
          id: txn.id,
          type: txn.transaction_type,
          amount: txn.amount,
          balance_after: txn.balance_after,
          description: txn.description,
          provider_cost_usd: txn.provider_cost_usd&.to_f,
          margin_usd: txn.margin_usd&.to_f,
          created_at: txn.created_at
        }
      end
    end
  end
end
```

### 9.2 Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
namespace :credits do
  get :balance
  get :transactions
end
```

### 9.3 Frontend Types

```typescript
// frontend/src/types/credits.ts

export interface CreditBalance {
  balance: number
  reserved: number
  credits_as_usd: number
}

export interface CreditTransaction {
  id: string
  type: 'grant' | 'purchase' | 'usage' | 'refund' | 'adjustment' | 'expiry'
  amount: number
  balance_after: number
  description: string | null
  provider_cost_usd: number | null
  margin_usd: number | null
  created_at: string
}

export interface CreditTransactionsResponse {
  transactions: CreditTransaction[]
  total_pages: number
  current_page: number
}
```

### 9.4 Frontend Components

```
AppShell header
  └─ CreditBalanceBadge                          ← NEW
     ├─ Shows: "1,234 credits" (or "$1.23")
     ├─ Color: green (>1000), yellow (100-1000), red (<100)
     └─ Click → opens CreditsPanel in SettingsDrawer

SettingsDrawer
  ├─ AgentConfigPanel (existing)
  ├─ UsageStatsPanel (from RFC: Usage Tracking)
  └─ CreditsPanel (NEW)
     ├─ Current balance + reserved
     ├─ Transaction history (paginated table)
     │  └─ Columns: date, type, amount, balance, description
     └─ Low balance warning: "Your balance is running low. Add credits to continue."
```

---

## 10. Implementation Phases

### Phase 1: Database (independently testable)
1. Migration: `credit_balances` table
2. Migration: `credit_transactions` table
3. Migration: `processed_stripe_events` table
4. Models: `CreditBalance`, `CreditTransaction`, `ProcessedStripeEvent`

### Phase 2: Credit Pricing
1. `config/credit_pricing.yml` with current pricing
2. `CreditPricer` service
3. Tests: token-based pricing, search pricing, BYOK returns 0, estimation

### Phase 3: Budget Enforcement
1. `BudgetEnforcer` service
2. `ChatStreamJob` pre-flight check integration
3. `estimate_input_tokens` helper
4. Tests: sufficient balance, insufficient balance, BYOK bypass

### Phase 4: Credit Debiting
1. `CreditDebiter` service
2. Hook into `ChatStreamJob#record_usage` (after `UsageRecorder.record`)
3. Tests: debit creates transaction, margin calculated correctly

### Phase 5: Reconciliation
1. `CreditReconcilerJob`
2. Tests: orphaned reservations released, active reservations preserved

### Phase 6: Stripe
1. `Webhooks::StripeController`
2. Routes
3. Tests: signature verification, idempotency, credit grant

### Phase 7: Frontend
1. `CreditsController` with balance + transactions endpoints
2. Routes
3. Frontend types + API client
4. `CreditBalanceBadge` component
5. `CreditsPanel` in settings drawer

---

## 11. Security Considerations

- **Atomic balance operations**: `CreditBalance.reserve!` uses SQL `UPDATE ... WHERE balance - reserved >= amount` to prevent TOCTOU races. No read-then-write pattern.
- **Stripe webhook authentication**: Every webhook verifies `Stripe-Signature` header via `Stripe::Webhook.construct_event`. Without this, attackers could forge credit grants.
- **Idempotency**: `processed_stripe_events` with unique constraint prevents replay attacks and double-processing of the same webhook event.
- **No negative balance**: Budget enforcement prevents spending below zero. Reconciliation only releases reservations, never creates negative balances.
- **Credit transactions are append-only**: No UPDATE or DELETE on `credit_transactions`. Corrections use `adjustment` transaction type with explanation.
- **RLS**: `credit_transactions` uses workspace-scoped RLS. `credit_balances` uses `workspace_id` as primary key — naturally scoped.

---

## 12. Verification Checklist

1. `bin/rails db:migrate` succeeds — `credit_balances`, `credit_transactions`, `processed_stripe_events` created
2. `CreditPricer.price(event)` returns correct credits for Claude Sonnet (matching §8.2 example)
3. `CreditPricer.price(byok_event)` returns 0
4. `BudgetEnforcer.check_and_reserve!` succeeds with sufficient balance
5. `BudgetEnforcer.check_and_reserve!` raises `BudgetExceededError` with insufficient balance
6. `BudgetEnforcer.check_and_reserve!` skips for BYOK workspaces
7. Chat message → credit_transaction with correct amount, provider_cost_usd, margin_usd
8. `CreditReconcilerJob` releases orphaned reservations
9. Stripe webhook with valid signature grants credits
10. Stripe webhook with invalid signature returns 400
11. Duplicate Stripe webhook is idempotent (no double credit)
12. `GET /api/v1/credits/balance` returns correct available balance
13. `GET /api/v1/credits/transactions` returns paginated history
14. Credit balance badge displays in app header
15. `bundle exec rails test` passes
16. `bundle exec rubocop` passes
17. `bundle exec brakeman --quiet` shows no warnings
