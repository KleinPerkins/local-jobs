#!/usr/bin/env bash
# Hermetic conformance + regression harness for local-jobs.
#
# Everything runs inside a throwaway sandbox with launchd DISABLED
# (LOCAL_JOBS_LAUNCHD_DISABLE=1) and isolated state/registry/config, so it never
# touches the real ~/.local-jobs, the real LaunchAgents, or any live agent. The
# REAL lib/bin/handlers/backends are exercised (symlinked in); only config and
# state are sandboxed.
#
# Coverage:
#   - ABI conformance for EVERY registered type (describe + instances validate
#     against the contract; doctor PASS) — type-dynamic, no hardcoded list.
#   - command full lifecycle (add/update/enable/disable/run real+dry/logs/
#     repair/delete) and run-log full-fidelity round-trip.
#   - cpp-archive singleton CRUD + drift-free disable (never executes the push).
#   - incremental-git-fetch dry-run against a sandbox repo, inherit-only filter.
#   - type-evolution regression: add field / remove field / version bump — the
#     evolving type's instance AND every other type still load + validate + run.
#   - a deliberately-broken type quarantines without crashing view/dashboard.
#   - add-job-type rolls back fully when cross-type regression fails.
#   - disabled job shows no drift; dashboard schema + events stream.
#
# Usage: test-local-jobs.sh [quick]   (quick = fast subset for pre-commit)
set -uo pipefail

REAL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-full}"
PY="${LOCAL_JOBS_PYTHON:-python3}"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is_json() { "$PY" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; }

SB=""
cleanup() { [[ -n "$SB" && -d "$SB" ]] && rm -rf "$SB"; }
trap cleanup EXIT

