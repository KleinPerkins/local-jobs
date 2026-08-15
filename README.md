# local-jobs local overlay

This repo is the operator-private companion to the global `local-jobs` skill. It
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

Pull requests are protected by runnerless v3 verification.
