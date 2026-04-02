#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_command op

environment="${1:?usage: render-env.sh <production|staging> <blue|green>}"
slot="${2:?usage: render-env.sh <production|staging> <blue|green>}"
slug="$(environment_slug "${environment}")"
root="$(dailywerk_root)"
target_file="$(app_env_file "${environment}" "${slot}")"
vault_name="DailyWerk Production"

if [[ "${environment}" == "staging" ]]; then
  vault_name="DailyWerk Staging"
fi

mkdir -p "$(dirname "${target_file}")"
umask 077

app_host="${APP_HOST_OVERRIDE:-$(default_host "${environment}")}"
good_job_enable_cron="${GOOD_JOB_ENABLE_CRON_OVERRIDE:-$(default_good_job_cron "${environment}")}"

cat > "${target_file}" <<EOF
RAILS_ENV=production
RAILS_MASTER_KEY=$(op read "op://${vault_name}/rails/master-key")
SECRET_KEY_BASE=$(op read "op://${vault_name}/rails/secret-key-base")
RAILS_LOG_LEVEL=${RAILS_LOG_LEVEL:-info}
RAILS_LOG_TO_STDOUT=true
APP_ENVIRONMENT=${environment}
APP_HOST=${app_host}
CORS_ORIGINS=https://${app_host}
ACTION_CABLE_ALLOWED_ORIGINS=https://${app_host}
DATABASE_URL=$(op read "op://${vault_name}/database/url")
DB_POOL=${DB_POOL:-10}
VALKEY_URL=$(op read "op://${vault_name}/valkey/url")
CACHE_NAMESPACE=dailywerk:${slug}:cache
CABLE_NAMESPACE=dailywerk:${slug}:cable
AWS_ACCESS_KEY_ID=$(op read "op://${vault_name}/storage/access-key-id")
AWS_SECRET_ACCESS_KEY=$(op read "op://${vault_name}/storage/secret-access-key")
AWS_ENDPOINT=$(op read "op://${vault_name}/storage/endpoint")
AWS_REGION=$(op read "op://${vault_name}/storage/region")
AWS_FORCE_PATH_STYLE=${AWS_FORCE_PATH_STYLE:-true}
S3_BUCKET=$(op read "op://${vault_name}/storage/bucket")
S3_REQUIRE_HTTPS_FOR_SSE_CPK=${S3_REQUIRE_HTTPS_FOR_SSE_CPK:-true}
VAULT_LOCAL_BASE=/data/workspaces
WORKOS_API_KEY=$(op read "op://${vault_name}/workos/api-key")
WORKOS_CLIENT_ID=$(op read "op://${vault_name}/workos/client-id")
STRIPE_SECRET_KEY=$(op read "op://${vault_name}/stripe/secret-key")
STRIPE_WEBHOOK_SECRET=$(op read "op://${vault_name}/stripe/webhook-secret")
STRIPE_PUBLISHABLE_KEY=$(op read "op://${vault_name}/stripe/publishable-key")
METRICS_ENABLED=true
METRICS_BASIC_AUTH_USERNAME=$(op read "op://${vault_name}/metrics/basic-auth-username")
METRICS_BASIC_AUTH_PASSWORD=$(op read "op://${vault_name}/metrics/basic-auth-password")
GOOD_JOB_ENABLE_CRON=${good_job_enable_cron}
BUILD_SHA=${BUILD_SHA:-}
BUILD_REF=${BUILD_REF:-}
EOF

if [[ -n "${OPENAI_API_KEY_OP_PATH:-}" ]]; then
  printf 'OPENAI_API_KEY=%s\n' "$(op read "${OPENAI_API_KEY_OP_PATH}")" >> "${target_file}"
fi
