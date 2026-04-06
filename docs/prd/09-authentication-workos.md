---
type: prd
title: Authentication — WorkOS Integration
domain: platform
created: 2026-04-06
updated: 2026-04-06
status: canonical
depends_on:
  - prd/01-platform-and-infrastructure
implemented_by:
  - rfc/2026-04-06-workos-authentication
---

# DailyWerk — Authentication (WorkOS)

> Canonical reference for authentication, session management, and identity sync.
> For workspace isolation and RLS: see [01-platform-and-infrastructure.md](./01-platform-and-infrastructure.md) §4.
> For billing and BYOK: see [04-billing-and-operations.md](./04-billing-and-operations.md).

---

## 1. What This Covers

WorkOS provides authentication (SSO, social login, magic links) and identity management for DailyWerk. This PRD defines the token strategy, OAuth flow, webhook-based identity sync, and environment configuration across dev/staging/production.

DailyWerk is an API-only Rails backend with a React SPA frontend. This architecture drives specific security constraints that differ from server-rendered applications.

---

## 2. Authentication Architecture

```
React SPA                    Rails API (Falcon)              WorkOS
────────                     ──────────────────              ──────
  │ click "Sign In"
  │──GET /api/v1/auth/login──▶│
  │                           │ generate PKCE + state
  │                           │ set encrypted HttpOnly cookie
  │◀─ { authorization_url } ──│
  │
  │─ redirect to WorkOS ─────────────────────────────────────▶│
  │                                                           │ user authenticates
  │◀─ redirect /auth/callback?code=...&state=... ────────────│
  │
  │──GET /auth/callback──────▶│
  │                           │ validate state (from cookie)
  │                           │ exchange code + code_verifier ─▶│
  │                           │◀─ access_token + refresh_token ─│
  │                           │ find/create User + Workspace
  │                           │ store refresh_token (encrypted DB)
  │                           │ set HttpOnly session cookie
  │◀─ redirect to SPA ───────│
  │
  │──GET /api/v1/auth/me─────▶│ (cookie sent automatically)
  │◀─ { access_token, user, workspace } ─│
  │
  │ store JWT in memory
  │ use as Bearer token ─────▶│ validate JWT via JWKS
```

---

## 3. Token Strategy

| Token | Lifetime | Storage | Purpose |
|-------|----------|---------|---------|
| **Access token** (WorkOS JWT) | ~15 min (WorkOS-controlled) | SPA memory only | Bearer token for every API + WebSocket request |
| **Refresh token** | ~30 days (WorkOS-controlled) | `user_sessions` table, `ActiveRecord::Encryption` | Server-side only; never exposed to frontend |
| **Session ID** | Until logout or expiry | `HttpOnly`, `Secure`, `SameSite=Strict` cookie | Links browser to server-side session for token refresh |
| **PKCE state** | 10 minutes | Encrypted `HttpOnly` cookie | OAuth flow CSRF protection; deleted after callback |

### 3.1 Why HttpOnly Cookie for Session ID

An API-only SPA typically stores tokens in `localStorage`, but:

- `localStorage` is readable by any JavaScript on the page — an XSS vulnerability can exfiltrate the token.
- WorkOS JWTs are self-contained — a stolen JWT grants access without needing a server secret.
- An `HttpOnly` cookie is invisible to JavaScript, immune to XSS exfiltration, and sent automatically by the browser.

The trade-off: adding one `HttpOnly` cookie to an otherwise stateless API. `SameSite=Strict` prevents CSRF without needing Rails CSRF middleware. The SPA and API must share a root domain.

### 3.2 Why JWT in Memory Only

Storing the access token in React state (not `localStorage`) means:

- A page refresh loses the JWT — the SPA must call `GET /api/v1/auth/me` to restore it (~50ms, cookie-based).
- No XSS risk for the short-lived access token.
- Cross-tab sync uses `BroadcastChannel` instead of `StorageEvent`.

### 3.3 Why PKCE Instead of Server-Side State

PKCE (Proof Key for Code Exchange) is the modern standard for OAuth in SPAs:

- Eliminates the need for server-side state storage (no Valkey dependency for auth).
- The `code_verifier` lives in an encrypted `HttpOnly` cookie, tied to the browser that initiated the flow.
- WorkOS supports PKCE natively.

---

## 4. JWT Validation (JWKS)

Access tokens are validated on every request using WorkOS's JSON Web Key Set:

- **Endpoint**: `https://api.workos.com/sso/jwks/<client_id>`
- **Algorithm**: RS256
- **Claims validated**: `iss` (issuer), `aud` (client_id), `exp` (expiry), `sub` (WorkOS user ID)

