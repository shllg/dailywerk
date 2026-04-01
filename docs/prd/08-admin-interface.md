---
type: prd
title: Admin Interface
domain: operations
created: 2026-04-01
updated: 2026-04-01
status: canonical
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/04-billing-and-operations
implemented_by:
  - rfc/2026-04-01-admin-interface-foundation
---

# DailyWerk — Admin Interface

> Canonical product document for the founder-only platform admin surface.
> For workspace isolation, see [01-platform-and-infrastructure.md §4](./01-platform-and-infrastructure.md#4-workspace-isolation-architecture).
> For user approval and billing dependencies, see [04-billing-and-operations.md](./04-billing-and-operations.md).
> For implementation detail, see [RFC: Admin Interface Foundation](../rfc-open/2026-04-01-admin-interface-foundation.md).

---

## 1. Overview

DailyWerk needs a small, high-trust admin surface for the founder to operate the platform across all workspaces without falling back to `rails console`, ad hoc SQL, or an exposed job dashboard.

This interface is not a customer-facing product area. It is an operational control plane with a narrow mandate:

- approve or block access to the product
- inspect platform health and tenant metadata
- reach job operations safely

The admin surface must remain intentionally limited. It is for metadata and aggregate visibility, not for reading user content.

---

## 2. Problem Statement

Today the platform has no safe cross-workspace operational UI.

- The billing and onboarding plan assumes manual approval of new users, but there is no approval workflow in the product yet.
- The GoodJob dashboard is mounted directly and needs explicit protection before the app is exposed beyond local development.
- Workspace-scoped application auth and PostgreSQL RLS are designed for tenant isolation, not platform-wide operations.
- Founder operations currently drift toward console access, which increases both privacy risk and operational inconsistency.

Without a dedicated admin interface, the platform has no clean way to bridge product operations and tenant isolation.

---

## 3. Goals & Success Metrics

### Goals

- Allow the founder to handle routine platform operations without console access.
- Provide cross-workspace visibility into tenant metadata and aggregate system health.
- Keep user content, prompts, vault data, and secrets outside the admin surface.
- Protect GoodJob and all admin endpoints behind explicit admin-only access control.

### Success Metrics

- Routine approval and suspension tasks can be completed entirely from the admin UI.
- GoodJob is no longer reachable without admin authentication.
- Admin endpoints return only allowlisted fields and aggregate data.
- No admin workflow requires reading message content, vault content, or stored credentials.

---

## 4. Primary User

### Founder / Platform Operator

The phase 1 admin interface serves one operator: the founder.

Core jobs:

- review newly created or pending accounts
- approve, suspend, or unsuspend users
- inspect workspace and conversation volume at a metadata level
- check job queue health and reach the GoodJob dashboard quickly

### Future Users

Support staff, finance staff, and multi-admin teams are future concerns. They are explicitly out of scope for the initial admin surface.

---

## 5. Product Scope

### Phase 1 In Scope

- founder-only platform admin authentication
- protected admin API namespace
- system overview dashboard
- user list and status actions (`approve`, `suspend`, `unsuspend`)
- workspace list with aggregate metadata
- protected access path to GoodJob
- admin entry points inside the React SPA

### Phase 2 In Scope

- workspace detail view with metadata-only drilldown
- usage analytics derived from current token/session data, then later from billing tables
- stronger audit history for admin actions

### Out of Scope

- multi-admin RBAC
- customer support tooling that reads message or vault content
- impersonation or "login as user"
- workspace creation or deletion from the UI
- Stripe billing operations
- real-time monitoring dashboards
- chart-heavy analytics as an MVP requirement

---

## 6. Privacy Contract

The admin surface is allowed to see platform metadata. It is not allowed to become a backdoor into tenant content.

| Tier | Policy | Examples |
|------|--------|----------|
| **Tier 1: Admin Visible** | Explicitly allowlisted metadata and aggregates | user email, user status, workspace name, member count, session count, total tokens, GoodJob queue health |
| **Tier 2: Admin Hidden** | Never returned by admin endpoints | message content, session summaries, prompts, agent instructions, vault file contents, tool call arguments/results, raw workspace/user settings blobs unless specifically allowlisted |
| **Tier 3: Never Accessible** | Not queryable through the admin surface, even by mistake | API keys, OAuth tokens, encrypted credentials, other secret-bearing fields |

Enforcement rules:

- admin queries must use explicit column allowlists
- admin endpoints must not use `SELECT *`
- admin serializers must not accept arbitrary model JSON dumps
- phase 1 should omit raw `settings` fields unless a specific operational key is intentionally allowlisted

---

## 7. Functional Requirements

### FR-1 Admin Access

Only designated platform admins may access `/api/v1/admin/*` or the GoodJob dashboard.

### FR-2 System Overview

The admin dashboard must show platform-wide aggregate counts for users, workspaces, sessions, messages, and job health.

### FR-3 User Operations

The admin UI must support listing users and performing valid status transitions:

- `pending -> active`
- `active -> suspended`
- `suspended -> active`

### FR-4 Workspace Visibility

The admin UI must show a cross-workspace list with metadata and aggregate activity, without exposing user content.

### FR-5 GoodJob Access

The founder must have a safe path from the admin UI to the GoodJob dashboard.

### FR-6 Admin Auditability

Phase 1 must record admin mutations in application logs. A dedicated audit table is deferred.

### FR-7 SPA Integration

Admin navigation must fit into the existing chat-first SPA without disrupting the default `/chat` flow for ordinary users.

---

## 8. Non-Functional Requirements

### Security

- founder-only access in phase 1
- explicit separation between platform admin access and workspace-scoped user access
- no tenant-content reads as part of routine admin workflows

### Performance

- dashboard and list endpoints should remain fast on small-to-medium tenant counts
- expensive cross-workspace queries must be bounded by pagination, query shape, and statement timeouts

### Operability

- the phase 1 model should remain simple enough to configure by environment variables plus one additional database role
- routine operations should not require console usage

### Compatibility

- phase 1 must work with the current bearer-token SPA
- phase 1 must not depend on WorkOS shipping first
- phase 1 must coexist with the current workspace-scoped RLS model

---

## 9. Dependencies & Constraints

- The current application auth flow is workspace-oriented and bearer-token based.
- Workspace-owned tables are protected by PostgreSQL RLS and `Current.workspace`.
- The current frontend stores auth state in local storage, which matters for any admin flow that leaves the SPA.
- The billing PRD assumes manual approval for new users, but the current codebase still defaults users to `active`; the approval workflow therefore lands before or alongside onboarding changes that create `pending` users by default.
- Usage and billing tables described in PRD 01 and PRD 04 are not yet the live source of truth; phase 2 analytics must start from the current schema and migrate later.

---

## 10. Rollout Plan

### Phase 0: Foundation

- define founder-only admin identity
- protect GoodJob
- establish cross-workspace read access strategy that does not weaken tenant isolation

### Phase 1: Admin MVP

- admin auth
- admin dashboard
- user list and status transitions
- workspace list
- admin navigation in the SPA

### Phase 2: Expanded Visibility

- workspace detail view
- usage analytics
- stronger admin audit trail

### Future

- WorkOS-backed admin roles
- multi-admin support
- richer operational analytics

---

## 11. Open Questions

1. Should platform admin identity remain ENV-based until multi-admin support is needed, or should it move into the data model earlier for auditability?
2. When WorkOS and cookie-based auth ship, should the admin interface move to a unified session model with GoodJob, or should GoodJob remain separately protected?
3. Which workspace settings, if any, are safe enough to expose in a metadata-only detail view?
4. At what scale does the admin surface need pre-aggregated reporting tables instead of live aggregate queries?
