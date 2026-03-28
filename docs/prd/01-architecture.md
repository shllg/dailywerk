# DailyWerk — Architecture Planning (Draft v0.5)

## 1. What DailyWerk Is

A managed, opinionated personal AI assistant SaaS for non-technical users. Inspired by OpenClaw but removes all setup/ops burden. Users interact via messaging apps, email, in-app chat, and a web dashboard. Data stays portable (Obsidian vault via official Obsidian Sync, or DailyWerk-native markdown vault). All technologies use **latest stable versions**.

Core capabilities: diary, nutrition/sport tracking, research, calendar management, task management, reminders, daily/weekly/monthly summaries, todo integration, comms aggregation.

---

## 2. Stack Decision Summary

| Layer | Choice | Rationale |
|-------|--------|-----------|
| **Frontend** | Vite + React + TypeScript + Tailwind CSS + DaisyUI | SPA dashboard with in-app chat. DaisyUI for fast, accessible UI. |
| **Backend API** | Ruby on Rails (latest, API mode) + Falcon server | Fiber-per-request concurrency, native HTTP/2, WebSocket. Streaming LLM responses. Deployed at Shopify. |
| **Background Jobs** | ActiveJob + GoodJob | Postgres-backed. No Redis dependency for jobs. Built-in cron, concurrency, batches, dashboard. |
| **DB** | PostgreSQL (latest) + pgvector | Primary store. RLS for tenant isolation. pgvector for semantic search. UUIDv7 PKs. |
| **Cache / Realtime** | Redis | Session cache, rate limiting, pub/sub, ActionCable (WebSocket for in-app chat). |
| **Search** | Hybrid: pgvector (semantic) + PostgreSQL FTS (keyword) | Postgres-native. OpenSearch as scaling escape hatch. |
| **File Storage** | Hetzner Object Storage (S3-compatible) | €4.99/mo base (1TB + 1TB egress). EU residency. Per-user SSE-C encryption. |
| **Vault Sync** | Obsidian Headless (official CLI) | Official headless client. Server-side bidirectional sync. |
| **Auth** | WorkOS | SSO, social login, magic links. |
| **Payments** | Stripe | Subscriptions, metered overage, add-ons. |

### Why Falcon over Puma

Fiber-based. Each request yields on I/O, enabling massive concurrency for streaming LLM responses and chained agent I/O. Rails integrates via `falcon-rails`, auto-sets `isolation_level = :fiber`. Risk: less ecosystem battle-testing. Puma maintained as fallback config.

### Why GoodJob over Sidekiq

Postgres-backed. Eliminates Redis as critical-path for jobs. Cron, concurrency controls, batches, web dashboard. v4.13+ (2026). Redis stays for cache/pub/sub only.

### Why UUIDv7

Time-ordered, 128-bit, PostgreSQL native `uuid` type (16 bytes). ULIDs need `varchar(26)` = 60% more storage, slower joins. RFC 9562 (2024). Native `uuidv7()` in PostgreSQL 18.

---

## 3. Tenant Isolation Architecture

### 3.1 Isolation Layers

| Layer | Mechanism |
|-------|-----------|
| **PostgreSQL** | Shared schema, `user_id` on all tables, RLS policies, connection-level `SET app.current_user_id` |
| **S3 (Hetzner)** | Per-user prefix `vaults/{user_id}/`, per-user AES-256 SSE-C key |
| **pgvector** | Embeddings with `user_id` + RLS. All vector searches scoped. |
| **Redis** | Key namespacing `user:{user_id}:*` |
| **Disk (vault checkout)** | `/data/vaults/{user_id}/`. LRU eviction. Max 10GB/user. |

### 3.2 Vault Storage Security (SSE-C)

On user creation, generate unique AES-256 key → stored encrypted in PG (Rails credentials / KMS). Every S3 PUT/GET includes SSE-C headers with user's key. Hetzner encrypts, then discards key. Cross-user read impossible even if bucket compromised.

---

## 4. System Architecture

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

## 5. Integrations

### 5.1 Email (Gmail + SMTP/IMAP)

