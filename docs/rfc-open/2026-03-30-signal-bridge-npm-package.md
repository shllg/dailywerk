---
type: rfc
title: Signal Bridge npm Package
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/02-integrations-and-channels
depends_on:
  - rfc/2026-03-30-messaging-gateway-and-bridge-protocol
phase: 2
---

# RFC: Signal Bridge npm Package

## Context

Issue 3 asks for a self-hosted Signal package that follows the bridge protocol cleanly enough to become the foundation for `dailywerk/signal-bridge`.

The local PRD already captures the high-level business need:

- Signal is the privacy-focused external channel
- self-hosted support is required
- managed hosting is a paid add-on

The missing part is the technical boundary.

Upstream research changes the design in two important ways:

1. official `signal-cli` already exposes a daemon with JSON-RPC and HTTP support, so DailyWerk does not need to invent its own control interface
2. `signal-cli` supports **linked device** mode, so "dedicated phone number only" is too strict as a default assumption

This RFC intentionally updates the self-hosted Signal assumption from PRD 02. The researched change is:

- self-hosted should default to linked-device onboarding
- dedicated-number registration remains supported for explicit headless setups
- managed Signal remains a product goal and should consume the same package/runtime boundary rather than a different stack

## Decision

Publish a Node 22 + TypeScript package named **`@dailywerk/signal-bridge`**.

The package is **library-first**, with a thin CLI for self-hosted operators and a reusable provisioner/runtime boundary that DailyWerk can drive from the dashboard for managed or guided self-hosted setups.

Primary design choices:

1. The primary upstream target is the **official `signal-cli` daemon**.
2. The package prefers **linked-device onboarding** over direct account registration.
3. The package uses the official JSON-RPC interface for sends and receive subscriptions.
4. The package implements DailyWerk Bridge Protocol v1 on top of that transport.
5. The package supports **one Signal account per runtime** in v1.
6. Compatibility with `bbernhard/signal-cli-rest-api` is optional and isolated behind a separate transport adapter.

## Why Official `signal-cli` Is The Primary Transport

The official daemon already gives us what we need:

- JSON-RPC commands for send and account operations
- `subscribeReceive` for controlled receive loops
- `startLink` and `finishLink` for linked-device onboarding
- an HTTP transport option for remote or containerized operation
- `/api/v1/check` for health checks

Using the official daemon as the primary contract reduces indirection and lets DailyWerk own the normalization layer instead of depending on a third-party REST API surface.

## Why Linked Device Is The Default

The PRD currently warns that registering a number with `signal-cli` deregisters it from the user's phone. That is true for direct registration, but upstream `signal-cli` also supports linking to an existing device.

Therefore the package should default to:

- **linked-device flow** for the common self-hosted case
- **direct registration flow** only when the operator explicitly chooses a dedicated number path

That keeps the safe UX by default without pretending the dedicated-number path is the only option.

## Package Scope

### Included In V1

- official daemon transport over HTTP JSON-RPC
- link and registration provisioners
- send helpers for text and attachments
- receive loop with message normalization
- Bridge Protocol v1 client for DailyWerk Core
- minimal CLI for `link`, `run`, and `doctor`
- compatibility transport for `signal-cli-rest-api`

### Deferred

- multi-account bridge runtime
- pooled/shared bridge hosting
- sticker/stories specific helpers
- embedded Signal binary management
- non-HTTP transports for remote daemon access

## Package Layout

```text
@dailywerk/signal-bridge
  /client
    SignalClient
    OfficialDaemonTransport
    RestApiCompatibilityTransport
  /runtime
    DailyWerkBridgeRuntime
    AttachmentStore
    HealthReporter
  /cli
    dailywerk-signal-bridge
```

## Public API

### Low-Level Client

```ts
import {
  SignalClient,
  officialDaemonHttpTransport
} from "@dailywerk/signal-bridge/client";

const client = new SignalClient({
  transport: officialDaemonHttpTransport({
    baseUrl: "http://127.0.0.1:8080",
    timeoutMs: 10_000
  }),
  account: "+4915112345678"
});

await client.health();
await client.sendText({
  recipients: ["u:sascha.123"],
  text: "hello"
});
```

### Bridge Runtime

