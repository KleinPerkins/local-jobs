#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

REPO_FILTER="${LOCAL_JOBS_IGF_INSTALL_REPO:-}"
HOUR="${LOCAL_JOBS_IGF_WINDOW_START_HOUR:-}"
MINUTE=0

# Scheduled runs go through the framework wrapper so every run lands in runs.jsonl.
RUN_SCHEDULED="$LOCAL_JOBS_HOME/bin/run-scheduled.sh"

usage() {
  cat <<USAGE
Usage: install-launchd.sh [--repo <id>]

Installs the user-level launchd agent for incremental-git-fetch.

Options:
  --repo <id>   Install a per-repo agent using that repo's schedule hour/minute
                (default: global agent at window_start_hour with runtime jitter)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      shift
      REPO_FILTER="${1:-}"
      [[ -n "$REPO_FILTER" ]] || die "--repo requires an id"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

global_json="$(config_py global)"
default_label="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("launchd",{}).get("label","com.kleinperkins.local-jobs.git-fetch"))' <<<"$global_json")"
log_dir_raw="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("logging",{}).get("dir","~/Library/Logs/local-jobs"))' <<<"$global_json")"
LOCAL_JOBS_IGF_LOG_DIR="$(expand_path "$log_dir_raw")"
LOCAL_JOBS_IGF_OUT_LOG="$LOCAL_JOBS_IGF_LOG_DIR/git-fetch.out.log"
LOCAL_JOBS_IGF_ERR_LOG="$LOCAL_JOBS_IGF_LOG_DIR/git-fetch.err.log"

if [[ -n "$REPO_FILTER" ]]; then
  repo_json="$(config_py repo "$REPO_FILTER")"
  LABEL="${default_label}.${REPO_FILTER}"
  HOUR="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; s=json.load(sys.stdin).get("schedule") or {}; print(s.get("hour",""))' <<<"$repo_json")"
  MINUTE="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; s=json.load(sys.stdin).get("schedule") or {}; print(s.get("minute",0))' <<<"$repo_json")"
  PROGRAM_ARGS=("$RUN_SCHEDULED" "--type" "incremental-git-fetch" "--id" "$REPO_FILTER")
  [[ -n "$HOUR" ]] || die "repo $REPO_FILTER has no schedule.hour for per-repo install"
else
  LABEL="$default_label"
  HOUR="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("launchd",{}).get("window_start_hour",18))' <<<"$global_json")"
  PROGRAM_ARGS=("$RUN_SCHEDULED" "--type" "incremental-git-fetch")
fi

[[ "$HOUR" =~ ^[0-9]+$ ]] || die "schedule hour must be numeric"
(( HOUR >= 0 && HOUR <= 23 )) || die "schedule hour must be 0-23"
[[ "$MINUTE" =~ ^[0-9]+$ ]] || die "schedule minute must be numeric"
(( MINUTE >= 0 && MINUTE <= 59 )) || die "schedule minute must be 0-59"

PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$LOCAL_JOBS_IGF_LOG_DIR"

{
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(escape_xml "$LABEL")</string>

  <key>ProgramArguments</key>
  <array>
PLIST
  for arg in "${PROGRAM_ARGS[@]}"; do
    printf '    <string>%s</string>\n' "$(escape_xml "$arg")"
  done
  cat <<PLIST
  </array>

  <key>WorkingDirectory</key>
  <string>$(escape_xml "$LOCAL_JOBS_HOME")</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>LOCAL_JOBS_IGF_CONFIG</key>
    <string>$(escape_xml "$LOCAL_JOBS_IGF_CONFIG")</string>
    <key>LOCAL_JOBS_HOME</key>
    <string>$(escape_xml "$LOCAL_JOBS_HOME")</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>$(escape_xml "$LOCAL_JOBS_IGF_OUT_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(escape_xml "$LOCAL_JOBS_IGF_ERR_LOG")</string>
</dict>
</plist>
PLIST
} >"$PLIST_PATH"

chmod 0644 "$PLIST_PATH"
launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

log "Installed launch agent: $PLIST_PATH"
log "Schedule: daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") local time"
log "Output log: $LOCAL_JOBS_IGF_OUT_LOG"
log "Error log: $LOCAL_JOBS_IGF_ERR_LOG"
