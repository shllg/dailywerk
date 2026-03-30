---
type: rfc
title: IMAP/SMTP Integration
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/02-integrations-and-channels
depends_on:
  - rfc/2026-03-30-workspace-isolation
phase: 4
---

# RFC: IMAP/SMTP Integration

## Context

[PRD 02 §3](../prd/02-integrations-and-channels.md#3-email-integration) specifies IMAP/SMTP as the alternative email path for users not on Gmail (or users who prefer not to use Google OAuth). This covers Outlook, Fastmail, ProtonMail Bridge, self-hosted mail servers, and Gmail users who create app passwords.

This RFC provides the agent with active email capabilities: reading the inbox, searching mail, and sending as the user. It complements the [Inbound Email RFC](2026-03-31-inbound-email-processing.md) (passive forwarding) and the [Google Integration RFC](2026-03-31-google-integration.md) (BYOA OAuth for Gmail).

IMAP/SMTP requires no third-party verification, no OAuth app registration, and no annual security audits. The user supplies their mail server credentials, and DailyWerk connects directly.

## Decision

Implement a provider-agnostic email integration layer using standard IMAP for reading and SMTP for sending. User-provided credentials are stored encrypted. The integration exposes a uniform `EmailService` interface that agent tools consume, regardless of whether the underlying transport is IMAP/SMTP or (future) Gmail API.

## Goals

- provider-agnostic email read/send for any IMAP/SMTP-capable provider
- encrypted credential storage with workspace isolation
- connection pooling (avoid opening a new IMAP connection per operation)
- incremental inbox sync via IMAP capabilities (IDLE, polling, UIDs)
- uniform `EmailService` interface for agent tools
- clear user setup flow with connection testing

## Non-Goals

- Gmail API integration (see [Google Integration RFC](2026-03-31-google-integration.md))
- inbound email forwarding (see [Inbound Email RFC](2026-03-31-inbound-email-processing.md))
- full mail client feature parity (folders, rules, filters — agent tools are the interface)
- calendar extraction from emails (handled by agent intelligence)
- email template management

## Architecture

### Provider-Agnostic Email Service

```ruby
# app/services/email_service.rb
#
# Uniform interface for agent tools.
# Delegates to the appropriate provider backend.
class EmailService
  def initialize(workspace:)
    @workspace = workspace
    @provider = resolve_provider(workspace)
  end

  def list_messages(folder: "INBOX", limit: 20, since: nil)
  def get_message(uid:, folder: "INBOX")
  def search(query:, folder: "INBOX", limit: 10)
  def send_message(to:, subject:, body:, cc: nil, bcc: nil, reply_to_uid: nil)
  def move_message(uid:, from_folder:, to_folder:)
  def flag_message(uid:, flag:)  # :seen, :flagged, :deleted

  private

  def resolve_provider(workspace)
    # Check for IMAP/SMTP credentials → ImapSmtpProvider
    # Check for Google connection with gmail scopes → GmailApiProvider (future)
    # Raise if no email integration configured
  end
end
```

This interface is what agent tools (`email_read`, `email_send`, etc.) call. The provider backend is transparent to the agent.

### IMAP/SMTP Provider

```
┌─────────────────────────────────────────────────────────┐
│                    EmailService                          │
│                        │                                │
│              ImapSmtpProvider                            │
│                 │           │                            │
│    ┌────────────┴──┐   ┌───┴────────────┐               │
│    │  IMAP Client  │   │  SMTP Client   │               │
│    │  (net-imap)   │   │  (net-smtp)    │               │
│    │               │   │                │               │
│    │  • list       │   │  • send        │               │
│    │  • fetch      │   │  • reply       │               │
│    │  • search     │   │                │               │
│    │  • move/flag  │   │                │               │
│    └───────────────┘   └────────────────┘               │
│                                                         │
│    Credentials: email_integrations table (encrypted)    │
└─────────────────────────────────────────────────────────┘
```

### Connection Management

IMAP connections are expensive to establish (TLS handshake, authentication, mailbox selection). DailyWerk maintains short-lived connections within job execution rather than persistent connection pools (Falcon's fiber model makes persistent IMAP connections risky).

Pattern:
1. Job starts → open IMAP connection using decrypted credentials
2. Perform all operations within the job
3. Job ends → close connection in `ensure` block
4. Never hold IMAP connections across fiber yields or outside job scope

For SMTP: connections are opened per-send and closed immediately. SMTP connections are lightweight enough that pooling adds complexity without meaningful benefit at DailyWerk's scale.

## Credential Storage

### User Setup Flow

1. User navigates to workspace settings → Email Integration
2. User enters: IMAP host, port, username, password, security (TLS/STARTTLS)
3. User enters: SMTP host, port, username, password, security (TLS/STARTTLS)
4. DailyWerk tests the connection (IMAP login + SMTP EHLO)
5. On success: credentials stored encrypted, integration marked active
6. On failure: error displayed, credentials not stored

### Provider Presets

To simplify setup, offer presets for common providers:

| Provider | IMAP Host | Port | SMTP Host | Port | Notes |
|----------|-----------|------|-----------|------|-------|
| Gmail | imap.gmail.com | 993 | smtp.gmail.com | 587 | Requires app password (2FA) |
| Outlook | outlook.office365.com | 993 | smtp.office365.com | 587 | App password or OAuth |
| Fastmail | imap.fastmail.com | 993 | smtp.fastmail.com | 587 | App password |
| ProtonMail | 127.0.0.1 | 1143 | 127.0.0.1 | 1025 | Via ProtonMail Bridge only |
| Yahoo | imap.mail.yahoo.com | 993 | smtp.mail.yahoo.com | 587 | App password |
| Custom | user-defined | user-defined | user-defined | user-defined | Any IMAP/SMTP server |

Presets auto-fill host/port fields. User still provides username and password.

## Schema

### `email_integrations` — IMAP/SMTP Credentials

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `label` | string | User-defined label (e.g., "Work Gmail") |
| `email_address` | string | The email address (for display + SMTP From) |
| `provider_preset` | string | `gmail`, `outlook`, `fastmail`, `protonmail`, `yahoo`, `custom` |
| `imap_host` | string | IMAP server hostname |
| `imap_port` | integer | IMAP server port (default: 993) |
| `imap_security` | string | `tls`, `starttls`, `none` |
| `smtp_host` | string | SMTP server hostname |
| `smtp_port` | integer | SMTP server port (default: 587) |
| `smtp_security` | string | `tls`, `starttls`, `none` |
| `username` | string | Login username (often same as email) |
| `password_enc` | text | Encrypted password / app password |
| `status` | string | `active`, `auth_failed`, `connection_failed`, `disabled` |
| `last_connected_at` | datetime | Last successful IMAP connection |
| `last_error` | text | Last error message |
| `sync_state` | jsonb | `{ last_uid: 12345, last_synced_at: "..." }` |
| `metadata` | jsonb | Extensible |
| `created_at` | datetime | |
| `updated_at` | datetime | |

**Indexes**: `[workspace_id]`, `[workspace_id, email_address]` unique.

## IMAP Operations

### Reading Messages

```ruby
# List recent messages from a folder
def list_messages(folder: "INBOX", limit: 20, since: nil)
  imap_connect do |imap|
    imap.select(folder)
    search_criteria = since ? ["SINCE", since.strftime("%d-%b-%Y")] : ["ALL"]
    uids = imap.uid_search(search_criteria).last(limit)
    fetch_summaries(imap, uids)
  end
end

# Fetch full message content
def get_message(uid:, folder: "INBOX")
  imap_connect do |imap|
    imap.select(folder)
    data = imap.uid_fetch(uid, ["ENVELOPE", "BODY[]", "FLAGS"]).first
    parse_message(data)
  end
end
```

### Searching

IMAP search supports server-side filtering:

```ruby
def search(query:, folder: "INBOX", limit: 10)
  imap_connect do |imap|
    imap.select(folder)
    # IMAP SEARCH supports: FROM, TO, SUBJECT, BODY, TEXT, SINCE, BEFORE, etc.
    uids = imap.uid_search(["TEXT", query]).last(limit)
    fetch_summaries(imap, uids)
  end
end
```

### Sending

```ruby
def send_message(to:, subject:, body:, cc: nil, bcc: nil, reply_to_uid: nil)
  mail = Mail.new do
    from    @integration.email_address
    to      to
    cc      cc if cc
    bcc     bcc if bcc
    subject subject
    body    body
  end

  if reply_to_uid
    original = get_message(uid: reply_to_uid)
    mail.in_reply_to = original.message_id
    mail.references  = original.message_id
  end

  smtp_deliver(mail)
end
```

### Inbox Monitoring

For near-real-time inbox monitoring (when agents need to react to new emails):

**Option A — IMAP IDLE (push-ish):**
IMAP IDLE keeps a connection open and receives push notifications for new messages. However, this requires a persistent connection per user, which conflicts with Falcon's fiber model and doesn't scale. **Rejected for v1.**

**Option B — Periodic polling (chosen):**
`EmailPollJob` runs every 2 minutes (GoodJob cron). For each active `email_integrations` row:
1. Open IMAP connection
2. `uid_search(["UID", "#{last_uid + 1}:*"])` to find new messages
3. Fetch new message summaries
4. Update `sync_state.last_uid`
5. Notify agent if workspace has auto-processing enabled

This is the same pattern as `TodoSyncWorker` in PRD 04 §8.

### GoodJob Cron

```ruby
email_poll: {
  cron: "*/5 * * * *",               # Every 5 minutes
  class: "EmailPollJob",
  description: "Poll IMAP mailboxes for new messages"
},
email_connection_health: {
  cron: "0 */6 * * *",               # Every 6 hours
  class: "EmailConnectionHealthJob",
  description: "Test IMAP/SMTP connections, detect auth failures"
}
```

## MIME Parsing

Email content parsing uses the `mail` gem (already a Rails dependency):

```ruby
def parse_message(raw_data)
  mail = Mail.read_from_string(raw_data)
  {
    uid: raw_data.attr["UID"],
    message_id: mail.message_id,
    from: mail.from&.first,
    to: mail.to,
    cc: mail.cc,
    subject: mail.subject,
    date: mail.date,
    text_body: mail.text_part&.decoded || mail.body.decoded,
    html_body: mail.html_part&.decoded,
    attachments: mail.attachments.map { |a|
      { filename: a.filename, content_type: a.content_type, size: a.body.decoded.size }
    },
    flags: raw_data.attr["FLAGS"]
  }
end
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/email_integrations` | Create integration (stores credentials after test) |
| `GET` | `/api/v1/email_integrations` | List workspace email integrations |
| `PATCH` | `/api/v1/email_integrations/:id` | Update credentials or settings |
| `DELETE` | `/api/v1/email_integrations/:id` | Remove integration (deletes credentials) |
| `POST` | `/api/v1/email_integrations/:id/test` | Test IMAP + SMTP connection |

## Security

### Credential Encryption

```ruby
class EmailIntegration < ApplicationRecord
  include WorkspaceScoped
  encrypts :password_enc
end
```

Non-deterministic `ActiveRecord::Encryption`. Credentials are decrypted only during active IMAP/SMTP connections and never logged or exposed via API responses.

### Connection Security

- **TLS required by default** — `imap_security` defaults to `tls`. `none` is allowed for local servers only (ProtonMail Bridge on localhost).
- **Certificate verification** — verify server certificates by default. Allow opt-out for self-signed certs (stored in `metadata.skip_tls_verify`, with UI warning).
- **No plaintext auth** — if server doesn't support encrypted auth mechanisms, connection is refused.

### SSRF Prevention

IMAP/SMTP hosts are validated:
- No connections to private IP ranges (10.x, 172.16-31.x, 192.168.x, 127.x) except `127.0.0.1` for ProtonMail Bridge
- No connections to DailyWerk's own infrastructure IPs
- Port numbers restricted to known email ports (993, 143, 587, 465, 25) plus ProtonMail Bridge ports

### Credential Isolation

- Each `email_integrations` row is workspace-scoped via `WorkspaceScoped` concern + RLS
- Credentials from one workspace can never be used in another workspace's context
- API responses never include the password — only connection status

## Rollout

### Phase 1 — Core IMAP/SMTP

- `email_integrations` table and encrypted credential storage
- Connection testing (IMAP login + SMTP EHLO)
- Provider presets (Gmail, Outlook, Fastmail)
- Basic read operations (list, fetch, search)
- Send operations (compose, reply)
- Settings UI

### Phase 2 — Inbox Monitoring

- `EmailPollJob` for periodic new-message detection
- `sync_state` tracking
- Agent notification on new messages

### Phase 3 — Advanced Operations

- Folder management (list, move between folders)
- Flag operations (read/unread, star, archive)
- Attachment download and S3 storage
- Connection health monitoring job

## Alternatives Considered

### Gmail API for All Gmail Users

Rejected for v1. Gmail API requires CASA verification for restricted scopes. Users who want Gmail API access can use the BYOA approach from the [Google Integration RFC](2026-03-31-google-integration.md). IMAP/SMTP with Gmail app passwords provides the same functionality without verification.

### IMAP IDLE for Push Notifications

Rejected. Requires persistent TCP connections per user. Doesn't fit Falcon's fiber-per-request model. Scales poorly (1,000 users = 1,000 persistent connections). Polling every 5 minutes is sufficient for an AI assistant use case.

### EmailEngine as Middleware

Considered. EmailEngine abstracts IMAP/SMTP behind a REST API with connection pooling and webhook delivery. Good product, but adds an operational dependency (another service to run). Direct IMAP/SMTP from Ruby is simpler for v1. Could reconsider at scale.

## References

- [PRD 02: Email Integration §3](../prd/02-integrations-and-channels.md#3-email-integration)
- [RFC: Workspace Isolation](2026-03-30-workspace-isolation.md)
- [Ruby net-imap Documentation](https://ruby-doc.org/3.4.1/gems/net-imap/)
- [Ruby net-smtp Documentation](https://ruby-doc.org/3.4.1/gems/net-smtp/)
- [Mail Gem](https://github.com/mikel/mail)
