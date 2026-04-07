#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# perform-deploy.sh — Blue/green deploy orchestrator
#
# Usage: perform-deploy.sh <payload.json>
#
# Reads the webhook payload, determines the inactive slot, renders the env,
# pulls images, runs migrations, starts the slot, waits for /ready, switches
# Nginx, annotates Grafana, and stops the old slot.
#
# Locking: Uses flock's re-exec pattern so the lock fd is never inherited by
# child processes (prevents op daemon from holding the lock forever).
# ---------------------------------------------------------------------------

readonly RUNTIME_DIR="/srv/dailywerk/runtime"
readonly COMPOSE_DIR="/srv/dailywerk/compose"
readonly LOCK_FILE="${RUNTIME_DIR}/deploy.lock"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Flock re-exec guard ───────────────────────────────────────────────────
# On first invocation, re-exec under flock. The --locked flag tells us we
# already hold the lock on re-entry so we don't loop.
if [[ "${1:-}" != "--locked" ]]; then
  exec /usr/bin/flock -n "${LOCK_FILE}" "$0" --locked "$@"
fi
shift  # remove --locked

# ── Parse payload ─────────────────────────────────────────────────────────
readonly PAYLOAD_PATH="${1:?Usage: perform-deploy.sh <payload.json>}"

readonly ENVIRONMENT="$(jq -r '.environment' "${PAYLOAD_PATH}")"
readonly API_IMAGE="$(jq -r '.api_image' "${PAYLOAD_PATH}")"
readonly FRONTEND_IMAGE="$(jq -r '.frontend_image' "${PAYLOAD_PATH}")"
readonly BUILD_SHA="$(jq -r '.build_sha' "${PAYLOAD_PATH}")"
readonly BUILD_REF="$(jq -r '.build_ref' "${PAYLOAD_PATH}")"

if [[ -z "${ENVIRONMENT}" || -z "${API_IMAGE}" || -z "${FRONTEND_IMAGE}" ]]; then
  echo "ERROR: payload missing required fields" >&2
  exit 1
fi

case "${ENVIRONMENT}" in
  production|staging) ;;
  *)
    echo "ERROR: unknown environment: ${ENVIRONMENT}" >&2
    exit 1
    ;;
esac

# ── Determine slots ──────────────────────────────────────────────────────
readonly SLOT_FILE="${RUNTIME_DIR}/${ENVIRONMENT}-active-slot"
ACTIVE_SLOT="$(cat "${SLOT_FILE}" 2>/dev/null || echo "blue")"

if [[ "${ACTIVE_SLOT}" == "blue" ]]; then
  INACTIVE_SLOT="green"
else
  INACTIVE_SLOT="blue"
fi

readonly ACTIVE_SLOT INACTIVE_SLOT
readonly PROJECT="dailywerk-${ENVIRONMENT}-${INACTIVE_SLOT}"
readonly SLOT_COMPOSE="${COMPOSE_DIR}/${ENVIRONMENT}-${INACTIVE_SLOT}/docker-compose.yml"

echo "━━━ Deploy: ${ENVIRONMENT} ${ACTIVE_SLOT} → ${INACTIVE_SLOT} (${BUILD_SHA:0:12}) ━━━"

# ── Render env ────────────────────────────────────────────────────────────
echo "→ Rendering environment for ${ENVIRONMENT}/${INACTIVE_SLOT}..."
"${SCRIPT_DIR}/render-env.sh" \
  "${ENVIRONMENT}" \
  "${INACTIVE_SLOT}" \
  "${API_IMAGE}" \
  "${FRONTEND_IMAGE}" \
  "${BUILD_SHA}" \
  "${BUILD_REF}"

# ── Pull images ──────────────────────────────────────────────────────────
echo "→ Pulling images..."
docker compose -p "${PROJECT}" -f "${SLOT_COMPOSE}" pull

# ── Run migrations ───────────────────────────────────────────────────────
echo "→ Running migrations..."
docker compose -p "${PROJECT}" -f "${SLOT_COMPOSE}" \
  run --rm --no-deps api /rails/docker/api/migrate

