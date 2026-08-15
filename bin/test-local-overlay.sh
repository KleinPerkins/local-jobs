#!/usr/bin/env bash
# Self-contained contract check for the operator-private local-jobs overlay.
set -euo pipefail

LOCAL_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${LOCAL_JOBS_PYTHON:-python3}"
TMP_ROOT="${TMPDIR:-$PWD}"
SB="$(mktemp -d "$TMP_ROOT/lj-local-overlay.XXXXXX")"
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
    test-launchd-env) handler_launchd_env ;;
    test-working-dir) handler_working_dir ;;
    *) hl_die "test chassis supports describe, run, and test introspection only" ;;
  esac
}
SH

ln -s /usr/bin/env "$SB/fake-archive/bin/archive-cpp-local.sh"
mkdir -p "$SB/home"
handler_env=(
  env -i
  "PATH=$PATH"
  "HOME=$SB/home"
  "LOCAL_JOBS_HOME=$SB/engine"
  "LOCAL_JOBS_STATE=$SB/state"
  "LOCAL_JOBS_CPP_ARCHIVE_CONFIG=$SB/state/jobs/cpp-archive.yml"
  "CPP_ARCHIVE_HOME=$SB/fake-archive"
  "CPP_ARCHIVE_SOURCE_REPO=$SB/source"
  "CPP_ARCHIVE_TARGET_REMOTE=dry-run-target"
)

describe_output="$("${handler_env[@]}" "$LOCAL_REPO/handlers/cpp-archive.sh" describe)"
EXPECTED_CONFIG="$SB/state/jobs/cpp-archive.yml" "$PY" -c '
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

launchd_output="$("${handler_env[@]}" "$LOCAL_REPO/handlers/cpp-archive.sh" test-launchd-env)"
EXPECTED_SOURCE="$SB/source" "$PY" -c '
import json
import os
import sys

record = json.load(sys.stdin)
assert record == {
    "CPP_ARCHIVE_SOURCE_REPO": os.environ["EXPECTED_SOURCE"],
    "CPP_ARCHIVE_TARGET_REMOTE": "dry-run-target",
}, record
' <<<"$launchd_output"

working_dir="$("${handler_env[@]}" "$LOCAL_REPO/handlers/cpp-archive.sh" test-working-dir)"
[[ "$working_dir" == "$SB/fake-archive" ]] || fail "handler working directory is not the archive home"

run_output="$("${handler_env[@]}" "$LOCAL_REPO/handlers/cpp-archive.sh" run --id cpp-archive --dry-run)"
EXPECTED_SOURCE="$SB/source" "$PY" -c '
import json
import os
import sys

lines = sys.stdin.read().splitlines()
environment = dict(line.split("=", 1) for line in lines if "=" in line)
assert environment["CPP_ARCHIVE_DRY_RUN"] == "1", environment
assert environment["CPP_ARCHIVE_SOURCE_REPO"] == os.environ["EXPECTED_SOURCE"], environment
assert environment["CPP_ARCHIVE_TARGET_REMOTE"] == "dry-run-target", environment
records = [
    json.loads(line.removeprefix("@@RUNLOG@@ "))
    for line in lines
    if line.startswith("@@RUNLOG@@ ")
]
assert len(records) == 1, records
assert records[0]["status"] == "dry-run", records
assert records[0]["fields"]["exit_code"] == 0, records
' <<<"$run_output"

rm "$SB/fake-archive/bin/archive-cpp-local.sh"
ln -s /usr/bin/false "$SB/fake-archive/bin/archive-cpp-local.sh"
set +e
failure_output="$(
  "${handler_env[@]}" "$LOCAL_REPO/handlers/cpp-archive.sh" run --id cpp-archive --dry-run 2>&1
)"
failure_rc=$?
set -e
[[ "$failure_rc" -eq 1 ]] || fail "handler did not preserve archive failure exit 1 (got $failure_rc)"
"$PY" -c '
import json
import sys

lines = sys.stdin.read().splitlines()
records = [
    json.loads(line.removeprefix("@@RUNLOG@@ "))
    for line in lines
    if line.startswith("@@RUNLOG@@ ")
]
assert records == [{
    "status": "dry-run",
    "fields": {"exit_code": 1, "last_line": ""},
}], records
' <<<"$failure_output"

printf 'local overlay test passed\n'
printf 'PR_AUTOMATION_VERIFY_OK\n'
