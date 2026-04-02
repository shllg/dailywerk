#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_command docker
require_command jq

payload_source="${1:-/dev/stdin}"
root="$(dailywerk_root)"
lock_file="${root}/runtime/deploy.lock"
mkdir -p "$(dirname "${lock_file}")"
exec 9>"${lock_file}"
flock -n 9

payload="$(cat "${payload_source}")"
environment="$(printf '%s' "${payload}" | jq -r '.environment')"
api_image="$(printf '%s' "${payload}" | jq -r '.api_image')"
frontend_image="$(printf '%s' "${payload}" | jq -r '.frontend_image')"
build_sha="$(printf '%s' "${payload}" | jq -r '.build_sha')"
build_ref="$(printf '%s' "${payload}" | jq -r '.build_ref // empty')"

slot="$(inactive_slot "${environment}")"
project="$(project_name "${environment}" "${slot}")"
app_slot_compose="${APP_SLOT_COMPOSE_FILE:-/deploy/compose/app-slot.yml}"
previous_slot="$(current_slot "${environment}")"

on_error() {
  if [[ -n "${build_sha}" ]]; then
    "${SCRIPT_DIR}/annotate-deploy.sh" "${environment}" "${slot}" "${build_sha}" "failure" "${api_image}" || true
  fi
}

trap on_error ERR

BUILD_SHA="${build_sha}" BUILD_REF="${build_ref}" "${SCRIPT_DIR}/render-env.sh" "${environment}" "${slot}"

APP_ENVIRONMENT="${environment}" \
APP_ENV_FILE="$(app_env_file "${environment}" "${slot}")" \
API_IMAGE="${api_image}" \
FRONTEND_IMAGE="${frontend_image}" \
WORKSPACE_ROOT="$(workspace_root "${environment}")" \
BUILD_SHA="${build_sha}" \
BUILD_REF="${build_ref}" \
docker compose -p "${project}" -f "${app_slot_compose}" pull frontend api worker

"${SCRIPT_DIR}/run-migrations.sh" "${environment}" "${slot}" "${api_image}" "${frontend_image}" "${build_sha}" "${build_ref}"

APP_ENVIRONMENT="${environment}" \
APP_ENV_FILE="$(app_env_file "${environment}" "${slot}")" \
API_IMAGE="${api_image}" \
FRONTEND_IMAGE="${frontend_image}" \
WORKSPACE_ROOT="$(workspace_root "${environment}")" \
BUILD_SHA="${build_sha}" \
BUILD_REF="${build_ref}" \
docker compose -p "${project}" -f "${app_slot_compose}" up -d

for _attempt in $(seq 1 30); do
  if docker compose -p "${project}" -f "${app_slot_compose}" exec -T api /rails/docker/api/ready >/dev/null 2>&1; then
    break
  fi

  sleep 2
done

docker compose -p "${project}" -f "${app_slot_compose}" exec -T api /rails/docker/api/ready >/dev/null 2>&1
"${SCRIPT_DIR}/switch-slot.sh" "${environment}" "${slot}"
"${SCRIPT_DIR}/annotate-deploy.sh" "${environment}" "${slot}" "${build_sha}" "success" "${api_image}"

sleep 10

APP_ENVIRONMENT="${environment}" \
APP_ENV_FILE="$(app_env_file "${environment}" "${previous_slot}")" \
API_IMAGE="${api_image}" \
FRONTEND_IMAGE="${frontend_image}" \
WORKSPACE_ROOT="$(workspace_root "${environment}")" \
BUILD_SHA="${build_sha}" \
BUILD_REF="${build_ref}" \
docker compose -p "$(project_name "${environment}" "${previous_slot}")" -f "${app_slot_compose}" stop frontend api worker || true
