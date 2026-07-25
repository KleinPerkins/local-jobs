#!/usr/bin/env bash
# pac-m0-dashboard-snapshot.sh — M0 hourly read-only verify-duration snapshot
#
# Purpose: capture the per-PR verify/sandbox duration history from the controller's
# SQLite journal for the T1 host-sizing study.
#
# Read-only guarantee:
#   • pr-automation-controller dashboard-data → "Emit dashboard-ready JSON"
#     (help text verbatim).  Pure SQLite read; no journal mutation, no lock held.
#
# Output:  ~/.local-jobs/telemetry/pac-m0-dashboard-snapshots.jsonl
# Schema:  pac-m0-dashboard-snapshot/v1
#
# Fields per line:
#   ts              ISO-8601 UTC timestamp of this snapshot
#   schema          "pac-m0-dashboard-snapshot/v1"
#   run_count       number of .runs[] items in this snapshot
#   runs            array of {repository, pull_request, outcome, duration_ms,
#                   started_at, finished_at, deepest_stage}
#                   duration_ms is the total verify/sandbox wall-clock time in ms
#
# Analysis note: at analysis time, use duration_ms to build the verify-duration
# distribution.  That distribution, combined with PR volume from the poll run-log
# and the pressure/headroom history from pac-m0-telemetry.jsonl, drives the
# Linux host sizing and re-derivation of the disk/memory reserve constants.
#
# Stop/remove:
#   bash ~/.claude/skills/local-jobs/scripts/local-jobs.sh delete-job --id pac-m0-dashboard-snapshot --confirm

set -euo pipefail

PAC_BIN="${PAC_BIN:-$HOME/.local/share/pr-automation-controller/current/pr-automation-controller}"
TELEMETRY_DIR="${PAC_M0_TELEMETRY_DIR:-$HOME/.local-jobs/telemetry}"
SNAPSHOT_LOG="$TELEMETRY_DIR/pac-m0-dashboard-snapshots.jsonl"

mkdir -p "$TELEMETRY_DIR"

# Read-only dashboard snapshot
DASHBOARD_JSON=$("$PAC_BIN" dashboard-data 2>/dev/null) \
  || DASHBOARD_JSON='{"runs":[]}'

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$DASHBOARD_JSON" | jq -c \
  --arg ts "$TS" \
  '{
    ts:        $ts,
    schema:    "pac-m0-dashboard-snapshot/v1",
    run_count: (.history.runs | length),
    runs: [.history.runs[] | {
      repository:    .repository,
      pull_request:  .pull_request,
      outcome:       .outcome,
      duration_ms:   .duration_ms,
      started_at:    .started_at,
      finished_at:   .finished_at,
      deepest_stage: .deepest_stage
    }]
  }' >> "$SNAPSHOT_LOG"
