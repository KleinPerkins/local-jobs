#!/usr/bin/env bash
# Handler plugin: incremental-git-fetch (first-class; local backend, ABI v1).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
BACKEND="$LOCAL_JOBS_HOME/backends/incremental-git-fetch"
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"
LOCAL_JOBS_IGF_CONFIG="${LOCAL_JOBS_IGF_CONFIG:-$LOCAL_JOBS_HOME/config/jobs/incremental-git-fetch.yml}"
export LOCAL_JOBS_HOME LOCAL_JOBS_IGF_CONFIG

LABEL_PREFIX="com.kleinperkins.local-jobs.git-fetch"
LOG_DIR="$HOME/Library/Logs/local-jobs"
OUT_LOG="$LOG_DIR/git-fetch.out.log"
ERR_LOG="$LOG_DIR/git-fetch.err.log"

die() { printf 'incremental-git-fetch: %s\n' "$*" >&2; exit 2; }

igf_config() {
  LOCAL_JOBS_IGF_CONFIG="$LOCAL_JOBS_IGF_CONFIG" "$LOCAL_JOBS_PYTHON" "$BACKEND/config.py" "$@"
}

# Best-effort lifecycle event (audit stream); never fails the verb.
igf_emit() { # verb id
  "$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/events.py" emit --kind lifecycle \
    --id "${2:-}" --type incremental-git-fetch --actor "${LOCAL_JOBS_ACTOR:-cli}" \
    --payload "{\"verb\":\"$1\"}" >/dev/null 2>&1 || true
}

[[ -f "$BACKEND/config.py" ]] || die "backend not found: $BACKEND"

usage() {
  cat <<USAGE
incremental-git-fetch handler verbs:
  describe list-instances view run logs add update delete repair enable disable doctor
USAGE
}

uid_domain() { printf 'gui/%s' "$(id -u)"; }
# Honor the hermetic disable flag and degrade gracefully when launchctl is
# absent (Linux CI), matching lib/launchd.py.
is_loaded() {
  [[ "${LOCAL_JOBS_LAUNCHD_DISABLE:-0}" == "1" ]] && return 1
  command -v launchctl >/dev/null 2>&1 || return 1
  launchctl print "$(uid_domain)/$1" >/dev/null 2>&1
}

parse_schedule() {
  local raw="$1"
  case "$raw" in
    inherit) printf 'inherit' ;;
    *:*) printf '%s:%s' "${raw%%:*}" "${raw#*:}" ;;
    *) die "invalid schedule (use inherit or HH:MM): $raw" ;;
  esac
}

cmd_describe() {
  "$LOCAL_JOBS_PYTHON" - "$LABEL_PREFIX" "$LOCAL_JOBS_IGF_CONFIG" <<'PY'
import json, sys
prefix, config = sys.argv[1], sys.argv[2]
print(json.dumps({
    "type": "incremental-git-fetch",
    "cardinality": "multi",
    "label_token": "git-fetch",
    "label_template": f"{prefix}[.<id>]",
    "config_file": config,
    "add_schema": [
        {"flag": "--id", "required": True, "help": "stable instance id"},
        {"flag": "--path", "required": True, "help": "repo path under ~/dev or absolute"},
        {"flag": "--branch", "required": True, "help": "branch to fetch"},
        {"flag": "--remote", "required": False, "help": "remote name (default origin)"},
        {"flag": "--schedule", "required": False, "help": "inherit | HH:MM"},
        {"flag": "--enabled", "required": False, "help": "true | false"},
    ],
}, indent=2))
PY
}

