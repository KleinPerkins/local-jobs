#!/usr/bin/env bash
# Import an installed LaunchAgent into the registry as a managed `command` job.
#
# Usage:
#   adopt-job.sh --label <launchd-label> [--id <id>] [--relabel --confirm] [--dry-run]
#
# Without --relabel the agent is registered in config only (the original label
# keeps running). With --relabel --confirm the original is booted out and a fresh
# com.kleinperkins.local-jobs.command.<id> agent is installed in its place.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

label=""; id=""; relabel=0; confirm=0; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) shift; label="${1:-}" ;;
    --id) shift; id="${1:-}" ;;
    --relabel) relabel=1 ;;
    --confirm) confirm=1 ;;
    --dry-run) dry=1 ;;
    *) die "unknown adopt option: $1" ;;
  esac
  shift
done
[[ -n "$label" ]] || die "adopt-job requires --label <launchd-label>"

plist="$HOME/Library/LaunchAgents/${label}.plist"
[[ -f "$plist" ]] || die "no plist for label: $plist"

# Extract program/args/env/schedule from the plist.
parsed="$(PLIST="$plist" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, plistlib
with open(os.environ["PLIST"], "rb") as f:
    d = plistlib.load(f)
prog = d.get("ProgramArguments") or []
cal = d.get("StartCalendarInterval") or {}
print(json.dumps({
    "program": prog[0] if prog else "",
    "args": prog[1:] if len(prog) > 1 else [],
    "env": {k: str(v) for k, v in (d.get("EnvironmentVariables") or {}).items() if k != "PATH"},
    "hour": cal.get("Hour", 0),
    "minute": cal.get("Minute", 0),
}))
PY
)"

program="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.loads(sys.argv[1])["program"])' "$parsed")"
[[ -n "$program" ]] || die "plist has no ProgramArguments to adopt: $label"
[[ -n "$id" ]] || id="${label##*.}"
schedule="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; d=json.loads(sys.argv[1]); print("%02d:%02d" % (int(d["hour"]), int(d["minute"])))' "$parsed")"

# Build the command_store add args.
add_args=(add --id "$id" --program "$program" --schedule "$schedule" --enabled true)
while IFS= read -r a; do [[ -n "$a" ]] && add_args+=("--arg=$a"); done < <("$LOCAL_JOBS_PYTHON" -c 'import json,sys; [print(x) for x in json.loads(sys.argv[1])["args"]]' "$parsed")
while IFS= read -r kv; do [[ -n "$kv" ]] && add_args+=("--env=$kv"); done < <("$LOCAL_JOBS_PYTHON" -c 'import json,sys; [print(f"{k}={v}") for k,v in json.loads(sys.argv[1])["env"].items()]' "$parsed")

if (( dry == 1 )); then
  printf 'would adopt %s as command id=%s schedule=%s program=%s\n' "$label" "$id" "$schedule" "$program"
  "$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/command_store.py" "${add_args[@]}" --dry-run
  exit 0
fi

"$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/command_store.py" "${add_args[@]}"
log "adopted $label into command store as id=$id"

if (( relabel == 1 )); then
  (( confirm == 1 )) || die "--relabel requires --confirm (boots out the original agent)"
  new_label="com.kleinperkins.local-jobs.command.${id}"
  "$(require_handler command)" repair --id "$id"
  if [[ "$label" != "$new_label" ]]; then
    launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
    rm -f "$plist"
    log "relabeled $label -> $new_label (original booted out + removed)"
  fi
else
  log "registered in config only; original agent $label still runs. Use --relabel --confirm to migrate it."
fi
