#!/usr/bin/env bash
# Handler plugin: cpp-archive (singleton, ABI v1).
# Thin handler on the shared chassis. It owns its plist under the local-jobs
# label namespace (the personal/cpp source is never modified) and tracks its
# real enabled state in a store (no more plist-existence proxy — fixes the
# permanent-drift bug). Scheduled runs dispatch through run-scheduled.sh.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"
. "$LOCAL_JOBS_HOME/lib/handler_lib.sh"

CPP_HOME="${CPP_ARCHIVE_HOME:-$HOME/dev/personal/cpp}"
ARCHIVE_SCRIPT="$CPP_HOME/bin/archive-cpp-local.sh"
SOURCE_REPO="${CPP_ARCHIVE_SOURCE_REPO:-$HOME/dev/affirm/src/card-platform-product}"
TARGET_REMOTE="${CPP_ARCHIVE_TARGET_REMOTE:-git@github.com:KleinPerkins/cpp.git}"
LEGACY_LABEL="com.kleinperkins.cpp-archive"

HANDLER_TYPE="cpp-archive"
HANDLER_CARDINALITY="singleton"
HANDLER_LABEL_TOKEN="cpp-archive"
HANDLER_SCHEMA_VERSION=1
HANDLER_SINGLETON_ID="cpp-archive"
HANDLER_STORE_FILE="${LOCAL_JOBS_CPP_ARCHIVE_CONFIG:-$LOCAL_JOBS_HOME/config/jobs/cpp-archive.yml}"
HANDLER_FIELD_DEFAULTS='{"enabled":true,"schedule":"18:00"}'
HANDLER_REQUIRED_FIELDS='[]'
HANDLER_ADD_SCHEMA='[
  {"flag":"--schedule","field":"schedule","kind":"scalar","required":false,"help":"HH:MM (default 18:00)"},
  {"flag":"--enabled","field":"enabled","kind":"bool","help":"true | false"}
]'

handler_describe() {
  HANDLER_TYPE="$HANDLER_TYPE" HANDLER_CARDINALITY="$HANDLER_CARDINALITY" \
  HANDLER_LABEL_TOKEN="$HANDLER_LABEL_TOKEN" HANDLER_SCHEMA_VERSION="$HANDLER_SCHEMA_VERSION" \
  HANDLER_STORE_FILE="$HANDLER_STORE_FILE" HANDLER_ADD_SCHEMA="$HANDLER_ADD_SCHEMA" \
    "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
print(json.dumps({
    "type": os.environ["HANDLER_TYPE"],
    "cardinality": os.environ["HANDLER_CARDINALITY"],
    "label_token": os.environ["HANDLER_LABEL_TOKEN"],
    "label_template": f'com.kleinperkins.local-jobs.{os.environ["HANDLER_LABEL_TOKEN"]}',
    "schema_version": int(os.environ["HANDLER_SCHEMA_VERSION"]),
    "config_file": os.environ["HANDLER_STORE_FILE"],
    "add_schema": json.loads(os.environ["HANDLER_ADD_SCHEMA"]),
}, indent=2))
PY
}

# Carry the archive env on the scheduled agent so the nightly run can push.
handler_launchd_env() {
  SOURCE_REPO="$SOURCE_REPO" TARGET_REMOTE="$TARGET_REMOTE" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
print(json.dumps({
    "CPP_ARCHIVE_SOURCE_REPO": os.environ["SOURCE_REPO"],
    "CPP_ARCHIVE_TARGET_REMOTE": os.environ["TARGET_REMOTE"],
}))
PY
}

handler_working_dir() { printf '%s' "$CPP_HOME"; }

handler_do_run() {
  local dry=0
  while [[ $# -gt 0 ]]; do case "$1" in --id) shift ;; --dry-run) dry=1 ;; *) hl_die "unknown run option: $1" ;; esac; shift; done
  [[ -x "$ARCHIVE_SCRIPT" ]] || hl_die "archive script missing: $ARCHIVE_SCRIPT"
  local out rc=0 status="success"
  if out="$(CPP_ARCHIVE_DRY_RUN="$dry" CPP_ARCHIVE_SOURCE_REPO="$SOURCE_REPO" CPP_ARCHIVE_TARGET_REMOTE="$TARGET_REMOTE" "$ARCHIVE_SCRIPT" 2>&1)"; then
    rc=0
  else
    rc=$?; status="failure"
  fi
  (( dry == 1 )) && status="dry-run"
  printf '%s\n' "$out"
  local last_line; last_line="$(printf '%s\n' "$out" | tail -n 1)"
  STATUS="$status" LAST="$last_line" RC="$rc" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os
print("@@RUNLOG@@ " + json.dumps({
    "status": os.environ["STATUS"],
    "fields": {"exit_code": int(os.environ["RC"]), "last_line": os.environ["LAST"][:200]},
}, separators=(",", ":")))
PY
  return "$rc"
}

handler_doctor_extra() {
  local issues=0
  if [[ -x "$ARCHIVE_SCRIPT" ]]; then printf 'archive script: ok\n'; else printf 'archive script: missing\n'; issues=$((issues+1)); fi
  if [[ -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist" ]] || _hl_py launchd.py is-loaded --label "$LEGACY_LABEL"; then
    printf 'legacy agent still present: %s (run repair)\n' "$LEGACY_LABEL"; issues=$((issues+1))
  fi
  return "$issues"
}

# Retire any legacy-labelled agent on repair, then converge via the chassis.
if [[ "${1:-}" == "repair" ]]; then
  if [[ -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist" ]] || _hl_py launchd.py is-loaded --label "$LEGACY_LABEL" 2>/dev/null; then
    _hl_py launchd.py uninstall --label "$LEGACY_LABEL" >/dev/null 2>&1 || true
    printf 'retired legacy agent %s\n' "$LEGACY_LABEL"
  fi
fi

handler_main "$@"
