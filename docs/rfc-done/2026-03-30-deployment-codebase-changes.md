---
type: rfc
title: "Deployment — Codebase Changes"
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/06-deployment-hetzner
phase: 1
---

# RFC: Deployment — Codebase Changes

## Context

The deployment baseline is now Debian + Docker Compose + GHCR + blue/green slots. This RFC lists the repository changes required to support that model. It intentionally replaces the earlier native-process deploy assumptions.

This RFC covers:

- application configuration changes
- Docker image build inputs
- GitHub workflow changes
- readiness, metrics, and logging contracts

This RFC does **not** cover:

- server provisioning
- Cloudflare setup
- live server compose operations

Those live in the sibling Manual Setup and Server Automation RFCs.

---

## 1. Environment Contract

### 1.1 `.env.tpl`

The repo should document the runtime contract for containerized deploys in the canonical `.env.tpl`.

Required environment variables:

```bash
# Rails
RAILS_ENV=production
RAILS_MASTER_KEY=
SECRET_KEY_BASE=
RAILS_LOG_LEVEL=info
RAILS_LOG_TO_STDOUT=true
APP_ENVIRONMENT=production

# HTTP / routing
APP_HOST=app.dailywerk.com
CORS_ORIGINS=https://app.dailywerk.com
ACTION_CABLE_ALLOWED_ORIGINS=https://app.dailywerk.com

# Database
DATABASE_URL=postgres://dailywerk:password@postgres:5432/dailywerk_production
DB_POOL=10

# Valkey (Redis protocol)
VALKEY_URL=redis://valkey:6379/0
CACHE_NAMESPACE=dailywerk:prod:cache
CABLE_NAMESPACE=dailywerk:prod:cable

# Storage
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_ENDPOINT=
AWS_REGION=
S3_BUCKET=

# Third-party auth/billing
WORKOS_API_KEY=
WORKOS_CLIENT_ID=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_PUBLISHABLE_KEY=

# Metrics and diagnostics
METRICS_ENABLED=true
METRICS_BASIC_AUTH_USERNAME=
METRICS_BASIC_AUTH_PASSWORD=
BUILD_SHA=
BUILD_REF=
```

### 1.2 Naming Rule

Use `VALKEY_URL` in the runtime contract, even though Rails still uses the Redis protocol and adapter internally. That keeps the infrastructure language accurate while avoiding confusion in operations docs.

---

## 2. Rails Runtime Configuration

### 2.1 Production Environment

Update `config/environments/production.rb` for containerized execution:

```ruby
config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym
config.log_tags  = [:request_id]

if ActiveModel::Type::Boolean.new.cast(ENV.fetch("RAILS_LOG_TO_STDOUT", "true"))
  logger           = ActiveSupport::Logger.new($stdout)
  logger.formatter = ::Logger::Formatter.new
  config.logger    = ActiveSupport::TaggedLogging.new(logger)
end

config.cache_store = :redis_cache_store, {
  url: ENV.fetch("VALKEY_URL"),
  namespace: ENV.fetch("CACHE_NAMESPACE", "dailywerk:cache")
}

config.action_cable.url = "wss://#{ENV.fetch('APP_HOST')}/cable"
config.action_cable.allowed_request_origins =
  ENV.fetch("ACTION_CABLE_ALLOWED_ORIGINS", "").split(",")

config.active_storage.service = :hetzner
config.hosts = [ENV["APP_HOST"]].compact
```

### 2.2 Cable Configuration

`config/cable.yml` should keep using the Redis adapter because Valkey is Redis-protocol compatible:

```yaml
production:
  adapter: redis
  url: <%= ENV.fetch("VALKEY_URL") %>
  channel_prefix: <%= ENV.fetch("CABLE_NAMESPACE", "dailywerk:cable") %>
```

### 2.3 GoodJob

GoodJob must remain in external mode:

```ruby
config.good_job.execution_mode = :external
```

The worker container is the external executor; no inline or async fallback is acceptable.

---

## 3. Readiness, Health, and Metrics

