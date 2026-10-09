"""Exercise the shell review contract without starting an external reviewer."""

import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "plugins/imps/scripts/run-codex-review.sh"


class CodexReviewContractTest(unittest.TestCase):
    def contract(self, cost, status="ok"):
        # Load the production emitters, stopping before CLI dispatch and its IO.
        definitions = SCRIPT.read_text().split('\nwhile [ "$#" -gt 0 ]; do', 1)[0]
        result = subprocess.run(
            ["bash"],
            input=definitions + '\nCOST_USD="$TEST_COST"\nSTATUS="$TEST_STATUS"\nemit_contract\n',
            env={**os.environ, "TEST_COST": cost, "TEST_STATUS": status},
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(len(result.stdout.splitlines()), 1)
        return json.loads(result.stdout)

    def test_invalid_cost_preserves_a_parseable_contract(self):
        for cost in ("", "1.2.3", "...", "01", ".5", "1.", "NaN", "Infinity", "+1", "1e", " 2 "):
            with self.subTest(cost=cost):
                self.assertIsNone(self.contract(cost)["cost_usd"])

    def test_json_numbers_survive(self):
        for cost in ("0", "1", "0.25", "-0.5", "1e-3", "2E+2"):
            with self.subTest(cost=cost):
                self.assertEqual(self.contract(cost)["cost_usd"], json.loads(cost))

    def test_skipped_attempt_has_no_provider(self):
        self.assertIsNone(self.contract("", "skip")["provider"])

    def test_real_attempt_keeps_provider(self):
        for status in ("ok", "blocked"):
            with self.subTest(status=status):
                self.assertEqual(self.contract("", status)["provider"], "codex")

    def test_cli_help_emits_skipped_contract(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], text=True, capture_output=True, check=True)
        contract = json.loads(result.stdout)
        self.assertEqual(contract["status"], "skip")
        self.assertIsNone(contract["provider"])


    def test_cleanup_stops_only_the_snapshot_broker(self):
        # Fake brokers carry the argv shape codex-companion spawns; only the one whose
        # --cwd is exactly the snapshot (and its cxc-* dir) may go.
        definitions = SCRIPT.read_text().split('\nwhile [ "$#" -gt 0 ]; do', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            snapshot = tmp / "run [1]+(x)/repo"
            other = tmp / "run [1]+(x)/repo2"
            procs = {}
            for name, cwd in (("mine", snapshot), ("other", other)):
                session = tmp / f"cxc-{name}"
                session.mkdir()
                (session / "broker.pid").write_text("")
                procs[name] = (session, subprocess.Popen([
                    "sh", "-c", "sleep 30", "app-server-broker.mjs", "serve", "--endpoint",
                    f"unix:{session}/broker.sock", "--cwd", str(cwd), "--pid-file", f"{session}/broker.pid",
                ], start_new_session=True))
            try:
                subprocess.run(
                    ["bash"],
                    input=definitions + f'\nTMP_ROOT=""\nSNAPSHOT={shlex.quote(str(snapshot))}\ncleanup\n',
                    text=True, check=True, capture_output=True,
                )
                self.assertIsNotNone(procs["mine"][1].wait(timeout=5))
                self.assertFalse(procs["mine"][0].exists())
                self.assertIsNone(procs["other"][1].poll())
                self.assertTrue(procs["other"][0].exists())
            finally:
                for _, proc in procs.values():
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()


if __name__ == "__main__":
    unittest.main()
