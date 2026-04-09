# Canonical environment template for the repository.
# Keep this file complete and do not add a separate .env.example.
#
# Empty values are stripped by bin/op-inject-env so they never poison
# Rails (DATABASE_URL="" overrides database.yml, SECRET_KEY_BASE=""
# overrides config/master.key, etc.).  Comment out vars that have no
# dev default — they'll only appear in .env when op inject fills them.

# Rails
RAILS_ENV=development
RAILS_LOG_LEVEL=info
# RAILS_TEST_LOG_LEVEL=warn  # Optional test-only override; defaults to warn
RAILS_LOG_TO_STDOUT=true
APP_ENVIRONMENT=development
# BUILD_SHA=              — set by CI/deploy only
# BUILD_REF=              — set by CI/deploy only
# SECRET_KEY_BASE=        — dev reads config/master.key; set in production only
# Development master key (staging/production use shllg vault, see bin/credentials-edit)
RAILS_MASTER_KEY=op://DailyWerk/dailywerk-dev-env/rails-master-key
# ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
# ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
# ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=

# HTTP / routing
APP_HOST=app.dailywerk.com
CORS_ORIGINS=http://localhost:5173,https://app.dailywerk.com
ACTION_CABLE_ALLOWED_ORIGINS=http://localhost:5173,http://localhost:3000,https://app.dailywerk.com

# Database
# DATABASE_URL=           — production only; dev uses DB_HOST/DB_PORT/DB_NAME below
DB_HOST=localhost
DB_PORT=5452
DB_USERNAME=postgres
DB_PASSWORD=password
DB_APP_PASSWORD=dailywerk_app_password
DB_NAME=dailywerk_development
DB_NAME_TEST=dailywerk_test
DB_POOL=10
RAILS_MAX_THREADS=5

# Valkey (Redis-compatible, cache + pub/sub)
VALKEY_URL=redis://localhost:6399/0
REDIS_URL=redis://localhost:6399/0
CACHE_NAMESPACE=dailywerk:dev:cache
CABLE_NAMESPACE=dailywerk_development
# CABLE_REDIS_URL=redis://localhost:6399/1   # Optional ActionCable override
# CABLE_PREFIX=dailywerk_development         # Legacy ActionCable prefix

# Storage
AWS_ENDPOINT=http://localhost:9002
AWS_ACCESS_KEY_ID=rustfsadmin
AWS_SECRET_ACCESS_KEY=rustfsadmin
AWS_REGION=us-east-1
AWS_FORCE_PATH_STYLE=true
S3_BUCKET=dailywerk-dev
S3_REQUIRE_HTTPS_FOR_SSE_CPK=false
# VAULT_LOCAL_BASE=       — optional override; local default is ../vault-workspaces
DAILYWERK_S3_PORT=9002
RUSTFS_ENDPOINT=http://localhost:9002
RUSTFS_ACCESS_KEY=rustfsadmin
RUSTFS_SECRET_KEY=rustfsadmin
RUSTFS_BUCKET=dailywerk-dev
# VAULT_S3_BUCKET=        — production only
# VAULT_S3_ENDPOINT=      — production only
VAULT_S3_REGION=fsn1
VAULT_S3_REQUIRE_HTTPS_FOR_SSE_CPK=true

# Mail (Mailcatcher)
SMTP_HOST=localhost
SMTP_PORT=1035

# Frontend dev server
PORT=3000
VITE_PORT=5173
VITE_API_PORT=3000

# Third-party auth / billing / AI
# These are now stored in Rails encrypted credentials. Set ENV vars here to override.
# WORKOS_API_KEY=
# WORKOS_CLIENT_ID=
# WORKOS_WEBHOOK_SECRET=
# STRIPE_SECRET_KEY=
# STRIPE_WEBHOOK_SECRET=
# STRIPE_PUBLISHABLE_KEY=
# OPENAI_API_KEY=
VAULT_STRUCTURE_ANALYSIS_MODEL=gpt-5.4

# Metrics and diagnostics
METRICS_ENABLED=true
# METRICS_BASIC_AUTH_USERNAME=
# METRICS_BASIC_AUTH_PASSWORD=
# GOOD_JOB_BASIC_AUTH_USERNAME=  — op inject or manual
# GOOD_JOB_BASIC_AUTH_PASSWORD=  — op inject or manual

# Developer tooling
SKIP_DOCKER=0
RUN_LIVE_LLM_TESTS=0
# PARALLEL_WORKERS=       — defaults handled in test_helper
# PARALLELIZE_THRESHOLD=  — defaults handled in test_helper

# Obsidian Sync (optional - defaults to 'ob' if not set)
# OBSIDIAN_HEADLESS_BIN=ob  — npm install -g obsidian-headless

# Jobs
# GOOD_JOB_QUEUE_PREFIX=  — empty is fine, leave unset
GOOD_JOB_ENABLE_CRON=true

# Deploy listener
DEPLOY_LISTENER_HOST=0.0.0.0
DEPLOY_LISTENER_PORT=8081
DEPLOY_LISTENER_LOG=/tmp/deploy-listener.log
# DEPLOY_WEBHOOK_SECRET=          — op inject or manual
# DEPLOY_WEBHOOK_SECRET_OP_PATH=  — op inject or manual
