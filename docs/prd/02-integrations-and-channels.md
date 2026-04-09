---
type: prd
title: Integrations & Channels
domain: integrations
created: 2026-03-28
updated: 2026-04-09
status: canonical
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/03-agentic-system
  - prd/04-billing-and-operations
implemented_by:
  - rfc/2026-03-30-messaging-gateway-and-bridge-protocol
  - rfc/2026-03-30-signal-bridge-npm-package
  - rfc/2026-03-31-google-integration
  - rfc/2026-03-31-voice-message-processing
  - rfc/2026-03-31-inbound-email-processing
  - rfc/2026-03-31-imap-smtp-integration
  - rfc/2026-03-31-vault-filesystem
  - rfc/2026-03-31-obsidian-sync
---

# DailyWerk — Integrations & Channels

> Everything that connects DailyWerk to external systems: messaging, email, calendar, vault sync, tasks, search.
> For database schema: see [01-platform-and-infrastructure.md §5](./01-platform-and-infrastructure.md#5-canonical-database-schema).
> For how agents use channels and tools: see [03-agentic-system.md](./03-agentic-system.md).
> For cost tracking of integration calls: see [04-billing-and-operations.md](./04-billing-and-operations.md).

---

## 1. Messaging Gateway & Bridge Protocol

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

### Webhook Security

**Inbound webhook authentication** uses Bearer tokens. For managed bridges, add HMAC signature verification:

- Bridge signs each payload with Ed25519 using a keypair generated during provisioning
- DailyWerk verifies the signature using the bridge's public key
- Timestamp-based replay protection: reject payloads older than 5 minutes
- Source IP validation for managed bridges (known Hetzner VPS IPs)

**Note**: Bearer-token-only auth is acceptable for MVP self-hosted bridges. Managed bridges must use signature verification before GA.

### Channel Types

**In-App Chat** (built-in, WebSocket): Native chat in the DailyWerk dashboard. ActionCable (Rails WebSocket) connects the SPA directly to the agent. No bridge needed — messages go straight to AgentRunner via [03 §9](./03-agentic-system.md#9-streaming-architecture). Primary channel for non-technical users who don't use messengers with the bot.

**Telegram** (built-in bridge): Bot API, webhook mode. User links via `/start` deep link with token. Simplest external integration.

**Telegram encryption note**: Telegram Bot API does **not** support end-to-end encryption. Bot messages use client-server encryption (MTProto) — Telegram servers can technically read them. Secret chats (E2EE) are human-to-human only, not available for bots. This is a fundamental Telegram limitation. Documented clearly for users; recommend Signal for security-sensitive use cases.

**WhatsApp** (built-in bridge, post-MVP): Meta Cloud API. Requires Meta Business Manager, phone number verification, message templates for outbound (24h session window). 4-6 weeks for Meta approval.

**Signal** (external bridge): No official bot API. DailyWerk publishes `dailywerk/signal-bridge` Docker image (open source — no magic, just message routing). Three layers:

*Layer 1 — Self-Hosted (free, technical users)*: User runs Docker image on their infra with DailyWerk API key. User registers dedicated phone number via dashboard.

*Layer 2 — Managed (paid add-on)*: User clicks "Enable Managed Signal" → DailyWerk auto-provisions Hetzner cx22 VPS, deploys bridge image via cloud-init, injects credentials. Billed as ~€5/mo add-on via Stripe (see [04 §1](./04-billing-and-operations.md#1-payments--stripe-integration)). Health monitoring every 60s, auto-restart on failure + alert user.

*Layer 3 — Pooled (future)*: Shared signal-cli infrastructure. Same bridge protocol. Users don't know which layer serves them.

**Critical**: Registering a number with signal-cli deregisters it from the user's phone. Dedicated phone number required (prepaid SIM). Very clear in UX.

---

## 2. Channel Adapter Architecture

The channel adapter layer provides a uniform interface for sending messages across different transports. The [AgentRuntime](./03-agentic-system.md#3-agent-runtime-react-loop) uses adapters to deliver responses without knowing the underlying transport.

```ruby
# app/services/channel_adapter_registry.rb
module ChannelAdapterRegistry
  ADAPTERS = {
    "web"      => WebChannelAdapter,
    "telegram" => TelegramChannelAdapter,
    "api"      => ApiChannelAdapter,
    "signal"   => SignalChannelAdapter
  }.freeze

  def self.resolve(channel_type, config = {})
    ADAPTERS.fetch(channel_type).new(config)
  end
end

# app/adapters/base_channel_adapter.rb
class BaseChannelAdapter
  def initialize(config); @config = config; end
  def send_message(session, content) = raise NotImplementedError
  def send_streaming_chunk(session, chunk) = raise NotImplementedError
  def format_tool_result(result) = result.to_s
end

# app/adapters/web_channel_adapter.rb
class WebChannelAdapter < BaseChannelAdapter
  def send_streaming_chunk(session, chunk)
    ActionCable.server.broadcast(
      "session_#{session.id}",
      { type: "token", content: chunk.content, agent: chunk.model_id }
    )
  end
end

# app/adapters/telegram_channel_adapter.rb
class TelegramChannelAdapter < BaseChannelAdapter
  def send_message(session, content)
    Telegram::Bot::Client.new(@config["bot_token"]).api.send_message(
      chat_id: session.channel.external_id,
      text: content, parse_mode: "Markdown"
    )
  end
end
```

### Session Resolver

Finds or creates the right session for an inbound message:

```ruby
# app/services/session_resolver.rb
class SessionResolver
  def self.resolve(workspace:, agent_slug:, channel_type:, external_id: nil, thread_id: nil)
    channel = Channel.create_or_find_by!(
      workspace: workspace, channel_type: channel_type, external_id: external_id
    )
    agent = Agent.find_by!(slug: agent_slug, workspace: workspace, active: true)

    Session.create_or_find_by!(
      agent: agent, channel: channel, status: "active", thread_id: thread_id
    ) do |s|
      s.workspace = workspace
      s.model_id  = agent.model_id
      s.provider  = agent.provider
    end
  end
end
```

`create_or_find_by!` handles concurrent request races (INSERT-first, rescue-to-SELECT). `thread_id` enables per-thread session isolation for group chats.

---

## 3. Email Integration

DailyWerk provides three email paths, ordered by user effort:

### Inbound Email Forwarding (primary, zero-setup)

Each workspace gets a unique inbound email address (`{workspace_token}@in.dailywerk.com`). Users forward content to the address; the agent processes it. Sender allowlist prevents abuse. No credentials, no OAuth, no setup beyond knowing the address. Works with every email provider.

See [RFC: Inbound Email Processing](../rfc-open/2026-03-31-inbound-email-processing.md).

### IMAP/SMTP (active email access, user-provided credentials)

For agent-initiated email operations (read inbox, send as user). User provides IMAP/SMTP server credentials (host, port, username, password/app-password). Provider-agnostic — works with Gmail (app passwords), Outlook, Fastmail, ProtonMail Bridge, self-hosted mail servers. Credentials stored encrypted (see [01 §5.9](./01-platform-and-infrastructure.md#59-integration-tables)).

See [RFC: IMAP/SMTP Integration](../rfc-open/2026-03-31-imap-smtp-integration.md).

### Gmail API via BYOA OAuth (power users)

Users create their own Google Cloud project and supply OAuth credentials to DailyWerk. This bypasses Google's CASA verification requirement (which blocks DailyWerk-managed Gmail OAuth). Full Gmail API access: read, send, label, archive, search. Push notifications via Google Pub/Sub.

See [RFC: Google Integration](../rfc-open/2026-03-31-google-integration.md).

### Gmail API via DailyWerk-Managed OAuth (future)

Deferred until user base justifies the annual CASA security assessment ($540–4,500/year). One-click Gmail connection without user-side GCP setup.

See [PRD 06: Gmail Direct Integration](./06-gmail-direct-integration.md).

**Design note**: `EmailService` provides a provider-agnostic interface — agent tools (`email_read`, `email_send`, etc.) work identically regardless of whether the backend is IMAP/SMTP or Gmail API.

---

## 4. Obsidian Vault Sync

> **Status:** ✅ Implemented. See [RFC: Vault Filesystem](../rfc-done/2026-03-31-vault-filesystem.md) for the data layer and [RFC: Obsidian Sync](../rfc-done/2026-03-31-obsidian-sync.md) for the sync integration. Frontend file browser available at `/vault`.

### S3 as Source of Truth, Disk as Working Copy

```
User's Obsidian App (phone/desktop)
         │ (Obsidian Sync protocol)
   Obsidian Cloud
         │ (obsidian-headless sync --continuous)
   DailyWerk Server: /data/workspaces/{workspace_id}/vaults/   ← local checkout
         │
         ├──▶ Agent reads/writes files here
         ├──▶ EmbeddingWorker indexes changes → pgvector
         │
         ▼ (VaultSyncWorker, every 5min + inotify)
   Hetzner S3: workspaces/{workspace_id}/vaults/   ← encrypted canonical store (SSE-C)
```

**Obsidian Headless** (official CLI, released Feb 2026): Headless client for Obsidian Sync. Requires Node.js 22+. Supports bidirectional sync, pull-only, and mirror-remote modes. Runs continuous sync watching for changes. Enables server-side vault synchronization without the desktop app.

### Consistency Guarantees

1. **S3 always latest**: VaultSyncWorker diffs local→S3 by content hash (every 5min + on inotify file change). One-way mirror. Agents write to local checkout; VaultSyncWorker pushes to S3.
2. **pgvector always current**: EmbeddingWorker triggered by inotify. Re-chunks and re-embeds changed files. `vault_files.content_hash` skips unchanged files. See [01 §5.6](./01-platform-and-infrastructure.md#56-vault-tables) for schema.
3. **Correct user on correct server**: MVP single-server = all active users checked out. Scale: Valkey checkout lock (`user:{id}:checkout_server = server-3`), request routing to locked server.
4. **Disk space**: LRU eviction for inactive users (>24h no triggers). S3 retains everything. Re-checkout on next trigger. Max 10GB/user enforced at VaultSyncWorker level. Monitoring + alerts.
5. **Cold start**: Pull full vault from S3, then start `obsidian-headless sync` on top. MVP: keep all test users warm, monitor, solve later.

### Non-Obsidian Users

Identical mechanism minus `obsidian-headless sync`. DailyWerk-native vault: markdown files in S3, simple read-only viewer in dashboard. Can connect Obsidian later to the same vault directory + start sync (may produce conflicts, user is warned).

### Multi-Vault (future)

Users may have multiple vaults (e.g., personal, work). Additional pricing TBD. Each vault = separate S3 prefix + separate local checkout + separate pgvector partition. Agent `tool_configs` specify which vault(s) they can access (see `vault_access` in [01 §5.3](./01-platform-and-infrastructure.md#53-agent-tables)).

**Obsidian Sync cost**: User's own subscription (~$4/mo). DailyWerk does not pay. Documented as prerequisite for Obsidian users.

---

## 5. Calendar

### Google Calendar API (primary)

OAuth 2.0 via DailyWerk-managed credentials (sensitive scopes only — no CASA required). Bidirectional sync with incremental updates via sync tokens and push notifications via HTTPS webhooks. DailyWerk stores its own calendar entries in PostgreSQL (see [01 §5.7](./01-platform-and-infrastructure.md#57-task--calendar-tables)). User-configurable rules per agent: which Google Calendar to target (personal, work, shared), default duration, reminders, color coding.

See [RFC: Google Integration](../rfc-open/2026-03-31-google-integration.md).

### CalDAV Export (read-only, for non-Google users)

DailyWerk exposes a CalDAV-compatible read-only endpoint per user (`https://api.dailywerk.com/caldav/{caldav_token}/`). Any CalDAV-compatible app (Apple Calendar, Thunderbird, Nextcloud) can subscribe and see DailyWerk-managed events. This is a **read-only feed** — events created in external apps don't sync back. Users get an .ics subscription URL as a simpler alternative.

Uses an opaque, per-user CalDAV token (not user_id) to prevent IDOR. Token is regeneratable by the user via dashboard.

### CalDAV Write Support (post-MVP)

Full CalDAV server implementation (e.g., via `cervicale` gem or custom Rack middleware). Enables bidirectional sync with any calendar app. Significant effort (RFC 4791). Evaluate when demand exists.

---

## 6. Tasks / Todos

### Internal Agent Tasks (ephemeral)

Scratch work during agentic loops. Live in session context, discarded when session ends. Not persisted to the tasks table.

### User-Facing Tasks (persistent, synced)

Stored in the `tasks` table (see [01 §5.7](./01-platform-and-infrastructure.md#57-task--calendar-tables)). Created by agents, users, or synced from external providers.

### External Sync Conflict Handling

Last-write-wins with conflict detection. On each sync cycle (TodoSyncWorker, GoodJob cron every 2min):

1. Pull changes from external provider since last sync.
2. Compare `external_updated_at` with local `updated_at`.
3. If external is newer → update local. If local is newer → push to external. If both changed → external wins (user explicitly edited in their app), log conflict for review.
4. Same strategy for calendar sync — external user edits take precedence over agent-generated events.

---

## 7. Data Search & Retrieval Layer

### 7.1 Two Search Domains

**Agent memory** (PostgreSQL only): Session history, memory entries, agent notes. Private to agents. Searched via `memory_search` tool (see [03 §6](./03-agentic-system.md#6-tool-system)).

**User data / vault** (S3-backed, pgvector-indexed): Vault files, diary entries, research notes. Owned by user, read/written by agents. Searched via `vault_search` tool.

These are separate search spaces with separate tools. An agent can search both, but the distinction matters for privacy and data lifecycle.

### 7.2 Hybrid Search in PostgreSQL

The `vault_chunks` table (see [01 §5.6](./01-platform-and-infrastructure.md#56-vault-tables)) supports both keyword and semantic search:

- **Keyword**: `ts_rank()` over `tsv tsvector` column (GIN index)
- **Semantic**: `1 - (embedding <=> query_embedding)` cosine similarity (HNSW index)
- **Fusion**: Combined via Reciprocal Rank Fusion (RRF) — `score = Σ 1/(k + rank)` with k=60

All queries scoped by `workspace_id` (RLS).

```ruby
# Hybrid search combining semantic + keyword via RRF in SQL
def hybrid_search(workspace, query, limit: 5)
  embedding = RubyLLM.embed(query).vectors

  VaultChunk.find_by_sql([<<~SQL, { embedding: embedding, query: query, workspace_id: workspace.id, k: 60, limit: limit }])
    WITH semantic AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> :embedding) AS rank
      FROM vault_chunks
      WHERE workspace_id = :workspace_id
      ORDER BY embedding <=> :embedding
      LIMIT :limit * 3
    ),
    fulltext AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY ts_rank(tsv, plainto_tsquery('english', :query)) DESC) AS rank
      FROM vault_chunks
      WHERE workspace_id = :workspace_id AND tsv @@ plainto_tsquery('english', :query)
      LIMIT :limit * 3
    ),
    rrf AS (
      SELECT COALESCE(s.id, f.id) AS id,
             COALESCE(1.0 / (:k + s.rank), 0) + COALESCE(1.0 / (:k + f.rank), 0) AS score
      FROM semantic s
      FULL OUTER JOIN fulltext f ON s.id = f.id
    )
    SELECT vault_chunks.* FROM rrf
    JOIN vault_chunks ON vault_chunks.id = rrf.id
    ORDER BY rrf.score DESC
    LIMIT :limit
  SQL
end
```

### 7.3 Indexing Pipeline

File change (inotify from local checkout or agent write) → EmbeddingWorker: read → markdown-aware chunk (respect headings, paragraphs, code blocks) → generate tsvector → call OpenAI `text-embedding-3-small` (1536 dims) → upsert `vault_chunks` → track credit cost (see [04 §4](./04-billing-and-operations.md#4-token--cost-tracking)).

### 7.4 Scaling Path

pgvector handles ~1M vectors with HNSW. Per-workspace vault = <50k chunks typically. At 10k+ users: partition `vault_chunks` by `workspace_id` → OpenSearch with filtered aliases → dedicated vector DB.

---

## 8. Open Questions

1. **CalDAV write support** — Read-only .ics feed for MVP. Full CalDAV server for bidirectional sync is significant effort (RFC 4791). Evaluate `cervicale` gem or custom Rack middleware when demand exists.
2. **External sync conflict resolution** — Last-write-wins with external-preference is the MVP strategy. May need user-facing conflict UI for edge cases (agent and user both modified same event simultaneously).
3. **Webhook idempotency** — Inbound bridge webhooks need idempotency keys (message dedup by `event_id` or content hash). Stripe webhooks need `processed_stripe_events` table — see [04 §1](./04-billing-and-operations.md#1-payments--stripe-integration).
4. **Inbound email service selection** — Postmark vs Mailgun for receiving forwarded emails. Both work; Postmark is simpler. See [RFC: Inbound Email Processing](../rfc-open/2026-03-31-inbound-email-processing.md).