cmd_list_instances() {
  local view loaded_global
  view="$(igf_config view)"
  loaded_global=false
  is_loaded "$LABEL_PREFIX" && loaded_global=true
  GLOBAL_LOADED="$loaded_global" PREFIX="$LABEL_PREFIX" OUT_LOG="$OUT_LOG" ERR_LOG="$ERR_LOG" VIEW="$view" \
    "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess

view = json.loads(os.environ["VIEW"])
prefix = os.environ["PREFIX"]
out_log = os.environ["OUT_LOG"]
err_log = os.environ["ERR_LOG"]
global_loaded = os.environ["GLOBAL_LOADED"] == "true"
uid = os.getuid()

def loaded(label):
    if os.environ.get("LOCAL_JOBS_LAUNCHD_DISABLE", "0") == "1":
        return False
    try:
        return subprocess.run(["launchctl", "print", f"gui/{uid}/{label}"],
                              capture_output=True).returncode == 0
    except FileNotFoundError:  # no launchctl (e.g. Linux CI)
        return False

g = view.get("global") or {}
launchd = g.get("launchd") or {}
instances = [{
    "id": "__global__",
    "type": "incremental-git-fetch",
    "role": "global_scheduler",
    "enabled": True,
    "schedule": {
        "window_start_hour": launchd.get("window_start_hour", 18),
        "window_end_hour": launchd.get("window_end_hour", 24),
        "use_jitter": launchd.get("use_jitter", True),
    },
    "schedule_summary": g.get("schedule_summary"),
    "launchd_label": prefix,
    "launchd_loaded": global_loaded,
    "log_paths": {"stdout": out_log, "stderr": err_log},
}]

for repo in view.get("repos") or []:
    schedule = repo.get("schedule") or "inherit"
    label = prefix if schedule == "inherit" else f"{prefix}.{repo['id']}"
    instances.append({
        "id": repo["id"],
        "type": "incremental-git-fetch",
        "role": "instance",
        "enabled": repo.get("enabled", True),
        "schedule": schedule,
        "path": repo.get("path"),
        "remote": repo.get("remote", "origin"),
        "branch": repo.get("branch", "main"),
        "head": (repo.get("git") or {}).get("head"),
        "launchd_label": label,
        "launchd_loaded": global_loaded if schedule == "inherit" else loaded(label),
        "log_paths": {"stdout": out_log, "stderr": err_log},
        "last_run_hint": repo.get("last_run_hint"),
    })

print(json.dumps(instances, indent=2))
PY
}

cmd_view() {
  local id="$1"
  [[ -n "$id" ]] || die "view requires --id"
  local list
  list="$(cmd_list_instances)"
  LIST="$list" TARGET="$id" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, sys
target = os.environ["TARGET"]
for inst in json.loads(os.environ["LIST"]):
    if inst.get("id") == target:
        print(json.dumps(inst, indent=2)); break
else:
    sys.exit(f"unknown instance: {target}")
PY
}

# Snapshot head + behind-count for a set of repos. Prints JSON {id: {head,behind}}.
snapshot() {
  local view
  view="$(igf_config view)"
  VIEW="$view" TARGET="$1" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess
target = os.environ["TARGET"]  # "" = all enabled
view = json.loads(os.environ["VIEW"])
out = {}
for repo in view.get("repos") or []:
    if target and repo["id"] != target:
        continue
    if not target and not repo.get("enabled", True):
        continue
    path = repo["path"]
    remote = repo.get("remote", "origin")
    branch = repo.get("branch", "main")
    def git(*a):
        return subprocess.run(["git", "-C", path, *a], capture_output=True, text=True).stdout.strip()
    head = git("rev-parse", "--short", "HEAD")
    behind = git("rev-list", "--count", f"HEAD..{remote}/{branch}")
    out[repo["id"]] = {"head": head, "behind": behind if behind.isdigit() else None}
print(json.dumps(out))
PY
}

cmd_run() {
  local id="" dry=0 jitter=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --dry-run) dry=1 ;;
      --jitter) jitter=1 ;;
      --all) id="" ;;
      *) die "unknown run option: $1" ;;
    esac
    shift
  done
  [[ "$id" == "__global__" || "$id" == "all" ]] && id=""

  local before after status="success" rc=0
  before="$(snapshot "$id")"

  local skip_jitter=1
  (( jitter == 1 )) && skip_jitter=0

  # A scheduled global run (jitter, no target) fetches only inherit repos so a
  # repo with its own per-repo agent is never fetched twice (P0-1).
  local inherit_only=0
  (( jitter == 1 )) && [[ -z "$id" ]] && inherit_only=1

  if LOCAL_JOBS_IGF_DRY_RUN="$dry" LOCAL_JOBS_IGF_SKIP_JITTER="$skip_jitter" \
       LOCAL_JOBS_IGF_INHERIT_ONLY="$inherit_only" \
       "$BACKEND/run-all.sh" ${id:+"$id"}; then
    rc=0
  else
    rc=$?
    status="failure"
  fi
  (( dry == 1 )) && status="dry-run"

  after="$(snapshot "$id")"

  # Emit one aggregate runlog record plus (for an all-repos run) one per_instance
  # record per repo so each repo's last-run is recorded — no more "never run"
  # for inherit repos that only ever ran inside the aggregate window (P1-C).
  BEFORE="$before" AFTER="$after" STATUS="$status" TARGET="${id:-all}" \
    "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
before = json.loads(os.environ["BEFORE"] or "{}")
after = json.loads(os.environ["AFTER"] or "{}")
status = os.environ["STATUS"]
target = os.environ["TARGET"]
repos = []
for rid in sorted(set(before) | set(after)):
    b = before.get(rid, {}); a = after.get(rid, {})
    repos.append({
        "id": rid,
        "head_before": b.get("head"), "head_after": a.get("head"),
        "behind_before": b.get("behind"), "behind_after": a.get("behind"),
    })
