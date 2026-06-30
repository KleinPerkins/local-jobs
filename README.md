# local-jobs

Unified framework for managing locally scheduled macOS `launchd` jobs in the `~/dev` ecosystem.

## Architecture

```
capabilities/skills/global/skills/local-jobs/   # IDE skill (user-facing)
        │
        ▼
personal/local-jobs/                            # framework runtime
├── config/registry.yml                         # job types + singleton instances
├── bin/local-jobs.sh                           # unified CLI
├── lib/registry.py                             # discovery + view aggregation
└── handlers/                                   # type plugins → backend repos
    ├── incremental-git-fetch.sh  → personal/dev-fetch
    └── cpp-archive.sh            → personal/cpp
```

**Job types** define a backend repo and handler plugin. **Instances** are either:

- Listed in `registry.yml` (singletons like `cpp-archive`), or
- Discovered from backend config (`incremental-git-fetch` repos in `dev-fetch/config/repos.yml`)

The framework also **discovers** all `com.kleinperkins.*` LaunchAgents on the machine and reports unmanaged ones in `view-jobs`.

## CLI

```bash
~/dev/personal/local-jobs/bin/local-jobs.sh view-jobs
~/dev/personal/local-jobs/bin/local-jobs.sh view-jobs --json
~/dev/personal/local-jobs/bin/local-jobs.sh doctor
~/dev/personal/local-jobs/bin/local-jobs.sh repair-job --all

# incremental-git-fetch
~/dev/personal/local-jobs/bin/local-jobs.sh add-job \
  --type incremental-git-fetch --id foo --path affirm/vendor/foo --branch main
~/dev/personal/local-jobs/bin/local-jobs.sh update-job --id foo --schedule 20:00
~/dev/personal/local-jobs/bin/local-jobs.sh update-job --id foo --enabled false
~/dev/personal/local-jobs/bin/local-jobs.sh delete-job --id foo --confirm
~/dev/personal/local-jobs/bin/local-jobs.sh repair-job --id foo

# cpp-archive (singleton)
~/dev/personal/local-jobs/bin/local-jobs.sh repair-job --id cpp-archive
~/dev/personal/local-jobs/bin/local-jobs.sh update-job --id cpp-archive --schedule 18:00
```

IDE agents use the **local-jobs** skill:

```bash
bash ~/.cursor/skills/local-jobs/scripts/local-jobs.sh view-jobs
```

## Registered job types

| Type | Backend | Launchd label(s) |
|------|---------|------------------|
| `incremental-git-fetch` | `personal/dev-fetch` | `com.kleinperkins.dev-fetch` (+ per-repo suffix) |
| `cpp-archive` | `personal/cpp` | `com.kleinperkins.cpp-archive` |

## Adding a new job type

1. Create backend repo with `install-launchd.sh`, logs under `~/Library/Logs/`, label `com.kleinperkins.<name>`.
2. Add handler script under `handlers/<type>.sh` implementing: `view`, `add`, `update`, `delete`, `repair`, `enable`, `disable`, `doctor`.
3. Register in `config/registry.yml` under `job_types`.
4. Add singleton to `instances` if applicable.

## Deprecations

- **`dev-fetch` skill** — replaced by `local-jobs` (dev-fetch remains the backend).
- **`cpp-archive` skill** — replaced by `local-jobs` (cpp remains the backend).

## Dependencies

- `python3` with PyYAML (`python3 -m pip install --user pyyaml`)
- `launchctl`, `git`