### 3.1 Distinguish Liveness from Readiness

The existing `/up` endpoint is not enough for blue/green switching. Add a readiness endpoint such as `/ready` that checks:

- DB connectivity
- Valkey connectivity
- any required pending-migration guard

The deploy listener and Nginx switch logic should use `/ready`, not `/up`.

### 3.2 Metrics Endpoint

Prometheus is mandatory, so the app needs an explicit metrics strategy.

Recommended change:

- add a Prometheus-compatible exporter path such as `/metrics`
- include request duration/count, ActiveRecord pool state, GoodJob queue depth, and Action Cable connection metrics where practical
- protect the endpoint with internal-only network access or basic auth at Nginx

### 3.3 Structured Logs to STDOUT

Container logs should go to stdout/stderr, not app-specific files. The app should emit parseable structured logs so Promtail/Loki can label and query them cleanly.

At minimum:

- request ID
- environment
- controller/action or job name
- severity
- timestamp

---

## 4. Container Images

### 4.1 Required Dockerfiles

The repo should define at least:

- `Dockerfile.api`
- `Dockerfile.frontend`
- optionally `docker/postgres-pgvector/Dockerfile` if the team chooses to publish its own PostgreSQL+pgvector image to GHCR

### 4.2 API Image Requirements

The API image should:

- install production gems only
- run as a non-root user
- provide commands for:
  - API server
  - worker
  - one-off migration job
- include a healthcheck/readiness script

### 4.3 Frontend Image Requirements

The frontend image should:

- build the Vite app in a builder stage
- serve static assets from a minimal runtime image
- expose a health endpoint or at least a deterministic `index.html` response for Nginx probing

### 4.4 `.dockerignore`

Add a strict `.dockerignore` to keep build contexts small and avoid leaking local data into images.

---

## 5. Deployment Artifacts in the Repo

The deployment model should be versioned with the application code.

Recommended repo paths:

- `deploy/compose/infra.yml`
- `deploy/compose/observability.yml`
- `deploy/compose/edge.yml`
- `deploy/compose/app-slot.yml`
- `deploy/nginx/templates/*.conf`
- `deploy/scripts/switch-slot.sh`
- `deploy/scripts/run-migrations.sh`

The server automation RFC can call these files, but they should live in the repo so changes are reviewed alongside app changes.

---

## 6. GitHub Actions / GHCR

### 6.1 Build and Publish Workflows

The repo should gain workflows that:

- build frontend and API images
- push them to GHCR
- publish immutable tags for each commit
- publish channel tags for `master` and `dev`

### 6.2 Deploy Notification Workflow

The repo should also define a workflow triggered by `registry_package` publish events or the end of the image-publish workflow. That workflow sends a signed deploy webhook to the server so the host never builds from source.

Expected inputs:

- environment (`production` or `staging`)
- API image tag or digest
- frontend image tag or digest
- build SHA

### 6.3 Recommended Image Metadata

Add OCI labels to images:

- source repository
- commit SHA
- branch/ref
- build timestamp

This makes rollback and incident tracing simpler.

---

## 7. Storage and External Services

### 7.1 Active Storage

`config/storage.yml` should keep using Hetzner Object Storage via S3-compatible config.

### 7.2 Database User Model

The production `DATABASE_URL` should use the non-superuser application role so RLS assumptions remain valid in containers exactly as they would natively.

---

## 8. Secrets Management — 1Password Integration

### 8.1 Architecture

Secrets are stored in 1Password vaults and retrieved at deploy time using a 1Password service account. The only secret manually placed on the server is the `OP_SERVICE_ACCOUNT_TOKEN`.

### 8.2 Env File Generation

The deploy-listener (or a pre-start script) must:

1. authenticate to 1Password using the service account token
2. read the appropriate vault items for the target environment
3. render the `.env` file for the app slot being deployed
4. pass the env file to Docker Compose

This replaces static `.env` files on the server. The `.env.tpl` in the repo documents the expected shape, but production values never live on disk outside of container runtime.

### 8.3 1Password CLI

