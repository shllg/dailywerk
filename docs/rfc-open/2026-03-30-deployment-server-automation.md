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
- GHCR read credentials exist
- backup encryption material exists
- required app secrets are available

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

- HTTPS from Cloudflare IP ranges
- SSH from known admin IPs only

Everything else should remain denied.

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
- expose `ops.dailywerk.com` to Grafana
- receive signed deploy notifications

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
- `ops.dailywerk.com` to Grafana

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
3. pull the new images into the inactive slot
4. run database migrations once using the new API image
5. start the inactive slot
6. wait for `/ready` on the new slot
7. reload Nginx to point to the new slot
8. verify public health
9. stop the previous slot after a grace period

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
- admin user from secret/env
- starter dashboards for host, Docker, DB, app, and worker

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
curl -sf https://ops.dailywerk.com/login
```

And confirm all of the following:

1. production and staging are healthy
2. Grafana dashboards load
3. Loki logs are queryable in Grafana Explore
4. Prometheus targets are healthy
5. a blue/green deploy flips without outage
6. a rollback flips back without outage
7. backups complete and restore verification passes

---

## 14. What This RFC Replaces

This automation RFC replaces the older assumptions of:

- host-native Ruby installation for production workloads
- host-native Node build steps for deploys
- native `redis-server`
- native Falcon and GoodJob systemd services
- journald/file-only operational visibility
