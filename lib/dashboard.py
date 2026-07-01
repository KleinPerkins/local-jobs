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

STALE_HOURS_DEFAULT = 36


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


def _hours_since(ts: str | None, now: datetime) -> float | None:
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.astimezone()
        return (now - dt).total_seconds() / 3600.0
    except (ValueError, TypeError):
        return None


def _is_stale(last_success_ts: str | None, schedule: Any, now: datetime, threshold_h: float = STALE_HOURS_DEFAULT) -> bool:
    """True when a daily-scheduled job hasn't succeeded within threshold hours."""
    if schedule in (None, "inherit", "?"):
        return False
    hrs = _hours_since(last_success_ts, now)
    if hrs is None:
        return True
    return hrs > threshold_h


def _recent_runs(limit: int = 15) -> list[dict[str, Any]]:
    return [e for e in events.recent(limit * 3) if e.get("kind") == "run"][:limit]


def _action(priority: int, job_id: str, jtype: str, issue: str, verb: str, command: str) -> dict[str, Any]:
    return {
        "priority": priority,
        "job_id": job_id,
        "type": jtype,
        "issue": issue,
        "verb": verb,
        "command": command,
    }


def build_next_actions(payload: dict[str, Any]) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    for inst in payload.get("instances", []):
        iid = inst.get("id") or inst.get("type") or "?"
        jtype = inst.get("type") or "?"
        if inst.get("role") == "error":
            actions.append(_action(1, iid, jtype, "quarantined type", "doctor",
                                     f"local-jobs.sh doctor"))
            continue
        rs = inst.get("run_stats") or {}
        if inst.get("drift"):
            actions.append(_action(1, iid, jtype, "launchd drift", "repair",
                                     f"local-jobs.sh repair-job --id {iid}"))
        if rs.get("consecutive_failures", 0) > 0:
            actions.append(_action(2, iid, jtype, f"{rs['consecutive_failures']} consecutive failure(s)", "logs",
                                     f"local-jobs.sh logs-job --id {iid} --tail 50"))
            actions.append(_action(2, iid, jtype, "retry run", "run",
                                     f"local-jobs.sh run-job --id {iid}"))
        if inst.get("stale"):
            actions.append(_action(3, iid, jtype, "stale — no recent success", "run",
                                     f"local-jobs.sh run-job --id {iid}"))
    for item in payload.get("discovered_unmanaged") or []:
        label = item.get("label") or "?"
        actions.append(_action(4, label, "unmanaged", "unmanaged launch agent", "adopt",
                                 f"local-jobs.sh adopt-job --label {label}"))
    actions.sort(key=lambda a: (a["priority"], a.get("job_id") or ""))
    return actions


def build_health_verdict(payload: dict[str, Any]) -> str:
    s = payload.get("summary") or {}
    parts: list[str] = []
    total = s.get("total", 0)
    if s.get("quarantined", 0):
        parts.append(f"{s['quarantined']} quarantined type(s)")
    if s.get("failing", 0):
        parts.append(f"{s['failing']} failing")
    if s.get("drifted", 0):
        parts.append(f"{s['drifted']} drifted")
    stale = sum(1 for i in payload.get("instances", []) if i.get("stale"))
    if stale:
        parts.append(f"{stale} stale")
    if s.get("unmanaged", 0):
        parts.append(f"{s['unmanaged']} unmanaged agent(s)")
    if not parts:
        return f"All {total} managed job(s) healthy."
    return f"{total} job(s): " + ", ".join(parts) + "."


