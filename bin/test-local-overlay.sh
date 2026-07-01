#!/usr/bin/env bash
# Hermetic check for the local-only overlay against the global local-jobs engine.
set -euo pipefail

LOCAL_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBAL_HOME="${LOCAL_JOBS_GLOBAL_HOME:-/Users/laurence.duggan/dev/capabilities/skills/global/skills/local-jobs}"
PY="${LOCAL_JOBS_PYTHON:-python3}"
SB="$(mktemp -d /tmp/lj-local-overlay.XXXXXX)"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

export LOCAL_JOBS_HOME="$GLOBAL_HOME"
export LOCAL_JOBS_STATE="$SB/state"
export LOCAL_JOBS_REGISTRY="$GLOBAL_HOME/config/registry.yml"
export LOCAL_JOBS_LAUNCHD_DISABLE=1
export LOCAL_JOBS_LAUNCHAGENTS_DIR="$SB/agents"
export LOCAL_JOBS_CPP_ARCHIVE_CONFIG="$SB/state/jobs/cpp-archive.yml"
export CPP_ARCHIVE_HOME="$SB/fake-archive"
export CPP_ARCHIVE_SOURCE_REPO="$SB/source"
export CPP_ARCHIVE_TARGET_REMOTE="dry-run-target"

mkdir -p "$SB/state/jobs" "$SB/state/registry.d" "$SB/agents" "$SB/fake-archive/bin" "$SB/source"
printf '#!/usr/bin/env bash
echo "local overlay dry run"
' > "$SB/fake-archive/bin/archive-cpp-local.sh"
chmod +x "$SB/fake-archive/bin/archive-cpp-local.sh"
cat > "$SB/state/jobs/cpp-archive.yml" <<'YAML'
schema: jobs/v1
version: 1
schema_version: 1
instances:
- id: cpp-archive
  enabled: true
  schedule: "18:00"
YAML
cat > "$SB/state/registry.d/cpp-archive.yml" <<YAML
id: cpp-archive
description: Local-only archive handler
handler: "$LOCAL_REPO/handlers/cpp-archive.sh"
YAML

"$GLOBAL_HOME/scripts/local-jobs.sh" list-types --plain | "$PY" -c 'import sys; s=sys.stdin.read(); assert "cpp-archive" in s, s'
"$GLOBAL_HOME/scripts/local-jobs.sh" run-job --type cpp-archive --id cpp-archive --dry-run | "$PY" -c 'import sys; s=sys.stdin.read(); assert "@@RUNLOG@@" in s, s'
printf 'local overlay test passed
'
