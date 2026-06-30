#!/usr/bin/env bash
# Handler plugin: incremental-git-fetch (dev-fetch backend)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_JOBS_HOME="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DEV_FETCH_HOME="${DEV_FETCH_HOME:-$HOME/dev/personal/dev-fetch}"
BACKEND="$DEV_FETCH_HOME/bin/dev-fetch.sh"

die() { printf 'incremental-git-fetch: %s\n' "$*" >&2; exit 2; }

[[ -x "$BACKEND" ]] || die "backend not found: $BACKEND"

usage() {
  cat <<USAGE
incremental-git-fetch handler verbs:
  view add update delete repair enable disable doctor
USAGE
}

parse_schedule() {
  local raw="$1"
  case "$raw" in
    inherit) printf 'inherit' ;;
    *:*)
      local h="${raw%%:*}"
      local m="${raw#*:}"
      printf '%s:%s' "$h" "$m"
      ;;
    *) die "invalid schedule (use inherit or HH:MM): $raw" ;;
  esac
}

case "${1:-}" in
  view)
    "$BACKEND" view
    ;;
  add)
    shift
    id="" path="" branch="" schedule="inherit" enabled="true"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --path) shift; path="${1:-}" ;;
        --branch) shift; branch="${1:-}" ;;
        --schedule) shift; schedule="$(parse_schedule "${1:-}")" ;;
        --enabled) shift; enabled="${1:-}" ;;
        *) die "unknown add option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" && -n "$path" && -n "$branch" ]] || die "add requires --id --path --branch"
    args=(add --id "$id" --path "$path" --branch "$branch" --enabled "$enabled" --schedule "$schedule")
    "$BACKEND" "${args[@]}"
    ;;
  update)
    shift
    id="" schedule="" enabled="" global=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --schedule) shift; schedule="$(parse_schedule "${1:-}")" ;;
        --enabled) shift; enabled="${1:-}" ;;
        --global) global=1 ;;
        *) die "unknown update option: $1" ;;
      esac
      shift
    done
    if [[ -n "$enabled" ]]; then
      [[ -n "$id" ]] || die "update --enabled requires --id"
      case "$enabled" in
        true|1|yes) "$BACKEND" enable --id "$id" ;;
        false|0|no) "$BACKEND" disable --id "$id" ;;
        *) die "invalid --enabled value: $enabled" ;;
      esac
    fi
    if [[ -n "$schedule" ]]; then
      if (( global == 1 )) || [[ "$id" == "__global__" ]]; then
        if [[ "$schedule" == "inherit" ]]; then
          die "global schedule cannot be inherit"
        fi
        hour="${schedule%%:*}"
        minute="${schedule#*:}"
        "$BACKEND" set-schedule --global --hour "$hour" --minute "$minute"
      else
        [[ -n "$id" ]] || die "update --schedule requires --id or --global"
        if [[ "$schedule" == "inherit" ]]; then
          "$BACKEND" set-schedule --id "$id" --inherit
        else
          hour="${schedule%%:*}"
          minute="${schedule#*:}"
          "$BACKEND" set-schedule --id "$id" --hour "$hour" --minute "$minute"
        fi
      fi
    fi
    if [[ -z "$enabled" && -z "$schedule" ]]; then
      die "update requires --schedule and/or --enabled"
    fi
    ;;
  delete)
    shift
    id="" purge=0 confirm=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --purge-launchd) purge=1 ;;
        --confirm) confirm=1 ;;
        *) die "unknown delete option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" ]] || die "delete requires --id"
    [[ "$id" != "__global__" ]] || die "cannot delete global scheduler"
    (( confirm == 1 )) || die "delete requires --confirm (destructive)"
    args=(remove --id "$id")
    (( purge == 1 )) && args+=(--purge-launchd)
    "$BACKEND" "${args[@]}"
    ;;
  repair)
    shift
    id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        --all) id="__all__" ;;
        *) die "unknown repair option: $1" ;;
      esac
      shift
    done
    # dev-fetch repair is all-in-one (global + per-repo agents)
    "$BACKEND" repair
    ;;
  enable)
    shift
    id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        *) die "unknown enable option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" ]] || die "enable requires --id"
    [[ "$id" != "__global__" ]] || die "use repair to enable global scheduler"
    "$BACKEND" enable --id "$id"
    ;;
  disable)
    shift
    id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) shift; id="${1:-}" ;;
        *) die "unknown disable option: $1" ;;
      esac
      shift
    done
    [[ -n "$id" ]] || die "disable requires --id"
    [[ "$id" != "__global__" ]] || die "cannot disable global scheduler via disable; use launchctl bootout"
    "$BACKEND" disable --id "$id"
    ;;
  doctor)
    "$BACKEND" doctor
    ;;
  "")
    usage
    exit 2
    ;;
  *)
    die "unknown verb: $1"
    ;;
esac
