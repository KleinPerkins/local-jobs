#!/usr/bin/env bash
# Self-contained contract check for the operator-private local-jobs overlay.
set -euo pipefail

LOCAL_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${LOCAL_JOBS_PYTHON:-python3}"
SB="$(mktemp -d /tmp/lj-local-overlay.XXXXXX)"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

fail() {
  printf 'local overlay test failed: %s\n' "$*" >&2
  exit 1
}

require_same() {
  local expected="$1" actual="$2" label="$3"
  cmp -s "$expected" "$actual" || fail "$label"
}

command -v "$PY" >/dev/null 2>&1 || fail "python not found: $PY"
bash -n "$LOCAL_REPO/install-overlay.sh"
bash -n "$LOCAL_REPO/handlers/cpp-archive.sh"

mkdir -p "$SB/state" "$SB/registry.d" "$SB/engine/lib" "$SB/fake-archive/bin" "$SB/source"

cat >"$SB/expected-template.yml" <<'YAML'
id: cpp-archive
description: Daily archive of committed cpp source refs to KleinPerkins/cpp
handler: __INSTALLED_BY_INSTALL_OVERLAY__
YAML
require_same \
  "$SB/expected-template.yml" \
  "$LOCAL_REPO/overlay/registry.d/cpp-archive.yml" \
  "source overlay template does not match the cpp-archive contract"

install_output="$(
  LOCAL_JOBS_STATE="$SB/state" \
  LOCAL_JOBS_OVERLAY_DIR="$SB/registry.d" \
    bash "$LOCAL_REPO/install-overlay.sh"
)"
cat >"$SB/expected-installed.yml" <<YAML
id: cpp-archive
description: Daily archive of committed cpp source refs to KleinPerkins/cpp
handler: "$LOCAL_REPO/handlers/cpp-archive.sh"
YAML
require_same \
  "$SB/expected-installed.yml" \
  "$SB/registry.d/cpp-archive.yml" \
  "installed overlay does not match the source contract and absolute handler path"
[[ -x "$LOCAL_REPO/handlers/cpp-archive.sh" ]] || fail "cpp-archive handler is not executable"
[[ "$install_output" == "installed cpp-archive overlay: $SB/registry.d/cpp-archive.yml -> $LOCAL_REPO/handlers/cpp-archive.sh" ]] \
  || fail "installer success output is not deterministic"

# The global engine owns the production chassis. This fixture implements only
# the published describe/run ABI seam needed to exercise this repository's real
# handler without a host checkout, launchd, PyYAML, credentials, or network.
cat >"$SB/engine/lib/handler_lib.sh" <<'SH'
#!/usr/bin/env bash
hl_die() {
  printf '%s: %s\n' "${HANDLER_TYPE:-handler}" "$*" >&2
  exit 2
}
_hl_label_template() {
  if [[ "${HANDLER_CARDINALITY:-multi}" == "singleton" ]]; then
    printf 'com.local-jobs.%s' "$HANDLER_LABEL_TOKEN"
  else
    printf 'com.local-jobs.%s.<id>' "$HANDLER_LABEL_TOKEN"
  fi
}
handler_main() {
  local verb="${1:-}"
  shift || true
  case "$verb" in
    describe) handler_describe ;;
    run) handler_do_run "$@" ;;
    *) hl_die "test chassis supports describe and run only" ;;
  esac
}
SH

cat >"$SB/fake-archive/bin/archive-cpp-local.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${CPP_ARCHIVE_DRY_RUN:-}" == "1" ]] || {
  printf 'expected dry-run flag\n' >&2
  exit 11
}
[[ "${CPP_ARCHIVE_SOURCE_REPO:-}" == "${ARCHIVE_FIXTURE_SOURCE:?}" ]] || {
  printf 'unexpected source repository\n' >&2
  exit 12
}
[[ "${CPP_ARCHIVE_TARGET_REMOTE:-}" == "${ARCHIVE_FIXTURE_REMOTE:?}" ]] || {
  printf 'unexpected target remote\n' >&2
  exit 13
}
if [[ "${ARCHIVE_FIXTURE_FAIL:-0}" == "1" ]]; then
  printf 'archive fixture failed\n'
  exit 7
fi
printf 'archive fixture ok\n'
SH
chmod +x "$SB/fake-archive/bin/archive-cpp-local.sh"

export LOCAL_JOBS_HOME="$SB/engine"
export LOCAL_JOBS_STATE="$SB/state"
export LOCAL_JOBS_CPP_ARCHIVE_CONFIG="$SB/state/jobs/cpp-archive.yml"
export CPP_ARCHIVE_HOME="$SB/fake-archive"
export CPP_ARCHIVE_SOURCE_REPO="$SB/source"
export CPP_ARCHIVE_TARGET_REMOTE="dry-run-target"
export ARCHIVE_FIXTURE_SOURCE="$CPP_ARCHIVE_SOURCE_REPO"
export ARCHIVE_FIXTURE_REMOTE="$CPP_ARCHIVE_TARGET_REMOTE"

describe_output="$("$LOCAL_REPO/handlers/cpp-archive.sh" describe)"
EXPECTED_CONFIG="$LOCAL_JOBS_CPP_ARCHIVE_CONFIG" "$PY" -c '
import json
import os
import sys

record = json.load(sys.stdin)
assert record["type"] == "cpp-archive", record
assert record["cardinality"] == "singleton", record
assert record["label_token"] == "cpp-archive", record
assert record["label_template"] == "com.local-jobs.cpp-archive", record
assert record["schema_version"] == 1, record
assert record["config_file"] == os.environ["EXPECTED_CONFIG"], record
assert [field["flag"] for field in record["add_schema"]] == [
    "--schedule",
    "--display-name",
    "--description",
    "--enabled",
], record
' <<<"$describe_output"

run_output="$("$LOCAL_REPO/handlers/cpp-archive.sh" run --id cpp-archive --dry-run)"
"$PY" -c '
import json
import sys

lines = sys.stdin.read().splitlines()
assert "archive fixture ok" in lines, lines
records = [
    json.loads(line.removeprefix("@@RUNLOG@@ "))
    for line in lines
    if line.startswith("@@RUNLOG@@ ")
]
assert records == [{
    "status": "dry-run",
    "fields": {"exit_code": 0, "last_line": "archive fixture ok"},
}], records
' <<<"$run_output"

set +e
failure_output="$(
  ARCHIVE_FIXTURE_FAIL=1 \
    "$LOCAL_REPO/handlers/cpp-archive.sh" run --id cpp-archive --dry-run 2>&1
)"
failure_rc=$?
set -e
[[ "$failure_rc" -eq 7 ]] || fail "handler did not preserve archive failure exit 7 (got $failure_rc)"
"$PY" -c '
import json
import sys

lines = sys.stdin.read().splitlines()
assert "archive fixture failed" in lines, lines
records = [
    json.loads(line.removeprefix("@@RUNLOG@@ "))
    for line in lines
    if line.startswith("@@RUNLOG@@ ")
]
assert records == [{
    "status": "dry-run",
    "fields": {"exit_code": 7, "last_line": "archive fixture failed"},
}], records
' <<<"$failure_output"

printf 'local overlay test passed\n'
printf 'PR_AUTOMATION_VERIFY_OK\n'
