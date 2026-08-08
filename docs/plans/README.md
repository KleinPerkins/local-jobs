# Plans

This directory contains multi-session plans for `local-jobs`.

**Governance:** `~/dev/_ops/doc-warden/POLICY.md` §2 (taxonomy), §9 (archival).
Plans are **byte-identical-forever** once their Status line reads `ACCEPTED` — no in-place edits
after approval. A revision is a new `{{slug}}-v2.md` with a `Supersedes:` pointer; the prior
version is never modified.

## Index

| Plan | Status | Date | Notes |
|---|---|---|---|
| <!-- TODO: doc-warden will populate rows here via repair --> | | | |

## Conventions

- Filename: `<slug>-vN.md` where `N` starts at `1`
- Status values: `DRAFT` → `ACCEPTED` → `SUPERSEDED` (tracked in the index row, NOT in the plan file itself after acceptance)
- A new version (`-v2`, `-v3`, …) is created when a material revision is needed post-acceptance; the prior version is immutable
- Draft plans may be edited in place before acceptance; accepted plans may not

## Archive

Superseded and retired plans that are no longer active but preserved for history live in
`docs/archive/plans/` (moved via `git mv`, not deleted).
