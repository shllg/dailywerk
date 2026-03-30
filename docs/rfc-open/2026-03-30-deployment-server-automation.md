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

After the manual setup steps (server provisioning, DNS, certificates), the remaining server configuration can be automated. This RFC lists everything that Claude Code should execute on the server, organized as sequential phases.

**Prerequisites**: Complete the Manual Setup RFC first. The server should be accessible via SSH as the `deploy` user with sudo access, and Cloudflare origin certificates should be uploaded.

---

## 1. Phase 1 — System Hardening

Run as `deploy` user with sudo.

### 1.1 SSH Hardening

```bash
# Backup original config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Apply hardened config
sudo tee /etc/ssh/sshd_config.d/dailywerk.conf << 'EOF'
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers deploy
EOF

sudo systemctl restart sshd
```

**Important**: Before restarting sshd, verify you can still connect. Open a second SSH session to test after restart.

### 1.2 Firewall (ufw)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH on custom port
sudo ufw allow 2222/tcp comment 'SSH'

# HTTPS from Cloudflare only
# Cloudflare IPv4 ranges (update periodically)
for ip in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
          141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
          197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
          104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
  sudo ufw allow from "$ip" to any port 443 proto tcp comment 'Cloudflare'
done

sudo ufw enable
```

### 1.3 fail2ban

```bash
sudo apt-get install -y fail2ban

sudo tee /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = 2222
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

sudo systemctl enable --now fail2ban
```

### 1.4 Automatic Security Updates

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades

# Enable automatic reboot for kernel updates (at 4am)
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades-local << 'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
```

### 1.5 Disable Unnecessary Services

```bash
sudo systemctl disable --now snapd snapd.socket snapd.seeded 2>/dev/null || true
sudo systemctl disable --now multipathd multipathd.socket 2>/dev/null || true
sudo systemctl disable --now ModemManager 2>/dev/null || true
```

### 1.6 Kernel Tuning

```bash
sudo tee /etc/sysctl.d/99-dailywerk.conf << 'EOF'
# Network security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Performance
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
vm.swappiness = 10
vm.overcommit_memory = 1
EOF

sudo sysctl -p /etc/sysctl.d/99-dailywerk.conf
```

---

## 2. Phase 2 — Runtime Installation

### 2.1 PostgreSQL 17 + pgvector

```bash
# Add PostgreSQL APT repository
sudo apt-get install -y curl ca-certificates
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > \
  /etc/apt/sources.list.d/pgdg.list'

sudo apt-get update
sudo apt-get install -y postgresql-17 postgresql-17-pgvector

# PostgreSQL listens on localhost only (default)
# Verify:
grep "^listen_addresses" /etc/postgresql/17/main/postgresql.conf || echo "Default: localhost only"
```

### 2.2 PostgreSQL Tuning

```bash
sudo tee /etc/postgresql/17/main/conf.d/dailywerk.conf << 'EOF'
# DailyWerk tuning for 16GB RAM server
shared_buffers = 4GB
effective_cache_size = 8GB
work_mem = 64MB
maintenance_work_mem = 512MB
max_connections = 100
max_wal_size = 2GB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
wal_compression = on

# Logging
log_min_duration_statement = 500
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
EOF

sudo systemctl restart postgresql
```

### 2.3 Create Databases and Roles

```bash
sudo -u postgres psql << 'SQL'
-- Production database
CREATE DATABASE dailywerk_production;

-- Staging database
CREATE DATABASE dailywerk_staging;

-- Application role (non-superuser, for RLS enforcement)
CREATE ROLE dailywerk WITH LOGIN PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
GRANT CONNECT ON DATABASE dailywerk_production TO dailywerk;
GRANT CONNECT ON DATABASE dailywerk_staging TO dailywerk;

-- Grant schema permissions (run after migrations create tables)
-- This is re-run by the deploy script after each migration
\c dailywerk_production
GRANT USAGE ON SCHEMA public TO dailywerk;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dailywerk;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dailywerk;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailywerk;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO dailywerk;

\c dailywerk_staging
GRANT USAGE ON SCHEMA public TO dailywerk;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dailywerk;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dailywerk;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailywerk;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO dailywerk;

-- Enable extensions (requires superuser, done once)
\c dailywerk_production
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

\c dailywerk_staging
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";
SQL
```

**Note**: Replace `CHANGE_ME_STRONG_PASSWORD` with the actual password from Rails credentials.

### 2.4 Redis 7

