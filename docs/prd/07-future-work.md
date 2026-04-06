---
type: prd
title: Future Work
domain: planning
created: 2026-03-31
updated: 2026-04-06
status: living
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/02-integrations-and-channels
  - prd/03-agentic-system
  - prd/04-billing-and-operations
  - prd/06-deployment-hetzner
---

# DailyWerk — Future Work

> Living document. Tracks features, improvements, and technical debt identified across PRDs and RFCs but not yet scheduled for implementation. Items move to an RFC when work begins, and are marked done when shipped.
>
> This is not a priority list — it's an inventory. Priority is determined by user demand, technical prerequisites, and business needs.

---

## Vault

| Item | Source | Notes |
|------|--------|-------|
| PDF-to-text pipeline | RFC: Vault Filesystem §2.1 | PDFs stored but not searchable by content. Extract text via `poppler`/`pdf-reader` gem, chunk and embed. |
| JSON Canvas parser | RFC: Vault Filesystem §2.1 | `.canvas` files contain links to other notes (JSON format, open spec). Parse `nodes[].file` references for the backlink graph. |
| Frontend file browser | RFC: Vault Filesystem | Files currently managed via agent tool only. Dashboard needs a tree view, file preview, and upload/download. |
| Multi-language FTS | RFC: Vault Filesystem §12 | tsvector currently hardcoded to `'english'`. Detect language per file and use appropriate PostgreSQL text search config. |
| Vault dashboard file editor | RFC: Obsidian Sync §4.3 | Non-Obsidian users need a way to view and edit vault files in the web UI, not just via the agent. |
| Multi-vault pricing | PRD 01 §8.2 | Additional vaults as paid feature. Architecture supports it (vaults table, per-vault encryption, per-agent `vault_access`). Pricing TBD. |
| Per-file selective snapshot rollback | RFC: Vault Backup §4.2 | `restore_snapshot` accepts `paths:` param, but no UI for file selection yet. Dashboard needs a file picker for selective restore from snapshots. |
| Cross-vault deduplication | RFC: Vault Backup §12 | Same attachment stored in two vaults = double S3 cost. Content-addressable storage layer could deduplicate. |
| Version diff view | RFC: Vault Backup §12 | Users can restore versions but can't see what changed. Generate and cache unified diffs between consecutive versions. |
| Version annotations from agents | RFC: Vault Backup §12 | `change_summary` on `vault_file_versions` is rarely populated. Agent should provide a brief summary when writing. |
| User-configurable version retention | RFC: Vault Backup §12 | All workspaces get 30 days. Premium plans could have 90-day or unlimited retention. |
| Vault size limit increase | RFC: Vault Filesystem §3.3 | MVP limit is 2 GB (conservative for 240 GB NVMe). Increase after disk monitoring validates capacity. |
| Obsidian Sync shared vaults | RFC: Obsidian Sync §1 | Multi-user Obsidian Sync vaults. Requires workspace collaboration model. |
| Obsidian Sync MFA support | RFC: Obsidian Sync §12 | `obsidian-headless` supports `--mfa` flag but not yet implemented in DailyWerk. |
| Obsidian Sync container isolation | RFC: Obsidian Sync §7.2 | Post-MVP: run `obsidian-headless` in per-workspace Docker containers with restricted filesystem/network access. |
| Sync failure user notification | RFC: Obsidian Sync §12 | User doesn't know sync is broken. Email/push notification on error status. |
| Sync progress indicator | RFC: Obsidian Sync §12 | Initial sync of large vaults provides no progress feedback. WebSocket progress updates to dashboard. |
| Credential passing via stdin/socket | RFC: Obsidian Sync §12 | Env vars visible to root via `/proc/PID/environ`. Unix domain socket or stdin pipe is more secure. |

---

## Agentic System

