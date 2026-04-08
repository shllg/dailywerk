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

Grafana is not publicly exposed. It is reachable only via Tailscale (see §3A below).

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

No Cloudflare configuration is needed for admin/ops access — that goes through Tailscale.

---

## 3A. Tailscale Setup

### 3A.1 Create the Tailnet

If not already done, create or use an existing Tailscale account. The server and all admin machines must join the same tailnet.

### 3A.2 Generate a Server Auth Key

1. Go to the Tailscale admin console
2. Create an auth key (reusable if needed for re-provisioning, single-use otherwise)
3. Store the auth key in 1Password (`DailyWerk Shared > tailscale > auth-key`)

### 3A.3 MagicDNS

Enable MagicDNS in the Tailscale admin console. Set the server's Tailscale hostname to `dailywerk-ops` so Grafana is reachable at `http://dailywerk-ops:3000`.

### 3A.4 ACLs (Optional)

If the tailnet is shared with other projects, restrict the DailyWerk server's Tailscale ACLs so only authorized users can reach SSH and Grafana ports.

### 3A.5 Admin Machines

Each operator must:

1. Install Tailscale on their machine
2. Join the same tailnet
3. Verify they can reach the server's Tailscale IP

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
- branch protection on `dev` if staging uses it
- GHCR package visibility and access rules
- GitHub Actions enabled for package publishing

---

## 4. Grafana / Ops Access

### 4.1 Access Model

Grafana is accessible only via Tailscale at `http://dailywerk-ops:3000`. No public internet exposure.

Grafana admin auth is still required as a secondary layer — Tailscale membership grants network access, not application access.

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

## 6. Secrets — 1Password Setup

### 6.1 Create Vaults

Create three vaults in 1Password:

| Vault | Purpose |
|-------|---------|
| `DailyWerk Production` | All production secrets |
| `DailyWerk Staging` | All staging secrets |
| `DailyWerk Shared` | Secrets shared across environments (deploy webhook, GHCR, Tailscale, Cloudflare certs) |

### 6.2 Populate Vault Items

For each environment vault, create items with fields as specified in the Codebase Changes RFC §8.4 (vault structure table).

At minimum, each environment needs:

- Rails master key and secret key base
- DATABASE_URL
- VALKEY_URL
- WorkOS API key and client ID
- Stripe secret key, webhook secret, publishable key
- S3/object storage credentials
- Metrics basic auth credentials
- Grafana admin credentials
- Restic backup password

### 6.3 Create a Service Account

1. In 1Password, create a service account named `dailywerk-server`
2. Grant it read access to all three vaults
3. Record the `OP_SERVICE_ACCOUNT_TOKEN`

This token is the **only secret that must be manually placed on the server**. All other secrets are retrieved via `op read` at deploy time.

### 6.4 Backup Encryption Material

The restic repository password must be stored in 1Password (`DailyWerk Production > backup > restic-password`) and also kept in a separate offline backup (e.g., printed or in a separate 1Password vault accessible to the account owner).

Do not keep the only copy of any secret on the server.

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
8. [ ] `http://dailywerk-ops:3000` opens Grafana via Tailscale
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
