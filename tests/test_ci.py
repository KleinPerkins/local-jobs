#!/usr/bin/env python3
"""Execute fail-closed CI mutations and the canary executable-fixture regression."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


ci = module("canary_verify", "scripts/verify.py")
ENV = dict(GITHUB_REPOSITORY="KleinPerkins/local-jobs", GITHUB_REPOSITORY_ID="1284625858",
           GITHUB_EVENT_NAME="pull_request", GITHUB_SHA="a"*40, GITHUB_WORKFLOW_SHA="a"*40,
           GITHUB_RUN_ID="100", GITHUB_RUN_ATTEMPT="2", GITHUB_REF="refs/pull/12/merge",
           CI_HEAD_SHA="c"*40, CI_BASE_SHA="d"*40,
           GITHUB_WORKFLOW_REF="KleinPerkins/local-jobs/.github/workflows/ci.yml@refs/pull/12/merge",
           GITHUB_WORKFLOW="CI")


def needs():
    return {shard:{"result":"success", "outputs":{"receipt":json.dumps({
        "schema":"local-jobs-ci-shard/v1", "shard":shard, "identity":ci.identity(ENV),
        "tests":paths, "result":"success"})}} for shard, paths in ci.SHARDS.items()}


class AggregateTests(unittest.TestCase):
    def test_complete_exact_run_passes(self):
        ci.validate_aggregate(needs(), ci.identity(ENV))

    def test_every_nonsuccess_result_fails(self):
        for shard in ci.SHARDS:
            for result in ("failure", "cancelled", "skipped", "neutral", "timed_out", "", None):
                with self.subTest(shard=shard, result=result):
                    data = needs()
                    data[shard]["result"] = result
                    with self.assertRaises(ci.ContractError):
                        ci.validate_aggregate(data, ci.identity(ENV))

    def test_missing_extra_duplicate_or_empty_evidence_fails(self):
        mutations = [None, {}, {"overlay":needs()["overlay"]}, dict(needs(), extra={})]
        for value in ("", "null", "[]", "{}", "not-json"):
            data = needs()
            data["overlay"]["outputs"]["receipt"] = value
            mutations.append(data)
        for field in ("outputs", "result"):
            data = needs()
            del data["overlay"][field]
            mutations.append(data)
        data = needs()
        data["app-and-ci"] = data["overlay"]
        mutations.append(data)
        for data in mutations:
            with self.subTest(data=data), self.assertRaises(ci.ContractError):
                ci.validate_aggregate(data, ci.identity(ENV))

    def test_each_stale_identity_field_fails(self):
        for key in ci.IDENTITY_KEYS:
            data = needs()
            receipt = json.loads(data["overlay"]["outputs"]["receipt"])
            receipt["identity"][key] += "-stale"
            data["overlay"]["outputs"]["receipt"] = json.dumps(receipt)
            with self.subTest(key=key), self.assertRaises(ci.ContractError):
                ci.validate_aggregate(data, ci.identity(ENV))

    def test_incomplete_receipt_suite_or_schema_fails(self):
        for key, value in (("tests", []), ("tests", ["echo passed"]), ("shard", "other"),
                           ("schema", "local-jobs-ci-shard/v0"), ("result", "failure")):
            data = needs()
            receipt = json.loads(data["overlay"]["outputs"]["receipt"])
            receipt[key] = value
            data["overlay"]["outputs"]["receipt"] = json.dumps(receipt)
            with self.subTest(key=key, value=value), self.assertRaises(ci.ContractError):
                ci.validate_aggregate(data, ci.identity(ENV))


class SourceTests(unittest.TestCase):
    def test_reject_wrong_or_incomplete_environment(self):
        for key in ENV:
            data = dict(ENV)
            data[key] = ""
            with self.subTest(key=key), self.assertRaises(ci.ContractError):
                ci.identity(data)
        for key, value in (("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_REPOSITORY_ID", "1"),
                           ("GITHUB_REF", "refs/heads/main"), ("GITHUB_RUN_ATTEMPT", "0")):
            with self.subTest(key=key), self.assertRaises(ci.ContractError):
                ci.identity(dict(ENV, **{key:value}))

    def test_push_main_identity_and_rejections(self):
        env = dict(ENV, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main", CI_HEAD_SHA="", CI_BASE_SHA="",
                   GITHUB_WORKFLOW_REF="KleinPerkins/local-jobs/.github/workflows/ci.yml@refs/heads/main")
        self.assertEqual(ci.identity(env)["event"], "push")
        for change in ({"GITHUB_REF":"refs/heads/other"}, {"CI_HEAD_SHA":"c"*40}):
            with self.subTest(change=change), self.assertRaises(ci.ContractError):
                ci.identity(dict(env, **change))

    def test_revision_and_merge_parents_must_match(self):
        expected = ci.identity(ENV)
        with mock.patch.object(ci.subprocess, "check_output", side_effect=["a"*40, "d"*40+" "+"c"*40]):
            ci.check_checkout(expected)
        for outputs in (["f"*40], ["a"*40, "c"*40+" "+"d"*40], ["a"*40, "d"*40]):
            with self.subTest(outputs=outputs), mock.patch.object(ci.subprocess, "check_output", side_effect=outputs):
                with self.assertRaises(ci.ContractError):
                    ci.check_checkout(expected)

    def test_real_git_merge_objects_bind_both_parents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*arguments, content=None):
                return subprocess.check_output(["git", "-C", str(root), *arguments],
                                               input=content, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "--quiet")
            tree = git("hash-object", "-t", "tree", "-w", "--stdin", content="")
            def commit(message, *parents):
                args = ["-c", "user.name=Canary Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit-tree", tree]
                for parent in parents:
                    args += ["-p", parent]
                return git(*args, content=message+"\n")
            base = commit("base")
            head = commit("head", base)
            merge = commit("merge", base, head)
            git("update-ref", "HEAD", merge)
            expected = dict(ci.identity(ENV), revision=merge, base_sha=base, head_sha=head)
            with mock.patch.object(ci, "ROOT", root):
                ci.check_checkout(expected)
                for change in ({"revision":head}, {"base_sha":head}, {"head_sha":base}):
                    with self.subTest(change=change), self.assertRaises(ci.ContractError):
                        ci.check_checkout(dict(expected, **change))

    def test_failed_suite_cannot_emit_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/"output"
            with mock.patch.dict(ci.os.environ, dict(ENV, GITHUB_OUTPUT=str(output)), clear=True), \
                 mock.patch.object(ci, "check_checkout"), \
                 mock.patch.object(ci.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "test")):
                with self.assertRaises(subprocess.CalledProcessError):
                    ci.run_shard("overlay")
            self.assertFalse(output.exists())

    def test_successful_suite_emits_bound_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/"output"
            with mock.patch.dict(ci.os.environ, dict(ENV, GITHUB_OUTPUT=str(output)), clear=True), \
                 mock.patch.object(ci, "check_checkout"), mock.patch.object(ci.subprocess, "run") as run:
                ci.run_shard("app-and-ci")
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args.args[0][-1], "tests/test_ci.py")
            value = json.loads(output.read_text().removeprefix("receipt="))
            self.assertEqual(value["identity"], ci.identity(ENV))
            self.assertEqual(value["tests"], ci.SHARDS["app-and-ci"])


class WorkflowTests(unittest.TestCase):
    def test_closed_meaningful_coverage(self):
        mapped=[p for paths in ci.SHARDS.values() for p in paths]
        actual=[str(p.relative_to(ROOT)) for p in (ROOT/'tests').glob('test_*.py')]
        self.assertEqual(sorted(mapped),sorted(actual))
        self.assertEqual(len(mapped),len(set(mapped)))
        self.assertEqual(ci.SHARDS['overlay'],['tests/test_overlay.py'])
    def test_unprivileged_pinned_bounded_workflow(self):
        workflow=json.loads((ROOT/'.github/workflows/ci.yml').read_text())
        self.assertEqual(workflow['permissions'],{'contents':'read'})
        self.assertEqual(set(workflow['on']),{'push','pull_request','workflow_dispatch'})
        self.assertEqual(set(workflow['jobs']),set(ci.SHARDS)|{'ci-required'})
        aggregate=workflow['jobs']['ci-required']
        self.assertEqual(set(aggregate['needs']),set(ci.SHARDS))
        self.assertEqual(aggregate['if'],'${{ always() }}')
        for name,job in workflow['jobs'].items():
            self.assertIn(job['runs-on'],['ubuntu-24.04','macos-15'])
            self.assertLessEqual(job['timeout-minutes'],10)
            self.assertNotIn('permissions',job)
            checkout=job['steps'][0]
            self.assertRegex(checkout['uses'],r'^actions/checkout@[0-9a-f]{40}$')
            self.assertEqual(checkout['with']['ref'],'${{ github.sha }}')
            self.assertFalse(checkout['with']['persist-credentials'])
            self.assertNotIn('secrets.',json.dumps(job))
            if name in ci.SHARDS:
                self.assertEqual(job['steps'][1]['run'],'python3 -I -B scripts/verify.py shard --shard '+name)

if __name__ == '__main__':
    unittest.main()
