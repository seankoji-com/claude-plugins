#!/usr/bin/env python3
"""Cross-platform drift budget for build/overrides/<plugin>/{agy/skills,opencode/commands}/*.md.

Each per-platform override file is hand-authored, final platform-specific text: apply_override's
docstring in build/generate.py says outright that "the platform mapping does not run over it,"
so a REPLACE-SECTION body writes __PLUGIN_ROOT__ and platform paths directly rather than the
Claude-native form generate.py's apply_mapping() would otherwise substitute.

That means the agy copy and the opencode copy of the same override are two independent,
by-hand documents with no shared source generate.py re-derives at build time -- unlike every
other platform-specific string in dist/, which comes from one Claude source plus
build/platform-table.json's `replacements` table. Nothing catches the two hand-authored copies
silently drifting apart on an edit to just one of them (the AGENTS.md "Cross-plugin audit log"
precedent -- audit-log.sh bundled identically into three plugins, diffed byte-for-byte by
tests/run.sh -- has no counterpart here).

A byte-for-byte diff (audit-log.sh's approach) doesn't fit this pair: the two copies are
*expected* to differ, by design, in platform-specific wording -- everything from a handful of
substituted paths (imp-agency.md) up to a wholly different CLI invocation and its own citation
of a different matrix item (issue-mode.md's `opencode run -m` vs `agy -p --model`). There is no
mechanical way to tell "still-legitimate platform wording" apart from "someone edited one copy
and forgot the other" from the text alone.

So this is a budget check (build/dist-lint.sh's check_budget is the precedent), not an equality
check: reduce the opencode copy by every substitution generate.py itself already computes for
this pair (build/platform-table.json's `replacements`, this plugin's own invocation-name
mapping, and the one hand-authored platform-label convention every override's leading comment
uses), then diff what's left against the agy copy. The line count of THAT diff is pinned per
pair below, at what the tree actually contains when this test was written -- covering every
genuine, necessary platform-specific line already in the file. A future edit that grows the
unexplained-diff footprint beyond its recorded ceiling fails here; shrinking it (folding a
difference into `replacements` instead, or genuinely simplifying) is always allowed, silently.
Only pairs whose *unreduced* line similarity (difflib.SequenceMatcher) is >= NEAR_DUPLICATE_RATIO
carry a budget at all -- a pair that starts out substantially different by design (e.g. ape's
forage.md) isn't a near-duplicate and gets no entry, rather than an artificially high one.
"""

import difflib
import sys
import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT / "build"))
import generate  # noqa: E402


# The one hand-authored (not platform-table.json-derived) pair every existing override file's
# leading comment uses consistently to name which platform it targets. Order matters: the
# longer, header-specific pair must run before the bare-word fallback, or the fallback would
# already have consumed the "OpenCode" inside the header phrase before the specific pair gets a
# chance to match it. Not a generic substitution generate.py would ever apply to a Claude
# source, so it lives here, explicitly, rather than pretending it belongs in
# build/platform-table.json's `replacements`.
_PLATFORM_LABEL_PAIRS = [
    ("OpenCode overrides for /", "Antigravity (agy) overrides for /"),
    ("OpenCode", "Agy"),
]

# Below this raw (pre-substitution) line similarity, a pair is legitimately divergent
# hand-authored prose, not a near-duplicate that owes a drift budget at all. See the module
# docstring for the measured scores that motivate 0.90 as the cutoff.
_NEAR_DUPLICATE_RATIO = 0.90

# (plugin, stem) -> maximum +/- line count in the unified diff between the substitution-reduced
# opencode copy and the agy copy. Recorded high-water marks, not targets -- see module
# docstring. A pair that clears _NEAR_DUPLICATE_RATIO but has no entry here defaults to budget 0
# (must reduce to exactly equal), so a brand-new near-duplicate pair is covered automatically
# without needing its own line added first.
_DRIFT_BUDGET = {
    ("imps", "imp-agency"): 0,
    ("imps", "prs"): 4,
    ("imps", "issue-mode"): 8,
}


