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
  dashboard              Rich status payload (--json, --brief for plain-English summary)
  explain-job            Narrative troubleshooting for one job (--id <id> [--type])
  resolve-instance       Fuzzy job discovery (--query <text> [--json])
  list-types (types)     Job type catalog (--plain human, --json schemas)
  describe-types         Machine-readable type+schema superset as JSON (feeds job-builder canvas)
  add-job (add)          Add a job instance (--type <t> --id <id> [type-specific flags])
  update-job (update)    Update schedule and/or enabled state
  delete-job (delete)    Remove a job instance (requires --confirm)
  run-job (run)          Run a job now (--id <id> | --all) [--dry-run]
  logs-job (logs)        Show log paths + tails (--id <id> [--tail N])
  repair-job (repair)    Idempotent repair for one or all managed jobs
  enable-job (enable)    Enable a job instance
  disable-job (disable)  Disable a job instance (keeps config)
  pause-job (pause)      Alias for disable-job
  resume-job (resume)    Alias for enable-job
  adopt-job (adopt)      Import an installed LaunchAgent as a managed command job
  add-job-type           Scaffold + register + verify a new ABI-conformant type
  update-job-type        Migrate a type's instances forward (verify + regression)
  doctor                 Run health checks (--plain for operator narrative)

Global options:
  --json                 JSON output (view-jobs, dashboard, resolve-instance, explain-job)
  --type <job-type>      Required for add-job; optional hint elsewhere

Run 'list-types --plain' or 'add-job --type <t>' flags via registry add_schema (see ABI.md).
USAGE
}

normalize_cmd() {
  case "${1:-}" in
    view|view-jobs) printf 'view' ;;
    dashboard) printf 'dashboard' ;;
    explain-job|explain) printf 'explain-job' ;;
    resolve-instance|resolve-job|resolve) printf 'resolve-instance' ;;
    list-types|types|job-types) printf 'list-types' ;;
    describe-types) printf 'describe-types' ;;
    add|add-job) printf 'add' ;;
    update|update-job) printf 'update' ;;
    delete|delete-job) printf 'delete' ;;
    run|run-job) printf 'run' ;;
    logs|logs-job) printf 'logs' ;;
    repair|repair-job) printf 'repair' ;;
    enable|enable-job|resume|resume-job) printf 'enable' ;;
    disable|disable-job|pause|pause-job) printf 'disable' ;;
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
  local json=0 brief=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --brief) brief=1 ;;
      *) die "unknown dashboard option: $1" ;;
    esac
    shift
  done
  if (( brief == 1 )); then registry_py dashboard --brief
  elif (( json == 1 )); then registry_py dashboard --json
  else registry_py dashboard; fi
}

cmd_explain_job() {
  local id="" job_type="" json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --type) shift; job_type="${1:-}" ;;
      --json) json=1 ;;
      *) die "unknown explain-job option: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || die "explain-job requires --id"
  local args=(explain-job --id "$id")
  [[ -n "$job_type" ]] && args+=(--type "$job_type")
  (( json == 1 )) && args+=(--json)
  registry_py "${args[@]}"
}

cmd_resolve_instance() {
  local query="" json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --query) shift; query="${1:-}" ;;
      --json) json=1 ;;
      *) die "unknown resolve-instance option: $1" ;;
    esac
    shift
  done
  [[ -n "$query" ]] || die "resolve-instance requires --query"
  local args=(resolve-instance --query "$query")
  (( json == 1 )) && args+=(--json)
  registry_py "${args[@]}"
}

cmd_list_types() {
  local plain=0 json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plain) plain=1 ;;
      --json) json=1 ;;
      *) die "unknown list-types option: $1" ;;
    esac
    shift
  done
  if (( json == 1 )); then registry_py list-types --json
  else registry_py list-types --plain; fi
}

cmd_describe_types() {
  # Machine-readable superset (schema_version + update-field matrix); always JSON.
  while [[ $# -gt 0 ]]; do case "$1" in --json) ;; *) die "unknown describe-types option: $1" ;; esac; shift; done
  registry_py describe-types --json
}

cmd_add() {
  local job_type="" id="" dry=0 passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) shift; job_type="${1:-}" ;;
      --id) shift; id="${1:-}"; passthrough+=(--id "$id") ;;
      --dry-run) dry=1; passthrough+=(--dry-run) ;;
      --*) # generic flag passthrough; consume an optional value
        local flag="$1"
        if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift; passthrough+=("$flag" "$1"); else passthrough+=("$flag"); fi
        ;;
      *) die "unknown add token: $1" ;;
    esac
    shift
  done
  [[ -n "$job_type" ]] || die "add-job requires --type"
  if [[ -n "$id" && $dry -eq 0 ]]; then
    local resolved rc=0
    resolved="$(registry_py instance-type --id "$id" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      die "id '$id' already exists under type '$resolved'; ids must be globally unique (use update-job to change it, or pick a new id)"
    elif [[ "$resolved" == *"ambiguous id"* ]]; then
      die "id '$id' already exists ($resolved)"
    fi
  fi
  local schema missing_json
  schema="$(registry_py add-schema --type "$job_type")"
  missing_json="$("$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/contract.py" missing-required --schema "$schema" -- "${passthrough[@]}" 2>&1)" || {
    if [[ -n "$missing_json" && "$missing_json" == \[* ]]; then
      local msg
      msg="$("$LOCAL_JOBS_PYTHON" - "$missing_json" <<'PY'
import json, sys
m = json.loads(sys.argv[1])
print("; ".join(f"{x['flag']} ({x['help']})" for x in m))
PY
)"
      die "add-job --type $job_type missing required flags: $msg"
    fi
    [[ -n "$missing_json" ]] && die "add-job --type $job_type missing required flags: $missing_json"
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
  local plain=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plain) plain=1 ;;
      *) die "unknown doctor option: $1" ;;
    esac
    shift
  done
  local failed=0 t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    printf '\n== doctor: %s ==\n' "$t"
    dispatch_handler "$t" doctor || failed=1
  done < <(registry_py job-types)
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
  if (( plain == 1 )); then
    printf '\n== operator summary ==\n'
    registry_py dashboard --brief || true
    for inst in $(printf '%s' "$dash_json" | "$LOCAL_JOBS_PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i["id"] for i in d["instances"] if i.get("drift")))'); do
      [[ -n "$inst" ]] || continue
      registry_py explain-job --id "$inst" 2>/dev/null || true
    done
  fi
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
    explain-job) cmd_explain_job "$@" ;;
    resolve-instance) cmd_resolve_instance "$@" ;;
    list-types) cmd_list_types "$@" ;;
    describe-types) cmd_describe_types "$@" ;;
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