```ts
import { DailyWerkBridgeRuntime } from "@dailywerk/signal-bridge/runtime";

const runtime = new DailyWerkBridgeRuntime({
  signal: {
    transport: {
      kind: "official-daemon-http",
      baseUrl: "http://127.0.0.1:8080"
    },
    account: "+4915112345678"
  },
  dailywerk: {
    bridgeId: "brg_01JQXYZ",
    apiBaseUrl: "https://api.dailywerk.com",
    apiKey: process.env.DAILYWERK_BRIDGE_API_KEY!
  }
});

await runtime.start();
```

## Transport And Provisioning Interfaces

The package should isolate steady-state messaging from one-time provisioning.

### Runtime Transport

```ts
export interface SignalTransport {
  health(): Promise<SignalHealth>;
  subscribeReceive(input: { account: string }): AsyncIterable<SignalEnvelope>;
  send(input: SignalSendRequest): Promise<SignalSendResult>;
}
```

### Provisioner

```ts
export interface SignalProvisioner {
  startLink(input: { deviceName: string }): Promise<{ deviceLinkUri: string }>;
  finishLink(input: { deviceLinkUri: string; deviceName?: string }): Promise<void>;
  register(input: {
    account: string;
    captcha?: string;
    voice?: boolean;
  }): Promise<void>;
  verify(input: {
    account: string;
    verificationCode: string;
    pin?: string;
  }): Promise<void>;
}
```

### Official Daemon Transport

Primary implementation:

- use `POST /api/v1/rpc`
- use `subscribeReceive` in `--receive-mode=manual`
- use `/api/v1/check` for liveness

Why `subscribeReceive` instead of SSE as the primary path:

- it keeps receive behavior explicit
- it fits the official RPC model directly
- it gives the runtime one place to manage reconnect logic

SSE support from `/api/v1/events` can remain a future transport optimization, but it should not be the v1 core path.

### Official Provisioner

The official linked-device and registration helpers should not be coupled to the steady-state runtime transport.

Implementation rule:

- use a temporary provisioning daemon in multi-account mode or a controlled subprocess shell-out
- complete linking or registration first
- start the long-lived one-account runtime only after credentials exist locally

### REST Compatibility Transport

Compatibility implementation for operators who already run `bbernhard/signal-cli-rest-api`.

Rules:

- kept in a separate module to avoid leaking third-party payload shapes into the core runtime
- feature set limited to what maps cleanly into the official transport model
- documented as compatibility mode, not the preferred path

## Onboarding Flows

### Preferred: Linked Device

Flow:

1. DailyWerk dashboard or CLI starts a link session
2. provisioner requests a `deviceLinkUri`
3. UI or CLI renders QR or prints the deep link
4. user links the bridge from the Signal mobile app
5. dashboard or CLI completes `link finish`
6. runtime switches into normal single-account mode

This should be the default in docs and UX for self-hosted setups.

### Fallback: Direct Registration

Flow:

1. operator configures a dedicated number
2. provisioner shells out to `signal-cli register` or talks to a provisioning daemon
3. user enters SMS/voice verification code
4. optional registration lock PIN is handled
5. runtime starts after verification

This mode must carry a strong warning:

- it is more operationally fragile
- it may replace the user's primary mobile registration
- it is for dedicated-number setups only

## Runtime Model

The bridge runtime is a long-lived Node process that does four jobs:

1. subscribe to Signal inbound events
2. normalize events into Bridge Protocol v1 payloads
3. deliver those payloads to DailyWerk Core with idempotent retries
4. expose local health and media endpoints for Core callbacks

### One Runtime Per Account

V1 intentionally keeps a one-account-per-runtime rule.

Why:

- simpler persistence and secret handling
- clearer health status
- easier self-hosting
- aligns with DailyWerk's per-user managed bridge billing

## Message Normalization

The package should expose a single normalized envelope before it touches DailyWerk:

```ts
export interface NormalizedSignalMessage {
  providerMessageId: string;
  providerThreadId: string;
  sender: {
    providerId: string;
    phoneNumber?: string;
    username?: string;
    displayName?: string;
    deviceId?: number;
  };
  text?: string;
  attachments: NormalizedAttachment[];
  raw: unknown;
}
```

Normalization rules:

- prefer stable provider IDs over phone numbers
- preserve Signal usernames when available
- preserve raw upstream payload for debugging
- map group IDs directly to `providerThreadId`
- treat receipts and typing events as separate normalized event families

## Attachment Handling

Signal attachments are local bridge concerns first, Core concerns second.

Inbound flow:

1. `signal-cli` downloads or exposes the attachment locally
2. runtime stores attachment metadata in a local temporary store
3. runtime exposes `GET /v1/media/:attachment_id`
4. runtime includes that URL in the Bridge Protocol event
5. Core downloads and moves the file into canonical storage

Outbound flow:

1. Core sends `content.attachments[*].download_url`
2. runtime downloads the file to a temp path
3. transport sends it through `signal-cli`
4. temp file is removed after send or retry exhaustion

## Reliability

### Receive Path

The receive loop must be at-least-once from the package's point of view.

Rules:

- every inbound message is converted into a deterministic `event_id`
- the runtime records pending deliveries locally before posting to Core
- successful Core `202` responses clear the local pending record
- reconnects replay any undelivered pending events first
- bridge redeployments must preserve logical identity for the same Signal account and thread

Suggested `event_id` basis:

`channel + logical_account_id + providerThreadId + providerMessageId + eventType`

### Outbound Path

Rules:

- Core `request_id` becomes the bridge idempotency key
- runtime stores accepted but not yet provider-confirmed sends in a small local queue
- transport retries use exponential backoff with jitter
- permanent provider errors are surfaced back to Core without retry loops

## Operational Rules

### Version Cadence

Upstream `signal-cli` warns that releases older than roughly three months may stop working correctly as Signal server behavior changes.

Therefore the package release policy should be:

- track current supported `signal-cli` releases actively
- publish compatibility updates quickly after upstream changes
- fail health checks when the upstream version is outside the supported window

### Persistence

The runtime needs three persistent areas:

- the `signal-cli` config directory
- a small runtime state directory for pending inbound/outbound events
- logs

For Docker deployments, these must be mounted explicitly.

## CLI

The published package should include a small operator CLI:

```text
dailywerk-signal-bridge link start
dailywerk-signal-bridge link finish
dailywerk-signal-bridge run
dailywerk-signal-bridge doctor
```

CLI goals:

- keep self-hosted onboarding simple
- avoid making operators hand-craft JSON-RPC requests
- provide a minimal health/debug story without requiring custom code

## Security

- DailyWerk bridge API key stored outside the repo and injected at runtime
- no plaintext logging of message content by default
- signed requests for managed mode remain a runtime concern layered above the package
- attachment endpoints require bridge auth or short-lived signed URLs
- SSRF-safe download policy for outbound attachment URLs

## Docker Image Relationship

`dailywerk/signal-bridge` should be a thin image around this npm package plus `signal-cli`.

That keeps:

- the package reusable for self-hosters who do not want the official image
- the image small in scope
- the transport logic testable outside Docker

## Alternatives Considered

### Package Against `signal-cli-rest-api` Only

Rejected because it makes DailyWerk depend on a third-party REST surface when the official daemon already provides a viable machine interface.

### Dedicated Number Only

Rejected because linked-device mode exists and should be the lower-risk default for self-hosters.

### Bundle `signal-cli` Inside The npm Package

Rejected because shipping native binaries and Java runtime concerns inside the package adds platform complexity that belongs in the Docker image or host environment.

## Rollout

### Phase 1

- package skeleton
- official daemon transport
- linked-device CLI
- bridge runtime for text, file, and image messages

### Phase 2

- dashboard-driven self-hosted onboarding on top of the same provisioner
- managed-mode helpers and image integration
- rest-api compatibility transport
- richer receipts and typing support
- better operator diagnostics

### Phase 3

- pooled/shared runtime support

## References

- [RFC: Messaging Gateway & Bridge Protocol](./2026-03-30-messaging-gateway-and-bridge-protocol.md)
- [signal-cli README](https://github.com/AsamK/signal-cli/blob/master/README.md)
- [signal-cli man page](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli.1.adoc)
- [signal-cli JSON-RPC man page](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli-jsonrpc.5.adoc)
- [signal-cli-rest-api README](https://github.com/bbernhard/signal-cli-rest-api/blob/master/README.md)
