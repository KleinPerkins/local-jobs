#!/usr/bin/env bash
# Unified, type-agnostic CLI for locally scheduled launchd jobs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<USAGE
Usage: local-jobs.sh <command> [options]

Commands (aliases in parentheses):
  view-jobs (view)       List managed instances + discovered com.kleinperkins.* agents
  dashboard              Rich status payload (use --json for the canvas feed)
  add-job (add)          Add a job instance (--type <t> --id <id> [type-specific flags])
  update-job (update)    Update schedule and/or enabled state
  delete-job (delete)    Remove a job instance (requires --confirm)
  run-job (run)          Run a job now (--id <id> | --all) [--dry-run]
  logs-job (logs)        Show log paths + tails (--id <id> [--tail N])
  repair-job (repair)    Idempotent repair for one or all managed jobs
  enable-job (enable)    Enable a job instance
  disable-job (disable)  Disable a job instance (keeps config)
  adopt-job (adopt)      Import an installed LaunchAgent as a managed command job
  add-job-type           Scaffold + register + verify a new ABI-conformant type
  update-job-type        Migrate a type's instances forward (verify + regression)
  doctor                 Run health checks across all registered types

Global options:
  --json                 JSON output (view-jobs, dashboard)
  --type <job-type>      Required for add-job; optional hint elsewhere

Run 'add-job --type <t>' flags via: registry add_schema (see ABI.md).
USAGE
}

normalize_cmd() {
  case "${1:-}" in
    view|view-jobs) printf 'view' ;;
    dashboard) printf 'dashboard' ;;
    add|add-job) printf 'add' ;;
    update|update-job) printf 'update' ;;
    delete|delete-job) printf 'delete' ;;
    run|run-job) printf 'run' ;;
    logs|logs-job) printf 'logs' ;;
    repair|repair-job) printf 'repair' ;;
    enable|enable-job) printf 'enable' ;;
    disable|disable-job) printf 'disable' ;;
    adopt|adopt-job) printf 'adopt' ;;
    add-job-type) printf 'add-job-type' ;;
    update-job-type) printf 'update-job-type' ;;
    doctor) printf 'doctor' ;;
    ""|-h|--help|help) printf 'help' ;;
    *) printf '%s' "$1" ;;
  esac
}

dispatch_handler() {
  local job_type="$1"; shift
  local handler
  handler="$(require_handler "$job_type")"
  "$handler" "$@"
}

cmd_view() {
  local json=0
  while [[ $# -gt 0 ]]; do case "$1" in --json) json=1 ;; *) die "unknown view option: $1" ;; esac; shift; done
  if (( json == 1 )); then registry_py view --json; else registry_py view; fi
}

cmd_dashboard() {
  local json=0
  while [[ $# -gt 0 ]]; do case "$1" in --json) json=1 ;; *) die "unknown dashboard option: $1" ;; esac; shift; done
  if (( json == 1 )); then registry_py dashboard --json; else registry_py dashboard; fi
}

cmd_add() {
  local job_type="" id="" passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) shift; job_type="${1:-}" ;;
      --id) shift; id="${1:-}"; passthrough+=(--id "$id") ;;
      --*) # generic flag passthrough; consume an optional value
        local flag="$1"
        if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift; passthrough+=("$flag" "$1"); else passthrough+=("$flag"); fi
        ;;
      *) die "unknown add token: $1" ;;
    esac
    shift
  done
  [[ -n "$job_type" ]] || die "add-job requires --type"
  # Global-uniqueness invariant: an explicit --id must not already resolve under
  # ANY type (instance ids are a global namespace). A genuinely-new id resolves
  # to "unknown instance" (nonzero) and is allowed; an existing — or already
  # ambiguous — id is rejected. Singletons pass no --id (their add is an upsert)
  # and are therefore exempt.
  if [[ -n "$id" ]]; then
    local resolved rc=0
    resolved="$(registry_py instance-type --id "$id" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      die "id '$id' already exists under type '$resolved'; ids must be globally unique (use update-job to change it, or pick a new id)"
    elif [[ "$resolved" == *"ambiguous id"* ]]; then
      die "id '$id' already exists ($resolved)"
    fi
  fi
  # Validate required flags from the handler's declared add_schema.
  local schema missing
  schema="$(registry_py add-schema --type "$job_type")"
  missing="$("$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/contract.py" missing-required --schema "$schema" -- "${passthrough[@]}" 2>&1)" || {
    [[ -n "$missing" ]] && die "add-job --type $job_type missing required flags: $missing"
    die "add-job --type $job_type: invalid flags"
  }
  dispatch_handler "$job_type" add "${passthrough[@]}"
}

cmd_update() {
  local id="" job_type="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}"; rest+=(--id "$id") ;;
      --type) shift; job_type="${1:-}" ;;
      --*) local flag="$1"; if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift; rest+=("$flag" "$1"); else rest+=("$flag"); fi ;;
      *) die "unknown update token: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "update-job requires --id"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" update "${rest[@]}"
}