```bash
sudo apt-get install -y redis-server

# Configure Redis
sudo tee /etc/redis/redis.conf.d/dailywerk.conf << 'EOF'
bind 127.0.0.1
maxmemory 512mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF

# If Redis doesn't support conf.d, edit main config:
sudo sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
sudo sed -i 's/^# maxmemory .*/maxmemory 512mb/' /etc/redis/redis.conf
sudo sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

sudo systemctl enable --now redis-server
```

### 2.5 Ruby (via ruby-install + chruby)

```bash
# Install ruby-install
wget https://github.com/postmodern/ruby-install/releases/download/v0.9.4/ruby-install-0.9.4.tar.gz
tar -xzf ruby-install-0.9.4.tar.gz
cd ruby-install-0.9.4/
sudo make install
cd ..
rm -rf ruby-install-0.9.4*

# Install chruby
wget https://github.com/postmodern/chruby/releases/download/v0.3.9/chruby-0.3.9.tar.gz
tar -xzf chruby-0.3.9.tar.gz
cd chruby-0.3.9/
sudo make install
cd ..
rm -rf chruby-0.3.9*

# Add chruby to deploy user's shell
echo 'source /usr/local/share/chruby/chruby.sh' >> /home/deploy/.bashrc
echo 'source /usr/local/share/chruby/auto.sh' >> /home/deploy/.bashrc

# Install Ruby (check Gemfile for version)
ruby-install ruby 3.4.2  # Match project's Ruby version

# Set default
echo 'chruby ruby-3.4.2' >> /home/deploy/.bashrc

# Install bundler
source /usr/local/share/chruby/chruby.sh
chruby ruby-3.4.2
gem install bundler
```

**Note**: Check the project's `.ruby-version` or `Gemfile` for the exact Ruby version needed.

### 2.6 Node.js 22 + pnpm

```bash
# Node.js via NodeSource
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# pnpm
sudo npm install -g pnpm

# Verify
node --version  # v22.x
pnpm --version
```

### 2.7 Nginx

```bash
sudo apt-get install -y nginx

# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default
```

### 2.8 Build Dependencies

```bash
# For native gem compilation and general build tools
sudo apt-get install -y build-essential libpq-dev libssl-dev libreadline-dev \
  zlib1g-dev libyaml-dev libffi-dev git
```

---

## 3. Phase 3 — Application Setup

### 3.1 Directory Structure

```bash
# Application directories
sudo mkdir -p /opt/dailywerk/{prod,staging}
sudo mkdir -p /data/workspaces/{prod,staging}
sudo mkdir -p /var/log/dailywerk/{prod,staging}
sudo mkdir -p /var/backups/dailywerk
sudo mkdir -p /opt/dailywerk/scripts

sudo chown -R deploy:deploy /opt/dailywerk /data/workspaces /var/log/dailywerk /var/backups/dailywerk
```

### 3.2 Clone Repository

```bash
# As deploy user
cd /opt/dailywerk/prod
git clone git@github.com:shllg/dailywerk.git .
git checkout master

cd /opt/dailywerk/staging
git clone git@github.com:shllg/dailywerk.git .
git checkout develop  # or master if develop doesn't exist yet
```

### 3.3 Environment Files

```bash
# Create .env files from .env.example
# Production
cp /opt/dailywerk/prod/.env.example /opt/dailywerk/prod/.env
chmod 600 /opt/dailywerk/prod/.env
# Edit with actual values: nano /opt/dailywerk/prod/.env

# Staging
cp /opt/dailywerk/staging/.env.example /opt/dailywerk/staging/.env
chmod 600 /opt/dailywerk/staging/.env
# Edit with actual values: nano /opt/dailywerk/staging/.env
```

### 3.4 Initial Deploy

```bash
# Production
cd /opt/dailywerk/prod
source /usr/local/share/chruby/chruby.sh && chruby ruby-3.4.2
bundle config set --local deployment true
bundle config set --local without 'development test'
bundle install --jobs 4
RAILS_ENV=production bin/rails db:migrate
RAILS_ENV=production bin/rails db:seed

cd frontend
pnpm install --frozen-lockfile
pnpm build
cd ..

# Staging — same steps with RAILS_ENV=staging and staging directory
```

---

## 4. Phase 4 — Nginx Configuration

### 4.1 Production Site