**Gmail API** (primary path): OAuth 2.0 with separate flow from WorkOS. Full access scopes: `gmail.readonly`, `gmail.send`, `gmail.modify`, `gmail.labels`. Agent can read, send, label, archive, star, and manage emails. Push notifications via Google Pub/Sub. `users.watch()` renewed every 7 days (GoodJob cron).

**SMTP/IMAP** (alternative path, post-MVP): For users not on Gmail. Standard IMAP polling for inbox monitoring, SMTP for sending. Credentials stored encrypted. IMAP IDLE for near-realtime push where supported. Broader provider support (Outlook, ProtonMail Bridge, self-hosted).

### 5.2 Messaging Gateway — Bridge Protocol

DailyWerk defines a **universal bridge protocol**. All messenger integrations speak the same webhook-based contract:

```
── Inbound (bridge → DailyWerk) ──────────────────────────
POST https://api.dailywerk.com/bridges/{bridge_id}/inbound
Authorization: Bearer {bridge_api_key}
{
  "event": "message",
  "sender": "+4915112345678",
  "timestamp": "2026-03-27T10:00:00Z",
  "content": {
    "type": "text|image|file|voice",
    "text": "...",
    "media_url": "...",
    "mime_type": "image/jpeg"
  },
  "thread_id": "...",
  "raw": { ... }
}

── Outbound (DailyWerk → bridge) ─────────────────────────
POST https://{bridge_host}/send
Authorization: Bearer {bridge_api_key}
{
  "recipient": "+4915112345678",
  "content": { "type": "text|image|file", "text": "...", "media_url": "...", "mime_type": "..." },
  "reply_to": "..."
}

── Health ─────────────────────────────────────────────────
GET https://{bridge_host}/health
→ { "status": "ok", "account": "+49...", "uptime": 3600 }
```

#### Channel Types

**In-App Chat** (built-in, WebSocket): Native chat in the DailyWerk dashboard. ActionCable (Rails WebSocket) connects the SPA directly to the agent. No bridge needed — messages go straight to AgentRunner. Primary channel for non-technical users who don't use messengers with the bot.

**Telegram** (built-in bridge): Bot API, webhook mode. User links via `/start` deep link with token. Simplest external integration.

**Telegram encryption note**: Telegram Bot API does **not** support end-to-end encryption. Bot messages use client-server encryption (MTProto) — Telegram servers can technically read them. Secret chats (E2EE) are human-to-human only, not available for bots. This is a fundamental Telegram limitation. We should document this clearly for users and recommend Signal for security-sensitive use cases.

**WhatsApp** (built-in bridge, post-MVP): Meta Cloud API. Requires Meta Business Manager, phone number verification, message templates for outbound (24h session window). 4-6 weeks for Meta approval.

**Signal** (external bridge): No official bot API. DailyWerk publishes `dailywerk/signal-bridge` Docker image (open source — no magic, just message routing). Three layers:

*Layer 1 — Self-Hosted (free, technical users)*: User runs Docker image on their infra with DailyWerk API key. User registers dedicated phone number via dashboard.

*Layer 2 — Managed (paid add-on)*: User clicks "Enable Managed Signal" → DailyWerk auto-provisions Hetzner cx22 VPS (€3.29/mo), deploys bridge image via cloud-init, injects credentials. Billed as ~€5/mo add-on via Stripe. Health monitoring every 60s, auto-restart on failure + alert user.

*Layer 3 — Pooled (future)*: Shared signal-cli infrastructure. Same bridge protocol. Users don't know which layer serves them.

**Critical**: Registering a number with signal-cli deregisters it from the user's phone. Dedicated phone number required (prepaid SIM). Very clear in UX.

### 5.3 Obsidian Vault Sync

#### S3 as Source of Truth, Disk as Working Copy

```
User's Obsidian App (phone/desktop)
         │ (Obsidian Sync protocol)
   Obsidian Cloud
         │ (ob sync --continuous)
   DailyWerk Server: /data/vaults/{user_id}/   ← local checkout
         │
         ├──▶ Agent reads/writes files here
         ├──▶ EmbeddingWorker indexes changes → pgvector
         │
         ▼ (VaultSyncWorker, every 5min + inotify)
   Hetzner S3: vaults/{user_id}/   ← encrypted canonical store (SSE-C)
```

