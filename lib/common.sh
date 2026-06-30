#!/usr/bin/env bash
# Shared helpers for the local-jobs framework.
set -euo pipefail

LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCAL_JOBS_REGISTRY="${LOCAL_JOBS_REGISTRY:-$LOCAL_JOBS_HOME/config/registry.yml}"
LOCAL_JOBS_STATE="${LOCAL_JOBS_STATE:-$HOME/.local-jobs}"
# Pin one interpreter for the whole framework (Phase 5). launchd plists export a
# PATH that puts the homebrew python3 (with PyYAML) first.
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"

log() {
  printf '[local-jobs] %s\n' "$*"
}

log_err() {
  printf '[local-jobs] ERROR: %s\n' "$*" >&2
}

die() {
  log_err "$*"
  exit "${LOCAL_JOBS_EXIT_CODE:-1}"
}

expand_path() {
  local raw="$1"
  case "$raw" in
    "~/"*) printf '%s\n' "${raw/#\~/$HOME}" ;;
    *) printf '%s\n' "$("$LOCAL_JOBS_PYTHON" -c 'import os,sys; print(os.path.expanduser(sys.argv[1]))' "$raw")" ;;
  esac
}

registry_py() {
  LOCAL_JOBS_REGISTRY="$LOCAL_JOBS_REGISTRY" \
  LOCAL_JOBS_HOME="$LOCAL_JOBS_HOME" \
    "$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/registry.py" "$@"
}

handler_for_type() {
  local job_type="$1"
  registry_py handler-path --type "$job_type"
}

resolve_instance_type() {
  local instance_id="$1"
  registry_py instance-type --id "$instance_id"
}

require_handler() {
  local job_type="$1"
  local handler
  handler="$(handler_for_type "$job_type")"
  [[ -x "$handler" ]] || die "handler not executable for type $job_type: $handler"
  printf '%s\n' "$handler"
}
