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

## 4. User Isolation Architecture

DailyWerk is user-centric: each user owns their data. Isolation is enforced at every layer via `user_id`. No multi-tenancy at MVP — if shared resources (e.g., shared agents) are needed later, a lightweight `agent_shares` table can be added without restructuring the data model.

### 4.1 Isolation Layers

| Layer | Mechanism |
|-------|-----------|
| **PostgreSQL** | Shared schema, `user_id` on all tables, RLS policies, connection-level `SET app.current_user_id` |
| **S3 (Hetzner)** | Per-user prefix `vaults/{user_id}/`, per-user AES-256 SSE-C key |
| **pgvector** | Embeddings with `user_id` + RLS. All vector searches scoped. |
| **Redis** | Key namespacing `user:{user_id}:*` |
| **Disk (vault checkout)** | `/data/vaults/{user_id}/`. LRU eviction. Max 10GB/user. |

### 4.2 PostgreSQL Row-Level Security

RLS enforces data boundaries at the database level. Even if application code has a bug that omits a `WHERE user_id = ?`, the database silently filters rows.

The pattern uses PostgreSQL session variables (`SET app.current_user_id`). A Rails middleware sets the variable on every request; an `ensure RESET` block clears it. Background jobs use a `UserScopedJob` concern.

```ruby
# db/migrate/xxx_setup_rls.rb
class SetupRls < ActiveRecord::Migration[8.0]
  def up
    # App MUST connect as non-superuser (superusers bypass RLS)
    execute <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
          CREATE ROLE app_user LOGIN PASSWORD '#{Rails.application.credentials.db_app_password}';
        END IF;
      END $$;
    SQL

    USER_SCOPED_TABLES.each do |table|
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;"

      execute <<~SQL
        CREATE POLICY user_isolation ON #{table}
          FOR ALL
          TO app_user
          USING (user_id::text = current_setting('app.current_user_id', true))
          WITH CHECK (user_id::text = current_setting('app.current_user_id', true));
      SQL
    end

    USER_SCOPED_TABLES.each do |table|
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO app_user;"
    end
    execute "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;"
  end

  USER_SCOPED_TABLES = %w[
    agents sessions channels messages tool_calls
    memory_entries daily_logs notes
    conversation_archives api_credentials mcp_server_configs
    usage_records usage_daily_summaries tasks calendar_events integrations
    bridges vaults vault_files vault_chunks
    credit_balances credit_transactions
  ].freeze
  # NOTE: messages, tool_calls, and conversation_archives need user_id
  # added (denormalized) — see schema §5.4–5.5 below.
  # vault_links and bridge_events lack user_id; access controlled via
  # JOINs to parent tables (vault_files, bridges).
end
```

```ruby
# app/middleware/user_rls_middleware.rb
class UserRlsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    user_id = resolve_user(request)

    if user_id
      set_rls_context(user_id) { @app.call(env) }
    else
      @app.call(env)
    end
  end

  private

  def resolve_user(request)
    request.env["current_user_id"] # Set by auth middleware (WorkOS)
  end

  def set_rls_context(user_id)
    # Session-level SET persists on the connection until RESET.
    # This is safer than SET LOCAL under Falcon's fiber model because
    # SET LOCAL requires an explicit transaction wrapper.
    ActiveRecord::Base.connection.execute(
      "SET app.current_user_id = #{ActiveRecord::Base.connection.quote(user_id)}"
    )
    yield
  ensure
    ActiveRecord::Base.connection.execute("RESET app.current_user_id")
  end
end
```

```ruby
# config/initializers/rls_safety.rb — Defense-in-depth: reset RLS on connection return
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkin, :before do
    raw_connection.exec("RESET app.current_user_id") rescue nil
  end
end
```

> **Invariant**: Never perform non-DB I/O (HTTP calls, LLM streaming, file reads) inside a database transaction. Transactions hold connections; under Falcon's fiber concurrency, long-held connections exhaust the pool.

```ruby
# app/jobs/concerns/user_scoped_job.rb
module UserScopedJob
  extend ActiveSupport::Concern

  included do
    around_perform :set_rls_context
  end

  private

  def set_rls_context
    uid = self.class.extract_user_id(arguments)
    raise ArgumentError, "#{self.class.name} requires user_id: keyword arg" unless uid

    ActiveRecord::Base.connection.execute(
      "SET app.current_user_id = #{ActiveRecord::Base.connection.quote(uid)}"
    )
    yield
  ensure
    ActiveRecord::Base.connection.execute("RESET app.current_user_id") if uid
  end

  class_methods do
    def extract_user_id(args)
      # Convention: all user-scoped jobs pass user_id: as keyword arg
      args.last.try(:[], :user_id) if args.last.is_a?(Hash)
    end
  end
end
```

All jobs touching user data must `include UserScopedJob` and pass `user_id:` as keyword argument.

