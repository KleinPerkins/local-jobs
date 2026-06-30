#!/usr/bin/env python3
"""Registry loader, instance discovery, and launchd scanning for local-jobs."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


def jobs_home() -> Path:
    return Path(os.environ.get("LOCAL_JOBS_HOME", "")).expanduser() or Path(__file__).resolve().parent.parent


def registry_path() -> Path:
    return Path(os.environ.get("LOCAL_JOBS_REGISTRY", "")).expanduser() or jobs_home() / "config" / "registry.yml"


def load_registry() -> dict[str, Any]:
    path = registry_path()
    if not path.is_file():
        raise FileNotFoundError(f"registry not found: {path}")
    with path.open() as handle:
        data = yaml.safe_load(handle) or {}
    if data.get("version") != 1:
        raise ValueError(f"unsupported registry version: {data.get('version')!r}")
    return data


def expand(path: str) -> str:
    return str(Path(path).expanduser())


def handler_path(job_type: str) -> Path:
    reg = load_registry()
    types = reg.get("job_types") or {}
    if job_type not in types:
        raise SystemExit(f"unknown job type: {job_type}")
    rel = types[job_type].get("handler")
    if not rel:
        raise SystemExit(f"job type {job_type} has no handler")
    path = jobs_home() / rel
    if not path.is_file():
        raise SystemExit(f"handler missing: {path}")
    return path


def instance_type(instance_id: str) -> str:
    reg = load_registry()
    for entry in reg.get("instances") or []:
        if isinstance(entry, dict) and entry.get("id") == instance_id:
            return str(entry.get("type", ""))
    # incremental-git-fetch instances live in dev-fetch config
    backend = (reg.get("job_types") or {}).get("incremental-git-fetch", {})
    backend_home = Path(expand(backend.get("backend_home", "~/dev/personal/dev-fetch")))
    config_py = backend_home / "lib" / "config.py"
    if config_py.is_file():
        env = {**os.environ, "DEV_FETCH_CONFIG": str(backend_home / "config" / "repos.yml")}
        proc = subprocess.run(
            ["python3", str(config_py), "list"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        for line in proc.stdout.splitlines():
            parts = line.split("\t")
            if parts and parts[0] == instance_id:
                return "incremental-git-fetch"
    raise SystemExit(f"unknown instance: {instance_id}")


def launchctl_loaded(label: str) -> bool:
    uid = os.getuid()
    proc = subprocess.run(
        ["launchctl", "print", f"gui/{uid}/{label}"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0


def parse_plist_schedule(plist_path: Path) -> dict[str, Any]:
    if not plist_path.is_file():
        return {}
    with plist_path.open("rb") as handle:
        data = plistlib.load(handle)
    schedule: dict[str, Any] = {}
    interval = data.get("StartInterval")
    if interval is not None:
        schedule["kind"] = "interval"
        schedule["seconds"] = interval
    cal = data.get("StartCalendarInterval")
    if isinstance(cal, dict):
        schedule["kind"] = "calendar"
        if "Hour" in cal:
            schedule["hour"] = cal["Hour"]
        if "Minute" in cal:
            schedule["minute"] = cal["Minute"]
    if data.get("RunAtLoad"):
        schedule["run_at_load"] = True
    return schedule


def discover_launchd(prefix: str) -> list[dict[str, Any]]:
    agents_dir = Path.home() / "Library" / "LaunchAgents"
    found: list[dict[str, Any]] = []
    if not agents_dir.is_dir():
        return found
    for plist in sorted(agents_dir.glob(f"{prefix}*.plist")):
        label = plist.stem
        loaded = launchctl_loaded(label)
        schedule = parse_plist_schedule(plist)
        found.append(
            {
                "label": label,
                "plist": str(plist),
                "loaded": loaded,
                "schedule": schedule,
            }
        )
    return found


def managed_labels(reg: dict[str, Any]) -> set[str]:
    labels: set[str] = set()
    types = reg.get("job_types") or {}
    if "incremental-git-fetch" in types:
        prefix = types["incremental-git-fetch"].get("launchd_label_prefix", "com.kleinperkins.dev-fetch")
        labels.add(prefix)
        # per-repo agents
        for item in discover_launchd(prefix + "."):
            labels.add(item["label"])
    if "cpp-archive" in types:
        label = types["cpp-archive"].get("launchd_label", "com.kleinperkins.cpp-archive")
        labels.add(label)
    return labels


def collect_instances(reg: dict[str, Any]) -> list[dict[str, Any]]:
    instances: list[dict[str, Any]] = []
    types = reg.get("job_types") or {}

    # Singleton / explicit instances
    for entry in reg.get("instances") or []:
        if not isinstance(entry, dict):
            continue
        iid = entry.get("id")
        jtype = entry.get("type")
        if not iid or not jtype:
            continue
        type_cfg = types.get(jtype, {})
        label = type_cfg.get("launchd_label", "")
        instances.append(
            {
                "id": iid,
                "type": jtype,
                "managed": True,
                "enabled": entry.get("enabled", True),
                "launchd_label": label,
                "launchd_loaded": launchctl_loaded(label) if label else None,
            }
        )

    # incremental-git-fetch instances from dev-fetch
    igf = types.get("incremental-git-fetch", {})
    backend_home = Path(expand(igf.get("backend_home", "~/dev/personal/dev-fetch")))
    config_py = backend_home / "lib" / "config.py"
    prefix = igf.get("launchd_label_prefix", "com.kleinperkins.dev-fetch")
    if config_py.is_file():
        env = {**os.environ, "DEV_FETCH_CONFIG": str(backend_home / "config" / "repos.yml")}
        proc = subprocess.run(
            ["python3", str(config_py), "view"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            view = json.loads(proc.stdout)
            for repo in view.get("repos") or []:
                rid = repo.get("id")
                schedule = repo.get("schedule") or "inherit"
                label = prefix if schedule == "inherit" else f"{prefix}.{rid}"
                instances.append(
                    {
                        "id": rid,
                        "type": "incremental-git-fetch",
                        "managed": True,
                        "enabled": repo.get("enabled", True),
                        "path": repo.get("path"),
                        "branch": repo.get("branch"),
                        "schedule": schedule,
                        "launchd_label": label,
                        "launchd_loaded": launchctl_loaded(label) if label else None,
                        "head": repo.get("head"),
                    }
                )
            global_agent = view.get("global_agent") or {}
            global_label = prefix
            instances.insert(
                0,
                {
                    "id": "__global__",
                    "type": "incremental-git-fetch",
                    "managed": True,
                    "enabled": True,
                    "role": "global_scheduler",
                    "schedule": global_agent.get("schedule"),
                    "launchd_label": global_label,
                    "launchd_loaded": launchctl_loaded(global_label),
                },
            )
    return instances


def view_jobs(as_json: bool) -> int:
    reg = load_registry()
    prefix = (reg.get("discovery") or {}).get("label_prefix", "com.kleinperkins.")
    managed = managed_labels(reg)
    instances = collect_instances(reg)
    discovered = discover_launchd(prefix)
    unmanaged = [d for d in discovered if d["label"] not in managed]

    payload = {
        "registry": str(registry_path()),
        "instances": instances,
        "discovered_unmanaged": unmanaged,
    }
    if as_json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"registry: {registry_path()}")
    print("\n== Managed instances ==")
    for inst in instances:
        if inst.get("id") == "__global__":
            print(
                f"  [global] {inst.get('launchd_label')} loaded={inst.get('launchd_loaded')} "
                f"schedule={inst.get('schedule')}"
            )
            continue
        enabled = "enabled" if inst.get("enabled", True) else "disabled"
        loaded = inst.get("launchd_loaded")
        print(
            f"  {inst.get('id')} ({inst.get('type')}) {enabled} "
            f"label={inst.get('launchd_label')} loaded={loaded} "
            f"schedule={inst.get('schedule', '-')}"
        )
        if inst.get("path"):
            print(f"    path={inst.get('path')} branch={inst.get('branch')} head={inst.get('head', '-')}")

    if unmanaged:
        print("\n== Discovered (unmanaged) com.kleinperkins.* agents ==")
        for item in unmanaged:
            sched = item.get("schedule") or {}
            sched_s = (
                f"every {sched.get('seconds')}s"
                if sched.get("kind") == "interval"
                else f"{sched.get('hour', '?')}:{sched.get('minute', 0):02d}"
                if sched.get("kind") == "calendar"
                else "?"
            )
            print(f"  {item['label']} loaded={item['loaded']} schedule={sched_s}")
    else:
        print("\n== Discovered (unmanaged) ==")
        print("  (none)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="local-jobs registry helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_handler = sub.add_parser("handler-path")
    p_handler.add_argument("--type", required=True)

    p_inst = sub.add_parser("instance-type")
    p_inst.add_argument("--id", required=True)

    p_view = sub.add_parser("view")
    p_view.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.cmd == "handler-path":
        print(handler_path(args.type))
        return 0
    if args.cmd == "instance-type":
        print(instance_type(args.id))
        return 0
    if args.cmd == "view":
        return view_jobs(args.json)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
