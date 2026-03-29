# RFC 002: Workspace Isolation

**Status:** Draft
**Created:** 2026-03-30

## Context

DailyWerk started as a greenfield Rails + React application with only GoodJob tables in place. Before feature tables land, the platform needs an isolation model that is safe in development and scalable to future collaboration.

The original PRD framed isolation around `user_id`. That works for a single-user product, but it becomes a migration trap as soon as multiple people need to collaborate around the same agents, sessions, notes, or vaults.

## Decision

Adopt a dual-layer workspace isolation model:

1. `users` remain the identity layer.
2. `workspaces` become the primary ownership boundary for user-facing data.
3. `workspace_memberships` connect users to workspaces and carry roles and future abilities.
4. Rails enforces workspace scoping with `Current.workspace` plus a `WorkspaceScoped` concern.
5. PostgreSQL RLS enforces the hard boundary with `app.current_workspace_id`.

## Why Workspace-Scoped Instead of User-Scoped

- A user-scoped schema cannot evolve into collaborative workspaces without rewriting ownership on every table.
- A workspace-scoped schema can support collaboration with a single new membership row.
- The MVP remains simple because each user automatically gets one default workspace.

## Why Two Security Layers

### Rails Layer

`WorkspaceScoped` is the primary development safety net:

- ordinary Active Record queries are auto-scoped
- missing workspace context fails closed with `none`
- cross-workspace assignment is caught close to the application code

### PostgreSQL Layer

RLS is the final boundary:

- protects against `unscoped`, raw SQL, or console accidents
- enforces the same `workspace_id` predicate even when the application slips
- requires the app to connect as a non-superuser role in environments where RLS is enforced

## Why `around_action` Instead of Middleware

The auth flow is token-based and controller-driven. Middleware runs before the controller has authenticated the request, so it does not yet know the current workspace. An `around_action` runs after authentication and can safely:

- set `app.current_workspace_id`
- execute the action
- `RESET` the variable in an `ensure` block

## Why Session-Level `SET` Instead of `SET LOCAL`

`SET LOCAL` only works inside a transaction. Wrapping each request in a transaction is a bad fit for Falcon and streaming workloads because connections stay pinned while non-database I/O happens. Session-level `SET` with explicit `RESET` and a connection checkin callback is the pragmatic tradeoff.

## Data Model

```text
User
  -> WorkspaceMembership
  -> Workspace
     -> agents
     -> sessions
     -> messages
     -> notes
     -> tasks
     -> vaults
     -> ...
```

## Roles And Abilities

`workspace_memberships.role` starts with:

- `owner`
- `admin`
- `member`
- `viewer`

`workspace_memberships.abilities` stays as an empty jsonb column for now. The field exists so fine-grained permissions can be layered in later without redesigning the join table.

## Migration Path

The MVP path is intentionally incremental:

1. Create `users`, `workspaces`, and `workspace_memberships`.
2. Auto-create one default workspace per user.
3. Authenticate into `Current.user` and `Current.workspace`.
4. Add `workspace_id` to future feature tables from day one.
5. Enable RLS as workspace-scoped tables are introduced.

## Consequences

### Positive

- collaboration is additive, not a migration event
- Rails and PostgreSQL share the same scoping key
- fake sessions and future WorkOS tokens can both carry `workspace_id`

### Negative

- every feature query now depends on one more join hop conceptually
- local development needs explicit workspace context
- documentation and schema examples must consistently distinguish identity (`user`) from ownership (`workspace`)

## Reference Pattern

The Rails-layer scoping approach is adapted from the `Current` + tenant concern pattern already used in FileWerk, but narrowed to workspace ownership and paired with PostgreSQL RLS from the start.
