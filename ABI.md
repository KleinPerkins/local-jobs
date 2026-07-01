# local-jobs handler ABI (`abi/v1`)

Every job type is a self-contained handler at `handlers/<type>.sh`. The core
(`bin/local-jobs.sh` + `lib/registry.py`) is **type-agnostic**: it discovers
types from `config/registry.yml` and drives each handler purely through the
verbs below. Adding a new type never requires editing the core.

## Top-level CLI verbs (`bin/local-jobs.sh`)

These are operator-facing commands routed by the core (not handler ABI):

| Verb | Purpose |
|---|---|
| `view-jobs` | Managed instances + discovered `com.kleinperkins.*` agents |
| `dashboard [--json\|--brief]` | Rich `dashboard/v1` payload or plain-English summary |
| `explain-job --id <id>` | Narrative troubleshooting + suggested commands |
| `resolve-instance --query <text>` | Fuzzy job discovery (exit 0/1/2) |
| `list-types [--plain\|--json]` | Type catalog with `add_schema` in JSON mode |
| `add-job [--dry-run]` | Create instance (preview with `--dry-run`) |
| `update-job` / `delete-job` / `run-job` / `logs-job` | Instance lifecycle |
| `enable-job` / `disable-job` | Toggle scheduling (`pause-job`/`resume-job` aliases) |
| `repair-job` / `doctor [--plain]` | Convergence + health |
| `adopt-job` | Import unmanaged LaunchAgent |
| `add-job-type` / `update-job-type` | Type authoring (agent-mediated) |

`dashboard/v1` JSON adds (v2, additive): `health_verdict`, `next_actions[]`,
`recent_runs[]`, per-instance `stale`, `hours_since_success`.

A handler is invoked as `handlers/<type>.sh <verb> [args]`.

## Verbs

| Verb | Contract |
|---|---|
| `describe` | Print one JSON object describing the type (schema below). Must not mutate anything. |
| `list-instances` | Print a JSON array of normalized instance objects (schema below). Read-only. |
| `view --id <id>` | Print one normalized instance object for `<id>`. Read-only. |
| `run --id <id> [--dry-run]` | Execute the job now. Print human progress to stdout/stderr, and emit exactly one machine line `@@RUNLOG@@ {json}` (the run record payload, see below). `--id all` / omitted runs every enabled instance of the type. |
| `logs --id <id> [--tail N]` | Print log file paths, then a tail of each (default N=40). |
| `add [type-specific flags]` | Create a new instance. Required flags are declared in `describe.add_schema`. |
| `update --id <id> [--schedule ...] [--enabled true\|false]` | Mutate schedule and/or enabled state. |
| `delete --id <id> --confirm [--purge-launchd]` | Remove an instance (destructive; requires `--confirm`). |
| `enable --id <id>` / `disable --id <id>` | Toggle scheduling without losing config. |
| `repair [--id <id>]` | Idempotent convergence (chmod, reinstall plist, etc). Safe to re-run. |
| `doctor` | Health check. Exit 0 = PASS, non-zero = issues. |

Unknown verb ⇒ exit 2. Missing required arg ⇒ exit 2.

## `describe` JSON schema

```json
{
  "type": "incremental-git-fetch",
  "cardinality": "multi",            // "singleton" | "multi"
  "label_token": "git-fetch",        // short token used in launchd labels
  "label_template": "com.kleinperkins.local-jobs.git-fetch[.<id>]",
  "config_file": "/abs/path/to/config/jobs/<type>.yml",  // or null
  "add_schema": [
    {"flag": "--id",     "required": true,  "help": "stable instance id"},
    {"flag": "--path",   "required": true,  "help": "repo path under ~/dev or absolute"},
    {"flag": "--branch", "required": true,  "help": "branch to fetch"},
    {"flag": "--schedule","required": false, "help": "inherit | HH:MM"},
    {"flag": "--enabled","required": false, "help": "true | false"}
  ]
}
```

`cardinality: singleton` types ignore `--id` on mutation verbs (one fixed
instance, e.g. `cpp-archive`). `multi` types key everything on `--id`.

The non-magic global scheduler (incremental-git-fetch's window agent) is
represented as a normal instance with `"role": "global_scheduler"` rather than
a magic `__global__` sentinel injected by the core.

## Normalized instance JSON schema

Uniform across types so the core/dashboard never special-case a backend:

```json
{
  "id": "all-the-things",
  "type": "incremental-git-fetch",
  "enabled": true,
  "role": "instance",                  // "instance" | "global_scheduler"
  "schedule": "inherit",               // "inherit" | "HH:MM" | {"window_start_hour":18,...}
  "launchd_label": "com.kleinperkins.local-jobs.git-fetch",
  "launchd_loaded": true,              // bool | null (null = no label)
  "log_paths": {"stdout": "...", "stderr": "..."},
  "...": "type-specific fields (path, branch, head, program, args, ...)"
}
```

## `@@RUNLOG@@` payload (emitted by `run`)

The handler prints exactly one line of the form:

```
@@RUNLOG@@ {"status":"success","fields":{ ...type-specific... }}
```

- `status`: `success` | `failure` | `skipped` | `dry-run`.
- `fields`: type-specific structured data the summarizer (`lib/summarize.py`)
  turns into a human headline. Examples:
  - igf: `{"behind_before":823,"behind_after":0,"head_before":"abc","head_after":"def"}`
  - cpp-archive: `{"refs":12,"commits":40}`
  - command: `{"exit_code":0,"last_line":"done"}`

The framework `run-job` dispatcher wraps `run`, captures this line, adds
`ts, job_id, type, duration_s`, computes `summary` via the summarizer, and
appends one `runlog/v1` record to `~/.local-jobs/runs.jsonl`. Handlers never
write the run log themselves, so the schema is uniform.

## Schema version envelopes

- `config/registry.yml` → `schema: registry/v1`
- `config/jobs/<type>.yml` → `schema: jobs/v1`
- `~/.local-jobs/runs.jsonl` records → `"schema": "runlog/v1"`