### 4.1 Caching Strategy

| Layer | Store | TTL | Purpose |
|-------|-------|-----|---------|
| L1 | `Concurrent::Map` (in-process) | Until key miss | Fiber-safe, zero-latency reads |
| L2 | Valkey | 1 hour | Shared across Falcon worker processes |
| Boot | Eager fetch in initializer | — | Prevents cold-start latency |

**Key rotation**: On signature verification failure with an unknown `kid`, refetch JWKS once from WorkOS, update both caches. If still unrecognized, reject the token.

### 4.2 Fiber Safety

The `workos` gem uses `Net::HTTP`, which hooks into Ruby's fiber scheduler on Ruby 3.2+. On DailyWerk's Ruby 4.0.2, JWKS fetches are non-blocking. The in-process cache (`Concurrent::Map`) is eagerly initialized — no lazy `||=` patterns.

---

## 5. WorkOS Organization Mapping

WorkOS Organizations map to DailyWerk Workspaces for Enterprise SSO and SCIM support:

| WorkOS Concept | DailyWerk Concept | Mapping |
|----------------|-------------------|---------|
| User | User | `users.workos_id` |
| Organization | Workspace | `workspaces.workos_organization_id` |
| Organization Membership | WorkspaceMembership | Via webhook sync |

### 5.1 Why Map Organizations to Workspaces

WorkOS ties SSO connections (SAML, OIDC) and directory sync (SCIM) to Organizations. If a corporate customer wants their employees to log into DailyWerk via Okta or Azure AD, WorkOS requires passing the `organization_id` to the authorization URL. Without a mapping, Enterprise SSO cannot work.

### 5.2 Workspace Resolution

When a user authenticates, the JWT contains an `org_id` claim:

1. Look up `Workspace.find_by(workos_organization_id: jwt["org_id"])` → use that workspace.
2. Fall back to `user.default_workspace` (first workspace by membership creation date).
3. Future: workspace chooser UI when user belongs to multiple workspaces.

### 5.3 First-Time User Flow

When a new user authenticates via WorkOS for the first time:

1. `WorkosAuthService` looks up by `workos_id` — not found.
2. Looks up by `email` — if found, links `workos_id` to existing user.
3. If not found, creates new User + default Workspace + WorkspaceMembership (role: `owner`).

---

## 6. Session Management

### 6.1 User Sessions Table

`user_sessions` stores server-side session state:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid (PK) | Session identifier, set in HttpOnly cookie |
| `user_id` | uuid (FK) | Owning user |
| `refresh_token` | text (encrypted) | WorkOS refresh token, `ActiveRecord::Encryption` |
| `workos_session_id` | string | WorkOS session ID for logout URL generation |
| `expires_at` | datetime | Session expiry (matches refresh token lifetime) |
| `revoked_at` | datetime | Null = active; set on explicit logout or user deactivation |
| `ip_address` | string | Audit trail |
| `user_agent` | string | Audit trail |

**Not workspace-scoped** — a user session precedes workspace selection. No RLS policy needed.

### 6.2 Token Refresh Flow

```
SPA detects JWT expires within 2 minutes (decoded client-side)
  → POST /api/v1/auth/refresh (HttpOnly cookie sent automatically)
  → Rails loads UserSession from cookie session_id
  → Decrypts stored refresh_token
  → Calls WorkOS SDK authenticate_with_refresh_token
  → Stores new refresh_token (if rotated)
  → Returns { access_token } to SPA
  → SPA replaces in-memory JWT
```

**Deduplication**: The SPA maintains a single in-flight refresh promise. Multiple concurrent requests that detect near-expiry share the same promise instead of triggering parallel refreshes.

### 6.3 Logout

```
SPA: DELETE /api/v1/auth/logout (HttpOnly cookie sent automatically)
  → Rails revokes UserSession (sets revoked_at)
  → Clears HttpOnly session cookie
  → Returns { logout_url } (WorkOS logout URL with session_id)
  → SPA: window.location.href = logout_url (clears WorkOS session)
```

### 6.4 Session Cleanup

A GoodJob cron job (`WorkosSessionCleanupJob`) deletes revoked and expired sessions older than 30 days.

---

## 7. ActionCable Authentication

WebSocket URLs expose credentials in server logs and browser history. DailyWerk uses a **one-time ticket** pattern:

```
SPA: POST /api/v1/auth/websocket_ticket (Bearer JWT)
  → Rails generates UUID ticket
  → Stores in Valkey: ws_ticket:<uuid> → { user_id, workspace_id } (15-second TTL)
  → Returns { ticket }

SPA: connect wss://host/cable?ticket=<uuid>
  → ActionCable connection.rb reads ticket from params
  → Valkey lookup → user_id + workspace_id → delete ticket
  → Reject if ticket expired or missing
```

