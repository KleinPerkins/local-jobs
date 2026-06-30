#!/usr/bin/env bash
# Shared run dispatcher: wraps a handler's `run` verb, captures the single
# @@RUNLOG@@ line it emits, computes the summary, and appends one runlog/v1
# record (a kind:"run" event) to the event stream. Handlers never write the run
# log themselves, so the schema stays uniform across every job type.
#
# Robustness (closes P0-3, P2-P, P1-C):
#   - a malformed @@RUNLOG@@ line synthesizes a failure record carrying the
#     parse error + real job_id/type/rc instead of masking the exit code;
#   - the handler-reported status is reconciled against the real exit code
#     (a non-zero rc can never be logged as success);
#   - a run may fan out per-instance records (e.g. one per repo) so inherit
#     instances stop showing "never run".
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
  payload=""              # no line emitted; the recorder synthesizes from rc
else
  payload="${runline#@@RUNLOG@@ }"
fi

JOB_TYPE="$job_type" JOB_ID="$job_id" DURATION="$duration" RC="$rc" PAYLOAD="$payload" \
  LOCAL_JOBS_HOME="$LOCAL_JOBS_HOME" LOCAL_JOBS_PYTHON="$LOCAL_JOBS_PYTHON" \
  "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess, sys
from pathlib import Path

home = os.environ["LOCAL_JOBS_HOME"]
lib = str(Path(home) / "lib")
sys.path.insert(0, lib)
import run_log  # noqa: E402

py = os.environ.get("LOCAL_JOBS_PYTHON", "python3")
job_type = os.environ["JOB_TYPE"]
job_id = os.environ["JOB_ID"]
duration = int(os.environ["DURATION"])
rc = int(os.environ.get("RC", "0") or "0")
raw = os.environ.get("PAYLOAD", "")

parse_error = None
if raw.strip() == "":
    payload = {}
else:
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("runlog payload is not a JSON object")
    except (json.JSONDecodeError, ValueError) as exc:
        parse_error = str(exc)
        payload = {}


def reconcile(status, fields):
    """A non-zero rc can never be success; never touch dry-run/skipped."""
    if rc != 0 and status == "success":
        return "failure"
    return status


def summarize(status, fields):
    try:
        out = subprocess.run(
            [py, f"{home}/lib/summarize.py", job_type, status],
            input=json.dumps(fields), capture_output=True, text=True,
        )
        return out.stdout.strip()
    except OSError:
        return status


def write(jid, status, fields, top_rc):
    status = reconcile(status, fields)
    run_log.append({
        "job_id": jid,
        "type": job_type,
        "status": status,
        "rc": top_rc,
        "duration_s": duration,
        "summary": summarize(status, fields),
        "fields": fields,
    })


status = payload.get("status") or ("failure" if rc != 0 else "success")
fields = payload.get("fields") if isinstance(payload.get("fields"), dict) else {}
per_instance = payload.get("per_instance") if isinstance(payload.get("per_instance"), list) else []

if parse_error is not None:
    status = "failure"
    fields = {"runlog_parse_error": parse_error, "raw": raw[:200]}

write(job_id, status, fields, rc)

# Fan out one record per instance so multi-target runs (e.g. igf inherit repos)
# give each instance its own last-run rather than only the aggregate.
for pi in per_instance:
    if not isinstance(pi, dict) or not pi.get("job_id"):
        continue
    pstatus = pi.get("status") or status
    pfields = pi.get("fields") if isinstance(pi.get("fields"), dict) else {}
    # Per-instance rc: 0 unless the whole run failed and this instance is the cause.
    prc = rc if pstatus == "failure" else 0
    write(pi["job_id"], pstatus, pfields, prc)
PY

exit "$rc"
