#!/usr/bin/env python3
"""Unit tests for build/generate.py plugin-file matching logic.

Tests the plugin_for_command_file() function which implements longest-name-first
matching to align with build/npm/lib/installer.js pluginForCommandFile().

Stdlib unittest only — no pytest, no new dependencies.
"""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
_GENERATE_PATH = os.path.join(_HERE, "..", "..", "build", "generate.py")


def _load_module():
    spec = importlib.util.spec_from_file_location("generate", _GENERATE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


generate = _load_module()


class PluginForCommandFileTest(unittest.TestCase):
    """Test the longest-name-first matching logic for command file ownership."""

    def test_exact_match_single_plugin(self):
        """Exact match: filename matches plugin name exactly."""
        self.assertEqual(
            generate.plugin_for_command_file("imps.md", ["imps"]),
            "imps",
        )

    def test_prefix_match_single_plugin(self):
        """Prefix match: filename starts with plugin name and dash."""
        self.assertEqual(
            generate.plugin_for_command_file("imps-cmd.md", ["imps"]),
            "imps",
        )

    def test_no_match_returns_none(self):
        """No match: filename doesn't match any plugin."""
        self.assertEqual(
            generate.plugin_for_command_file("unknown.md", ["imps"]),
            None,
        )

    def test_longest_name_wins_exact_case(self):
        """Longest-name-first: when multiple plugins match, the longest wins."""
        # With both "imps" and "imps-lite" available, "imps-lite.md" should
        # belong to "imps-lite", not "imps"
        result = generate.plugin_for_command_file("imps-lite.md", ["imps", "imps-lite"])
        self.assertEqual(result, "imps-lite")

    def test_longest_name_wins_prefix_case(self):
        """Longest-name-first: "imps-lite-cmd.md" belongs to "imps-lite", not "imps"."""
        result = generate.plugin_for_command_file(
            "imps-lite-cmd.md", ["imps", "imps-lite"]
        )
        self.assertEqual(result, "imps-lite")

    def test_three_plugin_longest_wins(self):
        """Longest-name-first with three overlapping prefixes."""
        plugins = ["ape", "ape-forage", "ape-forage-ext"]
        # "ape-forage-ext-cmd.md" should match "ape-forage-ext"
        self.assertEqual(
            generate.plugin_for_command_file("ape-forage-ext-cmd.md", plugins),
            "ape-forage-ext",
        )
        # "ape-forage-cmd.md" should match "ape-forage"
        self.assertEqual(
            generate.plugin_for_command_file("ape-forage-cmd.md", plugins),
            "ape-forage",
        )
        # "ape-cmd.md" should match "ape"
        self.assertEqual(
            generate.plugin_for_command_file("ape-cmd.md", plugins),
            "ape",
        )

    def test_unrelated_plugins_ignored(self):
        """Longest-name-first with unrelated plugins in the list."""
        plugins = ["imps", "imps-lite", "prompt-builder", "elephant-goldfish"]
        # "imps-lite-cmd.md" should still match "imps-lite", not "imps"
        self.assertEqual(
            generate.plugin_for_command_file("imps-lite-cmd.md", plugins),
            "imps-lite",
        )

    def test_exact_match_beats_unrelated_plugin(self):
        """Exact match should take precedence over any prefix logic."""
        # "prompt-builder.md" should match "prompt-builder", not "prompt"
        # (if "prompt" were a plugin)
        plugins = ["prompt", "prompt-builder"]
        self.assertEqual(
            generate.plugin_for_command_file("prompt-builder.md", plugins),
            "prompt-builder",
        )

    def test_md_extension_removed_for_matching(self):
        """The .md extension should be stripped before matching."""
        # Both versions should match the same plugin
        self.assertEqual(
            generate.plugin_for_command_file("imps.md", ["imps"]),
            "imps",
        )
        self.assertEqual(
            generate.plugin_for_command_file("imps.md", ["imps-lite", "imps"]),
            "imps",
        )


class SubtreeDirectiveTest(unittest.TestCase):
    """REPLACE-SUBTREE / DROP-SUBTREE (issue #164) must be depth-aware -- they swallow a
    nested child heading along with the target -- while the pre-existing REPLACE-SECTION /
    DROP-SECTION directives must keep stopping at the first nested heading of any level,
    unchanged. Both cases are constructed against the same body so the depth-aware and
    non-depth-aware behaviors are distinguished by the test, not just individually
    confirmed.
    """

    BODY = "\n".join(
        [
            "# Title",
            "",
            "## Foo",
            "Foo body line.",
            "",
            "### Bar",
            "Bar body line.",
            "",
            "## Baz",
            "Baz body line.",
            "",
        ]
    )

    def _override(self, tmp_dir, text):
        path = Path(tmp_dir) / "override.md"
        path.write_text(text)
        return generate.parse_override(path)

    def test_replace_section_stops_before_nested_child(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            override = self._override(
                tmp,
                "<!-- REPLACE-SECTION: ## Foo -->\n"
                "## Foo\n"
                "Replaced foo.\n"
                "<!-- END-SECTION -->\n",
            )
            result, held = generate.apply_override(self.BODY, override, "test")
            result = generate.restore_overrides(result, held)
            self.assertIn("Replaced foo.", result)
            self.assertIn("### Bar", result)
            self.assertIn("Bar body line.", result)
            self.assertIn("## Baz", result)

    def test_replace_subtree_swallows_nested_child(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            override = self._override(
                tmp,
                "<!-- REPLACE-SUBTREE: ## Foo -->\n"
                "## Foo\n"
                "Replaced foo and bar.\n"
                "<!-- END-SECTION -->\n",
            )
            result, held = generate.apply_override(self.BODY, override, "test")
            result = generate.restore_overrides(result, held)
            self.assertIn("Replaced foo and bar.", result)
            self.assertNotIn("### Bar", result)
            self.assertNotIn("Bar body line.", result)
            self.assertIn("## Baz", result)
            self.assertIn("Baz body line.", result)

    def test_drop_section_keeps_nested_child(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            override = self._override(tmp, "<!-- DROP-SECTION: ## Foo -->\n")
            result, held = generate.apply_override(self.BODY, override, "test")
            result = generate.restore_overrides(result, held)
            self.assertNotIn("Foo body line.", result)
            self.assertIn("### Bar", result)
            self.assertIn("Bar body line.", result)

    def test_drop_subtree_drops_nested_child_too(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            override = self._override(tmp, "<!-- DROP-SUBTREE: ## Foo -->\n")
            result, held = generate.apply_override(self.BODY, override, "test")
            result = generate.restore_overrides(result, held)
            self.assertNotIn("## Foo", result)
            self.assertNotIn("### Bar", result)
            self.assertNotIn("Bar body line.", result)
            self.assertIn("## Baz", result)
            self.assertIn("Baz body line.", result)

    def test_find_subtree_spans_nested_child_but_not_sibling(self):
        lines = self.BODY.split("\n")
        span = generate.find_subtree(lines, "## Foo")
        self.assertIsNotNone(span)
        start, end = span
        spanned = lines[start:end]
        self.assertIn("### Bar", spanned)
        self.assertNotIn("## Baz", spanned)

    def test_replace_subtree_requires_a_heading_line(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            path = Path(tmp) / "bad.md"
            path.write_text(
                "<!-- REPLACE-SUBTREE: not a heading -->\nx\n<!-- END-SECTION -->\n"
            )
            with self.assertRaises(generate.GenerateError):
                generate.parse_override(path)

    def test_drop_subtree_requires_a_heading_line(self):
        with tempfile.TemporaryDirectory(dir=str(generate.REPO_ROOT)) as tmp:
            path = Path(tmp) / "bad.md"
            path.write_text("<!-- DROP-SUBTREE: not a heading -->\n")
            with self.assertRaises(generate.GenerateError):
                generate.parse_override(path)


if __name__ == "__main__":
    unittest.main()
