# AGENTS.md — AI Agent Configuration for DailyWerk

## Non-Negotiables

1. **Fiber safety**: Falcon uses fibers. No `Thread.current`, no lazy mutex init (`@mutex ||= Mutex.new`), no blocking I/O (`Net::HTTP`, `sleep`). Use `Fiber[:key]` or `CurrentAttributes` for request context, `Concurrent::Map` for shared mutable state, `async-http-faraday` for HTTP.
2. **GoodJob external mode only**: Never inline or async execution. Workers run as a separate process. LLM HTTP calls only in GoodJob workers, never in the Falcon request cycle.
3. **UUIDv7**: All new tables use `id :uuid, default: -> { "gen_random_uuid_v7()" }`. FK columns also `type: :uuid`.
4. **Strong parameters**: Explicit `permit` allowlists on every controller action. Never `permit!`.
5. **Package managers**: `bundler` (backend), `pnpm` (frontend). Never yarn/npm.
6. **Git safety**: Never auto-commit or push. Suggest only.
7. **YARD docs**: Add concise YARD comments to new or changed Ruby classes/modules and non-trivial public methods. Keep them short and junior-readable.
8. **Workspace isolation**: Every workspace-owned model includes `WorkspaceScoped`. Every workspace-scoped job includes `WorkspaceScopedJob`. Every workspace-owned table gets an RLS policy via `RlsMigrationHelpers`.

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

## Architecture — Code Placement

| What | Where | Pattern |
|------|-------|---------|
| Data + validations + scopes | `app/models/` | ActiveRecord, UUIDv7 PKs |
| Shared model behavior | `app/models/concerns/` | `ActiveSupport::Concern` |
| Business logic | `app/services/` | Service objects, single responsibility |
| API endpoints | `app/controllers/api/v1/` | Skinny controllers, strong params, JSON only |
| Background work | `app/jobs/` | GoodJob, idempotent, with timeouts |
| WebSocket channels | `app/channels/` | ActionCable channels |
| JSON serialization | `app/serializers/` | Response shaping |
| React components | `frontend/src/components/` | TypeScript + Tailwind |
| React pages/routes | `frontend/src/pages/` | React Router |
| Custom hooks | `frontend/src/hooks/` | Reusable React hooks |
| API client functions | `frontend/src/services/` | Typed fetch wrappers |
| TypeScript types | `frontend/src/types/` | Shared type definitions |

**Fat model / skinny controller.** Controllers: auth, params, service call, render. Models: validations, scopes, associations. Service objects for multi-step business logic — avoid ActiveRecord callbacks for complex workflows.

## Frontend SPA Conventions

- Keep the SPA chat-first. New navigation must not break the `/chat` flow.
- Use `react-router` for app navigation and routed layouts.
- Keep one React component per file. If a file starts accumulating helper components, split them.
- Move non-visual logic into `hooks/`, `config/`, `services/`, or `types/` instead of burying it inside JSX files.
- Prefer pure render logic over unnecessary effects. Use `useEffect` only for real external synchronization.
- Small, focused files beat monolithic screen components. Route pages should mostly compose reusable components.

## Workspace Isolation

Two-layer defence: `WorkspaceScoped` default_scope (application) + PostgreSQL RLS policy (database).

**WorkspaceScoped concern** — include on every model with a `workspace_id` column:
- Adds `default_scope` filtered by `Current.workspace` (returns `none` when nil, `all` when `Current.skip_workspace_scoping?`)
- Adds `belongs_to :workspace` + presence validation
- Sets `workspace` from `Current.workspace` on `before_validation` (create only)
- `workspace_id` is immutable after create

**WorkspaceScopedJob concern** — include on every job that reads/writes workspace-owned records:
- Always accept `workspace_id:` as a keyword argument (raises `ArgumentError` if missing)
- The concern sets `Current.workspace`, `Current.user`, and `app.current_workspace_id` PG session var before `perform`, resets on exit

**RlsMigrationHelpers** — use in every migration creating a workspace-owned table:
- `enable_workspace_rls!(table)` — direct `workspace_id` column
- `enable_parent_rls!(table, parent_table:, parent_fk:)` — inherits via parent FK
- Always wrap in `safety_assured { }` (strong_migrations cannot analyse DDL)

**Cross-workspace jobs**: Use `Current.without_workspace_scoping { }` — never `unscoped`.

## LLM Patterns

`AgentRuntime` is the single entry point for all agent LLM calls. Never call `session.ask` directly from outside `AgentRuntime`.

**AgentRuntime flow:**
1. `enqueue_compaction_if_needed` — check `context_window_usage >= 0.75`
2. `ContextBuilder.new(session:, agent:).build` — assemble system prompt
3. `session.with_model(agent.model_id, provider: ...)` → `.with_runtime_instructions(...)` → `.ask(message, &stream_block)`

