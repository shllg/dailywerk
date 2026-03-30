# DailyWerk Core Architecture

> **Purpose:** Foundational facts and essential rules for every task.

## Architecture Mental Model

```
Vite SPA (React 19) ──→ Falcon ──→ Rails API ──→ PostgreSQL 17 + pgvector
                       ↕ ActionCable (WebSocket)  → Valkey 8 (pub/sub, cache)
                                                  → GoodJob Workers (external)
                                                  → S3 (Hetzner / RustFS)
                                                  → LLM Providers (ruby_llm)
```

**Product:** Personal AI assistant SaaS with conversational agents, vault sync, and multi-channel messaging.

## MUST Rules

- **MUST** use UUIDv7 for all new table primary keys
- **MUST** use `strong_migrations` gem for safe DDL changes
- **MUST** use `pnpm` for frontend JS packages (never yarn/npm)
- **MUST** run quality checks before declaring task complete: `rails test`, `brakeman`, `rubocop`

## NEVER Rules

- **NEVER** use thread-based patterns (Falcon uses fibers, see `rules/01-fiber-safety.md`)
- **NEVER** run GoodJob in inline or async mode — external mode only
- **NEVER** use raw `constantize` on user input — allowlist model/class names
- **NEVER** run `git add`, `git commit`, `git push`, `git reset`, `git checkout` (suggest only)

## Monorepo Structure

```
/                  Rails 8.1 API backend (bundler)
├── app/           Models, controllers, services, jobs, channels
├── frontend/      Vite + React 19 SPA (pnpm, separate package.json)
├── docs/prd/      Product requirements (architecture plans, not implemented code)
├── docs/rfc-open/ Open RFCs (date-prefixed, design decisions in progress)
├── config/        Rails configuration
├── db/            Migrations, schema, seeds
└── test/          Minitest test suite
```

## Key References

- `docs/prd/01-platform-and-infrastructure.md` — Stack, schema, deployment
- `docs/prd/02-integrations-and-channels.md` — Bridges, vault sync, search
- `docs/prd/03-agentic-system.md` — Agent runtime, memory, tools, streaming
- `docs/prd/04-billing-and-operations.md` — Credits, BYOK, GoodJob config
