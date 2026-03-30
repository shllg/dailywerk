---
type: rfc
title: "Deployment — Server Automation (Claude Code)"
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/06-deployment-hetzner
phase: 1
---

# RFC: Deployment — Server Automation (Claude Code)

## Context

This RFC describes what Claude Code should automate on the Hetzner host after the manual setup is complete. The target model is Debian + Docker Engine + Docker Compose + GHCR + blue/green slots.

The server automation should produce:

- a hardened Debian host
- Docker/Compose runtime
- dedicated compose projects for infra, edge, observability, and app slots
- zero-downtime deploy switching
- mandatory Prometheus/Grafana/Loki
- compressed and encrypted backup automation

---

## 1. Preconditions

Before running these steps:

- the Hetzner server exists
- the `deploy` user exists with sudo access
- Cloudflare origin certs are available on the server
- a Tailscale auth key is available (from 1Password or provided directly)
- the `OP_SERVICE_ACCOUNT_TOKEN` for 1Password is available
- GHCR read credentials exist (in 1Password)
- backup encryption material exists (in 1Password)

All app secrets are stored in 1Password and retrieved at runtime — they do not need to be pre-staged as files.

Claude Code should stop if those prerequisites are missing.

---

## 2. Phase 1 — Debian Hardening

Run as `deploy` with sudo.

### 2.1 SSH Hardening

- move SSH to a non-default port
- disable password auth
- disable root login
- limit auth attempts
- allow only the deploy user

### 2.2 Firewall

Configure `ufw` to allow:

- 443/tcp from Cloudflare IP ranges (for app/staging traffic)
- all traffic on the Tailscale interface (`tailscale0`)

SSH is **not** exposed on the public interface. Admin access (SSH, Grafana) is reachable only via Tailscale.

Everything else should remain denied on the public interface.

### 2.3 Baseline Security Packages

Install and enable:

- `fail2ban`
- `unattended-upgrades`
- basic audit/debug packages such as `curl`, `jq`, `htop`, `git`

### 2.4 Remove Unnecessary Host Services

Disable services not needed for the host profile. Keep the host minimal because application dependencies now live in containers.

---

## 3. Phase 2 — Docker Runtime Installation

### 3.1 Install Docker Engine and Compose Plugin

Use the official Docker Debian repository and install:

- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-buildx-plugin`
- `docker-compose-plugin`

### 3.2 Docker Daemon Configuration

Create `/etc/docker/daemon.json` with at least:

```json
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
```

`live-restore` reduces accidental downtime during Docker daemon maintenance.

### 3.3 Docker Access

- add `deploy` to the `docker` group
- verify `docker info`
- verify `docker compose version`

### 3.4 GHCR Login

Log the host into GHCR with a read-only credential:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
```

Store the credential where automation can re-use it safely.

---

## 3A. Phase 2A — Tailscale Installation

### 3A.1 Install Tailscale

Install Tailscale from the official Debian repository:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### 3A.2 Authenticate

Use the auth key from 1Password:

```bash
tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname=dailywerk-ops
```

### 3A.3 Verify

```bash
tailscale status
tailscale ip -4
```

The server should appear in the tailnet with hostname `dailywerk-ops`.

### 3A.4 Firewall Integration

After Tailscale is running, the `tailscale0` interface is available. The ufw rules from Phase 1 should allow all traffic on this interface:

```bash
ufw allow in on tailscale0
```

This makes SSH and Grafana (port 3000) reachable to tailnet members without opening them to the public internet.

---

## 3B. Phase 2B — 1Password CLI

### 3B.1 Install the `op` CLI

Install the 1Password CLI from the official repository:

```bash
# Add 1Password apt repo and install op
```

### 3B.2 Configure the Service Account

The `OP_SERVICE_ACCOUNT_TOKEN` must be placed in a secure location readable by the deploy user:

```bash
# Store in /srv/dailywerk/config/env/op-token.env
# Permissions: 600, owned by deploy:deploy
```

### 3B.3 Verify

```bash
op read "op://DailyWerk Shared/deploy/webhook-secret"
```

This must succeed before proceeding. All subsequent phases that need secrets should use `op read` or `op inject`.

---

## 4. Phase 3 — Host Directory Layout

Create a predictable layout:

```text
/srv/dailywerk/
  compose/
    infra/
    observability/
    edge/
    prod-blue/
    prod-green/
    staging-blue/
    staging-green/
  config/
    nginx/
    grafana/
    prometheus/
    promtail/
    loki/
    env/
  data/
    prod/
    staging/
  backups/
  runtime/
```

Important runtime markers:

- `/srv/dailywerk/runtime/prod-active-slot`
- `/srv/dailywerk/runtime/staging-active-slot`

These track which slot Nginx should route to.

---

## 5. Phase 4 — Compose Project Bootstrapping

### 5.1 Infra Compose

Bootstrap `dailywerk-infra` first.

Contents:

- PostgreSQL 17 + pgvector image
- Valkey
- persistent volumes
- no public ports bound to the host

Key rules:

- PostgreSQL data is on a named volume
- Valkey data is on a named volume
- only internal Docker networks can reach them

### 5.2 Observability Compose

Bootstrap `dailywerk-observability`.

Contents:

- Prometheus
- Grafana
- Loki
- Promtail
- node_exporter
- cAdvisor
- postgres_exporter
- valkey_exporter

Provision:

- Prometheus scrape targets
- Grafana datasources
- starter dashboards
- alerting contact points

### 5.3 Edge Compose

Bootstrap `dailywerk-edge`.

Contents:

- Nginx
- deploy-listener service

Responsibilities:

- terminate Cloudflare origin TLS
- proxy to the active blue/green slot
- receive signed deploy notifications

Grafana is **not** proxied through Nginx. It binds to the Tailscale interface only (see Phase 2A).

### 5.4 App Slot Compose Definitions

Prepare four slot definitions:

- `dailywerk-prod-blue`
- `dailywerk-prod-green`
- `dailywerk-staging-blue`
- `dailywerk-staging-green`

Each slot contains:

- `frontend`
- `api`
- `worker`

Each slot points to shared `dailywerk-infra` services and its own env file.

---

## 6. Phase 5 — Nginx and Slot Switching

### 6.1 Nginx Role

Nginx proxies:

- `app.dailywerk.com` to the active production slot
- `staging.dailywerk.com` to the active staging slot

Grafana is not served by Nginx — it is accessed directly via Tailscale on port 3000.

It must route:

- `/` to frontend
- `/api/` to API
- `/cable` to API with websocket headers

### 6.2 Slot Switch Mechanism

Automation should maintain small generated files or env fragments that define the active upstream targets.

Suggested flow:

1. write the inactive slot as the new target
2. validate Nginx config
3. reload Nginx
4. verify health externally
5. update the `*-active-slot` marker file

Switching should be idempotent and reversible.

---

## 7. Phase 6 — Zero-Downtime Deploy Automation

### 7.1 Deploy Listener

The deploy-listener receives a signed webhook when new GHCR images are published for `master` or `develop`.

Expected payload:

- environment
- frontend image tag or digest
- API image tag or digest
- build SHA

### 7.2 Deploy Procedure

For the targeted environment:

1. read the current active slot
2. choose the inactive slot
3. resolve secrets from 1Password for the target environment
4. pull the new images into the inactive slot
5. run database migrations once using the new API image
6. start the inactive slot
7. wait for `/ready` on the new slot
8. reload Nginx to point to the new slot
9. verify public health
10. push a deploy annotation to Grafana (timestamp, environment, slot, commit SHA, result)
11. stop the previous slot after a grace period

### 7.3 Rollback Procedure

Automation must expose a fast rollback path:

1. identify the previous slot
2. reload Nginx back to that slot
3. optionally restart the old slot if it was already stopped

Rollback should not require rebuilding images or pulling git.

---

## 8. Phase 7 — Database and Valkey Initialization

### 8.1 PostgreSQL

On first bootstrap:

- create `dailywerk_production`
- create `dailywerk_staging`
- create the non-superuser application role
- enable required extensions such as `pgcrypto` and `vector`

### 8.2 Valkey

Configure Valkey for local container-network access only.

Environment separation can use:

- logical DBs (`0` for production, `1` for staging)
- explicit namespaces in cache/cable config

No public port binding is required.

---

## 9. Phase 8 — Observability Automation

### 9.1 Prometheus

Prometheus must scrape at least:

- node_exporter
- cAdvisor
- postgres_exporter
- valkey_exporter
- Nginx metrics if exposed
- Rails `/metrics`

### 9.2 Grafana

Grafana must be provisioned automatically with:

- Prometheus datasource
- Loki datasource
- admin user from 1Password (`op read "op://DailyWerk Production/grafana/admin-password"`)
- starter dashboards for host, Docker, DB, app, and worker
- deploy annotation query on all dashboards (filtering on `deploy` tag)

Grafana must bind **only to the Tailscale interface** (e.g., `GF_SERVER_HTTP_ADDR=<tailscale-ip>`) so it is not reachable from the public internet. Operators access it at `http://dailywerk-ops:3000` via Tailscale MagicDNS.

### 9.3 Loki / Promtail

Promtail should collect:

- container logs from Docker
- Nginx access/error logs
- optionally host system logs that matter operationally

The required user-facing result is simple:

- operators can open Grafana in a browser
- select Explore
- query logs without SSH-ing into the host

### 9.4 Alerts

Grafana/Prometheus alerts should be provisioned for:

- app readiness failure
- repeated 5xx responses
- PostgreSQL unavailable
- Valkey unavailable
- disk > 85%
- backup failures
- no recent log ingestion from production

---

## 10. Phase 9 — Backup Automation

### 10.1 Backup Model

Backups must be **compressed and encrypted** before or while leaving the host.

Recommended implementation:

- `pg_dump -Fc` for database dumps
- restic repository in Hetzner Object Storage for encrypted off-host retention
- restic compression enabled
- local spool directory for recent hot restores

### 10.2 What to Back Up

- PostgreSQL dumps
- workspace/vault directories
- compose files
- env files and runtime config
- Grafana/Loki/Prometheus persistent data as needed

### 10.3 Scheduling

Use host-level timers that run container-aware backup commands. The host scheduler is acceptable even though the workloads are containerized.

Suggested jobs:

- DB backup every 6 hours
- workspace/config backup daily
- weekly verification restore into a temporary target

### 10.4 Restore Verification

Automation should include a scripted restore check that proves:

- the encrypted repository is readable
- a DB dump can be restored
- a sample file restore works

Backups are not considered valid until restore verification succeeds at least periodically.

---

## 11. Phase 10 — Systemd Wrappers

Application processes should not be native systemd services, but systemd is still useful for host boot orchestration.

Create systemd units for:

- `dailywerk-infra.service`
- `dailywerk-observability.service`
- `dailywerk-edge.service`

Each unit should call the checked-in compose file, for example:

```bash
docker compose -f /srv/dailywerk/compose/infra/docker-compose.yml up -d
```

Use systemd timers for:

- backups
- restore verification
- optional Cloudflare IP refresh if firewall rules are generated from their published ranges

---

## 12. Phase 11 — Claude Code Installation

Install Claude Code for the deploy user after the host is stable.

Claude Code responsibilities:

- inspect logs and dashboards during incidents
- assist with deploys and rollback verification
- help operate restore drills
- update compose/config artifacts under review

Claude Code should not be a permanent container inside the serving stack.

---

## 13. Verification Checklist

After automation completes, verify:

```bash
docker ps
docker compose ls
curl -sf https://app.dailywerk.com/up
curl -sf https://staging.dailywerk.com/up
curl -sf http://dailywerk-ops:3000/login    # via Tailscale
tailscale status
op read "op://DailyWerk Shared/deploy/webhook-secret"  # 1Password connectivity
```

And confirm all of the following:

1. production and staging are healthy
2. Grafana dashboards load via Tailscale (`http://dailywerk-ops:3000`)
3. Loki logs are queryable in Grafana Explore
4. Prometheus targets are healthy
5. a blue/green deploy flips without outage
6. deploy annotation appears in Grafana after the flip
7. a rollback flips back without outage
8. backups complete and restore verification passes
9. SSH is reachable only via Tailscale, not the public IP
10. 1Password `op read` resolves secrets correctly

---

## 14. What This RFC Replaces

This automation RFC replaces the older assumptions of:

- host-native Ruby installation for production workloads
- host-native Node build steps for deploys
- native `valkey-server`
- native Falcon and GoodJob systemd services
- journald/file-only operational visibility
