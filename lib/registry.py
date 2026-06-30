#!/usr/bin/env python3
"""Type-agnostic registry, discovery, and launchd scanning for local-jobs.

The core never hardcodes job types. It loads ``config/registry.yml``
(``registry/v1``) and drives every handler purely through the ABI verbs
``describe`` / ``list-instances`` (see ABI.md). Adding a new type requires only
a handler + a registry entry — no edits here.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract  # noqa: E402

HANDLER_TIMEOUT = float(os.environ.get("LOCAL_JOBS_HANDLER_TIMEOUT", "30"))


def jobs_home() -> Path:
    env = os.environ.get("LOCAL_JOBS_HOME", "")
    if env:
        return Path(env).expanduser()
    return Path(__file__).resolve().parent.parent


def registry_path() -> Path:
    env = os.environ.get("LOCAL_JOBS_REGISTRY", "")
    if env:
        return Path(env).expanduser()
    return jobs_home() / "config" / "registry.yml"


def load_registry() -> dict[str, Any]:
    path = registry_path()
    if not path.is_file():
        raise SystemExit(f"registry not found: {path}")
    with path.open() as handle:
        data = yaml.safe_load(handle) or {}
    schema = data.get("schema")
    if schema not in (None, "registry/v1") and data.get("version") != 1:
        raise SystemExit(f"unsupported registry schema: {schema!r}")
    return data


def job_types(reg: dict[str, Any]) -> dict[str, Any]:
    return reg.get("job_types") or {}


def handler_path(job_type: str, reg: dict[str, Any] | None = None) -> Path:
    reg = reg or load_registry()
    types = job_types(reg)
    if job_type not in types:
        raise SystemExit(f"unknown job type: {job_type}")
    rel = (types[job_type] or {}).get("handler")
    if not rel:
        raise SystemExit(f"job type {job_type} has no handler")
    path = jobs_home() / rel
    if not path.is_file():
        raise SystemExit(f"handler missing: {path}")
    return path


def _run_handler(
    job_type: str, args: list[str], reg: dict[str, Any], timeout: float = HANDLER_TIMEOUT
) -> subprocess.CompletedProcess[str]:
    handler = handler_path(job_type, reg)
    return subprocess.run(
        [str(handler), *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
    )


def _tail(text: str, n: int = 500) -> str:
    return (text or "").strip()[-n:]


def collect_for_type(job_type: str, reg: dict[str, Any]) -> list[dict[str, Any]]:
    """Instances for one type, fully isolated: any failure (non-zero rc, bad
    JSON, contract-invalid, timeout, missing handler) yields exactly ONE
    quarantine row instead of crashing the whole view or silently vanishing.
    """
    try:
        dproc = _run_handler(job_type, ["describe"], reg)
        if dproc.returncode != 0:
            return [contract.quarantine_row(job_type, "describe failed", _tail(dproc.stderr), "describe", dproc.returncode)]
        try:
            desc = json.loads(dproc.stdout or "null")
        except json.JSONDecodeError as exc:
            return [contract.quarantine_row(job_type, f"describe emitted non-JSON: {exc}", _tail(dproc.stdout), "describe")]
        derrs = contract.validate_describe(desc)
        if derrs:
            return [contract.quarantine_row(job_type, "invalid describe: " + "; ".join(derrs), _tail(dproc.stdout), "describe")]

        lproc = _run_handler(job_type, ["list-instances"], reg)
        if lproc.returncode != 0:
            return [contract.quarantine_row(job_type, "list-instances failed", _tail(lproc.stderr), "list-instances", lproc.returncode)]
        try:
            data = json.loads(lproc.stdout or "[]")
        except json.JSONDecodeError as exc:
            return [contract.quarantine_row(job_type, f"list-instances emitted non-JSON: {exc}", _tail(lproc.stdout), "list-instances")]
        if not isinstance(data, list):
            return [contract.quarantine_row(job_type, "list-instances did not return a JSON array", _tail(lproc.stdout), "list-instances")]

        out: list[dict[str, Any]] = []
        invalid = 0
        for inst in data:
            ierrs = contract.validate_instance(inst)
            if ierrs:
                invalid += 1
                continue
            inst.setdefault("type", job_type)
            out.append(inst)
        if invalid:
            out.append(contract.quarantine_row(job_type, f"{invalid} instance(s) failed contract validation", "", "list-instances"))
        return out
    except subprocess.TimeoutExpired:
        return [contract.quarantine_row(job_type, f"handler timed out after {HANDLER_TIMEOUT:g}s", "", "list-instances")]
    except SystemExit as exc:  # handler_path: missing handler/type
        return [contract.quarantine_row(job_type, str(exc), "", "discover")]
    except Exception as exc:  # never let one type break discovery
        return [contract.quarantine_row(job_type, f"unexpected error: {exc}", "", "discover")]


def handler_describe(job_type: str, reg: dict[str, Any]) -> dict[str, Any]:
    proc = _run_handler(job_type, ["describe"], reg)
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


def handler_list_instances(job_type: str, reg: dict[str, Any]) -> list[dict[str, Any]]:
    proc = _run_handler(job_type, ["list-instances"], reg)
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def collect_instances(reg: dict[str, Any]) -> list[dict[str, Any]]:
    """All instances across all types, with per-type failure isolation.

    A broken type contributes a single ``role:"error"`` quarantine row rather
    than crashing discovery or disappearing silently.
    """
    instances: list[dict[str, Any]] = []
    for jtype in job_types(reg):
        instances.extend(collect_for_type(jtype, reg))
    return instances


def instance_type(instance_id: str, reg: dict[str, Any] | None = None) -> str:
    reg = reg or load_registry()
    for jtype in job_types(reg):
        for inst in handler_list_instances(jtype, reg):
            if isinstance(inst, dict) and inst.get("id") == instance_id:
                return jtype
    raise SystemExit(f"unknown instance: {instance_id}")


def managed_labels(reg: dict[str, Any], instances: list[dict[str, Any]] | None = None) -> set[str]:
    if instances is None:
        instances = collect_instances(reg)
    labels: set[str] = set()
    for inst in instances:
        label = inst.get("launchd_label")
        if label:
            labels.add(label)
    return labels


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
        found.append(
            {
                "label": label,
                "plist": str(plist),
                "loaded": launchctl_loaded(label),
                "schedule": parse_plist_schedule(plist),
            }
        )
    return found


def _schedule_str(sched: dict[str, Any]) -> str:
    if sched.get("kind") == "interval":
        return f"every {sched.get('seconds')}s"
    if sched.get("kind") == "calendar":
        return f"{sched.get('hour', '?')}:{sched.get('minute', 0):02d}"
    return "?"


def build_view(reg: dict[str, Any]) -> dict[str, Any]:
    prefix = (reg.get("discovery") or {}).get("label_prefix", "com.kleinperkins.")
    instances = collect_instances(reg)
    managed = managed_labels(reg, instances)
    discovered = discover_launchd(prefix)
    unmanaged = [d for d in discovered if d["label"] not in managed]
    return {
        "registry": str(registry_path()),
        "instances": instances,
        "discovered_unmanaged": unmanaged,
    }


def view_jobs(as_json: bool) -> int:
    reg = load_registry()
    payload = build_view(reg)
    if as_json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"registry: {payload['registry']}")
    print("\n== Managed instances ==")
    for inst in payload["instances"]:
        if inst.get("role") == "error":
            err = inst.get("error") or {}
            print(f"  [QUARANTINED] {inst.get('type')} — {err.get('reason')} (verb={err.get('verb')})")
            continue
        if inst.get("role") == "global_scheduler":
            print(
                f"  [global] {inst.get('launchd_label')} "
                f"loaded={inst.get('launchd_loaded')} schedule={inst.get('schedule')}"
            )
            continue
        enabled = "enabled" if inst.get("enabled", True) else "disabled"
        print(
            f"  {inst.get('id')} ({inst.get('type')}) {enabled} "
            f"label={inst.get('launchd_label')} loaded={inst.get('launchd_loaded')} "
            f"schedule={inst.get('schedule', '-')}"
        )
        if inst.get("path"):
            print(f"    path={inst.get('path')} branch={inst.get('branch')} head={inst.get('head', '-')}")
        if inst.get("program"):
            print(f"    program={inst.get('program')}")

    unmanaged = payload["discovered_unmanaged"]
    if unmanaged:
        print("\n== Discovered (unmanaged) com.kleinperkins.* agents ==")
        for item in unmanaged:
            print(f"  {item['label']} loaded={item['loaded']} schedule={_schedule_str(item.get('schedule') or {})}")
    else:
        print("\n== Discovered (unmanaged) ==\n  (none)")
    return 0


def add_schema(job_type: str) -> int:
    reg = load_registry()
    desc = handler_describe(job_type, reg)
    print(json.dumps(desc.get("add_schema") or [], indent=2))
    return 0


def dashboard(as_json: bool) -> int:
    # Delegates to lib/dashboard.py for the richer payload (Phase 7).
    from importlib import import_module

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    dash = import_module("dashboard")
    payload = dash.build_dashboard(load_registry())
    if as_json:
        print(json.dumps(payload, indent=2))
    else:
        dash.print_dashboard(payload)
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

    p_schema = sub.add_parser("add-schema")
    p_schema.add_argument("--type", required=True)

    p_types = sub.add_parser("job-types")

    p_dash = sub.add_parser("dashboard")
    p_dash.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.cmd == "handler-path":
        print(handler_path(args.type))
        return 0
    if args.cmd == "instance-type":
        print(instance_type(args.id))
        return 0
    if args.cmd == "view":
        return view_jobs(args.json)
    if args.cmd == "add-schema":
        return add_schema(args.type)
    if args.cmd == "job-types":
        for jtype in job_types(load_registry()):
            print(jtype)
        return 0
    if args.cmd == "dashboard":
        return dashboard(args.json)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
