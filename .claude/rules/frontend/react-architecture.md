---
paths:
  - "frontend/src/**/*.tsx"
---

# React Component Architecture

- Keep each React component in its own file. If a file starts accumulating helper components, split them.
- Keep page files thin: route composition only. Move reusable view pieces into `frontend/src/components/`.
- Move non-visual logic into hooks, config, services, or types. Do not hide business rules inside JSX files.
- Prefer deriving UI during render. Add `useEffect` only for real external synchronization.
- Keep components pure and predictable: props in, JSX out, no hidden writes during render.
- Add concise comments only where structure or intent is not obvious from the code itself.
