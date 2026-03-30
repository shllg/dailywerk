---
type: prd
title: Deployment — Single Hetzner Server
domain: infrastructure
created: 2026-03-30
updated: 2026-03-30
status: draft
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/04-billing-and-operations
implemented_by:
  - rfc/2026-03-30-deployment-codebase-changes
  - rfc/2026-03-30-deployment-manual-setup
  - rfc/2026-03-30-deployment-server-automation
---

# DailyWerk — Deployment on Single Hetzner Server

> Production and staging environments on one Hetzner Cloud VPS.
> This version assumes Debian + Docker Compose + GHCR + blue/green deploys.
> For stack decisions, see [01-platform-and-infrastructure.md](./01-platform-and-infrastructure.md).

---

## 1. Goals & Constraints

| Goal | Detail |
|------|--------|
| **Single host** | One Hetzner Cloud VPS, no Kubernetes, no multi-node orchestration |
| **Docker-first** | Application and service runtime should rely on Docker images and Docker Compose |
| **Two environments** | Production and staging on one host with strict isolation |
| **Zero-downtime deploys** | App deploys must switch traffic without a visible outage |
| **GHCR-driven delivery** | `master` publishes production images, `develop` publishes staging images |
| **Local observability** | Metrics, dashboards, and logs stay on the host, reachable via web UI |
| **Recoverable** | Backups must be compressed, encrypted, restorable, and tested |
| **Affordable** | Target server cost stays in the ~20–30 EUR/month range |
| **Claude Code on server** | Claude Code is available for operational automation, but not part of the serving path |

### Explicit Non-Goals

- Kubernetes, Nomad, or Swarm
- Multi-host HA for databases or application slots
- Managed SaaS observability
- Bare-metal or native-process deployment of Rails, GoodJob, PostgreSQL, or Valkey

---

## 2. Server Baseline

### Recommended Host

| Spec | CPX31 | CPX41 |
|------|-------|-------|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16 GB |
| Disk | 160 GB NVMe | 240 GB NVMe |
| Traffic | 20 TB | 20 TB |
| Price | ~14 EUR/mo | ~27 EUR/mo |

**Recommendation**: start with **CPX41**. Blue/green slots, pgvector, Valkey, Prometheus, Grafana, Loki, and image layers all compete for RAM and disk cache. CPX31 is possible for early validation, but CPX41 is the safer default.

### Operating System

- **Debian stable** on Hetzner Cloud
- As of **March 30, 2026**, Debian stable is **Debian 13 "trixie"**
- If Hetzner image availability lags in a region, Debian 12 is an acceptable temporary fallback, but the target baseline for this plan is Debian 13

### Host Packages

The host should stay intentionally small:

- Docker Engine
- Docker Compose plugin
- `ufw`, `fail2ban`, `unattended-upgrades`
- minimal shell/debug tooling
- no host-level Ruby, Node, PostgreSQL, or Valkey for production workloads

### Storage Planning

| Data | Estimate | Backing |
|------|----------|---------|
| PostgreSQL data volume | 10–40 GB | Docker named volume |
| Valkey data volume | <1 GB | Docker named volume |
| Workspace and vault data | 10–50 GB | bind mount under `/srv/dailywerk/data/` |
| GHCR image layers | 10–25 GB | Docker image cache |
| Prometheus, Loki, Grafana | 10–25 GB | Docker named volumes |
| Local backup spool | 10–20 GB | `/srv/dailywerk/backups/` |
| Total practical use | ~50–160 GB | fits comfortably on 240 GB NVMe |

---

## 3. Runtime Architecture

The server runs several Docker Compose projects with clear ownership boundaries.

### 3.1 Compose Projects

| Project | Purpose | Core Services |
|---------|---------|---------------|
| `dailywerk-infra` | stateful data services | PostgreSQL 17 + pgvector, Valkey |
| `dailywerk-observability` | metrics, dashboards, logs | Prometheus, Grafana, Loki, Promtail, exporters |
| `dailywerk-edge` | ingress and deployment control | Nginx, deploy-listener |
| `dailywerk-prod-blue` / `dailywerk-prod-green` | active/inactive production slots | frontend, api, worker |
| `dailywerk-staging-blue` / `dailywerk-staging-green` | active/inactive staging slots | frontend, api, worker |

### 3.2 Core Design Rules

- **PostgreSQL and Valkey live in their own compose project** and are not rebuilt on normal app deploys
- **Application slots are immutable** and are created from GHCR images
- **Nginx switches between blue and green slots** after health checks pass
- **Prometheus, Grafana, and Loki are mandatory**, not optional
- **Grafana Explore is the primary log viewer**; no separate proprietary log product is needed

### 3.3 Logical Diagram

