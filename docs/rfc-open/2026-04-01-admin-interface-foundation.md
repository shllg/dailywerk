---
type: rfc
title: Admin Interface Foundation
created: 2026-04-01
updated: 2026-04-01
status: draft
implements:
  - prd/08-admin-interface
depends_on:
  - rfc/2026-03-30-workspace-isolation
phase: 1
---

# RFC: Admin Interface Foundation

## Context

The product now has enough tenant-scoped data that founder operations need a dedicated path instead of console access.

Current codebase constraints:

- `GoodJob::Engine` is mounted directly at `/good_job`.
- `Authentication` always resolves a workspace and sets both `Current.user` and `Current.workspace`.
- Workspace-owned tables rely on PostgreSQL RLS and `app.current_workspace_id`.
- The SPA stores the bearer token in local storage and only attaches it to API requests.
- There is no admin namespace, no admin auth concern, and no admin-specific read model.

The current admin PRD also mixes product decisions and implementation details. This RFC narrows the first implementation slice to the minimum foundation that is safe and coherent with the live architecture.

## What This RFC Covers

- founder-only admin authentication
- protected GoodJob access compatible with the current SPA auth model
- dedicated admin database access strategy
- phase 1 admin API namespace
- phase 1 query design for dashboard, users, and workspaces
- minimal SPA integration

## What This RFC Does NOT Cover

- workspace detail drilldown
- usage analytics dashboards
- multi-admin RBAC
- unified WorkOS session management
- content-level support tooling
- dedicated `admin_audit_logs` table

---

## 1. Decision: Separate Platform Admin Auth from Workspace Auth

### Problem

The existing `Authentication` concern is correct for tenant-scoped requests and wrong for platform-wide requests. It always:

1. verifies a bearer token
2. loads an active user
3. resolves a workspace
4. sets `Current.workspace`
5. sets the PostgreSQL workspace variable in `with_rls_context`

That behavior is appropriate for normal product APIs and inappropriate for admin endpoints that must operate above the workspace boundary.

### Decision

Introduce a separate platform-admin auth path.

Admin controllers should:

- skip the existing workspace-scoped auth concern
- authenticate the user identity from the existing bearer token
- authorize that user against a founder allowlist
- leave `Current.workspace` unset
- avoid setting `app.current_workspace_id`

### Implementation Shape

- Add a concern such as `PlatformAuthentication`.
- Reuse the existing token verifier logic instead of inventing a second token system.
- Keep the admin base controller separate from workspace-scoped controllers.

### Why This Is Better

- It fixes the root problem instead of fighting `Current.workspace` after it is already set.
- It preserves the existing tenant auth path untouched.
- It makes admin behavior explicit in code review and tests.

---

## 2. Decision: Founder-Only Identity via `ADMIN_EMAILS`

### Decision

Use an ENV-based allowlist in phase 1:

```bash
ADMIN_EMAILS=admin@dailywerk.com
```

### Why

- single founder/operator today
- no schema change required
- low operational complexity
- easy to audit per environment

### Deferred Alternative

When DailyWerk needs multiple admins, move to a database-backed or WorkOS-backed model with explicit role/audit semantics.

---

## 3. Decision: Protect GoodJob with a Short-Lived Admin Cookie

### Root Cause

The SPA bearer token is stored in local storage and attached only to API fetch calls. A direct browser visit to `/good_job` does not carry the SPA `Authorization` header.

Because of that, simply "using the same bearer token" for GoodJob is not a working design.

### Decision

Protect GoodJob through a short-lived, signed cookie issued by an authenticated admin API endpoint.

Phase 1 flow:

1. admin is authenticated inside the SPA via the normal bearer token
2. admin clicks "Open GoodJob"
3. frontend calls `POST /api/v1/admin/good_job_session`
4. backend verifies founder admin access and sets an `HttpOnly` signed cookie scoped to `/good_job`
5. frontend opens `/good_job` in a new tab
6. GoodJob checks the cookie on every request

### Why This Is Better Than Basic Auth