| Item | Source | Notes |
|------|--------|-------|
| Tool system / ReAct loop | PRD 03 §3, §6 | Full `AgentRuntime` with tool execution loop. RFC: Agent Session Management designed for future tool extension. |
| ~~Memory architecture (5-layer)~~ | PRD 03 §7 | **Mostly done (2026-04-06).** Layers 1-5 implemented: explicit memories with staged promotion pipeline, conversation archives, user profile synthesis (`user_profiles` table), bounded compaction rewriting, cross-agent archive sharing, deterministic session recap, frontend session context card. Remaining: daily logs (Tier 2), memory associations graph. See [RFC: Memory Associations](../rfc-open/2026-04-06-memory-associations.md). |
| Memory associations graph | PRD 03 §7 | (RFC open) Join table linking related memories for cluster retrieval. See [RFC: Memory Associations](../rfc-open/2026-04-06-memory-associations.md). |
| Daily logs | PRD 03 §7 | `daily_logs` table for auto-written agent activity logs. Nightly summarize → promote to memory. Not yet implemented. |
| ~~Compaction~~ | PRD 03 §8 | **Done.** Context-window compaction ships at 75% estimated usage. See [RFC: Agent Session Management](../rfc-done/2026-03-31-agent-session-management.md). |
| Multi-agent routing / handoffs | PRD 03 §4 | `HandoffTool` for inter-agent delegation. `agent_channel_bindings` for message routing. |
| ~~Smart session rotation~~ | RFC: Agent Session Management D9 | **Done** — inline rotation in `Session.resolve` based on configurable inactivity timeout (default 4h). |
| ~~Cross-session structured memory (Level 3)~~ | RFC: Agent Session Management D10, PRD 03 §7 | **Done (2026-04-06).** `MemoryExtractionJob` extracts facts after each response into staged `memory_entries`. `MemoryConsolidationJob` promotes/deduplicates nightly. `MemoryRetrievalService` injects promoted memories at context-build time. `ProfileSynthesisJob` synthesizes user profile. Deterministic session recap always references previous conversation. |
| Confidential/isolated sessions | RFC: Simple Chat §2 | Diary agent sessions with privacy boundary. Separate from shared memory pool. |
| Agent sidebar (multi-agent UI) | RFC: Simple Chat §2 | Sidebar lists agents, not conversations. Clicking an agent opens its current session. |
| Provider failover | PRD 03 §13.3 | LLM router falls back to OpenRouter when primary provider fails. |
| Handoff cycle detection | PRD 03 §13.4 | Validate acyclicity of `handoff_targets` at agent save time (topological sort or DFS). |
| Parallel agent execution | PRD 03 §9 | `ParallelAgentExecutor` with `Async::Semaphore` for fan-out to multiple agents. |
| `instructions_path` ERB templates | RFC: Agent Config §5 | Deferred — ERB is full Ruby execution, security risk. Consider Liquid if needed. |
| Agent CRUD REST API | PRD 03 §2 | `Api::V1::AgentsController` for dashboard agent management. |
| Exa neural search provider | RFC: Web Search Tool §Context | Alternative to Brave Search with semantic/neural search via own embeddings index (~$5/1K queries). Could complement Brave for research-heavy agents. Implement as a `SearchProvider` behind the existing interface. |
| OpenAI Responses API server-side compaction | RFC: Agent Session Management | Uses `previous_response_id` for efficient context management. |

---

## Messaging & Channels

| Item | Source | Notes |
|------|--------|-------|
| WhatsApp bridge | PRD 02 §1 | Meta Cloud API. Requires Meta Business Manager, phone verification, message templates. 4-6 week Meta approval. |
| Managed Signal Bridge | PRD 02 §1 | Auto-provision Hetzner VPS, deploy bridge image via cloud-init, health monitoring. ~€5/mo add-on. |
| Pooled Signal infrastructure | PRD 02 §1 | Layer 3: shared signal-cli infrastructure. Users don't know which layer serves them. |
| Multi-provider bridge instances | RFC: Messaging Gateway | One bridge process serving multiple accounts of the same channel type. Deferred — complicates key management. |
| Group-level trust for bridges | RFC: Messaging Gateway | Trust all members of a specific group. V1 resolves per-sender only. |
| Inbound email rule-based routing | RFC: Inbound Email §6 | Route specific senders/subjects to specific agents. Deferred until multi-agent ships. |
| Inbound email per-agent addresses | RFC: Inbound Email §10 | `{agent-slug}.{workspace_token}@in.dailywerk.com`. Deferred — single address simpler for MVP. |
| Inbound email outbound replies | RFC: Inbound Email §10 | Sending email from the inbound address. Requires outbound SMTP, SPF/DKIM. |

---

## Email & Calendar

| Item | Source | Notes |
|------|--------|-------|
| DailyWerk-managed Gmail OAuth | PRD 06 (Gmail Direct) | One-click Gmail connection without user-side GCP setup. Requires annual CASA assessment ($540-4,500/yr). |
| Google RISC events | RFC: Google Integration | Cross-Account Protection push events (token-revoked, sessions-revoked). |
| CalDAV write support | PRD 02 §5 | Full bidirectional CalDAV server (RFC 4791). Significant effort. Evaluate `cervicale` gem. |
| External sync conflict UI | PRD 02 §8.2 | User-facing conflict resolution for edge cases where agent and user both modified same event. |

---

## Billing & Operations