```bash
sudo tee /etc/nginx/sites-available/dailywerk-prod << 'NGINX'
upstream falcon_prod {
    server 127.0.0.1:3000;
    keepalive 16;
}

server {
    listen 443 ssl http2;
    server_name app.dailywerk.com;

    ssl_certificate     /etc/ssl/cloudflare/origin.pem;
    ssl_certificate_key /etc/ssl/cloudflare/origin-key.pem;
    ssl_client_certificate /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem;
    ssl_verify_client on;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    root /opt/dailywerk/prod/frontend/dist;

    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    gzip_min_length 1000;

    # API requests
    location /api/ {
        proxy_pass http://falcon_prod;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_http_version 1.1;

        # Timeouts for LLM streaming
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # ActionCable WebSocket
    location /cable {
        proxy_pass http://falcon_prod;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
    }

    # Health check
    location = /up {
        proxy_pass http://falcon_prod;
        proxy_set_header Host $host;
    }

    # GoodJob dashboard
    location /good_job {
        proxy_pass http://falcon_prod;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        # Access restriction handled at Rails level
    }

    # SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Static asset caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    access_log /var/log/nginx/dailywerk-prod-access.log;
    error_log /var/log/nginx/dailywerk-prod-error.log;
}
NGINX

sudo ln -sf /etc/nginx/sites-available/dailywerk-prod /etc/nginx/sites-enabled/
```

### 4.2 Staging Site

```bash
sudo tee /etc/nginx/sites-available/dailywerk-staging << 'NGINX'
upstream falcon_staging {
    server 127.0.0.1:3100;
    keepalive 8;
}

server {
    listen 443 ssl http2;
    server_name staging.dailywerk.com;

    ssl_certificate     /etc/ssl/cloudflare/origin.pem;
    ssl_certificate_key /etc/ssl/cloudflare/origin-key.pem;
    ssl_client_certificate /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem;
    ssl_verify_client on;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /opt/dailywerk/staging/frontend/dist;

    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    location /api/ {
        proxy_pass http://falcon_staging;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }

    location /cable {
        proxy_pass http://falcon_staging;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
    }

    location = /up {
        proxy_pass http://falcon_staging;
    }

    location /good_job {
        proxy_pass http://falcon_staging;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    access_log /var/log/nginx/dailywerk-staging-access.log;
    error_log /var/log/nginx/dailywerk-staging-error.log;
}
NGINX

sudo ln -sf /etc/nginx/sites-available/dailywerk-staging /etc/nginx/sites-enabled/

# Test and reload
sudo nginx -t && sudo systemctl reload nginx
```

---

## 5. Phase 5 — systemd Service Units

### 5.1 Production Falcon

```bash
sudo tee /etc/systemd/system/dailywerk-prod-falcon.service << 'EOF'
[Unit]
Description=DailyWerk Production — Falcon API Server
After=postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/opt/dailywerk/prod
EnvironmentFile=/opt/dailywerk/prod/.env
ExecStart=/home/deploy/.rubies/ruby-3.4.2/bin/bundle exec falcon serve --bind http://localhost:3000 --count 4
Restart=on-failure
RestartSec=5
MemoryMax=4G
CPUQuota=300%

StandardOutput=append:/var/log/dailywerk/prod/falcon.log
StandardError=append:/var/log/dailywerk/prod/falcon.log

[Install]
WantedBy=multi-user.target
EOF
```

### 5.2 Production GoodJob Worker

```bash
sudo tee /etc/systemd/system/dailywerk-prod-worker.service << 'EOF'
[Unit]
Description=DailyWerk Production — GoodJob Worker
After=postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/opt/dailywerk/prod
EnvironmentFile=/opt/dailywerk/prod/.env
ExecStart=/home/deploy/.rubies/ruby-3.4.2/bin/bundle exec good_job start
Restart=on-failure
RestartSec=5
MemoryMax=3G
CPUQuota=200%

StandardOutput=append:/var/log/dailywerk/prod/worker.log
StandardError=append:/var/log/dailywerk/prod/worker.log

[Install]
WantedBy=multi-user.target
EOF
```

### 5.3 Staging Services

