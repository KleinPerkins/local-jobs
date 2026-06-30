#!/usr/bin/env python3
"""CRUD store for the generic `command` job type (config/jobs/command.yml).

Pure config persistence + JSON projection; launchd handling lives in the
command handler. Schema: jobs/v1.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import yaml


def store_path() -> Path:
    env = os.environ.get("LOCAL_JOBS_COMMAND_CONFIG", "")
    if env:
        return Path(env).expanduser()
    home = Path(os.environ.get("LOCAL_JOBS_HOME", "")).expanduser() or Path(__file__).resolve().parent.parent
    return home / "config" / "jobs" / "command.yml"


def load() -> dict[str, Any]:
    path = store_path()
    if not path.is_file():
        return {"schema": "jobs/v1", "version": 1, "instances": []}
    with path.open() as handle:
        data = yaml.safe_load(handle) or {}
    if data.get("version") != 1:
        raise SystemExit(f"unsupported command config version: {data.get('version')!r}")
    data.setdefault("instances", [])
    return data


def save(data: dict[str, Any]) -> Path:
    path = store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        yaml.safe_dump(data, handle, default_flow_style=False, sort_keys=False)
    return path


def find(data: dict[str, Any], iid: str) -> dict[str, Any] | None:
    for entry in data.get("instances") or []:
        if isinstance(entry, dict) and entry.get("id") == iid:
            return entry
    return None


def parse_env(pairs: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    for pair in pairs or []:
        if "=" not in pair:
            raise SystemExit(f"--env expects K=V, got: {pair}")
        k, v = pair.split("=", 1)
        env[k] = v
    return env


def cmd_list() -> int:
    print(json.dumps(load().get("instances") or [], indent=2))
    return 0


def cmd_get(iid: str) -> int:
    entry = find(load(), iid)
    if not entry:
        raise SystemExit(f"command instance not found: {iid}")
    print(json.dumps(entry, indent=2))
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    data = load()
    if find(data, args.id):
        raise SystemExit(f"command instance already exists: {args.id}")
    if ":" not in args.schedule:
        raise SystemExit("schedule must be HH:MM")
    entry = {
        "id": args.id,
        "program": args.program,
        "args": args.arg or [],
        "env": parse_env(args.env),
        "schedule": args.schedule,
        "enabled": args.enabled,
    }
    data.setdefault("instances", []).append(entry)
    if args.dry_run:
        print(json.dumps({"dry_run": True, "would_add": entry}, indent=2))
        return 0
    save(data)
    print(f"added command instance {args.id}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    data = load()
    entry = find(data, args.id)
    if not entry:
        raise SystemExit(f"command instance not found: {args.id}")
    if args.dry_run:
        print(json.dumps({"dry_run": True, "would_remove": entry}, indent=2))
        return 0
    data["instances"] = [e for e in data["instances"] if e.get("id") != args.id]
    save(data)
    print(f"removed command instance {args.id}")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    data = load()
    entry = find(data, args.id)
    if not entry:
        raise SystemExit(f"command instance not found: {args.id}")
    if args.schedule is not None:
        if ":" not in args.schedule:
            raise SystemExit("schedule must be HH:MM")
        entry["schedule"] = args.schedule
    if args.enabled is not None:
        entry["enabled"] = args.enabled
    save(data)
    print(f"updated command instance {args.id}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="command_store.py")
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("validate")
    g = sub.add_parser("get"); g.add_argument("--id", required=True)
    a = sub.add_parser("add")
    a.add_argument("--id", required=True)
    a.add_argument("--program", required=True)
    a.add_argument("--arg", action="append", default=[])
    a.add_argument("--env", action="append", default=[])
    a.add_argument("--schedule", required=True)
    a.add_argument("--enabled", type=lambda v: v.lower() == "true", default=True)
    a.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("remove"); r.add_argument("--id", required=True); r.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("set")
    s.add_argument("--id", required=True)
    s.add_argument("--schedule", default=None)
    s.add_argument("--enabled", type=lambda v: v.lower() == "true", default=None)

    args = ap.parse_args()
    if args.command == "list":
        return cmd_list()
    if args.command == "validate":
        load(); print("ok"); return 0
    if args.command == "get":
        return cmd_get(args.id)
    if args.command == "add":
        return cmd_add(args)
    if args.command == "remove":
        return cmd_remove(args)
    if args.command == "set":
        return cmd_set(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
