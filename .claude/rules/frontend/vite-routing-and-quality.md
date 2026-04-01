---
paths:
  - "frontend/**/*.ts"
  - "frontend/**/*.tsx"
---

# Vite SPA Conventions

- Use `react-router` for app navigation in this Vite SPA. Keep shell layout in `components/layout/` and route components in `pages/`.
- Preserve a chat-first UX. New navigation should not break the main `/chat` flow.
- Keep modules narrowly scoped: config in `config/`, typed API calls in `services/`, shared shape definitions in `types/`.
- Prefer explicit imports and typed public interfaces over clever barrel indirection.
- Verify frontend changes with the relevant `pnpm` commands before finishing: at minimum `pnpm test`, and use `pnpm build` for routing or structural changes.
