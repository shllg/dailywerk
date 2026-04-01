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
---

# DailyWerk — Admin Interface

> Platform admin dashboard for tenant visibility, user management, and usage analytics.
> For workspace isolation: see [01-platform-and-infrastructure.md §4](./01-platform-and-infrastructure.md#4-workspace-isolation-architecture).
> For billing and usage tracking: see [04-billing-and-operations.md](./04-billing-and-operations.md).

---

## 1. Overview & Scope

DailyWerk needs a platform admin interface for the sole founder to manage tenants, approve users, and monitor system health. The admin dashboard provides cross-workspace visibility into metadata and aggregate statistics while enforcing strict privacy boundaries around user content.

### In Scope

- Platform admin identity (ENV-based allowlist)
- Admin database role for safe cross-workspace queries
- System overview dashboard (users, workspaces, sessions, tokens, GoodJob health)
- Workspace list and detail views (metadata and aggregates only)
- User management (list, approve pending, suspend, unsuspend)
- Usage analytics (token aggregates by model, provider, date range)
- Privacy boundary enforcement (3-tier model)
- GoodJob dashboard authentication
- Admin frontend pages in the React SPA

### Out of Scope

- Multi-admin RBAC (single admin for now, migrate to WorkOS roles later)
- Workspace creation/deletion by admin (use `rails console`)
- Billing management (Stripe dashboard handles this)
- Real-time metrics or streaming dashboards
- Chart visualizations (Phase 2 — tabular data first)

---

## 2. Prerequisites — Existing Issues to Fix

Two pre-existing issues become higher risk with admin context and should be addressed before or alongside the admin work.

### 2.1 GoodJob Dashboard Authentication

`config/routes.rb:4` mounts GoodJob with zero authentication:

```ruby
mount GoodJob::Engine => "good_job"
```

PRD 04 §8 specifies `authenticate :admin_user` but this is not implemented. The dashboard exposes job parameters (workspace_ids, user_ids) and allows job retry/discard.

**Fix:** Gate behind Rack middleware that checks admin identity:

```ruby
# config/routes.rb
admin_constraint = lambda do |request|
  admin_emails = ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }
  # Extract bearer token from cookie or Authorization header
  token = request.authorization.to_s[/\ABearer (.+)\z/, 1] ||
          request.cookie_jar.signed[:admin_token]
  return false unless token

  payload = Rails.application.message_verifier(:api_session)
                 .verified(token, purpose: :api_session) rescue nil
  return false unless payload

  user = User.find_by(id: payload["user_id"] || payload[:user_id])
  user && admin_emails.include?(user.email)
end

constraints(admin_constraint) do
  mount GoodJob::Engine => "good_job"
end
```

### 2.2 Fiber-Safe Session Variables (`SET` vs `SET LOCAL`)

`app/controllers/concerns/authentication.rb:74` uses bare `SET`:

```ruby
connection.execute("SET app.current_workspace_id = #{connection.quote(workspace_id)}")
```

Under Falcon's fiber concurrency, if a fiber yields on I/O, another fiber can inherit the connection with a stale session variable from the pool. The `ensure` block only resets after the action completes, not during I/O yields within it.

**Fix:** Use `SET LOCAL` inside a transaction. `SET LOCAL` is scoped to the current transaction and auto-resets on commit/rollback:

```ruby
def with_rls_context
  authenticate_request! unless @current_user || performed?
  return if performed?

  workspace_id = current_workspace&.id || Current.workspace&.id
  if workspace_id.present?
    ActiveRecord::Base.transaction do
      connection = ActiveRecord::Base.connection
      connection.execute(
        "SET LOCAL app.current_workspace_id = #{connection.quote(workspace_id)}"
      )
      yield
    end
  else
    yield
  end
end
```

This change affects all controller actions (they now run inside a transaction). Evaluate impact on streaming responses and ActionCable before applying.

---

## 3. Admin Authentication & Authorization

### Decision: ENV-Based Allowlist

For a solo founder with 1-10 test users, ENV-based admin identity provides the best security-to-complexity ratio:

- Zero database attack surface — no column to flip via SQL injection or mass assignment
- Trivially auditable — `echo $ADMIN_EMAILS`
- No migration, no schema change
- Trade-off: requires redeploy to change admins (acceptable for single admin)

```bash
# .env
ADMIN_EMAILS=admin@dailywerk.com
```

### AdminAuthentication Concern

```ruby
# app/controllers/concerns/admin_authentication.rb
module AdminAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_request!  # Reuse from Authentication
    before_action :require_admin!
    # Skip workspace RLS — admin queries use BYPASSRLS DB role
    skip_around_action :with_rls_context
  end

  private

  def require_admin!
    admin_emails = ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }
    return if admin_emails.include?(@current_user.email)

    render json: { error: "Forbidden" }, status: :forbidden
  end
end
```

The concern reuses the existing token-based authentication from `Authentication` (user identity verification) but skips `with_rls_context` (no workspace scoping for admin). The admin check happens at the controller layer after identity is verified.

**Note:** `User` already normalizes emails to lowercase (`user.rb:13`: `normalizes :email, with: ->(email) { email.strip.downcase }`), so the `downcase` on the ENV value is sufficient to prevent case mismatch bypasses.

### Auth Flow for Admin Requests

```
Request → Authentication#authenticate_request! (verifies token, loads Current.user)
        → AdminAuthentication#require_admin! (checks ENV allowlist)
        → Controller action (no workspace context, uses admin DB connection)
```

The token payload still contains `workspace_id` from the user's regular session. Admin auth ignores it — admin endpoints never set `Current.workspace` or the RLS session variable.

### Migration Path

When multiple admins are needed or WorkOS RBAC ships:

1. Add `is_platform_admin` boolean to `users` (with `attr_readonly`)
2. Replace ENV check with `@current_user.is_platform_admin?`
3. Or use WorkOS organization roles once the integration is complete

---

## 4. Admin Database Role

### Problem

All workspace-scoped tables have PostgreSQL RLS policies enforced on the `app_user` role. Admin queries need cross-workspace visibility. Three options were evaluated:

| Option | Approach | Verdict |
|--------|----------|---------|
| A | Add `OR is_admin` condition to every RLS policy | Rejected: destroys query planner optimization (prevents index usage, forces seq scans), creates escalation risk if any SQL injection reaches `SET app.is_admin` |
| B | Separate `admin_user` DB role with `BYPASSRLS` | **Chosen**: clean separation, no RLS policy changes, standard index usage |
| C | `Current.without_workspace_scoping` only | Insufficient: only bypasses ActiveRecord default_scope, PostgreSQL RLS still blocks rows |

### Implementation

**Create the admin database role** (one-time setup, not a Rails migration):

```sql
-- Run as superuser
CREATE ROLE admin_user LOGIN PASSWORD '<strong-password>' INHERIT;
GRANT USAGE ON SCHEMA public TO admin_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO admin_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO admin_user;

-- BYPASSRLS allows this role to see all rows regardless of RLS policies
ALTER ROLE admin_user BYPASSRLS;

-- Grant UPDATE only on users table (for approve/suspend)
GRANT UPDATE (status) ON users TO admin_user;
```

The `admin_user` role is **read-only by default** with a targeted UPDATE grant on `users.status`. This follows the principle of least privilege — admin can view everything but only modify what's explicitly needed.

**Rails multi-database configuration:**

```yaml
# config/database.yml
default: &default
  adapter: postgresql
  encoding: unicode
  max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  host: <%= ENV.fetch("DB_HOST") { "localhost" } %>
  port: <%= ENV.fetch("DB_PORT") { 5452 } %>

development:
  primary:
    <<: *default
    database: dailywerk_development
    username: <%= ENV.fetch("DB_USERNAME") { "postgres" } %>
    password: <%= ENV.fetch("DB_PASSWORD") { "password" } %>
  admin:
    <<: *default
    database: dailywerk_development
    username: <%= ENV.fetch("ADMIN_DB_USERNAME") { "admin_user" } %>
    password: <%= ENV.fetch("ADMIN_DB_PASSWORD") { "admin_password" } %>
    replica: true  # Prevents writes by default

production:
  primary:
    url: <%= ENV["DATABASE_URL"] %>
  admin:
    url: <%= ENV["ADMIN_DATABASE_URL"] %>
    replica: true
```

**AdminRecord base class:**

```ruby
# app/models/admin_record.rb
class AdminRecord < ApplicationRecord
  self.abstract_class = true
  connects_to database: { reading: :admin, writing: :admin }
end
```

Admin controllers query via `AdminRecord.connection` or through read-only model proxies. The `replica: true` flag on the admin connection prevents accidental writes through this connection pool — explicit `connected_to(role: :writing)` is required for the user status UPDATE.

---

## 5. Admin API Namespace & Base Controller

### Routes

```ruby
# config/routes.rb — inside api/v1 namespace
namespace :admin do
  resource :dashboard, only: :show, controller: "dashboard"
  resources :workspaces, only: [:index, :show]
  resources :users, only: [:index, :show] do
    member do
      patch :approve
      patch :suspend
      patch :unsuspend
    end
  end
  resource :usage, only: :show, controller: "usage"
end
```

Full paths:

| Method | Path | Controller#Action | Purpose |
|--------|------|-------------------|---------|
| GET | `/api/v1/admin/dashboard` | `dashboard#show` | System overview stats |
| GET | `/api/v1/admin/workspaces` | `workspaces#index` | List all workspaces |
| GET | `/api/v1/admin/workspaces/:id` | `workspaces#show` | Workspace detail |
| GET | `/api/v1/admin/users` | `users#index` | List all users |
| GET | `/api/v1/admin/users/:id` | `users#show` | User detail |
| PATCH | `/api/v1/admin/users/:id/approve` | `users#approve` | Approve pending user |
| PATCH | `/api/v1/admin/users/:id/suspend` | `users#suspend` | Suspend active user |
| PATCH | `/api/v1/admin/users/:id/unsuspend` | `users#unsuspend` | Unsuspend user |
| GET | `/api/v1/admin/usage` | `usage#show` | Usage analytics |

### Base Controller

```ruby
# app/controllers/api/v1/admin/base_controller.rb
class Api::V1::Admin::BaseController < ApplicationController
  include AdminAuthentication

  around_action :with_admin_query_timeout

  private

  # Protect DB from expensive cross-workspace queries.
  def with_admin_query_timeout
    AdminRecord.connection.execute("SET statement_timeout = '5s'")
    yield
  ensure
    AdminRecord.connection.execute("RESET statement_timeout")
  end
end
```

All admin controllers inherit from `BaseController`. This gives them:
- Token-based user authentication (from `Authentication`)
- Admin allowlist check (from `AdminAuthentication`)
- No workspace RLS context (skipped by `AdminAuthentication`)
- 5-second statement timeout on admin queries
- Access to the `admin_user` DB connection pool (via `AdminRecord`)

---

## 6. Dashboard — System Overview

**Endpoint:** `GET /api/v1/admin/dashboard`

Returns cached system-wide aggregates and GoodJob health. Cached in Valkey for 5 minutes.

### Response

```json
{
  "users": {
    "total": 42,
    "pending": 3,
    "active": 38,
    "suspended": 1
  },
  "workspaces": {
    "total": 40
  },
  "conversations": {
    "total_sessions": 512,
    "active_sessions": 89,
    "total_messages": 15230,
    "total_tokens": 4520000
  },
  "good_job": {
    "queued": 5,
    "running": 2,
    "finished_last_hour": 120,
    "errored_last_hour": 1
  },
  "cached_at": "2026-04-01T03:15:00Z"
}
```

### Implementation

```ruby
# app/controllers/api/v1/admin/dashboard_controller.rb
class Api::V1::Admin::DashboardController < Api::V1::Admin::BaseController
  def show
    stats = Rails.cache.fetch("admin:dashboard", expires_in: 5.minutes) do
      {
        users: AdminRecord.connection.select_one(<<~SQL),
          SELECT
            COUNT(*) AS total,
            COUNT(*) FILTER (WHERE status = 'pending') AS pending,
            COUNT(*) FILTER (WHERE status = 'active') AS active,
            COUNT(*) FILTER (WHERE status = 'suspended') AS suspended
          FROM users
        SQL
        workspaces: { total: AdminRecord.connection.select_value("SELECT COUNT(*) FROM workspaces") },
        conversations: AdminRecord.connection.select_one(<<~SQL),
          SELECT
            (SELECT COUNT(*) FROM sessions) AS total_sessions,
            (SELECT COUNT(*) FROM sessions WHERE status = 'active') AS active_sessions,
            (SELECT COUNT(*) FROM messages) AS total_messages,
            (SELECT COALESCE(SUM(total_tokens), 0) FROM sessions) AS total_tokens
          FROM (SELECT 1) AS dummy
        SQL
        good_job: good_job_stats,
        cached_at: Time.current.iso8601
      }
    end

    render json: stats
  end

  private

  def good_job_stats
    {
      queued: GoodJob::Job.queued.count,
      running: GoodJob::Job.running.count,
      finished_last_hour: GoodJob::Job.finished(Time.current - 1.hour..).count,
      errored_last_hour: GoodJob::Job.where(error: !nil).where(finished_at: Time.current - 1.hour..).count
    }
  end
end
```

Dashboard queries run through `AdminRecord.connection` (the `admin_user` role that bypasses RLS). GoodJob queries use the primary connection since `good_job_*` tables have no RLS.

---

## 7. Workspace Management

### 7.1 Workspace List

**Endpoint:** `GET /api/v1/admin/workspaces?page=1&per_page=25&sort=created_at&order=desc`

**Response (each item):**

```json
{
  "id": "01912345-6789-7abc-def0-123456789abc",
  "name": "My Workspace",
  "owner": {
    "id": "01912345-...",
    "email": "user@example.com",
    "name": "Jane Doe"
  },
  "member_count": 1,
  "agent_count": 2,
  "session_count": 15,
  "active_session_count": 1,
  "total_tokens": 125000,
  "created_at": "2026-03-15T10:00:00Z"
}
```

**Implementation:** Single aggregate query via `AdminRecord.connection`:

```sql
SELECT
  w.id, w.name, w.created_at,
  u.id AS owner_id, u.email AS owner_email, u.name AS owner_name,
  COUNT(DISTINCT wm.id) AS member_count,
  COUNT(DISTINCT a.id) AS agent_count,
  COUNT(DISTINCT s.id) AS session_count,
  COUNT(DISTINCT s.id) FILTER (WHERE s.status = 'active') AS active_session_count,
  COALESCE(SUM(s.total_tokens), 0) AS total_tokens
FROM workspaces w
JOIN users u ON u.id = w.owner_id
LEFT JOIN workspace_memberships wm ON wm.workspace_id = w.id
LEFT JOIN agents a ON a.workspace_id = w.id
LEFT JOIN sessions s ON s.workspace_id = w.id
GROUP BY w.id, u.id
ORDER BY w.created_at DESC
LIMIT 25 OFFSET 0
```

### 7.2 Workspace Detail

**Endpoint:** `GET /api/v1/admin/workspaces/:id`

Returns workspace metadata plus agent configs and recent session metadata. No user content is exposed.

**Response:**

```json
{
  "id": "...",
  "name": "My Workspace",
  "settings": {},
  "owner": { "id": "...", "email": "...", "name": "..." },
  "member_count": 1,
  "agent_count": 2,
  "session_count": 15,
  "total_tokens": 125000,
  "created_at": "...",
  "agents": [
    {
      "id": "...",
      "slug": "main",
      "name": "DailyWerk",
      "model_id": "gpt-5.4",
      "provider": null,
      "temperature": 0.7,
      "is_default": true,
      "active": true
    }
  ],
  "recent_sessions": [
    {
      "id": "...",
      "status": "active",
      "gateway": "web",
      "message_count": 25,
      "total_tokens": 8000,
      "started_at": "...",
      "last_activity_at": "..."
    }
  ]
}
```

**Privacy enforcement:**
- Agents: only metadata columns (`slug`, `name`, `model_id`, `provider`, `temperature`, `is_default`, `active`). Excludes `soul`, `instructions`, `identity`, `params`, `thinking`.
- Sessions: only metadata columns. Excludes `title`, `summary`, `context_data`.

---

## 8. User Management

### 8.1 User List

**Endpoint:** `GET /api/v1/admin/users?page=1&per_page=25&status=pending`

**Response (each item):**

```json
{
  "id": "...",
  "email": "user@example.com",
  "name": "Jane Doe",
  "status": "pending",
  "workspaces": [
    { "id": "...", "name": "My Workspace", "role": "owner" }
  ],
  "created_at": "2026-03-28T12:00:00Z"
}
```

### 8.2 Status Transitions

| Action | From | To | Endpoint |
|--------|------|----|----------|
| Approve | `pending` | `active` | `PATCH /api/v1/admin/users/:id/approve` |
| Suspend | `active` | `suspended` | `PATCH /api/v1/admin/users/:id/suspend` |
| Unsuspend | `suspended` | `active` | `PATCH /api/v1/admin/users/:id/unsuspend` |

All return `{ "user": { ...updated user JSON... } }` on success or `{ "error": "..." }` with `422` on invalid transition.

### Service Object

```ruby
# app/services/admin/user_status_service.rb
class Admin::UserStatusService
  TRANSITIONS = {
    "approve"   => { from: "pending",   to: "active" },
    "suspend"   => { from: "active",    to: "suspended" },
    "unsuspend" => { from: "suspended", to: "active" }
  }.freeze

  def initialize(user:, action:, admin:)
    @user = user
    @action = action
    @admin = admin
  end

  def call
    transition = TRANSITIONS.fetch(@action)
    unless @user.status == transition[:from]
      return { success: false, error: "Cannot #{@action}: user is #{@user.status}" }
    end

    @user.update!(status: transition[:to])
    Rails.logger.info(
      "[Admin] #{@admin.email} #{@action}d user #{@user.email} " \
      "(#{transition[:from]} -> #{transition[:to]})"
    )
    { success: true, user: @user }
  end
end
```

**Note:** User status updates use the primary DB connection (not admin_user) since the admin needs write access to the `users` table. The controller explicitly uses `ActiveRecord::Base.connected_to(role: :writing)` for this action. Alternatively, grant `UPDATE (status)` on `users` to the `admin_user` role and route the write through that connection.

---

## 9. Privacy Boundary

### 3-Tier Model

| Tier | Visibility | Data |
|------|-----------|------|
| **1 — Admin Visible** | Always shown in admin views | User email, name, status, created_at. Workspace name, settings, created_at. Agent slug, name, model_id, provider, temperature, is_default, active. Session count, total_tokens, status, gateway, timestamps. Message aggregate counts and token sums. Tool call counts grouped by name. |
| **2 — Admin Hidden** | Never loaded by admin queries | Message content, content_raw, thinking_text, thinking_signature. Session title, summary, context_data. Agent soul, instructions, identity. Tool call arguments, results. All future vault files, memory entries, notes, daily logs, conversation archives. |
| **3 — Never Accessible** | Not queryable even with admin DB role | BYOK API keys (api_credentials.api_key_enc). MCP OAuth tokens (mcp_server_configs.oauth_token_enc). Integration credentials (integrations.credentials_encrypted). |

### Enforcement Strategy

Privacy is enforced at the **query level**, not the serializer level. Admin queries use explicit `SELECT` with named columns — never `SELECT *`. This ensures sensitive data never leaves the database, regardless of how the response is serialized.

```ruby
# Example: safe agent query for admin
AdminRecord.connection.select_all(<<~SQL, "Admin::AgentList", [workspace_id])
  SELECT id, slug, name, model_id, provider, temperature, is_default, active, created_at
  FROM agents
  WHERE workspace_id = $1
SQL
```

Tier 3 data protection is additionally enforced by not granting `SELECT` on credential columns to the `admin_user` role:

```sql
-- Revoke access to credential columns (if these tables exist)
-- REVOKE SELECT (api_key_enc) ON api_credentials FROM admin_user;
-- REVOKE SELECT (oauth_token_enc) ON mcp_server_configs FROM admin_user;
-- REVOKE SELECT (credentials_encrypted) ON integrations FROM admin_user;
```

---

## 10. Usage Analytics

**Endpoint:** `GET /api/v1/admin/usage?start_date=2026-03-01&end_date=2026-03-31&group_by=model`

### Response

```json
{
  "period": { "start": "2026-03-01", "end": "2026-03-31" },
  "totals": {
    "total_messages": 5200,
    "total_input_tokens": 1200000,
    "total_output_tokens": 800000,
    "total_thinking_tokens": 150000,
    "total_sessions": 180
  },
  "breakdown": [
    {
      "model_id": "gpt-5.4",
      "message_count": 3100,
      "input_tokens": 800000,
      "output_tokens": 500000
    },
    {
      "model_id": "claude-sonnet-4-6",
      "message_count": 2100,
      "input_tokens": 400000,
      "output_tokens": 300000
    }
  ],
  "cached_at": "2026-04-01T03:00:00Z"
}
```

### Data Source Strategy

**Phase 1 (now):** Derive from `messages` table. Every message has `input_tokens`, `output_tokens`, `cached_tokens`, `thinking_tokens`. Model info comes from the parent session's `model_id` joined to `ruby_llm_models`.

```sql
SELECT
  s.model_id,
  COUNT(m.id) AS message_count,
  COALESCE(SUM(m.input_tokens), 0) AS input_tokens,
  COALESCE(SUM(m.output_tokens), 0) AS output_tokens
FROM messages m
JOIN sessions s ON s.id = m.session_id
WHERE m.created_at BETWEEN $1 AND $2
  AND m.role = 'assistant'
GROUP BY s.model_id
ORDER BY input_tokens DESC
```

**Phase 2 (when billing ships):** Switch to `usage_daily_summaries` for fast pre-aggregated queries. The endpoint response shape stays the same — only the data source changes.

Cached in Valkey for 15 minutes since analytics data is not time-critical.

---

## 11. Database Changes

### Migration 1: Indexes for Admin Queries

Admin aggregate queries across all workspaces need indexes that don't start with `workspace_id`:

```ruby
class AddAdminQueryIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Session aggregates for workspace overview
    add_index :sessions, [:workspace_id, :status],
              name: "idx_sessions_workspace_status",
              algorithm: :concurrently,
              if_not_exists: true

    # Message date-range queries for usage analytics
    add_index :messages, :created_at,
              name: "idx_messages_created_at",
              algorithm: :concurrently,
              if_not_exists: true

    # User status filtering
    add_index :users, :status,
              name: "idx_users_status",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
```

### No Schema Changes to Users Table

Admin identity lives in ENV, not the database. No migration needed for the admin flag.

### Admin DB Role Setup Script

Not a Rails migration — run once per environment as superuser:

```sql
-- scripts/setup_admin_role.sql
CREATE ROLE admin_user LOGIN PASSWORD :'admin_password' INHERIT;
GRANT USAGE ON SCHEMA public TO admin_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO admin_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO admin_user;
ALTER ROLE admin_user BYPASSRLS;

-- Targeted write grants
GRANT UPDATE (status) ON users TO admin_user;
```

---

## 12. Frontend

### Route Structure

Add React Router to the frontend. Admin pages live under `/admin`:

```
/              → Chat (existing AppShell)
/admin         → AdminDashboard
/admin/users   → UserList
/admin/spaces  → WorkspaceList
/admin/spaces/:id → WorkspaceDetail
/admin/usage   → UsageAnalytics
```

### Auth Gate

After login, the frontend calls `GET /api/v1/admin/dashboard`. A `200` response means the user is admin — set `isAdmin: true` in `AuthContext`. A `403` means not admin — hide admin navigation. Admin routes are wrapped in an `AdminRoute` guard component that redirects non-admins.

This is a frontend convenience only — the backend enforces admin access on every request.

### Page & Component Hierarchy

```
frontend/src/
  pages/
    admin/
      AdminDashboard.tsx       # Stat cards for users, workspaces, tokens, GoodJob
      UserList.tsx             # Paginated table, status filter, approve/suspend
      WorkspaceList.tsx        # Paginated table with aggregate stats
      WorkspaceDetail.tsx      # Agents list, session metadata timeline
      UsageAnalytics.tsx       # Date picker, model breakdown table
  components/
    admin/
      AdminLayout.tsx          # Admin-specific layout with sidebar nav
      AdminRoute.tsx           # Route guard: redirects non-admins to /
      StatCard.tsx             # Reusable metric display (DaisyUI stat)
      DataTable.tsx            # Sortable, paginated table (DaisyUI table)
      StatusBadge.tsx          # Colored badges for user/session status
  services/
    adminApi.ts                # Admin API client (typed fetch wrappers)
  types/
    admin.ts                   # Admin TypeScript types
```

### Code Splitting

Admin pages are lazy-loaded via `React.lazy()` + `Suspense`. Regular users never download the admin JS bundle:

```tsx
const AdminDashboard = React.lazy(() => import("./pages/admin/AdminDashboard"));
```

### DaisyUI Components

Use existing DaisyUI components for the admin UI:
- `stat` — dashboard metric cards
- `table` — data tables with zebra striping
- `badge` — status indicators (pending=warning, active=success, suspended=error)
- `btn` — action buttons (approve, suspend)
- `tabs` — workspace detail sub-sections
- `pagination` — table pagination

---

## 13. GoodJob Dashboard Integration

The existing GoodJob dashboard at `/good_job` should be gated behind admin auth (see §2.1) and linked from the admin dashboard page. The admin frontend includes a link/button to open `/good_job` in a new tab rather than embedding it in the React SPA.

---

## 14. Security Hardening

### Rate Limiting

Admin endpoints are high-value targets. Apply Rack::Attack throttle:

```ruby
# config/initializers/rack_attack.rb
Rack::Attack.throttle("admin_api", limit: 60, period: 60) do |request|
  request.ip if request.path.start_with?("/api/v1/admin")
end
```

### Statement Timeout

All admin queries execute with a 5-second PostgreSQL `statement_timeout` (set in `AdminBaseController`). This prevents expensive cross-workspace queries from degrading the database for regular users.

### Audit Logging

All admin state-change actions (approve, suspend, unsuspend) are logged with structured metadata:

```
[Admin] admin@dailywerk.com approved user jane@example.com (pending -> active)
```

A dedicated `admin_audit_logs` table is deferred to Phase 3. Rails structured logging is sufficient for the MVP.

### Input Validation

- `workspace_id` and `user_id` path params validated as UUID format before reaching the database
- Date range params (`start_date`, `end_date`) validated and capped at 90-day max range
- Pagination params capped: `per_page` max 100, `page` must be positive integer

---

## 15. Implementation Phases

### Phase 0: Prerequisites

- Fix `SET` → `SET LOCAL` in `Authentication` concern (§2.2)
- Gate GoodJob dashboard behind admin auth (§2.1)
- Create `admin_user` DB role (§4, §11)

### Phase 1: Core Admin MVP

- `AdminAuthentication` concern
- `AdminRecord` base class with `connects_to`
- Admin base controller with statement timeout
- Dashboard endpoint (cached system aggregates)
- User list with status filtering
- User approve/suspend/unsuspend actions
- Workspace list endpoint
- Frontend: React Router, AdminLayout, AdminDashboard, UserList
- Admin route guard in React
- Admin query indexes migration

### Phase 2: Detail Views & Analytics

- Workspace detail endpoint (agents + session metadata)
- Usage analytics endpoint (date range, model grouping)
- Frontend: WorkspaceDetail, UsageAnalytics pages
- Valkey caching for analytics queries
- Rate limiting (Rack::Attack)

### Phase 3: Hardening & Polish (Deferred)

- Admin audit log table
- Chart visualizations for usage trends
- Notification on new pending user registration
- Migrate usage analytics to `usage_daily_summaries` when billing tables ship
- WorkOS RBAC integration for admin identity (when WorkOS auth ships)

---

## 16. Open Questions

1. **Admin DB role in development** — Should dev mode use the admin role or just use the superuser (which bypasses RLS anyway)? Superuser is simpler for dev but doesn't validate the admin role grants.
2. **Streaming responses and `SET LOCAL`** — The `SET LOCAL` fix (§2.2) wraps actions in a transaction. Streaming LLM responses may need to send data before the transaction commits. Evaluate whether streaming actions need a different approach (e.g., advisory locks instead of `SET LOCAL`).
3. **Admin token lifetime** — Should admin tokens have a shorter expiry than regular user tokens (currently 12 hours)?
4. **Workspace deletion** — Not in scope for Phase 1, but when needed: ActiveRecord cascading deletes under RLS are problematic. Workspace deletion should run through the `admin_user` role or a dedicated `WorkspaceDeletionService` ([PRD 01 §8.6](./01-platform-and-infrastructure.md#8-open-questions)).
