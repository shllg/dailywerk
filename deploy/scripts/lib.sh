#!/usr/bin/env bash
set -euo pipefail

dailywerk_root() {
  printf '%s\n' "${DAILYWERK_ROOT:-/srv/dailywerk}"
}

environment_slug() {
  case "$1" in
    production) printf '%s\n' "prod" ;;
    staging) printf '%s\n' "staging" ;;
    *)
      echo "Unsupported environment: $1" >&2
      return 1
      ;;
  esac
}

default_host() {
  case "$1" in
    production) printf '%s\n' "app.dailywerk.com" ;;
    staging) printf '%s\n' "staging.dailywerk.com" ;;
    *)
      echo "Unsupported environment: $1" >&2
      return 1
      ;;
  esac
}

default_good_job_cron() {
  case "$1" in
    production) printf '%s\n' "true" ;;
    staging) printf '%s\n' "false" ;;
    *)
      echo "Unsupported environment: $1" >&2
      return 1
      ;;
  esac
}

runtime_dir() {
  printf '%s/runtime\n' "$(dailywerk_root)"
}

active_slot_file() {
  printf '%s/%s-active-slot\n' "$(runtime_dir)" "$(environment_slug "$1")"
}

current_slot() {
  local marker
  marker="$(active_slot_file "$1")"

  if [[ -f "${marker}" ]]; then
    tr -d '[:space:]' < "${marker}"
  else
    printf '%s\n' "blue"
  fi
}

inactive_slot() {
  case "$(current_slot "$1")" in
    blue) printf '%s\n' "green" ;;
    green) printf '%s\n' "blue" ;;
    *)
      echo "Unsupported slot state" >&2
      return 1
      ;;
  esac
}

project_name() {
  printf 'dailywerk-%s-%s\n' "$(environment_slug "$1")" "$2"
}

app_env_file() {
  printf '%s/config/env/%s-%s.env\n' "$(dailywerk_root)" "$(environment_slug "$1")" "$2"
}

workspace_root() {
  printf '%s/data/%s\n' "$(dailywerk_root)" "$(environment_slug "$1")"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}