| Item | Source | Notes |
|------|--------|-------|
| Usage tracking & provider cost attribution | PRD 04 §2-4 | (RFC in progress) Provider pricing, CostCalculator, adapter pattern, usage_records. See [RFC: Usage Tracking](../rfc-open/2026-03-31-usage-tracking-provider-cost.md). |
| Credit system & billing | PRD 04 §3-5 | (RFC in progress) Credit pricing, BudgetEnforcer, Stripe webhooks, margin tracking. Depends on Usage Tracking RFC. See [RFC: Credit System](../rfc-open/2026-03-31-credit-system-billing.md). |
| Rate limiting | PRD 04 §10.1, PRD 01 §8 | Per-workspace requests/minute in Valkey. Per-provider rate limiting for API quotas. |
| Error handling / retry strategy | PRD 04 §10.2 | LLM call failures, provider timeouts, rate limit responses. Provider failover in LLM router. |
| MCP client cross-process invalidation | PRD 04 §10.3 | `Concurrent::Map` cache is process-scoped. Need Valkey pub/sub for Falcon multi-process. |
| ReAct loop JSON failure handling | PRD 04 §10.4 | Retry when LLM outputs invalid tool JSON. Feed parse error back, cap at 3 retries. |
| Credit reservation: Valkey vs Postgres | PRD 04 §10.6 | Evaluate Valkey DECRBY for high-concurrency credit reservation vs Postgres atomic UPDATE. |
| MCP security RFC | PRD 04 §7 | Sandboxing, transport security, tool-level authorization, abuse prevention. |

---

## Platform & Infrastructure

| Item | Source | Notes |
|------|--------|-------|
| Observability design | PRD 01 §8 | Logging, metrics, alerting, health checks, session replay for debugging. |
| GDPR / data deletion | PRD 01 §8 | `WorkspaceDeletionService` for hard-delete across PG, S3, Valkey, vault checkouts. |
| SPA authentication design | PRD 01 §8.7 | React SPA + Rails API shared root domain for HttpOnly/Secure/SameSite cookie-based auth. JWT in localStorage = XSS vector. |
| Connection pooling (PgBouncer) | PRD 01 §8.8 | Falcon at scale needs PgBouncer. Transaction-mode conflicts with session-level SET for RLS. |
| Shared resources / agent sharing | PRD 01 §4.5 | `agent_shares` table for sub-workspace sharing. Layer on top of workspace model. |
| Envelope encryption with KMS | PRD 01 §4.3 | Rails master key → per-workspace DEK → KMS-managed KEK. Prevents data access from DB compromise alone. |
| Webhook idempotency | PRD 02 §8.3 | Bridge webhooks need idempotency keys (dedup by `event_id` or content hash). |
| Prompt injection hardening | PRD 03 §2, Audit 2026-03-31 | Output filtering, sandboxed prompt placement, tool-level auth enforcement. See `/prompt-injection-review` command. |
| Authorization framework | Audit 2026-03-31 | Lightweight authorization (cancancan or action_policy) for debug endpoints, admin features, and future billing. Admin interface now has its own PRD ([08-admin-interface.md](./08-admin-interface.md)). |
| Dependency audit CI | Audit 2026-03-31 | Add `bundler-audit` and `brakeman` to CI pipeline. Currently manual. |

---

## Frontend

| Item | Source | Notes |
|------|--------|-------|
| Component patterns codification | PRD 01 §8.4 | Vite + React + TypeScript + Tailwind + DaisyUI patterns to be codified after more features ship. |
| Agent management dashboard | PRD 03 §2 | Create/edit/delete agents, configure tools, set personality. |
| Usage/billing dashboard | PRD 04 §4 | Per-workspace token usage, cost breakdown by model, credit balance. Minimal stats in [RFC: Usage Tracking](../rfc-open/2026-03-31-usage-tracking-provider-cost.md); full dashboard deferred. |
| GoodJob admin dashboard access | PRD 04 §8 | Mount behind admin auth. Covered in [RFC: Admin Interface Foundation](../rfc-open/2026-04-01-admin-interface-foundation.md). |
| Vault file browser | RFC: Vault Filesystem | Tree view, file preview, upload/download, vault guide editor. |
| Settings pages | RFC: Agent Config | Agent configuration UI, integration management, sync status. |

---

## How to Use This Document

1. **Adding items**: When an RFC or PRD identifies something deferred, add a row here with the source reference.
2. **Starting work**: When an item gets an RFC, add the RFC reference to the Notes column and change the item text to include "(RFC in progress)".
3. **Shipping**: When the RFC is implemented, remove the row. Don't keep shipped items — the RFC and git history are the record.
4. **Grouping**: Items belong under the domain they most naturally fit. Cross-cutting concerns go under Platform & Infrastructure.