---

## 8. Webhook System

WorkOS sends webhooks for identity lifecycle events. DailyWerk processes them asynchronously via GoodJob.

### 8.1 Events

| WorkOS Event | DailyWerk Action |
|-------|-----------------|
| `user.updated` | Sync email, name to `users` table |
| `user.deleted` | Set `users.status = "suspended"`, revoke all UserSessions |
| `organization_membership.created` | Create WorkspaceMembership (if workspace exists) |
| `organization_membership.updated` | Update role |
| `organization_membership.deleted` | Remove WorkspaceMembership |

### 8.2 Webhook Security

- **HMAC-SHA256 signature verification** using `WORKOS_WEBHOOK_SECRET`
- Signature in `WorkOS-Signature` header, format: `v1=<hex-digest>`
- Constant-time comparison via `OpenSSL.fixed_length_secure_compare`

### 8.3 Processing

Webhook controller validates signature and immediately enqueues `WorkosWebhookJob`:

- `queue_as :default`
- `retry_on StandardError, wait: :exponentially_longer, attempts: 5`
- `discard_on ActiveRecord::RecordNotFound`

### 8.4 Race Conditions

The OAuth callback is the primary user creation path. Webhook handlers use `find_or_create_by(workos_id:)` with a rescue on uniqueness constraint to handle the case where a `user.created` webhook arrives simultaneously with the first login.

---

## 9. Environment Strategy

| Rails env | WorkOS env | Auth behavior |
|-----------|-----------|---------------|
| `development` | dev WorkOS project (optional) | `WORKOS_API_KEY` present → WorkOS flow. Absent → dev-only SessionsController (existing). `/api/v1/auth/config` returns `{ provider: "dev" }` or `"workos"` |
| `test` | none | Test JWKS keypair generates valid JWTs. MessageVerifier fallback in `verify_token`. No WorkOS API calls. |
| `staging` | staging WorkOS project | Full WorkOS flow |
| `production` | production WorkOS project | Full WorkOS flow. Dev SessionsController returns 404 |

### 9.1 Environment Variables

| Variable | Purpose | Required In |
|----------|---------|------------|
| `WORKOS_API_KEY` | Server-side API key for WorkOS SDK | staging, production |
| `WORKOS_CLIENT_ID` | Client ID for OAuth and JWKS | staging, production |
| `WORKOS_REDIRECT_URI` | OAuth callback URL | staging, production |
| `WORKOS_WEBHOOK_SECRET` | HMAC secret for webhook verification | staging, production |

### 9.2 WorkOS Dashboard Configuration (Per Environment)

1. **Redirect URIs**: `http://localhost:5173/auth/callback` (dev), staging/prod URLs
2. **Webhook endpoint**: `https://<host>/webhooks/workos`
3. **Webhook events**: `user.*`, `organization_membership.*`
4. **Authentication methods**: Email + password, Google OAuth, magic links (configurable per environment)

### 9.3 Local Development Without WorkOS

The existing `Api::V1::SessionsController` remains as a dev-only fallback, gated by `Rails.env.local?`. The SPA `LoginPage` detects the auth mode via `GET /api/v1/auth/config` and renders either a "Sign in" button (WorkOS) or an email form (dev). Both paths ultimately produce a Bearer token that the `Authentication` concern validates — the rest of the app is unaware of which auth provider was used.

---

## 10. Dependencies

| Gem | Version | Purpose |
|-----|---------|---------|
| `workos` | ~> 5.0 | WorkOS Ruby SDK — authorization URLs, code exchange, refresh tokens |
| `jwt` | ~> 2.9 | JWT decoding and JWKS-based verification |

Both gems use `Net::HTTP` internally, which is fiber-safe on Ruby 4.0.2.

---

## 11. Open Questions

1. **Workspace chooser UI** — When a user belongs to multiple workspaces, how do they switch? Current implementation uses `default_workspace`. A workspace switcher is needed before multi-workspace users exist. Deferred.
2. **Admin impersonation** — FileWerk has impersonation support via WorkOS. DailyWerk will need this for the admin interface ([08-admin-interface.md](./08-admin-interface.md)). Deferred to admin PRD.
3. **SCIM directory sync** — WorkOS Organizations enable SCIM provisioning. The mapping exists (`workos_organization_id` on workspaces) but the sync service is deferred to post-MVP.
4. **Session concurrency** — Should there be a limit on active sessions per user? Currently unlimited. Monitor and add if abuse is detected.