```text
Cloudflare
  -> Nginx (edge compose)
     -> active production slot (blue or green)
        -> frontend container
        -> api container
        -> worker container
     -> active staging slot (blue or green)
        -> frontend container
        -> api container
        -> worker container

Shared state (separate infra compose)
  -> PostgreSQL 17 + pgvector
  -> Valkey

Observability (separate observability compose)
  -> Prometheus
  -> Grafana
  -> Loki
  -> Promtail
  -> node_exporter / cAdvisor / postgres_exporter / valkey_exporter
```

---

## 4. Environment Isolation

| Resource | Production | Staging |
|----------|-----------|---------|
| Domain | `app.dailywerk.com` | `staging.dailywerk.com` |
| DB | `dailywerk_production` | `dailywerk_staging` |
| Valkey logical DB | `0` | `1` |
| Compose slot pairs | `prod-blue`, `prod-green` | `staging-blue`, `staging-green` |
| Workspace root | `/srv/dailywerk/data/prod/` | `/srv/dailywerk/data/staging/` |
| Image tag channel | `prod-*` | `staging-*` |
| Active slot marker | `/srv/dailywerk/runtime/prod-active-slot` | `/srv/dailywerk/runtime/staging-active-slot` |

### Isolation Expectations

- production and staging share the host but not the same DB
- production and staging do not share workspace directories
- one slot is active while the other is available for rollout or rollback
- observability and infra are shared but labeled by environment

---

## 5. Routing and TLS

```text
User
  -> Cloudflare edge
  -> Cloudflare Origin Pull
  -> Nginx container on the Hetzner host
  -> active frontend/api slot
```

### TLS Strategy

1. Cloudflare serves the public certificate to end users
2. Nginx presents a Cloudflare origin certificate to Cloudflare
3. Cloudflare SSL mode is **Full (Strict)**
4. Cloudflare Authenticated Origin Pulls are enabled
5. Nginx proxies internally to the active blue/green slot over the Docker network

### DNS Records

| Type | Name | Target | Notes |
|------|------|--------|-------|
| A | `app` | Hetzner server IP | proxied |
| A | `staging` | Hetzner server IP | proxied |
| A | `ops` | Hetzner server IP | proxied, admin-only |

`ops.dailywerk.com` is used for Grafana so logs and dashboards are available in a browser behind admin auth.

---

## 6. Deployment Strategy

### 6.1 Image Flow

| Branch | Result | Target |
|--------|--------|--------|
| `master` | build and publish immutable production images to GHCR | production |
| `develop` | build and publish immutable staging images to GHCR | staging |

Recommended images:

- `ghcr.io/shllg/dailywerk-api`
- `ghcr.io/shllg/dailywerk-frontend`
- `ghcr.io/shllg/dailywerk-postgres-pgvector`
- optional helper images such as `deploy-listener` or backup runner

Recommended tags:

- immutable tags: commit SHA, e.g. `prod-<sha>` and `staging-<sha>`
- moving channel tags: `prod-current`, `staging-current`

### 6.2 Trigger Model

The deployment path is event-driven:

1. GitHub Actions builds and publishes the image to GHCR
2. A **package-publish event** from GHCR triggers a deploy notification
3. The server-side deploy-listener receives the signed webhook
4. The deploy-listener updates the inactive slot with Docker Compose
5. Nginx flips traffic only after readiness checks pass

This avoids git polling on the server and keeps the server focused on pulling images, not building code.

### 6.3 Zero-Downtime Rollout

For each environment:

1. read the active slot (`blue` or `green`)
2. select the inactive slot
3. `docker compose pull` the new frontend/api images for the inactive slot
4. run one-off migrations using the new API image against the shared DB
5. start the new inactive slot containers
6. wait for readiness on the new slot
7. rewrite or reload the Nginx upstream target
8. switch traffic to the new slot
9. keep the previous slot warm briefly, then stop it

### 6.4 Rollback

Rollback must be immediate:

- switch Nginx back to the previous slot
- keep the prior slot definition and image tag available
- if a migration is backward-incompatible, the migration plan must include an explicit rollback or expand/contract sequence

### 6.5 Downtime Policy

- **Production**: zero-downtime is required
- **Staging**: use the same slot-based process for parity
- host-level Docker daemon restarts should use Docker `live-restore` to reduce accidental container interruption during daemon maintenance

---

## 7. Security and Hardening

### Host

- Debian automatic security updates enabled
- SSH key only
- root login disabled
- SSH on a non-default port
- `ufw` allows:
  - 443/tcp from Cloudflare IP ranges
  - SSH from admin IPs only
- `fail2ban` protects SSH

### Docker