```yaml
# config/database.yml
production:
  primary:
    adapter: postgresql
    username: app_user          # NOT the superuser — RLS enforced
    password: <%= Rails.application.credentials.db_app_password %>
  primary_admin:
    adapter: postgresql
    username: postgres          # Superuser for migrations only
    password: <%= Rails.application.credentials.db_admin_password %>
    migrations_paths: db/migrate
```

### 4.3 Vault Storage Security (SSE-C)

On user creation, generate unique AES-256 key → stored encrypted in PG (Rails credentials / KMS). Every S3 PUT/GET includes SSE-C headers with user's key. Hetzner encrypts, then discards key. Cross-user read impossible even if bucket compromised.

**Future**: Envelope encryption with external KMS (e.g., Hashicorp Vault). The Rails master key encrypts a per-user DEK, but the DEK itself should be wrapped by a KMS-managed key. Database compromise alone should be insufficient to access vault data.

### 4.4 Future: Shared Resources

If shared agents or shared vaults are needed later, use a permissions table rather than full multi-tenancy:

```sql
-- Lightweight sharing without tenant refactor
agent_shares (id, agent_id, owner_user_id, shared_with_user_id,
              permission enum(read,use,admin), created_at)
```

RLS policies can be extended to include shared resources: `USING (user_id = current_user_id OR id IN (SELECT agent_id FROM agent_shares WHERE shared_with_user_id = current_user_id))`.

---

## 5. Canonical Database Schema

All IDs UUIDv7. All tables with `user_id` have RLS. This is the **single source of truth** for the data model — other PRDs reference this section.

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

```ruby
class CreateCoreTables < ActiveRecord::Migration[8.0]
  def change
    create_table :users, id: :uuid do |t|
      t.string   :workos_id,    null: false, index: { unique: true }
      t.string   :email,        null: false, index: { unique: true }
      t.references :plan,       type: :uuid, foreign_key: true
      t.text     :vault_encryption_key_enc  # AES-256 key, encrypted at rest
      t.string   :stripe_customer_id
      t.string   :stripe_subscription_id
      t.string   :status,       null: false, default: "pending"
      # status: pending (admin approval), active, suspended, cancelled
      t.text     :synthesized_profile       # Layer 5 memory: daily background synthesis
      t.jsonb    :settings,     default: {}
      t.timestamps
    end

    create_table :plans, id: :uuid do |t|
      t.string   :name,           null: false
      t.integer  :monthly_credits, null: false
      t.integer  :price_cents,    null: false
      t.string   :stripe_price_id
      t.jsonb    :features,      default: {}
      t.timestamps
    end
  end
end
```

### 5.3 Agent Tables