# ── Start inactive slot ──────────────────────────────────────────────────
echo "→ Starting ${PROJECT}..."
docker compose -p "${PROJECT}" -f "${SLOT_COMPOSE}" up -d

# ── Wait for /ready ──────────────────────────────────────────────────────
echo "→ Waiting for readiness..."
readonly MAX_WAIT=120
readonly INTERVAL=2
elapsed=0

while (( elapsed < MAX_WAIT )); do
  if docker compose -p "${PROJECT}" -f "${SLOT_COMPOSE}" \
       exec -T api curl -fsS http://localhost:3000/ready >/dev/null 2>&1; then
    echo "  ✓ Slot ${INACTIVE_SLOT} is ready (${elapsed}s)"
    break
  fi
  sleep "${INTERVAL}"
  (( elapsed += INTERVAL ))
done

if (( elapsed >= MAX_WAIT )); then
  echo "ERROR: slot ${INACTIVE_SLOT} did not become ready within ${MAX_WAIT}s" >&2
  echo "→ Stopping failed slot..."
  docker compose -p "${PROJECT}" -f "${SLOT_COMPOSE}" down
  exit 1
fi

# ── Switch Nginx ─────────────────────────────────────────────────────────
echo "→ Switching Nginx to ${INACTIVE_SLOT}..."
"${SCRIPT_DIR}/switch-slot.sh" "${ENVIRONMENT}" "${INACTIVE_SLOT}"

# ── Verify public health ────────────────────────────────────────────────
echo "→ Verifying public health..."
if [[ "${ENVIRONMENT}" == "production" ]]; then
  HEALTH_URL="https://app.dailywerk.com/ready"
else
  HEALTH_URL="https://staging.dailywerk.com/ready"
fi

if ! curl -fsS --max-time 10 "${HEALTH_URL}" >/dev/null 2>&1; then
  echo "WARNING: public health check failed — consider rollback" >&2
fi

# ── Grafana annotation ───────────────────────────────────────────────────
GRAFANA_API_KEY="${GRAFANA_API_KEY:-}"

if [[ -z "${GRAFANA_API_KEY}" && -n "${GRAFANA_API_KEY_OP_PATH:-}" ]]; then
  GRAFANA_API_KEY="$(op read "${GRAFANA_API_KEY_OP_PATH}" 2>/dev/null || true)"
fi

if [[ -n "${GRAFANA_API_KEY}" ]]; then
  echo "→ Annotating Grafana..."
  GRAFANA_URL="${GRAFANA_URL:-http://grafana:3000}"
  NOW_MS="$(date +%s%3N)"

  curl -fsS -X POST "${GRAFANA_URL}/api/annotations" \
    -H "Authorization: Bearer ${GRAFANA_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --argjson time "${NOW_MS}" \
      --arg env "${ENVIRONMENT}" \
      --arg slot "${INACTIVE_SLOT}" \
      --arg sha "${BUILD_SHA}" \
      --arg ref "${BUILD_REF}" \
      '{
        time: $time,
        tags: ["deploy", $env, $slot],
        text: "Deploy \($env) → \($slot) (\($sha[0:12])) ref=\($ref)"
      }'
    )" >/dev/null 2>&1 || echo "  WARNING: Grafana annotation failed (non-fatal)"
fi

# ── Stop old slot ────────────────────────────────────────────────────────
OLD_PROJECT="dailywerk-${ENVIRONMENT}-${ACTIVE_SLOT}"
OLD_COMPOSE="${COMPOSE_DIR}/${ENVIRONMENT}-${ACTIVE_SLOT}/docker-compose.yml"

echo "→ Stopping old slot (${ACTIVE_SLOT}) after grace period..."
sleep 10
docker compose -p "${OLD_PROJECT}" -f "${OLD_COMPOSE}" down || true

# ── Done ─────────────────────────────────────────────────────────────────
echo "━━━ Deploy complete: ${ENVIRONMENT} is now on ${INACTIVE_SLOT} (${BUILD_SHA:0:12}) ━━━"