- containers run as non-root where practical
- root filesystem read-only where practical
- only Nginx and Grafana are exposed externally
- PostgreSQL and Valkey are available only on the internal Docker network
- GHCR credentials are read-only and stored outside the repo

### Application

- production/staging secrets are separate
- webhook signatures are verified
- container images are immutable and referenced by exact tag or digest for deploys
- health and readiness endpoints are distinct so Nginx never switches early

---

## 8. Backups and Recovery

### 8.1 Backup Requirements

Backups must be:

- encrypted at rest
- compressed
- copied off-host to Hetzner Object Storage
- restorable without rebuilding the entire server manually

### 8.2 Backup Design

| Data | Method | Frequency | Retention |
|------|--------|-----------|----------|
| PostgreSQL | `pg_dump -Fc` into restic repository | every 6 hours | 7 days hot, 30 days object storage |
| Workspace and vault data | restic backup with compression enabled | daily | 30 days object storage |
| Nginx, Grafana, compose config, env files | restic backup with compression enabled | daily | 30 days object storage |
| Docker volumes for Grafana/Loki/Prometheus | restic backup | daily | 14–30 days |
| Full server image | Hetzner snapshot | weekly | 4 snapshots |

### 8.3 Why Restic

- encrypted repositories are a first-class feature
- compression is available for repository format v2
- a single tool can cover object storage backups for configs, workspaces, and database dumps

### 8.4 Restore Modes

| Scenario | Recovery Path |
|----------|---------------|
| app image failure | switch traffic back to previous slot |
| bad deploy after switch | redeploy prior immutable image tag to inactive slot and flip back |
| DB corruption | restore latest verified dump into a fresh DB or replace the DB volume |
| full host loss | provision new Hetzner host, restore compose configs and secrets, restore DB/workspaces from restic, redeploy latest images |

### 8.5 Recovery Targets

- **RTO**: under 15 minutes for app rollback, under 2 hours for host rebuild
- **RPO**: up to 6 hours for DB, up to 24 hours for workspace files unless higher frequency is later required

---

## 9. Logging, Monitoring, and Metrics

### 9.1 Mandatory Stack

| Need | Tool |
|------|------|
| metrics storage and alert evaluation | Prometheus |
| dashboards and web UI | Grafana |
| log storage | Loki |
| log shipping | Promtail |
| host metrics | node_exporter |
| container metrics | cAdvisor |
| PostgreSQL metrics | postgres_exporter |
| Valkey metrics | valkey_exporter |

### 9.2 Log Viewer Requirement

The OSS web log viewer requirement is satisfied by:

- Grafana Explore for the UI
- Loki for indexed log queries
- Promtail for collecting container, Nginx, and host logs

This keeps metrics and logs in the same admin interface instead of splitting the operational surface across multiple tools.

### 9.3 Access Model

- Grafana is published at `https://ops.dailywerk.com`
- access is restricted with admin auth and optionally Cloudflare Access or IP allowlisting
- Grafana has separate dashboards for:
  - production app
  - staging app
  - PostgreSQL
  - Valkey
  - Nginx
  - Docker host

### 9.4 Alerting

Grafana alerting should send notifications to at least one of:

- email
- Telegram
- webhook receiver for future automation

At minimum, alerts are required for:

- app readiness failure
- high 5xx rate
- low disk space
- PostgreSQL unavailable
- Valkey unavailable
- backup failure
- Loki or Prometheus down

---

## 10. Resource Model

### Recommended Budget on CPX41

| Service Group | Approx Memory Budget |
|---------------|----------------------|
| PostgreSQL + pgvector | 4–6 GB |
| Valkey | 256–512 MB |
| active app slot | 2–4 GB |
| inactive slot during rollout | 2–4 GB |
| Prometheus + Grafana + Loki | 2–3 GB |
| Nginx + exporters + deploy-listener | <1 GB |

This still leaves operating margin for Docker cache, filesystem cache, and burst usage during deploys.

---

## 11. Claude Code on the Server

Claude Code is an operator tool, not a runtime dependency.

Use cases:

- inspect logs and dashboards during incidents
- assist with restores and rollback drills
- update compose definitions and hardening scripts
- validate backup restores in staging

Rules:

- Claude Code runs under the deploy user
- it should not be part of the request path
- it should not hold long-lived production secrets beyond what the deploy user already needs

---

## 12. Final Decision Summary

This PRD now assumes:

1. **Debian stable**, not Ubuntu
2. **Docker Compose**, not native app processes
3. **PostgreSQL + pgvector and Valkey in a dedicated infra compose**
4. **GHCR image publishing and package-publish-triggered deploy notifications**
5. **blue/green zero-downtime deploys**
6. **compressed and encrypted backups**
7. **Grafana + Prometheus + Loki as required local observability**

That is the baseline the RFCs must implement.
