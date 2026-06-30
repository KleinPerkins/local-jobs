#!/usr/bin/env bash
# Handler plugin: command (generic scheduled program, ABI v1).
# Self-manages its plist; no backend repo. Scheduled runs go through the
# framework run-scheduled wrapper for uniform run-logging.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="${LOCAL_JOBS_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOCAL_JOBS_PYTHON="${LOCAL_JOBS_PYTHON:-python3}"
STORE="$LOCAL_JOBS_HOME/lib/command_store.py"
LABEL_PREFIX="com.kleinperkins.local-jobs.command"
LOG_DIR="$HOME/Library/Logs/local-jobs"
RUN_SCHEDULED="$LOCAL_JOBS_HOME/bin/run-scheduled.sh"
export LOCAL_JOBS_HOME

die() { printf 'command: %s\n' "$*" >&2; exit 2; }
store() { "$LOCAL_JOBS_PYTHON" "$STORE" "$@"; }
uid_domain() { printf 'gui/%s' "$(id -u)"; }
is_loaded() { launchctl print "$(uid_domain)/$1" >/dev/null 2>&1; }
escape_xml() { /usr/bin/python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$1"; }

label_for() { printf '%s.%s' "$LABEL_PREFIX" "$1"; }
out_log_for() { printf '%s/command-%s.out.log' "$LOG_DIR" "$1"; }
err_log_for() { printf '%s/command-%s.err.log' "$LOG_DIR" "$1"; }

usage() { printf 'command handler verbs:\n  describe list-instances view run logs add update delete repair enable disable doctor\n'; }

install_plist() {
  local iid="$1"
  local entry label hour minute out_log err_log
  entry="$(store get --id "$iid")"
  label="$(label_for "$iid")"
  out_log="$(out_log_for "$iid")"
  err_log="$(err_log_for "$iid")"
  hour="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["schedule"].split(":")[0])' <<<"$entry")"
  minute="$("$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["schedule"].split(":")[1])' <<<"$entry")"
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  ENTRY="$entry" LABEL="$label" HOUR="$hour" MINUTE="$minute" RUN_SCHEDULED="$RUN_SCHEDULED" \
    LOCAL_JOBS_HOME="$LOCAL_JOBS_HOME" OUT_LOG="$out_log" ERR_LOG="$err_log" IID="$iid" \
    "$LOCAL_JOBS_PYTHON" - >"$HOME/Library/LaunchAgents/${label}.plist" <<'PY'
import html, json, os
entry = json.loads(os.environ["ENTRY"])
def esc(s): return html.escape(str(s), quote=True)
env = dict(entry.get("env") or {})
env["LOCAL_JOBS_HOME"] = os.environ["LOCAL_JOBS_HOME"]
env.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
prog = [os.environ["RUN_SCHEDULED"], "--type", "command", "--id", os.environ["IID"]]
lines = ['<?xml version="1.0" encoding="UTF-8"?>',
 '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
 '<plist version="1.0">', '<dict>',
 '  <key>Label</key>', f'  <string>{esc(os.environ["LABEL"])}</string>',
 '  <key>ProgramArguments</key>', '  <array>']
for a in prog:
    lines.append(f'    <string>{esc(a)}</string>')
lines += ['  </array>', '  <key>EnvironmentVariables</key>', '  <dict>']
for k, v in env.items():
    lines += [f'    <key>{esc(k)}</key>', f'    <string>{esc(v)}</string>']
lines += ['  </dict>',
 '  <key>StartCalendarInterval</key>', '  <dict>',
 f'    <key>Hour</key><integer>{int(os.environ["HOUR"])}</integer>',
 f'    <key>Minute</key><integer>{int(os.environ["MINUTE"])}</integer>', '  </dict>',
 '  <key>StandardOutPath</key>', f'  <string>{esc(os.environ["OUT_LOG"])}</string>',
 '  <key>StandardErrorPath</key>', f'  <string>{esc(os.environ["ERR_LOG"])}</string>',
 '</dict>', '</plist>']
print("\n".join(lines))
PY
  chmod 0644 "$HOME/Library/LaunchAgents/${label}.plist"
  launchctl bootout "$(uid_domain)/${label}" >/dev/null 2>&1 || true
  launchctl bootstrap "$(uid_domain)" "$HOME/Library/LaunchAgents/${label}.plist"
}

