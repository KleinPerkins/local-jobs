#!/usr/bin/env python3
"""Append-only run history for local-jobs (runlog/v1).

One JSON record per line in ``~/.local-jobs/runs.jsonl``. Writes are made under
an flock sidecar and capped so a single record stays within macOS ``PIPE_BUF``
(512B) to avoid interleave tearing when multiple agents fire in the same window.
Readers tolerate a malformed trailing line (crash-truncation). Rotation keeps
the file bounded by size and age.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MAX_LINE = 512  # macOS PIPE_BUF
MAX_BYTES = 5 * 1024 * 1024
MAX_AGE_DAYS = 90


def state_dir() -> Path:
    return Path(os.environ.get("LOCAL_JOBS_STATE", str(Path.home() / ".local-jobs"))).expanduser()


def runs_path() -> Path:
    return state_dir() / "runs.jsonl"


def _cap_record(record: dict[str, Any]) -> str:
    line = json.dumps(record, separators=(",", ":"))
    if len(line.encode()) <= MAX_LINE:
        return line
    # Trim the largest soft fields until it fits.
    trimmed = dict(record)
    summary = str(trimmed.get("summary", ""))
    if summary:
        trimmed["summary"] = summary[:120] + "…"
    line = json.dumps(trimmed, separators=(",", ":"))
    if len(line.encode()) <= MAX_LINE:
        return line
    # Last resort: drop type-specific fields.
    minimal = {k: trimmed.get(k) for k in ("schema", "ts", "job_id", "type", "status", "duration_s")}
    minimal["summary"] = str(trimmed.get("summary", ""))[:80]
    return json.dumps(minimal, separators=(",", ":"))


def _rotate_if_needed(path: Path) -> None:
    try:
        if not path.is_file():
            return
        if path.stat().st_size <= MAX_BYTES:
            # also age-check the first line
            with path.open(errors="replace") as fh:
                first = fh.readline()
            try:
                ts = json.loads(first).get("ts")
                if ts:
                    age = (datetime.now(timezone.utc) - datetime.fromisoformat(ts)).days
                    if age <= MAX_AGE_DAYS:
                        return
                else:
                    return
            except (json.JSONDecodeError, ValueError):
                return
        # rotate: keep the newest half
        lines = path.read_text(errors="replace").splitlines()
        keep = lines[len(lines) // 2 :]
        path.write_text("\n".join(keep) + ("\n" if keep else ""))
    except OSError:
        pass


def append(record: dict[str, Any]) -> int:
    record.setdefault("schema", "runlog/v1")
    record.setdefault("ts", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    path = runs_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_suffix(".jsonl.lock")
    line = _cap_record(record)
    try:
        with open(lock, "w") as lk:
            fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
            try:
                _rotate_if_needed(path)
                fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
                try:
                    os.write(fd, (line + "\n").encode())
                finally:
                    os.close(fd)
            finally:
                fcntl.flock(lk.fileno(), fcntl.LOCK_UN)
    except OSError as exc:
        print(f"run_log: append failed: {exc}", file=sys.stderr)
        return 1
    return 0


def read_records() -> list[dict[str, Any]]:
    path = runs_path()
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    with path.open(errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # tolerate malformed (e.g. crash-truncated) lines
    return records


def recent(limit: int, job_id: str | None = None) -> list[dict[str, Any]]:
    records = read_records()
    if job_id:
        records = [r for r in records if r.get("job_id") == job_id]
    return records[-limit:]


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("append")  # reads record JSON from stdin
    r = sub.add_parser("recent"); r.add_argument("--limit", type=int, default=20); r.add_argument("--id", default=None)
    args = ap.parse_args()
    if args.cmd == "append":
        data = json.loads(sys.stdin.read() or "{}")
        return append(data)
    if args.cmd == "recent":
        print(json.dumps(recent(args.limit, args.id), indent=2))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
