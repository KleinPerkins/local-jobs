#!/usr/bin/env bash
# pac-m0-telemetry.sh — M0 passive read-only host + pressure telemetry
#
# Purpose: accumulate days of host-sizing evidence for the T1 pivot (Linux re-host).
# Fires every ~120 s via local-jobs; appends ONE timestamped JSON line per run.
#
# Read-only guarantees:
#   • pr-automation-controller status --json → "Emit controller and queue state
#     without mutation" (help text verbatim).  No journal write, no lock held.
#   • vm_stat, sysctl hw.pagesize/hw.memsize, sysctl vm.swapusage → plain macOS
#     read-only sysctls; no side effects.
#   • This script never calls poll-once, recover, pause, or any mutating subcommand.
#
# Output:  ~/.local-jobs/telemetry/pac-m0-telemetry.jsonl
# Schema:  pac-m0-telemetry/v1
#
# Fields:
#   ts                      ISO-8601 UTC timestamp of this sample
#   pressure_state          controller admission pressure: normal|warn|critical|stale|unavailable
#   queue_depth             {in_flight_attempts, owed_runs, state} from status --json
#   stage_duration          {state, ...} from status --json (idle when no active verify)
#   host.pages_free         raw vm_stat "Pages free" count (multiply by page_size_bytes for bytes)
#   host.page_size_bytes    hw.pagesize (16384 on M-series Macs)
#   host.free_headroom_gib  pages_free * page_size / 1 GiB  — the admission headroom signal
#   host.swapins_cumulative running vm_stat "Swapins" counter (take delta between samples
#                           at analysis time to compute swap-in rate per interval)
#   host.mem_total_bytes    hw.memsize (total installed RAM in bytes)
#   host.swap_used_mib      vm.swapusage "used" field in MiB
#
# Analysis note (M0 output, NOT computed here):
#   • Deferral cause: extracted at analysis time from the existing poll run-log at
#     ~/Library/Logs/local-jobs/command-pr-automation-controller.out.log
#     (search for .deferrals[].reason = RuntimePressure|ClaimActive|RuntimeDeadline|ProfileCollision)
#   • Verify/sandbox duration: captured separately by pac-m0-dashboard-snapshot.sh (hourly)
#     from `dashboard-data` .runs[].duration_ms
#   • Intended analysis (do NOT run until days of data accumulate):
#     PR volume, pressure/swap/headroom history → Linux host sizing;
#     re-derivation of CONCURRENT_DEV_MEMORY_RESERVE_GIB (compile-time assertion) AND
#     CONCURRENT_DEV_DISK_RESERVE_GIB (runtime-enforced at claims.rs:224) for the
#     target Linux disk size.
#
# Stop/remove:
#   bash ~/.claude/skills/local-jobs/scripts/local-jobs.sh delete-job --id pac-m0-telemetry --confirm

set -euo pipefail

PAC_BIN="${PAC_BIN:-$HOME/.local/share/pr-automation-controller/current/pr-automation-controller}"
TELEMETRY_DIR="${PAC_M0_TELEMETRY_DIR:-$HOME/.local-jobs/telemetry}"
TELEMETRY_LOG="$TELEMETRY_DIR/pac-m0-telemetry.jsonl"

mkdir -p "$TELEMETRY_DIR"

# ── 1. Read-only status snapshot ──────────────────────────────────────────────
STATUS_JSON=$("$PAC_BIN" status --json 2>/dev/null) \
  || STATUS_JSON='{"operator_floor":{"pressure":{"state":"unavailable"},"queue_depth":{"state":"error"},"stage_duration":{"state":"error"}}}'

# ── 2. Host memory: read-only sysctls + vm_stat ───────────────────────────────
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
MEM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

VMSTAT=$(vm_stat 2>/dev/null || echo "")
PAGES_FREE=$(echo "$VMSTAT" | awk '/Pages free:/ { gsub(/\./,"",$3); print $3+0 }')
SWAPINS_CUMULATIVE=$(echo "$VMSTAT" | awk '/Swapins:/ { gsub(/\./,"",$2); print $2+0 }')

# Default to 0 if vm_stat parsing failed
PAGES_FREE=${PAGES_FREE:-0}
SWAPINS_CUMULATIVE=${SWAPINS_CUMULATIVE:-0}

# Free headroom in GiB (the same quantity admission checks)
FREE_HEADROOM_GIB=$(awk "BEGIN { printf \"%.4f\", ($PAGES_FREE * $PAGE_SIZE) / 1073741824 }")

# Swap used in MiB from vm.swapusage: "total = 2048.00M  used = 350.75M  ..."
SWAP_USED_MIB=$(sysctl -n vm.swapusage 2>/dev/null \
  | awk '{ for(i=1;i<=NF;i++) if($i=="used") { v=$(i+2); gsub(/[^0-9.]/,"",v); printf "%.2f", v+0; break } }' \
  || echo "0.00")
SWAP_USED_MIB=${SWAP_USED_MIB:-0.00}

# ── 3. Emit one JSON line ─────────────────────────────────────────────────────
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$STATUS_JSON" | jq -c \
  --arg    ts             "$TS" \
  --argjson page_size      "$PAGE_SIZE" \
  --argjson mem_total      "$MEM_TOTAL_BYTES" \
  --argjson pages_free     "$PAGES_FREE" \
  --argjson free_gib       "$FREE_HEADROOM_GIB" \
  --argjson swapins        "$SWAPINS_CUMULATIVE" \
  --argjson swap_used_mib  "$SWAP_USED_MIB" \
  '{
    ts:             $ts,
    schema:         "pac-m0-telemetry/v1",
    pressure_state: .operator_floor.pressure.state,
    queue_depth:    .operator_floor.queue_depth,
    stage_duration: .operator_floor.stage_duration,
    host: {
      page_size_bytes:    $page_size,
      mem_total_bytes:    $mem_total,
      pages_free:         $pages_free,
      free_headroom_gib:  $free_gib,
      swapins_cumulative: $swapins,
      swap_used_mib:      $swap_used_mib
    }
  }' >> "$TELEMETRY_LOG"
