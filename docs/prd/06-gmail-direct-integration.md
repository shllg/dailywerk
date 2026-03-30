---
type: prd
title: Gmail Direct Integration (Future)
domain: integrations
created: 2026-03-31
updated: 2026-03-31
status: deferred
depends_on:
  - prd/02-integrations-and-channels
  - prd/01-platform-and-infrastructure
trigger: user-count-threshold
---

# DailyWerk — Gmail Direct Integration via Managed OAuth

> Future-looking PRD for when DailyWerk has enough users to justify CASA verification.
> This is NOT currently planned for implementation. It documents the path, costs, and process so the decision can be made quickly when the time comes.
> Current email integration paths: [Inbound Email RFC](../rfc-open/2026-03-31-inbound-email-processing.md), [IMAP/SMTP RFC](../rfc-open/2026-03-31-imap-smtp-integration.md), [BYOA OAuth RFC](../rfc-open/2026-03-31-google-integration.md).

---

## 1. What This Enables

DailyWerk registers its own Google Cloud project with verified restricted Gmail scopes. Users click "Connect Gmail" — one-click OAuth, no GCP console, no app passwords, no forwarding setup. The agent gets full programmatic access to the user's Gmail: read, search, send, label, archive.

This is the gold-standard Gmail integration. Every major SaaS (Superhuman, Notion, Linear) uses this path. The blocker is Google's CASA (Cloud Application Security Assessment) requirement for restricted scopes.

---

## 2. Why It's Deferred

### CASA Requirement

Google classifies most useful Gmail scopes as **restricted**:

| Scope | Classification |
|-------|---------------|
| `gmail.readonly` | Restricted |
| `gmail.modify` | Restricted |
| `gmail.compose` | Restricted |
| `gmail.insert` | Restricted |
| `gmail.metadata` | Restricted |
| `gmail.send` | **Sensitive** (not restricted) |
| `gmail.labels` | Non-sensitive |

Restricted scopes require CASA — a paid annual third-party security audit. Without it, DailyWerk is capped at 100 lifetime users (not concurrent — lifetime, non-resettable) and users see a scary "This app isn't verified" warning.

### Cost & Timeline

| Item | Details |
|------|---------|
| Brand verification | Free, 2–3 business days |
| Sensitive scope verification | Free, 1–4 weeks |
| CASA Tier 2 assessment (TAC Security) | $540–720/year |
| CASA Tier 3 assessment (if assigned) | $4,500+/year |
| Total first-time timeline | 4–12 weeks |
| Annual renewal | Full re-assessment, same cost |

### Current Alternatives Cover the Use Cases

| Use Case | Current Path |
|----------|-------------|
| User forwards content to agent | Inbound email (zero setup) |
| Agent reads user's inbox | IMAP/SMTP (user provides credentials) |
| Agent sends as user | IMAP/SMTP or `gmail.send` (sensitive, no CASA) |
| Power user wants full Gmail API | BYOA OAuth (user creates own GCP project) |

---

## 3. When to Trigger

Consider CASA verification when:

- **Active paying users exceed 50** — the operational overhead is justified
- **User feedback consistently requests one-click Gmail** — BYOA/IMAP setup is a churn driver
- **A competitor ships one-click Gmail** — table-stakes parity
- **DailyWerk already passes most OWASP ASVS controls** — remediation cost is low

Do NOT trigger based on:
- "Nice to have" — the alternatives work
- Investor pressure without user demand
- A single enterprise deal (use domain-wide delegation instead)

---

## 4. The CASA Process

### Step-by-Step

1. **Prepare materials**
   - Privacy policy on dailywerk.com (already needed for other features)
   - YouTube demo video showing Gmail scope usage and user-facing features
   - Written justification for each restricted scope

2. **Configure GCP production project**
   - Separate project from dev/staging
   - Enable Gmail API
   - OAuth consent screen with all restricted scopes
   - Click "Publish App" → moves to "In Production" (unverified)

3. **Submit for verification**
   - Google reviews branding, scope justification, demo video
   - Expect 1–4 weeks of email back-and-forth (Google responds in 24–48 hours per email)
   - Google assigns CASA tier (likely Tier 2 for a small SaaS)

4. **Engage authorized lab**
   - Recommended: TAC Security ($540–720 for Tier 2)
   - Provide: login credentials, deployed app URL, source code access (for SAST)
   - Lab runs SAST (static code analysis) + DAST (dynamic testing against live app)

5. **Remediate findings**
   - Fix all vulnerabilities the scans found (zero exceptions)
   - Common findings: security headers, TLS config, input validation, error disclosure
   - Lab re-validates after fixes

6. **Receive Letter of Validation (LOV)**
   - Lab issues LOV directly to Google
   - Google lifts 100-user cap and removes "unverified app" warning
   - Full Gmail integration goes live

### What Auditors Check (OWASP ASVS Level 2)

14 categories, 134 requirements. Key areas:

- **Authentication**: login flows, password hashing, MFA, credential storage
- **Session management**: unique sessions, timeouts, invalidation
- **Access control**: authorization enforcement, data isolation (RLS helps here)
- **Input validation**: injection prevention, XSS, encoding
- **Cryptography**: encryption at rest (ActiveRecord::Encryption), key management
- **Communications**: TLS configuration, certificate validation
- **Error handling**: no stack traces in production, audit logging
- **API security**: rate limiting, authentication, input validation
- **Configuration**: secure defaults, dependency management

DailyWerk's existing architecture (RLS, encrypted credentials, workspace isolation) already satisfies many of these. The gap is likely operational controls: security headers, CSP policy, dependency scanning in CI, structured audit logging.

### Tier System

