#!/usr/bin/env python3
"""Run bounded canary shards and verify exact-run, exact-revision completion."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARDS = {'overlay': ['tests/test_overlay.py'], 'review-adapter': ['tests/test_local_review.py', 'tests/test_create_review_pr.py'], 'app-and-ci': ['tests/test_reviewer_app.py', 'tests/test_ci.py']}
IDENTITY_KEYS = ("repository", "repository_id", "event", "revision", "workflow_sha",
                 "run_id", "run_attempt", "ref", "head_sha", "base_sha", "workflow_ref", "workflow")


class ContractError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def identity(environment: dict[str, str]) -> dict[str, str]:
    names = ("GITHUB_REPOSITORY", "GITHUB_REPOSITORY_ID", "GITHUB_EVENT_NAME", "GITHUB_SHA",
             "GITHUB_WORKFLOW_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_REF",
             "CI_HEAD_SHA", "CI_BASE_SHA", "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW")
    value = {key: environment.get(name, "") for key, name in zip(IDENTITY_KEYS, names)}
    require(value["repository"] == "KleinPerkins/local-jobs", "wrong repository")
    require(value["repository_id"] == "1284625858", "wrong immutable repository id")
    require(value["event"] in {"push", "pull_request", "workflow_dispatch"}, "unsupported CI event")
    for key in ("revision", "workflow_sha"):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", value[key])), f"invalid {key}")
    for key in ("run_id", "run_attempt"):
        require(bool(re.fullmatch(r"[1-9][0-9]*", value[key])), f"invalid {key}")
    if value["event"] == "pull_request":
        require(bool(re.fullmatch(r"refs/pull/[1-9][0-9]*/merge", value["ref"])), "expected PR merge ref")
        for key in ("head_sha", "base_sha"):
            require(bool(re.fullmatch(r"[0-9a-f]{40}", value[key])), f"invalid {key}")
    else:
        require(value["ref"] == "refs/heads/main", "push must target main")
        require(value["head_sha"] == value["base_sha"] == "", "unexpected PR identity on push")
    require(value["workflow"] == "CI", "wrong workflow name")
    require(value["workflow_sha"] == value["revision"], "workflow revision differs from tested source")
    require(value["workflow_ref"] == "KleinPerkins/local-jobs/.github/workflows/ci.yml@" + value["ref"],
            "wrong workflow path or ref")
    return value


def validate_aggregate(needs: dict, expected: dict[str, str]) -> None:
    require(isinstance(needs, dict) and set(needs) == set(SHARDS), "missing or extra required shard")
    for shard in SHARDS:
        row = needs[shard]
        require(isinstance(row, dict) and set(row) == {"result", "outputs"}, f"invalid shard {shard}")
        require(row["result"] == "success", f"shard {shard} did not succeed")
        outputs = row["outputs"]
        require(isinstance(outputs, dict) and set(outputs) == {"receipt"}, f"missing receipt for {shard}")
        try:
            receipt = json.loads(outputs["receipt"])
        except (ValueError, TypeError) as exc:
            raise ContractError(f"invalid receipt for {shard}") from exc
        require(receipt == {"schema": "local-jobs-ci-shard/v1", "shard": shard,
                            "identity": expected, "tests": SHARDS[shard], "result": "success"},
                f"stale or incorrect receipt for {shard}")


def check_checkout(expected: dict[str, str]) -> None:
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(revision == expected["revision"], "checkout differs from event revision")
    # A PR run tests GitHub's merge revision, with both constituent revisions bound.
    if expected["event"] == "pull_request":
        parents = subprocess.check_output(["git", "show", "-s", "--format=%P", "HEAD"],
                                          cwd=ROOT, text=True).split()
        require(parents == [expected["base_sha"], expected["head_sha"]],
                "merge revision does not bind the expected base and head")


def run_shard(shard: str) -> None:
    expected = identity(dict(os.environ))
    check_checkout(expected)
    for path in SHARDS[shard]:
        subprocess.run([sys.executable, "-I", "-B", path], cwd=ROOT, check=True)
    receipt = {"schema": "local-jobs-ci-shard/v1", "shard": shard, "identity": expected,
               "tests": SHARDS[shard], "result": "success"}
    output = os.environ.get("GITHUB_OUTPUT")
    require(bool(output), "GITHUB_OUTPUT is required for hosted shards")
    with open(output, "a", encoding="utf-8") as stream:
        stream.write("receipt=" + json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["local", "shard", "aggregate"])
    parser.add_argument("--shard", choices=SHARDS)
    args = parser.parse_args()
    if args.mode == "local":
        require(args.shard is None, "local runs all shards")
        for paths in SHARDS.values():
            for path in paths:
                subprocess.run([sys.executable, "-I", "-B", path], cwd=ROOT, check=True)
        print("All local shards passed; hosted execution is unqualified")
    elif args.mode == "shard":
        require(args.shard is not None, "a shard is required")
        run_shard(args.shard)
    else:
        require(args.shard is None, "aggregate cannot select a shard")
        expected = identity(dict(os.environ))
        check_checkout(expected)
        validate_aggregate(json.loads(os.environ.get("CI_NEEDS", "null")), expected)
        print("LOCAL_JOBS_CI_AGGREGATE_V1 " + json.dumps({"schema": "local-jobs-ci-aggregate/v1", "identity": expected, "result": "success"}, sort_keys=True, separators=(",", ":")))
        print("ci-required: every required shard passed for this exact run and revision")


if __name__ == "__main__":
    try:
        main()
    except (ContractError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"CI verification failed: {exc}", file=sys.stderr)
        sys.exit(1)
