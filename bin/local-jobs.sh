#!/usr/bin/env bash
# Unified CLI for locally scheduled launchd jobs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<USAGE
Usage: local-jobs.sh <command> [options]

Commands (aliases in parentheses):
  view-jobs (view)       List managed instances + discovered com.kleinperkins.* agents
  add-job (add)          Add a job instance
  update-job (update)    Update schedule and/or enabled state
  delete-job (delete)    Remove a job instance (requires --confirm)
  repair-job (repair)    Idempotent repair for one or all managed jobs
  enable-job (enable)    Enable a job instance
  disable-job (disable)  Disable a job instance (keeps config)
  doctor                 Run health checks for managed backends

add-job:
  --type <job-type> --id <id> [type-specific options]
  incremental-git-fetch: --path <path> --branch <branch> [--schedule inherit|HH:MM] [--enabled true|false]

update-job:
  --id <id> [--schedule HH:MM|inherit] [--enabled true|false]
  --id __global__ --schedule HH:MM   (incremental-git-fetch global window start)

delete-job:
  --id <id> --confirm [--purge-launchd]   (incremental-git-fetch per-repo agents)

repair-job:
  [--id <id>] [--all]

Global options:
  --json                 JSON output (view-jobs)
  --type <job-type>      Required for add-job; optional hint for repair
USAGE
}

normalize_cmd() {
  case "${1:-}" in
    view|view-jobs) printf 'view' ;;
    add|add-job) printf 'add' ;;
    update|update-job) printf 'update' ;;
    delete|delete-job) printf 'delete' ;;
    repair|repair-job) printf 'repair' ;;
    enable|enable-job) printf 'enable' ;;
    disable|disable-job) printf 'disable' ;;
    doctor) printf 'doctor' ;;
    ""|-h|--help|help) printf 'help' ;;
    *) printf '%s' "$1" ;;
  esac
}

invoke_handler() {
  local job_type="$1"
  shift
  local handler
  handler="$(require_handler "$job_type")"
  "$handler" "$@"
}

dispatch_handler() {
  invoke_handler "$@"
}

cmd_view() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      *) die "unknown view option: $1" ;;
    esac
    shift
  done
  if (( json == 1 )); then
    registry_py view --json
  else
    registry_py view
  fi
}

cmd_add() {
  local job_type="" id="" path="" branch="" schedule="inherit" enabled="true"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) shift; job_type="${1:-}" ;;
      --id) shift; id="${1:-}" ;;
      --path) shift; path="${1:-}" ;;
      --branch) shift; branch="${1:-}" ;;
      --schedule) shift; schedule="${1:-}" ;;
      --enabled) shift; enabled="${1:-}" ;;
      *) die "unknown add option: $1" ;;
    esac
    shift
  done
  [[ -n "$job_type" ]] || die "add-job requires --type"
  case "$job_type" in
    incremental-git-fetch)
      [[ -n "$id" && -n "$path" && -n "$branch" ]] || die "incremental-git-fetch add requires --id --path --branch"
      dispatch_handler "$job_type" add --id "$id" --path "$path" --branch "$branch" \
        --schedule "$schedule" --enabled "$enabled"
      ;;
    cpp-archive)
      [[ -z "$id" || "$id" == "cpp-archive" ]] || die "cpp-archive is a singleton (id: cpp-archive)"
      dispatch_handler "$job_type" add
      ;;
    *)
      die "unknown job type: $job_type"
      ;;
  esac
}

cmd_update() {
  local id="" schedule="" enabled="" job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --schedule) shift; schedule="${1:-}" ;;
      --enabled) shift; enabled="${1:-}" ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "update-job requires --id"
  if [[ -z "$job_type" ]]; then
    job_type="$(resolve_instance_type "$id")"
  fi
  local args=(update --id "$id")
  [[ -n "$schedule" ]] && args+=(--schedule "$schedule")
  [[ -n "$enabled" ]] && args+=(--enabled "$enabled")
  dispatch_handler "$job_type" "${args[@]}"
}

cmd_delete() {
  local id="" confirm=0 purge=0 job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --confirm) confirm=1 ;;
      --purge-launchd) purge=1 ;;
      *) die "unknown delete option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "delete-job requires --id"
  (( confirm == 1 )) || die "delete-job requires --confirm"
  if [[ -z "$job_type" ]]; then
    job_type="$(resolve_instance_type "$id")"
  fi
  local args=(delete --id "$id" --confirm)
  (( purge == 1 )) && args+=(--purge-launchd)
  dispatch_handler "$job_type" "${args[@]}"
}

cmd_repair() {
  local id="" all=0 job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --all) all=1 ;;
      *) die "unknown repair option: $1" ;;
    esac
    shift
  done
  if (( all == 1 )); then
    dispatch_handler incremental-git-fetch repair --all
    dispatch_handler cpp-archive repair
    return 0
  fi
  if [[ -n "$id" ]]; then
    [[ -z "$job_type" ]] && job_type="$(resolve_instance_type "$id")"
    dispatch_handler "$job_type" repair --id "$id"
    return 0
  fi
  die "repair-job requires --id or --all"
}

cmd_enable() {
  local id="" job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      *) die "unknown enable option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "enable-job requires --id"
  [[ -z "$job_type" ]] && job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" enable --id "$id"
}

cmd_disable() {
  local id="" job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      *) die "unknown disable option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "disable-job requires --id"
  [[ -z "$job_type" ]] && job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" disable --id "$id"
}

cmd_doctor() {
  local failed=0
  for t in incremental-git-fetch cpp-archive; do
    printf '\n== doctor: %s ==\n' "$t"
    if ! invoke_handler "$t" doctor; then
      failed=1
    fi
  done
  return "$failed"
}

main() {
  local verb
  verb="$(normalize_cmd "${1:-}")"
  shift || true
  case "$verb" in
    help)
      usage
      ;;
    view) cmd_view "$@" ;;
    add) cmd_add "$@" ;;
    update) cmd_update "$@" ;;
    delete) cmd_delete "$@" ;;
    repair) cmd_repair "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    doctor) cmd_doctor "$@" ;;
    *)
      die "unknown command: $verb"
      ;;
  esac
}

main "$@"
