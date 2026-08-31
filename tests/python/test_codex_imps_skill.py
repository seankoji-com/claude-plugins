"""Maintenance contracts for the personal Codex translation of /imps:imps."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugins" / "imps"
SKILL = PLUGIN / "codex-skills" / "imps" / "SKILL.md"
OPENAI_YAML = SKILL.parent / "agents" / "openai.yaml"


class CodexImpsSkillContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SKILL.read_text(encoding="utf-8")

    def frontmatter_value(self, key: str) -> str:
        match = re.search(rf"(?m)^  {re.escape(key)}: \"([^\"]+)\"$", self.text)
        self.assertIsNotNone(match, f"missing metadata.{key}")
        return match.group(1)

    def test_translation_is_reviewed_on_every_imps_version_bump(self) -> None:
        manifest = json.loads(
            (PLUGIN / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(self.frontmatter_value("source-version"), manifest["version"])

    def test_shared_runtime_references_exist(self) -> None:
        for relative in (
            "references/task-sizing.md",
            "references/diagnosis-loop.md",
            "references/checklist-mode.md",
            "references/discussion-mode.md",
            "references/opencode-review.md",
            "scripts/audit-log.sh",
            "scripts/opencode-review.sh",
        ):
            with self.subTest(relative=relative):
                self.assertTrue((PLUGIN / relative).is_file())

    def test_translation_does_not_require_claude_runtime_tools(self) -> None:
        forbidden_calls = ("Workflow({", "ScheduleWakeup({", "AskUserQuestion({")
        for token in forbidden_calls:
            with self.subTest(token=token):
                self.assertNotIn(token, self.text)

    def test_skill_is_an_explicit_user_command(self) -> None:
        metadata = OPENAI_YAML.read_text(encoding="utf-8")
        self.assertIn('default_prompt: "Use $imps ', metadata)
        self.assertIn("allow_implicit_invocation: false", metadata)


if __name__ == "__main__":
    unittest.main()
