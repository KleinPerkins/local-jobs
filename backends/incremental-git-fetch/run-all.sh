#!/usr/bin/env bash
# Run all enabled repos (optionally one repo) with schedule jitter.
# Each repo fetch is serialized behind a per-repo flock so overlapping launchd
# agents (global + per-repo + an in-flight migration) never collide.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

TARGET_REPO="${1:-}"
DRY_RUN="${LOCAL_JOBS_IGF_DRY_RUN:-0}"
FAILURES=0

LOCK_DIR="${LOCAL_JOBS_STATE:-$HOME/.local-jobs}/locks"
FLOCK="$LOCAL_JOBS_HOME/lib/flock.py"

apply_jitter() {
  local global_json window_start window_end use_jitter window_seconds jitter

  if [[ "${LOCAL_JOBS_IGF_SKIP_JITTER:-0}" == "1" ]]; then
    log "Skipping schedule jitter (LOCAL_JOBS_IGF_SKIP_JITTER=1)"
    return 0
  fi

  global_json="$(config_py global)"
  window_start="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; g=json.load(sys.stdin); print(g.get("launchd",{}).get("window_start_hour",18))' <<<"$global_json")"
  window_end="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; g=json.load(sys.stdin); print(g.get("launchd",{}).get("window_end_hour",24))' <<<"$global_json")"
  use_jitter="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; g=json.load(sys.stdin); print("1" if g.get("launchd",{}).get("use_jitter", True) else "0")' <<<"$global_json")"

  [[ "$use_jitter" == "1" ]] || {
    log "Schedule jitter disabled in config"
    return 0
  }

  window_seconds=$(( (window_end - window_start) * 3600 ))
  (( window_seconds > 0 )) || die "invalid schedule window: ${window_start}-${window_end}"

  # Use the shared scheduler for jitter so the full window is covered
  # (bash $RANDOM caps at 32767s ~9.1h and truncates longer windows — P2-8).
  jitter="$("$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/schedule.py" jitter \
    --schedule "{\"window_start_hour\":$window_start,\"window_end_hour\":$window_end,\"use_jitter\":true}" 2>/dev/null)"
  [[ "$jitter" =~ ^[0-9]+$ ]] || jitter=$(( RANDOM % window_seconds ))
  log "Schedule window ${window_start}:00-${window_end}:00; sleeping ${jitter}s (~$(( jitter / 60 )) min)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would sleep ${jitter}s"
  else
    sleep "$jitter"
  fi
}

fetch_one() {
  local repo_id="$1"
  local lock="$LOCK_DIR/igf-${repo_id}.lock"
  LOCAL_JOBS_IGF_DRY_RUN="$DRY_RUN" "$LOCAL_JOBS_PYTHON" "$FLOCK" "$lock" "$SCRIPT_DIR/fetch-repo.sh" "$repo_id"
}

run_all() {
  local repo_id

  if [[ -n "$TARGET_REPO" ]]; then
    if fetch_one "$TARGET_REPO"; then
      :
    else
      FAILURES=$((FAILURES + 1))
    fi
    return 0
  fi

  # The global scheduled window fetches only inherit repos; a repo with its own
  # per-repo agent is fetched by that agent, never twice (P0-1). A manual
  # `run-job --all` (INHERIT_ONLY unset) still fetches every enabled repo.
  local id_source="enabled-ids"
  if [[ "${LOCAL_JOBS_IGF_INHERIT_ONLY:-0}" == "1" ]]; then
    id_source="inherit-ids"
  fi

  while IFS= read -r repo_id; do
    [[ -n "$repo_id" ]] || continue
    if fetch_one "$repo_id"; then
      :
    else
      FAILURES=$((FAILURES + 1))
      log_err "[$repo_id] fetch failed"
    fi
  done < <(config_py "$id_source")
}

main() {
  require_cmd git
  require_cmd "$LOCAL_JOBS_PYTHON"

  mkdir -p "$LOCAL_JOBS_IGF_LOG_DIR" "$LOCK_DIR"
  log "incremental-git-fetch run starting (dry_run=$DRY_RUN target=${TARGET_REPO:-all})"

  apply_jitter
  run_all

  if (( FAILURES > 0 )); then
    log_err "incremental-git-fetch completed with $FAILURES failure(s)"
    exit 1
  fi

  log "incremental-git-fetch run completed successfully"
}

main "$@"
