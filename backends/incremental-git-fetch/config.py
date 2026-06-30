#!/usr/bin/env python3
"""Load and query the incremental-git-fetch YAML configuration (jobs/v1)."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import yaml

DEFAULT_LABEL = "com.kleinperkins.local-jobs.git-fetch"
DEFAULT_LOG_DIR = "~/Library/Logs/local-jobs"
LOG_BASENAME = "git-fetch.out.log"


def config_path(path: str | None = None) -> Path:
    return Path(path or os.environ.get("LOCAL_JOBS_IGF_CONFIG", "")).expanduser()


def _check_version(data: dict[str, Any]) -> None:
    # Forward-migration policy (P1-3): never brick existing instances on a
    # version bump. v1/missing load as-is; a higher version still loads (the
    # schema is forward-compatible via defaults-merge) with a one-line note.
    version = data.get("version", 1)
    if version in (None, 1):
        return
    if not isinstance(version, int) or version < 1:
        raise ValueError(f"unsupported config version: {version!r}")
    print(
        f"incremental-git-fetch: config version {version} > 1; loading forward-compatibly",
        file=sys.stderr,
    )


def load_raw_config(path: str | None = None) -> dict[str, Any]:
    config_file = config_path(path)
    if not config_file.is_file():
        raise FileNotFoundError(f"config not found: {config_file}")
    with config_file.open() as handle:
        data = yaml.safe_load(handle) or {}
    _check_version(data)
    return data


def save_raw_config(data: dict[str, Any], path: str | None = None) -> Path:
    config_file = config_path(path)
    with config_file.open("w") as handle:
        yaml.safe_dump(data, handle, default_flow_style=False, sort_keys=False)
    return config_file


def find_repo_index(data: dict[str, Any], repo_id: str) -> int:
    repos = data.get("repos") or []
    for index, entry in enumerate(repos):
        if isinstance(entry, dict) and entry.get("id") == repo_id:
            return index
    raise SystemExit(f"repo not found: {repo_id}")


def load_config(path: str | None = None) -> dict[str, Any]:
    config_file = config_path(path)
    if not config_file.is_file():
        raise FileNotFoundError(f"config not found: {config_file}")

    with config_file.open() as handle:
        data = yaml.safe_load(handle) or {}

    _check_version(data)

    defaults = data.get("defaults") or {}
    repos = data.get("repos") or []
    global_cfg = data.get("global") or {}

    dev_root = os.path.expanduser(
        global_cfg.get("dev_root") or os.environ.get("LOCAL_JOBS_IGF_DEV_ROOT", "~/dev")
    )

    normalized: list[dict[str, Any]] = []
    for entry in repos:
        if not isinstance(entry, dict) or "id" not in entry:
            raise ValueError("each repo entry requires an id")
        merged = {**defaults, **entry}
        raw_path = merged["path"]
        path_obj = Path(os.path.expanduser(raw_path))
        if not path_obj.is_absolute():
            path_obj = Path(dev_root) / raw_path
        merged["path"] = str(path_obj.resolve())
        normalized.append(merged)

    data["repos"] = normalized
    data["global"] = global_cfg
    data["_dev_root"] = dev_root
    return data


def cmd_list() -> int:
    cfg = load_config()
    for repo in cfg["repos"]:
        print(
            f"{repo['id']}\t"
            f"{'enabled' if repo.get('enabled', True) else 'disabled'}\t"
            f"{repo['path']}\t"
            f"{repo.get('remote', 'origin')}/{repo.get('branch', 'main')}"
        )
    return 0


def cmd_get_global() -> int:
    print(json.dumps(load_config()["global"], indent=2, sort_keys=True))
    return 0


def cmd_get_repo(repo_id: str) -> int:
    cfg = load_config()
    for repo in cfg["repos"]:
        if repo["id"] == repo_id:
            print(json.dumps(repo, indent=2, sort_keys=True))
            return 0
    raise SystemExit(f"repo not found: {repo_id}")


def cmd_enabled_ids() -> int:
    for repo in load_config()["repos"]:
        if repo.get("enabled", True):
            print(repo["id"])
    return 0


def cmd_inherit_ids() -> int:
    """Enabled repos that follow the global window (no per-repo agent).

    The global scheduled run fetches only these so a repo with its own
    per-repo agent is never also fetched in the global window (no double-run).
    """
    for repo in load_config()["repos"]:
        schedule = repo.get("schedule", "inherit")
        if repo.get("enabled", True) and (schedule == "inherit" or schedule is None):
            print(repo["id"])
    return 0


def cmd_validate() -> int:
    load_config()
    print("ok")
    return 0


def _repo_git_hint(path: str) -> dict[str, str]:
    repo_path = Path(path)
    if not repo_path.is_dir():
        return {"git": "missing"}
    import subprocess

    try:
        subprocess.run(
            ["git", "-C", str(repo_path), "rev-parse", "--is-inside-work-tree"],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return {"git": "not-a-repo"}

    branch = subprocess.run(
        ["git", "-C", str(repo_path), "branch", "--show-current"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    head = subprocess.run(
        ["git", "-C", str(repo_path), "rev-parse", "--short", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return {"git": "ok", "branch": branch, "head": head}


def _last_log_hint(repo_id: str, log_dir: str) -> str | None:
    log_path = Path(os.path.expanduser(log_dir)) / LOG_BASENAME
    if not log_path.is_file():
        return None
    marker = f"[{repo_id}]"
    try:
        lines = deque_tail(log_path, 200)
    except OSError:
        return None
    for line in reversed(lines):
        if marker in line:
            return line.strip()
    return None


def deque_tail(path: Path, max_lines: int) -> list[str]:
    from collections import deque

    with path.open(errors="replace") as handle:
        return list(deque(handle, maxlen=max_lines))


def cmd_view() -> int:
    cfg = load_config()
    global_cfg = cfg.get("global") or {}
    launchd = global_cfg.get("launchd") or {}
    logging_cfg = global_cfg.get("logging") or {}
    log_dir = os.path.expanduser(logging_cfg.get("dir", DEFAULT_LOG_DIR))

    repos_out: list[dict[str, Any]] = []
    for repo in cfg["repos"]:
        hints = _repo_git_hint(repo["path"])
        entry: dict[str, Any] = {
            "id": repo["id"],
            "enabled": repo.get("enabled", True),
            "path": repo["path"],
            "remote": repo.get("remote", "origin"),
            "branch": repo.get("branch", "main"),
            "schedule": repo.get("schedule", "inherit"),
            "filter_blobs": repo.get("filter_blobs", True),
            "full_fetch_other_refs": repo.get("full_fetch_other_refs", False),
            "ff_only_merge": repo.get("ff_only_merge", True),
            "git": hints,
            "last_run_hint": _last_log_hint(repo["id"], log_dir),
        }
        repos_out.append(entry)

    payload = {
        "global": {
            "dev_root": cfg.get("_dev_root"),
            "launchd": launchd,
            "logging": {"dir": log_dir},
            "schedule_summary": (
                f"daily {launchd.get('window_start_hour', 18):02d}:00 "
                f"with jitter to {launchd.get('window_end_hour', 24):02d}:00"
                if launchd.get("use_jitter", True)
                else f"daily {launchd.get('window_start_hour', 18):02d}:00 fixed"
            ),
        },
        "repos": repos_out,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    if args.type != "incremental":
        raise SystemExit(f"unsupported repo type: {args.type!r} (only 'incremental')")

    data = load_raw_config()
    repos = data.setdefault("repos", [])
    if any(isinstance(entry, dict) and entry.get("id") == args.id for entry in repos):
        raise SystemExit(f"repo already exists: {args.id}")

    dev_root = os.path.expanduser(
        (data.get("global") or {}).get("dev_root")
        or os.environ.get("LOCAL_JOBS_IGF_DEV_ROOT", "~/dev")
    )
    raw_path = args.path
    resolved = Path(os.path.expanduser(raw_path))
    if not resolved.is_absolute():
        resolved = Path(dev_root) / raw_path

    if not args.dry_run and not resolved.is_dir():
        raise SystemExit(f"path does not exist: {resolved}")

    entry: dict[str, Any] = {
        "id": args.id,
        "path": raw_path,
        "branch": args.branch,
        "enabled": args.enabled,
        "schedule": args.schedule,
    }
    if args.remote:
        entry["remote"] = args.remote

    repos.append(entry)
    if args.dry_run:
        print(json.dumps({"dry_run": True, "would_add": entry}, indent=2, sort_keys=True))
        return 0

    saved = save_raw_config(data)
    print(f"added {args.id} to {saved}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    data = load_raw_config()
    index = find_repo_index(data, args.id)
    removed = data["repos"].pop(index)

    if args.dry_run:
        print(
            json.dumps(
                {
                    "dry_run": True,
                    "would_remove": removed,
                    "purge_launchd": args.purge_launchd,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    saved = save_raw_config(data)
    print(f"removed {args.id} from {saved}")
    if args.purge_launchd:
        print(f"PURGE_LAUNCHD:{args.id}")
    return 0


def cmd_set_enabled(repo_id: str, enabled: bool, dry_run: bool) -> int:
    data = load_raw_config()
    index = find_repo_index(data, repo_id)
    data["repos"][index]["enabled"] = enabled

    if dry_run:
        print(json.dumps({"dry_run": True, "id": repo_id, "enabled": enabled}, indent=2))
        return 0

    saved = save_raw_config(data)
    state = "enabled" if enabled else "disabled"
    print(f"{state} {repo_id} in {saved}")
    return 0


def cmd_set_schedule(args: argparse.Namespace) -> int:
    data = load_raw_config()
    global_cfg = data.setdefault("global", {})
    launchd = global_cfg.setdefault("launchd", {})

    if args.global_schedule:
        launchd["window_start_hour"] = args.hour
        if args.minute is not None:
            launchd["window_start_minute"] = args.minute
        target = "global"
        schedule_value: Any = {
            "window_start_hour": args.hour,
            **({"window_start_minute": args.minute} if args.minute is not None else {}),
        }
    else:
        if not args.id:
            raise SystemExit("set-schedule requires --id or --global")
        index = find_repo_index(data, args.id)
        if args.inherit:
            data["repos"][index]["schedule"] = "inherit"
            schedule_value = "inherit"
        else:
            minute = 0 if args.minute is None else args.minute
            data["repos"][index]["schedule"] = {"hour": args.hour, "minute": minute}
            schedule_value = {"hour": args.hour, "minute": minute}
        target = args.id

    if args.dry_run:
        print(
            json.dumps(
                {"dry_run": True, "target": target, "schedule": schedule_value},
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    saved = save_raw_config(data)
    print(f"updated schedule for {target} in {saved}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="config.py")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list")
    sub.add_parser("validate")
    sub.add_parser("global")
    sub.add_parser("enabled-ids")
    sub.add_parser("inherit-ids")
    sub.add_parser("view")

    repo_p = sub.add_parser("repo")
    repo_p.add_argument("repo_id")

    add_p = sub.add_parser("add")
    add_p.add_argument("--id", required=True)
    add_p.add_argument("--path", required=True)
    add_p.add_argument("--branch", required=True)
    add_p.add_argument("--type", default="incremental")
    add_p.add_argument("--remote", default="")
    add_p.add_argument("--enabled", type=lambda v: v.lower() == "true", default=True)
    add_p.add_argument("--schedule", default="inherit")
    add_p.add_argument("--dry-run", action="store_true")

    remove_p = sub.add_parser("remove")
    remove_p.add_argument("--id", required=True)
    remove_p.add_argument("--purge-launchd", action="store_true")
    remove_p.add_argument("--dry-run", action="store_true")

    enable_p = sub.add_parser("enable")
    enable_p.add_argument("--id", required=True)
    enable_p.add_argument("--dry-run", action="store_true")

    disable_p = sub.add_parser("disable")
    disable_p.add_argument("--id", required=True)
    disable_p.add_argument("--dry-run", action="store_true")

    sched_p = sub.add_parser("set-schedule")
    sched_p.add_argument("--id", default="")
    sched_p.add_argument("--global", dest="global_schedule", action="store_true")
    sched_p.add_argument("--hour", type=int)
    sched_p.add_argument("--minute", type=int)
    sched_p.add_argument("--inherit", action="store_true")
    sched_p.add_argument("--dry-run", action="store_true")

    return parser


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] in {
        "list",
        "validate",
        "global",
        "enabled-ids",
        "inherit-ids",
        "repo",
    }:
        command = sys.argv[1]
        if command == "list":
            return cmd_list()
        if command == "validate":
            return cmd_validate()
        if command == "global":
            return cmd_get_global()
        if command == "enabled-ids":
            return cmd_enabled_ids()
        if command == "inherit-ids":
            return cmd_inherit_ids()
        if command == "repo":
            if len(sys.argv) != 3:
                raise SystemExit("usage: config.py repo <id>")
            return cmd_get_repo(sys.argv[2])

    parser = build_parser()
    args = parser.parse_args()

    if args.command == "list":
        return cmd_list()
    if args.command == "validate":
        return cmd_validate()
    if args.command == "global":
        return cmd_get_global()
    if args.command == "enabled-ids":
        return cmd_enabled_ids()
    if args.command == "inherit-ids":
        return cmd_inherit_ids()
    if args.command == "view":
        return cmd_view()
    if args.command == "repo":
        return cmd_get_repo(args.repo_id)
    if args.command == "add":
        if args.schedule not in ("inherit",) and not isinstance(args.schedule, dict):
            if args.schedule.startswith("{"):
                args.schedule = json.loads(args.schedule.replace("'", '"'))
            elif ":" in args.schedule:
                hour_s, minute_s = args.schedule.split(":", 1)
                args.schedule = {"hour": int(hour_s), "minute": int(minute_s)}
        return cmd_add(args)
    if args.command == "remove":
        return cmd_remove(args)
    if args.command == "enable":
        return cmd_set_enabled(args.id, True, args.dry_run)
    if args.command == "disable":
        return cmd_set_enabled(args.id, False, args.dry_run)
    if args.command == "set-schedule":
        if args.global_schedule and args.inherit:
            raise SystemExit("--inherit is only valid with per-repo --id")
        if args.global_schedule:
            if args.hour is None:
                raise SystemExit("set-schedule --global requires --hour")
        elif args.inherit:
            if not args.id:
                raise SystemExit("set-schedule --inherit requires --id")
        else:
            if not args.id or args.hour is None:
                raise SystemExit("set-schedule requires --id and --hour (or --inherit)")
            if args.minute is None:
                args.minute = 0
        return cmd_set_schedule(args)

    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