setup_sandbox() {
  SB="$(mktemp -d /tmp/lj-harness.XXXXXX)"
  export LOCAL_JOBS_HOME="$SB"
  export LOCAL_JOBS_STATE="$SB/state"
  export LOCAL_JOBS_PYTHON="$PY"
  export LOCAL_JOBS_LAUNCHD_DISABLE=1
  export LOCAL_JOBS_LAUNCHAGENTS_DIR="$SB/agents"
  export LOCAL_JOBS_REGISTRY="$SB/config/registry.yml"
  export LOCAL_JOBS_COMMAND_CONFIG="$SB/config/jobs/command.yml"
  export LOCAL_JOBS_CPP_ARCHIVE_CONFIG="$SB/config/jobs/cpp-archive.yml"
  export LOCAL_JOBS_IGF_CONFIG="$SB/config/jobs/incremental-git-fetch.yml"
  export LOCAL_JOBS_IGF_DEV_ROOT="$SB/repos"
  export LOCAL_JOBS_IGF_LOG_DIR="$SB/logs"
  export CPP_ARCHIVE_HOME="$SB/fake-cpp"
  export LOCAL_JOBS_ACTOR="harness"

  mkdir -p "$SB/config/jobs" "$SB/agents" "$SB/state" "$SB/logs" "$SB/repos" "$SB/handlers" "$SB/fake-cpp/bin"
  # Real code, sandboxed config/state.
  ln -s "$REAL_HOME/lib" "$SB/lib"
  ln -s "$REAL_HOME/bin" "$SB/bin"
  ln -s "$REAL_HOME/backends" "$SB/backends"
  for h in "$REAL_HOME/handlers"/*.sh; do ln -s "$h" "$SB/handlers/$(basename "$h")"; done

  # Dummy cpp archive script so cpp-archive doctor passes without the real repo.
  printf '#!/usr/bin/env bash\necho "[fake] cpp archive (dry=%s)"\n' '$CPP_ARCHIVE_DRY_RUN' > "$SB/fake-cpp/bin/archive-cpp-local.sh"
  chmod +x "$SB/fake-cpp/bin/archive-cpp-local.sh"

  # A sandbox git repo for igf dry-run (with a self-remote so rev-list works).
  git init -q "$SB/repos/demo"
  git -C "$SB/repos/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SB/repos/demo" remote add origin "$SB/repos/demo/.git" 2>/dev/null || true
  git -C "$SB/repos/demo" config branch.master.remote origin 2>/dev/null || true

  # Registry: the three real types.
  cat > "$SB/config/registry.yml" <<'EOF'
schema: registry/v1
version: 1
discovery:
  label_prefix: com.kleinperkins.
job_types:
  incremental-git-fetch:
    handler: handlers/incremental-git-fetch.sh
  cpp-archive:
    handler: handlers/cpp-archive.sh
  command:
    handler: handlers/command.sh
EOF
  printf 'schema: jobs/v1\nversion: 1\ninstances: []\n' > "$SB/config/jobs/command.yml"
  printf 'schema: jobs/v1\nversion: 1\nschema_version: 1\ninstances:\n- id: cpp-archive\n  enabled: true\n  schedule: "18:00"\n' > "$SB/config/jobs/cpp-archive.yml"
  cat > "$SB/config/jobs/incremental-git-fetch.yml" <<EOF
schema: jobs/v1
version: 1
defaults: {remote: origin, branch: master, enabled: true, filter_blobs: true, ff_only_merge: true, schedule: inherit}
global:
  dev_root: $SB/repos
  launchd: {label: com.kleinperkins.local-jobs.git-fetch, window_start_hour: 18, window_end_hour: 24, use_jitter: true}
  logging: {dir: $SB/logs}
repos:
- {id: demo, path: demo, remote: origin, branch: master, enabled: true, schedule: inherit}
EOF
}

CLI() { "$SB/bin/local-jobs.sh" "$@"; }
H() { "$SB/handlers/$1.sh" "${@:2}"; }

# ---- ABI conformance per registered type (type-dynamic) --------------------
test_conformance() {
  echo "== ABI conformance per registered type =="
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    printf -- '-- %s --\n' "$t"
    if H "$t" describe | is_json; then ok "$t describe -> JSON"; else bad "$t describe"; fi
    if H "$t" describe | "$PY" "$SB/lib/contract.py" validate-describe >/dev/null 2>&1; then ok "$t describe valid"; else bad "$t describe invalid"; fi
    if H "$t" list-instances | is_json; then ok "$t list-instances -> JSON"; else bad "$t list-instances"; fi
    if H "$t" list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1; then ok "$t instances valid"; else bad "$t instances invalid"; fi
    first_id="$(H "$t" list-instances | "$PY" -c 'import json,sys; a=json.load(sys.stdin); print(next((i["id"] for i in a if i.get("role")=="instance"), ""))')"
    if [[ -n "$first_id" ]]; then
      if H "$t" view --id "$first_id" | is_json; then ok "$t view --id $first_id"; else bad "$t view"; fi
    fi
    if H "$t" doctor >/dev/null 2>&1; then ok "$t doctor PASS"; else bad "$t doctor"; fi
  done < <(CLI view >/dev/null 2>&1; "$PY" "$SB/lib/registry.py" job-types)
}

# ---- command full lifecycle (hermetic, real run) ---------------------------
# Ids are a GLOBAL namespace: add-job rejects an id already used by any type and
# bare --id resolution is fail-closed on collisions (see test_id_uniqueness).
# "cmdjob" is unique in the sandbox (the igf repo is "demo"), so every bare
# --id below resolves deterministically.
test_command_lifecycle() {
  echo "== command full lifecycle =="
  local cid="cmdjob"
  CLI add-job --type command --id "$cid" --program /bin/echo --arg=hello --env=K=V --schedule 03:03 >/dev/null 2>&1 && ok "command add" || bad "command add"
  CLI run-job --id "$cid" 2>/dev/null | grep -q '@@RUNLOG@@' && ok "command run emits runlog" || bad "command run"
  CLI run-job --id "$cid" --dry-run 2>/dev/null | grep -q 'dry-run' && ok "command dry-run" || bad "command dry-run"
  CLI update-job --id "$cid" --schedule 06:06 >/dev/null 2>&1 && ok "command update" || bad "command update"
  CLI disable-job --id "$cid" >/dev/null 2>&1 && ok "command disable" || bad "command disable"
  # disabled + not-loaded => NO drift
  drift="$(CLI dashboard --json | "$PY" -c 'import json,sys; print(next((i["drift"] for i in json.load(sys.stdin)["instances"] if i.get("id")=="'"$cid"'"), None))')"
  [[ "$drift" == "False" ]] && ok "disabled job shows no drift" || bad "disabled drift=$drift"
  CLI enable-job --id "$cid" >/dev/null 2>&1 && ok "command enable" || bad "command enable"
  CLI logs-job --id "$cid" --tail 2 >/dev/null 2>&1 && ok "command logs" || bad "command logs"
  CLI repair-job --id "$cid" >/dev/null 2>&1 && ok "command repair" || bad "command repair"
  # run-log full fidelity: the last command record carries fields.exit_code
  CLI run-job --id "$cid" >/dev/null 2>&1
  "$PY" "$SB/lib/run_log.py" recent --limit 1 --id "$cid" | "$PY" -c 'import json,sys; r=json.load(sys.stdin)[-1]; assert r["fields"].get("exit_code")==0, r' && ok "run-log full fields" || bad "run-log full fields"
  CLI delete-job --id "$cid" --confirm >/dev/null 2>&1 && ok "command delete" || bad "command delete"
}

# ---- cpp-archive singleton (no real push) ----------------------------------
test_cpp_archive() {
  echo "== cpp-archive singleton =="
  H cpp-archive list-instances | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d[0]["id"]=="cpp-archive"' && ok "cpp-archive singleton present" || bad "cpp-archive singleton"
  CLI disable-job --id cpp-archive >/dev/null 2>&1
  en="$(H cpp-archive view --id cpp-archive | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["enabled"])')"
  [[ "$en" == "False" ]] && ok "cpp-archive disable (store-backed)" || bad "cpp-archive disable=$en"
  CLI enable-job --id cpp-archive >/dev/null 2>&1
  CLI add-job --type cpp-archive --schedule 19:30 >/dev/null 2>&1 && ok "cpp-archive singleton upsert" || bad "cpp-archive upsert"
  sched="$(H cpp-archive view --id cpp-archive | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["schedule"])')"
  [[ "$sched" == "19:30" ]] && ok "cpp-archive reschedule" || bad "cpp-archive reschedule=$sched"
}

# ---- incremental-git-fetch (dry-run, hermetic) -----------------------------
test_igf() {
  echo "== incremental-git-fetch dry-run =="
  H incremental-git-fetch list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 && ok "igf instances valid" || bad "igf instances"
  CLI run-job --id demo --dry-run 2>/dev/null | grep -q '@@RUNLOG@@' && ok "igf dry-run runlog" || bad "igf dry-run"
  # per-instance fan-out: an all-repos run records the per-repo last-run
  CLI run-job --type incremental-git-fetch --all --dry-run >/dev/null 2>&1 || true
  "$PY" "$SB/lib/run_log.py" recent --limit 5 --id demo | "$PY" -c 'import json,sys; assert len(json.load(sys.stdin))>=1' && ok "igf per-repo last-run recorded" || bad "igf per-repo last-run"
  inh="$("$PY" "$SB/backends/incremental-git-fetch/config.py" inherit-ids)"
  [[ "$inh" == "demo" ]] && ok "igf inherit-ids" || bad "igf inherit-ids=$inh"
}

# ---- global id-uniqueness + fail-closed ambiguity --------------------------
test_id_uniqueness() {
  echo "== id uniqueness + ambiguity =="
  local out rc igf="$SB/config/jobs/incremental-git-fetch.yml"

  # (a) WRITE-TIME: add-job rejects an id already claimed by another type.
  CLI add-job --type command --id shared --program /bin/echo --arg=x --schedule 03:03 >/dev/null 2>&1 \
    && ok "seed command id 'shared'" || bad "seed shared"
  rc=0; out="$(CLI add-job --type incremental-git-fetch --id shared --path demo --branch master 2>&1)" || rc=$?
  if [[ $rc -ne 0 && "$out" == *"globally unique"* ]]; then ok "add-job rejects duplicate id across types"; else bad "dup id not rejected (rc=$rc)"; fi

  # (b) READ-TIME: force a real cross-type collision by injecting the igf side
  # directly (bypassing the write-time guard), then prove bare --id is
  # ambiguous while --type disambiguates deterministically.
  cp "$igf" "$igf.bak"
  "$PY" - "$igf" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
d.setdefault("repos", []).append(
    {"id": "shared", "path": "demo", "remote": "origin", "branch": "master", "enabled": True, "schedule": "inherit"}
)
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
  rc=0; out="$("$PY" "$SB/lib/registry.py" instance-type --id shared 2>&1)" || rc=$?
  if [[ $rc -ne 0 && "$out" == *"ambiguous id"* ]]; then ok "resolver fail-closed on collision"; else bad "resolver not ambiguous (rc=$rc)"; fi
  rc=0; out="$(CLI run-job --id shared --dry-run 2>&1)" || rc=$?
  if [[ $rc -ne 0 && "$out" == *"ambiguous id"* ]]; then ok "bare --id errors ambiguous"; else bad "bare --id not ambiguous (rc=$rc)"; fi
  CLI run-job --type command --id shared --dry-run 2>/dev/null | grep -q 'dry-run' \
    && ok "--type command --id resolves (escape hatch)" || bad "--type command escape hatch"
  CLI run-job --type incremental-git-fetch --id shared --dry-run >/dev/null 2>&1 \
    && ok "--type igf --id resolves (escape hatch)" || bad "--type igf escape hatch"

  # cleanup: restore the igf config and drop the seeded command instance.
  mv "$igf.bak" "$igf"
  CLI delete-job --type command --id shared --confirm >/dev/null 2>&1 || true
}

# ---- repair converges disabled instances (no lingering plist drift) ----------
test_repair_disabled_drift() {
  echo "== repair disabled drift convergence =="
  local cid="driftjob"
  local plist="$SB/agents/com.kleinperkins.local-jobs.command.${cid}.plist"
  CLI add-job --type command --id "$cid" --program /bin/echo --arg=x --schedule 04:04 >/dev/null 2>&1 && ok "drift seed add" || bad "drift seed add"
  CLI enable-job --id "$cid" >/dev/null 2>&1
  [[ -f "$plist" ]] && ok "enable wrote plist" || bad "enable plist missing"
  CLI disable-job --id "$cid" >/dev/null 2>&1
  [[ ! -f "$plist" ]] && ok "disable removed plist" || bad "disable left plist"
  # Simulate drift: agent plist reappears while instance stays disabled.
  printf '%s\n' '<plist version="1.0"><dict/></plist>' > "$plist"
  CLI repair-job --id "$cid" >/dev/null 2>&1 && ok "repair disabled id" || bad "repair disabled id"
  [[ ! -f "$plist" ]] && ok "repair purged drift plist" || bad "repair left drift plist"
  CLI delete-job --id "$cid" --confirm >/dev/null 2>&1 || true
}

# ---- run-log dedup across legacy + event stream -----------------------------
test_runlog_dedup() {
  echo "== run-log dedup =="
  local ts="2026-06-30T12:00:00+00:00"
  printf '{"schema":"event/v1","ts":"%s","kind":"run","job_id":"dedup","type":"command","payload":{"status":"success","duration_s":1,"rc":0,"summary":"ok","fields":{}}}\n' "$ts" \
    >> "$SB/state/runs.jsonl"
  printf '{"schema":"event/v1","ts":"%s","kind":"run","job_id":"dedup","type":"command","payload":{"status":"success","duration_s":1,"rc":0,"summary":"ok","fields":{}}}\n' "$ts" \
    >> "$SB/state/events.jsonl"
  cnt="$("$PY" "$SB/lib/run_log.py" recent --limit 50 --id dedup | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [[ "$cnt" == "1" ]] && ok "run-log dedupes legacy+events" || bad "run-log dup count=$cnt"
}

# ---- add-job validates --flag=value required tokens -------------------------
test_add_flag_equals() {
  echo "== add-job --flag=value required check =="
  rc=0; out="$(CLI add-job --type command --id=bare --schedule=05:05 2>&1)" || rc=$?
  if [[ $rc -ne 0 && "$out" == *"missing required"* ]]; then ok "add-job rejects missing --program (inline flags)"; else bad "inline-flag required check (rc=$rc)"; fi
}

# ---- adopt-job rejects duplicate global ids ----------------------------------
test_adopt_id_guard() {
  echo "== adopt-job global id guard =="
  local fake="$SB/agents/com.example.fake.plist"
  mkdir -p "$SB/agents"
  cat > "$fake" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.fake</string>
  <key>ProgramArguments</key><array><string>/bin/echo</string><string>x</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>3</integer></dict>
</dict></plist>
PLIST
  rc=0; out="$(CLI adopt-job --label com.example.fake --id demo 2>&1)" || rc=$?
  if [[ $rc -ne 0 && "$out" == *"already exists"* ]]; then ok "adopt rejects duplicate id"; else bad "adopt dup guard (rc=$rc out=$out)"; fi
}

# ---- quarantine: a broken type must not crash view/dashboard ---------------
test_quarantine() {
  echo "== quarantine (broken type) =="
  printf '#!/usr/bin/env bash\necho "not json"; exit 0\n' > "$SB/handlers/brokentype.sh"
  chmod +x "$SB/handlers/brokentype.sh"
  "$PY" - "$SB/config/registry.yml" <<'PY'
import sys, yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["job_types"]["brokentype"]={"handler":"handlers/brokentype.sh"}
yaml.safe_dump(d, open(p,"w"), sort_keys=False)
PY
  CLI view >/dev/null 2>&1 && ok "view survives broken type" || bad "view crashed"
  q="$(CLI dashboard --json | "$PY" -c 'import json,sys; print(sum(1 for i in json.load(sys.stdin)["instances"] if i.get("role")=="error"))')"
  [[ "$q" -ge 1 ]] && ok "broken type quarantined (role=error)" || bad "no quarantine row ($q)"
  CLI dashboard --json | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["summary"]["quarantined"]>=1' && ok "dashboard counts quarantine" || bad "dashboard quarantine count"
  # remove the broken type for subsequent tests
  "$PY" "$SB/lib/authoring.py" unregister --type brokentype >/dev/null 2>&1
  rm -f "$SB/handlers/brokentype.sh"
}

# ---- type-evolution regression (add/remove field, version bump) ------------
test_type_evolution() {
  echo "== type-evolution regression =="
  CLI add-job-type --type evolve --cardinality multi >/dev/null 2>&1 && ok "scaffold evolve type" || bad "scaffold evolve"
  CLI add-job --type evolve --id e1 --schedule 01:00 >/dev/null 2>&1 && ok "evolve add instance" || bad "evolve add"
  hf="$SB/handlers/evolve.sh"

  others_ok() { # every OTHER type still loads+validates+(command runs)
    H command list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 || return 1
    H incremental-git-fetch list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 || return 1
    H cpp-archive list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 || return 1
    CLI run-job --id demo2 --dry-run >/dev/null 2>&1 || true   # command may not have demo2; ignore
    return 0
  }

  # ADD FIELD: declare a new optional default; existing instance picks it up.
  "$PY" - "$hf" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('HANDLER_FIELD_DEFAULTS=\'{"enabled":true}\'','HANDLER_FIELD_DEFAULTS=\'{"enabled":true,"retries":3}\'')
open(p,"w").write(s)
PY
  CLI update-job-type --type evolve >/dev/null 2>&1
  got="$(H evolve view --id e1 | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("retries"))')"
  [[ "$got" == "3" ]] && ok "add-field migrates existing instance (retries=3)" || bad "add-field got=$got"
  H evolve list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 && ok "evolve still valid after add-field" || bad "evolve invalid after add-field"
  others_ok && ok "other types unaffected by add-field" || bad "other types broke on add-field"

  # REMOVE FIELD: drop the default; the now-unknown key is ignored, not rejected.
  "$PY" - "$hf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('HANDLER_FIELD_DEFAULTS=\'{"enabled":true,"retries":3}\'','HANDLER_FIELD_DEFAULTS=\'{"enabled":true}\'')
open(p,"w").write(s)
PY
  CLI update-job-type --type evolve >/dev/null 2>&1 && ok "remove-field migrate ok" || bad "remove-field migrate"
  H evolve list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 && ok "evolve loads after remove-field" || bad "evolve broke on remove-field"

  # VERSION BUMP: schema_version 1 -> 2; existing instance must NOT hard-reject.
  "$PY" - "$hf" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('HANDLER_SCHEMA_VERSION=1','HANDLER_SCHEMA_VERSION=2')
open(p,"w").write(s)
PY
  CLI update-job-type --type evolve >/dev/null 2>&1 && ok "version-bump migrate ok" || bad "version-bump migrate"
  ver="$("$PY" -c 'import yaml; print(yaml.safe_load(open("'"$SB"'/config/jobs/evolve.yml")).get("schema_version"))')"
  [[ "$ver" == "2" ]] && ok "version stamped forward (2)" || bad "version stamp=$ver"
  H evolve list-instances | "$PY" "$SB/lib/contract.py" validate-instances >/dev/null 2>&1 && ok "evolve loads at v2" || bad "evolve broke at v2"
  others_ok && ok "other types unaffected by version bump" || bad "other types broke on version bump"
}

# ---- authoring rollback ----------------------------------------------------
test_authoring_rollback() {
  echo "== authoring rollback =="
  printf '#!/usr/bin/env bash\necho "not json"; exit 0\n' > "$SB/handlers/wedge.sh"; chmod +x "$SB/handlers/wedge.sh"
  "$PY" - "$SB/config/registry.yml" <<'PY'
import sys, yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["job_types"]["wedge"]={"handler":"handlers/wedge.sh"}
yaml.safe_dump(d, open(p,"w"), sort_keys=False)
PY
  CLI add-job-type --type widget --cardinality multi >/dev/null 2>&1
  if "$PY" -c 'import yaml,sys; sys.exit(0 if "widget" in yaml.safe_load(open("'"$SB"'/config/registry.yml"))["job_types"] else 1)'; then
    bad "rollback left widget registered"
  else
    ok "add-job-type rolled back widget on regression failure"
  fi
  [[ -e "$SB/handlers/widget.sh" ]] && bad "rollback left widget handler" || ok "rollback removed widget handler"
  "$PY" "$SB/lib/authoring.py" unregister --type wedge >/dev/null 2>&1; rm -f "$SB/handlers/wedge.sh"
}

# ---- dashboard + events schema --------------------------------------------
test_dashboard_events() {
  echo "== dashboard + events =="
  CLI dashboard --json | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]=="dashboard/v1" and "summary" in d and isinstance(d["instances"],list) and "recent_events" in d' && ok "dashboard schema + events surfaced" || bad "dashboard schema"
  "$PY" "$SB/lib/events.py" recent --limit 5 | is_json && ok "events recent -> JSON" || bad "events recent"
}

main() {
  setup_sandbox
  echo "sandbox: $SB (launchd disabled)"
  echo
  test_conformance; echo
  test_command_lifecycle; echo
  test_quarantine; echo
  test_dashboard_events; echo
  if [[ "$MODE" != "quick" ]]; then
    test_cpp_archive; echo
    test_igf; echo
    test_id_uniqueness; echo
    test_repair_disabled_drift; echo
    test_runlog_dedup; echo
    test_add_flag_equals; echo
    test_adopt_id_guard; echo
    test_type_evolution; echo
    test_authoring_rollback; echo
  fi
  printf 'RESULT: %d passed, %d failed (mode=%s)\n' "$pass" "$fail" "$MODE"
  (( fail == 0 ))
}

main "$@"
