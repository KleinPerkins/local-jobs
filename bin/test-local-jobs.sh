#!/usr/bin/env bash
# ABI conformance + smoke harness. Runs the read-only ABI contract against EVERY
# registered job type, plus dry-run mutations on the generic command type and a
# runs.jsonl round-trip. Exit non-zero if any check fails.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLI="$SCRIPT_DIR/local-jobs.sh"
PY="${LOCAL_JOBS_PYTHON:-python3}"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

is_json() { "$PY" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; }

echo "== ABI conformance per registered type =="
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  handler="$("$PY" "$LOCAL_JOBS_HOME/lib/registry.py" handler-path --type "$t")"
  printf '\n-- %s (%s) --\n' "$t" "$handler"

  if "$handler" describe | is_json; then ok "$t describe -> JSON"; else bad "$t describe"; fi
  # describe must declare required keys
  if "$handler" describe | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["type"] and d["cardinality"] in ("singleton","multi") and isinstance(d["add_schema"],list)'; then
    ok "$t describe schema keys"; else bad "$t describe schema keys"; fi

  if "$handler" list-instances | is_json; then ok "$t list-instances -> JSON array"; else bad "$t list-instances"; fi

  # view on the first instance id (if any)
  first_id="$("$handler" list-instances | "$PY" -c 'import json,sys; a=json.load(sys.stdin); print(a[0]["id"] if a else "")')"
  if [[ -n "$first_id" ]]; then
    if "$handler" view --id "$first_id" | is_json; then ok "$t view --id $first_id"; else bad "$t view --id $first_id"; fi
  fi

  if "$handler" doctor >/dev/null 2>&1; then ok "$t doctor PASS"; else bad "$t doctor"; fi
done < <("$PY" "$LOCAL_JOBS_HOME/lib/registry.py" job-types)

echo
echo "== generic command lifecycle (real, harmless) =="
TID="__conformance_test__"
"$CLI" delete-job --id "$TID" --confirm >/dev/null 2>&1 || true
if "$CLI" add-job --type command --id "$TID" --program /bin/echo --arg=conformance --schedule 04:04 >/dev/null 2>&1; then ok "command add"; else bad "command add"; fi
if "$CLI" run-job --id "$TID" 2>/dev/null | grep -q '@@RUNLOG@@'; then ok "command run emits runlog"; else bad "command run"; fi
if "$CLI" run-job --id "$TID" --dry-run >/dev/null 2>&1; then ok "command run --dry-run"; else bad "command run --dry-run"; fi
if "$CLI" delete-job --id "$TID" --confirm >/dev/null 2>&1; then ok "command delete"; else bad "command delete"; fi

echo
echo "== run log round-trip =="
if "$PY" "$LOCAL_JOBS_HOME/lib/run_log.py" recent --limit 1 | is_json; then ok "run_log recent -> JSON"; else bad "run_log recent"; fi

echo
echo "== dashboard schema =="
if "$CLI" dashboard --json | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]=="dashboard/v1" and "generated_at" in d and isinstance(d["instances"],list) and "summary" in d'; then ok "dashboard --json schema"; else bad "dashboard --json schema"; fi

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