```bash
sudo tee /etc/systemd/system/dailywerk-staging-falcon.service << 'EOF'
[Unit]
Description=DailyWerk Staging — Falcon API Server
After=postgresql.service redis-server.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/opt/dailywerk/staging
EnvironmentFile=/opt/dailywerk/staging/.env
ExecStart=/home/deploy/.rubies/ruby-3.4.2/bin/bundle exec falcon serve --bind http://localhost:3100 --count 2
Restart=on-failure
RestartSec=5
MemoryMax=1G
CPUQuota=100%

StandardOutput=append:/var/log/dailywerk/staging/falcon.log
StandardError=append:/var/log/dailywerk/staging/falcon.log

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/dailywerk-staging-worker.service << 'EOF'
[Unit]
Description=DailyWerk Staging — GoodJob Worker
After=postgresql.service redis-server.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/opt/dailywerk/staging
EnvironmentFile=/opt/dailywerk/staging/.env
ExecStart=/home/deploy/.rubies/ruby-3.4.2/bin/bundle exec good_job start
Restart=on-failure
RestartSec=5
MemoryMax=1G
CPUQuota=100%

StandardOutput=append:/var/log/dailywerk/staging/worker.log
StandardError=append:/var/log/dailywerk/staging/worker.log

[Install]
WantedBy=multi-user.target
EOF
```

### 5.4 Enable and Start All Services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dailywerk-prod-falcon dailywerk-prod-worker
sudo systemctl enable --now dailywerk-staging-falcon dailywerk-staging-worker
```

---

## 6. Phase 6 — Backup Automation

### 6.1 Backup Script

```bash
tee /opt/dailywerk/scripts/backup.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/dailywerk"
LOG="/var/log/dailywerk/backup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

log "Starting backup..."

# PostgreSQL dumps
for db in dailywerk_production dailywerk_staging; do
  DUMP_FILE="$BACKUP_DIR/pg_${db}_${TIMESTAMP}.dump"
  if pg_dump -Fc "$db" > "$DUMP_FILE" 2>> "$LOG"; then
    log "OK: $db dumped ($(du -h "$DUMP_FILE" | cut -f1))"
  else
    log "FAIL: $db dump failed"
  fi
done

# Upload to Hetzner Object Storage (if configured)
if command -v aws &> /dev/null && [ -n "${S3_BACKUP_BUCKET:-}" ]; then
  for f in "$BACKUP_DIR"/pg_*_${TIMESTAMP}.dump; do
    aws s3 cp "$f" "s3://$S3_BACKUP_BUCKET/postgres/$(basename "$f")" \
      --endpoint-url "$S3_BACKUP_ENDPOINT" >> "$LOG" 2>&1 || \
      log "FAIL: S3 upload of $(basename "$f")"
  done
fi

# Clean local backups older than 7 days
find "$BACKUP_DIR" -name "pg_*.dump" -mtime +7 -delete
log "Cleaned local backups older than 7 days"

log "Backup complete."
SCRIPT

chmod +x /opt/dailywerk/scripts/backup.sh
```

### 6.2 Backup Timer

```bash
sudo tee /etc/systemd/system/dailywerk-backup.service << 'EOF'
[Unit]
Description=DailyWerk Database Backup

[Service]
Type=oneshot
User=deploy
ExecStart=/opt/dailywerk/scripts/backup.sh
EOF

sudo tee /etc/systemd/system/dailywerk-backup.timer << 'EOF'
[Unit]
Description=DailyWerk Backup Timer (every 6 hours)

[Timer]
OnCalendar=*-*-* 00/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dailywerk-backup.timer
```

---

## 7. Phase 7 — Health Check & Log Rotation

### 7.1 Health Check Script

```bash
tee /opt/dailywerk/scripts/healthcheck.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

ALERT_LOG="/var/log/dailywerk/alerts.log"
alert() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $1" >> "$ALERT_LOG"; }

# Check production Falcon
curl -sf http://localhost:3000/up > /dev/null 2>&1 || alert "Production Rails down"

# Check staging Falcon
curl -sf http://localhost:3100/up > /dev/null 2>&1 || alert "Staging Rails down"

# Check PostgreSQL
pg_isready -q 2>/dev/null || alert "PostgreSQL down"

# Check Redis
redis-cli ping > /dev/null 2>&1 || alert "Redis down"

# Check disk usage
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
[ "$DISK_USAGE" -gt 85 ] && alert "Disk usage ${DISK_USAGE}%"

# Check memory
FREE_MEM=$(free -m | awk '/Mem:/ {print $7}')
[ "$FREE_MEM" -lt 512 ] && alert "Low memory (${FREE_MEM}MB available)"

# Check systemd service status
for svc in dailywerk-prod-falcon dailywerk-prod-worker dailywerk-staging-falcon dailywerk-staging-worker; do
  systemctl is-active --quiet "$svc" || alert "$svc is not running"
done
SCRIPT

chmod +x /opt/dailywerk/scripts/healthcheck.sh
```

### 7.2 Health Check Timer

```bash
sudo tee /etc/systemd/system/dailywerk-healthcheck.service << 'EOF'
[Unit]
Description=DailyWerk Health Check

