# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records for `local-jobs`.

**Governance:** `~/dev/_ops/doc-warden/POLICY.md` §2 (taxonomy), §9 (archival).
ADRs are **byte-identical-forever** once their Status line reads `accepted` — no in-place edits
after acceptance, not even a status-bullet edit. Supersession is recorded only via a new ADR's
`Supersedes:` pointer and this index file's row update.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| <!-- TODO: doc-warden will populate rows here via repair --> | | | |

## Conventions

Format (Nygard):
```markdown
# ADR <NNNN>: <title>
Status: <draft|accepted|superseded> — <date>

## Decision
## Why
## Consequences
```

- Numbering: 4-digit zero-padded sequential (`0001`, `0002`, …)
- Filename: `<NNNN>-<slug>.md`
- Status values: `draft` → `accepted` → `superseded`
- `Supersedes: ADR-NNNN` line added to the new ADR; old ADR is never modified
- The index row for a superseded ADR is updated to `superseded — <date>` (this index is mutable;
  the ADR file itself is not)