**Consistency guarantees**:

1. **S3 always latest**: VaultSyncWorker diffs local→S3 by content hash (every 5min + on inotify file change). One-way mirror. Agents write to local checkout; VaultSyncWorker pushes to S3.
2. **pgvector always current**: EmbeddingWorker triggered by inotify. Re-chunks and re-embeds changed files. `vault_files.content_hash` skips unchanged files.
3. **Correct tenant on correct server**: MVP single-server = all active users checked out. Scale: Redis checkout lock (`user:{id}:checkout_server = server-3`), request routing to locked server.
4. **Disk space**: LRU eviction for inactive users (>24h no triggers). S3 retains everything. Re-checkout on next trigger. Max 10GB/user enforced at VaultSyncWorker level. Monitoring + alerts.
5. **Cold start**: Pull full vault from S3, then start `ob sync` on top. MVP: keep all test users warm, monitor, solve later.

**Non-Obsidian users**: Identical mechanism minus `ob sync`. DailyWerk-native vault: markdown files in S3, simple read-only viewer in dashboard. Can connect Obsidian later to the same vault directory + start sync (may produce conflicts, user is warned).

**Multi-vault** (future): Users may have multiple vaults (e.g., personal, work). Additional pricing TBD. Each vault = separate S3 prefix + separate local checkout + separate pgvector partition. Agent tool configs specify which vault(s) they can access.

**Obsidian Sync cost**: User's own subscription (~$4/mo). DailyWerk does not pay. Documented as prerequisite for Obsidian users. Requires Node.js 22+ on server.

### 5.4 Calendar

**Google Calendar API** (primary): OAuth 2.0, separate flow from WorkOS. Bidirectional sync. DailyWerk stores its own calendar entries in PostgreSQL. User-configurable rules per agent: which Google Calendar to target (personal, work, shared), default duration, reminders, color coding.

**CalDAV export** (read-only, for non-Google users): DailyWerk exposes a CalDAV-compatible read-only endpoint per user (`https://api.dailywerk.com/caldav/{user_id}/`). Any CalDAV-compatible app (Apple Calendar, Thunderbird, Nextcloud) can subscribe and see DailyWerk-managed events. This is a **read-only feed** — events created in external apps don't sync back (that requires a full CalDAV server, which is post-MVP complexity). Users get an .ics subscription URL as a simpler alternative.

**CalDAV write support** (post-MVP): Full CalDAV server implementation (e.g., via `cervicale` gem or custom Rack middleware). Enables bidirectional sync with any calendar app.

### 5.5 Tasks / Todos

**A) Internal agent tasks** (ephemeral, session-scoped): Scratch work during agentic loops. Live in session context, discarded when session ends.

**B) User-facing tasks** (persistent, synced):

```sql
tasks (id, user_id, agent_id, title, description,
       status enum(todo,in_progress,done,cancelled),
       priority, due_date, labels text[],
       source enum(agent,user,integration),
       external_id, external_provider enum(todoist,vikunja,...),
       external_updated_at timestamp,  -- for conflict detection
       metadata jsonb, created_at, updated_at)
```

**External sync conflict handling**: Last-write-wins with conflict detection. On each sync cycle (TodoSyncWorker, GoodJob cron every 2min):
1. Pull changes from external provider since last sync.
2. Compare `external_updated_at` with local `updated_at`.
3. If external is newer → update local. If local is newer → push to external. If both changed → external wins (user explicitly edited in their app), log conflict for review.
4. Same strategy for calendar sync — external user edits take precedence over agent-generated events.

---

## 6. Data Search & Retrieval Layer

### 6.1 Two Search Domains

**Agent memory** (PostgreSQL only): Session history, memory entries, agent notes. Private to agents. Searched via `memory_search` tool.

**User data / vault** (S3-backed, pgvector-indexed): Vault files, diary entries, research notes. Owned by user, read/written by agents. Searched via `vault_search` tool.

