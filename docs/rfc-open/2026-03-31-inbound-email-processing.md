---
type: rfc
title: Inbound Email Processing
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/02-integrations-and-channels
depends_on:
  - rfc/2026-03-30-workspace-isolation
  - rfc/2026-03-29-simple-chat-conversation
phase: 2
---

# RFC: Inbound Email Processing

## Context

DailyWerk's agents need to receive information from users beyond real-time chat. Users regularly encounter content in their email — newsletters, receipts, booking confirmations, meeting notes, documents — that they want their AI assistant to process, store, or act on.

Direct Gmail API integration requires CASA verification (see [PRD 06](../prd/06-gmail-direct-integration.md)). IMAP/SMTP integration requires per-user credential setup (see [RFC: IMAP/SMTP](2026-03-31-imap-smtp-integration.md)). Both have friction.

Inbound email forwarding has zero friction: the user forwards an email to a DailyWerk address, and the agent processes it. No OAuth, no credentials, no setup beyond knowing the address. Every email provider supports forwarding. This makes it the ideal first email integration path.

## Decision

Provide each workspace with a unique inbound email address. Users forward emails to this address. DailyWerk receives, validates (sender allowlist), parses, and routes the email to the appropriate agent for processing.

Use a transactional email service (Postmark or Mailgun) for inbound email receiving rather than self-hosting an MX receiver. This avoids operating SMTP infrastructure, handling spam filtering, managing IP reputation, and dealing with DNS propagation for MX records.

## Goals

- zero-setup email ingestion for users (just forward to an address)
- sender allowlist to prevent abuse
- structured extraction of email content (text, HTML, attachments)
- route inbound emails to the correct agent for processing
- workspace-scoped isolation
- support for both forwarded emails and direct sends

## Non-Goals

- reading the user's inbox (that's Gmail API / IMAP territory)
- sending email as the user
- two-way email conversations via the inbound address
- spam filtering beyond sender allowlist (the email service handles spam)
- processing encrypted/PGP emails

## Architecture

### Email Flow

```
User forwards email
        │
        ▼
┌──────────────────────┐
│  Postmark / Mailgun  │  ← MX for in.dailywerk.com
│  Inbound Webhook     │
└──────────┬───────────┘
           │ POST /api/v1/inbound_emails/webhook
           ▼
┌──────────────────────┐
│  InboundEmailsCtrl   │  ← Verify webhook signature
│  (Rails controller)  │  ← Persist raw email
└──────────┬───────────┘
           │ enqueue
           ▼
┌──────────────────────┐
│  ProcessInboundEmail │  ← Sender allowlist check
│  Job                 │  ← Parse MIME (text, HTML, attachments)
│  (GoodJob)           │  ← Route to agent
│                      │  ← Create message in session
└──────────────────────┘
```

### Inbound Email Addresses

Each workspace gets a unique inbound address:

```
{workspace_token}@in.dailywerk.com
```

Where `workspace_token` is a short, URL-safe, random token (e.g., `dk_7xm3q9`) generated at workspace creation. The token is:

- unique across all workspaces
- not derived from workspace_id (prevents enumeration)
- regeneratable by the user (invalidates the old address)
- stored on the `workspaces` table

**Why not per-agent addresses?** Simplicity. A single workspace address keeps the UX minimal — users remember one address. Agent routing is handled server-side based on content or explicit rules (see Routing section). Per-agent addresses can be added later as an additive feature if demand exists.

### Webhook Receiving

The inbound email service (Postmark recommended) receives mail at `in.dailywerk.com` and posts parsed content to DailyWerk via webhook:

