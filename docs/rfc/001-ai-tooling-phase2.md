# RFC 001: AI Developer Tooling — Phase 2 Incremental Configuration

**Status:** Draft
**Created:** 2026-03-29

## Context

DailyWerk's Claude Code and Codex configuration follows a "grow with the code" strategy. Phase 1 (CLAUDE.md, AGENTS.md, 5 rules, basic .codex/) provides the lean foundation. This RFC defines the Phase 2 items — rules, agents, commands, hooks, and skills — that should be added incrementally as the codebase matures.

**Principle:** Never configure rules about patterns that don't exist in the codebase yet. Each item below has a trigger condition that must be met before creation.

## Deferred Rules

### Rule: User Isolation / RLS (`05-user-isolation.md`)

**Trigger:** After RLS middleware is implemented and first 3 RLS-scoped models are committed.

**Content outline:**
- PostgreSQL Row-Level Security pattern: `SET LOCAL app.current_user_id` in middleware
- App connects as `app_user` (non-superuser) to enforce RLS
- All user-scoped tables must have `user_id` foreign key
- RLS context must be set in `around_perform` hook for GoodJob workers
- Storage isolation: per-user S3 prefix, per-user SSE-C encryption key
- Redis key namespacing: `user:{user_id}:*`
- pgvector embeddings always user-scoped

**Why deferred:** RLS middleware, user model, and scoped tables don't exist yet. Rules referencing these patterns would cause AI to hallucinate implementations.

### Rule: LLM Patterns (`06-llm-patterns.md`)

**Trigger:** After ruby_llm gem is added to Gemfile and first agent/chat model is committed.

**Content outline:**
- ruby_llm framework: `RubyLLM::Chat`, `RubyLLM::Agent`, `acts_as_chat`
- BYOK: `RubyLLM.context { |c| c.api_key = user_key }` for per-user isolation
- Agent runtime: ReAct loop, max 25 tool iterations, compaction at 75% context
- Tool system: inherit from `RubyLLM::Tool`, allowlisted model names
- Memory architecture: 5-layer model with token budgets
- Streaming: Falcon fibers + ActionCable for real-time token streaming

**Why deferred:** ruby_llm is not in Gemfile yet. No agent models, tools, or runtime code exists.

### Rule: Frontend Conventions (`07-frontend.md`)

**Trigger:** After 5+ React components exist in `frontend/src/`.

**Content outline:**
- React 19 + TypeScript strict mode conventions
- Tailwind CSS 4 (CSS-first config) + DaisyUI component patterns
- Functional components only, TypeScript interfaces for props
- API calls via typed service functions, not inline fetch
- ActionCable JS client for real-time chat streaming

**Why deferred:** Only bare scaffold (App.tsx, main.tsx) exists. Patterns should emerge from actual development before being codified.

### Rule: Testing Conventions (`08-testing.md`)

**Trigger:** After test suite has 10+ test files.

**Content outline:**
- Minitest patterns and fixtures with UUIDv7 IDs
- RLS test context: always set `app.current_user_id` in test setup
- Cross-user isolation tests: verify user A cannot access user B's records
- GoodJob tests: verify `around_perform` sets RLS context
- Frontend: Vitest + React Testing Library patterns

**Why deferred:** Only one health controller test exists. Testing conventions should emerge from the first wave of real tests.

### Rule: Background Jobs (`09-background-jobs.md`)

**Trigger:** After 3+ job classes exist beyond ApplicationJob.

**Content outline:**
- GoodJob external mode patterns, queue naming (`llm:3`, `embeddings:2`, `maintenance:1`, `default:4`)
- Concurrency controls via `GoodJob::ActiveJobExtensions::Concurrency`
- All jobs must be idempotent and set RLS context in `around_perform`
- Cron job definitions in `config/initializers/good_job.rb`
- LISTEN/NOTIFY for low-latency job pickup

**Why deferred:** Only ApplicationJob and the GoodJob migration exist. Queue structure and concurrency patterns should be designed when actual jobs are created.

## Deferred Agents

### Agent: Code Reviewer (`dailywerk-code-reviewer.md`)

**Trigger:** After core domain is established (User model + RLS + at least 2 domain models + services).

**Content outline:** Read-only agent that reviews uncommitted changes for RLS compliance, fiber safety, UUIDv7 usage, GoodJob conventions, and security. Uses `rails-review` skill.

### Agent: LLM/Agent Expert (`llm-agent-expert.md`)

**Trigger:** After agent runtime is built (ruby_llm integration, AgentRuntime service, at least 2 tools).

**Content outline:** Specialist for ruby_llm patterns, ReAct loop, tool development, memory architecture, compaction, BYOK isolation.

### Agent: Frontend Expert (`react-frontend-expert.md`)

**Trigger:** After frontend patterns solidify (10+ components, established API client pattern, routing).

**Content outline:** React 19 + TypeScript + Tailwind 4 + DaisyUI specialist. Component structure, hook patterns, state management, ActionCable client integration.

## Deferred Commands

### `/dailywerk-review`, `/dailywerk-plan`, `/dailywerk-pr`

**Trigger:** After code-reviewer agent exists and review skill is written.

**Content outline:** Slash commands that invoke primary skill, load conditional skills based on diff content, run mandatory double-review (Codex + Gemini), and produce structured output.

## Deferred Hooks

### PreToolUse: skill-reminder.sh

**Trigger:** After skills exist AND a real development gotcha has been discovered (e.g., unscoped RLS query, fiber-unsafe pattern).

**Content outline:** Maps file paths to relevant skills on Edit/Write operations. Non-blocking advisory output.

**Why deferred:** Hooks on every Edit/Write add latency during rapid scaffolding. The value comes from reminding about gotchas that have actually caused problems, not hypothetical ones.

### PreToolUse: ExitPlanMode review reminder

**Trigger:** After `/dailywerk-review` command exists.

**Content outline:** Reminds to run review before finalizing changes.

## Deferred Skills

| Skill | Trigger |
|-------|---------|
| `rails-model` | After first 3 models with RLS are committed |
| `rails-service` | After first 3 service objects with established patterns |
| `rails-testing` | After test suite conventions are established |
| `rails-review` | After code-reviewer agent is created |
| `react-frontend` | After frontend component patterns solidify |
| `rails-job` | After 3+ job classes with GoodJob patterns |
| `codex-review` | After primary review workflow is established |
| `gemini-review` | After primary review workflow is established |

## Deferred .codex/ Expansion

### Codex prompts and skills

**Trigger:** When Codex CLI usage in this project warrants dedicated prompts.

**Content outline:** `prompts/dailywerk-review.md` (review prompt), expanded `rules/skill-routing.md` (skill mapping), and bundled reference docs in `skills/`.

**Alternative:** Use `codex-sync` skill to auto-generate `.codex/` config from CLAUDE.md, avoiding manual maintenance of parallel configs.