def build_explain(job_id: str, job_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    inst = next((i for i in payload.get("instances", []) if i.get("id") == job_id), None)
    if inst is None:
        return {
            "job_id": job_id,
            "type": job_type,
            "found": False,
            "narrative": [f"No managed instance '{job_id}' found."],
            "suggested_commands": [f"local-jobs.sh resolve-instance --query {job_id}"],
        }
    lines: list[str] = []
    cmds: list[str] = []
    enabled = inst.get("enabled", True)
    loaded = inst.get("launchd_loaded")
    lines.append(f"{job_id} ({job_type}) is {'enabled' if enabled else 'disabled'}; launchd loaded={loaded}.")
    rs = inst.get("run_stats") or {}
    last = rs.get("last_run")
    if last:
        lines.append(f"Last run: {last.get('status')} at {last.get('ts')} — {last.get('summary') or '(no summary)'}.")
    else:
        lines.append("Never run (no run-log records).")
    if inst.get("drift"):
        lines.append("DRIFT: enabled state disagrees with launchd — repair recommended.")
        cmds.append(f"local-jobs.sh repair-job --id {job_id}")
    if rs.get("consecutive_failures", 0) > 0:
        lines.append(f"Failing streak: {rs['consecutive_failures']} consecutive failure(s).")
        cmds.append(f"local-jobs.sh logs-job --id {job_id} --tail 50")
        cmds.append(f"local-jobs.sh run-job --id {job_id}")
    if inst.get("stale"):
        lines.append(f"Stale: no success in >{STALE_HOURS_DEFAULT}h (daily schedule).")
        cmds.append(f"local-jobs.sh run-job --id {job_id}")
    nr = inst.get("next_run") or {}
    if nr.get("window_start"):
        lines.append(f"Next window: {nr['window_start']}..{nr.get('window_end')} ({nr.get('basis')}).")
    if inst.get("role") == "error":
        err = inst.get("error") or {}
        lines.append(f"QUARANTINED: {err.get('reason')}")
        cmds.append("local-jobs.sh doctor")
    # dedupe commands preserving order
    seen: set[str] = set()
    deduped = [c for c in cmds if not (c in seen or seen.add(c))]
    return {
        "job_id": job_id,
        "type": job_type,
        "found": True,
        "narrative": lines,
        "suggested_commands": deduped or [f"local-jobs.sh dashboard --json"],
    }


def print_brief(payload: dict[str, Any]) -> None:
    print(build_health_verdict(payload))
    s = payload.get("summary") or {}
    print(f"  {s.get('total', 0)} managed · {s.get('failing', 0)} failing · "
          f"{s.get('drifted', 0)} drifted · {s.get('quarantined', 0)} quarantined · "
          f"{s.get('unmanaged', 0)} unmanaged")
    actions = payload.get("next_actions") or []
    if actions:
        print("Next actions:")
        for a in actions[:3]:
            print(f"  • {a['issue']} ({a['job_id']}): {a['command']}")
    stale_n = sum(1 for i in payload.get("instances", []) if i.get("stale"))
    if stale_n:
        print(f"  {stale_n} job(s) stale (no success in >{STALE_HOURS_DEFAULT}h).")
    gen = payload.get("generated_at")
    if gen:
        print(f"  Snapshot: {gen}")


def print_explain(explain: dict[str, Any]) -> None:
    print(f"=== {explain.get('job_id')} ({explain.get('type')}) ===")
    for line in explain.get("narrative") or []:
        print(line)
    cmds = explain.get("suggested_commands") or []
    if cmds:
        print("\nSuggested:")
        for c in cmds:
            print(f"  {c}")


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
                "stale": False,
                "hours_since_success": None,
            })
            continue
        stats = _run_stats(_records_for(inst, records))
        enabled = inst.get("enabled", True)
        loaded = inst.get("launchd_loaded")
        # Drift both ways: enabled-but-not-loaded, and disabled-but-still-loaded.
        drift = bool((enabled and loaded is False) or (not enabled and loaded is True))
        stale = _is_stale(stats["last_success_ts"], inst.get("schedule"), now)
        hours_since = _hours_since(stats["last_success_ts"], now)
        if stats["consecutive_failures"] > 0:
            failing += 1
        out_instances.append({
            **inst,
            "next_run": _next_run(inst, now),
            "run_stats": stats,
            "drift": drift,
            "stale": stale,
            "hours_since_success": hours_since,
        })

    # Quarantined, failing, and drifted sort to the top.
    out_instances.sort(key=lambda i: (
        0 if (i.get("role") == "error" or i["run_stats"]["consecutive_failures"] > 0 or i["drift"] or i.get("stale")) else 1,
        i.get("id") or "",
    ))

    recent_runs = list(reversed(_recent_runs(15)))
    payload = {
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
        "recent_runs": recent_runs,
    }
    payload["health_verdict"] = build_health_verdict(payload)
    payload["next_actions"] = build_next_actions(payload)
    return payload


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