For agent model details and runtime behavior, see [03 §2](./03-agentic-system.md#2-agent-model).

```ruby
class CreateAgentTables < ActiveRecord::Migration[8.0]
  def change
    create_table :agents, id: :uuid do |t|
      t.references :user,        type: :uuid, null: false, foreign_key: true
      t.string   :slug,          null: false
      t.string   :name,          null: false
      t.boolean  :is_default,    default: false

      # Identity & behavior
      t.text     :soul                        # Personality, tone, boundaries
      t.text     :instructions                # Operating procedures
      t.string   :instructions_path           # Alternative: ERB prompt file
      t.jsonb    :identity,      default: {}  # Structured persona, tone, constraints, examples

      # Model configuration
      t.string   :model_id,      null: false, default: "claude-sonnet-4-6"
      t.string   :provider                    # nil = auto-detect
      t.float    :temperature,   default: 0.7
      t.jsonb    :params,        default: {}  # max_tokens, etc.
      t.jsonb    :thinking,      default: {}  # { enabled: true, budget_tokens: 10000 }

      # Tool & capability configuration
      t.jsonb    :tool_names,    default: []  # ["notes", "memory", "vault_search"]
      t.jsonb    :handoff_targets, default: [] # ["research_agent", "code_agent"]
      t.jsonb    :enabled_mcps,  default: {}  # MCP server configs (also see mcp_server_configs table)
      t.jsonb    :tool_configs,  default: {}  # Per-tool config (calendar rules, etc.)

      # Access controls (DailyWerk-specific)
      t.string   :memory_isolation, default: "shared"
      # shared: reads/writes shared long-term memory
      # isolated: own long-term memory only
      # read_shared: reads shared, writes to own
      t.string   :sandbox_level,    default: "full"
      # full: all enabled tools available
      # restricted: subset of tools, confirmation required for destructive ops
      # readonly: read-only tools only
      t.string   :vault_access,  array: true, default: [] # Which vault IDs this agent can access

      t.boolean  :active,        default: true
      t.jsonb    :metadata,      default: {}
      t.timestamps

      t.index [:user_id, :slug], unique: true
      t.index [:user_id, :is_default]
    end

    create_table :agent_channel_bindings, id: :uuid do |t|
      t.references :agent,   type: :uuid, null: false, foreign_key: true
      t.string   :channel,   null: false  # signal, telegram, whatsapp, email, web, in_app
      t.string   :channel_account_id       # Which Signal number, Telegram bot, etc.
      t.string   :channel_thread_id        # Specific group/thread, or NULL for all DMs
      t.integer  :priority,  default: 0    # Lower = higher priority
      t.jsonb    :filter_rules, default: {} # Keyword triggers, sender filters
      t.timestamps
    end
  end
end
```

### 5.4 Channel, Session & Message Tables

For session lifecycle and compaction details, see [03 §5](./03-agentic-system.md#5-session-management) and [03 §8](./03-agentic-system.md#8-compaction).

```ruby
class CreateSessionTables < ActiveRecord::Migration[8.0]
  def change
    # Channels — normalized abstraction for messaging endpoints
    create_table :channels, id: :uuid do |t|
      t.string   :channel_type,  null: false  # web, telegram, api, signal, whatsapp
      t.string   :external_id                 # telegram chat_id, signal number, etc.
      t.jsonb    :config,        default: {}  # webhook_url, bot_token_ref, etc.
      t.references :user,        type: :uuid, foreign_key: true
      t.timestamps
      t.index [:channel_type, :external_id], unique: true
    end

    # Sessions — one active session per agent × channel
    create_table :sessions, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :agent,   type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true

      t.string   :session_type, default: "interactive"
      # interactive: user-initiated conversation
      # background: agent-initiated (scheduled tasks, notifications)
      # scheduled: cron-triggered (daily summaries, etc.)

      t.string   :status,       default: "active"  # active, compacted, archived
      t.string   :model_id                          # Override agent's default model
      t.string   :provider                          # Override agent's default provider

      t.text     :summary                           # Compacted conversation summary
      t.integer  :message_count, default: 0
      t.integer  :total_tokens,  default: 0
      t.jsonb    :context_data,  default: {}        # Sliding window metadata
      t.jsonb    :metadata,      default: {}

      t.datetime :started_at
      t.datetime :last_activity_at
      t.datetime :ended_at
      t.timestamps

      t.index [:agent_id, :channel_id], unique: true, where: "status = 'active'"
      t.index [:user_id, :status]
    end

    # Messages — rich token tracking, importance scoring, thinking support
    create_table :messages, id: :uuid do |t|
      t.references :session, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS — also available via session.user_id
      t.string   :role,      null: false   # user, assistant, system, tool
      t.text     :content
      t.text     :content_raw               # Provider-specific Content::Raw
      t.string   :response_id               # OpenAI Responses API chaining
      t.string   :agent_slug                # Which agent produced this message

      # Token accounting (split by type for cost calculation)
      t.integer  :input_tokens
      t.integer  :output_tokens
      t.integer  :cached_tokens

      # Extended thinking support
      t.text     :thinking_text
      t.text     :thinking_signature
      t.integer  :thinking_tokens

      # Compaction
      t.boolean  :compacted,   default: false
      t.integer  :importance,  default: 5    # 1-10, affects compaction priority

      t.timestamps
      t.index [:session_id, :created_at]
      t.index [:session_id, :compacted]
    end

    # Tool calls — separate table for structured tool execution tracking
    create_table :tool_calls, id: :uuid do |t|
      t.references :message, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS — also available via session.user_id
      t.string   :tool_call_id
      t.string   :name
      t.jsonb    :arguments,   default: {}
      t.text     :result
      t.string   :status,      default: "pending"  # pending, success, error
      t.integer  :duration_ms
      t.timestamps
    end
  end
end
```

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
4. **Frontend architecture** — Vite + React + TypeScript + Tailwind + DaisyUI chosen. Component structure, state management, and API contract details TBD.
5. **Observability** — Logging, metrics, alerting, health checks, session replay for debugging. Needs dedicated design.
6. **GDPR / data deletion** — Define `UserDeletionService` for hard-delete of all user data across PG, S3, Redis, and vault checkouts.
7. **SPA authentication** — React SPA and Rails API must share a root domain for HttpOnly/Secure/SameSite cookie-based auth. JWT in localStorage is an XSS vector.
8. **Connection pooling** — Falcon at scale needs PgBouncer. Transaction-mode PgBouncer conflicts with session-level SET. Evaluate statement-level pooling or connection pinning strategies.
9. **Observability** — Logging, metrics, alerting, health checks, session replay for debugging. Needs dedicated design.
10. **GDPR / data deletion** — `UserDeletionService` for hard-delete of all user data across PG, S3, Redis, and vault checkouts.
11. **Rate limiting** — Per-user request rate (requests/minute) in Redis. Per-provider rate limiting to respect API quotas.