cmd_describe() {
  "$LOCAL_JOBS_PYTHON" - "$LABEL_PREFIX" <<'PY'
import json, sys
print(json.dumps({
    "type": "command",
    "cardinality": "multi",
    "label_token": "command",
    "label_template": f"{sys.argv[1]}.<id>",
    "config_file": None,
    "add_schema": [
        {"flag": "--id", "required": True, "help": "stable instance id"},
        {"flag": "--program", "required": True, "help": "absolute path to executable"},
        {"flag": "--schedule", "required": True, "help": "HH:MM"},
        {"flag": "--arg", "required": False, "help": "program arg (repeatable)"},
        {"flag": "--env", "required": False, "help": "K=V (repeatable)"},
        {"flag": "--enabled", "required": False, "help": "true | false"},
    ],
}, indent=2))
PY
}

cmd_list_instances() {
  local raw; raw="$(store list)"
  RAW="$raw" PREFIX="$LABEL_PREFIX" LOG_DIR="$LOG_DIR" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess
raw = json.loads(os.environ["RAW"])
prefix = os.environ["PREFIX"]; log_dir = os.environ["LOG_DIR"]
uid = os.getuid()
def loaded(label):
    return subprocess.run(["launchctl","print",f"gui/{uid}/{label}"],capture_output=True).returncode==0
out=[]
for e in raw:
    iid=e["id"]; label=f"{prefix}.{iid}"
    out.append({
        "id": iid, "type": "command", "role": "instance",
        "enabled": e.get("enabled", True), "schedule": e.get("schedule"),
        "program": e.get("program"), "args": e.get("args") or [], "env": e.get("env") or {},
        "launchd_label": label, "launchd_loaded": loaded(label),
        "log_paths": {"stdout": f"{log_dir}/command-{iid}.out.log",
                       "stderr": f"{log_dir}/command-{iid}.err.log"},
    })
print(json.dumps(out, indent=2))
PY
}

cmd_view() {
  local id="$1"; [[ -n "$id" ]] || die "view requires --id"
  cmd_list_instances | LOCAL_JOBS_TARGET="$id" "$LOCAL_JOBS_PYTHON" -c '
import json,os,sys
t=os.environ["LOCAL_JOBS_TARGET"]
for i in json.load(sys.stdin):
    if i.get("id")==t: print(json.dumps(i,indent=2)); break
else: sys.exit(f"unknown instance: {t}")'
}

cmd_run() {
  local id="" dry=0
  while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; --dry-run) dry=1 ;; *) die "unknown run option: $1" ;; esac; shift; done
  [[ -n "$id" ]] || die "run requires --id"
  local entry; entry="$(store get --id "$id")"
  ENTRY="$entry" DRY="$dry" "$LOCAL_JOBS_PYTHON" - <<'PY'
import json, os, subprocess, sys
entry = json.loads(os.environ["ENTRY"])
dry = os.environ["DRY"] == "1"
cmd = [entry["program"], *(entry.get("args") or [])]
env = {**os.environ, **(entry.get("env") or {})}
if dry:
    print(f"[dry-run] would run: {' '.join(cmd)}")
    print("@@RUNLOG@@ " + json.dumps({"status":"dry-run","fields":{"exit_code":0,"last_line":"dry-run"}}, separators=(",",":")))
    sys.exit(0)
proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
out = (proc.stdout or "") + (proc.stderr or "")
sys.stdout.write(out)
last = (out.strip().splitlines() or [""])[-1]
status = "success" if proc.returncode == 0 else "failure"
print("@@RUNLOG@@ " + json.dumps({"status":status,"fields":{"exit_code":proc.returncode,"last_line":last[:200]}}, separators=(",",":")))
sys.exit(proc.returncode)
PY
}

cmd_logs() {
  local id="" tail=40
  while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; --tail) shift; tail="${1:-40}" ;; *) die "unknown logs option: $1" ;; esac; shift; done
  [[ -n "$id" ]] || die "logs requires --id"
  local o e; o="$(out_log_for "$id")"; e="$(err_log_for "$id")"
  printf 'stdout: %s\nstderr: %s\n' "$o" "$e"
  for f in "$o" "$e"; do
    printf '\n-- %s (tail %s) --\n' "$f" "$tail"
    [[ -f "$f" ]] && tail -n "$tail" "$f" || printf '(no log yet)\n'
  done
}

