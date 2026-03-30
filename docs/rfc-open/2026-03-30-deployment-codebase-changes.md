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

DailyWerk needs production-readiness changes in the Rails and React codebase before deploying to a Hetzner server. This RFC lists everything that must change in code, configuration, or project structure. No infrastructure or server-side work — that lives in the sibling RFCs.

---

## 1. Rails Production Configuration

### 1.1 Environment Variables

Create a `.env.example` documenting all required production environment variables:

```bash
# .env.example — Copy to .env and fill in values
# NEVER commit .env to git

# Rails
RAILS_ENV=production
RAILS_MASTER_KEY=           # from config/master.key
SECRET_KEY_BASE=            # rails secret
RAILS_LOG_LEVEL=info

# Database
DATABASE_URL=postgres://dailywerk:PASSWORD@localhost:5432/dailywerk_production

# Redis
REDIS_URL=redis://localhost:6379/0

# Falcon
PORT=3000
FALCON_COUNT=4              # Number of worker processes

# WorkOS Auth
WORKOS_API_KEY=
WORKOS_CLIENT_ID=

# Stripe
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_PUBLISHABLE_KEY=

# Hetzner Object Storage (S3-compatible)
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_ENDPOINT=https://fsn1.your-objectstorage.com
AWS_REGION=fsn1
S3_BUCKET=dailywerk-production

# OpenAI (platform key for system operations)
OPENAI_API_KEY=

# Application
APP_HOST=app.dailywerk.com
CORS_ORIGINS=https://app.dailywerk.com
ACTION_CABLE_ALLOWED_ORIGINS=https://app.dailywerk.com
```

### 1.2 Production Environment Updates

Changes to `config/environments/production.rb`:

```ruby
# Cache store — use Redis
config.cache_store = :redis_cache_store, {
  url: ENV["REDIS_URL"],
  namespace: "cache:#{ENV.fetch('RAILS_ENV', 'production')}"
}

# Action Cable — Redis adapter
config.action_cable.url = "wss://#{ENV['APP_HOST']}/cable"
config.action_cable.allowed_request_origins = ENV.fetch("ACTION_CABLE_ALLOWED_ORIGINS", "").split(",")

# Active Storage — S3
config.active_storage.service = :hetzner

# Host authorization
config.hosts = [
  ENV["APP_HOST"],
  "localhost"
].compact

# Log level from env
config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym
```

### 1.3 Cable Configuration

Update `config/cable.yml`:

```yaml
development:
  adapter: redis
  url: redis://localhost:<%= ENV.fetch("DAILYWERK_REDIS_PORT", 6399) %>/1

test:
  adapter: test

production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL", "redis://localhost:6379/1") %>
  channel_prefix: dailywerk_<%= Rails.env %>
```

### 1.4 Storage Configuration

Update `config/storage.yml`:

```yaml
local:
  service: Disk
  root: <%= Rails.root.join("storage") %>

hetzner:
  service: S3
  access_key_id: <%= ENV["AWS_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
  endpoint: <%= ENV["AWS_ENDPOINT"] %>
  region: <%= ENV.fetch("AWS_REGION", "fsn1") %>
  bucket: <%= ENV["S3_BUCKET"] %>
  force_path_style: true
```

### 1.5 CORS Configuration

Update `config/initializers/cors.rb`:

```ruby
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*ENV.fetch("CORS_ORIGINS", "http://localhost:5173").split(","))

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ["Authorization"],
      credentials: true
  end
end
```

### 1.6 GoodJob Production Config

Verify `config/initializers/good_job.rb` sets external mode for production:

```ruby
config.good_job.execution_mode = :external
```

