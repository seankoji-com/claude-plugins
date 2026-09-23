"""Publishing retries must not lose artifacts or turn dry runs into writes."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "plugins/elephant-goldfish/scripts/gh_publish.py"
spec = importlib.util.spec_from_file_location("publish_transactions", SCRIPT)
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)


class PublishTransactions(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.topic = self.root / "topic"
        self.topic.mkdir()
        self.meta = self.topic / "meta.json"
        self.meta.write_text(json.dumps({"github": {"mode": "issue", "number": 7, "repo": "owner/repo"}}))
        (self.topic / "spec.md").write_text("Original artifact")
        self.args = argparse.Namespace(root=str(self.root), slug="topic", artifact="spec.md", dry_run=False)

    def post(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return gp.cmd_post(self.args)

    def test_failed_post_does_not_record_digest_and_retry_can_publish(self):
        before = self.meta.read_bytes()
        with patch.object(gp, "require_gh"), patch.object(gp, "run", side_effect=gp.PublishError("offline")):
            with self.assertRaises(gp.PublishError):
                self.post()
        self.assertEqual(self.meta.read_bytes(), before)
        with patch.object(gp, "require_gh"), patch.object(gp, "run", return_value="https://example.invalid/comment") as run:
            self.assertEqual(self.post(), 0)
            self.assertEqual(self.post(), 0)
            self.assertEqual(run.call_count, 1)
            (self.topic / "spec.md").write_text("Revised artifact")
            self.assertEqual(self.post(), 0)
            self.assertEqual(run.call_count, 2)
            self.assertIn("Revised artifact", run.call_args.kwargs["stdin"])

    def test_dry_run_never_invokes_github_or_changes_metadata(self):
        self.args.dry_run = True
        before = self.meta.read_bytes()
        with patch.object(gp, "require_gh") as require, patch.object(gp, "run") as run:
            self.assertEqual(self.post(), 0)
            require.assert_not_called()
            run.assert_not_called()
        self.assertEqual(self.meta.read_bytes(), before)

    def test_local_only_topic_cannot_publish(self):
        self.meta.write_text("{}")
        with patch.object(gp, "run") as run:
            with self.assertRaisesRegex(gp.PublishError, "local-only"):
                self.post()
            run.assert_not_called()
