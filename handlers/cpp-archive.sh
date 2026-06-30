#!/usr/bin/env bash
# Handler plugin: cpp-archive (singleton, ABI v1).
# Owns its own plist generation under the local-jobs label namespace so the
# personal/cpp backend source is never modified. Scheduled runs go through the
# framework run-scheduled wrapper for uniform run-logging.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"

CPP_HOME="${CPP_ARCHIVE_HOME:-$HOME/dev/personal/cpp}"
ARCHIVE_SCRIPT="$CPP_HOME/bin/archive-cpp-local.sh"
LABEL="${CPP_ARCHIVE_LAUNCHD_LABEL:-com.kleinperkins.local-jobs.cpp-archive}"
LEGACY_LABEL="com.kleinperkins.cpp-archive"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SOURCE_REPO="${CPP_ARCHIVE_SOURCE_REPO:-$HOME/dev/affirm/src/card-platform-product}"
TARGET_REMOTE="${CPP_ARCHIVE_TARGET_REMOTE:-git@github.com:KleinPerkins/cpp.git}"
OUT_LOG="$HOME/Library/Logs/cpp-archive.out.log"
ERR_LOG="$HOME/Library/Logs/cpp-archive.err.log"
RUN_SCHEDULED="$LOCAL_JOBS_HOME/bin/run-scheduled.sh"

die() { printf 'cpp-archive: %s\n' "$*" >&2; exit 2; }

usage() { printf 'cpp-archive handler verbs:\n  describe list-instances view run logs add update delete repair enable disable doctor\n'; }

uid_domain() { printf 'gui/%s' "$(id -u)"; }
is_loaded() { launchctl print "$(uid_domain)/$1" >/dev/null 2>&1; }

escape_xml() { /usr/bin/python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$1"; }

plist_schedule() {
  # echoes "HOUR MINUTE" from the installed plist, defaulting 18 0
  if [[ -f "$PLIST" ]]; then
    "$LOCAL_JOBS_PYTHON" - "$PLIST" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    cal = (plistlib.load(f).get("StartCalendarInterval") or {})
print(cal.get("Hour", 18), cal.get("Minute", 0))
PY
  else
    printf '18 0\n'
  fi
}

install_plist() {
  local hour="$1" minute="$2"
  [[ "$hour" =~ ^[0-9]+$ ]] || die "hour must be numeric"
  [[ "$minute" =~ ^[0-9]+$ ]] || die "minute must be numeric"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(escape_xml "$LABEL")</string>

  <key>ProgramArguments</key>
  <array>
    <string>$(escape_xml "$RUN_SCHEDULED")</string>
    <string>--type</string>
    <string>cpp-archive</string>
    <string>--id</string>
    <string>cpp-archive</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$(escape_xml "$CPP_HOME")</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>CPP_ARCHIVE_SOURCE_REPO</key>
    <string>$(escape_xml "$SOURCE_REPO")</string>
    <key>CPP_ARCHIVE_TARGET_REMOTE</key>
    <string>$(escape_xml "$TARGET_REMOTE")</string>
    <key>LOCAL_JOBS_HOME</key>
    <string>$(escape_xml "$LOCAL_JOBS_HOME")</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>$(escape_xml "$OUT_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(escape_xml "$ERR_LOG")</string>
</dict>
</plist>
PLIST
  chmod 0644 "$PLIST"
  launchctl bootout "$(uid_domain)/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "$(uid_domain)" "$PLIST"
}

cmd_describe() {
  LABEL="$LABEL" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
print(json.dumps({
    "type": "cpp-archive",
    "cardinality": "singleton",
    "label_token": "cpp-archive",
    "label_template": os.environ["LABEL"],
    "config_file": None,
    "add_schema": [
        {"flag": "--schedule", "required": False, "help": "HH:MM (default 18:00)"},
    ],
}, indent=2))
PY
}

cmd_list_instances() {
  read -r hour minute < <(plist_schedule)
  local loaded=false; is_loaded "$LABEL" && loaded=true
  LABEL="$LABEL" LOADED="$loaded" HOUR="$hour" MINUTE="$minute" PLIST="$PLIST" \
    OUT_LOG="$OUT_LOG" ERR_LOG="$ERR_LOG" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
hour = int(os.environ["HOUR"]); minute = int(os.environ["MINUTE"])
print(json.dumps([{
    "id": "cpp-archive",
    "type": "cpp-archive",
    "role": "instance",
    "enabled": os.path.isfile(os.environ["PLIST"]),
    "schedule": f"{hour:02d}:{minute:02d}",
    "launchd_label": os.environ["LABEL"],
    "launchd_loaded": os.environ["LOADED"] == "true",
    "plist": os.environ["PLIST"],
    "log_paths": {"stdout": os.environ["OUT_LOG"], "stderr": os.environ["ERR_LOG"]},
}], indent=2))
PY
}

cmd_view() {
  cmd_list_instances | "$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0], indent=2))'
}

cmd_run() {
  local dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) shift ;;
      --dry-run) dry=1 ;;
      *) die "unknown run option: $1" ;;
    esac
    shift
  done
  [[ -x "$ARCHIVE_SCRIPT" ]] || die "archive script missing: $ARCHIVE_SCRIPT"
  local out rc=0 status="success"
  if out="$(CPP_ARCHIVE_DRY_RUN="$dry" CPP_ARCHIVE_SOURCE_REPO="$SOURCE_REPO" CPP_ARCHIVE_TARGET_REMOTE="$TARGET_REMOTE" "$ARCHIVE_SCRIPT" 2>&1)"; then
    rc=0
  else
    rc=$?; status="failure"
  fi
  (( dry == 1 )) && status="dry-run"
  printf '%s\n' "$out"
  local last_line
  last_line="$(printf '%s\n' "$out" | tail -n 1)"
  STATUS="$status" LAST="$last_line" RC="$rc" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
