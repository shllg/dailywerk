---
type: prd
title: AI Developer Tooling
domain: tooling
created: 2026-03-29
updated: 2026-03-30
status: canonical
implemented_by:
  - rfc/2026-03-29-ai-tooling-phase2
---

# PRD 05: AI Developer Tooling

## Goal

Claude Code and Codex CLI should be effective, accurate coding tools in the DailyWerk repository. They must understand the tech stack, follow project conventions, and avoid common footguns — without requiring repeated correction.

## Phase 1: Foundation (Implemented)

AI tools in this repo should:

- Know the exact tech stack (Rails 8.1.3, Falcon, React 19, GoodJob external, PG17+pgvector, pnpm)
- Follow fiber-safe patterns (Falcon, not Puma) without being told
- Use UUIDv7 for all new table primary keys without being told
- Never run GoodJob in inline/async mode
- Use strong parameters and avoid SQL injection patterns
- Use `pnpm` for frontend, `bundler` for backend
- Run quality checks (minitest, brakeman, rubocop) before presenting results
- Auto-format Ruby code via rubocop on session stop

**Config files:** `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, `.claude/rules/00-04`, `.codex/config.toml`, `.codex/rules/default.rules`

## Phase 2: Domain Expertise (Deferred)

As the codebase grows, AI tools should gain domain-specific expertise:

- **User isolation:** Understand RLS patterns, user-scoped queries, cross-user isolation testing
- **LLM orchestration:** Follow ruby_llm conventions, ReAct loop patterns, BYOK isolation
- **Frontend:** Follow established React 19 + TypeScript + Tailwind 4 + DaisyUI patterns
- **Testing:** Apply Minitest conventions, RLS test context, fixture patterns
- **Background jobs:** Follow GoodJob queue structure, concurrency controls, cron patterns
- **Review workflows:** Automated code review with domain-specific checklists
- **Skill-based guidance:** Contextual reminders when editing specific code areas

**Trigger conditions and implementation details:** See [RFC 001: AI Tooling Phase 2](../rfc-open/2026-03-29-ai-tooling-phase2.md)

## Success Criteria

1. AI follows fiber-safety rules without reminders when editing `app/` or `lib/` code
2. AI generates UUIDv7 migrations without being told
3. AI never suggests GoodJob inline/async mode
4. AI uses `pnpm` for frontend commands, `bundler` for backend
5. AI runs rubocop automatically on session stop when files changed
6. Phase 2 items are added only when their trigger conditions are met — never preemptively
