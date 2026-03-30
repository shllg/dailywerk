---
type: rfc
title: Google Integration — Calendar & BYOA OAuth
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/02-integrations-and-channels
  - prd/01-platform-and-infrastructure
depends_on:
  - rfc/2026-03-30-workspace-isolation
phase: 3
---

# RFC: Google Integration — Calendar & BYOA OAuth

## Context

[PRD 02 §5](../prd/02-integrations-and-channels.md#5-calendar) specifies Google Calendar as the primary calendar integration, with bidirectional sync via OAuth 2.0. [PRD 02 §3](../prd/02-integrations-and-channels.md#3-email-integration) specifies Gmail API as the primary email path.

However, Gmail API scopes (`gmail.readonly`, `gmail.modify`, `gmail.send`) are classified as **restricted** by Google. Production apps requesting restricted scopes must pass the CASA (Cloud Application Security Assessment) — a paid annual third-party security audit ($540–4,500/year) with a 4–12 week verification timeline. This blocks Gmail API integration for an early-stage product.

Google Calendar scopes (`calendar.events`, `calendar.readonly`) are classified as **sensitive** only — free verification, no CASA, 1–4 week timeline.

This RFC implements two strategies:

1. **DailyWerk-managed OAuth** for Google Calendar (sensitive scopes, no CASA).
2. **Bring Your Own OAuth App (BYOA)** for Gmail and Calendar — users create their own Google Cloud project and supply credentials to DailyWerk, bypassing CASA entirely.

The BYOA pattern is well-established: n8n, Make/Integromat, Appsmith, and NocoDB all use it for Google restricted scopes.

## Decision

Build a unified Google OAuth infrastructure that supports two credential sources:

1. **Platform credentials** — DailyWerk's own GCP project, verified for sensitive Calendar scopes.
2. **User-supplied credentials (BYOA)** — user's own GCP project with their `client_id` and `client_secret`, enabling restricted Gmail scopes without DailyWerk going through CASA.

Both credential sources share the same OAuth callback endpoint, token storage, refresh logic, and API client layer. The difference is only which `client_id`/`client_secret` pair is used for the OAuth flow.

## Goals

- bidirectional Google Calendar sync with push notifications
- let power users connect Gmail via their own Google OAuth app
- workspace-scoped, encrypted credential storage
- token lifecycle management (refresh, revocation detection, cleanup)
- provider-agnostic patterns where possible (reusable for future Microsoft Graph, etc.)

## Non-Goals

- DailyWerk-managed Gmail OAuth (deferred to [PRD 06](../prd/06-gmail-direct-integration.md) pending CASA)
- Google Contacts / People API
- agent tool implementations (`email_read`, `calendar_create`, etc. — separate RFC)
- IMAP/SMTP integration (separate RFC)
- inbound email processing (separate RFC)

## Architecture

### Credential Sources

```
┌─────────────────────────────────────────────────────────────┐
│                    Google OAuth Flow                         │
│                                                             │
│  ┌──────────────────────┐   ┌────────────────────────────┐  │
│  │ Platform Credentials │   │ BYOA Credentials (per-user)│  │
│  │ (DailyWerk GCP)      │   │ (user's GCP project)       │  │
│  │                      │   │                            │  │
│  │ • Calendar scopes    │   │ • Calendar scopes          │  │
│  │ • Sensitive only     │   │ • Gmail scopes (restricted)│  │
│  │ • Verified by Google │   │ • No verification needed   │  │
│  └──────────┬───────────┘   └──────────────┬─────────────┘  │
│             │                              │                │
│             └──────────┬───────────────────┘                │
│                        ▼                                    │
│              Shared OAuth Callback                          │
│     POST /api/v1/google/callback                            │
│                        │                                    │
│                        ▼                                    │
│           Token Storage (encrypted)                         │
│           google_connections table                           │
│                        │                                    │
│                        ▼                                    │
│           API Client Layer                                  │
│     (google-apis-calendar_v3, google-apis-gmail_v1)         │
└─────────────────────────────────────────────────────────────┘
```

### OAuth Flow

Both credential sources use the standard server-side authorization code flow with PKCE:

1. **Initiate** — `GET /api/v1/google/authorize`
   - Frontend sends `{ credential_source: "platform" | "byoa", scopes: [...] }`
   - For BYOA: frontend also sends `byoa_credential_id` referencing stored client credentials
   - Backend generates `state` token (HMAC-signed, includes workspace_id + credential_source + nonce)
   - Backend generates PKCE `code_verifier` and `code_challenge`, stores verifier in Redis (keyed by state, TTL 10 min)
   - Backend returns Google authorization URL with `access_type=offline`, `prompt=consent`, `include_granted_scopes=true`

2. **Callback** — `GET /api/v1/google/callback`
   - Google redirects with `code` and `state`
   - Backend validates `state` HMAC, extracts workspace_id and credential_source
   - Backend retrieves PKCE `code_verifier` from Redis
   - Backend exchanges code for tokens using the appropriate client credentials
   - Backend stores `access_token`, `refresh_token`, `expires_at`, `granted_scopes` in `google_connections`
   - Backend redirects to frontend with success/error status

3. **Token Refresh** — automatic, before API calls
   - Check `expires_at` before each API call
   - If expired or within 5-minute buffer: refresh using stored `refresh_token`
   - If refresh fails (401/403): mark connection as `revoked`, notify user
   - Update `access_token` and `expires_at` in database

### Incremental Authorization

Google supports combining scopes across multiple authorization flows via `include_granted_scopes=true`. A user can:

1. Connect Calendar first (platform credentials, sensitive scopes)
2. Later add Gmail (BYOA credentials, restricted scopes)

Each authorization adds to the granted scope set. The `google_connections` table tracks `granted_scopes` as a string array to know what the connection can do.

**Important**: incremental authorization only works within the same GCP project. Platform Calendar + BYOA Gmail are separate projects, so they produce **separate connections** (two rows in `google_connections`). This is by design — it isolates credential lifecycle and revocation.

## BYOA Credential Management

### User Setup Process

The user performs these steps in Google Cloud Console (DailyWerk provides a step-by-step guide):

1. Create a Google Cloud project (or use an existing one)
2. Enable Gmail API (and optionally Calendar API)
3. Configure OAuth consent screen — external user type, app name, scopes
4. **Switch publishing status to "In Production"** (critical — Testing mode limits refresh tokens to 7-day expiry)
5. Create OAuth 2.0 Web Application credentials
6. Add redirect URI: `https://app.dailywerk.com/api/v1/google/callback`
7. Copy `client_id` and `client_secret` into DailyWerk settings

### Why "In Production" Mode

In Google's Testing mode, refresh tokens expire after 7 days. The user must re-authorize weekly. Switching to "In Production" (unverified) gives long-lived refresh tokens. The user sees an "unverified app" warning once during consent — since they're consenting to their own app, this is expected.

The 100-user lifetime cap on unverified production apps is irrelevant for BYOA — only the user themselves will authorize.

### Credential Storage

```ruby
# User-supplied OAuth app credentials
# Stored separately from the connection tokens
class ByoaCredential < ApplicationRecord
  include WorkspaceScoped

  encrypts :client_secret

  validates :provider, inclusion: { in: %w[google] }  # extensible
  validates :client_id, presence: true
  validates :client_secret, presence: true
end
```

BYOA credentials are **workspace-scoped** and isolated. One workspace's credentials can never be used by another workspace.

## Schema

### `google_connections` — OAuth Token Storage

Each row represents one authorized Google account connection to a workspace. A workspace may have multiple connections (e.g., platform Calendar + BYOA Gmail, or multiple Google accounts).

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `credential_source` | string | `platform` or `byoa` |
| `byoa_credential_id` | uuid FK | References `byoa_credentials` (null for platform) |
| `google_account_email` | string | Google account email (for display) |
| `google_account_id` | string | Google `sub` claim (stable account identifier) |
| `access_token_enc` | text | Encrypted access token |
| `refresh_token_enc` | text | Encrypted refresh token |
| `token_expires_at` | datetime | Access token expiry |
| `granted_scopes` | string[] | Array of granted OAuth scopes |
| `status` | string | `active`, `refresh_failed`, `revoked`, `disconnected` |
| `last_used_at` | datetime | Last successful API call |
| `last_error` | text | Last error message (for UI display) |
| `metadata` | jsonb | Extensible (e.g., user-selected calendars) |
| `created_at` | datetime | |
| `updated_at` | datetime | |

**Indexes**: `[workspace_id, credential_source]`, `[workspace_id, google_account_id]` unique per credential_source, `[status]`.

### `byoa_credentials` — User-Supplied OAuth App Credentials

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `provider` | string | `google` (extensible to `microsoft`, etc.) |
| `label` | string | User-defined label (e.g., "My Gmail OAuth App") |
| `client_id` | string | OAuth client ID |
| `client_secret_enc` | text | Encrypted OAuth client secret |
| `redirect_uri` | string | The redirect URI configured in the user's GCP project |
| `status` | string | `active`, `disabled` |
| `created_at` | datetime | |
| `updated_at` | datetime | |

**Indexes**: `[workspace_id, provider]`, `[workspace_id, client_id]` unique.

### `calendar_sync_states` — Per-Calendar Sync Tracking

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `google_connection_id` | uuid FK | Parent connection |
| `google_calendar_id` | string | Google Calendar ID (email-like) |
| `calendar_name` | string | Display name |
| `sync_direction` | string | `bidirectional`, `read_only`, `disabled` |
| `sync_token` | text | Google sync token for incremental sync |
| `watch_channel_id` | string | Push notification channel UUID |
| `watch_resource_id` | string | Google-assigned resource ID |
| `watch_expiry` | datetime | When the push channel expires |
| `last_synced_at` | datetime | Last successful sync |
| `last_error` | text | Last sync error |
| `metadata` | jsonb | User prefs (default duration, reminders, color) |
| `created_at` | datetime | |
| `updated_at` | datetime | |

**Indexes**: `[google_connection_id, google_calendar_id]` unique, `[watch_expiry]` (for renewal job).

## Google Calendar Sync

### Initial Setup

When a user connects Google Calendar:

1. OAuth flow completes → `google_connections` row created with `calendar.events` scope
2. Fetch calendar list (`calendarList.list`) → present to user
3. User selects which calendars to sync and direction (bidirectional/read-only)
4. For each selected calendar: create `calendar_sync_states` row
5. Run initial full sync → store events in `calendar_events` table (PRD 01 §5.7)
6. Register push notification channels (`events.watch`) for each calendar

### Incremental Sync

Google Calendar uses **sync tokens** for efficient incremental sync:

1. `events.list(syncToken: stored_token)` returns only changes since last sync
2. Deleted events come back with `status: "cancelled"` → delete locally
3. Store the new `nextSyncToken` from the response
4. If sync token is invalid (HTTP 410 Gone): wipe local events for that calendar and do a full re-sync

### Push Notifications

Google Calendar sends HTTPS webhook notifications when events change:

```
POST https://api.dailywerk.com/api/v1/google/calendar/webhook
X-Goog-Channel-ID: <watch_channel_id>
X-Goog-Resource-ID: <resource_id>
X-Goog-Resource-State: exists | sync
X-Goog-Channel-Expiration: <rfc2822-date>
```

On receiving a notification:
1. Look up `calendar_sync_states` by `watch_channel_id`
2. Resolve workspace from the sync state's connection
3. Enqueue `CalendarSyncJob` for that specific calendar

Notifications do not contain event data — they only signal that changes occurred. The job runs the incremental sync.

### Push Channel Renewal

Watch channels expire after ~7 days (server-determined). `RenewCalendarWatchJob` runs daily, finds channels expiring within 48 hours, and creates new channels. Overlapping channels are harmless — duplicate notifications just trigger the same idempotent sync.

### Conflict Resolution

Following PRD 02 §6 — **external wins**:

1. On each sync cycle, compare `external_updated_at` with local `updated_at`
2. If Google event is newer → update local `calendar_events` row
3. If local is newer → push to Google via `events.update`
4. If both changed since last sync → Google wins, log conflict for user review
5. Agent-created events always push to Google immediately (not batched)

### Bidirectional Sync Flow

```
Google Calendar ◄──► CalendarSyncJob ◄──► calendar_events table ◄──► Agent Tools
                          │
                          ├─ Pull: events.list(syncToken) → upsert calendar_events
                          ├─ Push: detect local changes → events.insert/update/delete
                          └─ Conflict: external wins, log for review
```

### Free/Busy Queries

Agents can check availability without syncing all events:

```ruby
# POST https://www.googleapis.com/calendar/v3/freeBusy
# Returns consolidated busy blocks for a time range
# Handles recurring events automatically
```

This is exposed as an agent tool capability (implementation in a separate RFC).

## Background Jobs

### `CalendarSyncJob`

Triggered by: push notification webhook, or cron fallback every 5 minutes.

```ruby
# Workspace-scoped, idempotent
# Runs incremental sync for a single calendar
# Handles 410 Gone (full re-sync), 401 (token refresh), rate limits (backoff)
class CalendarSyncJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default
  retry_on Google::Apis::RateLimitError, wait: :polynomially_longer, attempts: 5
end
```

### `RenewCalendarWatchJob`

Cron: daily. Finds `calendar_sync_states` where `watch_expiry < 48.hours.from_now`, creates new watch channels.

### `GoogleTokenRefreshJob`

Cron: hourly. Proactively refreshes tokens expiring within 30 minutes. Prevents API calls from hitting expired tokens.

### `GoogleConnectionHealthJob`

Cron: every 6 hours. For each active connection: attempt a lightweight API call (`calendarList.list` with `maxResults=1`). Mark connections as `refresh_failed` if both refresh and API call fail. Notify user via web UI.

### GoodJob Cron Additions

```ruby
renew_calendar_watch: {
  cron: "0 3 * * *",               # Daily at 3am
  class: "RenewCalendarWatchJob",
  description: "Renew Google Calendar push notification channels"
},
google_token_refresh: {
  cron: "0 * * * *",               # Hourly
  class: "GoogleTokenRefreshJob",
  description: "Proactively refresh Google OAuth tokens nearing expiry"
},
google_connection_health: {
  cron: "0 */6 * * *",             # Every 6 hours
  class: "GoogleConnectionHealthJob",
  description: "Health check Google connections, detect revocations"
}
```

## API Endpoints

### OAuth Flow

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/google/authorize` | Initiate OAuth flow, returns authorization URL |
| `GET` | `/api/v1/google/callback` | OAuth callback, exchanges code for tokens |
| `DELETE` | `/api/v1/google/connections/:id` | Disconnect (revoke tokens, delete connection) |
| `GET` | `/api/v1/google/connections` | List workspace's Google connections and status |

### BYOA Credentials

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/google/byoa_credentials` | Store user's OAuth app credentials |
| `GET` | `/api/v1/google/byoa_credentials` | List stored BYOA credentials |
| `DELETE` | `/api/v1/google/byoa_credentials/:id` | Remove BYOA credentials |

### Calendar

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/google/calendars` | List available Google calendars |
| `POST` | `/api/v1/google/calendars/:id/sync` | Enable sync for a calendar |
| `PATCH` | `/api/v1/google/calendars/:id/sync` | Update sync settings |
| `DELETE` | `/api/v1/google/calendars/:id/sync` | Disable sync for a calendar |
| `POST` | `/api/v1/google/calendar/webhook` | Push notification receiver (no auth — verified by channel ID) |

## Security

### Token Encryption

All tokens use `ActiveRecord::Encryption` in non-deterministic mode:

```ruby
class GoogleConnection < ApplicationRecord
  encrypts :access_token_enc
  encrypts :refresh_token_enc
end

class ByoaCredential < ApplicationRecord
  encrypts :client_secret_enc
end
```

### Scope Minimization

- Platform credentials request only `calendar.events` (sensitive, not restricted)
- BYOA credentials: DailyWerk's OAuth flow requests only scopes the user explicitly enables
- Incremental authorization: start minimal, add scopes as features activate

### BYOA Isolation

- BYOA credentials are workspace-scoped and encrypted
- One workspace's BYOA credentials can never be used for another workspace's OAuth flow
- The `state` parameter in the OAuth flow includes the workspace_id, preventing CSRF across workspaces
- BYOA credentials are validated (format check on client_id) before use

### Revocation Detection

Three detection paths:

1. **On API call failure** — 401/403 with `invalid_grant` → mark connection as `revoked`
2. **Proactive health check** — `GoogleConnectionHealthJob` every 6 hours
3. **Google RISC events** (future) — register for Cross-Account Protection push events (`token-revoked`, `sessions-revoked`)

### Webhook Security

Calendar push notification webhooks are verified by `X-Goog-Channel-ID` matching a known `calendar_sync_states.watch_channel_id`. The channel ID is a UUID generated by DailyWerk — it cannot be guessed. Additional validation: reject requests where the channel ID doesn't map to an active sync state.

### SSRF Protection

The callback endpoint validates the `state` parameter via HMAC — it cannot be used to redirect to arbitrary URLs. BYOA `redirect_uri` values are validated to match DailyWerk's known callback path.

## Ruby Gems

```ruby
# Gemfile additions
gem "google-apis-calendar_v3"    # Calendar API client
gem "google-apis-gmail_v1"       # Gmail API client (for BYOA)
gem "googleauth"                 # OAuth 2.0 library (PKCE, token refresh)
```

`googleauth` handles token refresh via `Google::Auth::UserRefreshCredentials`. DailyWerk wraps this with custom token persistence (database instead of file/Redis token store) and workspace-scoped credential resolution.

## Rollout

### Phase 1 — Google Calendar (Platform OAuth)

- OAuth infrastructure (flow, token storage, refresh)
- Calendar sync (full + incremental, push notifications)
- `calendar_events` table population
- Connection management UI

### Phase 2 — BYOA OAuth

- BYOA credential storage and management UI
- Step-by-step setup guide (with screenshots)
- BYOA connections using the same OAuth infrastructure
- Gmail read/send via BYOA (enables `email_read`, `email_send` agent tools)

### Phase 3 — Polish

- Google RISC event receiver for real-time revocation
- Calendar conflict UI (show logged conflicts to user)
- Multi-account support (multiple Google accounts per workspace)

## Alternatives Considered

### DailyWerk-Managed Gmail OAuth (CASA)

Deferred. Requires annual CASA assessment ($540–4,500/year) and 4–12 week verification. Documented in [PRD 06](../prd/06-gmail-direct-integration.md) for when user base justifies the investment.

### OmniAuth for OAuth Flow

Rejected. OmniAuth is designed for authentication (login), not for ongoing API access with token refresh. The `googleauth` gem is purpose-built for the API access pattern we need.

### Single Connection Per Workspace

Rejected. Platform Calendar + BYOA Gmail are different GCP projects with different credentials. Supporting multiple connections is inherent to the architecture.

## References

- [PRD 02: Integrations & Channels](../prd/02-integrations-and-channels.md)
- [PRD 01: Platform & Infrastructure §5.7](../prd/01-platform-and-infrastructure.md#57-task--calendar-tables)
- [PRD 04: Billing & Operations §8](../prd/04-billing-and-operations.md#8-goodjob-configuration)
- [RFC: Workspace Isolation](2026-03-30-workspace-isolation.md)
- [Google OAuth 2.0 for Web Server Apps](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Google Calendar API Sync Guide](https://developers.google.com/workspace/calendar/api/guides/sync)
- [Google Calendar Push Notifications](https://developers.google.com/workspace/calendar/api/guides/push)
- [Sensitive Scope Verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)
- [n8n Google OAuth Docs](https://docs.n8n.io/integrations/builtin/credentials/google/oauth-single-service/)