payload = {"status": os.environ["STATUS"],
           "fields": {"exit_code": int(os.environ["RC"]), "last_line": os.environ["LAST"][:200]}}
print("@@RUNLOG@@ " + json.dumps(payload, separators=(",", ":")))
PY
  return "$rc"
}

cmd_logs() {
  local tail=40
  while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; --tail) shift; tail="${1:-40}" ;; *) die "unknown logs option: $1" ;; esac; shift; done
  printf 'stdout: %s\nstderr: %s\n' "$OUT_LOG" "$ERR_LOG"
  for f in "$OUT_LOG" "$ERR_LOG"; do
    printf '\n-- %s (tail %s) --\n' "$f" "$tail"
    [[ -f "$f" ]] && tail -n "$tail" "$f" || printf '(no log yet)\n'
  done
}

case "${1:-}" in
  describe) cmd_describe ;;
  list-instances) cmd_list_instances ;;
  view) shift; cmd_view ;;
  run) shift; cmd_run "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  add)
    shift
    schedule="18:00"
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; --schedule) shift; schedule="${1:-18:00}" ;; *) die "unknown add option: $1" ;; esac; shift; done
    install_plist "${schedule%%:*}" "${schedule#*:}"
    printf 'installed %s\n' "$LABEL"
    ;;
  update)
    shift
    schedule="" enabled=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift ;;
        --schedule) shift; schedule="${1:-}" ;;
        --enabled) shift; enabled="${1:-}" ;;
        *) die "unknown update option: $1" ;;
      esac
      shift
    done
    if [[ -n "$enabled" ]]; then
      case "$enabled" in
        true|1|yes) read -r h m < <(plist_schedule); install_plist "$h" "$m" ;;
        false|0|no) launchctl bootout "$(uid_domain)/${LABEL}" >/dev/null 2>&1 || true ;;
        *) die "invalid --enabled: $enabled" ;;
      esac
    fi
    if [[ -n "$schedule" ]]; then
      case "$schedule" in
        *:*) install_plist "${schedule%%:*}" "${schedule#*:}" ;;
        *) die "schedule must be HH:MM" ;;
      esac
    fi
    [[ -n "$enabled" || -n "$schedule" ]] || die "update requires --schedule and/or --enabled"
    ;;
  delete)
    shift
    confirm=0
    while [[ $# -gt 0 ]]; do case "$1" in --confirm) confirm=1 ;; --id) shift ;; *) die "unknown delete option: $1" ;; esac; shift; done
    (( confirm == 1 )) || die "delete requires --confirm"
    launchctl bootout "$(uid_domain)/${LABEL}" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    printf 'removed launch agent %s\n' "$LABEL"
    ;;
  repair)
    shift
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; *) die "unknown repair option: $1" ;; esac; shift; done
    chmod +x "$CPP_HOME/bin/"*.sh 2>/dev/null || true
    [[ -x "$ARCHIVE_SCRIPT" ]] || die "archive script missing"
    read -r h m < <(plist_schedule)
    install_plist "$h" "$m"
    # retire any legacy-labelled agent left behind
    if [[ -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist" ]]; then
      launchctl bootout "$(uid_domain)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
      rm -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist"
      printf 'retired legacy agent %s\n' "$LEGACY_LABEL"
    fi
    printf 'repair: complete\n'
    ;;
  enable)
    shift
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; *) die "unknown enable option: $1" ;; esac; shift; done
    [[ -f "$PLIST" ]] || { read -r h m < <(plist_schedule); install_plist "$h" "$m"; }
    launchctl bootout "$(uid_domain)/${LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "$(uid_domain)" "$PLIST"
    printf 'enabled %s\n' "$LABEL"
    ;;
  disable)
    shift
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; *) die "unknown disable option: $1" ;; esac; shift; done
    launchctl bootout "$(uid_domain)/${LABEL}" >/dev/null 2>&1 || true
    printf 'disabled %s\n' "$LABEL"
    ;;
  doctor)
    issues=0
    printf '== cpp-archive doctor ==\n'
    if [[ -x "$ARCHIVE_SCRIPT" ]]; then printf 'archive script: ok\n'; else printf 'archive script: missing\n'; issues=$((issues+1)); fi
    if "$LOCAL_JOBS_PYTHON" -c 'import yaml' 2>/dev/null; then printf 'PyYAML: ok\n'; else printf 'PyYAML: missing\n'; issues=$((issues+1)); fi
    if [[ -f "$PLIST" ]]; then printf 'plist: %s\n' "$PLIST"; else printf 'plist: missing\n'; issues=$((issues+1)); fi
    if is_loaded "$LABEL"; then printf 'loaded: yes\n'; else printf 'loaded: no\n'; issues=$((issues+1)); fi
    if [[ -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist" ]] || is_loaded "$LEGACY_LABEL"; then
      printf 'legacy agent still present: %s (run repair)\n' "$LEGACY_LABEL"; issues=$((issues+1));
    fi
    if (( issues == 0 )); then printf 'doctor: PASS\n'; else printf 'doctor: FAIL (%s)\n' "$issues"; exit 1; fi
    ;;
  ""|-h|--help) usage; exit 2 ;;
  *) die "unknown verb: $1" ;;
esac