These are separate search spaces with separate tools. An agent can search both, but the distinction matters for privacy and data lifecycle.

### 6.2 Hybrid Search in PostgreSQL

```sql
vault_chunks (id, user_id, vault_id, file_path, chunk_idx, content text,
              tsv tsvector,           -- GIN index, keyword search
              embedding vector(1536), -- HNSW index, semantic search
              metadata jsonb, updated_at)
```

Hybrid query: `ts_rank()` for keyword + `1 - (embedding <=> query_embedding)` for cosine, combined via Reciprocal Rank Fusion (RRF). All queries scoped by `user_id` (RLS).

### 6.3 Indexing Pipeline

File change (inotify from local checkout or agent write) → EmbeddingWorker: read → markdown-aware chunk (respect headings, paragraphs, code blocks) → generate tsvector → call OpenAI `text-embedding-3-small` (1536 dims) → upsert `vault_chunks` → track credit cost.

### 6.4 Scaling Path

pgvector handles ~1M vectors with HNSW. Per-user vault = <50k chunks typically. At 10k+ users: partition `vault_chunks` by `user_id` → OpenSearch with filtered aliases → dedicated vector DB.

---

## 7. Payments & Credit System

### 7.1 Stripe Integration

- **Subscriptions**: Stripe Products/Prices. Upgrade/downgrade via Billing Portal.
- **Credit overage**: Stripe Usage Records (metered). Billed end of cycle if user enabled it.
- **Add-ons**: Managed Signal Bridge = separate Subscription Item (~€5/mo). Additional vaults = TBD.
- **Free tier**: No Stripe subscription. Internal credit grant. **Manual admin approval** — new users created as `pending`. Admin unlocks before use.
- **Credit exhaustion**: Chat is **blocked** (not degraded). If overage billing enabled, additional credits charged per-credit.
- **Webhooks**: Stripe → Rails endpoint → update plan/credit/subscription state.

### 7.2 Provider Registry

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
      gpt-4o: { input_cost_per_1m_tokens: 2.50, output_cost_per_1m_tokens: 10.00, ... }
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

**Stats & measurement**: Every LLM call → `credit_transactions` with: provider, model, tokens_in, tokens_out, latency_ms, provider_cost_cents, credits_charged. Enables per-user dashboards, per-model analysis, margin tracking, anomaly detection.

### 7.3 LLM Router

Routes by task type, user plan, agent config overrides, provider health. Falls back to OpenRouter if primary provider is down.

### 7.4 Credit Model

1 credit = $0.001. Pre-deduct estimated → reconcile actual async. Free tier: small monthly grant, no rollover. Embedding costs negligible (~$0.02/1M tokens) but tracked.

---

## 8. Agent Architecture (OpenClaw-Inspired, No Compatibility)

Heavy inspiration from OpenClaw's identity-first, file-driven model. Not compatible — DailyWerk is its own product. No import/export with OpenClaw.

### 8.1 Multi-Agent Model

Each user can have multiple agents with distinct roles, tools, memory, and access levels:

```sql
agents (id, user_id, name, slug, is_default boolean,
        soul text,              -- personality, tone, boundaries (≈ SOUL.md)
        instructions text,      -- operating procedures (≈ AGENTS.md)
        identity jsonb,         -- name, emoji, role label
        model_overrides jsonb,  -- per-task model selection
        enabled_tools text[],   -- which tools this agent can use
        enabled_mcps jsonb,     -- MCP server configs
        tool_configs jsonb,     -- per-tool config (calendar rules, vault access, etc.)
        vault_access text[],    -- which vault IDs this agent can read/write
        memory_isolation enum(shared,isolated,read_shared),
        sandbox_level enum(full,restricted,readonly),
        status enum(active,paused,archived),
        created_at, updated_at)
```

**Memory isolation modes**:
- `shared`: Agent reads/writes shared long-term memory. Default for general assistants.
- `isolated`: Agent has its own long-term memory. Diary agent, confidential agent.
- `read_shared`: Agent can read shared memory but writes to its own. Research agent that consumes context but doesn't pollute shared memory.

