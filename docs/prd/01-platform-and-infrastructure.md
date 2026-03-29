# DailyWerk — Platform & Infrastructure

> Canonical reference for stack decisions, tenant isolation, database schema, and deployment.
> For agent runtime and memory: see [03-agentic-system.md](./03-agentic-system.md).
> For integrations: see [02-integrations-and-channels.md](./02-integrations-and-channels.md).
> For billing and operations: see [04-billing-and-operations.md](./04-billing-and-operations.md).

---

## 1. What DailyWerk Is

A managed, opinionated personal AI assistant SaaS for non-technical users. Inspired by OpenClaw but removes all setup/ops burden. Users interact via messaging apps, email, in-app chat, and a web dashboard. Data stays portable (Obsidian vault via official Obsidian Sync, or DailyWerk-native markdown vault). All technologies use **latest stable versions**.

Core capabilities: diary, nutrition/sport tracking, research, calendar management, task management, reminders, daily/weekly/monthly summaries, todo integration, comms aggregation.

---

## 2. Stack Decisions

| Layer | Choice | Rationale |
|-------|--------|-----------|
| **Frontend** | Vite + React + TypeScript + Tailwind CSS + DaisyUI | SPA dashboard with in-app chat. DaisyUI for fast, accessible UI. |
| **Backend API** | Ruby on Rails (latest, API mode) + Falcon server | Fiber-per-request concurrency, native HTTP/2, WebSocket. Streaming LLM responses. |
| **Background Jobs** | ActiveJob + GoodJob | Postgres-backed. No Redis dependency for jobs. Built-in cron, concurrency, batches, dashboard. See [04 §8](./04-billing-and-operations.md#8-goodjob-configuration). |
| **DB** | PostgreSQL (latest) + pgvector | Primary store. RLS for user isolation. pgvector for semantic search. UUIDv7 PKs. |
| **Cache / Realtime** | Redis | Session cache, rate limiting, pub/sub, ActionCable (WebSocket for in-app chat). |
| **Search** | Hybrid: pgvector (semantic) + PostgreSQL FTS (keyword) | Postgres-native. See [02 §7](./02-integrations-and-channels.md#7-data-search--retrieval-layer). |
| **File Storage** | Hetzner Object Storage (S3-compatible) | EU residency. Per-user SSE-C encryption. |
| **Vault Sync** | Obsidian Headless (official CLI, Feb 2026) | Official headless client. Server-side bidirectional sync. Node.js 22+. |
| **Auth** | WorkOS | SSO, social login, magic links. |
| **Payments** | Stripe | Subscriptions, metered overage, add-ons. See [04 §1](./04-billing-and-operations.md#1-payments--stripe-integration). |
| **LLM Framework** | ruby_llm (v1.14+) + ruby_llm-mcp + ruby_llm-responses_api | Provider-agnostic agents, MCP support, OpenAI Responses API. See [03 §1](./03-agentic-system.md#1-rubyllm-framework-foundation). |

### Why Falcon over Puma

Fiber-based. Each request yields on I/O, enabling massive concurrency for streaming LLM responses and chained agent I/O. Rails integrates via `falcon-rails`, auto-sets `isolation_level = :fiber`. Risk: less ecosystem battle-testing. Puma maintained as fallback config.

### Why GoodJob over Sidekiq

Postgres-backed. Eliminates Redis as critical-path for jobs. Cron, concurrency controls, batches, web dashboard. GoodJob runs in **external mode** for production (separate worker process) — `async_server` mode uses threads internally and is untested with Falcon's fiber model. Redis stays for cache/pub/sub only.

### Why UUIDv7

Time-ordered, 128-bit, PostgreSQL native `uuid` type (16 bytes). ULIDs need `varchar(26)` = 60% more storage, slower joins. RFC 9562 (2024). Native `uuidv7()` in PostgreSQL 18.

---

## 3. System Architecture

```
┌──────────────┐    ┌────────────────────────────────────────────┐
│   Vite SPA   │───▶│           Rails API (Falcon server)        │
│  Tailwind +  │    │                                            │
│  DaisyUI     │    │  ├── Auth (WorkOS)                         │
│  In-App Chat │    │  ├── Payments (Stripe)                     │
│  (WebSocket) │    │  ├── Agent orchestration                   │
└──────────────┘    │  ├── Vault file API (S3 proxy)             │
                    │  ├── Credit ledger / billing               │
       ┌───────────▶│  ├── CalDAV endpoint (read-only export)    │
       │            │  └── Webhook receivers (Gmail, bridges)     │
       │            └───────────┬────────────────────────────────┘
       │                        │
       │            ┌───────────▼────────────────┐
       │            │   GoodJob Workers          │
       │            │   (external process)       │
       │            │                            │
       │            │  ├── AgentRunner           │
       │            │  ├── MessageIngress        │
       │            │  ├── EmailProcessor        │
       │            │  ├── ScheduledJobs (cron)  │
       │            │  ├── ResearchWorker        │
       │            │  ├── EmbeddingWorker       │
       │            │  ├── VaultSyncWorker       │
       │            │  ├── MemoryManager         │
       │            │  ├── TodoSyncWorker        │
       │            │  └── CreditReconciler      │
       │            └───────────┬────────────────┘
       │                        │
       │            ┌───────────▼────────────────┐
       │            │   LLM Router + Provider    │
       │            │   Registry                 │
       │            └────────────────────────────┘
       │
┌──────┴───────────────────────────────────────────────────┐
│              Messaging Gateway (Bridge Protocol)         │
│  In-App Chat (WebSocket, built-in)                       │
│  Telegram (Bot API, built-in)                            │
│  WhatsApp (Meta Cloud API, built-in, post-MVP)           │
│  Signal (external bridge, self-hosted or managed VPS)    │
└──────────────────────────────────────────────────────────┘
```

---

## 4. Workspace Isolation Architecture

DailyWerk now separates **identity** from **data ownership**:

- A WorkOS identity maps to a `users` row.
- A user belongs to one or more `workspaces` through `workspace_memberships`.
- All user-facing application data lives under `workspace_id`, not directly under `user_id`.

This indirection is deliberate. It keeps the MVP simple (one default workspace auto-created for each user) while making future collaborative workspaces an additive change instead of a data migration project.

### 4.1 Isolation Layers

| Layer | Mechanism | Safety default |
|-------|-----------|----------------|
| **Rails** | `Current.workspace` + `WorkspaceScoped` concern on workspace-owned models | `none` when no workspace context exists |
| **PostgreSQL** | Shared schema, `workspace_id` on scoped tables, RLS policies, connection-level `SET app.current_workspace_id` | no rows visible when the variable is unset |
| **S3 (Hetzner)** | Per-workspace prefix `workspaces/{workspace_id}/...`, per-workspace AES-256 SSE-C key | workspace boundary enforced at storage path level |
| **pgvector** | Embeddings carry `workspace_id` + RLS | searches stay workspace-scoped |
| **Redis** | Key namespacing `workspace:{workspace_id}:*` | shared cache space without cross-workspace collisions |
| **Disk (vault checkout)** | `/data/workspaces/{workspace_id}/vaults/...` | workspace-local working set |

### 4.2 PostgreSQL Row-Level Security

Workspace isolation is defense-in-depth:

1. Rails sets `Current.user` and `Current.workspace` after token auth.
2. `WorkspaceScoped` adds a default scope on workspace-owned models.
3. PostgreSQL RLS uses `app.current_workspace_id` as the hard database boundary.

RLS still matters even with Rails scoping. If a query bypasses the concern with raw SQL or `unscoped`, PostgreSQL should remain the final barrier.

The concrete implementation pattern for auth, request/job scoping, and connection reset lives in [RFC 002: Workspace Isolation](../rfc-open/2026-03-30-workspace-isolation.md).

PRD-level invariants:

- request and job execution must set workspace context before touching workspace-owned data
- the database must fail closed when no workspace context is present
- the application must use a non-superuser database role where RLS is expected to enforce isolation
- long-running non-database I/O must not hold open database transactions under Falcon's fiber concurrency model

### 4.3 Vault Storage Security (SSE-C)

On workspace creation, generate a unique AES-256 key → store it encrypted in PostgreSQL (Rails credentials / KMS). Every S3 PUT/GET includes SSE-C headers with the workspace key. Hetzner encrypts, then discards the key. Cross-workspace reads remain impossible even if the bucket is compromised.

**Future**: Envelope encryption with external KMS (e.g., Hashicorp Vault). The Rails master key encrypts a per-user DEK, but the DEK itself should be wrapped by a KMS-managed key. Database compromise alone should be insufficient to access vault data.

### 4.4 Workspace Memberships

Workspace memberships are the collaboration pivot:

- `owner`, `admin`, `member`, and `viewer` roles live on `workspace_memberships`.
- Fine-grained permissions can be added later through an `abilities` jsonb column.
- Adding a second user to a workspace becomes a single insert, not a data migration.

Future shared resources can still exist, but they should build on workspace membership instead of bypassing it with ad hoc user-to-user sharing tables.

### 4.5 Future: Shared Resources

If sub-workspace sharing is ever needed, layer it on top of the workspace model rather than replacing it:

```sql
-- Lightweight sharing without tenant refactor
agent_shares (id, agent_id, owner_user_id, shared_with_user_id,
              permission enum(read,use,admin), created_at)
```

RLS policies can be extended to include shared resources: `USING (workspace_id = current_workspace_id OR id IN (SELECT agent_id FROM agent_shares WHERE shared_with_user_id = current_user_id))`.

---

## 5. Canonical Database Schema

All IDs UUIDv7. Identity lives on `users`; collaboration and scoping live on `workspaces`; workspace-owned tables use `workspace_id` and RLS. This section describes the target data model. RFCs own implementable slices and migration-level detail.

### 5.1 Extensions

```ruby
class EnableExtensions < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto"
    enable_extension "vector"
  end
end
```

### 5.2 Core Tables

The implemented identity and ownership tables are specified in [RFC 002: Workspace Isolation](../rfc-open/2026-03-30-workspace-isolation.md).

| Table | Purpose | Notes |
|-------|---------|-------|
| `users` | Identity layer | WorkOS-backed user record with account status and settings |
| `workspaces` | Ownership boundary | Default workspace per user today; collaboration boundary long term |
| `workspace_memberships` | User-to-workspace join | Holds role and future fine-grained abilities |
| `plans` | Billing catalog | Product plan definition for credits, pricing, and feature flags |

### 5.3 Agent Tables

For agent model details and runtime behavior, see [03 §2](./03-agentic-system.md#2-agent-model). For initial minimal schema, see [RFC 002 §2.1](../rfc-open/2026-03-29-simple-chat-conversation.md#21-agents-table-minimal).

#### `agents` — Full Target Schema

| Column | Type | Description |
|--------|------|-------------|
| `workspace_id` | uuid FK | Owning workspace (required) |
| `slug` | string | Unique per workspace |
| `name` | string | Display name |
| `is_default` | boolean | Default agent for workspace |
| `soul` | text | Personality, tone, boundaries |
| `instructions` | text | Operating procedures (system prompt) |
| `instructions_path` | string | ERB prompt file (admin-only, validated against allowlist) |
| `identity` | jsonb | Structured persona, tone, constraints, examples |
| `model_id` | string | LLM model ID (default: gpt-5.4) |
| `provider` | string | nil = auto-detect from model_id |
| `temperature` | float | Sampling temperature (default: 0.7) |
| `params` | jsonb | Extra model params (max_tokens, etc.) |
| `thinking` | jsonb | Extended thinking config `{ enabled, budget_tokens }` |
| `tool_names` | jsonb array | Enabled tool names |
| `handoff_targets` | jsonb array | Agent slugs this agent can hand off to |
| `enabled_mcps` | jsonb | MCP server configs |
| `tool_configs` | jsonb | Per-tool configuration |
| `memory_isolation` | string | shared / isolated / read_shared |
| `sandbox_level` | string | full / restricted / readonly |
| `vault_access` | string array | Which vault IDs this agent can access |
| `active` | boolean | Soft delete |
| `metadata` | jsonb | Extensible metadata |

**Indexes**: `[workspace_id, slug]` unique, `[workspace_id, is_default]`.

#### `agent_channel_bindings` — Message Routing

Routes inbound messages to agents based on channel, account, and thread. Fields: `agent_id` (FK), `channel` (type string), `channel_account_id`, `channel_thread_id`, `priority`, `filter_rules` (jsonb). Deferred until multi-channel routing ships.

### 5.4 Channel, Session & Message Tables

For session lifecycle and compaction details, see [03 §5](./03-agentic-system.md#5-session-management) and [03 §8](./03-agentic-system.md#8-compaction). For initial minimal schema, see [RFC 002 §2](../rfc-open/2026-03-29-simple-chat-conversation.md#2-database-schema).

#### `channels` — Messaging Endpoints

| Column | Type | Description |
|--------|------|-------------|
| `channel_type` | string | web, telegram, api, signal, whatsapp |
| `external_id` | string | telegram chat_id, signal number, etc. |
| `config` | jsonb | webhook_url, bot_token_ref, etc. |
| `workspace_id` | uuid FK | Owning workspace |

**Index**: `[channel_type, external_id]` unique. Deferred — RFC 002 treats web as an implicit channel.

#### `sessions` — Conversation Continuity

| Column | Type | Description |
|--------|------|-------------|
| `workspace_id` | uuid FK | Owning workspace (required) |
| `agent_id` | uuid FK | Which agent handles this session (required) |
| `channel_id` | uuid FK | Which channel (deferred in RFC 002) |
| `session_type` | string | interactive / background / scheduled |
| `status` | string | active / compacted / archived |
| `model_id` | string | Override agent's default model |
| `provider` | string | Override agent's default provider |
| `title` | string | Display title |
| `summary` | text | Compacted conversation summary |
| `message_count` | integer | Message count |
| `total_tokens` | integer | Total tokens used |
| `context_data` | jsonb | Sliding window metadata |
| `metadata` | jsonb | Extensible |
| `started_at`, `last_activity_at`, `ended_at` | datetime | Lifecycle timestamps |

**Indexes**: `[agent_id, channel_id] WHERE status = 'active'` unique, `[workspace_id, status]`.

Uses ruby_llm's `acts_as_chat` for automatic message persistence and LLM context management.

#### `messages` — Conversation Messages

| Column | Type | Description |
|--------|------|-------------|
| `session_id` | uuid FK | Parent session (required) |
| `workspace_id` | uuid FK | Denormalized for RLS |
| `role` | string | user / assistant / system / tool |
| `content` | text | Message text (no presence validation — ruby_llm creates blank records before streaming) |
| `content_raw` | text | Provider-specific raw payload (ruby_llm v1.9+) |
| `response_id` | string | OpenAI Responses API chaining |
| `agent_slug` | string | Which agent produced this message |
| `model_id` | string | Which model produced this message |
| `input_tokens`, `output_tokens`, `cached_tokens` | integer | Token accounting |
| `thinking_text`, `thinking_signature` | text | Extended thinking support (v1.10+) |
| `thinking_tokens` | integer | Thinking token count |
| `compacted` | boolean | Whether this message has been compacted |
| `importance` | integer | 1-10, affects compaction priority |

**Indexes**: `[session_id, created_at]`, `[session_id, compacted]`.

Uses ruby_llm's `acts_as_message` for automatic token tracking and streaming support.

#### `tool_calls` — Tool Execution Tracking

| Column | Type | Description |
|--------|------|-------------|
| `message_id` | uuid FK | Parent message (required) |
| `workspace_id` | uuid FK | Denormalized for RLS |
| `tool_call_id` | string | Provider's tool call ID |
| `name` | string | Tool name |
| `arguments` | jsonb | Tool arguments |
| `result` | text | Tool execution result |
| `status` | string | pending / success / error |
| `duration_ms` | integer | Execution time |

Uses ruby_llm's `acts_as_tool_call`. Required by the gem even when no tools are configured.

### 5.5 Memory Tables

For memory architecture (5-layer model) and retrieval, see [03 §7](./03-agentic-system.md#7-memory-architecture).

```ruby
class CreateMemoryTables < ActiveRecord::Migration[8.0]
  def change
    # Tier 1 — Long-term memory entries (curated key facts)
    create_table :memory_entries, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :agent,   type: :uuid, foreign_key: true  # NULL = shared memory
      t.references :session, type: :uuid, foreign_key: true   # Source session
      t.string   :category,    default: "general"
      # fact, preference, rule, summary, relationship, instruction, context
      t.text     :content,     null: false
      t.string   :source,      default: "agent"  # agent, user, system
      t.integer  :importance,  default: 5         # 1-10
      t.integer  :access_count, default: 0
      t.datetime :last_accessed_at
      t.boolean  :active,      default: true
      t.vector   :embedding, limit: 1536          # text-embedding-3-small
      t.timestamps

      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index [:user_id, :category]
      t.index [:user_id, :active, :importance]
      t.index [:user_id, :agent_id]
    end

    # Tier 2 — Daily logs (auto-written by agent, today+yesterday loaded)
    create_table :daily_logs, id: :uuid do |t|
      t.references :user,  type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, foreign_key: true
      t.date     :date,    null: false
      t.text     :content, null: false
      t.timestamps

      t.index [:user_id, :agent_id, :date], unique: true
    end

    # Notes — persistent agent note-taking with semantic search
    create_table :notes, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.string   :title
      t.text     :content,   null: false
      t.string   :tags,      array: true, default: []
      t.jsonb    :metadata,  default: {}
      t.vector   :embedding, limit: 1536
      t.timestamps

      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index [:user_id, :created_at]
      t.index :tags, using: :gin
    end

    # Conversation archives — cold storage summaries with semantic search
    create_table :conversation_archives, id: :uuid do |t|
      t.references :session, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS — also available via session.user_id
      t.text     :summary
      t.jsonb    :key_facts,     default: []
      t.integer  :message_count
      t.integer  :total_tokens
      t.vector   :embedding, limit: 1536
      t.daterange :date_range
      t.timestamps

      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
    end
  end
end
```

### 5.6 Vault Tables

For vault sync mechanism, see [02 §4](./02-integrations-and-channels.md#4-obsidian-vault-sync). For vault search tools, see [03 §6](./03-agentic-system.md#6-tool-system).

```ruby
class CreateVaultTables < ActiveRecord::Migration[8.0]
  def change
    # Vaults — multi-vault support, per-vault encryption
    create_table :vaults, id: :uuid do |t|
      t.references :user,   type: :uuid, null: false, foreign_key: true
      t.string   :name,     null: false
      t.string   :slug,     null: false
      t.string   :vault_type, default: "native"  # obsidian, native
      t.text     :encryption_key_enc              # Per-vault AES-256 SSE-C key
      t.bigint   :max_size_bytes, default: 10_737_418_240  # 10GB
      t.string   :status,   default: "active"     # active, syncing, error
      t.timestamps

      t.index [:user_id, :slug], unique: true
    end

    # Vault files — metadata tracking for S3-backed files
    create_table :vault_files, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: true
      t.references :user,  type: :uuid, null: false, foreign_key: true
      t.string   :path,    null: false
      t.string   :content_hash
      t.bigint   :size_bytes
      t.datetime :last_modified
      t.datetime :indexed_at
      t.timestamps

      t.index [:vault_id, :path], unique: true
    end

    # Vault chunks — chunked content for hybrid search (semantic + FTS)
    create_table :vault_chunks, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: true
      t.references :user,  type: :uuid, null: false, foreign_key: true
      t.string   :file_path, null: false
      t.integer  :chunk_idx, null: false
      t.text     :content,   null: false
      t.tsvector :tsv                              # GIN index, keyword search
      t.vector   :embedding, limit: 1536           # HNSW index, semantic search
      t.jsonb    :metadata,  default: {}
      t.timestamps

      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index :tsv, using: :gin
      t.index [:vault_id, :file_path, :chunk_idx], unique: true
    end

    # Vault links — bidirectional backlinks (Obsidian-style [[wikilinks]])
    create_table :vault_links, id: :uuid do |t|
      t.references :source, type: :uuid, null: false,
                   foreign_key: { to_table: :vault_files }
      t.references :target, type: :uuid, null: false,
                   foreign_key: { to_table: :vault_files }
      t.string   :link_type, default: "reference"  # reference, embed, tag
      t.text     :context                           # Surrounding text snippet
      t.timestamps

      t.index [:source_id, :target_id, :link_type], unique: true
      t.index :target_id  # Fast backlink lookups
    end
  end
end
```

### 5.7 Task & Calendar Tables

For task sync and calendar integration, see [02 §5-6](./02-integrations-and-channels.md#5-calendar).

```ruby
class CreateTaskAndCalendarTables < ActiveRecord::Migration[8.0]
  def change
    create_table :tasks, id: :uuid do |t|
      t.references :user,  type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, foreign_key: true
      t.string   :title,       null: false
      t.text     :description
      t.string   :status,      default: "todo"  # todo, in_progress, done, cancelled
      t.integer  :priority
      t.date     :due_date
      t.string   :labels,      array: true, default: []
      t.string   :source,      default: "agent"  # agent, user, integration
      t.string   :external_id
      t.string   :external_provider              # todoist, vikunja, etc.
      t.datetime :external_updated_at            # For conflict detection
      t.jsonb    :metadata,    default: {}
      t.timestamps

      t.index [:user_id, :status]
      t.index [:external_provider, :external_id]
    end

    create_table :calendar_events, id: :uuid do |t|
      t.references :user,  type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, foreign_key: true
      t.string   :title,       null: false
      t.text     :description
      t.datetime :start_at,    null: false
      t.datetime :end_at
      t.boolean  :all_day,     default: false
      t.string   :external_id
      t.string   :external_provider              # google, caldav
      t.string   :external_calendar_id
      t.datetime :external_updated_at
      t.jsonb    :metadata,    default: {}
      t.timestamps

      t.index [:user_id, :start_at]
      t.index [:external_provider, :external_id]
    end
  end
end
```

### 5.8 Credit & Usage Tables

For billing logic and cost tracking, see [04 §1-5](./04-billing-and-operations.md#1-payments--stripe-integration).

```ruby
class CreateBillingTables < ActiveRecord::Migration[8.0]
  def change
    create_table :credit_balances, id: false do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, primary_key: true
      t.bigint   :balance, null: false, default: 0
      t.timestamps
    end

    create_table :credit_transactions, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.bigint   :amount,      null: false  # Positive = credit, negative = debit
      t.string   :transaction_type, null: false  # Avoids Rails STI conflict with reserved 'type' column
      # transaction_type values: grant, purchase, usage, refund, expiry
      t.string   :provider
      t.string   :model
      t.integer  :tokens_in
      t.integer  :tokens_out
      t.integer  :latency_ms
      t.integer  :provider_cost_cents
      t.bigint   :credits_charged
      t.jsonb    :metadata,    default: {}
      t.timestamps

      t.index [:user_id, :created_at]
    end

    # Detailed usage records (per LLM call)
    create_table :usage_records, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.references :message, type: :uuid, foreign_key: true
      t.string   :agent_slug
      t.string   :model_id,       null: false
      t.string   :provider,       null: false
      t.string   :request_type,   default: "chat"  # chat, embedding, image
      t.integer  :input_tokens,   default: 0
      t.integer  :output_tokens,  default: 0
      t.integer  :cached_tokens,  default: 0
      t.integer  :thinking_tokens, default: 0
      t.decimal  :input_cost,     precision: 12, scale: 8, default: 0
      t.decimal  :output_cost,    precision: 12, scale: 8, default: 0
      t.decimal  :total_cost,     precision: 12, scale: 8, default: 0
      t.string   :currency,       default: "USD"
      t.integer  :duration_ms
      t.jsonb    :metadata,       default: {}
      t.timestamps

      t.index [:user_id, :created_at]
      t.index [:model_id, :created_at]
    end

    # Daily aggregates for fast dashboard queries
    create_table :usage_daily_summaries, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.date     :date,          null: false
      t.string   :model_id
      t.string   :provider
      t.integer  :request_count,       default: 0
      t.integer  :total_input_tokens,  default: 0
      t.integer  :total_output_tokens, default: 0
      t.decimal  :total_cost, precision: 12, scale: 6, default: 0
      t.timestamps

      t.index [:user_id, :date, :model_id, :provider], unique: true, name: "idx_usage_daily_unique"
    end
  end
end
```

### 5.9 Integration Tables

For BYOK and MCP details, see [04 §6-7](./04-billing-and-operations.md#6-byok--bring-your-own-key). For bridge protocol, see [02 §1](./02-integrations-and-channels.md#1-messaging-gateway--bridge-protocol).

```ruby
class CreateIntegrationTables < ActiveRecord::Migration[8.0]
  def change
    # General integrations (Gmail, Google Calendar, etc.)
    create_table :integrations, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string   :provider,    null: false  # gmail, google_calendar, todoist, etc.
      t.text     :credentials_encrypted
      t.jsonb    :config,      default: {}
      t.string   :status,      default: "active"
      t.jsonb    :metadata,    default: {}
      t.timestamps

      t.index [:user_id, :provider], unique: true
    end

    # BYOK — API credentials for LLM providers
    create_table :api_credentials, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string   :provider,      null: false  # openai, anthropic, openrouter
      t.text     :api_key_enc,   null: false  # Rails 8 encryption
      t.string   :api_base                    # Custom endpoint (Azure, self-hosted)
      t.boolean  :active,        default: true
      t.jsonb    :metadata,      default: {}
      t.timestamps

      t.index [:user_id, :provider], unique: true
    end

    # MCP server configurations
    create_table :mcp_server_configs, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string   :name,            null: false
      t.string   :transport_type,  null: false, default: "streamable"  # streamable, sse (user); stdio (admin-only)
      t.string   :url                          # For streamable/sse
      t.jsonb    :stdio_config,    default: {} # { command:, args:, env: }
      t.jsonb    :oauth_config,    default: {} # { scope:, client_id:, ... }
      t.text     :oauth_token_enc              # Encrypted OAuth token
      t.boolean  :active,          default: true
      t.string   :allowed_tools,   array: true, default: []
      t.string   :blocked_tools,   array: true, default: []
      t.jsonb    :metadata,        default: {}
      t.timestamps

      t.index [:user_id, :name], unique: true
    end

    # Messaging bridges
    create_table :bridges, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string   :channel,      null: false  # signal, telegram, whatsapp
      t.string   :bridge_type,  null: false  # builtin, self_hosted, managed
      t.string   :api_key_hash
      t.string   :webhook_url
      t.string   :host_url
      t.string   :status,       default: "provisioning"
      # provisioning, healthy, unhealthy, deprovisioned
      t.string   :managed_server_id
      t.string   :managed_server_ip
      t.string   :phone_number
      t.datetime :last_health_check_at
      t.timestamps
    end

    create_table :bridge_events, id: :uuid do |t|
      t.references :bridge, type: :uuid, null: false, foreign_key: true
      t.string   :event_type,  null: false
      t.jsonb    :metadata,    default: {}
      t.timestamps

      t.index [:bridge_id, :created_at]
    end
  end
end
```

---

## 6. Deployment Architecture (MVP)

```
┌─────────────────────────────────────────────────────────┐
│  DailyWerk Core (Hetzner Dedicated / VPS)               │
│                                                         │
│  Nginx (+TLS) → Rails API (Falcon)                      │
│  GoodJob Workers (separate process, external mode)      │
│  PostgreSQL (+pgvector) + Redis                         │
│  Node.js 22 (Obsidian Headless)                         │
│  Vault checkouts: /data/vaults/{user_id}/               │
│  Built-in bridges (Telegram, WhatsApp)                  │
│  SPA via Nginx/CDN                                      │
│  S3 → Hetzner Object Storage                            │
├─────────────────────────────────────────────────────────┤
│  Managed Signal Bridges (Hetzner Cloud VPS, per user)   │
│  Self-Hosted Signal Bridges (user's infra)              │
│  Both speak Bridge Protocol → Core API                  │
└─────────────────────────────────────────────────────────┘
```

Docker Compose for MVP. Single server for first 10 test users (keep all vaults warm). Kubernetes as scaling path: StatefulSets for vault checkouts with persistent volumes, Signal bridges as pods instead of VPS, regional node labels.

---

## 7. Platform Conventions

### 7.1 Rails Best Practices

- **N+1 prevention**: Use `strict_loading` on models by default. Consider `bullet` gem for development.
- **Strong parameters**: All controller actions use `permit` with explicit allowlists.
- **CSRF**: API-mode Rails disables CSRF by default. WebSocket and webhook endpoints use token-based auth.
- **SQL injection**: All queries use parameterized statements. RLS provides defense-in-depth.
- **Migration safety**: Use `strong_migrations` gem. No locking DDL on large tables without `safety_assured`.
- **Service objects**: Business logic in `app/services/`. Models stay thin.
- **Indexes**: Every foreign key indexed. Every `WHERE` clause backed by an appropriate index.

### 7.2 Security Considerations

- API keys and credentials encrypted via Rails 8 `ActiveRecord::Encryption` (non-deterministic).
- `instructions_path` in agents table: validated against allowlist of known prompt templates. Not user-settable via API — admin-only field.
- `GenerateEmbeddingJob` uses allowlisted model names: `EMBEDDABLE_MODELS = %w[MemoryEntry Note VaultChunk ConversationArchive]`. No raw `constantize`.
- **RLS safety**: Session-level `SET` with connection-pool checkin hooks. Architectural invariant: no non-DB I/O inside transactions.
- **Path traversal**: All file path construction from user/agent input must be canonicalized and prefix-checked against the expected base directory.
- **SSRF protection**: User-provided URLs (BYOK `api_base`, webhook URLs) validated against allowlists. HTTPS-only. Custom endpoints require admin approval.

---

## 8. Open Questions

1. **Vault cold-start latency** — Large vaults (5-10GB) re-checkout from S3 could take minutes. MVP: keep all test users warm, monitor. Solve when real usage data exists.
2. **Multi-vault pricing** — Additional vaults as paid feature. Pricing TBD. Architecture supports it (vaults table, per-vault encryption, per-agent vault_access).
3. **Shared resources** — Agent sharing, vault sharing. Deferred to post-MVP. Schema supports it via `agent_shares` pattern (§4.4).
4. **Frontend architecture** — Vite + React + TypeScript + Tailwind + DaisyUI chosen. [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) defines the initial chat UI, app shell with top bar, and API contract. Component patterns to be codified after more features ship.
5. **Observability** — Logging, metrics, alerting, health checks, session replay for debugging. Needs dedicated design.
6. **GDPR / data deletion** — Define `UserDeletionService` for hard-delete of all user data across PG, S3, Redis, and vault checkouts.
7. **SPA authentication** — React SPA and Rails API must share a root domain for HttpOnly/Secure/SameSite cookie-based auth. JWT in localStorage is an XSS vector.
8. **Connection pooling** — Falcon at scale needs PgBouncer. Transaction-mode PgBouncer conflicts with session-level SET. Evaluate statement-level pooling or connection pinning strategies.
9. **Observability** — Logging, metrics, alerting, health checks, session replay for debugging. Needs dedicated design.
10. **GDPR / data deletion** — `UserDeletionService` for hard-delete of all user data across PG, S3, Redis, and vault checkouts.
11. **Rate limiting** — Per-user request rate (requests/minute) in Redis. Per-provider rate limiting to respect API quotas.
