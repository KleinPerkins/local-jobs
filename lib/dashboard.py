#!/usr/bin/env python3
"""Rich dashboard payload for local-jobs (consumed by `dashboard --json` and the
Cursor Canvas recipe). Joins handler-discovered instances with the run log to
add last-run, failure streaks, duration aggregates, a next-run *window* (never a
point — jitter is runtime), drift detection, and parsed summaries.
"""

from __future__ import annotations

import statistics
from datetime import datetime, timedelta, timezone
from typing import Any

import registry
import run_log


def _next_at(hour: int, minute: int, now: datetime) -> datetime:
    cand = now.replace(hour=hour % 24, minute=minute, second=0, microsecond=0)
    if cand <= now:
        cand += timedelta(days=1)
    return cand


def _next_run(inst: dict[str, Any], now: datetime) -> dict[str, Any]:
    sched = inst.get("schedule")
    if inst.get("role") == "global_scheduler" and isinstance(sched, dict):
        start_h = int(sched.get("window_start_hour", 18))
        end_h = int(sched.get("window_end_hour", 24))
        jitter = sched.get("use_jitter", True)
        start = _next_at(start_h, 0, now)
        end = start + timedelta(hours=(end_h - start_h))
        return {
            "window_start": start.isoformat(timespec="minutes"),
            "window_end": end.isoformat(timespec="minutes"),
            "basis": "jitter" if jitter else "fixed",
        }
    if isinstance(sched, str) and ":" in sched:
        h, m = sched.split(":", 1)
        at = _next_at(int(h), int(m), now)
        return {"window_start": at.isoformat(timespec="minutes"),
                "window_end": at.isoformat(timespec="minutes"), "basis": "fixed"}
    if isinstance(sched, dict) and "hour" in sched:
        at = _next_at(int(sched["hour"]), int(sched.get("minute", 0)), now)
        return {"window_start": at.isoformat(timespec="minutes"),
                "window_end": at.isoformat(timespec="minutes"), "basis": "fixed"}
    # 'inherit' (per-repo following the global window) — basis says so.
    return {"window_start": None, "window_end": None, "basis": "inherit"}


def _records_for(inst: dict[str, Any], all_records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    job_id = "all" if inst.get("role") == "global_scheduler" else inst.get("id")
    return [r for r in all_records if r.get("job_id") == job_id]


def _run_stats(records: list[dict[str, Any]]) -> dict[str, Any]:
    if not records:
        return {
            "last_run": None, "last_success_ts": None, "consecutive_failures": 0,
            "durations": {"p50": None, "max": None, "avg": None, "series": []},
        }
    last = records[-1]
    last_success = next((r["ts"] for r in reversed(records) if r.get("status") == "success"), None)
    cf = 0
    for r in reversed(records):
        if r.get("status") == "failure":
            cf += 1
        else:
            break
    durs = [int(r["duration_s"]) for r in records if isinstance(r.get("duration_s"), int)]
    series = durs[-10:]
    agg = {
        "p50": int(statistics.median(durs)) if durs else None,
        "max": max(durs) if durs else None,
        "avg": int(statistics.fmean(durs)) if durs else None,
        "series": series,
    }
    return {
        "last_run": {"ts": last.get("ts"), "status": last.get("status"), "summary": last.get("summary")},
        "last_success_ts": last_success,
        "consecutive_failures": cf,
        "durations": agg,
    }


def build_dashboard(reg: dict[str, Any]) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    instances = registry.collect_instances(reg)
    records = run_log.read_records()
    prefix = (reg.get("discovery") or {}).get("label_prefix", "com.kleinperkins.")
    managed = registry.managed_labels(reg, instances)
    discovered = registry.discover_launchd(prefix)
    unmanaged = [d for d in discovered if d["label"] not in managed]

    out_instances = []
    failing = 0
    for inst in instances:
        stats = _run_stats(_records_for(inst, records))
        enabled = inst.get("enabled", True)
        loaded = inst.get("launchd_loaded")
        drift = bool(enabled and loaded is False)
        if stats["consecutive_failures"] > 0:
            failing += 1
        out_instances.append({
            **inst,
            "next_run": _next_run(inst, now),
            "run_stats": stats,
            "drift": drift,
        })

    # Failing + drifted sort to the top.
    out_instances.sort(key=lambda i: (
        0 if (i["run_stats"]["consecutive_failures"] > 0 or i["drift"]) else 1,
        i.get("id") or "",
    ))

    return {
        "schema": "dashboard/v1",
        "generated_at": now.isoformat(timespec="seconds"),
        "summary": {
            "total": len(out_instances),
            "failing": failing,
            "drifted": sum(1 for i in out_instances if i["drift"]),
            "unmanaged": len(unmanaged),
        },
        "instances": out_instances,
        "discovered_unmanaged": unmanaged,
    }


def print_dashboard(payload: dict[str, Any]) -> None:
    s = payload["summary"]
    print(f"local-jobs dashboard — generated {payload['generated_at']}")
    print(f"  {s['total']} jobs · {s['failing']} failing · {s['drifted']} drifted · {s['unmanaged']} unmanaged")
    for inst in payload["instances"]:
        rs = inst["run_stats"]
        last = rs["last_run"]
        last_s = f"{last['status']} — {last['summary']}" if last else "never run"
        flags = []
        if inst["drift"]:
            flags.append("DRIFT")
        if rs["consecutive_failures"] > 0:
            flags.append(f"{rs['consecutive_failures']}x FAIL")
        flag_s = (" [" + ",".join(flags) + "]") if flags else ""
        print(f"  - {inst.get('id')} ({inst.get('type')}){flag_s}: last={last_s}")
        nr = inst["next_run"]
        if nr.get("window_start"):
            print(f"      next: {nr['window_start']}..{nr['window_end']} ({nr['basis']})")
