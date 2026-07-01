#!/usr/bin/env python3
"""The handler contract for local-jobs: describe/instance validation, a typed
``HandlerError`` with a quarantine projection, and schema-driven arg parsing.

This is the "scaffolding of requirements" that makes every job uniform. The
registry validates handler output against it (failure → one quarantine row, not
an aborted view), and the CLI builds ``add``/``update`` entries from each type's
declared ``add_schema`` so new types never edit the core.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
ROLES = {"instance", "global_scheduler", "error"}
CARDINALITIES = {"singleton", "multi"}


class HandlerError(Exception):
    """A typed handler failure that the registry can quarantine + attribute."""

    def __init__(self, job_type: str, verb: str, rc: int, reason: str, stderr_tail: str = "") -> None:
        super().__init__(f"{job_type} {verb}: {reason}")
        self.job_type = job_type
        self.verb = verb
        self.rc = rc
        self.reason = reason
        self.stderr_tail = (stderr_tail or "").strip()

    def quarantine_row(self) -> dict[str, Any]:
        return quarantine_row(self.job_type, self.reason, self.stderr_tail, verb=self.verb, rc=self.rc)


def quarantine_row(
    job_type: str,
    reason: str,
    stderr_tail: str = "",
    verb: str = "discover",
    rc: int | None = None,
) -> dict[str, Any]:
    """One uniform row representing a quarantined (broken) type.

    Carries ``role:"error"`` so views/dashboards render it as degraded rather
    than crashing, and never claims an agent is loaded.
    """
    return {
        "id": f"{job_type} (error)",
        "type": job_type,
        "role": "error",
        "enabled": False,
        "schedule": None,
        "launchd_label": None,
        "launchd_loaded": None,
        "error": {"verb": verb, "rc": rc, "reason": reason, "stderr_tail": (stderr_tail or "")[-500:]},
    }


def validate_describe(desc: Any) -> list[str]:
    errs: list[str] = []
    if not isinstance(desc, dict):
        return ["describe did not return a JSON object"]
    if not desc.get("type"):
        errs.append("describe.type is required")
    if desc.get("cardinality") not in CARDINALITIES:
        errs.append("describe.cardinality must be 'singleton' or 'multi'")
    if not desc.get("label_token"):
        errs.append("describe.label_token is required")
    if not isinstance(desc.get("add_schema"), list):
        errs.append("describe.add_schema must be a list")
    else:
        for i, field in enumerate(desc["add_schema"]):
            if not isinstance(field, dict) or "flag" not in field:
                errs.append(f"add_schema[{i}] must be an object with a 'flag'")
    sv = desc.get("schema_version", 1)
    if not isinstance(sv, int) or sv < 1:
        errs.append("describe.schema_version must be a positive integer")
    return errs


def validate_instance(inst: Any) -> list[str]:
    errs: list[str] = []
    if not isinstance(inst, dict):
        return ["instance is not a JSON object"]
    role = inst.get("role", "instance")
    if role not in ROLES:
        errs.append(f"role must be one of {sorted(ROLES)}")
    if role == "error":
        return errs  # quarantine rows are intentionally minimal
    for key in ("id", "type", "launchd_label"):
        if not inst.get(key):
            errs.append(f"instance.{key} is required")
    if not isinstance(inst.get("enabled", True), bool):
        errs.append("instance.enabled must be a bool")
    loaded = inst.get("launchd_loaded")
    if loaded is not None and not isinstance(loaded, bool):
        errs.append("instance.launchd_loaded must be bool or null")
    iid = inst.get("id")
    if isinstance(iid, str) and iid not in ("__global__",) and not ID_PATTERN.match(iid):
        errs.append(f"instance.id is not sanitary (^[A-Za-z0-9._-]+$): {iid!r}")
    return errs


def sanitize_id(value: str) -> str:
    if not value or not ID_PATTERN.match(value):
        raise ValueError(f"invalid id (must match ^[A-Za-z0-9._-]+$): {value!r}")
    return value


def _coerce(kind: str, value: str) -> Any:
    if kind == "bool":
        return str(value).strip().lower() in ("1", "true", "yes", "y", "on")
    if kind == "int":
        return int(value)
    return value


def build_entry(
    add_schema: list[dict[str, Any]],
    argv: list[str],
    seed_defaults: bool = True,
    check_required: bool = True,
) -> tuple[dict[str, Any], list[str]]:
    """Build a store entry from CLI flags, driven entirely by ``add_schema``.

    Each schema field may declare ``field`` (target key; defaults to the flag
    without dashes), ``kind`` (``scalar``|``list``|``map``|``bool``|``int``|
    ``id``|``schedule``; default ``scalar``), ``required`` and ``default``.
    Supports ``--flag value``, ``--flag=value`` and repeated flags for lists/maps.

    With ``seed_defaults=False`` / ``check_required=False`` this builds a partial
    patch (only the explicitly-provided fields) for ``update``.
    """
    by_flag: dict[str, dict[str, Any]] = {f["flag"]: f for f in add_schema if isinstance(f, dict) and "flag" in f}
    entry: dict[str, Any] = {}
    errors: list[str] = []

    if seed_defaults:
        for field in add_schema:
            if isinstance(field, dict) and "default" in field:
                entry[_field_name(field)] = field["default"]

    i = 0
    seen: set[str] = set()
    while i < len(argv):
        tok = argv[i]
        flag, inline_val = (tok.split("=", 1) + [None])[:2] if tok.startswith("--") and "=" in tok else (tok, None)
        spec = by_flag.get(flag)
        if spec is None:
            errors.append(f"unknown flag: {flag}")
            i += 1
            continue
        kind = spec.get("kind", "scalar")
        name = _field_name(spec)
        if kind == "flag":  # boolean presence flag
            entry[name] = True
            seen.add(flag)
            i += 1
            continue
        if inline_val is not None:
            value = inline_val
        else:
            if i + 1 >= len(argv):
                errors.append(f"{flag} requires a value")
                break
            value = argv[i + 1]
            i += 1
        i += 1
        seen.add(flag)
        try:
            if kind == "list":
                entry.setdefault(name, [])
                entry[name].append(value)
            elif kind == "map":
                if "=" not in value:
                    errors.append(f"{flag} expects K=V, got: {value}")
                else:
                    k, v = value.split("=", 1)
                    entry.setdefault(name, {})
                    entry[name][k] = v
            elif kind == "id":
                entry[name] = sanitize_id(value)
            else:
                entry[name] = _coerce(kind, value)
        except ValueError as exc:
            errors.append(str(exc))

    if check_required:
        for spec in add_schema:
            if isinstance(spec, dict) and spec.get("required") and spec["flag"] not in seen and _field_name(spec) not in entry:
                errors.append(f"missing required flag: {spec['flag']}")
    return entry, errors


def _field_name(spec: dict[str, Any]) -> str:
    if spec.get("field"):
        return spec["field"]
    return spec["flag"].lstrip("-").replace("-", "_")


def missing_required(add_schema: list[dict[str, Any]], argv: list[str]) -> list[str]:
    present = set()
    for tok in argv:
        if tok.startswith("--"):
            present.add(tok.split("=", 1)[0])
    return [f["flag"] for f in add_schema if isinstance(f, dict) and f.get("required") and f["flag"] not in present]


def main() -> int:
    ap = argparse.ArgumentParser(prog="contract.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate-describe")  # describe JSON on stdin
    p_inst = sub.add_parser("validate-instances")  # instance array on stdin
    p_inst.add_argument("--allow-empty", action="store_true")
    p_build = sub.add_parser("build-entry")
    p_build.add_argument("--schema", required=True, help="add_schema JSON")
    p_build.add_argument("rest", nargs=argparse.REMAINDER)
    p_patch = sub.add_parser("build-patch")
    p_patch.add_argument("--schema", required=True, help="add_schema JSON")
    p_patch.add_argument("rest", nargs=argparse.REMAINDER)
    p_miss = sub.add_parser("missing-required")
    p_miss.add_argument("--schema", required=True, help="add_schema JSON")
    p_miss.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    if args.cmd == "validate-describe":
        errs = validate_describe(json.loads(sys.stdin.read() or "null"))
        if errs:
            print("\n".join(errs), file=sys.stderr)
            return 2
        print("ok")
        return 0
    if args.cmd == "validate-instances":
        data = json.loads(sys.stdin.read() or "[]")
        if not isinstance(data, list):
            print("instances payload must be a JSON array", file=sys.stderr)
            return 2
        all_errs = []
        for inst in data:
            all_errs += validate_instance(inst)
        if all_errs:
            print("\n".join(all_errs), file=sys.stderr)
            return 2
        print("ok")
        return 0
    if args.cmd in ("build-entry", "build-patch"):
        schema = json.loads(args.schema)
        rest = list(args.rest)
        if rest and rest[0] == "--":
            rest = rest[1:]
        is_patch = args.cmd == "build-patch"
        entry, errors = build_entry(
            schema, rest, seed_defaults=not is_patch, check_required=not is_patch
        )
        if errors:
            print(json.dumps({"errors": errors}), file=sys.stderr)
            return 2
        print(json.dumps(entry))
        return 0
    if args.cmd == "missing-required":
        schema = json.loads(args.schema)
        rest = list(args.rest)
        if rest and rest[0] == "--":
            rest = rest[1:]
        miss = missing_required(schema, rest)
        if miss:
            print(" ".join(miss), file=sys.stderr)
            return 2
        print("ok")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
