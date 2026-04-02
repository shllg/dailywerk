# Database
DB_HOST=localhost
DB_PORT=5452
DB_USERNAME=postgres
DB_PASSWORD=password
DB_APP_PASSWORD=dailywerk_app_password
# DB_NAME=dailywerk_development          # Override for worktrees

# Valkey (Redis-compatible, cache + pub/sub)
VALKEY_URL=redis://localhost:6399/0
# REDIS_URL=redis://localhost:6399/0          # Legacy fallback
# CABLE_NAMESPACE=dailywerk_development       # ActionCable channel prefix

# RustFS (S3-compatible storage)
AWS_ENDPOINT=http://localhost:9002
AWS_ACCESS_KEY_ID=rustfsadmin
AWS_SECRET_ACCESS_KEY=rustfsadmin
AWS_REGION=us-east-1
AWS_FORCE_PATH_STYLE=true
S3_BUCKET=dailywerk-dev
# RUSTFS_ENDPOINT=http://localhost:9002       # Legacy fallback
# RUSTFS_ACCESS_KEY=rustfsadmin               # Legacy fallback
# RUSTFS_SECRET_KEY=rustfsadmin               # Legacy fallback
# RUSTFS_BUCKET=dailywerk-dev                 # Legacy fallback

# Mail (Mailcatcher)
SMTP_HOST=localhost
SMTP_PORT=1035

# CORS
CORS_ORIGINS=http://localhost:5173

# OpenAI
OPENAI_API_KEY=op://DailyWerk/dailywerk-dev-env/openai-api-key

# GoodJob
# GOOD_JOB_QUEUE_PREFIX=                  # Queue name prefix for worktree isolation
# GOOD_JOB_ENABLE_CRON=true               # Disable in worktrees
