# DailyWerk — Personal AI Assistant SaaS

AI-powered personal assistant with conversational agents, vault sync, and multi-channel messaging. Rails 8.1 API + React 19 SPA monorepo.

## Core Non-Negotiables

- **NEVER use thread-based patterns** — Falcon uses fibers. No `Thread.current`, no `Mutex.new` lazy init, no blocking I/O.
- **NEVER run GoodJob in inline or async mode** — External mode only (separate worker process).
- **NEVER run** `git add`, `git commit`, `git push`, `git reset`, `git checkout` — suggest only.
- **ALWAYS use UUIDv7** for all new table primary keys: `id :uuid, default: -> { "gen_random_uuid_v7()" }`.
- **ALWAYS use strong parameters** — never `permit!`, always explicit allowlists.
- **ALWAYS use `pnpm`** for frontend packages (never yarn/npm).
- **ALWAYS add concise YARD comments** to new or changed Ruby classes/modules and non-trivial public methods. Keep them short and junior-readable.

## Tech Stack

**Backend:** Rails 8.1.3, Ruby 4.0.2, Falcon (fiber-based), PostgreSQL 17 + pgvector
**Frontend:** Vite 8 + React 19 + TypeScript 5.9 + Tailwind CSS 4.2 (SPA in `frontend/`)
**Jobs:** GoodJob (external mode only — separate worker process, never inline/async)
**Cache/Realtime:** Valkey 8 (ActionCable pub/sub, rate limiting)
**Auth:** WorkOS (SSO, social login, magic links)
**Payments:** Stripe (subscriptions + metered credits)
**Storage:** Hetzner Object Storage (S3-compatible, SSE-C per-user encryption), RustFS in dev
**LLM:** ruby_llm (provider-agnostic, v1.14+)
**Package manager:** pnpm (frontend), bundler (backend)
**Infrastructure:** Docker Compose for local services (PostgreSQL, Valkey, RustFS, Mailcatcher)

## Architecture Mental Model

```
Vite SPA (React 19) ──→ Falcon ──→ Rails API ──→ PostgreSQL 17 + pgvector
                       ↕ WebSocket (ActionCable)  → Valkey 8 (pub/sub, cache)
                                                  → GoodJob Workers (external)
                                                  → S3 (Hetzner / RustFS)
                                                  → LLM Providers (ruby_llm)
```

## AI MCP Workflow

- **Codex** (`mcp__codex__codex`): Implementation, refactoring, debugging
- **Gemini** (`mcp__gemini__gemini-analyze-code`): Security/performance analysis, second opinions
- **Critical changes**: Use both — Codex for implementation, Gemini for independent review

## Quality Checklist

```bash
bundle exec rails test                    # Minitest (backend)
cd frontend && pnpm test                  # Vitest (frontend)
bundle exec brakeman --quiet              # Security
bundle exec rubocop --autocorrect-all     # Ruby style
bundle exec bundler-audit check --update  # Dependency audit
```

## Monorepo Structure

- Root `/` — Rails 8.1 API backend (bundler)
- `frontend/` — Vite + React 19 SPA (pnpm, separate package.json)
- `docs/prd/` — Product requirements (architecture plans, not implemented code)
- `docs/rfc-open/` — Open RFCs (date-prefixed, design decisions in progress)

## Key References

- `docs/prd/01-platform-and-infrastructure.md` — Stack, schema, deployment
- `docs/prd/02-integrations-and-channels.md` — Bridges, vault sync, search
- `docs/prd/03-agentic-system.md` — Agent runtime, memory, tools, streaming
- `docs/prd/04-billing-and-operations.md` — Credits, BYOK, GoodJob config, MCP
- `docs/prd/05-ai-developer-tooling.md` — Expectations for Claude Code and Codex
- `docs/rfc-open/2026-03-29-ai-tooling-phase2.md` — Deferred agent/skill/hook config
- `docs/rfc-open/2026-03-29-simple-chat-conversation.md` — First chat conversation implementation

## Claude Code Configuration

**Rules** (`.claude/rules/`) — auto-loaded, conditional by path:

| Rule | Content | Loading |
|------|---------|---------|
| `00-core` | Architecture, MUST/NEVER, project identity | Always |
| `01-fiber-safety` | Falcon fiber patterns, unsafe/safe table | Conditional: `app/**`, `lib/**` |
| `02-architecture` | Code placement, service objects, fat model/skinny controller | Always |
| `03-data-conventions` | UUIDv7, strong_migrations, indexes, N+1 | Conditional: `app/models/**`, `db/migrate/**` |
| `04-security` | Strong params, encryption, injection prevention | Always |

## Dev Environment

```bash
docker compose up -d          # Start PostgreSQL, Valkey, RustFS, Mailcatcher
bin/dev                       # Falcon + GoodJob worker + Vite dev server
bin/rails db:create db:migrate
cd frontend && pnpm install
```