This is already specified in [PRD 04 §8](../prd/04-billing-and-operations.md#8-goodjob-configuration). Ensure no environment override changes it.

---

## 2. Database Configuration

### 2.1 Production Database User

The application must connect as a non-superuser role where RLS is expected to enforce isolation (per [PRD 01 §4.2](../prd/01-platform-and-infrastructure.md#42-postgresql-row-level-security)).

Add a setup task or migration that creates the `app_user` role:

```ruby
# db/seeds/production_setup.rb (run once, manually)
# Or as a standalone Rake task: bin/rails db:create_app_user

ActiveRecord::Base.connection.execute(<<~SQL)
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
      CREATE ROLE app_user WITH LOGIN PASSWORD 'from_env_var';
    END IF;
  END
  $$;

  GRANT CONNECT ON DATABASE dailywerk_production TO app_user;
  GRANT USAGE ON SCHEMA public TO app_user;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO app_user;
SQL
```

The `DATABASE_URL` in production `.env` should use this `app_user` role, not the superuser `postgres`.

### 2.2 Database Connection Pool

Update `config/database.yml` to respect `DATABASE_URL` and connection pool:

```yaml
production:
  <<: *default
  url: <%= ENV["DATABASE_URL"] %>
  pool: <%= ENV.fetch("DB_POOL", 10) %>
  prepared_statements: true
```

---

## 3. Frontend Build Configuration

### 3.1 Vite Production Build

The frontend needs environment-aware API base URL configuration.

```typescript
// frontend/src/config.ts
export const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || ''
export const WS_URL = import.meta.env.VITE_WS_URL || `wss://${window.location.host}/cable`
```

Ensure `frontend/.env.production` exists:

```bash
VITE_API_BASE_URL=
VITE_WS_URL=
```

When empty, the SPA uses the same origin (served by Nginx), which is the correct production behavior — API calls go to `/api/v1/...` on the same domain.

### 3.2 Build Output

`pnpm build` outputs to `frontend/dist/`. Nginx serves this directly. No Rails asset pipeline involved.

### 3.3 .gitignore

Ensure `frontend/dist/` is in `.gitignore` — it's built on the server during deploy, not committed.

---

## 4. Deploy Script

Create a deploy script in the repository:

```bash
#!/bin/bash
# bin/deploy
# Usage: bin/deploy [production|staging]
# Run on the server, not locally

set -euo pipefail

ENVIRONMENT="${1:-production}"
APP_DIR="/opt/dailywerk/${ENVIRONMENT}"
SYSTEMD_PREFIX="dailywerk-${ENVIRONMENT}"

echo "==> Deploying ${ENVIRONMENT} from $(git rev-parse --short HEAD)"

cd "$APP_DIR"

# Pull latest code
git fetch origin
case "$ENVIRONMENT" in
  production) git checkout master && git pull --ff-only origin master ;;
  staging)    git checkout develop && git pull --ff-only origin develop ;;
esac

# Backend dependencies
bundle config set --local deployment true
bundle config set --local without 'development test'
bundle install --jobs 4

# Database migration
RAILS_ENV="$ENVIRONMENT" bin/rails db:migrate

# Frontend build
cd frontend
pnpm install --frozen-lockfile
pnpm build
cd ..

# Restart services
sudo systemctl restart "${SYSTEMD_PREFIX}-falcon"
sudo systemctl restart "${SYSTEMD_PREFIX}-worker"

# Health check
sleep 3
if curl -sf "http://localhost:${PORT:-3000}/up" > /dev/null; then
  echo "==> Deploy successful ($(git rev-parse --short HEAD))"
else
  echo "==> HEALTH CHECK FAILED — check logs"
  exit 1
fi
```

Make executable: `chmod +x bin/deploy`.

---

## 5. Webhook Receiver (Optional)

If using webhook-based deploys, add a lightweight receiver:

```bash
# bin/webhook-deploy
# Receives GitHub webhook, verifies signature, triggers deploy
# Uses the `webhook` tool (https://github.com/adnanh/webhook)
# Config in /opt/dailywerk/webhook.json
```

The webhook config and systemd unit live on the server, not in the codebase. The receiver only needs to verify the GitHub signature and call `bin/deploy`.

---

## 6. Health Check Endpoint

The existing `/up` endpoint from Rails health check is sufficient. Verify it's accessible:

```ruby
# config/routes.rb — already present
get "up" => "rails/health#show", as: :rails_health_check
```

No changes needed unless we want richer health data (DB connectivity, Redis, disk space). Defer for now.

---

## 7. Procfile.prod

Create a production Procfile for reference (systemd units are the actual process manager, but this documents what runs):

```
# Procfile.prod — Reference only. Systemd manages these in production.
api: bundle exec falcon serve --bind http://localhost:${PORT:-3000} --count ${FALCON_COUNT:-4}
worker: bundle exec good_job start
```

---

## 8. .gitignore Updates

Ensure these are in `.gitignore`:

```
# Environment files
.env
.env.production
.env.staging

# Frontend build output
frontend/dist/

# Bundle deployment
vendor/bundle/

# Rails
tmp/
log/
storage/
```

---

## 9. Implementation Checklist

1. [ ] Create `.env.example` with all required variables
2. [ ] Update `config/environments/production.rb` (cache, cable, storage, hosts)
3. [ ] Update `config/cable.yml` (Redis adapter for production)
4. [ ] Update `config/storage.yml` (Hetzner S3)
5. [ ] Update `config/initializers/cors.rb` (env-driven origins)
6. [ ] Create `frontend/src/config.ts` and `frontend/.env.production`
7. [ ] Create `bin/deploy` script
8. [ ] Create `Procfile.prod`
9. [ ] Update `.gitignore`
10. [ ] Verify GoodJob external mode is set for production
11. [ ] Add database `app_user` creation task/documentation

---

## 10. What This RFC Does NOT Change

- No Docker/container changes — production runs natively
- No CI/CD pipeline definition — deploy is triggered by webhook or manual script
- No Nginx config — that's server-side setup (RFC: Manual Setup)
- No systemd units — that's server-side setup (RFC: Server Automation)
- No new gem dependencies
