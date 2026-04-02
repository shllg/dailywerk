#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_command docker

environment="${1:?usage: switch-slot.sh <production|staging> <blue|green>}"
target_slot="${2:?usage: switch-slot.sh <production|staging> <blue|green>}"
root="$(dailywerk_root)"
generated_dir="${root}/deploy/nginx/generated"
runtime_root="${root}/runtime"
edge_compose="${EDGE_COMPOSE_FILE:-/deploy/compose/edge.yml}"

mkdir -p "${generated_dir}" "${runtime_root}"

prod_slot="$(current_slot production)"
staging_slot="$(current_slot staging)"

if [[ "${environment}" == "production" ]]; then
  prod_slot="${target_slot}"
else
  staging_slot="${target_slot}"
fi

target_file="${generated_dir}/upstreams.conf"
backup_file="${target_file}.bak"
temp_file="${target_file}.tmp"

if [[ -f "${target_file}" ]]; then
  cp "${target_file}" "${backup_file}"
fi

cat > "${temp_file}" <<EOF
upstream prod_frontend {
  server $(project_name production "${prod_slot}")-frontend-1:8080;
}

upstream prod_api {
  server $(project_name production "${prod_slot}")-api-1:3000;
}

upstream staging_frontend {
  server $(project_name staging "${staging_slot}")-frontend-1:8080;
}

upstream staging_api {
  server $(project_name staging "${staging_slot}")-api-1:3000;
}
EOF

mv "${temp_file}" "${target_file}"

if ! docker compose -f "${edge_compose}" exec -T nginx nginx -t; then
  if [[ -f "${backup_file}" ]]; then
    mv "${backup_file}" "${target_file}"
  fi
  exit 1
fi

docker compose -f "${edge_compose}" exec -T nginx nginx -s reload
printf '%s\n' "${target_slot}" > "$(active_slot_file "${environment}")"
rm -f "${backup_file}"
