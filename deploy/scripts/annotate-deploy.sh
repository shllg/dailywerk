#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_command curl
require_command jq

environment="${1:?usage: annotate-deploy.sh <production|staging> <slot> <build-sha> <result> <image-ref>}"
slot="${2:?usage: annotate-deploy.sh <production|staging> <slot> <build-sha> <result> <image-ref>}"
build_sha="${3:-unknown}"
result="${4:-unknown}"
image_ref="${5:-unknown}"
grafana_url="${GRAFANA_URL:-http://grafana:3000}"
grafana_api_key="${GRAFANA_API_KEY:-}"

if [[ -z "${grafana_api_key}" && -n "${GRAFANA_API_KEY_OP_PATH:-}" ]]; then
  require_command op
  grafana_api_key="$(op read "${GRAFANA_API_KEY_OP_PATH}")"
fi

if [[ -z "${grafana_api_key}" ]]; then
  echo "Missing Grafana API key" >&2
  exit 1
fi

payload="$(jq -nc \
  --arg environment "${environment}" \
  --arg slot "${slot}" \
  --arg build_sha "${build_sha}" \
  --arg image_ref "${image_ref}" \
  --arg result "${result}" \
  --argjson time "$(($(date +%s) * 1000))" \
  '{
    time: $time,
    tags: ["deploy", $environment, $slot],
    text: ("Deploy " + $build_sha + " (" + $image_ref + ") to " + $environment + "/" + $slot + " - " + $result)
  }'
)"

curl -fsS -X POST "${grafana_url}/api/annotations" \
  -H "Authorization: Bearer ${grafana_api_key}" \
  -H "Content-Type: application/json" \
  -d "${payload}" >/dev/null
