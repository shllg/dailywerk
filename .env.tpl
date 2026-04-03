# Canonical environment template for the repository.
# Keep this file complete and do not add a separate .env.example.

# Rails
RAILS_ENV=development
RAILS_MASTER_KEY=
SECRET_KEY_BASE=
RAILS_LOG_LEVEL=info
RAILS_LOG_TO_STDOUT=true
APP_ENVIRONMENT=development
BUILD_SHA=
BUILD_REF=
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=

# HTTP / routing
APP_HOST=app.dailywerk.com
CORS_ORIGINS=http://localhost:5173,https://app.dailywerk.com
ACTION_CABLE_ALLOWED_ORIGINS=http://localhost:5173,http://localhost:3000,https://app.dailywerk.com

# Database
DATABASE_URL=
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
VAULT_LOCAL_BASE=/data/workspaces
DAILYWERK_S3_PORT=9002
RUSTFS_ENDPOINT=http://localhost:9002
RUSTFS_ACCESS_KEY=rustfsadmin
RUSTFS_SECRET_KEY=rustfsadmin
RUSTFS_BUCKET=dailywerk-dev
VAULT_S3_BUCKET=
VAULT_S3_ENDPOINT=
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
WORKOS_API_KEY=
WORKOS_CLIENT_ID=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_PUBLISHABLE_KEY=
OPENAI_API_KEY=op://DailyWerk/dailywerk-dev-env/openai-api-key
VAULT_STRUCTURE_ANALYSIS_MODEL=gpt-5.4

# Metrics and diagnostics
METRICS_ENABLED=true
METRICS_BASIC_AUTH_USERNAME=
METRICS_BASIC_AUTH_PASSWORD=

# Developer tooling
SKIP_DOCKER=0
RUN_LIVE_LLM_TESTS=0
PARALLEL_WORKERS=
PARALLELIZE_THRESHOLD=

# Jobs
GOOD_JOB_QUEUE_PREFIX=
GOOD_JOB_ENABLE_CRON=true

# Deploy listener
DEPLOY_LISTENER_HOST=0.0.0.0
DEPLOY_LISTENER_PORT=8081
DEPLOY_LISTENER_LOG=/tmp/deploy-listener.log
DEPLOY_WEBHOOK_SECRET=
DEPLOY_WEBHOOK_SECRET_OP_PATH=