cmd_delete() {
  local id="" job_type="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}"; rest+=(--id "$id") ;;
      --type) shift; job_type="${1:-}" ;;
      --confirm) rest+=(--confirm) ;;
      --purge-launchd) rest+=(--purge-launchd) ;;
      *) die "unknown delete option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "delete-job requires --id"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" delete "${rest[@]}"
}

cmd_run() {
  local id="" all=0 dry=0 job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --all) all=1 ;;
      --dry-run) dry=1 ;;
      *) die "unknown run option: $1" ;;
    esac
    shift
  done
  if (( all == 1 )); then
    local t
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      printf '\n== run: %s ==\n' "$t"
      "$SCRIPT_DIR/dispatch-run.sh" --type "$t" $([[ $dry -eq 1 ]] && printf -- '--dry-run') || true
    done < <(registry_py job-types)
    return 0
  fi
  [[ -n "$id" ]] || die "run-job requires --id or --all"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  local args=(--type "$job_type")
  [[ "$id" != "__global__" && "$id" != "all" ]] && args+=(--id "$id")
  (( dry == 1 )) && args+=(--dry-run)
  "$SCRIPT_DIR/dispatch-run.sh" "${args[@]}"
}

cmd_logs() {
  local id="" tail=40 job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --tail) shift; tail="${1:-40}" ;;
      *) die "unknown logs option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "logs-job requires --id"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" logs --id "$id" --tail "$tail"
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
    local t failed=0
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      printf '\n== repair: %s ==\n' "$t"
      dispatch_handler "$t" repair || failed=1
    done < <(registry_py job-types)
    return "$failed"
  fi
  [[ -n "$id" ]] || die "repair-job requires --id or --all"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" repair --id "$id"
}

cmd_simple() { # enable/disable
  local verb="$1"; shift
  local id="" job_type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      *) die "unknown $verb option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "$verb-job requires --id"
  [[ -n "$job_type" ]] || job_type="$(resolve_instance_type "$id")"
  dispatch_handler "$job_type" "$verb" --id "$id"
}

cmd_doctor() {
  local failed=0 t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    printf '\n== doctor: %s ==\n' "$t"
    dispatch_handler "$t" doctor || failed=1
  done < <(registry_py job-types)
  # Cross-type drift scan: surface (and record as drift events) any instance
  # whose loaded state disagrees with its enabled state, or any quarantined type.
  printf '\n== doctor: drift scan ==\n'
  local dash_json
  dash_json="$(registry_py dashboard --json)"
  DASH_JSON="$dash_json" LOCAL_JOBS_HOME="$LOCAL_JOBS_HOME" LOCAL_JOBS_PYTHON="$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_PYTHON" - <<'PY' || failed=1
import json, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ["LOCAL_JOBS_HOME"]) / "lib"))
import events  # noqa: E402
payload = json.loads(os.environ["DASH_JSON"])
issues = 0
for inst in payload.get("instances", []):
    if inst.get("role") == "error":
        issues += 1
        err = inst.get("error") or {}
        print(f"  QUARANTINED: {inst.get('type')} — {err.get('reason')}")
        events.emit("drift", job_type=inst.get("type"), payload={"kind": "quarantine", "reason": err.get("reason")})
        continue
    if inst.get("drift"):
        issues += 1
        print(f"  DRIFT: {inst.get('id')} ({inst.get('type')}) enabled={inst.get('enabled')} loaded={inst.get('launchd_loaded')}")
        events.emit("drift", job_id=inst.get("id"), job_type=inst.get("type"),
                    payload={"enabled": inst.get("enabled"), "loaded": inst.get("launchd_loaded")})
print("  no drift" if issues == 0 else f"  {issues} drift/quarantine issue(s)")
sys.exit(1 if issues else 0)
PY
  return "$failed"
}

main() {
  local verb
  verb="$(normalize_cmd "${1:-}")"
  shift || true
  case "$verb" in
    help) usage ;;
    view) cmd_view "$@" ;;
    dashboard) cmd_dashboard "$@" ;;
    add) cmd_add "$@" ;;
    update) cmd_update "$@" ;;
    delete) cmd_delete "$@" ;;
    run) cmd_run "$@" ;;
    logs) cmd_logs "$@" ;;
    repair) cmd_repair "$@" ;;
    enable) cmd_simple enable "$@" ;;
    disable) cmd_simple disable "$@" ;;
    adopt) "$SCRIPT_DIR/adopt-job.sh" "$@" ;;
    add-job-type) "$SCRIPT_DIR/add-job-type.sh" "$@" ;;
    update-job-type) "$SCRIPT_DIR/update-job-type.sh" "$@" ;;
    doctor) cmd_doctor "$@" ;;
    *) die "unknown command: $verb" ;;
  esac
}

main "$@"
