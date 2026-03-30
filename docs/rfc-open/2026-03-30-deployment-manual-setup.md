---
type: rfc
title: "Deployment — Manual Setup Steps"
created: 2026-03-30
updated: 2026-03-30
status: draft
implements:
  - prd/06-deployment-hetzner
phase: 1
---

# RFC: Deployment — Manual Setup Steps

## Context

Some deployment steps require human judgment, account creation, or access to web dashboards that cannot be automated. This RFC lists everything the operator must do manually before and after the automated setup (see sibling RFC: Server Automation).

---

## 1. Hetzner — Server Provisioning

### 1.1 Create Server

1. Log into [Hetzner Cloud Console](https://console.hetzner.cloud)
2. Create new project: "DailyWerk"
3. Create server:
   - **Location**: Falkenstein (FSN1) or Nuremberg (NBG1)
   - **Image**: Ubuntu 24.04
   - **Type**: CPX41 (8 vCPU, 16 GB RAM, 240 GB NVMe) — or CPX31 to start smaller
   - **SSH Key**: Add your public key (Ed25519)
   - **Name**: `dailywerk-01`
   - **Backups**: Enable (adds ~20% cost, provides weekly snapshots)
4. Note the server's IPv4 address

### 1.2 Create Object Storage Bucket (Backups)

1. In Hetzner Cloud Console → Object Storage
2. Create bucket: `dailywerk-backups`
3. Location: same as server (FSN1)
4. Generate S3 credentials (access key + secret key)
5. Save credentials securely — needed for backup scripts

**Note**: The primary application S3 storage (Hetzner Object Storage for vault files) is a separate bucket with separate credentials.

### 1.3 Create Application Storage Bucket

1. Create bucket: `dailywerk-production`
2. Create bucket: `dailywerk-staging`
3. Generate S3 credentials (can reuse same access key pair)

---

## 2. Cloudflare — DNS & SSL

### 2.1 Add Domain

1. Log into [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Add site: `dailywerk.com` (or chosen domain)
3. Update nameservers at domain registrar to Cloudflare's

### 2.2 DNS Records

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `app` | `<server-ip>` | Proxied (orange cloud) |
| A | `staging` | `<server-ip>` | Proxied (orange cloud) |

### 2.3 SSL/TLS Settings

1. **SSL/TLS → Overview**: Set to **Full (Strict)**
2. **SSL/TLS → Origin Server**: Create Origin Certificate
   - Hostnames: `*.dailywerk.com, dailywerk.com`
   - Validity: 15 years
   - Key type: RSA (2048)
   - **Download both**: certificate (`.pem`) and private key (`.key`)
   - Save these files — you'll upload them to the server
3. **SSL/TLS → Origin Server**: Enable **Authenticated Origin Pulls**
   - Download [Cloudflare's CA certificate](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/zone-level/) for origin pull verification

### 2.4 Cloudflare Settings

Navigate through the Cloudflare dashboard and set:

| Section | Setting | Value |
|---------|---------|-------|
| SSL/TLS | Always Use HTTPS | On |
| SSL/TLS | Minimum TLS Version | 1.2 |
| Speed → Optimization | HTTP/2 | On |
| Network | WebSockets | On |
| Security → Settings | Security Level | Medium |
| Caching → Configuration | Browser Cache TTL | Respect Existing Headers |

---

## 3. GitHub — Repository Access

### 3.1 Deploy Key

1. On the server (after initial SSH), generate a deploy key:
   ```bash
   ssh-keygen -t ed25519 -C "dailywerk-deploy" -f ~/.ssh/deploy_key -N ""
   ```
2. In GitHub → Settings → Deploy Keys → Add deploy key
   - Title: `dailywerk-server`
   - Key: contents of `~/.ssh/deploy_key.pub`
   - Allow write access: **No** (read-only)

### 3.2 Webhook (if using webhook deploys)

1. In GitHub → Settings → Webhooks → Add webhook
   - Payload URL: `https://app.dailywerk.com/deploy-webhook` (or a non-standard port)
   - Content type: `application/json`
   - Secret: generate a strong random secret, save it
   - Events: Just the push event
   - Active: Yes

### 3.3 Branch Protection (Optional)

For `master`:
- Require pull request reviews before merging
- Require status checks to pass (when CI is set up)

---

## 4. WorkOS — Auth Configuration

### 4.1 Create Application

1. Log into [WorkOS Dashboard](https://dashboard.workos.com)
2. Create application or use existing one
3. Configure redirect URIs:
   - `https://app.dailywerk.com/auth/callback`
   - `https://staging.dailywerk.com/auth/callback`
4. Note: API Key, Client ID

### 4.2 Auth Methods

Enable desired auth methods:
- Magic Links (email)
- Social login (Google, GitHub — as needed)
- SSO (if needed later)

---

## 5. Stripe — Payments Configuration

### 5.1 Account Setup

1. Log into [Stripe Dashboard](https://dashboard.stripe.com)
2. Complete account activation (business details, bank account)
3. Note API keys (publishable + secret) for both:
   - **Live mode** (production)
   - **Test mode** (staging)

### 5.2 Webhook Endpoint

1. Developers → Webhooks → Add endpoint
   - URL: `https://app.dailywerk.com/api/v1/webhooks/stripe`
   - Events: `customer.subscription.*`, `invoice.*`, `payment_intent.*`
2. Note the webhook signing secret
3. Repeat for staging with test mode keys

### 5.3 Products & Prices

Create subscription products and prices as defined in [PRD 04 §1](../prd/04-billing-and-operations.md#1-payments--stripe-integration). This is product-specific and should be done when billing is implemented.

---

## 6. Rails Credentials

### 6.1 Generate Production Credentials

```bash
EDITOR=nano rails credentials:edit --environment production
```

Add all secrets:

```yaml
secret_key_base: <generate with `rails secret`>

workos:
  api_key: wos_...
  client_id: client_...

stripe:
  secret_key: sk_live_...
  publishable_key: pk_live_...
  webhook_secret: whsec_...

openai:
  api_key: sk-...

hetzner_s3:
  access_key_id: ...
  secret_access_key: ...
  endpoint: https://fsn1.your-objectstorage.com

database:
  app_user_password: <generate strong password>
```

### 6.2 Transfer Master Key

The `config/credentials/production.key` file must be securely transferred to the server. Options:
- `scp` directly to the server
- Paste via SSH session
- Store in a password manager, retrieve on server

**Never commit the key file. Never transmit over unencrypted channels.**

---

## 7. Initial Server Access

### 7.1 First SSH

```bash
ssh root@<server-ip>
```

### 7.2 Create Deploy User

```bash
adduser --disabled-password deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

### 7.3 Verify Deploy User Access

```bash
# From local machine
ssh deploy@<server-ip>
sudo echo "sudo works"  # Should prompt for confirmation, not password
```

After verifying, disable root SSH login (done by automation RFC).

---

## 8. Upload Certificates to Server

```bash
# From local machine — transfer Cloudflare origin cert and key
scp origin.pem deploy@<server-ip>:/tmp/
scp origin-key.pem deploy@<server-ip>:/tmp/
scp authenticated_origin_pull_ca.pem deploy@<server-ip>:/tmp/

# On server — move to correct location
sudo mkdir -p /etc/ssl/cloudflare
sudo mv /tmp/origin.pem /etc/ssl/cloudflare/
sudo mv /tmp/origin-key.pem /etc/ssl/cloudflare/
sudo mv /tmp/authenticated_origin_pull_ca.pem /etc/ssl/cloudflare/
sudo chmod 600 /etc/ssl/cloudflare/origin-key.pem
sudo chmod 644 /etc/ssl/cloudflare/origin.pem /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem
```

---

## 9. Post-Automation Verification

After the server automation RFC scripts have run, manually verify:

1. [ ] SSH as `deploy` user works (not root)
2. [ ] `sudo` works for deploy user
3. [ ] `https://app.dailywerk.com/up` returns 200
4. [ ] `https://staging.dailywerk.com/up` returns 200
5. [ ] WebSocket connects (`wss://app.dailywerk.com/cable`)
6. [ ] PostgreSQL is running, both databases exist
7. [ ] Redis is running
8. [ ] Backups are scheduled (`systemctl list-timers`)
9. [ ] `ufw status` shows only expected ports
10. [ ] `fail2ban-client status` shows SSH jail active
11. [ ] SSL Labs test (via Cloudflare): A+ rating
12. [ ] GoodJob dashboard accessible (via admin auth)

---

## 10. Ongoing Manual Tasks

| Task | Frequency | Notes |
|------|-----------|-------|
| Hetzner billing review | Monthly | Verify costs in budget |
| Cloudflare security events | Weekly | Check for attack patterns |
| SSL certificate renewal | Never (15-year origin cert) | Monitor expiry date anyway |
| Ubuntu LTS upgrade | Every 2 years | 24.04 → 26.04 |
| Backup restore test | Quarterly | Restore to staging, verify data |
| Stripe webhook health | Monthly | Check for failed deliveries |
| Review server access logs | Weekly | Look for anomalies |
