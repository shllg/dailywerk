---
name: react-vite-frontend
description: Use when implementing or refactoring UI in `frontend/` for this DailyWerk Vite + React app, especially for routed layouts, sidebar/navigation work, reusable components, or React architecture cleanup. Do not use for Rails-only work.
---

# React Vite Frontend

Use this skill when the task touches the DailyWerk SPA in `frontend/`.

## Goal

Ship frontend changes with a clean file structure that stays easy to extend as the PRDs land.

## Workflow

1. Read the route, layout, and neighboring component files before editing.
2. Keep one React component per file. If a component needs helpers, move non-component helpers into `config/`, `hooks/`, `services/`, or `types/`.
3. Keep routes in `frontend/src/pages/`, reusable shell parts in `frontend/src/components/layout/`, and generic UI primitives in `frontend/src/components/`.
4. Prefer pure render logic over effects. Only use `useEffect` for subscriptions, DOM synchronization, network bootstrapping, or other external effects.
5. If you add navigation, keep chat-first behavior intact and make route names align with the product language in the PRDs.
6. Add brief comments or TSDoc only where the structure or contract would otherwise be unclear.

## DailyWerk Frontend Conventions

- Package manager: `pnpm` only.
- Router: `react-router`.
- Strong preference for small, single-purpose files.
- Avoid giant config blobs inside JSX files. Extract route metadata, navigation definitions, and view content into dedicated modules when they start to grow.
- Preserve existing typed API clients in `frontend/src/services/`.
- Treat placeholder pages as intentional scaffolding: they should reflect real planned product surfaces, not random filler.

## Verification

- Run `pnpm test` for frontend changes.
- Run `pnpm build` when changing routing, app shell structure, or dependency wiring.
- If tests fail, fix the root cause instead of weakening the assertions.
