#!/usr/bin/env bash
# Install LD's operator-private local-jobs type overlay into machine state.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE="${LOCAL_JOBS_STATE:-$HOME/.local-jobs}"
REGISTRY_DIR="${LOCAL_JOBS_OVERLAY_DIR:-$STATE/registry.d}"
HANDLER="$ROOT/handlers/cpp-archive.sh"
FRAGMENT="$REGISTRY_DIR/cpp-archive.yml"

mkdir -p "$REGISTRY_DIR"
[[ -x "$HANDLER" ]] || {
  printf 'ERROR: cpp-archive handler is not executable: %s\n' "$HANDLER" >&2
  exit 2
}

tmp="${FRAGMENT}.tmp"
cat >"$tmp" <<YAML
id: cpp-archive
description: Daily archive of committed cpp source refs to KleinPerkins/cpp
handler: "$HANDLER"
YAML
mv -f "$tmp" "$FRAGMENT"

printf 'installed cpp-archive overlay: %s -> %s\n' "$FRAGMENT" "$HANDLER"
