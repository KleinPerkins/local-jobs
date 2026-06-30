#!/usr/bin/env bash
# Handler plugin: cpp-archive (singleton backend)
set -euo pipefail

CPP_HOME="${CPP_ARCHIVE_HOME:-$HOME/dev/personal/cpp}"
LABEL="${CPP_ARCHIVE_LAUNCHD_LABEL:-com.kleinperkins.cpp-archive}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
INSTALLER="$CPP_HOME/bin/install-launchd.sh"
ARCHIVE_SCRIPT="$CPP_HOME/bin/archive-cpp-local.sh"
OUT_LOG="$HOME/Library/Logs/cpp-archive.out.log"
ERR_LOG="$HOME/Library/Logs/cpp-archive.err.log"

die() { printf 'cpp-archive: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<USAGE
cpp-archive handler verbs:
  view add update delete repair enable disable doctor
USAGE
}

launchctl_domain() {
  printf 'gui/%s' "$(id -u)"
}

is_loaded() {
  launchctl print "$(launchctl_domain)/${LABEL}" >/dev/null 2>&1
}

view_json() {
  python3 - <<'PY'
import json, os, subprocess, plistlib
from pathlib import Path

label = os.environ["LABEL"]
plist = Path(os.environ["PLIST"])
uid = os.getuid()
loaded = subprocess.run(
    ["launchctl", "print", f"gui/{uid}/{label}"],
    capture_output=True,
).returncode == 0
schedule = {}
if plist.is_file():
    with plist.open("rb") as f:
        data = plistlib.load(f)
    cal = data.get("StartCalendarInterval") or {}
    schedule = {"hour": cal.get("Hour"), "minute": cal.get("Minute")}
print(json.dumps({
    "id": "cpp-archive",
    "type": "cpp-archive",
    "singleton": True,
    "launchd_label": label,
    "loaded": loaded,
    "plist": str(plist),
    "schedule": schedule,
    "logs": {"stdout": os.environ["OUT_LOG"], "stderr": os.environ["ERR_LOG"]},
}, indent=2))
PY
}

case "${1:-}" in
  view)
    LABEL="$LABEL" PLIST="$PLIST" OUT_LOG="$OUT_LOG" ERR_LOG="$ERR_LOG" view_json
    ;;
  add)
    # Singleton already registered; installing launchd is equivalent to add
    [[ -x "$INSTALLER" ]] || die "installer missing: $INSTALLER"
    "$INSTALLER"
    ;;
  update)
    shift
    schedule="" enabled=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift ;;  # singleton; id ignored
        --schedule) shift; schedule="${1:-}" ;;
        --enabled) shift; enabled="${1:-}" ;;
        *) die "unknown update option: $1" ;;
      esac
      shift
    done
    if [[ -n "$enabled" ]]; then
      case "$enabled" in
        true|1|yes) [[ -x "$INSTALLER" ]] && "$INSTALLER" ;;
        false|0|no)
          launchctl bootout "$(launchctl_domain)" "$PLIST" 2>/dev/null || true
          ;;
        *) die "invalid --enabled: $enabled" ;;
      esac
    fi
    if [[ -n "$schedule" ]]; then
      case "$schedule" in
        *:*)
          export CPP_ARCHIVE_HOUR="${schedule%%:*}"
          export CPP_ARCHIVE_MINUTE="${schedule#*:}"
          [[ -x "$INSTALLER" ]] || die "installer missing"
          "$INSTALLER"
          ;;
        *) die "schedule must be HH:MM" ;;
      esac
    fi
    if [[ -z "$enabled" && -z "$schedule" ]]; then
      die "update requires --schedule and/or --enabled"
    fi
    ;;
  delete)
    shift
    confirm=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --confirm) confirm=1 ;;
        *) die "unknown delete option: $1" ;;
      esac
      shift
    done
    (( confirm == 1 )) || die "delete requires --confirm"
    launchctl bootout "$(launchctl_domain)" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    printf 'removed launch agent %s\n' "$LABEL"
    ;;
  repair)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift ;;  # singleton; id ignored
        *) die "unknown repair option: $1" ;;
      esac
      shift
    done
    chmod +x "$CPP_HOME/bin/"*.sh 2>/dev/null || true
    [[ -x "$ARCHIVE_SCRIPT" ]] || die "archive script missing"
    [[ -x "$INSTALLER" ]] || die "installer missing"
    "$INSTALLER"
    printf 'repair: complete\n'
    ;;
  enable)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift ;;  # singleton; id ignored
        *) die "unknown enable option: $1" ;;
      esac
      shift
    done
    [[ -f "$PLIST" ]] || die "plist not installed; run repair or add first"
    launchctl bootstrap "$(launchctl_domain)" "$PLIST"
    printf 'enabled %s\n' "$LABEL"
    ;;
  disable)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift ;;  # singleton; id ignored
        *) die "unknown disable option: $1" ;;
      esac
      shift
    done
    launchctl bootout "$(launchctl_domain)" "$PLIST" 2>/dev/null || true
    printf 'disabled %s\n' "$LABEL"
    ;;
  doctor)
    issues=0
    printf '== cpp-archive doctor ==\n'
    for f in "$ARCHIVE_SCRIPT" "$INSTALLER"; do
      if [[ -x "$f" ]]; then printf '%s: ok\n' "$f"; else printf '%s: missing\n' "$f"; issues=$((issues+1)); fi
    done
    if [[ -f "$PLIST" ]]; then printf 'plist: %s\n' "$PLIST"; else printf 'plist: missing\n'; issues=$((issues+1)); fi
    if is_loaded; then printf 'loaded: yes\n'; else printf 'loaded: no\n'; issues=$((issues+1)); fi
    if (( issues == 0 )); then printf 'doctor: PASS\n'; else printf 'doctor: FAIL (%s)\n' "$issues"; exit 1; fi
    ;;
  "")
    usage
    exit 2
    ;;
  *)
    die "unknown verb: $1"
    ;;
esac
