#!/usr/bin/env bash
# Scaffold a new ABI-conformant job type: handler stub + backend dir + registry
# entry. Lowers the cost of adding future types (architecture A7).
#
# Usage: add-job-type.sh --type <type> [--cardinality singleton|multi] [--description "..."]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

type=""; cardinality="multi"; description=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) shift; type="${1:-}" ;;
    --cardinality) shift; cardinality="${1:-multi}" ;;
    --description) shift; description="${1:-}" ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -n "$type" ]] || die "add-job-type requires --type"
[[ "$cardinality" == "singleton" || "$cardinality" == "multi" ]] || die "cardinality must be singleton|multi"

handler="$LOCAL_JOBS_HOME/handlers/${type}.sh"
backend="$LOCAL_JOBS_HOME/backends/${type}"
[[ -e "$handler" ]] && die "handler already exists: $handler"

mkdir -p "$backend"
token="${type//[^a-z0-9]/-}"
cat >"$handler" <<HANDLER
#!/usr/bin/env bash
# Handler plugin: ${type} (ABI v1 scaffold — fill in the TODOs).
set -euo pipefail
SCRIPT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="\${LOCAL_JOBS_HOME:-\$(cd -- "\$SCRIPT_DIR/.." && pwd)}"
LOCAL_JOBS_PYTHON="\${LOCAL_JOBS_PYTHON:-python3}"
LABEL_PREFIX="com.kleinperkins.local-jobs.${token}"
die() { printf '${type}: %s\\n' "\$*" >&2; exit 2; }

case "\${1:-}" in
  describe)
    "\$LOCAL_JOBS_PYTHON" - "\$LABEL_PREFIX" <<'PY'
import json, sys
print(json.dumps({
    "type": "${type}",
    "cardinality": "${cardinality}",
    "label_token": "${token}",
    "label_template": sys.argv[1] + ("" if "${cardinality}" == "singleton" else ".<id>"),
    "config_file": None,
    "add_schema": [
        {"flag": "--id", "required": ${cardinality:+true}, "help": "instance id"},
        # TODO: declare type-specific add flags here
    ],
}, indent=2))
PY
    ;;
  list-instances) printf '[]\\n' ;;          # TODO: enumerate instances
  view) die "TODO: implement view" ;;
  run) printf '@@RUNLOG@@ {"status":"success","fields":{}}\\n' ;;  # TODO: real run
  logs) die "TODO: implement logs" ;;
  add|update|delete|enable|disable|repair) die "TODO: implement \$1" ;;
  doctor) printf '== ${type} doctor ==\\ndoctor: PASS\\n' ;;
  *) die "unknown verb: \${1:-}" ;;
esac
HANDLER
chmod +x "$handler"

cat >"$backend/README.md" <<EOF
# ${type} backend

Scaffolded by add-job-type.sh. Implement the run logic here and wire the
handler verbs (\`handlers/${type}.sh\`) to the ABI in ../../ABI.md.
EOF

log "created handler: $handler"
log "created backend dir: $backend"
log "Next: register it under job_types in config/registry.yml:"
cat <<EOF

  ${type}:
    description: ${description:-TODO describe ${type}}
    handler: handlers/${type}.sh
EOF