The server needs the `op` CLI installed. The deploy scripts should use `op read` or `op inject` to resolve secret references.

Example:

```bash
op read "op://DailyWerk Production/rails/master-key"
```

### 8.4 Required Vault Structure

| Vault | Item | Fields |
|-------|------|--------|
| `DailyWerk Production` | `rails` | `master-key`, `secret-key-base` |
| `DailyWerk Production` | `database` | `url` |
| `DailyWerk Production` | `valkey` | `url` |
| `DailyWerk Production` | `workos` | `api-key`, `client-id` |
| `DailyWerk Production` | `stripe` | `secret-key`, `webhook-secret`, `publishable-key` |
| `DailyWerk Production` | `storage` | `access-key-id`, `secret-access-key`, `endpoint`, `region`, `bucket` |
| `DailyWerk Production` | `metrics` | `basic-auth-username`, `basic-auth-password` |
| `DailyWerk Production` | `grafana` | `admin-username`, `admin-password` |
| `DailyWerk Production` | `backup` | `restic-password` |
| `DailyWerk Staging` | *(same structure, staging values)* | |
| `DailyWerk Shared` | `deploy` | `webhook-secret`, `ghcr-token`, `ghcr-user` |
| `DailyWerk Shared` | `tailscale` | `auth-key` |

---

## 9. Deploy Event Tracking

### 9.1 Grafana Annotations

The deploy-listener must push an annotation to Grafana after each successful slot switch. This makes deploys visible as vertical markers on all dashboards.

Required annotation fields:

- `time`: deploy timestamp
- `tags`: `["deploy", "<environment>", "<slot>"]`
- `text`: commit SHA, image tag, environment, result

### 9.2 Implementation

The deploy-listener calls the Grafana HTTP API:

```bash
curl -X POST http://grafana:3000/api/annotations \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "time": <epoch_ms>,
    "tags": ["deploy", "production", "blue"],
    "text": "Deploy prod-abc123f to blue slot — success"
  }'
```

The Grafana API key should be stored in 1Password and injected into the deploy-listener container.

### 9.3 Dashboard Integration

All Grafana dashboards should include an annotation query filtering on the `deploy` tag so operators can correlate metric changes with specific rollouts.

---

## 10. Operational Documentation

The codebase changes must include the creation of `docs/infrastructure/` with runbooks as specified in the PRD §9. These are versioned alongside the application so they stay in sync with deploy scripts, compose files, and secret structures.

The implementation checklist below includes a line item for each required runbook.

---

## 11. Implementation Checklist

1. [ ] keep `.env.tpl` as the single container runtime contract
2. [ ] switch production cache/cable settings to `VALKEY_URL`
3. [ ] enable stdout-first structured logging
4. [ ] add `/ready` endpoint for blue/green slot cutover
5. [ ] add `/metrics` strategy for Prometheus
6. [ ] add Dockerfiles for API and frontend images
7. [ ] add `.dockerignore`
8. [ ] add versioned deployment manifests and slot-switch scripts
9. [ ] add GHCR build/publish workflows
10. [ ] add deploy-notification workflow
11. [ ] verify GoodJob remains external-only
12. [ ] add 1Password CLI integration to deploy scripts (`op read` / `op inject`)
13. [ ] add Grafana annotation push to deploy-listener after slot switch
14. [ ] create `docs/infrastructure/deploy.md` runbook
15. [ ] create `docs/infrastructure/rollback.md` runbook
16. [ ] create `docs/infrastructure/backup-restore.md` runbook
17. [ ] create `docs/infrastructure/tailscale.md` runbook
18. [ ] create `docs/infrastructure/secrets.md` runbook
19. [ ] create `docs/infrastructure/incident-response.md` runbook
20. [ ] create `docs/infrastructure/new-server.md` runbook

---

## 12. What This RFC No Longer Assumes

- no host-level `bundle install` during deploy
- no host-level `pnpm build` during deploy
- no `bin/deploy` script that pulls git and restarts native services
- no host-native Redis terminology in ops docs
- no restart-based app deploys
