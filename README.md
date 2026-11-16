# local-jobs local overlay

This repo is the source companion to the global `local-jobs` skill. It
no longer contains the generic runtime. The generic engine lives in the global
skill payload and reads this repo only through an installed overlay fragment.

## Contents

- `handlers/cpp-archive.sh` — LD-only singleton handler for the local archive job.
- `overlay/registry.d/cpp-archive.yml` — source template for the overlay entry.
- `install-overlay.sh` — writes `~/.local-jobs/registry.d/cpp-archive.yml` with an
  absolute executable handler path.
- `bin/test-local-overlay.sh` — self-contained overlay and handler contract check.

Machine state lives under `~/.local-jobs` and is not source-tracked here.

## Install / Repair Overlay

```bash
bash install-overlay.sh
```

Then verify through the global engine:

```bash
~/.cursor/skills/local-jobs/scripts/local-jobs.sh list-types --plain
~/.cursor/skills/local-jobs/scripts/local-jobs.sh doctor --plain
```

G4 informational proof: the repository-owned overlay contract now runs without an installed global
engine and catches source/install identity drift.

R5 requiredness proof: the named local overlay contract Check blocks a failing head and permits a
restored passing head to merge.

CI runs the real overlay/handler contract in temporary fixtures plus separate review-adapter and App/CI tests. It needs no installed engine, archive credentials or live controller. Run `python3 -I -B scripts/verify.py local` for local validation.

Ready PRs receive independent review from their originating Codex account, then the existing Chaos Scheduler App owns approval and native squash delivery. Initial automation admission and activation remain separate; this source change does not install or run host jobs. The `bin/pac-m0-*` scripts are retained historical controller telemetry tools, not CI or delivery dependencies.
