#!/usr/bin/env python3
"""Generic id-keyed CRUD store for local-jobs instance config (jobs/v1).

One implementation for every type's ``config/jobs/<type>.yml`` — load/save/
find/add/set/remove with dup-id rejection, id sanitization, dry-run, and
load-time forward migration (single re-merge-at-load policy via
:mod:`migrate`). Handlers shape their own entry JSON and hand it here; the store
stays type-agnostic. Consolidates the former ``command_store.py`` and the
id-keyed half of the igf backend ``config.py``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import yaml

import contract
import migrate


class Store:
    def __init__(
        self,
        path: Path,
        schema_version: int = 1,
        field_defaults: dict[str, Any] | None = None,
        required: list[str] | None = None,
    ) -> None:
        self.path = Path(path).expanduser()
        self.schema_version = schema_version
        self.field_defaults = field_defaults or {}
        self.required = required or []

    def _skeleton(self) -> dict[str, Any]:
        return {"schema": "jobs/v1", "version": 1, "schema_version": self.schema_version, "instances": []}

    def _read_raw(self) -> dict[str, Any]:
        if not self.path.is_file():
            return self._skeleton()
        with self.path.open() as handle:
            data = yaml.safe_load(handle) or {}
        if data.get("version") not in (None, 1):
            raise SystemExit(f"unsupported store file version: {data.get('version')!r}")
        data.setdefault("schema", "jobs/v1")
        data.setdefault("instances", [])
        return data

    def load(self) -> dict[str, Any]:
        """Read + forward-migrate in memory (re-merge defaults, stamp version)."""
        data = self._read_raw()
        migrate.forward_migrate(data, self.schema_version, self.field_defaults)
        return data

    def save(self, data: dict[str, Any]) -> Path:
        migrate.forward_migrate(data, self.schema_version, self.field_defaults)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        with tmp.open("w") as handle:
            yaml.safe_dump(data, handle, default_flow_style=False, sort_keys=False)
        tmp.replace(self.path)
        return self.path

    def list(self) -> list[dict[str, Any]]:
        return self.load().get("instances") or []

    def find(self, iid: str) -> dict[str, Any] | None:
        for entry in self.list():
            if isinstance(entry, dict) and entry.get("id") == iid:
                return entry
        return None

    def get(self, iid: str) -> dict[str, Any]:
        entry = self.find(iid)
        if entry is None:
            raise SystemExit(f"instance not found: {iid}")
        return entry

    def add(self, entry: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
        iid = entry.get("id")
        contract.sanitize_id(iid or "")
        for field in self.required:
            if field not in entry or entry[field] in (None, ""):
                raise SystemExit(f"missing required field: {field}")
        data = self.load()
        if any(e.get("id") == iid for e in data["instances"]):
            raise SystemExit(f"instance already exists: {iid}")
        data["instances"].append(entry)
        if dry_run:
            return {"dry_run": True, "would_add": entry}
        self.save(data)
        return {"added": iid}

    def set(self, iid: str, patch: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
        data = self.load()
        for entry in data["instances"]:
            if entry.get("id") == iid:
                if dry_run:
                    return {"dry_run": True, "id": iid, "patch": patch}
                entry.update(patch)
                self.save(data)
                return {"updated": iid}
        raise SystemExit(f"instance not found: {iid}")

    def remove(self, iid: str, dry_run: bool = False) -> dict[str, Any]:
        data = self.load()
        if not any(e.get("id") == iid for e in data["instances"]):
            raise SystemExit(f"instance not found: {iid}")
        if dry_run:
            return {"dry_run": True, "would_remove": iid}
        data["instances"] = [e for e in data["instances"] if e.get("id") != iid]
        self.save(data)
        return {"removed": iid}

    def validate(self) -> list[str]:
        data = self.load()
        errs: list[str] = []
        seen: set[str] = set()
        for entry in data["instances"]:
            iid = entry.get("id")
            if not iid:
                errs.append("instance missing id")
                continue
            try:
                contract.sanitize_id(iid)
            except ValueError as exc:
                errs.append(str(exc))
            if iid in seen:
                errs.append(f"duplicate id: {iid}")
            seen.add(iid)
            for field in self.required:
                if field not in entry or entry[field] in (None, ""):
                    errs.append(f"{iid}: missing required field {field}")
        return errs

    def migrate(self) -> dict[str, Any]:
        data = self._read_raw()
        _, changed = migrate.forward_migrate(data, self.schema_version, self.field_defaults)
        if changed:
            self.save(data)
        return {"migrated": changed, "schema_version": self.schema_version, "count": len(data.get("instances") or [])}


def _store_from_args(args: argparse.Namespace) -> Store:
    defaults = json.loads(args.defaults) if args.defaults else {}
    required = json.loads(args.required) if args.required else []
    return Store(Path(args.file), schema_version=args.schema_version, field_defaults=defaults, required=required)


def main() -> int:
    ap = argparse.ArgumentParser(prog="store.py")
    ap.add_argument("--file", required=True)
    ap.add_argument("--schema-version", type=int, default=1)
    ap.add_argument("--defaults", default=None, help="JSON object of optional-field defaults")
    ap.add_argument("--required", default=None, help="JSON array of required field names")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    g = sub.add_parser("get"); g.add_argument("--id", required=True)
    a = sub.add_parser("add"); a.add_argument("--entry", required=True); a.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("set"); s.add_argument("--id", required=True); s.add_argument("--patch", required=True); s.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("remove"); r.add_argument("--id", required=True); r.add_argument("--dry-run", action="store_true")
    sub.add_parser("validate")
    sub.add_parser("migrate")

    args = ap.parse_args()
    store = _store_from_args(args)

    if args.cmd == "list":
        print(json.dumps(store.list(), indent=2))
        return 0
    if args.cmd == "get":
        print(json.dumps(store.get(args.id), indent=2))
        return 0
    if args.cmd == "add":
        print(json.dumps(store.add(json.loads(args.entry), args.dry_run), indent=2))
        return 0
    if args.cmd == "set":
        print(json.dumps(store.set(args.id, json.loads(args.patch), args.dry_run), indent=2))
        return 0
    if args.cmd == "remove":
        print(json.dumps(store.remove(args.id, args.dry_run), indent=2))
        return 0
    if args.cmd == "validate":
        errs = store.validate()
        if errs:
            print("\n".join(errs), file=sys.stderr)
            return 2
        print("ok")
        return 0
    if args.cmd == "migrate":
        print(json.dumps(store.migrate(), indent=2))
        return 0
    return 1


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main())
