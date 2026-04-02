#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_command docker

environment="${1:?usage: run-migrations.sh <production|staging> <blue|green> <api-image> <frontend-image> [build-sha] [build-ref]}"
slot="${2:?usage: run-migrations.sh <production|staging> <blue|green> <api-image> <frontend-image> [build-sha] [build-ref]}"
api_image="${3:?api image is required}"
frontend_image="${4:?frontend image is required}"
build_sha="${5:-}"
build_ref="${6:-}"

APP_ENVIRONMENT="${environment}" \
APP_ENV_FILE="$(app_env_file "${environment}" "${slot}")" \
API_IMAGE="${api_image}" \
FRONTEND_IMAGE="${frontend_image}" \
WORKSPACE_ROOT="$(workspace_root "${environment}")" \
BUILD_SHA="${build_sha}" \
BUILD_REF="${build_ref}" \
docker compose -p "$(project_name "${environment}" "${slot}")" -f "${APP_SLOT_COMPOSE_FILE:-/deploy/compose/app-slot.yml}" run --rm api /rails/docker/api/migrate