**MUST / NEVER:**
- Use `with_runtime_instructions` (in-memory) not `with_instructions` (persists a Message row) in hot paths
- Resolve `context_window_size` from `model.context_window` column — not metadata JSONB
- Append to `session.summary` with `\n\n---\n\n` separator, never overwrite
- Never hardcode model names — read from `agent.model_id` or `agent.params`
- All LLM HTTP calls in GoodJob workers only — never in the Falcon request cycle

**Compaction** fires at 75% context usage. `CompactionService` keeps the newest 10 messages, summarizes the rest, marks compacted with `compacted: true`, and appends to `session.summary`.

## Data Conventions

- UUIDv7 PKs on all tables; `type: :uuid` on all FK columns
- `strong_migrations` gem — prevents unsafe DDL; all migrations must be reversible
- Index every FK and every column used in WHERE clauses
- Concurrent indexes on existing tables: `add_index :table, :col, algorithm: :concurrently`
- N+1: use `includes` / `preload`; prefer named scopes over raw `where` chains in controllers

## Security

- Strong params with explicit `permit` allowlists — never `permit!`
- `ActiveRecord::Encryption` (non-deterministic) for API keys and credentials
- WorkOS for auth (SSO, social login, magic links) — token-based, no cookies = no CSRF
- Never interpolate user input into SQL strings
- Never raw `constantize` on user input — maintain allowlists

## Background Jobs

GoodJob external mode only. Two job types:

| Type | Concern | Arguments |
|------|---------|-----------|
| Workspace-scoped | `WorkspaceScopedJob` | positional args + `workspace_id:` keyword |
| Cross-workspace (cron) | none | no workspace context |

Concurrency: use `GoodJob::ActiveJobExtensions::Concurrency` with a dynamic key — never PostgreSQL advisory locks.
All jobs must be idempotent. Add `discard_on ActiveRecord::RecordNotFound` to jobs that look up a record by ID.
Use `find_each` for batch processing — never load unbounded collections into memory.
Register cron jobs in `config/initializers/good_job.rb`.

**Queue names:** `:llm` for `ChatStreamJob`, `:default` for everything else.

## Testing

Minitest only. No RSpec. No FactoryBot. No mocking gems. No fixture YAML files.

Tests run in parallel (`parallelize(workers: :number_of_processors)`) — all setup must be parallel-safe.

**Record creation:**
```ruby
user, workspace = create_user_with_workspace
# Multiple workspaces in one test need unique identifiers:
user2, ws2 = create_user_with_workspace(
  email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
  workspace_name: "Other"
)
```
Always use `SecureRandom.hex(4)` in slugs and emails.

**Workspace scoping:**
```ruby
with_current_workspace(workspace, user:) do
  agent = Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "Test", model_id: "gpt-5.4")
  assert_equal 1, Agent.count
end
```

**Stubbing:** `define_singleton_method` only. Always capture original and restore in `ensure`.

**Job tests:** Include `ActiveJob::TestHelper`, set `queue_adapter = :test` in setup, clear jobs in teardown.

**Controller tests:** Inherit from `ActionDispatch::IntegrationTest`. Pass `api_auth_headers(user:, workspace:)` on every request.

## Operating Order

1. Read relevant files and rules before editing.
2. Apply rules for the changed area (models, services, jobs, migrations, tests).
3. Match existing architecture and naming patterns.
4. Run tests for changed behavior (`bundle exec rails test` / `cd frontend && pnpm test`).
5. Run static checks (`bundle exec brakeman`, `bundle exec rubocop`).

## Quality Checklist

```bash
bundle exec rails test                    # Minitest (backend)
cd frontend && pnpm test                  # Vitest (frontend)
bundle exec brakeman --quiet              # Security
bundle exec rubocop --autocorrect-all     # Ruby style
bundle exec bundler-audit check --update  # Dependency audit
```

## Dev Environment

- Ruby 4.0.2, Rails 8.1.3
- Node >= 22 (for frontend + Obsidian Headless)
- PostgreSQL 17 + pgvector, Valkey 8
- Falcon (API server) + GoodJob (external worker) + Vite (frontend dev)
- Docker Compose for local services: `docker compose up -d`
- Start all: `bin/dev` (Procfile.dev: falcon + good_job + vite)

## Key References

- `docs/prd/01-platform-and-infrastructure.md` — Stack, schema, deployment
- `docs/prd/02-integrations-and-channels.md` — Bridges, vault sync, search
- `docs/prd/03-agentic-system.md` — Agent runtime, memory, tools, streaming
- `docs/prd/04-billing-and-operations.md` — Credits, BYOK, GoodJob config, MCP
- `docs/prd/05-ai-developer-tooling.md` — Expectations for AI coding agents
- `docs/prd/07-future-work.md` — Living inventory of deferred features and technical debt
