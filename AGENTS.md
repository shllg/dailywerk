# AGENTS.md — AI Agent Configuration for DailyWerk

## Non-Negotiables

1. Fiber safety: Falcon means no blocking I/O, no `Thread.current`, no lazy mutex init.
2. GoodJob external mode: never inline or async execution. Workers run as a separate process.
3. UUIDv7: all new tables use `id :uuid, default: -> { "gen_random_uuid_v7()" }`.
4. Strong parameters: explicit `permit` allowlists on every controller action.
5. Package managers: `bundler` (backend), `pnpm` (frontend). Never yarn/npm.
6. Git safety: never auto-commit or push.
7. YARD docs: add concise YARD comments to new or changed Ruby classes/modules and non-trivial public methods. Keep them short and easy for junior devs to follow.

## Operating Order

1. Read relevant files and rules before editing.
2. Apply rules from `.claude/rules/` for the changed area.
3. Match existing architecture and naming patterns.
4. Run tests for changed behavior (`bundle exec rails test` / `cd frontend && pnpm test`).
5. Run static checks (`bundle exec brakeman`, `bundle exec rubocop`).

## Dev Environment

- Ruby 4.0.2, Rails 8.1.3
- Node >= 22 (for frontend + Obsidian Headless)
- PostgreSQL 17 + pgvector, Redis 7
- Falcon (API server) + GoodJob (external worker) + Vite (frontend dev)
- Docker Compose for local services: `docker compose up -d`
- Start all: `bin/dev` (Procfile.dev: falcon + good_job + vite)