| Tier | Who Gets It | What Happens | Cost |
|------|-------------|--------------|------|
| Tier 1 | Very low risk | Self-assessment only | Free |
| Tier 2 | Most restricted-scope apps | You scan, lab validates results | $540–1,800/year |
| Tier 3 | High risk / large user base | Lab independently tests everything | $4,500+/year |

Google assigns the tier — you don't choose. A small SaaS with moderate user count will almost certainly get Tier 2. Once assigned Tier 3, you stay there permanently.

### Annual Renewal

- Google emails ~12 months from LOV date
- Full re-assessment required (same scope as initial)
- Same lab or different lab — your choice
- Faster if using the same lab (they already know the app)
- Missing the deadline: restricted scope access is revoked

---

## 5. Google's Limited Use Policy

Apps with restricted Gmail scopes must comply with Google's Limited Use Policy. Key constraints:

### Allowed

- Read emails to provide user-facing AI features (summaries, drafts, scheduling)
- Process email content for user-initiated actions (create tasks, extract events)
- Store email data as needed to provide the feature

### Prohibited

- Use email data for advertising or targeting
- Sell or transfer email data to third parties
- Train AI models on user email content
- Build searchable databases of email content beyond feature needs
- Allow human employees to read user emails without explicit per-message consent

### Required

- Encrypt email data in transit and at rest
- Delete user data on request
- Include Limited Use compliance statement on website
- Annual re-verification of compliance

### DailyWerk Implications

- Agent processing of emails for user-facing features: **allowed**
- Storing email summaries in agent memory: **allowed** (it's a user-facing feature)
- Embedding email content in pgvector for search: **gray area** — likely allowed if scoped to the user's own search, but worth legal review
- Using email content to improve DailyWerk's models: **prohibited**

---

## 6. Scope Strategy

### Minimum Viable Scopes

| Feature | Scope | Classification |
|---------|-------|---------------|
| Read inbox | `gmail.readonly` | Restricted |
| Send email | `gmail.send` | Sensitive |
| Modify (label, archive, star) | `gmail.modify` | Restricted |
| Manage labels | `gmail.labels` | Non-sensitive |

### Incremental Authorization

Use `include_granted_scopes=true` to let users connect incrementally:

1. Start with `gmail.send` + `gmail.labels` (sensitive + non-sensitive, no CASA)
2. Add `gmail.readonly` when user enables inbox reading (restricted, requires CASA)
3. Add `gmail.modify` when user enables label/archive actions (restricted)

This means DailyWerk can ship `gmail.send` (sensitive scope) before CASA, and only trigger CASA when read access is needed.

---

## 7. Technical Implementation (When Triggered)

The [Google Integration RFC](../rfc-open/2026-03-31-google-integration.md) already builds the OAuth infrastructure, token storage, and refresh logic. Adding managed Gmail OAuth is an incremental change:

1. Register DailyWerk's GCP project with Gmail restricted scopes
2. Complete CASA verification
3. Add `platform` credential source for Gmail (currently only Calendar uses platform credentials)
4. Add `gmail.readonly` and `gmail.modify` to the incremental scope flow
5. Implement Gmail-specific sync (History API, Pub/Sub push notifications)
6. Connect to the `EmailService` interface from the IMAP/SMTP RFC

### Gmail-Specific Infrastructure

- **Push notifications**: Gmail uses Google Pub/Sub (not HTTPS webhooks like Calendar). Need to create a Pub/Sub topic, grant `gmail-api-push@system.gserviceaccount.com` publish rights.
- **`users.watch`**: registers push notifications, expires every ~7 days. `RenewGmailWatchJob` already in PRD 04 cron config.
- **History API**: `history.list` with `startHistoryId` for incremental sync. Falls back to full sync if historyId expires (HTTP 404).
- **Rate limits**: 250 quota units/user/second. `messages.send` costs 100 units. Plan for exponential backoff.

---

## 8. Domain-Wide Delegation (Enterprise Alternative)

For Google Workspace organizations, there's a CASA-free path: **service account with domain-wide delegation**. The org admin grants DailyWerk's service account access to specific scopes for their domain.

| Aspect | User OAuth | Domain-Wide Delegation |
|--------|-----------|----------------------|
| CASA required | Yes | No |
| Works for | Consumer + Workspace | Workspace only |
| Setup by | Each user | Org admin (once) |
| Scope | Per-user consent | Org-wide policy |
| Use case | B2C | B2B/Enterprise |

This is relevant if DailyWerk targets team/enterprise plans. Not applicable for individual users.

---

## 9. Open Questions

1. **pgvector embedding of email content** — Does this violate Limited Use Policy's prohibition on "building databases"? Likely fine if scoped to the user's own search, but needs legal review before CASA.
2. **CASA tier prediction** — Will DailyWerk get Tier 2 or Tier 3? Depends on user count and data sensitivity at time of application.
3. **`gmail.send` as intermediate step** — Ship send-only with platform credentials before CASA? Low friction, no restricted scopes. But users can already send via IMAP/SMTP.

## References

- [PRD 02: Email Integration](02-integrations-and-channels.md#3-email-integration)
- [RFC: Google Integration](../rfc-open/2026-03-31-google-integration.md)
- [RFC: Inbound Email Processing](../rfc-open/2026-03-31-inbound-email-processing.md)
- [RFC: IMAP/SMTP Integration](../rfc-open/2026-03-31-imap-smtp-integration.md)
- [Google Restricted Scope Verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
- [App Defense Alliance — CASA](https://appdefensealliance.dev/casa)
- [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)
- [TAC Security CASA Assessment](https://tacsecurity.com/google-casa-cloud-application-security-assessment/)