```
POST /api/v1/inbound_emails/webhook
Content-Type: application/json

{
  "From": "user@example.com",
  "FromName": "Sascha",
  "To": "dk_7xm3q9@in.dailywerk.com",
  "Subject": "Fwd: Flight Confirmation",
  "TextBody": "...",
  "HtmlBody": "...",
  "Date": "2026-03-31T10:00:00Z",
  "MessageID": "<abc123@mail.example.com>",
  "Headers": [...],
  "Attachments": [
    {
      "Name": "boarding-pass.pdf",
      "Content": "<base64>",
      "ContentType": "application/pdf",
      "ContentLength": 42331
    }
  ]
}
```

### Webhook Security

- **Signature verification**: Postmark signs webhooks with a shared secret. Verify before processing.
- **Idempotency**: `MessageID` is the dedup key. Reject duplicates silently (200 OK).
- **Rate limiting**: per-workspace rate limit (e.g., 100 emails/hour) to prevent abuse if a workspace token leaks.

## Sender Allowlist

Inbound emails are only processed if the sender is on the workspace's allowlist. This prevents:

- strangers from sending content to the agent
- spam/phishing from polluting agent context
- abuse via leaked workspace email addresses

### Allowlist Rules

| Rule Type | Example | Description |
|-----------|---------|-------------|
| `exact` | `sascha@example.com` | Exact email match |
| `domain` | `@company.com` | Any address at this domain |

### Behavior

- **Allowlisted sender** → email is processed normally
- **Unknown sender** → email is stored (for audit) but NOT processed. Workspace owner is notified.
- **No allowlist entries** → all senders are blocked (fail-closed). User must add at least one entry.

The first email address added to a workspace's allowlist should be the workspace owner's email — suggested during onboarding.

### Auto-Discovery

When a user forwards an email, the `From` header contains the forwarder's address (the user), not the original sender. Most email clients set the forwarding user as the `From` when using manual forward. This means the allowlist primarily validates the **user**, not the original email author.

For automated forwarding rules (Gmail filters, etc.), the `From` may be the original sender. Users configuring auto-forward should add both their own address and expected sender domains to the allowlist.

## Email Parsing

### Content Extraction

```ruby
# Priority order for body content:
# 1. TextBody (clean, preferred for agent context)
# 2. HtmlBody → strip tags, extract text (fallback)
# 3. Subject only (if no body)
```

### Forwarded Email Detection

When users forward emails, the body typically contains quoted content with headers like:

```
---------- Forwarded message ---------
From: airline@example.com
Date: Mon, Mar 31, 2026
Subject: Your Flight Confirmation
```

The parser should:

1. Detect forwarded message markers (provider-specific patterns)
2. Extract the original sender, date, subject from forwarded headers
3. Separate the user's added note (above the forward marker) from the forwarded content
4. Store both: user's note as context, forwarded content as the primary payload

### Attachments

Attachments are stored in S3 (workspace-scoped path):

```
workspaces/{workspace_id}/inbound_emails/{inbound_email_id}/{filename}
```

Size limits:
- Per attachment: 25 MB (matching most email provider limits)
- Per email total: 50 MB
- Emails exceeding limits: stored without attachments, user notified

Supported attachment processing:
- **PDF**: extract text (for agent context)
- **Images**: store reference, pass to multimodal agent if capable
- **Documents** (.docx, .txt, .csv): extract text
- **Other**: store reference only, no text extraction

## Agent Routing

### Default Behavior

Inbound emails route to the workspace's **default agent** (the agent with `is_default: true`). The email content becomes a message in the agent's active session, as if the user had typed it in chat.

### Future: Rule-Based Routing

Deferred until multi-agent workflows ship. Possible extension:

- Route by subject keyword (`[finance]` → finance agent)
- Route by original sender domain (newsletters → research agent)
- Route by attachment type (receipts → expense agent)
- Per-agent inbound addresses (`{agent_slug}_{workspace_token}@in.dailywerk.com`)

## Processing Pipeline

When an allowlisted email arrives:

1. **Persist raw email** → `inbound_emails` table (always, before any processing)
2. **Parse content** → extract text, detect forwards, handle attachments
3. **Store attachments** → upload to S3
4. **Resolve agent** → default agent for the workspace
5. **Resolve session** → find or create session for inbound email channel
6. **Create message** → insert into `messages` table with role `user`, source `email`
7. **Enqueue agent execution** → `ChatStreamJob` with the new message

The agent sees the email content as a user message and responds normally. The response stays in the web UI session — it is not emailed back to the user (no outbound email in this RFC).

### Session Strategy

Inbound emails create messages in a dedicated **inbound email session** per workspace (separate from the web chat session). This keeps forwarded content organized and prevents it from mixing with real-time chat context.

The session uses `session_type: "inbound_email"` and is long-lived (one per workspace per default agent). The agent can reference prior forwarded emails in the same session context.

## Schema

### `inbound_emails` — Raw Email Storage

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `message_id_header` | string | Email `Message-ID` header (dedup key) |
| `from_address` | string | Sender email address |
| `from_name` | string | Sender display name |
| `to_address` | string | Recipient (workspace inbound address) |
| `subject` | string | Email subject |
| `text_body` | text | Plain text body |
| `html_body` | text | HTML body (stored for reference) |
| `parsed_body` | text | Cleaned/extracted text for agent consumption |
| `forwarded_from` | string | Original sender if forwarded email detected |
| `forwarded_subject` | string | Original subject if forwarded |
| `headers` | jsonb | Raw email headers |
| `attachment_count` | integer | Number of attachments |
| `status` | string | `received`, `processing`, `processed`, `rejected`, `failed` |
| `rejection_reason` | string | Why rejected (e.g., `sender_not_allowed`, `rate_limited`) |
| `processed_at` | datetime | When processing completed |
| `agent_id` | uuid FK | Agent that processed this email |
| `session_id` | uuid FK | Session the email was posted to |
| `message_id` | uuid FK | Message record created from this email |
| `raw_payload` | jsonb | Full webhook payload (for debugging) |
| `created_at` | datetime | |

**Indexes**: `[workspace_id, created_at]`, `[message_id_header]` unique, `[workspace_id, status]`.

### `inbound_email_allowlists` — Sender Allowlist

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace (required) |
| `rule_type` | string | `exact` or `domain` |
| `value` | string | Email address or domain (e.g., `@company.com`) |
| `label` | string | User-defined label |
| `created_at` | datetime | |

**Indexes**: `[workspace_id, rule_type, value]` unique.

### `workspaces` Table Addition

Add `inbound_email_token` column:

| Column | Type | Description |
|--------|------|-------------|
| `inbound_email_token` | string | Unique token for inbound address (e.g., `dk_7xm3q9`) |

**Index**: `[inbound_email_token]` unique.

Generated at workspace creation. Regeneratable via API (invalidates old address).

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/inbound_emails/webhook` | Webhook receiver (email service → DailyWerk) |
| `GET` | `/api/v1/inbound_emails` | List received emails for workspace |
| `GET` | `/api/v1/inbound_emails/:id` | Get specific email details |
| `GET` | `/api/v1/inbound_email_settings` | Get inbound address + allowlist |
| `POST` | `/api/v1/inbound_email_settings/regenerate_token` | Generate new inbound address |
| `POST` | `/api/v1/inbound_email_allowlist` | Add allowlist entry |
| `DELETE` | `/api/v1/inbound_email_allowlist/:id` | Remove allowlist entry |
| `GET` | `/api/v1/inbound_email_allowlist` | List allowlist entries |

## Email Service Selection

### Postmark (Recommended)

- Inbound email processing with webhook delivery
- Reliable, well-documented API
- Free tier includes inbound processing
- Automatic spam filtering before webhook delivery
- Parses MIME, extracts attachments, delivers structured JSON
- Webhook signature verification

### Mailgun (Alternative)

- Similar inbound routing capabilities
- Route-based webhook configuration
- Slightly more complex setup but more flexible routing rules

### Action Mailbox (Rejected for Primary Path)

Rails' built-in Action Mailbox can receive email via Postmark/Mailgun adapters. However:

- It's designed for full email processing within Rails (stores blobs, has its own lifecycle)
- Adds unnecessary complexity for our use case (we just need the parsed content)
- We'd still need Postmark/Mailgun for actual MX receiving
- Direct webhook processing is simpler and gives us full control over the parsing and routing

Action Mailbox could be reconsidered if email processing requirements grow significantly.

## DNS Configuration

```
; MX record for inbound email subdomain
in.dailywerk.com.  MX  10  inbound.postmarkapp.com.

