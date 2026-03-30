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
> For stack decisions: see [01-platform-and-infrastructure.md](./01-platform-and-infrastructure.md).
> For background job config: see [04-billing-and-operations.md §8](./04-billing-and-operations.md#8-goodjob-configuration).

---

## 1. Goals & Constraints

| Goal | Detail |
|------|--------|
| **Simple** | One server, no Kubernetes, no multi-node orchestration |
| **Affordable** | €20–30/month for the VPS |
| **Two environments** | Production and staging on the same host, isolated |
| **GitHub-driven deploys** | Push to `master` → production, push to `develop` → staging |
| **Local observability** | All logs, metrics, monitoring on the server itself — no external SaaS |
| **Recoverable** | Automated backups with tested restore procedures |
| **Claude Code on server** | Claude Code installed for server-side automation tasks |

### What This PRD Does NOT Cover

- Kubernetes, container orchestration, or multi-server setups
- CDN configuration beyond Cloudflare proxy
- CI/CD pipelines (GitHub Actions definition) — the RFCs describe the deploy trigger, not the full pipeline
- Signal bridge deployment (separate VPS per [PRD 01 §6](./01-platform-and-infrastructure.md#6-deployment-architecture-mvp))

---

## 2. Server Specification

### Recommended: Hetzner Cloud CPX31 or CPX41

| Spec | CPX31 | CPX41 |
|------|-------|-------|
| vCPU | 4 (AMD) | 8 (AMD) |
| RAM | 8 GB | 16 GB |
| Disk | 160 GB NVMe | 240 GB NVMe |
| Traffic | 20 TB | 20 TB |
| Price | ~€14/mo | ~€27/mo |

**Recommendation**: Start with **CPX41** (8 vCPU, 16 GB RAM, 240 GB NVMe). Running PostgreSQL + pgvector, Redis, Falcon, GoodJob workers, Nginx, and Node.js (Obsidian Headless) concurrently needs headroom. 16 GB RAM gives comfortable room for pgvector indexes and LLM response buffering. Upgrade or downgrade is a single Hetzner API call.

**Location**: Falkenstein (FSN1) or Nuremberg (NBG1) — EU, low latency to Cloudflare EU edge.

**OS**: Ubuntu 24.04 LTS (Hetzner image, minimal).

### Storage Planning

| Data | Est. Size (10 users, 6 months) | Location |
|------|-------------------------------|----------|
| PostgreSQL (with pgvector) | 5–15 GB | `/var/lib/postgresql/` |
| Redis (ephemeral) | <100 MB | In-memory |
| Application code (2 envs) | <1 GB | `/opt/dailywerk/` |
| Vault checkouts (warm) | 10–50 GB | `/data/workspaces/` |
| Backups (local, rolling 7d) | 10–30 GB | `/var/backups/dailywerk/` |
| Logs | 1–5 GB (with rotation) | `/var/log/dailywerk/` |
| **Total** | **~30–100 GB** | 240 GB plenty |

---

## 3. Process Layout

All processes run natively (no Docker in production). Docker adds memory overhead and operational complexity for a single-server setup with no scaling needs.

```
┌─────────────────────────────────────────────────────────────────┐
│  Hetzner Cloud VPS (Ubuntu 24.04)                               │
│                                                                 │
│  Nginx (TLS termination, reverse proxy, static files)           │
│    ├── app.dailywerk.com    → Falcon :3000 (production)         │
│    ├── staging.dailywerk.com → Falcon :3100 (staging)           │
│    └── static SPA assets    → /opt/dailywerk/prod/frontend/dist │
│                                                                 │
│  Production Environment (:3000)                                 │
│    ├── Falcon (Rails API + ActionCable WebSocket)               │
│    ├── GoodJob Worker (external mode, separate process)         │
│    └── Node.js 22 (Obsidian Headless, future)                   │
│                                                                 │
│  Staging Environment (:3100)                                    │
│    ├── Falcon (Rails API + ActionCable WebSocket)               │
│    ├── GoodJob Worker (external mode, separate process)         │
│    └── (shares PostgreSQL + Redis, separate databases)          │
│                                                                 │
│  Shared Services                                                │
│    ├── PostgreSQL 17 (+pgvector) — two databases                │
│    ├── Redis 7 — key namespacing per environment                │
│    └── systemd managing all processes                           │
│                                                                 │
│  Tooling                                                        │
│    ├── Claude Code (for server automation)                      │
│    └── GitHub deploy key (read-only)                            │
└─────────────────────────────────────────────────────────────────┘
```

### Process Manager: systemd

Each process gets its own systemd unit file. This gives:
- Automatic restart on crash (`Restart=on-failure`)
- Log integration with journald
- Resource limits via cgroups (`MemoryMax`, `CPUQuota`)
- Dependency ordering (`After=postgresql.service redis.service`)
- Clean shutdown signals

### Environment Isolation

| Resource | Production | Staging |
|----------|-----------|--------|
| PostgreSQL DB | `dailywerk_production` | `dailywerk_staging` |
| Redis prefix | `prod:` | `staging:` |
| Falcon port | 3000 | 3100 |
| ActionCable port | via Falcon | via Falcon |
| App directory | `/opt/dailywerk/prod/` | `/opt/dailywerk/staging/` |
| Vault data | `/data/workspaces/prod/` | `/data/workspaces/staging/` |
| .env file | `/opt/dailywerk/prod/.env` | `/opt/dailywerk/staging/.env` |
| systemd prefix | `dailywerk-prod-*` | `dailywerk-staging-*` |

---

## 4. Routing — Cloudflare to Server

```
User → Cloudflare Edge (SSL termination, DDoS, WAF)
     → Cloudflare Origin Pull (HTTPS, origin certificate)
     → Nginx (443, origin cert + key)
     → Falcon (localhost:3000 or :3100)
```

### TLS Strategy

1. **Cloudflare → User**: Cloudflare manages the public TLS certificate automatically.
2. **Cloudflare → Origin (Nginx)**: Cloudflare Origin Certificate (15-year, free). Nginx presents this cert. Cloudflare SSL mode: **Full (Strict)**.
3. **Nginx → Falcon**: Plain HTTP over localhost. No TLS needed for loopback traffic.

### Cloudflare Configuration

| Setting | Value | Reason |
|---------|-------|--------|
| SSL/TLS mode | Full (Strict) | Origin cert validation |
| Always Use HTTPS | On | Force HTTPS |
| Minimum TLS | 1.2 | Security baseline |
| HTTP/2 | On | Performance |
| WebSockets | On | ActionCable |
| Authenticated Origin Pulls | On | Verify Cloudflare → origin |
| Browser Cache TTL | Respect Existing Headers | Let Nginx control caching |

### DNS Records

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| A | app | `<server-ip>` | Proxied (orange cloud) |
| A | staging | `<server-ip>` | Proxied (orange cloud) |

### Nginx Configuration Sketch

```nginx
# /etc/nginx/sites-available/dailywerk-prod
upstream falcon_prod {
    server 127.0.0.1:3000;
}

server {
    listen 443 ssl http2;
    server_name app.dailywerk.com;

    ssl_certificate     /etc/ssl/cloudflare/origin.pem;
    ssl_certificate_key /etc/ssl/cloudflare/origin-key.pem;

    # Verify requests come from Cloudflare
    ssl_client_certificate /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem;
    ssl_verify_client on;

    # SPA static files
    root /opt/dailywerk/prod/frontend/dist;

    # API and WebSocket
    location /api/ {
        proxy_pass http://falcon_prod;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /cable {
        proxy_pass http://falcon_prod;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;  # Keep WebSocket alive
    }

    # Health check (bypass Cloudflare auth for uptime monitoring)
    location = /up {
        proxy_pass http://falcon_prod;
    }

    # GoodJob dashboard (admin only, restrict by IP or auth)
    location /good_job {
        proxy_pass http://falcon_prod;
        # TODO: restrict access via HTTP basic auth or IP allowlist
    }

    # SPA fallback — serve index.html for client-side routing
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Security headers (Cloudflare adds some, but belt-and-suspenders)
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
}
```

---

## 5. Deployment Strategy

### Branch Model

| Branch | Environment | Trigger |
|--------|-------------|--------|
| `master` | Production | Push/merge to master |
| `develop` | Staging | Push/merge to develop |

### Deploy Flow

```
Developer pushes to master
  → GitHub webhook fires
  → Server-side deploy script runs (systemd timer or webhook listener)
  → git pull --ff-only
  → bundle install --deployment
  → RAILS_ENV=production bin/rails db:migrate
  → RAILS_ENV=production bin/rails assets:precompile (if needed)
  → cd frontend && pnpm install --frozen-lockfile && pnpm build
  → systemctl restart dailywerk-prod-falcon
  → systemctl restart dailywerk-prod-worker
  → Health check: curl -f https://app.dailywerk.com/up
```

### Deploy Mechanism Options

**Option A: Webhook listener (recommended for simplicity)**
A lightweight webhook receiver (e.g., `webhook` package or a small Ruby script) listens on a localhost port. GitHub sends a push webhook. The receiver verifies the signature, checks the branch, and runs the deploy script.

**Option B: GitHub Actions + SSH**
GitHub Actions SSH into the server and run the deploy script. Requires a deploy SSH key stored in GitHub Secrets.

**Option C: Polling (simplest, least responsive)**
A cron job or systemd timer runs `git fetch && git diff --quiet origin/master` every minute. If changes detected, run deploy script. No webhook infrastructure needed.

### Zero-Downtime Considerations

For MVP with <10 users, a brief restart (~2–5 seconds) is acceptable. Falcon restarts quickly. If zero-downtime becomes important:
- Use systemd `ExecReload` with Falcon's graceful reload
- Or run two Falcon instances behind Nginx and swap upstream

### Rollback

```bash
# Immediate rollback: revert to previous commit
cd /opt/dailywerk/prod
git checkout HEAD~1
bundle install --deployment
RAILS_ENV=production bin/rails db:rollback STEP=1  # if migration was run
systemctl restart dailywerk-prod-falcon dailywerk-prod-worker
```

Keep the last 3 releases as git tags for quick reference.

---

## 6. Security & Server Hardening

### SSH

- **Disable password auth** — key-only (`PasswordAuthentication no`)
- **Disable root login** — use a deploy user with sudo (`PermitRootLogin no`)
- **Change SSH port** — non-standard port (e.g., 2222) reduces noise
- **SSH key**: Ed25519 keys only

### Firewall (ufw)

```
Allow: 443/tcp (HTTPS — Cloudflare IPs only)
Allow: 2222/tcp (SSH — your IP only)
Deny: everything else
```

Port 80 not needed — Cloudflare handles HTTP→HTTPS redirect. PostgreSQL (5432), Redis (6379), Falcon (3000/3100) are localhost-only, not exposed.

### Cloudflare IP Restriction

Nginx should only accept connections from Cloudflare IP ranges. This prevents direct-to-IP access bypassing Cloudflare's WAF/DDoS protection.

```nginx
# /etc/nginx/conf.d/cloudflare-ips.conf
# Updated periodically from https://www.cloudflare.com/ips/
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
# ... (all Cloudflare ranges)
real_ip_header CF-Connecting-IP;
```

### System Hardening

- **Automatic security updates**: `unattended-upgrades` for Ubuntu security patches
- **fail2ban**: Protect SSH against brute force
- **No unnecessary services**: Disable anything not needed (e.g., `snapd`, `multipathd`)
- **PostgreSQL**: Listen on localhost only (`listen_addresses = 'localhost'`)
- **Redis**: Bind to localhost, no password needed (localhost-only access)
- **File permissions**: Deploy user owns `/opt/dailywerk/`, PostgreSQL user owns data dir
- **Secrets**: Rails credentials encrypted, `.env` files with `600` permissions

### Application Security

Covered by existing rules ([04-security.md](./../.claude/rules/04-security.md)):
- Strong parameters, encryption, injection prevention
- WorkOS auth, RLS isolation
- Brakeman + bundler-audit in deploy pipeline

---

## 7. Backup & Recovery

### What Gets Backed Up

| Data | Method | Frequency | Retention |
|------|--------|-----------|----------|
| PostgreSQL (both DBs) | `pg_dump` → compressed file | Every 6 hours | 7 days local, 30 days S3 |
| Vault data (`/data/workspaces/`) | rsync to backup dir | Daily | 7 days local, 30 days S3 |
| Rails credentials + .env | Encrypted copy to S3 | On change | Latest 3 versions |
| Nginx config | Part of system backup | Weekly | 4 weeks |
| Full system | Hetzner snapshot | Weekly | 4 snapshots |

### Backup Script

```bash
#!/bin/bash
# /opt/dailywerk/scripts/backup.sh
# Run via systemd timer every 6 hours

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/dailywerk"
S3_BUCKET="dailywerk-backups"

# PostgreSQL dumps
for db in dailywerk_production dailywerk_staging; do
  pg_dump -Fc "$db" > "$BACKUP_DIR/pg_${db}_${TIMESTAMP}.dump"
done

# Upload to Hetzner Object Storage
for f in "$BACKUP_DIR"/pg_*_${TIMESTAMP}.dump; do
  aws s3 cp "$f" "s3://$S3_BUCKET/postgres/$(basename $f)" \
    --endpoint-url https://fsn1.your-objectstorage.com
done

# Clean local backups older than 7 days
find "$BACKUP_DIR" -name "pg_*.dump" -mtime +7 -delete

# Clean S3 backups older than 30 days
aws s3 ls "s3://$S3_BUCKET/postgres/" --endpoint-url https://fsn1.your-objectstorage.com \
  | awk '{print $4}' | while read f; do
    # ... age check and delete
  done
```

### Recovery Procedures

#### Database Restore

```bash
# Stop application
systemctl stop dailywerk-prod-falcon dailywerk-prod-worker

# Restore from dump
pg_restore -d dailywerk_production -c /var/backups/dailywerk/pg_dailywerk_production_TIMESTAMP.dump

# Restart
systemctl start dailywerk-prod-falcon dailywerk-prod-worker
```

#### Full Server Recovery (Disaster)

1. Create new Hetzner Cloud server (same spec)
2. Restore from Hetzner snapshot (if recent enough) — done
3. Or: fresh Ubuntu install → run Claude Code automation scripts → restore DB from S3 backup → deploy latest code from GitHub

**RTO target**: <1 hour from snapshot, <2 hours from scratch.

---

## 8. Logging, Monitoring & Metrics

All local. No external SaaS dependencies.

### Logging

| Source | Destination | Format |
|--------|-------------|--------|
| Falcon (Rails) | journald + `/var/log/dailywerk/prod/rails.log` | Tagged JSON (request_id) |
| GoodJob Worker | journald + `/var/log/dailywerk/prod/worker.log` | Rails logger |
| Nginx | `/var/log/nginx/dailywerk-*.log` | Combined + JSON access log |
| PostgreSQL | `/var/log/postgresql/` | Default pg_log |
| System | journald | Default |

### Log Rotation

```
# /etc/logrotate.d/dailywerk
/var/log/dailywerk/*/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

/var/log/nginx/dailywerk-*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid)
    endscript
}
```

### Monitoring (Local)

**Health checks via systemd + simple script:**

```bash
#!/bin/bash
# /opt/dailywerk/scripts/healthcheck.sh
# Run via systemd timer every 1 minute

# Check Rails is responding
curl -sf https://app.dailywerk.com/up > /dev/null || echo "ALERT: Rails down" >> /var/log/dailywerk/alerts.log

# Check disk usage
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
[ "$DISK_USAGE" -gt 85 ] && echo "ALERT: Disk usage ${DISK_USAGE}%" >> /var/log/dailywerk/alerts.log

# Check PostgreSQL
pg_isready -q || echo "ALERT: PostgreSQL down" >> /var/log/dailywerk/alerts.log

# Check Redis
redis-cli ping > /dev/null 2>&1 || echo "ALERT: Redis down" >> /var/log/dailywerk/alerts.log

# Check memory
FREE_MEM=$(free -m | awk '/Mem:/ {print $7}')
[ "$FREE_MEM" -lt 512 ] && echo "ALERT: Low memory (${FREE_MEM}MB available)" >> /var/log/dailywerk/alerts.log
```

**Optional: Lightweight metrics with node_exporter + Prometheus + Grafana (all local)**

If richer dashboards are wanted later, all three run on the same server:
- `node_exporter` → system metrics (CPU, RAM, disk, network)
- `prometheus` → scrapes node_exporter + Rails `/metrics` endpoint
- `grafana` → dashboards on localhost:3001, accessed via SSH tunnel

This is optional for MVP. The health check script + journald is sufficient to start.

### Alerting

For MVP, alerts go to a log file. When email/Telegram notifications are wanted:
- The health check script sends alerts via the Telegram Bot API (DailyWerk's own bot)
- Or: a simple SMTP send to the admin email
- Or: write to a file that Claude Code on the server can monitor and act on

---

## 9. Resource Limits

### systemd Resource Controls

```ini
# Production Falcon
MemoryMax=4G
CPUQuota=300%

# Production GoodJob Worker
MemoryMax=3G
CPUQuota=200%

# Staging Falcon
MemoryMax=1G
CPUQuota=100%

# Staging GoodJob Worker
MemoryMax=1G
CPUQuota=100%

# PostgreSQL (managed by pg config, not systemd)
# shared_buffers = 4GB, effective_cache_size = 8GB (for 16GB server)
```

### PostgreSQL Tuning (for 16 GB RAM server)

```
shared_buffers = 4GB
effective_cache_size = 8GB
work_mem = 64MB
maintenance_work_mem = 512MB
max_connections = 100
max_wal_size = 2GB
checkpoint_completion_target = 0.9
random_page_cost = 1.1  # NVMe
```

### Redis Tuning

```
maxmemory 512mb
maxmemory-policy allkeys-lru
```

---

## 10. Claude Code on Server

Claude Code is installed on the server for operational automation:
- Running deployment scripts
- Investigating production issues (log analysis, query debugging)
- Applying security patches and updates
- Running backup verification

**Access**: Via SSH into the deploy user account. Claude Code runs with the deploy user's permissions — no root access.

**API key**: Stored in the deploy user's environment, not in the application's `.env`.

---

## 11. Open Questions

1. **Domain name**: `dailywerk.com` or different? Affects Cloudflare, Nginx, CORS, WorkOS config.
2. **Develop branch**: Does `develop` exist today, or should we adopt it? Alternative: staging deploys from feature branches.
3. **Email delivery**: Transactional email provider for password resets, notifications? (Postmark, Resend, or self-hosted?)
4. **Hetzner Object Storage region**: Same datacenter as VPS (FSN1) for lowest latency to backup bucket.
5. **Webhook vs polling for deploys**: Webhook is more responsive but needs a listener process. Polling is simpler but has 1-minute delay.
6. **Prometheus/Grafana**: Worth the memory overhead (~500MB) for MVP, or defer?
