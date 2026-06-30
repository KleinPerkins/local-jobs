#!/usr/bin/env python3
"""Rich dashboard payload for local-jobs (consumed by `dashboard --json` and the
Cursor Canvas recipe). Joins handler-discovered instances with the run log to
add last-run, failure streaks, duration aggregates, a next-run *window* (never a
point — jitter is runtime), drift detection, and parsed summaries.
"""

from __future__ import annotations

import statistics
from datetime import datetime
from typing import Any

import events
import registry
import run_log
import schedule as schedule_mod


def _next_run(inst: dict[str, Any], now: datetime) -> dict[str, Any]:
    """Next-run window via the single scheduler (LOCAL time — fixes the UTC
    drift, P1-6). 'inherit' has no own window; it follows the global agent.
    """
    sched = inst.get("schedule")
    if sched in (None, "inherit"):
        return {"window_start": None, "window_end": None, "basis": "inherit"}
    try:
        return schedule_mod.Schedule.parse(sched).next_run(now)
    except (ValueError, KeyError, TypeError):
        return {"window_start": None, "window_end": None, "basis": "unknown"}


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
        "last_run": {
            "ts": last.get("ts"),
            "status": last.get("status"),
            "summary": last.get("summary"),
            "rc": last.get("rc"),
            "fields": last.get("fields") or {},  # full fidelity (P0-B): nothing dropped
        },
        "last_success_ts": last_success,
        "consecutive_failures": cf,
        "durations": agg,
    }


def build_dashboard(reg: dict[str, Any]) -> dict[str, Any]:
    now = datetime.now().astimezone()  # LOCAL, tz-aware (fixes UTC next-run drift)
    instances = registry.collect_instances(reg)
    records = run_log.read_records()
    prefix = (reg.get("discovery") or {}).get("label_prefix", "com.kleinperkins.")
    managed = registry.managed_labels(reg, instances)
    discovered = registry.discover_launchd(prefix)
    unmanaged = [d for d in discovered if d["label"] not in managed]

    out_instances = []
    failing = 0
    quarantined = 0
    for inst in instances:
        # Quarantined (broken) types render as degraded — never crash the board,
        # never claim a schedule/last-run they don't have.
        if inst.get("role") == "error":
            quarantined += 1
            out_instances.append({
                **inst,
                "next_run": {"window_start": None, "window_end": None, "basis": "error"},
                "run_stats": _run_stats([]),
                "drift": False,
            })
            continue
        stats = _run_stats(_records_for(inst, records))
        enabled = inst.get("enabled", True)
        loaded = inst.get("launchd_loaded")
        # Drift both ways: enabled-but-not-loaded, and disabled-but-still-loaded.
        drift = bool((enabled and loaded is False) or (not enabled and loaded is True))
        if stats["consecutive_failures"] > 0:
            failing += 1
        out_instances.append({
            **inst,
            "next_run": _next_run(inst, now),
            "run_stats": stats,
            "drift": drift,
        })

    # Quarantined, failing, and drifted sort to the top.
    out_instances.sort(key=lambda i: (
        0 if (i.get("role") == "error" or i["run_stats"]["consecutive_failures"] > 0 or i["drift"]) else 1,
        i.get("id") or "",
    ))

    return {
        "schema": "dashboard/v1",
        "generated_at": now.isoformat(timespec="seconds"),
        "summary": {
            "total": sum(1 for i in out_instances if i.get("role") != "error"),
            "failing": failing,
            "drifted": sum(1 for i in out_instances if i["drift"]),
            "quarantined": quarantined,
            "unmanaged": len(unmanaged),
        },
        "instances": out_instances,
        "discovered_unmanaged": unmanaged,
        "recent_events": list(reversed(events.recent(25))),  # newest first
    }


def print_dashboard(payload: dict[str, Any]) -> None:
    s = payload["summary"]
    print(f"local-jobs dashboard — generated {payload['generated_at']}")
    print(
        f"  {s['total']} jobs · {s['failing']} failing · {s['drifted']} drifted · "
        f"{s.get('quarantined', 0)} quarantined · {s['unmanaged']} unmanaged"
    )
    for inst in payload["instances"]:
        if inst.get("role") == "error":
            err = inst.get("error") or {}
            print(f"  - {inst.get('type')} [QUARANTINED]: {err.get('reason')} (verb={err.get('verb')})")
            continue
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
