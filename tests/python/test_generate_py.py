#!/usr/bin/env python3
"""Unit tests for build/generate.py plugin-file matching logic.

Tests the plugin_for_command_file() function which implements longest-name-first
matching to align with build/npm/lib/installer.js pluginForCommandFile().

Stdlib unittest only — no pytest, no new dependencies.
"""

import importlib.util
import os
import unittest

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


if __name__ == "__main__":
    unittest.main()