Examples: Daily Assistant (default, full tools, shared memory), Research Agent (web search + vault, read_shared), Diary Agent (diary vault only, isolated memory), Health Tracker (nutrition/sport tools, isolated).

### 8.2 Admin / Config Tools (Master Chat)

A powerful pattern from OpenClaw: users can configure agents **via conversation** instead of a web UI. The default agent (or a dedicated "admin" agent) has access to **config tools**:

- `update_soul` — Modify an agent's personality/tone. "You're too harsh" → agent updates its own soul.
- `update_instructions` — Modify operating procedures.
- `create_agent` — "I need an agent for health tracking in Signal group X" → creates agent, binds to channel.
- `update_agent_tools` — Enable/disable tools for an agent.
- `update_agent_routing` — Change which channels route to which agents.
- `list_agents` — Show all configured agents and their bindings.

These are **admin-level tools** available only to the default/master agent, gated by a confirmation step ("I'm about to change your diary agent's personality. Confirm?"). Changes take effect on the next session start for the affected agent.

**When soul/instructions change**: The affected agent's next session loads the updated config. No mid-session hot-swap — too risky for context coherence. The agent gets the full updated context (soul + instructions + user profile) at session start, ensuring it has complete context.

### 8.3 Agent Prompt Assembly

On every agent invocation, system prompt assembled from:

```
1. System preamble (DailyWerk platform rules, safety)
2. Agent soul (personality, tone, boundaries)
3. Agent instructions (operating procedures, memory rules)
4. User profile (who the user is, preferences)
5. Tool definitions (filtered by agent's enabled_tools + enabled_mcps)
6. Memory context:
   a. Tier 1: long-term memory entries for this agent (+ shared if mode allows)
   b. Tier 2: today's + yesterday's daily log
   c. Relevant: pgvector search for current query context
7. Session history (recent messages, compacted older ones)
8. Current message
```

### 8.4 Agent Routing

Messages are routed to agents based on channel, thread, and routing rules:

```sql
agent_channel_bindings (id, agent_id, channel enum(signal,telegram,whatsapp,email,web,in_app),
                        channel_account_id,  -- which Signal number, Telegram bot, etc.
                        channel_thread_id,   -- specific group/thread, or NULL for all DMs
                        priority integer,    -- lower = higher priority
                        filter_rules jsonb,  -- keyword triggers, sender filters, etc.
                        created_at)
```

**Routing logic**: On inbound message, find matching bindings (channel + account + thread). If multiple agents match, route to highest priority. For multi-agent routing (message relevant to >1 agent), the primary agent handles the response but can spawn sub-agent sessions for parallel processing.

### 8.5 Session Model

Sessions are the unit of conversation continuity:

```sql
sessions (id, user_id, agent_id,
          channel, channel_thread_id,
          session_type enum(interactive,background,scheduled),
          status enum(active,compacted,archived),
          message_count, token_count,
          compact_summary text,
          metadata jsonb,
          started_at, last_activity_at, ended_at)

session_messages (id, session_id, role enum(user,assistant,system,tool),
                  content text,
                  tool_name, tool_result text,
                  token_count integer,
                  pruned boolean default false,
                  created_at)
```

**Lifecycle**:
1. **Creation**: New session per new context (channel+thread+agent combination).
2. **Continuation**: Messages in same context append to existing session.
3. **Compaction**: When approaching context limit: (a) prune old tool results first, (b) flush important facts to memory, (c) summarize older messages into `compact_summary`, (d) replace summarized messages. User/assistant message content preserved in DB for replay/search, marked as compacted.
4. **Archival**: Inactive >7 days → archived. Searchable but not loaded into context.
5. **Routing**: Each channel+thread maps to exactly one session per agent. Signal doesn't bleed into Telegram.

**Session replay**: Archived sessions remain fully searchable. Admin dashboard shows session timeline. Useful for debugging agent behavior.

### 8.6 Memory Architecture

**Critical distinction**: Agent memory ≠ user vault data.