case "${1:-}" in
  describe) cmd_describe ;;
  list-instances) cmd_list_instances ;;
  view) shift; id=""; while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown view option: $1" ;; esac; shift; done; cmd_view "$id" ;;
  run) shift; cmd_run "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  add)
    shift
    args=(add)
    enabled_seen=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; args+=(--id "${1:-}") ;;
        --program) shift; args+=(--program "${1:-}") ;;
        --schedule) shift; args+=(--schedule "${1:-}") ;;
        --arg) shift; args+=("--arg=${1:-}") ;;
        --arg=*) args+=("$1") ;;
        --env) shift; args+=("--env=${1:-}") ;;
        --env=*) args+=("$1") ;;
        --enabled) shift; args+=(--enabled "${1:-}"); enabled_seen=1 ;;
        --dry-run) args+=(--dry-run) ;;
        *) die "unknown add option: $1" ;;
      esac
      shift
    done
    out="$(store "${args[@]}")"; printf '%s\n' "$out"
    if [[ "$out" != *dry_run* ]]; then
      iid="$("$LOCAL_JOBS_PYTHON" -c 'import sys; a=sys.argv[1:]; print(a[a.index("--id")+1])' "${args[@]}")"
      enabled="$(store get --id "$iid" | "$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("enabled",True))')"
      [[ "$enabled" == "True" ]] && install_plist "$iid"
    fi
    ;;
  update)
    shift
    id="" schedule="" enabled=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --schedule) shift; schedule="${1:-}" ;;
        --enabled) shift; enabled="${1:-}" ;;
        *) die "unknown update option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" ]] || die "update requires --id"
    set_args=(set --id "$id")
    [[ -n "$schedule" ]] && set_args+=(--schedule "$schedule")
    [[ -n "$enabled" ]] && set_args+=(--enabled "$enabled")
    store "${set_args[@]}"
    if [[ "$enabled" == "false" || "$enabled" == "0" || "$enabled" == "no" ]]; then
      launchctl bootout "$(uid_domain)/$(label_for "$id")" >/dev/null 2>&1 || true
    else
      install_plist "$id"
    fi
    ;;
  delete)
    shift
    id="" confirm=0
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; --confirm) confirm=1 ;; --purge-launchd) ;; *) die "unknown delete option: $1" ;; esac; shift; done
    [[ -n "$id" ]] || die "delete requires --id"
    (( confirm == 1 )) || die "delete requires --confirm"
    launchctl bootout "$(uid_domain)/$(label_for "$id")" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/LaunchAgents/$(label_for "$id").plist"
    store remove --id "$id" >/dev/null
    printf 'removed command instance %s\n' "$id"
    ;;
  enable)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown enable option: $1" ;; esac; shift; done
    [[ -n "$id" ]] || die "enable requires --id"
    store set --id "$id" --enabled true; install_plist "$id"
    ;;
  disable)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; *) die "unknown disable option: $1" ;; esac; shift; done
    [[ -n "$id" ]] || die "disable requires --id"
    store set --id "$id" --enabled false
    launchctl bootout "$(uid_domain)/$(label_for "$id")" >/dev/null 2>&1 || true
    ;;
  repair)
    shift; id=""
    while [[ $# -gt 0 ]]; do case "$1" in --id) shift; id="${1:-}" ;; --all) ;; *) die "unknown repair option: $1" ;; esac; shift; done
    if [[ -n "$id" ]]; then
      install_plist "$id"
    else
      while IFS= read -r iid; do [[ -n "$iid" ]] && install_plist "$iid"; done < <(store list | "$LOCAL_JOBS_PYTHON" -c 'import json,sys; [print(e["id"]) for e in json.load(sys.stdin) if e.get("enabled",True)]')
    fi
    printf 'repair: complete\n'
    ;;
  doctor)
    issues=0
    printf '== command doctor ==\n'
    if "$LOCAL_JOBS_PYTHON" -c 'import yaml' 2>/dev/null; then printf 'PyYAML: ok\n'; else printf 'PyYAML: missing\n'; issues=$((issues+1)); fi
    if store validate >/dev/null 2>&1; then printf 'store: ok\n'; else printf 'store: INVALID\n'; issues=$((issues+1)); fi
    count="$(store list | "$LOCAL_JOBS_PYTHON" -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    printf 'instances: %s\n' "$count"
    if (( issues == 0 )); then printf 'doctor: PASS\n'; else printf 'doctor: FAIL (%s)\n' "$issues"; exit 1; fi
    ;;
  ""|-h|--help) usage; exit 2 ;;
  *) die "unknown verb: $1" ;;
esac
