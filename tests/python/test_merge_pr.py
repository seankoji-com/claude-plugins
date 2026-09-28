"""Exercise the actual merge helper with isolated GitHub transport stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "plugins/babysitter/scripts/merge-pr.sh"
HEAD = "a" * 40


@unittest.skipUnless(shutil.which("jq"), "jq required by the shipped helper")
class MergeTest(unittest.TestCase):
    def run_helper(self, mode, extra_args=(), followups=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {
                "gh": "#!/bin/sh\nprintf fixture-token",
                "sleep": "#!/bin/sh\nexit 0",
                "curl": '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
mode = os.environ["MERGE_FIXTURE_MODE"]
body = json.loads(a[a.index("--data")+1]) if "--data" in a else {}
with open(os.environ["MERGE_FIXTURE_LOG"], "a") as log:
    log.write(json.dumps(body)+"\\n")
state_file = Path(os.environ["MERGE_FIXTURE_LOG"]).with_suffix(".state")
query = body.get("query", "")
code = "200"
if "node(id:" in query:
    payload = {"data":{"node":{"id":"T1", "pullRequest":{"id":"OTHER" if mode=="foreign" else "PR1", "headRefOid":"a"*40}}}}
elif query.startswith("query"):
    threads = []
    if mode in ("marker", "preexisting-unresolved") or (mode == "flow" and not state_file.exists()):
        threads = [{"id":"T1", "isResolved":False, "comments":{"nodes":[{"body":"[babysitter] fixed"}]}}]
    pr = {"id":"PR1", "state":"OPEN", "headRefOid":"a"*40, "mergeable":"MERGEABLE",
          "mergeStateStatus":"CLEAN", "autoMergeRequest":None,
          "reviewThreads":{"nodes":threads,"pageInfo":{"hasNextPage":mode=="truncated"}},
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}
    if mode in ("merged", "closed"): pr = {"state":mode.upper()}
    if mode == "conflict": pr["mergeable"] = "CONFLICTING"
    if mode == "behind":
        pr["mergeStateStatus"] = "BEHIND"
        if state_file.exists(): pr["headRefOid"] = "b"*40
    if mode == "null": pr = None
    if mode in ("failing", "preexisting-failing", "merged-after-block", "closed-after-block"): pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"] = "FAILURE"
    if mode in ("already-auto", "preexisting-unresolved", "preexisting-failing"): pr["autoMergeRequest"] = {"enabledAt":"fixture-time"}
    rollup, merge_state = {
        "pending": ("PENDING", "BLOCKED"), "expected": ("EXPECTED", "BLOCKED"),
        "pending-dirty": ("PENDING", "DIRTY"), "no-checks": (None, "CLEAN"),
        "state-blocked": ("SUCCESS", "BLOCKED"), "state-unstable": ("SUCCESS", "UNSTABLE"),
        "state-has_hooks": ("SUCCESS", "HAS_HOOKS"), "state-unknown": ("SUCCESS", "UNKNOWN"),
        "review-required": ("SUCCESS", "BLOCKED"),
    }.get(mode, (0, 0))
    if merge_state:
        pr["mergeStateStatus"] = merge_state
        pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = rollup and {"state":rollup}
    if mode == "review-required": pr["reviewDecision"] = "REVIEW_REQUIRED"
    if mode == "behind-then-fresh":
        # update-branch lands a new head whose checks have not registered yet.
        pr["mergeStateStatus"] = "UNKNOWN" if state_file.exists() else "BEHIND"
        if state_file.exists(): pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = None
    if mode in ("merged-after-block", "closed-after-block"):
        if state_file.exists(): pr = {"state":"CLOSED" if mode.startswith("closed") else "MERGED"}
        state_file.write_text("queried")
    payload = {"data":{"repository":{"pullRequest":pr}}}
elif "resolveReviewThread" in query:
    if mode == "flow": state_file.write_text("resolved")
    payload = {"data":{"resolveReviewThread":{"thread":{"id":"T1", "isResolved":True}}}}
elif "enablePullRequestAutoMerge" in query:
    payload = {"data":{"enablePullRequestAutoMerge":{"pullRequest":{"autoMergeRequest":{"enabledAt":"fixture-time"}}}}}
elif query:
    payload = {"errors":[{"message":"unexpected mutation"}]}
else:
    if a[-1].endswith("/update-branch"):
        state_file.write_text("updated")
    if mode == "transport": sys.exit(7)
    code = {"race":"409", "unexpected":"500", "method":"405", "forbidden":"403", "invalid":"422"}.get(mode, "200")
    if mode == "method" and body.get("merge_method") == "merge": code = "200"
    payload = {"merged": code == "200" and mode != "false-success"}
Path(a[a.index("-o")+1]).write_text(json.dumps(payload))
print(code, end="")
''',
            }.items():
                path = root / name
                path.write_text(body)
                path.chmod(0o755)
            log = root / "calls.jsonl"
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "MERGE_FIXTURE_MODE": mode, "MERGE_FIXTURE_LOG": str(log)}
            results = []
            for flags in (extra_args, *followups):
                result = subprocess.run(["bash", str(SCRIPT), "--repo", "fixture/repo", "--pr", "1", *flags],
                                        env=env, capture_output=True, text=True, timeout=20)
                results.append(result)

            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return (results if followups else result), calls

    def test_blocked_resolve_merge_flow_exposes_usable_thread_id(self):
        results, calls = self.run_helper("flow", followups=(
            ["--resolve-thread", "T1", "--verified-head", HEAD], []))
        self.assertEqual([r.returncode for r in results], [4, 0, 0])
        self.assertIn("threads=T1", results[0].stdout)
        self.assertIn("RESOLVED", results[1].stdout)
        self.assertIn("MERGED", results[2].stdout)

    def test_terminal_states_are_idempotent(self):
        result, calls = self.run_helper("merged")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("via preexisting", result.stdout)
        self.assertEqual(len(calls), 1)
        result, calls = self.run_helper("closed")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=closed", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_behind_timeout_does_not_arm_for_future_commits(self):
        result, calls = self.run_helper("behind")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=behind", result.stdout)
        self.assertIn("automerge=unavailable", result.stdout)
        self.assertFalse(any('enablePullRequestAutoMerge' in c.get('query', '') for c in calls))

    def test_conflict_does_not_arm_for_future_commits(self):
        result, calls = self.run_helper("conflict")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=conflict", result.stdout)
        self.assertIn("automerge=unavailable", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_pending_rollup_arms_automerge_instead_of_merging(self):
        # careynas.net#2635: an org-admin token merged over a PENDING rollup via the
        # ruleset's implicit "always" bypass. No merge PUT may be sent. A null rollup
        # (checks not registered yet) counts as pending even when GitHub says CLEAN.
        for mode in ("pending", "expected", "no-checks"):
            with self.subTest(mode=mode):
                result, calls = self.run_helper(mode)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn("reason=checks_pending", result.stdout)
                self.assertIn("automerge=armed", result.stdout)
                self.assertFalse(any("merge_method" in c for c in calls))
                self.assertIn("enablePullRequestAutoMerge", calls[-1]["query"])

    def test_not_clean_merge_state_arms_automerge_instead_of_merging(self):
        for state in ("blocked", "unstable", "has_hooks", "unknown"):
            with self.subTest(state=state):
                result, calls = self.run_helper("state-" + state)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn("reason=not_clean", result.stdout)
                self.assertIn("mergeStateStatus=" + state.upper(), result.stdout)
                self.assertIn("automerge=armed", result.stdout)
                self.assertFalse(any("merge_method" in c for c in calls))

    def test_not_clean_with_no_auto_neither_merges_nor_arms(self):
        result, calls = self.run_helper("state-blocked", ["--no-auto"])
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=not_clean", result.stdout)
        self.assertIn("automerge=unavailable", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_dirty_reports_conflict_before_pending_checks(self):
        result, calls = self.run_helper("pending-dirty")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=conflict", result.stdout)
        self.assertIn("automerge=unavailable", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_clean_with_success_merges_directly(self):
        result, calls = self.run_helper("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MERGED fixture/repo#1 via squash", result.stdout)
        self.assertFalse(any("enablePullRequestAutoMerge" in c.get("query", "") for c in calls))

    def test_required_review_is_reported_as_branch_protection(self):
        result, calls = self.run_helper("review-required")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=branch_protection", result.stdout)
        self.assertIn("reviewDecision=REVIEW_REQUIRED", result.stdout)
        self.assertIn("automerge=armed", result.stdout)
        self.assertFalse(any("merge_method" in c for c in calls))

    def test_behind_sync_never_merges_the_fresh_head_in_the_same_run(self):
        result, calls = self.run_helper("behind-then-fresh")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=checks_pending", result.stdout)
        self.assertIn("rollup=NONE", result.stdout)
        self.assertFalse(any("merge_method" in c for c in calls))

    def test_success_pins_head_and_requires_merged_true(self):
        result, calls = self.run_helper("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MERGED", result.stdout)
        self.assertEqual(calls[-1], {"merge_method": "squash", "sha": HEAD})

    def test_reply_marker_cannot_resolve_thread_or_arm_merge(self):
        result, calls = self.run_helper("marker")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=unanswered_threads", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_incomplete_snapshot_cannot_merge(self):
        for mode, code in (("truncated", 4), ("null", 3)):
            with self.subTest(mode=mode):
                result, calls = self.run_helper(mode)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(len(calls), 1)

    def test_changed_head_never_retries_or_arms_automerge(self):
        result, calls = self.run_helper("race")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=head_changed", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_unknown_outcomes_stop_without_retry(self):
        for mode in ("transport", "unexpected", "false-success"):
            with self.subTest(mode=mode):
                result, calls = self.run_helper(mode)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertNotIn("MERGED", result.stdout)
                self.assertEqual(len(calls), 2)

    def test_permanent_rejections_are_classified_without_retry_or_automerge(self):
        for mode, reason in (("forbidden", "permission_denied"), ("invalid", "validation_failed")):
            with self.subTest(mode=mode):
                result, calls = self.run_helper(mode)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn("reason=" + reason, result.stdout)
                self.assertIn("automerge=unavailable", result.stdout)
                self.assertEqual(len(calls), 2)

    def test_method_fallback_preserves_checked_head(self):
        result, calls = self.run_helper("method")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["sha"] for c in calls[1:]], [HEAD, HEAD])

    def test_automerge_checks_head_when_armed(self):
        result, calls = self.run_helper("failing")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("automerge=armed", result.stdout)
        self.assertIn("expectedHeadOid:$sha", calls[-1]["query"])
        self.assertEqual(calls[-1]["variables"]["sha"], HEAD)

    def test_no_auto_prevents_arming_and_rejects_existing_request(self):
        for mode in ("failing", "already-auto"):
            with self.subTest(mode=mode):
                result, calls = self.run_helper(mode, ["--no-auto"])
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertIn("BLOCKED", result.stdout)

    def test_existing_automerge_is_not_reported_as_unavailable_or_newly_armed(self):
        result, calls = self.run_helper("preexisting-unresolved")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=automerge_already_enabled", result.stdout)
        self.assertIn("automerge=preexisting", result.stdout)
        self.assertEqual(len(calls), 1)
        result, calls = self.run_helper("preexisting-failing")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("automerge=preexisting", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_merge_observed_during_refresh_reports_truth_and_original_blocker(self):
        result, calls = self.run_helper("merged-after-block")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MERGED", result.stdout)
        self.assertIn("prior_blocker=failing_checks", result.stdout)
        self.assertEqual(len(calls), 2)
        result, calls = self.run_helper("closed-after-block")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("reason=closed", result.stdout)
        self.assertIn("prior_blocker=failing_checks", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_explicit_resolution_checks_owner_and_head_without_merging(self):
        args = ["--resolve-thread", "T1", "--verified-head", HEAD]
        result, calls = self.run_helper("resolve", args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESOLVED", result.stdout)
        self.assertEqual(len(calls), 3)
        self.assertIn("resolveReviewThread", calls[-1]["query"])
        result, calls = self.run_helper("foreign", args)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("reason=thread_not_on_pr", result.stdout)
        result, calls = self.run_helper("resolve", ["--resolve-thread", "T1", "--verified-head", "b" * 40])
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("reason=verified_head_changed", result.stdout)


if __name__ == "__main__":
    unittest.main()
