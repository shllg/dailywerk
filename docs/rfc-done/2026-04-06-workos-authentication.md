---
type: rfc
title: WorkOS Authentication
created: 2026-04-06
updated: 2026-04-06
status: draft
implements:
  - prd/09-authentication-workos
phase: 1
---

# RFC: WorkOS Authentication

## Context

DailyWerk has placeholder authentication designed from day one to be replaced by WorkOS. The `User` model has a `workos_id` column, and TODO markers across six files explicitly reference the WorkOS migration. The existing dev-only `SessionsController` issues Rails MessageVerifier tokens that work identically to WorkOS JWTs from the downstream code's perspective — both are Bearer tokens that resolve to a user and workspace.

FileWerk (`/home/sascha/src/filewerk/rails`) provides a mature reference implementation with ~95 WorkOS-related files. However, FileWerk is server-rendered with cookie sessions, whereas DailyWerk is an API-only backend with a React SPA. This architectural difference drives the core design decisions in this RFC.

## Decision

Integrate WorkOS AuthKit using a **server-mediated OAuth flow with HttpOnly cookie session management and PKCE**. The Rails API handles the full OAuth dance, stores refresh tokens server-side, and issues access tokens (WorkOS JWTs) to the SPA via a cookie-protected endpoint. The SPA stores the JWT in memory only and sends it as a Bearer token on every request.

### Why Server-Mediated OAuth (Not SPA Public Client)

A public client (SPA doing the code exchange directly) would require the SPA to handle refresh tokens, which means storing them in `localStorage` (XSS-vulnerable) or `sessionStorage` (lost on tab close). A server-mediated flow keeps refresh tokens entirely server-side.

### Why HttpOnly Cookie for Session ID

The session cookie is the bridge between "stateless API" and "persistent browser session":

- It is invisible to JavaScript (immune to XSS).
- `SameSite=Strict` prevents CSRF without Rails CSRF middleware.
- The SPA and API share a root domain, so cookies flow automatically.
- On page refresh, the SPA calls `GET /api/v1/auth/me` — the cookie restores the session in ~50ms.

### Why PKCE Instead of Valkey-Stored State

PKCE is the OAuth 2.1 standard for code exchange security:

- No server-side state store needed — the `code_verifier` lives in an encrypted HttpOnly cookie.
- The `state` parameter (also in the cookie) prevents login CSRF.
- WorkOS supports PKCE natively.
- Eliminates a Valkey dependency from the auth critical path.

### Why WorkOS Organizations Map to Workspaces

WorkOS ties SSO connections (SAML/OIDC) and directory sync (SCIM) to Organizations. Without a mapping, enterprise customers cannot use their corporate IdP. Adding `workos_organization_id` to workspaces now avoids a painful retrofit later. The column is nullable — personal workspaces without a WorkOS org continue to work.

### Why Ticket-Based ActionCable Auth

The current approach passes the auth token as `?token=` in the WebSocket URL. With short-lived JWTs, this exposes credentials in server access logs, proxy logs, and browser history. A one-time Valkey ticket (15-second TTL, deleted after use) keeps the JWT out of URLs.

---

## Data Model

### New: `user_sessions`

```ruby
create_table :user_sessions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
  t.references :user, type: :uuid, null: false, foreign_key: true, index: true
  t.text :refresh_token                # ActiveRecord::Encryption (non-deterministic)
  t.string :workos_session_id          # WorkOS session ID (for logout URL)
  t.datetime :expires_at, null: false
  t.datetime :revoked_at               # null = active
  t.string :ip_address
  t.string :user_agent
  t.timestamps
end

add_index :user_sessions, :workos_session_id, unique: true,
          where: "workos_session_id IS NOT NULL"
```

Not workspace-scoped. No RLS policy. A user session precedes workspace selection.

### Modified: `workspaces`

```ruby
add_column :workspaces, :workos_organization_id, :string
add_index :workspaces, :workos_organization_id, unique: true,
          where: "workos_organization_id IS NOT NULL"
```

---

## Implementation

### Phase 1: Foundation

No auth behavior changes. Everything is additive and independently testable.

**New files:**

