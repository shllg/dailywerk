# Database
DB_HOST=localhost
DB_PORT=5452
DB_USERNAME=postgres
DB_PASSWORD=password
DB_APP_PASSWORD=dailywerk_app_password
# DB_NAME=dailywerk_development          # Override for worktrees

# Redis (cache)
REDIS_URL=redis://localhost:6399/0
# CABLE_REDIS_URL=redis://localhost:6399/1  # ActionCable (defaults to REDIS_URL)
# CABLE_PREFIX=dailywerk_development        # ActionCable channel prefix

# RustFS (S3-compatible storage)
RUSTFS_ENDPOINT=http://localhost:9002
RUSTFS_ACCESS_KEY=rustfsadmin
RUSTFS_SECRET_KEY=rustfsadmin
RUSTFS_BUCKET=dailywerk-dev

# Mail (Mailcatcher)
SMTP_HOST=localhost
SMTP_PORT=1035

# CORS
CORS_ORIGINS=http://localhost:5173

# GoodJob
# GOOD_JOB_QUEUE_PREFIX=                  # Queue name prefix for worktree isolation
# GOOD_JOB_ENABLE_CRON=true               # Disable in worktrees
