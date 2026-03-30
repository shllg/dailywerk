---
type: rfc
title: "Deployment — Manual Setup Steps"
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/06-deployment-hetzner
phase: 1
---

# RFC: Deployment — Manual Setup Steps

## Context

This RFC covers the operator actions that cannot be cleanly automated away: Hetzner provisioning, Cloudflare setup, credentials, GitHub/GHCR configuration, and the final acceptance checks for the Docker-based production model.

---

## 1. Hetzner Provisioning

### 1.1 Create the Server

1. Log into Hetzner Cloud
2. Create a project for DailyWerk
3. Create a server with:
   - **Location**: FSN1 or NBG1
   - **Image**: **Debian stable**
     - target: Debian 13 "trixie"
     - fallback only if image availability lags: Debian 12
   - **Type**: CPX41 preferred, CPX31 minimum
   - **SSH key**: add your Ed25519 key
   - **Backups**: enable Hetzner snapshots
4. Record the public IPv4 address

### 1.2 Object Storage

Create separate Hetzner Object Storage buckets:

- `dailywerk-backups`
- `dailywerk-production`
- `dailywerk-staging`

Record:

- access key ID
- secret key
- endpoint URL
- region

`dailywerk-backups` is used for encrypted off-host backups. The application buckets are used for Active Storage or other object storage needs.

---

## 2. Cloudflare Setup

### 2.1 DNS

Create proxied DNS records:

| Type | Name | Target |
|------|------|--------|
| A | `app` | server IP |
| A | `staging` | server IP |
| A | `ops` | server IP |

`ops.dailywerk.com` is the admin-facing Grafana endpoint.

### 2.2 SSL/TLS

In Cloudflare:

1. Set SSL/TLS mode to **Full (Strict)**
2. Create a Cloudflare origin certificate for:
   - `app.dailywerk.com`
   - `staging.dailywerk.com`
   - `ops.dailywerk.com`
3. Enable **Authenticated Origin Pulls**
4. Download:
   - origin certificate
   - origin private key
   - Authenticated Origin Pull CA certificate

### 2.3 Cloudflare Settings

Enable:

- Always Use HTTPS
- WebSockets
- HTTP/2
- minimum TLS 1.2 or higher

Restrict access to `ops.dailywerk.com` with either:

- Cloudflare Access, or
- Cloudflare WAF/IP rules plus Grafana auth

---

## 3. GitHub and GHCR

### 3.1 GHCR Access for the Server

Create a read-only credential for GHCR image pulls from the server.

Preferred options:

1. fine-grained PAT with package read access
2. GitHub App with package read access

Store the credential outside the repo and inject it into the host at setup time.

### 3.2 Deploy Notification Secret

Generate and store a secret used to sign deploy notifications from GitHub to the server-side deploy listener.

You need:

- `DEPLOY_WEBHOOK_URL`
- `DEPLOY_WEBHOOK_SECRET`

These are used by the workflow that reacts to published GHCR packages.

### 3.3 Repository Settings

Verify or configure:

- branch protection on `master`
- branch protection on `develop` if staging uses it
- GHCR package visibility and access rules
- GitHub Actions enabled for package publishing

---

## 4. Grafana / Ops Access

### 4.1 Decide the Admin Access Model

Choose one:

- Grafana login + Cloudflare Access
- Grafana login + IP allowlist
- Grafana login + both

Recommendation: **Grafana login + Cloudflare Access** for the cleanest browser-based admin experience.

### 4.2 Prepare Grafana Credentials

Create and store:

- Grafana admin username
- Grafana admin password

These should not be embedded directly in committed compose files.

---

## 5. WorkOS and Stripe

### 5.1 WorkOS

Configure redirect/callback URLs for:

- `https://app.dailywerk.com/...`
- `https://staging.dailywerk.com/...`

Record:

- WorkOS API key
- WorkOS client ID

### 5.2 Stripe

Configure webhook endpoints for:

- production
- staging

Record:

- publishable key
- secret key
- webhook signing secret

---

## 6. Rails Secrets and Application Credentials

### 6.1 Production Credentials

Prepare production and staging secrets for:

- Rails master key
- WorkOS
- Stripe
- object storage
- database role password
- GHCR pull token if the deploy listener expects it in env
- backup encryption/restic password material

### 6.2 Backup Encryption Material

The backup design assumes encrypted off-host backups. Prepare and store one of:

- a restic repository password, or
- an `age` public/private keypair if the implementation chooses envelope encryption for exported artifacts

Do not keep the only copy of the backup secret on the server.

---

## 7. Initial Server Access

### 7.1 First Login

```bash
ssh root@<server-ip>
```

### 7.2 Create Deploy User

```bash
adduser --disabled-password deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

### 7.3 Verify Access

```bash
ssh deploy@<server-ip>
sudo true
```

The deploy user remains the operational account even though the runtime is containerized.

---

## 8. Upload Cloudflare Certificates

```bash
scp origin.pem deploy@<server-ip>:/tmp/
scp origin-key.pem deploy@<server-ip>:/tmp/
scp authenticated_origin_pull_ca.pem deploy@<server-ip>:/tmp/
```

These are later moved into the location expected by the edge compose / Nginx container setup.

---

## 9. Post-Automation Verification

After the automation RFC has been applied, manually verify:

1. [ ] SSH as `deploy` works and root login is disabled
2. [ ] Docker Engine and `docker compose` are available
3. [ ] `dailywerk-infra` is healthy
4. [ ] PostgreSQL and Valkey are reachable only on internal Docker networks
5. [ ] `https://app.dailywerk.com/up` returns success
6. [ ] `https://staging.dailywerk.com/up` returns success
7. [ ] zero-downtime rehearsal works by deploying a harmless image change
8. [ ] `https://ops.dailywerk.com` opens Grafana
9. [ ] Grafana shows Prometheus metrics
10. [ ] Grafana Explore can query Loki logs from app, worker, and Nginx
11. [ ] backups run and an encrypted restore rehearsal succeeds
12. [ ] GHCR publish event reaches the deploy listener

---

## 10. Ongoing Manual Tasks

| Task | Frequency | Notes |
|------|-----------|-------|
| review Hetzner cost | monthly | ensure CPX41 is still the right size |
| review Cloudflare security events | weekly | especially admin endpoints |
| test restore from encrypted backup | quarterly | restore into staging or isolated temp environment |
| review Grafana alerts | weekly | confirm alert routes still work |
| review GHCR package retention | monthly | avoid unnecessary image bloat |
| Debian major upgrade planning | per release | keep stable but deliberate |