```
┌─────────────────────────────────────────────────────────┐
│  AGENT MEMORY (PostgreSQL only)                        │
│  Private to agent(s). Managed by system.               │
│                                                         │
│  Tier 1 — Always loaded:                                │
│    memory_entries table. Curated key facts.             │
│    Per-agent or shared (based on memory_isolation).     │
│    Pro users can edit via dashboard (at their risk).    │
│    Includes long-term memory summaries.                 │
│                                                         │
│  Tier 2 — Daily context:                                │
│    daily_logs table. Auto-written by agent.             │
│    Today + yesterday loaded per session.                │
│    NOT in vault — internal agent utility.               │
│    Background cleanup: consolidate → promote to Tier 1. │
│                                                         │
│  Session history:                                       │
│    session_messages table. Searchable.                  │
│    NOT in vault. Compacted over time.                   │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  USER VAULT DATA (S3 + pgvector index)                 │
│  Owned by user. Agents read/write per permissions.      │
│                                                         │
│  Diary, research, nutrition logs, attachments, etc.     │
│  Maintained by users AND agents.                       │
│  Survives agent deletion. Exportable.                  │
│  Searchable via vault_search tool (pgvector + FTS).    │
│                                                         │
│  Daily notes (OpenClaw pattern): agents write to       │
│  vault files like diary/YYYY-MM-DD.md per user rules.  │
│  This is user data, not agent memory.                  │
└─────────────────────────────────────────────────────────┘
```

```sql
-- Agent memory (Tier 1)
memory_entries (id, user_id, agent_id,  -- agent_id NULL = shared
               category enum(fact,preference,rule,summary,relationship),
               content text, source enum(agent,user,system),
               created_at, updated_at)

-- Agent memory (Tier 2)
daily_logs (id, user_id, agent_id, date date,
            content text, created_at, updated_at)
```

**Background memory processes** (GoodJob scheduled):
- **Nightly**: Summarize yesterday's daily logs → promote durable facts to Tier 1.
- **Weekly**: Review Tier 1 entries → consolidate, deduplicate, prune stale facts.
- **Session cleanup**: Archive old sessions, prune tool results from archived sessions.
- **Memory index**: Re-index memory entries for search (keyword + semantic).

### 8.7 Agent Tools

Tools are capabilities. Configurable per agent via `enabled_tools`.

**Core tools** (always available):
- `notes` — Agent scratch pad. **PostgreSQL only**, not persisted to vault. Ephemeral within session for agent's working memory.
- `memory_search` — Search agent memory (Tier 1 + Tier 2 + session history). PostgreSQL only.
- `memory_write` — Write to today's daily log (Tier 2) or long-term memory (Tier 1).
- `send_message` — Send via messaging gateway.

**Vault tools** (configurable per agent, per vault):
- `vault_read` / `vault_write` / `vault_list` — Operate on user vault files (local checkout).
- `vault_search` — Hybrid search across vault files (pgvector + FTS). Separate from `memory_search`.

