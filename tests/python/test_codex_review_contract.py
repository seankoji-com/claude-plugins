"""Exercise the shell review contract without starting an external reviewer."""

import json
import os
from pathlib import Path
import subprocess
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


if __name__ == "__main__":
    unittest.main()