[Service]
Type=oneshot
User=deploy
ExecStart=/opt/dailywerk/scripts/healthcheck.sh
EOF

sudo tee /etc/systemd/system/dailywerk-healthcheck.timer << 'EOF'
[Unit]
Description=DailyWerk Health Check (every minute)

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dailywerk-healthcheck.timer
```

### 7.3 Log Rotation

```bash
sudo tee /etc/logrotate.d/dailywerk << 'EOF'
/var/log/dailywerk/*/*.log /var/log/dailywerk/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

sudo tee /etc/logrotate.d/dailywerk-nginx << 'EOF'
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
EOF
```

---

## 8. Phase 8 — Cloudflare IP Update Script

Cloudflare IP ranges change occasionally. Keep the firewall in sync:

```bash
tee /opt/dailywerk/scripts/update-cloudflare-ips.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

LOG="/var/log/dailywerk/cloudflare-ip-update.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# Fetch current Cloudflare IPs
CF_IPS=$(curl -sf https://www.cloudflare.com/ips-v4)
if [ -z "$CF_IPS" ]; then
  log "FAIL: Could not fetch Cloudflare IPs"
  exit 1
fi

# Remove old Cloudflare rules
sudo ufw status numbered | grep 'Cloudflare' | awk -F'[][]' '{print $2}' | \
  sort -rn | while read num; do
    sudo ufw --force delete "$num"
  done

# Add current Cloudflare IPs
while IFS= read -r ip; do
  sudo ufw allow from "$ip" to any port 443 proto tcp comment 'Cloudflare'
done <<< "$CF_IPS"

log "Updated Cloudflare IPs ($(echo "$CF_IPS" | wc -l) ranges)"
SCRIPT

chmod +x /opt/dailywerk/scripts/update-cloudflare-ips.sh
```

Run monthly via systemd timer or cron:

```bash
sudo tee /etc/systemd/system/cloudflare-ip-update.timer << 'EOF'
[Unit]
Description=Update Cloudflare IP ranges in firewall (monthly)

[Timer]
OnCalendar=*-*-01 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/cloudflare-ip-update.service << 'EOF'
[Unit]
Description=Update Cloudflare IPs

[Service]
Type=oneshot
ExecStart=/opt/dailywerk/scripts/update-cloudflare-ips.sh
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now cloudflare-ip-update.timer
```

---

## 9. Phase 9 — Claude Code Installation

```bash
# As deploy user
# Install Claude Code CLI (follow current Anthropic installation instructions)
# The exact install command may change — check https://docs.anthropic.com/claude-code

# Store API key in deploy user's environment (NOT in app .env)
echo 'export ANTHROPIC_API_KEY="sk-ant-..."' >> /home/deploy/.bashrc

# Verify
source ~/.bashrc
claude --version
```

---

## 10. Execution Order Summary

Run these phases sequentially. Each phase should complete without errors before proceeding.

| Phase | What | Estimated Time |
|-------|------|---------------|
| 1 | System hardening (SSH, firewall, fail2ban, updates) | 10 min |
| 2 | Runtime installation (PG, Redis, Ruby, Node, Nginx) | 20 min |
| 3 | Application setup (dirs, clone, env files, initial deploy) | 15 min |
| 4 | Nginx configuration (prod + staging sites) | 5 min |
| 5 | systemd service units (Falcon, GoodJob, enable/start) | 5 min |
| 6 | Backup automation (script + timer) | 5 min |
| 7 | Health check + log rotation | 5 min |
| 8 | Cloudflare IP update script | 2 min |
| 9 | Claude Code installation | 5 min |
| **Total** | | **~70 min** |

---

## 11. Verification After All Phases

```bash
# Services running
systemctl is-active dailywerk-prod-falcon dailywerk-prod-worker \
  dailywerk-staging-falcon dailywerk-staging-worker \
  postgresql redis-server nginx

# Timers active
systemctl list-timers | grep dailywerk

# Firewall
sudo ufw status

# Health check
/opt/dailywerk/scripts/healthcheck.sh
cat /var/log/dailywerk/alerts.log  # Should be empty or minimal

# Endpoints
curl -sf http://localhost:3000/up   # Production
curl -sf http://localhost:3100/up   # Staging

# External (after DNS propagation)
curl -sf https://app.dailywerk.com/up
curl -sf https://staging.dailywerk.com/up
```
