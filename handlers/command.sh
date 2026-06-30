#!/usr/bin/env bash
# Handler plugin: command (generic scheduled program, ABI v1).
# Thin handler on the shared chassis (lib/handler_lib.sh): it declares its
# schema + how to run, and inherits store/launchd/schedule/CRUD/lifecycle from
# the chassis. Scheduled runs dispatch through run-scheduled.sh for uniform
# run-logging; the program's env/args are applied at run time, not baked into
# the plist.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"
. "$LOCAL_JOBS_HOME/lib/handler_lib.sh"

HANDLER_TYPE="command"
HANDLER_CARDINALITY="multi"
HANDLER_LABEL_TOKEN="command"
HANDLER_SCHEMA_VERSION=1
HANDLER_STORE_FILE="${LOCAL_JOBS_COMMAND_CONFIG:-$LOCAL_JOBS_HOME/config/jobs/command.yml}"
HANDLER_FIELD_DEFAULTS='{"args":[],"env":{},"enabled":true}'
HANDLER_REQUIRED_FIELDS='["program","schedule"]'
HANDLER_ADD_SCHEMA='[
  {"flag":"--id","field":"id","kind":"id","required":true,"help":"stable instance id"},
  {"flag":"--program","field":"program","kind":"scalar","required":true,"help":"absolute path to executable"},
  {"flag":"--schedule","field":"schedule","kind":"scalar","required":true,"help":"HH:MM"},
  {"flag":"--arg","field":"args","kind":"list","help":"program arg (repeatable)"},
  {"flag":"--env","field":"env","kind":"map","help":"K=V (repeatable)"},
  {"flag":"--enabled","field":"enabled","kind":"bool","default":true,"help":"true | false"}
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
    "label_template": f'com.kleinperkins.local-jobs.{os.environ["HANDLER_LABEL_TOKEN"]}.<id>',
    "schema_version": int(os.environ["HANDLER_SCHEMA_VERSION"]),
    "config_file": os.environ["HANDLER_STORE_FILE"],
    "add_schema": json.loads(os.environ["HANDLER_ADD_SCHEMA"]),
}, indent=2))
PY
}

handler_do_run() {
  local id="" dry=0
  while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; --dry-run) dry=1 ;; *) hl_die "unknown run option: $1" ;; esac; shift; done
  [[ -n "$id" ]] || hl_die "run requires --id"
  local entry; entry="$(_hl_store get --id "$id")"
  ENTRY="$entry" DRY="$dry" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess, sys
entry = json.loads(os.environ["ENTRY"])
dry = os.environ["DRY"] == "1"
cmd = [entry["program"], *(entry.get("args") or [])]
env = {**os.environ, **(entry.get("env") or {})}
if dry:
    print(f"[dry-run] would run: {' '.join(cmd)}")
    print("@@RUNLOG@@ " + json.dumps({"status": "dry-run", "fields": {"exit_code": 0, "last_line": "dry-run"}}, separators=(",", ":")))
    sys.exit(0)
proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
out = (proc.stdout or "") + (proc.stderr or "")
sys.stdout.write(out)
last = (out.strip().splitlines() or [""])[-1]
status = "success" if proc.returncode == 0 else "failure"
print("@@RUNLOG@@ " + json.dumps({"status": status, "fields": {"exit_code": proc.returncode, "last_line": last[:200]}}, separators=(",", ":")))
sys.exit(proc.returncode)
PY
}

handler_main "$@"
