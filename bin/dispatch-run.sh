#!/usr/bin/env bash
# Shared run dispatcher: wraps a handler's `run` verb, captures the single
# @@RUNLOG@@ line it emits, computes the summary, and appends one runlog/v1
# record to ~/.local-jobs/runs.jsonl. Handlers never write the run log
# themselves, so the schema stays uniform across every job type.
#
# Usage: dispatch-run.sh --type <type> [--id <id>] [--dry-run] [--jitter]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

job_type=""; job_id="all"; run_args=()
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --type) i=$((i+1)); job_type="${args[$i]}" ;;
    --id) i=$((i+1)); job_id="${args[$i]}"; run_args+=(--id "$job_id") ;;
    --dry-run) run_args+=(--dry-run) ;;
    --jitter) run_args+=(--jitter) ;;
    *) run_args+=("${args[$i]}") ;;
  esac
  i=$((i+1))
done
[[ -n "$job_type" ]] || die "dispatch-run requires --type"

handler="$(require_handler "$job_type")"

start="$(date +%s)"
tmp_out="$(mktemp)"
rc=0
# Stream handler output to the terminal AND capture it for the runlog line.
if "$handler" run "${run_args[@]}" 2>&1 | tee "$tmp_out"; then
  rc=0
else
  rc=${PIPESTATUS[0]}
fi
end="$(date +%s)"
duration=$(( end - start ))

runline="$(grep '^@@RUNLOG@@ ' "$tmp_out" | tail -n 1 || true)"
rm -f "$tmp_out"

if [[ -z "$runline" ]]; then
  # Handler emitted no runlog line; synthesize one from the exit code.
  status="success"; (( rc != 0 )) && status="failure"
  payload="{\"status\":\"$status\",\"fields\":{}}"
else
  payload="${runline#@@RUNLOG@@ }"
fi

JOB_TYPE="$job_type" JOB_ID="$job_id" DURATION="$duration" RC="$rc" PAYLOAD="$payload" \
  LOCAL_JOBS_HOME="$LOCAL_JOBS_HOME" LOCAL_JOBS_PYTHON="$LOCAL_JOBS_PYTHON" \
  "$LOCAL_JOBS_PYTHON" - <<'PY' | "$LOCAL_JOBS_PYTHON" "$LOCAL_JOBS_HOME/lib/run_log.py" append
import json, os, subprocess, sys
payload = json.loads(os.environ["PAYLOAD"] or "{}")
status = payload.get("status", "success")
fields = payload.get("fields", {}) or {}
home = os.environ["LOCAL_JOBS_HOME"]
job_type = os.environ["JOB_TYPE"]
summary = subprocess.run(
    [os.environ.get("LOCAL_JOBS_PYTHON", "python3"), f"{home}/lib/summarize.py", job_type, status],
    input=json.dumps(fields), capture_output=True, text=True,
).stdout.strip()
record = {
    "schema": "runlog/v1",
    "job_id": os.environ["JOB_ID"],
    "type": job_type,
    "status": status,
    "duration_s": int(os.environ["DURATION"]),
    "summary": summary,
    "fields": fields,
}
print(json.dumps(record))
PY

exit "$rc"
