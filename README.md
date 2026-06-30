# local-jobs

Unified, type-agnostic framework for managing locally scheduled macOS `launchd`
jobs in the `~/dev` ecosystem. The core discovers job types from a registry and
drives every handler through a uniform ABI — adding a new type never requires
editing the core.

## Architecture

```
capabilities/skills/global/skills/local-jobs/   # IDE skill (user-facing)
        │
        ▼
personal/local-jobs/                            # framework runtime (git-tracked: KleinPerkins/local-jobs)
├── ABI.md                                       # the handler contract (abi/v1)
├── config/
│   ├── registry.yml                             # job types (registry/v1)
│   └── jobs/                                     # per-type instance config (jobs/v1)
│       ├── incremental-git-fetch.yml
│       └── command.yml
├── bin/
│   ├── local-jobs.sh                            # unified CLI (type-agnostic)
│   ├── dispatch-run.sh                          # wraps handler `run`, writes runs.jsonl
│   ├── run-scheduled.sh                         # launchd entrypoint (adds igf jitter)
│   ├── adopt-job.sh                             # import an installed agent
│   ├── add-job-type.sh                          # scaffold a new type
│   └── test-local-jobs.sh                       # ABI conformance harness
├── lib/                                         # the type-agnostic chassis
│   ├── registry.py                              # discovery via handler ABI (failure-isolated)
│   ├── contract.py                              # describe/instance validation + quarantine
│   ├── launchd.py                               # the single escaped plist writer + verify-load
│   ├── schedule.py                              # one Schedule type (local next-run, full-window jitter)
│   ├── store.py                                 # generic id-keyed CRUD (jobs/v1)
│   ├── migrate.py                               # load-time forward migration (re-merge defaults)
│   ├── handler_runtime.py                       # generic instance projection + launchd install
│   ├── handler_lib.sh                           # bash chassis: every generic verb for thin handlers
│   ├── events.py                                # uniform versioned event stream (event/v1)
│   ├── dashboard.py                             # rich dashboard payload
│   ├── run_log.py                               # run history (runlog/v1), the run slice of events
│   ├── summarize.py                             # structured fields → headline
│   ├── flock.py                                 # portable per-repo lock
│   └── common.sh
├── handlers/                                     # type plugins (ABI v1)
│   ├── incremental-git-fetch.sh
│   ├── cpp-archive.sh
│   └── command.sh
└── backends/
    └── incremental-git-fetch/                    # absorbed fetch backend (first-class)
```

## Handler ABI

Every type is a handler at `handlers/<type>.sh` implementing the verbs
`describe · list-instances · view · run · logs · add · update · delete ·
enable · disable · repair · doctor`. See [`ABI.md`](ABI.md).

## CLI

```bash
~/dev/personal/local-jobs/bin/local-jobs.sh view-jobs            # all instances + unmanaged agents
~/dev/personal/local-jobs/bin/local-jobs.sh dashboard --json     # rich payload (canvas feed)
~/dev/personal/local-jobs/bin/local-jobs.sh doctor               # health across every type
~/dev/personal/local-jobs/bin/local-jobs.sh run-job --id <id>    # run now (logs to runs.jsonl)
~/dev/personal/local-jobs/bin/local-jobs.sh logs-job --id <id>
~/dev/personal/local-jobs/bin/local-jobs.sh repair-job --all

# incremental-git-fetch (absorbed backend)
~/dev/personal/local-jobs/bin/local-jobs.sh add-job \
  --type incremental-git-fetch --id foo --path affirm/vendor/foo --branch main
~/dev/personal/local-jobs/bin/local-jobs.sh update-job --id foo --schedule 20:00
~/dev/personal/local-jobs/bin/local-jobs.sh delete-job --id foo --confirm

# generic command type (arbitrary program + schedule, self-managed plist)
~/dev/personal/local-jobs/bin/local-jobs.sh add-job \
  --type command --id backup --program /path/script.sh --schedule 02:00 --arg=--flag --env=K=V

# adopt an existing installed agent into the registry
~/dev/personal/local-jobs/bin/local-jobs.sh adopt-job --label com.kleinperkins.something [--relabel --confirm]
```

## Registered job types

| Type | Backend | Launchd label(s) |
|------|---------|------------------|
| `incremental-git-fetch` | `backends/incremental-git-fetch` | `com.kleinperkins.local-jobs.git-fetch` (+ `.<id>` per repo) |
| `cpp-archive` | `personal/cpp` (source unchanged) | `com.kleinperkins.local-jobs.cpp-archive` |
| `command` | self-managed (no backend) | `com.kleinperkins.local-jobs.command.<id>` |

## Run history

`run-job` and every scheduled agent dispatch through `dispatch-run.sh`, which
captures the handler's single `@@RUNLOG@@` line, computes a summary, and appends
one `runlog/v1` record to `~/.local-jobs/runs.jsonl` (flock-guarded, capped per
line, size/age-rotated, malformed-tolerant).

## Adding a new job type

```bash
bin/add-job-type.sh --type my-type --cardinality multi --description "..."
# then implement the ABI verbs in handlers/my-type.sh and register it in config/registry.yml
```

## Schedule (incremental-git-fetch)

Global agent triggers daily at `window_start_hour` (default 18:00) and the
runner sleeps a random jitter up to `window_end_hour` (default 24:00). Per-repo
fixed schedules use `schedule: {hour, minute}` and a dedicated `.<id>` agent
(no jitter). Manual `run-job` skips jitter.

## Dependencies

- `python3` with PyYAML (`python3 -m pip install --user pyyaml`)
- `launchctl`, `git`, `lsof`

## Git tracking

This framework is its own repo (`KleinPerkins/local-jobs`) with the standard
KleinPerkins noreply identity + commit guards, so the absorbed backend and run
history are durably tracked.
