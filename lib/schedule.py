#!/usr/bin/env python3
"""One ``Schedule`` type for local-jobs.

Consolidates the three divergent schedule encodings (``"inherit"``, ``"HH:MM"``,
``{"hour","minute"}``, ``{"window_start_hour",...}``) and fixes:
  - the UTC ``next_run`` bug (P1-6) — ``next_run`` is computed in **local** time;
  - the ``$RANDOM`` jitter cap of 32767s (P2-8) — jitter uses ``random.randrange``
    across the full window.

Pure/​stdlib only. Exposed both as an importable type and a thin CLI so bash
handlers share exactly this logic.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from datetime import datetime, timedelta
from typing import Any

INHERIT = "inherit"


class Schedule:
    __slots__ = ("kind", "hour", "minute", "start_hour", "end_hour", "use_jitter", "seconds")

    def __init__(
        self,
        kind: str,
        hour: int | None = None,
        minute: int = 0,
        start_hour: int | None = None,
        end_hour: int | None = None,
        use_jitter: bool = True,
        seconds: int | None = None,
    ) -> None:
        self.kind = kind
        self.hour = hour
        self.minute = minute
        self.start_hour = start_hour
        self.end_hour = end_hour
        self.use_jitter = use_jitter
        self.seconds = seconds

    @classmethod
    def parse(cls, value: Any) -> "Schedule":
        if isinstance(value, Schedule):
            return value
        if value is None:
            return cls("inherit")
        if isinstance(value, str):
            v = value.strip()
            if v in (INHERIT, ""):
                return cls("inherit")
            if v.startswith("{"):
                return cls.parse(json.loads(v.replace("'", '"')))
            if ":" in v:
                hour_s, minute_s = v.split(":", 1)
                return cls("calendar", hour=int(hour_s), minute=int(minute_s))
            raise ValueError(f"invalid schedule (use inherit | HH:MM | json): {value!r}")
        if isinstance(value, dict):
            if "window_start_hour" in value:
                return cls(
                    "window",
                    start_hour=int(value.get("window_start_hour", 18)),
                    end_hour=int(value.get("window_end_hour", 24)),
                    use_jitter=bool(value.get("use_jitter", True)),
                )
            if value.get("kind") == "interval" or "seconds" in value:
                return cls("interval", seconds=int(value["seconds"]))
            if "hour" in value:
                return cls("calendar", hour=int(value["hour"]), minute=int(value.get("minute", 0)))
            if value.get("kind") == "inherit":
                return cls("inherit")
        raise ValueError(f"unrecognized schedule: {value!r}")

    def serialize(self) -> Any:
        if self.kind == "inherit":
            return "inherit"
        if self.kind == "calendar":
            return {"hour": self.hour, "minute": self.minute}
        if self.kind == "window":
            return {
                "window_start_hour": self.start_hour,
                "window_end_hour": self.end_hour,
                "use_jitter": self.use_jitter,
            }
        if self.kind == "interval":
            return {"kind": "interval", "seconds": self.seconds}
        raise ValueError(self.kind)

    def hhmm(self) -> str:
        if self.kind != "calendar":
            raise ValueError("not a calendar schedule")
        return f"{self.hour:02d}:{self.minute:02d}"

    def calendar(self) -> tuple[int, int] | None:
        """(hour, minute) for a launchd StartCalendarInterval, or None."""
        if self.kind == "calendar":
            return self.hour, self.minute
        if self.kind == "window":
            return self.start_hour, 0
        return None

    def launchd_schedule(self) -> dict[str, Any]:
        """The schedule fragment ``launchd.render_plist`` understands."""
        cal = self.calendar()
        if cal is not None:
            return {"hour": cal[0], "minute": cal[1]}
        if self.kind == "interval":
            return {"seconds": self.seconds}
        return {}

    def validate(self) -> list[str]:
        errs: list[str] = []
        if self.kind == "calendar":
            if self.hour is None or not (0 <= self.hour <= 23):
                errs.append("hour must be 0-23")
            if not (0 <= self.minute <= 59):
                errs.append("minute must be 0-59")
        elif self.kind == "window":
            if self.start_hour is None or not (0 <= self.start_hour <= 23):
                errs.append("window_start_hour must be 0-23")
            if self.end_hour is None or not (self.start_hour < self.end_hour <= 24):
                errs.append("window_end_hour must be > start and <= 24")
        elif self.kind == "interval":
            if not self.seconds or self.seconds <= 0:
                errs.append("interval seconds must be > 0")
        return errs

    def next_run(self, now: datetime | None = None) -> dict[str, Any]:
        now = now or datetime.now().astimezone()  # LOCAL, tz-aware

        def at(hour: int, minute: int) -> datetime:
            cand = now.replace(hour=hour % 24, minute=minute, second=0, microsecond=0)
            if cand <= now:
                cand += timedelta(days=1)
            return cand

        if self.kind == "calendar":
            t = at(self.hour or 0, self.minute)
            stamp = t.isoformat(timespec="minutes")
            return {"window_start": stamp, "window_end": stamp, "basis": "fixed"}
        if self.kind == "window":
            start = at(self.start_hour or 18, 0)
            end = start + timedelta(hours=((self.end_hour or 24) - (self.start_hour or 18)))
            return {
                "window_start": start.isoformat(timespec="minutes"),
                "window_end": end.isoformat(timespec="minutes"),
                "basis": "jitter" if self.use_jitter else "fixed",
            }
        if self.kind == "interval":
            t = now + timedelta(seconds=self.seconds or 0)
            stamp = t.isoformat(timespec="minutes")
            return {"window_start": stamp, "window_end": stamp, "basis": "interval"}
        return {"window_start": None, "window_end": None, "basis": "inherit"}

    def jitter_seconds(self) -> int:
        if self.kind == "window" and self.use_jitter:
            span = ((self.end_hour or 24) - (self.start_hour or 18)) * 3600
            return random.randrange(max(1, span))
        return 0

    def summary(self) -> str:
        if self.kind == "inherit":
            return "inherit (follows global window)"
        if self.kind == "calendar":
            return f"daily {self.hhmm()} local"
        if self.kind == "window":
            tail = f" with jitter to {self.end_hour:02d}:00" if self.use_jitter else " fixed"
            return f"daily {self.start_hour:02d}:00{tail} local"
        if self.kind == "interval":
            return f"every {self.seconds}s"
        return "?"


def _parse_arg(value: str) -> Any:
    value = value.strip()
    if value.startswith("{"):
        return json.loads(value.replace("'", '"'))
    return value


def main() -> int:
    ap = argparse.ArgumentParser(prog="schedule.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("next-run", "jitter", "calendar", "serialize", "summary", "validate"):
        p = sub.add_parser(name)
        p.add_argument("--schedule", required=True)
        if name == "next-run":
            p.add_argument("--now", default=None)
    args = ap.parse_args()
    try:
        sched = Schedule.parse(_parse_arg(args.schedule))
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"schedule: {exc}", file=sys.stderr)
        return 2

    if args.cmd == "next-run":
        now = datetime.fromisoformat(args.now) if args.now else None
        print(json.dumps(sched.next_run(now)))
        return 0
    if args.cmd == "jitter":
        print(sched.jitter_seconds())
        return 0
    if args.cmd == "calendar":
        cal = sched.calendar()
        print(f"{cal[0]} {cal[1]}" if cal else "")
        return 0
    if args.cmd == "serialize":
        print(json.dumps(sched.serialize()))
        return 0
    if args.cmd == "summary":
        print(sched.summary())
        return 0
    if args.cmd == "validate":
        errs = sched.validate()
        if errs:
            print("; ".join(errs), file=sys.stderr)
            return 2
        print("ok")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