; SPF for the subdomain (Postmark handles receiving, no sending)
in.dailywerk.com.  TXT "v=spf1 include:spf.mtasv.net ~all"
```

## Security

### Webhook Authentication

Verify Postmark webhook signature on every request:

```ruby
# Postmark includes a signature header
# Verify HMAC-SHA256 of the raw body against the webhook secret
```

Reject unsigned or incorrectly signed requests with 403.

### Sender Validation

- Allowlist is fail-closed — no entries means no processing
- Domain rules use exact suffix matching (no regex to prevent ReDoS)
- Email addresses are normalized (lowercase, trim whitespace)

### Content Safety

- Attachments are stored in S3 with workspace-scoped paths (SSE-C encryption)
- HTML bodies are sanitized before any rendering
- No executable attachments are processed (.exe, .bat, .sh, etc.)
- Email content passed to agents is treated as untrusted user input

### Rate Limiting

- Per-workspace: 100 emails/hour (configurable)
- Per-sender: 20 emails/hour to a single workspace
- Exceeding limits: email stored with `status: "rejected"`, `rejection_reason: "rate_limited"`

### Token Security

- `inbound_email_token` is cryptographically random (SecureRandom.alphanumeric, 12 chars with prefix)
- Not derived from workspace_id
- Regeneration invalidates old address immediately
- Leaked tokens can be rotated without affecting other integrations

## Rollout

### Phase 1 — Core Inbound Processing

- Postmark inbound webhook setup
- `inbound_emails` table + `inbound_email_allowlists` table
- Workspace inbound token generation
- Sender allowlist validation
- Basic text extraction and agent routing
- Inbound email settings UI

### Phase 2 — Rich Processing

- Forwarded email detection and parsing
- Attachment storage and text extraction (PDF, docx)
- Inbound email history UI (list of received emails and their status)

### Phase 3 — Advanced Routing

- Per-agent inbound addresses
- Rule-based routing (subject, sender, attachment type)
- Auto-forwarding setup guide (Gmail filters, Outlook rules)

## Alternatives Considered

### Self-Hosted SMTP Server

Rejected. Operating an MX server requires managing DNS, spam filtering, IP reputation, TLS certificates, DKIM/SPF/DMARC, and high-availability. Postmark/Mailgun handle all of this for pennies per email.

### Per-Agent Email Addresses

Deferred to Phase 3. Single workspace address is simpler to communicate and remember. Most users will only have one agent initially.

### Two-Way Email (Reply via Inbound Address)

Deferred. Sending email from the inbound address requires outbound SMTP configuration, SPF/DKIM setup, and reply tracking. The inbound address is receive-only. Outbound email is handled by IMAP/SMTP integration or Gmail API.

## References

- [PRD 02: Email Integration](../prd/02-integrations-and-channels.md#3-email-integration)
- [RFC: Workspace Isolation](2026-03-30-workspace-isolation.md)
- [Postmark Inbound Email Processing](https://postmarkapp.com/developer/webhooks/inbound-webhook)
- [Mailgun Inbound Routing](https://documentation.mailgun.com/docs/mailgun/user-manual/receiving-forwarding-and-storing-messages/)
- [Rails Action Mailbox Guide](https://guides.rubyonrails.org/action_mailbox_basics.html)