- keeps one admin identity model in phase 1
- fits the existing same-origin SPA
- avoids distributing a second set of founder credentials
- provides a clean migration path to unified cookie auth later

### Cookie Requirements

- `HttpOnly`
- `SameSite=Lax`
- `Secure` in production
- path-scoped to `/good_job`
- short expiry, for example 15 minutes

### GoodJob Integration

Use GoodJob's controller hook for custom auth, not an ad hoc route hack:

- `ActiveSupport.on_load(:good_job_application_controller)`
- verify the signed admin cookie
- reject with `Not Found` or `Forbidden` when absent or invalid

The app already includes the middleware GoodJob needs in API-only mode, so this integrates cleanly with the current stack.

Reference: GoodJob documents both API-only middleware requirements and custom dashboard authentication hooks: https://github.com/bensheldon/good_job

---

## 4. Decision: Dedicated `admin_user` Database Role with Least Privilege

### Problem

`Current.without_workspace_scoping` only bypasses Rails default scopes. It does not bypass PostgreSQL RLS.

Admin endpoints need cross-workspace visibility without weakening tenant policies for normal application traffic.

### Decision

Use a second database connection with a dedicated `admin_user` role that has:

- `BYPASSRLS`
- `SELECT` on allowlisted tables needed for admin read models
- targeted `UPDATE` on `users.status`

### Important Clarification

Do not model this as a replica.

The admin connection points at the same primary database with different credentials. It exists for privilege separation, not read-replica routing.

That means:

- use a separate `admin` database entry
- set `database_tasks: false` because Rails should not manage schema through this connection
- rely on database grants for real write safety
- do not rely on `replica: true` as a write-protection mechanism

Rails' multiple-database guide is explicit that `replica: true` identifies replica connections and that `prevent_writes: true` is only a query guard, not the primary security boundary: https://guides.rubyonrails.org/active_record_multiple_databases.html

### Rails Shape

- `AdminRecord` as a dedicated abstract base class
- `connects_to database: { writing: :admin }`
- all admin read models inherit from `AdminRecord` or use `AdminRecord.connection`

### Why This Is Better

- no RLS policy changes
- normal app traffic remains on the workspace-scoped role
- platform-wide visibility is explicit and reviewable
- least privilege remains enforceable at the database layer

---

## 5. Phase 1 API Surface