**Integration tools** (configurable per agent):
- `email_read` / `email_send` / `email_label` / `email_archive` — Full Gmail operations.
- `calendar_read` / `calendar_create` / `calendar_update` — Google Calendar (user's rules applied).
- `todo_create` / `todo_update` / `todo_complete` / `todo_list` — User-facing tasks.
- `web_search` — Brave Search API.

**Admin tools** (master agent only):
- `update_soul` / `update_instructions` / `create_agent` / `update_agent_tools` / `update_agent_routing` / `list_agents` — See §8.2.

**Extensibility**: MCP servers configurable per agent via `enabled_mcps`. Custom tools addable as MCP endpoints.

---

## 9. Data Model (Core Tables)

All IDs UUIDv7. All tables with `user_id` have RLS.

```sql
-- Core
users (id, workos_id, email, plan_id, vault_encryption_key_enc,
       stripe_customer_id, stripe_subscription_id,
       status enum(pending,active,suspended,cancelled),
       settings jsonb, created_at)
plans (id, name, monthly_credits, price_cents, stripe_price_id, features jsonb)

-- Credits
credit_balances (user_id PK, balance bigint, updated_at)
credit_transactions (id, user_id, amount, type, provider, model,
                     tokens_in, tokens_out, latency_ms,
                     provider_cost_cents, credits_charged,
                     metadata jsonb, created_at)

-- Agents
agents (id, user_id, name, slug, is_default, soul text, instructions text,
        identity jsonb, model_overrides jsonb, enabled_tools text[],
        enabled_mcps jsonb, tool_configs jsonb, vault_access text[],
        memory_isolation, sandbox_level, status, created_at, updated_at)
agent_channel_bindings (id, agent_id, channel, channel_account_id,
                        channel_thread_id, priority, filter_rules jsonb, created_at)

-- Sessions
sessions (id, user_id, agent_id, channel, channel_thread_id,
          session_type, status, message_count, token_count,
          compact_summary text, metadata jsonb,
          started_at, last_activity_at, ended_at)
session_messages (id, session_id, role, content text,
                  tool_name, tool_result text,
                  token_count, pruned boolean, created_at)

-- Agent Memory
memory_entries (id, user_id, agent_id, category, content text,
               source, created_at, updated_at)
daily_logs (id, user_id, agent_id, date, content text, created_at, updated_at)

-- Tasks
tasks (id, user_id, agent_id, title, description, status, priority,
       due_date, labels text[], source, external_id, external_provider,
       external_updated_at, metadata jsonb, created_at, updated_at)

-- Vaults
vaults (id, user_id, name, slug, vault_type enum(obsidian,native),
        encryption_key_enc, max_size_bytes, status, created_at)
vault_files (id, vault_id, user_id, path, content_hash, size_bytes,
             last_modified, indexed_at)
vault_chunks (id, vault_id, user_id, file_path, chunk_idx, content text,
              tsv tsvector, embedding vector(1536), metadata jsonb, updated_at)

-- Calendar
calendar_events (id, user_id, agent_id, title, description,
                 start_at, end_at, all_day boolean,
                 external_id, external_provider enum(google,caldav),
                 external_calendar_id, external_updated_at,
                 metadata jsonb, created_at, updated_at)

-- Integrations
integrations (id, user_id, provider, credentials_encrypted,
              config jsonb, status, metadata jsonb)

-- Messaging Bridges
bridges (id, user_id, channel, bridge_type enum(builtin,self_hosted,managed),
         api_key_hash, webhook_url, host_url,
         status enum(provisioning,healthy,unhealthy,deprovisioned),
         managed_server_id, managed_server_ip, phone_number,
         last_health_check_at, created_at)
bridge_events (id, bridge_id, event_type, metadata jsonb, created_at)
```

---

## 10. Deployment Architecture (MVP)

```
┌─────────────────────────────────────────────────────────┐
│  DailyWerk Core (Hetzner Dedicated / VPS)               │
│                                                         │
│  Nginx (+TLS) → Rails API (Falcon) + GoodJob Workers   │
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

## 11. Open Questions / Remaining Design Work

1. **Session quality & robustness** — The most complex subsystem. Needs detailed design for: smart compaction algorithms (what to keep vs summarize), session replay for debugging, long message summarization before sending to LLM, message searchability across sessions, short-term vs daily vs long-term memory promotion heuristics, background cleanup scheduling. Heavily research existing implementations (OpenClaw session management, LangChain/LlamaIndex memory modules, production chatbot architectures). Priority for next design phase.

2. **Vault cold-start latency** — Large vaults (5-10GB) re-checkout from S3 could take minutes. MVP: keep all test users warm, monitor. Solve when real usage data exists.

3. **Multi-vault pricing** — Additional vaults as paid feature. Pricing TBD. Architecture supports it (vaults table, per-vault encryption, per-agent vault_access).

4. **SMTP/IMAP implementation** — Post-MVP but architecture should not preclude it. EmailProcessor worker needs to be provider-agnostic from the start.

5. **CalDAV write support** — Read-only .ics feed for MVP. Full CalDAV server for bidirectional sync is significant effort (RFC 4791). Evaluate `cervicale` gem or custom Rack middleware when demand exists.

6. **External sync conflict resolution** — Last-write-wins with external-preference is the MVP strategy. May need user-facing conflict UI for edge cases (agent and user both modified same event simultaneously).
