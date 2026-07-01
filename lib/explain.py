#!/usr/bin/env python3
"""Operator narrative layer for local-jobs.

The single source of truth for the plain-English surfaces built on top of a
``dashboard/v1`` payload: ``next_actions[]``, the one-line ``health_verdict``,
per-job ``explain-job`` narratives, and the ``--brief`` printer. Extracted from
``dashboard.py`` so the data-join (``build_dashboard``) and the narrative it
feeds live in separate modules with no copy-paste duplication.

These are pure functions over an already-built payload dict — this module has no
dependency on ``dashboard`` or ``registry``, so it is a leaf in the import graph
(``dashboard`` imports *this*, never the reverse). Behavior is identical to the
prior in-dashboard implementation.
"""

from __future__ import annotations

from typing import Any

STALE_HOURS_DEFAULT = 36


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