| File | Purpose |
|------|---------|
| `config/initializers/workos.rb` | WorkOS SDK config, ENV validation, `WorkOS::DailyWerk` constants |
| `db/migrate/XXX_create_user_sessions.rb` | User sessions table |
| `db/migrate/XXX_add_workos_organization_id_to_workspaces.rb` | WorkOS org mapping |
| `app/models/user_session.rb` | Encrypted refresh token storage, session lifecycle |
| `app/services/workos_jwks_service.rb` | JWKS fetch, L1/L2 caching, JWT verification |

**Modified files:**

| File | Change |
|------|--------|
| `Gemfile` | Add `workos ~> 5.0`, `jwt ~> 2.9` |
| `app/models/user.rb` | Add `has_many :user_sessions, dependent: :destroy` |

**WorkOS initializer:**
- Configure SDK with `ENV["WORKOS_API_KEY"]`
- Validate required vars in non-test envs (warn, don't crash — allows dev without WorkOS)
- Define `WorkOS::DailyWerk` module: `SESSION_COOKIE_NAME`, `STATE_COOKIE_EXPIRY`, `WS_TICKET_TTL`
- Eager-load JWKS via `after_initialize` hook (skip in test)

**JWKS service:**
- Class method `verify_token(jwt_string)` → decoded payload hash or nil
- L1: `Concurrent::Map` (eagerly initialized, fiber-safe)
- L2: Valkey (`workos:jwks` key, 1hr TTL)
- On unknown `kid`: refetch once, update both caches, then fail if still unknown
- Validate: `iss`, `aud` (client_id), `exp`, `iat`

**Tests:**
- `test/models/user_session_test.rb` — encryption round-trip, scopes, revoke
- `test/services/workos_jwks_service_test.rb` — fixture RS256 keypair, valid/expired/wrong-aud tokens

### Phase 2: Backend Auth Flow

**New files:**

| File | Purpose |
|------|---------|
| `app/services/workos_auth_service.rb` | OAuth URL (PKCE), code exchange, user find/create, token refresh |
| `app/controllers/auth/callbacks_controller.rb` | Handles browser redirect from WorkOS |
| `app/controllers/api/v1/auth_controller.rb` | `login`, `me`, `refresh`, `logout`, `config`, `websocket_ticket` |

**Modified files:**

| File | Change |
|------|--------|
| `app/controllers/concerns/authentication.rb` | Replace `verify_token`: try JWKS JWT first, MessageVerifier fallback in `Rails.env.local?`. Remove `issue_token`/`session_token_verifier`. Add `resolve_workspace_from_jwt`. |
| `app/controllers/api/v1/sessions_controller.rb` | Move `issue_token`/`session_token_verifier` here (dev-only) |
| `config/routes.rb` | Add auth + webhook routes |
| `test/test_helper.rb` | Add `workos_auth_headers` helper using test JWKS keypair |

**WorkOS auth service:**

```ruby
class WorkosAuthService
  def authorization_url(redirect_uri:)
    # Generate PKCE code_verifier + code_challenge
    # Generate state nonce
    # Return { authorization_url, state, code_verifier }
  end

  def exchange_code(code:, code_verifier:, ip_address: nil, user_agent: nil)
    # Call WorkOS SDK with code + code_verifier
    # Find or create user (workos_id → email → new)
    # Ensure default workspace
    # Create UserSession with encrypted refresh_token
    # Return UserSession
  end

  def refresh_access_token(user_session:)
    # Decrypt stored refresh_token
    # Call WorkOS SDK authenticate_with_refresh_token
    # Update stored refresh_token if rotated
    # Return { access_token }
  end

  def logout_url(user_session:)
    # WorkOS::UserManagement.get_logout_url(session_id:)
  end

  private

  def find_or_create_user(workos_user:)
    # 1. User.find_by(workos_id:) → update email/name, return
    # 2. User.find_by(email:) → link workos_id, return
    # 3. Create User + Workspace + WorkspaceMembership(owner)
  end
end
```

**Auth callbacks controller** (outside API namespace — handles browser redirect):

```ruby
class Auth::CallbacksController < ActionController::API
  def show
    # Read state + code_verifier from encrypted PKCE cookie
    # Validate state matches params[:state]
    # Exchange code via WorkosAuthService
    # Set HttpOnly session cookie (session_id)
    # Clear PKCE cookie
    # Redirect to SPA /auth/callback
  end
end
```

**API auth controller:**

```ruby
class Api::V1::AuthController < ApplicationController
  skip_authentication! :login, :me, :refresh, :config

  def login   # GET — generate PKCE, set cookie, return { authorization_url }
  def me      # GET — read session cookie → return { access_token, user, workspace }
  def refresh # POST — read session cookie → refresh → return { access_token }
  def logout  # DELETE — revoke session, clear cookie → { logout_url }
  def config  # GET — return { provider: "workos" | "dev" }
  def websocket_ticket  # POST — authenticated, Valkey ticket → { ticket }
end
```

**Authentication concern changes:**

```ruby
def verify_token(token)
  if (payload = WorkosJwksService.verify_token(token))
    workos_id = payload["sub"]
    user = User.active.find_by(workos_id: workos_id)
    return nil unless user
    workspace_id = resolve_workspace_from_jwt(payload, user)
    { "user_id" => user.id, "workspace_id" => workspace_id }
  elsif Rails.env.local?
    session_token_verifier.verified(token, purpose: :api_session)
  end
rescue ActiveSupport::MessageVerifier::InvalidSignature
  nil
end

def resolve_workspace_from_jwt(payload, user)
  org_id = payload["org_id"]
  if org_id.present?
    Workspace.find_by(workos_organization_id: org_id)&.id
  end || user.default_workspace&.id
end
```

**Routes:**

```ruby
# Browser redirect from WorkOS (outside API namespace)
get "auth/callback", to: "auth/callbacks#show"

# Webhook
post "webhooks/workos", to: "webhooks/workos#handle"

# API auth endpoints
namespace :api do
  namespace :v1 do
    get  "auth/login",  to: "auth#login"
    get  "auth/me",     to: "auth#me"
    post "auth/refresh", to: "auth#refresh"
    delete "auth/logout", to: "auth#logout"
    get  "auth/config", to: "auth#config"
    post "auth/websocket_ticket", to: "auth#websocket_ticket"
  end
end
```

**Tests:**
- `test/services/workos_auth_service_test.rb` — stub WorkOS SDK, test find/create/link user flows
- `test/controllers/auth/callbacks_controller_test.rb` — stub WorkOS, test full callback flow with cookie
- `test/controllers/api/v1/auth_controller_test.rb` — test me/refresh/logout with session cookie

### Phase 3: Frontend Auth Flow

**New files:**

| File | Purpose |
|------|---------|
| `frontend/src/services/authApi.ts` | Bare `fetch` wrappers for auth endpoints (with `credentials: 'include'`) |
| `frontend/src/pages/AuthCallbackPage.tsx` | Post-OAuth redirect handler → calls `/auth/me` → navigates to `/chat` |

**Modified files:**

| File | Change |
|------|--------|
| `frontend/src/contexts/AuthContext.tsx` | JWT in React state (not localStorage). `login()` → redirect. Token refresh timer. Session restore on mount via `getMe()`. `BroadcastChannel` for cross-tab sync. |
| `frontend/src/pages/LoginPage.tsx` | Dual-mode: WorkOS "Sign in" button vs dev email form (based on `/auth/config`) |
| `frontend/src/services/api.ts` | Remove localStorage token read. Accept token via module getter. Add refresh-on-401 interceptor with single-promise deduplication. |
| `frontend/src/services/cable.ts` | Ticket-based WebSocket auth |
| `frontend/src/App.tsx` | Add `/auth/callback` route outside auth guard |
| `frontend/src/types/auth.ts` | Update response types |

**Auth context changes:**
- `login()`: check auth config → if WorkOS, get authorization URL, redirect browser. If dev, show email form.
- On mount: call `getMe()` → if session cookie valid, receive JWT. If not, user stays logged out.
- Refresh: `setInterval` checks JWT `exp` (decoded client-side). When <2min from expiry, call `refreshToken()`.
- Cross-tab: `BroadcastChannel('dailywerk_auth')` — broadcast logout and token refresh events.

### Phase 4: Webhooks + ActionCable

**New files:**

| File | Purpose |
|------|---------|
| `app/controllers/webhooks/workos_controller.rb` | HMAC signature verification, dispatch to GoodJob |
| `app/jobs/workos_webhook_job.rb` | Event routing with retry |
| `app/services/workos_sync/user_sync_service.rb` | Sync user email/name from webhook |

**Modified files:**

| File | Change |
|------|--------|
| `app/channels/application_cable/connection.rb` | Replace `request.params[:token]` with Valkey ticket lookup |

**Webhook controller** (adapted from FileWerk `webhooks/workos_controller.rb`):
- `verify_webhook_signature` before_action
- HMAC-SHA256: `v1=#{OpenSSL::HMAC.hexdigest('sha256', secret, raw_post)}`
- `OpenSSL.fixed_length_secure_compare` for timing-safe comparison
- Strong params on payload → `WorkosWebhookJob.perform_later`

**Webhook job:**
- `user_updated` → `WorkosSync::UserSyncService` (update email/name)
- `user_deleted` → suspend user, revoke all sessions
- `organization_membership.*` → future: workspace membership sync

**ActionCable ticket auth:**
```ruby
def connect
  ticket = request.params[:ticket]
  reject_unauthorized_connection unless ticket.present?

  data = Rails.application.config.valkey.call("GET", "ws_ticket:#{ticket}")
  reject_unauthorized_connection unless data

  Rails.application.config.valkey.call("DEL", "ws_ticket:#{ticket}")
  parsed = JSON.parse(data)

  self.current_user = User.find(parsed["user_id"])
  self.current_workspace = Workspace.find(parsed["workspace_id"])
rescue ActiveRecord::RecordNotFound
  reject_unauthorized_connection
end
```

### Phase 5: Hardening + Cutover

1. **Eager JWKS loading**: `Rails.application.config.after_initialize { WorkosJwksService.warm_cache }` (skip in test)
2. **Session cleanup**: GoodJob cron — `WorkosSessionCleanupJob` deletes expired/revoked sessions >30 days
3. **Cross-tab sync**: `BroadcastChannel('dailywerk_auth')` in AuthContext
4. **Monitor dual-auth**: Log when MessageVerifier fallback is used
5. **Remove dev fallback from production**: Once staging is confirmed working

---

## Migration Path

### Dual-Auth Transition

The transition is non-breaking:

1. Deploy Phase 1-4 with dual-auth `verify_token` (JWT primary, MessageVerifier fallback).
2. All existing dev/test sessions continue working (MessageVerifier fallback).
3. Deploy frontend with dual-mode LoginPage.
4. Test WorkOS flow end-to-end in staging.
5. Existing users without `workos_id`: linked by email on first WorkOS login.
6. After confirmation, remove MessageVerifier fallback from `verify_token` in production.
7. `SessionsController` remains for local development permanently.

### Zero-Downtime

- `user_sessions` is a new table — no locking.
- `workos_organization_id` is a nullable column add — no locking.
- `verify_token` changes are backwards-compatible (dual-mode).
- Frontend changes are additive (new routes, modified login flow).

---

## Consequences

### Positive

- Authentication via industry-standard provider (SSO, social login, magic links)
- Enterprise SSO/SCIM ready via WorkOS Organization mapping
- Refresh tokens never touch the browser — immune to XSS
- PKCE eliminates server-side state dependency for OAuth
- ActionCable credentials no longer appear in logs
- Local development continues to work without WorkOS

### Negative

- Adding one HttpOnly cookie to an otherwise stateless API
- Page refresh requires a network call to restore JWT (~50ms)
- JWKS cache miss adds ~200ms latency (mitigated by eager loading)
- Two gems added to dependency tree (`workos`, `jwt`)
- Webhook infrastructure adds operational surface area

---

## Reference Patterns

The WorkOS integration adapts proven patterns from FileWerk:

- **OAuth code exchange**: `workos_auth_service.rb:249-268`
- **User find-or-create**: `workos_auth_service.rb:285-334`
- **Webhook controller**: `webhooks/workos_controller.rb` (HMAC verification)
- **Webhook job**: `workos_webhook_job.rb` (event routing with retry)
- **User sync service**: `workos_sync/user_sync_service.rb`

Key adaptations for DailyWerk: PKCE instead of session-stored state, HttpOnly cookie instead of cookie session, ticket-based ActionCable auth, Minitest instead of RSpec, no Dry::Monads.
