#!/usr/bin/env bash
# BEGIN KleinPerkins/dev baseline (managed by KleinPerkins/dev; do not hand-edit — see _ops/baseline/README.md in KleinPerkins/dev)
# .github/scripts/baseline-verify.sh — vendored, SELF-CONTAINED baseline check.
#
# This file is copied verbatim into every baselined repo. It must never depend on ~/dev paths,
# network access, or anything outside this checkout — CI runs it with only `actions/checkout`.
# Re-render with: repo-baseline.sh apply <repo>   (run from a KleinPerkins/dev checkout).
#
# Checks only portable invariants (v1 scope — no auto-detected test/lint execution):
#   - required baseline files are present
#   - the managed .gitignore block is present
#   - no obviously-committed credential filenames
#   - this repo's own baseline workflow declares minimal permissions
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
fail=0
pass() { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "== baseline-verify: required files present =="
for rel in SECURITY.md .github/CODEOWNERS .github/workflows/baseline.yml .github/scripts/baseline-verify.sh; do
  if [ -f "$ROOT/$rel" ]; then pass "$rel present"; else bad "$rel MISSING"; fi
done

echo "== baseline-verify: managed .gitignore block present =="
if [ -f "$ROOT/.gitignore" ] && grep -qF '# BEGIN KleinPerkins/dev baseline' "$ROOT/.gitignore"; then
  pass ".gitignore managed block present"
else
  bad ".gitignore managed block MISSING"
fi

echo "== baseline-verify: no obviously-committed credential files =="
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cred_pattern='\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|\.keystore$|\.kdbx$|id_rsa|id_dsa|id_ed25519|\.netrc$|\.pgpass$|(^|/)credentials$|(^|/)credentials\.|service-account.*\.json$|(^|/)\.env$|\.env\.[^.]+$'
  hits="$(git -C "$ROOT" ls-files 2>/dev/null | grep -E "$cred_pattern" | grep -vE '\.env\.(example|sample|template)$' || true)"
  if [ -z "$hits" ]; then
    pass "no obviously-committed credential filenames"
  else
    bad "possible committed credential files:"
    printf '        %s\n' $hits
  fi
else
  bad "not a git work tree — cannot audit tracked files"
fi

echo "== baseline-verify: this repo's baseline workflow declares minimal permissions =="
wf="$ROOT/.github/workflows/baseline.yml"
if [ -f "$wf" ] && grep -qE '^[[:space:]]*permissions:[[:space:]]*$' "$wf" && grep -qE '^[[:space:]]*contents:[[:space:]]*read[[:space:]]*$' "$wf"; then
  pass "baseline.yml declares permissions: contents: read"
else
  bad "baseline.yml missing a minimal top-level 'permissions: contents: read'"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "baseline-verify: OK"
else
  echo "baseline-verify: FAILED (see FAIL lines above)"
fi
exit "$fail"
# END KleinPerkins/dev baseline
