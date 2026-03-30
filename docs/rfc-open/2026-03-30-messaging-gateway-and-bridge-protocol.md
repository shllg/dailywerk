---
type: rfc
title: Messaging Gateway & Bridge Protocol
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/02-integrations-and-channels
  - prd/01-platform-and-infrastructure
depends_on:
  - rfc/2026-03-30-workspace-isolation
  - rfc/2026-03-29-simple-chat-conversation
phase: 2
---

# RFC: Messaging Gateway & Bridge Protocol

## Context

[PRD 02](../prd/02-integrations-and-channels.md#1-messaging-gateway--bridge-protocol) defines the idea of a universal bridge protocol, but the current sketch is still too loose to implement safely:

- it assumes phone numbers are always the canonical sender identifier
- it does not define idempotency or retry semantics
- it mixes generic bridge behavior with Signal-specific provisioning ideas
- it does not say which side owns session resolution, attachment transfer, or delivery state
- it does not give managed bridges stronger guarantees than self-hosted bridges

That gap is the real implementation risk. Without a stricter contract, every bridge will make different choices around sender identity, retries, and message state, which pushes transport-specific complexity back into Rails.

## Decision

Adopt **Bridge Protocol v1** as a narrow, transport-agnostic **data plane** between DailyWerk Core and any external bridge runtime.

Bridge Protocol v1 makes the following choices:

1. The bridge contract is **message transport only**. Provisioning and onboarding remain channel-specific control-plane concerns.
2. DailyWerk Core owns users, workspaces, agents, sessions, billing, retries, and auditing.
3. Bridge runtimes own provider auth, provider webhook/polling mechanics, transport normalization, and temporary media serving.
4. All inbound events are pushed to Core via HTTPS JSON and are **idempotent by `event_id`**.
5. All outbound sends are pushed from Core to the bridge via HTTPS JSON and are **idempotent by `request_id`**.
6. Sender and thread identities are **structured objects**, not bare phone numbers.
7. Managed bridges require stronger authentication than self-hosted bridges.

## Goals

- keep external-channel logic out of Rails controllers and jobs
- let Signal, Telegram, and future channels share one Core-side processing path
- support both self-hosted and managed bridge deployments
- make bridge retries safe
- support the "one continuous conversation per gateway" session model from the chat RFC

## Non-Goals

- a universal provisioning API for every channel
- multi-provider bridge instances in v1 (one bridge process, multiple provider accounts)
- provider-specific feature parity across all channels
- a streaming token protocol from Core to messengers

## Architecture Boundary

### Core Owns

- bridge records and lifecycle state in `bridges`
- inbound event persistence in `bridge_events`
- workspace/user authorization
- session resolution
- agent execution
- usage tracking (`request_type = "bridge"`)
- retry policy for outbound bridge calls

### Bridge Runtime Owns

- provider credentials and transport sessions
- provider-specific receive loops
- transforming provider payloads into Bridge Protocol events
- transforming Core outbound commands into provider sends
- temporary attachment hosting for inbound media
- health reporting

### Why The Protocol Is Data-Plane Only

Provisioning is the part that varies most by channel:

- Telegram uses Bot API webhooks and a bot token
- WhatsApp depends on Meta business approval and templates
- Signal can be linked as a secondary device or registered directly

Trying to force those flows into one universal API would either make the protocol too vague to be useful or too Signal-shaped to be generic. The universal contract should therefore begin **after** a bridge has credentials and can send/receive messages.

## Bridge Model

Each `bridges` row represents one workspace-owned bridge deployment associated with one external account.

`bridge_id` is the deployment and provenance identifier, not the logical conversation identity.

### V1 Assumptions

- one bridge process maps to one external account
- one bridge has one channel (`signal`, `telegram`, `whatsapp`)
- one bridge has one `host_url`
- one bridge can serve multiple threads/conversations for that one account

Multi-provider bridge instances (one bridge process serving multiple provider accounts of the same channel type) are deferred. They complicate key management, health reporting, and per-account billing without helping the MVP. A workspace that needs both a Signal bridge and a Telegram bridge runs two separate bridge processes, each with its own `bridges` row.

Bridges are not shareable across workspaces. Each bridge belongs to exactly one workspace.

The current platform PRD still shows `bridges.user_id`. Before external channels ship, that table should be aligned with the workspace isolation direction so bridge ownership is scoped by workspace, not by direct user ownership alone.

## Bridge Connectivity

The outbound contract requires Core to reach the bridge at `{bridge.host_url}`. How the bridge becomes reachable depends on the deployment model.

### Managed Bridges

Core and the bridge run on the same infrastructure or within a private network. Connectivity is direct. No user-side networking setup required.

### Self-Hosted — Public URL

The operator exposes the bridge process behind a reverse proxy with a public domain and valid TLS certificate. Core calls the bridge over the public internet.

Requirements:

- HTTPS with a valid certificate (self-signed is not accepted)
- stable hostname or IP (dynamic DNS is acceptable)
- firewall/NAT configured to forward traffic to the bridge port

This is the simplest self-hosted path for users who already run services with public endpoints.

### Self-Hosted — Tunnel Service

The operator uses a tunnel service to expose the bridge without opening ports or managing DNS. Supported approaches include:

- Cloudflare Tunnel (free tier available, `cloudflared` daemon)
- Tailscale Funnel (zero-config if already on Tailscale)
- ngrok or similar relay services

The bridge registers a tunnel, and the resulting public URL becomes the `host_url` stored in the `bridges` row.

Requirements:

- HTTPS (provided by the tunnel service)
- the tunnel URL must remain stable or be updated in Core when it changes
- Core's SSRF validation must accept the tunnel provider's domain patterns

### Connectivity Validation

Core validates bridge connectivity during provisioning and ongoing health checks:

- `host_url` must pass SSRF validation (no internal IPs, no localhost)
- initial provisioning must succeed with a `/health` call before the bridge is marked active
- if health checks fail repeatedly, Core marks the bridge as `unhealthy` and stops outbound sends

The bridge provisioning UI should guide users through their chosen connectivity method and verify reachability before completing setup.

## Protocol Versioning

Every protocol request or response that carries a JSON body must include
`protocol_version: "2026-03-30"`.

Rules:

- additive fields are allowed within a version
- breaking changes require a new version string
- the bridge advertises supported versions in `/health`
- Core refuses to provision or use a bridge that does not support the configured version

## Canonical Entities

### Account

```json
{
  "provider_account_id": "signal:+4915112345678",
  "display_name": "DailyWerk Signal Bridge"
}
```

Rules:

- `provider_account_id` is required
- it is the stable external account key used for routing and migration continuity
- it may be opaque and must not be assumed to be a phone number
- bridge replacement must preserve the same logical `provider_account_id`

### Participant

Bridge Protocol must not assume a phone number exists. Signal's upstream client already supports Service IDs, ACI/PNI identifiers, and usernames in addition to phone numbers.

```json
{
  "provider_id": "d6e0c5c6-5f7b-4a5f-8e9d-1c2b3a4d5e6f",
  "phone_number": "+4915112345678",
  "username": "u:sascha.123",
  "display_name": "Sascha"
}
```

Rules:

- `provider_id` is required
- `phone_number` is optional
- `username` is optional
- bridges should include every stable identifier they know
- provider-specific per-device details stay in `raw`, not in the canonical participant shape

### Conversation

```json
{
  "provider_thread_id": "dm:aci:9ce9d3fa-44b8-4aa1-a4d3-ef2d093d9999",
  "thread_type": "dm",
  "title": "Signal DM",
  "participants": []
}
```

Rules:

- `provider_thread_id` is required
- `thread_type` is one of `dm`, `group`, `broadcast`, `unknown`
- `provider_thread_id` may be a bridge-generated stable key when the upstream transport has no native DM thread identifier
- `participants` is optional metadata, not the session key

### Attachment

```json
{
  "attachment_id": "att_01JQXYZ",
  "mime_type": "image/jpeg",
  "filename": "photo.jpg",
  "byte_size": 412331,
  "sha256": "base64-or-hex",
  "download_url": "https://bridge.example.com/v1/media/att_01JQXYZ"
}
```

Rules:

- `download_url` must remain valid for at least 15 minutes
- bridge auth applies to attachment fetches unless the URL is separately signed
- attachments larger than the channel limit must be rejected before Core retries

## Inbound Contract

### Endpoint

`POST /api/v1/bridges/:bridge_id/inbound`

### Headers

- `Authorization: Bearer <bridge_api_key>`
- `Content-Type: application/json`
- `X-Bridge-Timestamp: 2026-03-30T12:00:00Z`
- `X-Bridge-Nonce: <uuid>`
- `X-Bridge-Signature: <detached-signature>` for managed bridges only

### Body

```json
{
  "protocol_version": "2026-03-30",
  "event_id": "evt_01JQXYZ",
  "event_type": "message.received",
  "occurred_at": "2026-03-30T12:00:00Z",
  "bridge_message_id": "sig_1743336000000_2",
  "account": {
    "provider_account_id": "+4915112345678"
  },
  "conversation": {
    "provider_thread_id": "dm:aci:9ce9d3fa-44b8-4aa1-a4d3-ef2d093d9999",
    "thread_type": "dm"
  },
  "sender": {
    "provider_id": "aci:9ce9d3fa-44b8-4aa1-a4d3-ef2d093d9999",
    "phone_number": "+4915112345678",
    "display_name": "Sascha"
  },
  "message": {
    "provider_message_id": "1743336000000",
    "sent_at": "2026-03-30T12:00:00Z",
    "text": "hello",
    "attachments": [],
    "quoted_message_id": null
  },
  "raw": {}
}
```

### Required Event Types

V1 requires support for:

- `message.received`

V1 optional events:

- `message.updated`
- `message.deleted`
- `receipt.delivered`
- `receipt.read`
- `typing.started`
- `typing.stopped`
- `presence.changed`

The bridge advertises optional support through `/health.capabilities`.

### Inbound Semantics

- Core must persist the raw payload and normalized envelope before side effects
- `event_id` must identify the logical upstream event, not merely one bridge delivery attempt
- duplicate `event_id` values are treated as successful no-ops
- `raw` is mandatory and stored for debugging even when a normalized field is missing
- inbound handlers must be fast and enqueue downstream work instead of running the agent inline
- bridge replacement, failover, or self-hosted-to-managed migration must not change `event_id` for the same upstream message event

### Response Codes

- `202 Accepted`: event persisted or accepted as duplicate
- `401 Unauthorized`: bearer token invalid
- `403 Forbidden`: signature invalid or bridge disabled
- `409 Conflict`: timestamp/nonce replay detected
- `422 Unprocessable Entity`: schema invalid
- `429 Too Many Requests`: back off and retry
- `5xx`: transient failure, safe to retry

Bridge retry rule:

- retry only on `408`, `429`, or `5xx`
- do not retry `401`, `403`, `409`, or `422`

## Outbound Contract

### Endpoint

`POST {bridge.host_url}/v1/messages`

### Request

```json
{
  "protocol_version": "2026-03-30",
  "request_id": "obr_01JQXYZ",
  "conversation": {
    "provider_thread_id": "dm:aci:9ce9d3fa-44b8-4aa1-a4d3-ef2d093d9999",
    "thread_type": "dm"
  },
  "recipient": {
    "provider_id": "aci:9ce9d3fa-44b8-4aa1-a4d3-ef2d093d9999",
    "phone_number": "+4915112345678"
  },
  "content": {
    "type": "text",
    "text": "hello back",
    "attachments": [
      {
        "mime_type": "image/jpeg",
        "filename": "photo.jpg",
        "download_url": "https://api.dailywerk.com/bridge-media/att_01JQXYZ"
      }
    ]
  },
  "reply_to": {
    "provider_message_id": "1743336000000"
  }
}
```

### Response

```json
{
  "protocol_version": "2026-03-30",
  "request_id": "obr_01JQXYZ",
  "status": "accepted",
  "bridge_message_id": "sig_out_01JQXYZ",
  "provider_message_id": "1743336012345",
  "accepted_at": "2026-03-30T12:00:12Z"
}
```

### Outbound Semantics

- `request_id` is the idempotency key
- bridges must treat repeated `request_id` values as the same send request
- Core retries only when the bridge indicates the send is not durably accepted
- bridges may return `accepted` before the provider confirms delivery
- delivery/read receipts come back later as inbound events

### Error Model

- `409 Conflict`: duplicate with incompatible payload
- `422 Unprocessable Entity`: unsupported content, bad recipient, or invalid provider state
- `424 Failed Dependency`: provider session not linked or not ready
- `503 Service Unavailable`: transient provider or bridge outage

## Health Contract

### Endpoint

`GET {bridge.host_url}/health`

### Response

```json
{
  "protocol_version": "2026-03-30",
  "status": "ok",
  "channel": "signal",
  "account": {
    "provider_account_id": "+4915112345678"
  },
  "supported_protocol_versions": ["2026-03-30"],
  "capabilities": {
    "attachments_inbound": true,
    "attachments_outbound": true,
    "receipts": true,
    "typing": false,
    "groups": true,
    "message_updates": false,
    "message_deletes": false
  },
  "bridge_version": "0.1.0",
  "provider_version": "signal-cli 0.13.x",
  "last_inbound_at": "2026-03-30T12:00:00Z",
  "last_outbound_at": "2026-03-30T12:00:12Z",
  "uptime_seconds": 3600
}
```

Core maps this into the existing `bridges.status` and `last_health_check_at` fields:

- `ok` -> `healthy`
- `degraded` -> `unhealthy`
- `error` -> `unhealthy`
- request timeout -> `unhealthy`

## Session Resolution

Core resolves sessions. Bridges never choose an agent session.

Core first resolves an agent binding from channel + account + thread using the `agent_channel_bindings` model described in PRD 03 or an equivalent resolver.

The session key is then:

`workspace + resolved_agent + channel + account.provider_account_id + conversation.provider_thread_id`

Rules:

- DMs reuse one ongoing session per logical bridge conversation
- group chats isolate by `provider_thread_id`
- the bridge payload may include sender metadata, but it does not override workspace ownership
- bridge deployment changes must not fork sessions if `channel + account + thread` are unchanged
- built-in web chat remains a direct channel and does not use the HTTP bridge protocol

## Sender Authorization

Bridge-to-Core authentication (bearer tokens, signatures) proves that a bridge is legitimate. Sender authorization is a separate concern: it determines **what happens** when a legitimate bridge delivers a message from a specific external person.

Without sender authorization, anyone who knows the bridge's external account (e.g., a Signal phone number) can trigger agent execution. For a personal AI assistant with access to memory, vault, and tools, this is a critical trust boundary.

### Design Principles

- **Default-deny for agent execution.** Unknown senders never trigger agent execution.
- **Always persist.** Every inbound message is stored in `bridge_events` regardless of sender trust level, for audit and later review.
- **Workspace-level identity.** A contact recognized on Signal should be recognizable on Telegram if the user links them. Trust is not siloed per bridge.
- **User controls everything.** The user decides who can interact with their agents, at what level, and can revoke access instantly.

### Sender Trust Levels

| Level | Agent Execution | Message Persisted | Owner Notified | Description |
|-------|----------------|-------------------|----------------|-------------|
| `owner` | yes | yes | no | The workspace owner messaging from their own external account |
| `trusted` | yes | yes | no | Explicitly approved contacts with full agent interaction |
| `known` | no | yes | optional | Recognized contacts, messages visible in UI but no agent execution |
| `blocked` | no | yes | no | Explicitly denied, silently persisted for audit only |
| `unknown` | no | yes | yes | First contact, pending review |

### Contact Registry

Sender authorization is managed through a **workspace-level contact registry** that maps external identities to trust levels.

#### `contacts` Table

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `workspace_id` | uuid FK | Owning workspace |
| `display_name` | string | User-assigned name |
| `trust_level` | string | `owner`, `trusted`, `known`, `blocked` |
| `notes` | text | Optional user notes about this contact |
| `created_at` | timestamp | When the contact was first seen or created |
| `updated_at` | timestamp | Last trust level change |

**Index**: `[workspace_id, trust_level]`.

#### `contact_identities` Table

Links a contact to one or more external provider identities, enabling cross-channel recognition.

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid PK | UUIDv7 |
| `contact_id` | uuid FK | Parent contact |
| `channel` | string | `signal`, `telegram`, `whatsapp` |
| `provider_id` | string | Canonical provider identity (ACI, Telegram user ID, etc.) |
| `phone_number` | string | Optional, for display and matching |
| `username` | string | Optional provider username |
| `verified_at` | timestamp | When this identity was confirmed to belong to this contact |

**Index**: `[channel, provider_id]` unique.

### Per-Bridge Default Policy

Each bridge has a `default_sender_policy` that determines how unknown senders are handled:

| Policy | Behavior |
|--------|----------|
| `owner_only` | Only the workspace owner's linked identity can trigger the agent. All others treated as `unknown`. Strictest mode. |
| `contacts_only` | Only senders with an existing contact record at `trusted` or higher can trigger the agent. Default for personal bridges. |
| `notify_on_unknown` | Same as `contacts_only` for execution, but unknown senders generate a notification for the workspace owner. Recommended default. |

There is no `allow_all` policy. Agent execution always requires an explicit trust decision.

### Inbound Processing Flow

```
bridge delivers inbound event
  │
  ├─ 1. persist raw event in bridge_events (always, regardless of outcome)
  │
  ├─ 2. extract sender identity (provider_id, phone_number, username)
  │
  ├─ 3. resolve contact
  │     ├─ match contact_identities by (channel, provider_id)
  │     ├─ fallback: match by (channel, phone_number) if provider_id unknown
  │     └─ no match → create contact with trust_level = "unknown"
  │
  ├─ 4. check trust level
  │     ├─ owner or trusted → proceed to session resolution and agent execution
  │     ├─ known → persist message in session (visible in UI), skip agent execution
  │     ├─ blocked → persist in bridge_events only, no session, no notification
  │     └─ unknown → persist in bridge_events, apply bridge default_sender_policy:
  │           ├─ notify_on_unknown → create notification for workspace owner
  │           └─ owner_only / contacts_only → silent persist only
  │
  └─ 5. if authorized: resolve session → enqueue agent execution (as existing flow)
```

### First Contact Flow

When an unknown sender messages a bridge for the first time:

1. The message is persisted in `bridge_events` with full sender metadata.
2. A new `contact` record is created with `trust_level: "unknown"` and the sender's identity linked in `contact_identities`.
3. If the bridge policy is `notify_on_unknown`, the workspace owner receives a notification (web UI push, and optionally via another bridge channel).
4. The notification includes sender identity, message preview, and actions: **Approve** (set to `trusted`), **Acknowledge** (set to `known`), or **Block**.
5. No agent execution occurs until the owner makes a trust decision.
6. If the owner approves, subsequent messages from that sender trigger agent execution immediately.

### Owner Identity Linking

The workspace owner can link their own external accounts (e.g., "this Signal number is me") to the `owner` trust level. This enables the owner to message their own agent from Signal and have it respond, which is the primary personal assistant use case.

Owner identity linking happens during bridge provisioning or in workspace settings. The linked identity is stored as a `contact_identity` on a contact with `trust_level: "owner"`.

### Group Chat Authorization

Group chats introduce multiple senders in one thread. Authorization rules:

- The bridge delivers group messages with `thread_type: "group"` and individual `sender` per message.
- Each sender in a group is resolved against the contact registry independently.
- Agent execution for a group message requires the **sender** (not the group) to be `trusted` or `owner`.
- Messages from `known` or `unknown` senders in a trusted group are persisted but do not trigger agent execution.
- A future extension may add group-level trust (trust all members of a specific group), but v1 resolves per-sender.

### Emergency Lockdown

The workspace owner can immediately stop all inbound agent execution:

- **Per-bridge**: set bridge status to `disabled`. Core rejects all inbound events with `403` and stops outbound sends. The bridge continues to run but messages are not processed.
- **Per-workspace**: a workspace-level kill switch disables all bridges at once. Useful if the owner suspects compromise of any channel.

Re-enabling requires explicit action in the web UI. There is no automatic re-enable.

### Trust Level Changes

- Changing a contact from `trusted` to `known` or `blocked` takes effect immediately on the next inbound message. In-flight agent executions already enqueued are not cancelled.
- Changing a contact to `trusted` does not retroactively process previously received messages. The contact can send new messages to interact with the agent going forward.
- Trust level changes are logged in `bridge_events` with event family `authorization.changed` for audit.

## Security

### Self-Hosted

- bearer token auth is enough for MVP
- HTTPS required
- host URL must pass SSRF validation and allowlist checks
- token rotation must be supported without bridge recreation

### Managed

Managed bridges must add detached request signing on top of bearer auth:

- per-bridge Ed25519 keypair generated at provisioning time
- Core stores the public key
- bridge signs `(method, path, timestamp, nonce, sha256(body))`
- Core rejects requests older than 5 minutes
- Core stores used nonces to block replay
- source IP checks are defense-in-depth only, not the primary trust boundary

## Attachments

Inbound media stays bridge-local initially.

Flow:

1. bridge receives provider payload and downloads provider attachment if needed
2. bridge exposes a temporary authenticated `download_url`
3. Core fetches the file, stores it in canonical storage, and replaces the temporary URL with internal storage metadata

Why not inline base64 in inbound events:

- it inflates webhook payloads
- it complicates retries
- it makes event persistence expensive

Outbound media flow:

1. Core sends one or more `content.attachments[*].download_url` values
2. bridge downloads each file
3. bridge converts the files into the provider's upload/send format

## Observability And Auditing

Every bridge interaction should emit a `bridge_events` row.

Recommended event families:

- `inbound.accepted`
- `inbound.duplicate`
- `inbound.rejected`
- `outbound.accepted`
- `outbound.failed`
- `health.ok`
- `health.failed`
- `provisioning.changed`
- `authorization.changed`

The event table is the audit trail for:

- debugging webhook disputes
- usage reconciliation
- managed bridge incident response

## Rollout

### Phase 1

- Signal external bridge only
- `message.received` and text/file/image outbound sends
- health polling every minute for managed bridges
- Core-side idempotency and bridge event persistence

### Phase 2

- Telegram built-in adapter conforms to the same normalized Core event model
- delivery/read receipts
- richer group metadata

### Phase 3

- pooled bridge runtime
- optional bridge capability negotiation for edits, reactions, stories, and presence

## Alternatives Considered

### Provider Webhooks Directly Into Rails

Rejected because it would leak channel-specific auth, payload normalization, and provider operational quirks into the main app.

### Message Broker Between Core And Bridges

Rejected for MVP because HTTP plus idempotency is easier to operate, easier for self-hosters, and already matches the PRD.

### Phone-Number-Only Identity

Rejected because Signal upstream already treats phone number privacy as a first-class constraint. The protocol must support opaque provider IDs and usernames from day one.

## References

- [PRD 02: Integrations & Channels](../prd/02-integrations-and-channels.md)
- [PRD 01: Platform & Infrastructure](../prd/01-platform-and-infrastructure.md)
- [signal-cli man page](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli.1.adoc)
- [signal-cli JSON-RPC man page](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli-jsonrpc.5.adoc)