payload = {"status": status, "fields": {"target": target, "repos": repos}}
if target == "all":
    payload["per_instance"] = [
        {"job_id": r["id"], "status": status, "fields": {"target": r["id"], "repos": [r]}}
        for r in repos
    ]
print("@@RUNLOG@@ " + json.dumps(payload, separators=(",", ":")))
PY
  return "$rc"
}

cmd_logs() {
  local id="" tail=40
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift; id="${1:-}" ;;
      --tail) shift; tail="${1:-40}" ;;
      *) die "unknown logs option: $1" ;;
    esac
    shift
  done
  printf 'stdout: %s\nstderr: %s\n' "$OUT_LOG" "$ERR_LOG"
  for f in "$OUT_LOG" "$ERR_LOG"; do
    printf '\n-- %s (tail %s) --\n' "$f" "$tail"
    [[ -f "$f" ]] && "$LOCAL_JOBS_PYTHON" - "$f" "$tail" <<'PY' || printf '(no log yet)\n'
from collections import deque
from pathlib import Path
import sys
for line in deque(Path(sys.argv[1]).open(errors="replace"), maxlen=int(sys.argv[2])):
    print(line, end="")
PY
  done
}

case "${1:-}" in
  describe) cmd_describe ;;
  list-instances) cmd_list_instances ;;
  view)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown view option: $1" ;; esac; shift; done
    cmd_view "$id"
    ;;
  run) shift; cmd_run "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  add)
    shift
    id="" path="" branch="" remote="" schedule="inherit" enabled="true"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --path) shift; path="${1:-}" ;;
        --branch) shift; branch="${1:-}" ;;
        --remote) shift; remote="${1:-}" ;;
        --schedule) shift; schedule="$(parse_schedule "${1:-}")" ;;
        --enabled) shift; enabled="${1:-}" ;;
        *) die "unknown add option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" && -n "$path" && -n "$branch" ]] || die "add requires --id --path --branch"
    args=(add --id "$id" --path "$path" --branch "$branch" --enabled "$enabled" --schedule "$schedule")
    [[ -n "$remote" ]] && args+=(--remote "$remote")
    igf_config "${args[@]}"
    # A custom-scheduled, enabled repo gets its own per-repo agent immediately.
    if [[ "$schedule" != "inherit" && "$enabled" =~ ^(true|1|yes)$ ]]; then
      "$BACKEND/install-launchd.sh" --repo "$id" || true
    fi
    igf_emit add "$id"
    ;;
  update)
    shift
    id="" schedule="" enabled="" global=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --schedule) shift; schedule="$(parse_schedule "${1:-}")" ;;
        --enabled) shift; enabled="${1:-}" ;;
        --global) global=1 ;;
        *) die "unknown update option: $1" ;;
      esac
      shift
    done
    [[ -n "$enabled" || -n "$schedule" ]] || die "update requires --schedule and/or --enabled"
    if [[ -n "$enabled" ]]; then
      [[ -n "$id" && "$id" != "__global__" ]] || die "update --enabled requires a repo --id"
      case "$enabled" in
        true|1|yes) igf_config enable --id "$id" ;;
        false|0|no) igf_config disable --id "$id" ;;
        *) die "invalid --enabled value: $enabled" ;;
      esac
    fi
    if [[ -n "$schedule" ]]; then
      if (( global == 1 )) || [[ "$id" == "__global__" ]]; then
        [[ "$schedule" != "inherit" ]] || die "global schedule cannot be inherit"
        igf_config set-schedule --global --hour "${schedule%%:*}" --minute "${schedule#*:}"
        "$BACKEND/install-launchd.sh"
      else
        [[ -n "$id" ]] || die "update --schedule requires --id or --global"
        if [[ "$schedule" == "inherit" ]]; then
          igf_config set-schedule --id "$id" --inherit
          "$BACKEND/uninstall-launchd.sh" --repo "$id" || true
          "$BACKEND/install-launchd.sh"
        else
          igf_config set-schedule --id "$id" --hour "${schedule%%:*}" --minute "${schedule#*:}"
          "$BACKEND/install-launchd.sh" --repo "$id"
        fi
      fi
    fi
    igf_emit update "${id:-__global__}"
    ;;
  delete)
    shift
    id="" purge=0 confirm=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --purge-launchd) purge=1 ;;
        --confirm) confirm=1 ;;
        *) die "unknown delete option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" ]] || die "delete requires --id"
    [[ "$id" != "__global__" ]] || die "cannot delete global scheduler"
    (( confirm == 1 )) || die "delete requires --confirm (destructive)"
    args=(remove --id "$id")
    (( purge == 1 )) && args+=(--purge-launchd)
    output="$(igf_config "${args[@]}")"
    printf '%s\n' "$output"
    if (( purge == 1 )) && grep -q "^PURGE_LAUNCHD:${id}$" <<<"$output"; then
      "$BACKEND/uninstall-launchd.sh" --repo "$id" || true
    fi
    igf_emit delete "$id"
    ;;
  repair)
    shift
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; --all) ;; *) die "unknown repair option: $1" ;; esac; shift; done
    chmod +x "$BACKEND"/*.sh 2>/dev/null || true
    igf_config validate >/dev/null
    "$BACKEND/install-launchd.sh"
    while IFS=$'\t' read -r repo_id enabled _rest; do
      [[ -n "$repo_id" ]] || continue
      [[ "$enabled" == "enabled" ]] || continue
      repo_json="$(igf_config repo "$repo_id")"
      kind="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; s=json.load(sys.stdin).get("schedule"); print("custom" if isinstance(s,dict) else "inherit")' <<<"$repo_json")"
      [[ "$kind" == "custom" ]] && "$BACKEND/install-launchd.sh" --repo "$repo_id"
    done < <(igf_config list)
    igf_emit repair "${id:-all}"
    printf 'repair: complete\n'
    ;;
  enable)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown enable option: $1" ;; esac; shift; done
    [[ -n "$id" && "$id" != "__global__" ]] || die "enable requires a repo --id"
    igf_config enable --id "$id"
    # Re-create the per-repo agent if this repo is custom-scheduled.
    repo_json="$(igf_config repo "$id")"
    kind="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; s=json.load(sys.stdin).get("schedule"); print("custom" if isinstance(s,dict) else "inherit")' <<<"$repo_json")"
    [[ "$kind" == "custom" ]] && "$BACKEND/install-launchd.sh" --repo "$id" || true
    igf_emit enable "$id"
    ;;
  disable)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown disable option: $1" ;; esac; shift; done
    [[ -n "$id" && "$id" != "__global__" ]] || die "disable requires a repo --id"
    igf_config disable --id "$id"
    # A disabled repo must not keep its own per-repo agent running (no drift).
    "$BACKEND/uninstall-launchd.sh" --repo "$id" 2>/dev/null || true
    igf_emit disable "$id"
    ;;
  doctor)
    issues=0
    printf '== incremental-git-fetch doctor ==\n'
    if igf_config validate >/dev/null 2>&1; then printf 'config: ok (%s)\n' "$LOCAL_JOBS_IGF_CONFIG"; else printf 'config: INVALID\n'; issues=$((issues+1)); fi
    if "$LOCAL_JOBS_PYTHON" -c 'import yaml' 2>/dev/null; then printf 'PyYAML: ok (%s)\n' "$LOCAL_JOBS_PYTHON"; else printf 'PyYAML: MISSING under %s\n' "$LOCAL_JOBS_PYTHON"; issues=$((issues+1)); fi
    for cmd in git lsof; do
      if command -v "$cmd" >/dev/null 2>&1; then printf '%s: ok\n' "$cmd"; else printf '%s: missing\n' "$cmd"; issues=$((issues+1)); fi
    done
    # launchctl is macOS-only; only required when launchd is live (not hermetic).
    if [[ "${LOCAL_JOBS_LAUNCHD_DISABLE:-0}" == "1" ]]; then
      printf 'launchctl: skipped (launchd disabled)\n'
    elif command -v launchctl >/dev/null 2>&1; then printf 'launchctl: ok\n'
    else printf 'launchctl: missing\n'; issues=$((issues+1)); fi
    for s in config.py common.sh fetch-repo.sh run-all.sh install-launchd.sh uninstall-launchd.sh; do
      if [[ -e "$BACKEND/$s" ]]; then printf '%s: present\n' "$s"; else printf '%s: missing\n' "$s"; issues=$((issues+1)); fi
    done
    if [[ "${LOCAL_JOBS_LAUNCHD_DISABLE:-0}" == "1" ]]; then
      printf 'global agent: skipped (launchd disabled)\n'
    elif is_loaded "$LABEL_PREFIX"; then printf 'global agent: loaded (%s)\n' "$LABEL_PREFIX"
    else printf 'global agent: not loaded (%s)\n' "$LABEL_PREFIX"; issues=$((issues+1)); fi
    doctor_status=PASS; (( issues == 0 )) || doctor_status=FAIL
    "$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/events.py" emit --kind status --type incremental-git-fetch \
      --actor "${LOCAL_JOBS_ACTOR:-cli}" --payload "{\"check\":\"doctor\",\"status\":\"$doctor_status\",\"issues\":$issues}" >/dev/null 2>&1 || true
    if (( issues == 0 )); then printf 'doctor: PASS\n'; else printf 'doctor: FAIL (%s)\n' "$issues"; exit 1; fi
    ;;
  ""|-h|--help) usage; exit 2 ;;
  *) die "unknown verb: $1" ;;
esac