class TestOverridePlatformDrift(unittest.TestCase):
    def setUp(self):
        self.platform_table = generate.load_json(generate.PLATFORM_TABLE_PATH)

    def _replacement_pairs(self):
        """(opencode_string, agy_string) pairs generate.py's own apply_mapping would already
        produce for the same Claude-native `find` string on each platform -- so an override
        author who typed each platform's file out by hand never needed to introduce a
        difference beyond these to stay consistent with the rest of dist/."""
        agy_map = dict(self.platform_table["agy"]["replacements"])
        oc_map = dict(self.platform_table["opencode"]["replacements"])
        pairs = []
        for find, oc_replace in oc_map.items():
            agy_replace = agy_map.get(find)
            if agy_replace is not None and agy_replace != oc_replace:
                pairs.append((oc_replace, agy_replace))
        return pairs

    def test_near_duplicate_overrides_stay_within_their_drift_budget(self):
        overrides_dir = generate.OVERRIDES_DIR
        replacement_pairs = self._replacement_pairs()
        agy_naming = self.platform_table["agy"]["command_naming"]
        oc_naming = self.platform_table["opencode"]["command_naming"]

        checked = 0
        for plugin_dir in sorted(p for p in overrides_dir.iterdir() if p.is_dir()):
            plugin = plugin_dir.name
            agy_dir = plugin_dir / "agy" / "skills"
            oc_dir = plugin_dir / "opencode" / "commands"
            if not agy_dir.is_dir() or not oc_dir.is_dir():
                continue

            commands, _skills = generate.plugin_sources(plugin)
            command_names = {path.stem for path in commands}

            for oc_file in sorted(oc_dir.glob("*.md")):
                stem = oc_file.stem
                agy_file = agy_dir / f"{stem}.md"
                if not agy_file.is_file():
                    continue  # a platform-only override -- nothing to cross-check

                oc_text = generate.read_text(oc_file)
                agy_text = generate.read_text(agy_file)

                similarity = difflib.SequenceMatcher(
                    None, oc_text.splitlines(), agy_text.splitlines()
                ).ratio()
                if similarity < _NEAR_DUPLICATE_RATIO:
                    continue  # legitimately platform-specific prose, not a near-duplicate

                pairs = list(replacement_pairs) + list(_PLATFORM_LABEL_PAIRS)
                if stem in command_names:
                    agy_name = generate.output_command_name(plugin, stem, agy_naming)
                    oc_name = generate.output_command_name(plugin, stem, oc_naming)
                    if agy_name != oc_name:
                        pairs.append((f"/{oc_name}", f"/{agy_name}"))

                reduced = oc_text
                for oc_str, agy_str in pairs:
                    reduced = reduced.replace(oc_str, agy_str)

                diff_lines = [
                    line
                    for line in difflib.unified_diff(
                        reduced.splitlines(), agy_text.splitlines(), lineterm=""
                    )
                    if (line.startswith("+") or line.startswith("-"))
                    and not line.startswith(("+++", "---"))
                ]

                checked += 1
                budget = _DRIFT_BUDGET.get((plugin, stem), 0)
                self.assertLessEqual(
                    len(diff_lines),
                    budget,
                    msg=(
                        f"\nbuild/overrides/{plugin}/{{opencode/commands,agy/skills}}/{stem}.md "
                        f"differ by {len(diff_lines)} line(s) beyond known substitutions "
                        f"(budget: {budget}):\n"
                        + "\n".join(diff_lines)
                        + "\n\nIf this is a new, necessary platform-specific difference, raise "
                        "this pair's ceiling in _DRIFT_BUDGET with a comment explaining why. If "
                        "it is not, one copy was edited without the other -- fix the stale one."
                    ),
                )

        # A vacuous pass (e.g. every override directory renamed and glob() found nothing, or
        # the ratio cutoff silently stopped matching anything) would be worse than no test at
        # all -- fail loudly instead of reporting green.
        self.assertGreater(
            checked, 0, "found no near-duplicate (>= NEAR_DUPLICATE_RATIO) override file pairs to compare"
        )


if __name__ == "__main__":
    unittest.main()