Phase 1 keeps the surface intentionally small:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/v1/admin/dashboard` | aggregate platform health |
| `GET` | `/api/v1/admin/users` | paginated user list, optional status filter |
| `PATCH` | `/api/v1/admin/users/:id/approve` | `pending -> active` |
| `PATCH` | `/api/v1/admin/users/:id/suspend` | `active -> suspended` |
| `PATCH` | `/api/v1/admin/users/:id/unsuspend` | `suspended -> active` |
| `GET` | `/api/v1/admin/workspaces` | paginated workspace list with aggregate metadata |
| `POST` | `/api/v1/admin/good_job_session` | issue short-lived GoodJob cookie |

Not part of phase 1:

- workspace detail
- usage analytics
- admin access endpoint separate from dashboard

The dashboard itself can serve as the "am I an admin?" probe for the frontend because its response is cacheable and cheap relative to adding a second bootstrap-only endpoint.

---

## 6. Query Model

### 6.1 Dashboard

The dashboard returns aggregate counts only:

- users by status
- total workspaces
- total sessions and active sessions
- total messages
- total session tokens
- GoodJob queue/process health

This endpoint should be cached briefly.

### 6.2 Users List

Phase 1 user rows should include:

- `id`
- `email`
- `name`
- `status`
- `created_at`
- `workspace_count`

Do not include:

- `settings`
- workspace content
- recent messages
- prompts or vault state

### 6.3 Workspace List

Do not use a single fan-out join across memberships, agents, and sessions when computing aggregates. That shape multiplies rows and inflates `SUM(total_tokens)`.

Use subqueries or CTEs instead:

```sql
WITH member_counts AS (
  SELECT workspace_id, COUNT(*) AS member_count
  FROM workspace_memberships
  GROUP BY workspace_id
),
agent_counts AS (
  SELECT workspace_id, COUNT(*) AS agent_count
  FROM agents
  GROUP BY workspace_id
),
session_stats AS (
  SELECT
    workspace_id,
    COUNT(*) AS session_count,
    COUNT(*) FILTER (WHERE status = 'active') AS active_session_count,
    COALESCE(SUM(total_tokens), 0) AS total_tokens
  FROM sessions
  GROUP BY workspace_id
)
SELECT ...
```

Phase 1 workspace rows should include only:

- `id`
- `name`
- owner name/email
- member count
- agent count
- session count
- active session count
- total tokens
- created timestamp

Do not include raw workspace `settings` in phase 1.

---

## 7. User Status Transitions

Phase 1 supports exactly three transitions:

| Action | From | To |
|--------|------|----|
| `approve` | `pending` | `active` |
| `suspend` | `active` | `suspended` |
| `unsuspend` | `suspended` | `active` |

Implementation notes:

- encapsulate transition rules in a small service object
- log every mutation with admin email, target user, and before/after status
- reject invalid transitions with `422`

### Dependency Note

The product requirement for manual user approval already exists, but the current code still defaults users to `active`. This RFC does not need to solve onboarding in the same patch, but it must not assume the pending-user flow is already live.

The approval UI can ship before or alongside the onboarding/auth change that begins creating `pending` users by default.

---

## 8. SPA Integration

### Routes

Phase 1 frontend routes:

- `/admin`
- `/admin/users`
- `/admin/workspaces`

### UX Rules

- keep chat as the default landing flow
- hide admin navigation for non-admins
- lazy-load admin pages so ordinary users do not download the admin bundle

### Capability Detection

The frontend may determine admin capability by probing `/api/v1/admin/dashboard` after login or on first admin navigation.

- `200` means admin access is available
- `403` means hide or block admin navigation

This avoids coupling the general auth session payload to admin-only concerns.

---

## 9. Privacy Rules

The admin surface must be built from explicit read models, not generic AR serialization.

Rules:

- no `SELECT *`
- no `render json: model`
- no raw `settings` blobs in phase 1
- no session `summary`, `title`, or `context_data`
- no agent `instructions`, `soul`, `identity`, `params`, or `thinking`
- no message content or vault content
- no secret-bearing tables or columns

Tier 3 secret fields stay outside the admin role entirely where practical.

---

## 10. Testing & Rollout

### Tests

- request tests for admin auth and 403 behavior
- request tests for dashboard, users, and workspaces endpoints
- service tests for user status transitions
- request or integration tests for GoodJob cookie issuance
- regression tests proving non-admins cannot reach `/good_job`

### Rollout Order

1. add admin auth foundation
2. add admin DB role and connection
3. protect GoodJob
4. ship dashboard and user operations
5. ship workspace list
6. add frontend navigation and pages

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Admin code accidentally uses workspace auth path | incorrect scoping or hidden coupling | separate admin concern and tests that `Current.workspace` stays unset |
| GoodJob protection looks secure but direct browser requests bypass SPA auth | dashboard exposure | signed GoodJob cookie issued by admin API, verified inside GoodJob |
| Cross-workspace aggregate queries get slow | operational drag | pagination, caching, statement timeout, subquery-based aggregates |
| Phase 1 starts leaking semi-structured metadata | privacy regression | explicit field allowlists and no raw settings blobs |
| Manual approval UX ships before pending-user onboarding is live | partial feature | document dependency clearly and test status transitions independently |

---

## 12. Open Questions

1. Should the GoodJob cookie share the same token payload shape as API sessions, or use a dedicated minimal payload just for dashboard access?
2. Does phase 1 need a dedicated admin access endpoint later, or is dashboard probing sufficient?
3. When WorkOS ships, should admin capability be surfaced in the auth bootstrap payload instead of inferred from an admin endpoint?
