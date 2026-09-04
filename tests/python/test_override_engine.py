#!/usr/bin/env python3
"""Unit coverage for build/generate.py's override engine: heading detection, section
spans, and the order in which REPLACE-SECTION/DROP-SECTION directives are applied.

Why this file exists at all: both failure modes covered here corrupt dist/ *silently*.
The generated file stays well-formed markdown, so every dist/-shaped invariant in
build/dist-lint.sh stays green, and generate.py itself reports success. One was found only
because the leaked text happened to trip an unrelated `absolute-path` lint; the other only
by hand-diffing headings between two dist/ trees. Neither would have been caught by any
check that looks at output shape rather than output *content*.

build/dist-lint.sh --self-test carries an end-to-end fixture for each (a copy of the real
generate.py with the fix seded back out, proving the probe catches a regressed generator).
This file is the complement: fine-grained cases over the individual functions, including
the boundaries the end-to-end fixtures deliberately don't poke at -- indented fences,
tilde fences, longer closing fences, info strings with attributes, and the interaction
between fence-awareness and DROP-SECTION.
"""

import sys
import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT / "build"))
import generate  # noqa: E402


def _doc(*lines: str) -> str:
    return "\n".join(lines)


def _render(body: str, replacements) -> str:
    """apply_override + restore_overrides, with no platform mapping in between.

    The real pipeline (render_markdown) runs apply_mapping between the two, but the
    mapping is deliberately a no-op over sentinels -- that is the entire reason sentinels
    exist -- so leaving it out isolates the override engine without changing its result.
    """
    override = generate.Override()
    override.replacements = list(replacements)
    swapped, held = generate.apply_override(body, override, "<test>")
    return generate.restore_overrides(swapped, held, "<test>")


class HeadingIndicesTest(unittest.TestCase):
    def test_plain_headings_at_every_level(self):
        lines = ["# One", "text", "###### Six", "####### Seven (not a heading)", "#NoSpace"]
        self.assertEqual(generate.heading_indices(lines), {0, 2})

    def test_shell_comment_in_tagged_fence_is_not_a_heading(self):
        lines = ["## Real", "```bash", "# a shell comment", "echo hi", "```", "## Also real"]
        self.assertEqual(generate.heading_indices(lines), {0, 5})

    def test_heading_in_markdown_fence_stays_a_heading(self):
        # Load-bearing: 20+ live directives in build/overrides/imps/ target headings
        # inside imps.md's fenced GOAL.md template. Masking these breaks generation
        # outright -- `heading '## Task table' not found` -- rather than silently.
        lines = ["## Outer", "```markdown", "## Inner", "body", "```", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 2, 5})

    def test_untagged_fence_stays_transparent(self):
        # An untagged fence holds no declared language, so its `## ` lines are read as
        # markdown -- matching how imps/references/checklist-mode.md and
        # imps/commands/issue-mode.md already use bare fences for markdown templates.
        lines = ["## Outer", "```", "## Inner", "```", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 2, 4})

    def test_info_string_with_attributes_is_still_a_language(self):
        lines = ["## Outer", "```bash title=run.sh", "# comment", "```", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 4})

    def test_language_match_is_case_insensitive(self):
        lines = ["## Outer", "```MarkDown", "## Inner", "```", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 2, 4})

    def test_tilde_fence_is_recognized(self):
        lines = ["## Outer", "~~~bash", "# comment", "~~~", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 4})

    def test_fence_may_be_indented_up_to_three_spaces(self):
        lines = ["## Outer", "   ```bash", "   # comment", "   ```", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 4})

    def test_four_space_indent_is_not_a_fence(self):
        # Four spaces makes it an indented code block, not a fence; the delimiter line is
        # literal content, so nothing opens and the following `# ` line is unmasked. That
        # is CommonMark's rule, and being wrong in this direction is the safe one: a
        # section ends early rather than a replacement leaking.
        lines = ["## Outer", "    ```bash", "# comment", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 2, 3})

    def test_closing_fence_may_be_longer_than_the_opener(self):
        lines = ["## Outer", "```bash", "# comment", "`````", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 4})

    def test_shorter_run_does_not_close_the_fence(self):
        # ``` cannot close a ````-opened fence, so `# still inside` stays masked and the
        # fence runs to end of input.
        lines = ["## Outer", "````bash", "```", "# still inside", "## also inside"]
        self.assertEqual(generate.heading_indices(lines), {0})

    def test_tilde_does_not_close_a_backtick_fence(self):
        lines = ["## Outer", "```bash", "~~~", "# still inside"]
        self.assertEqual(generate.heading_indices(lines), {0})

    def test_closing_fence_carries_no_info_string(self):
        # A second ```bash is not a close (info strings are illegal on a closing fence),
        # so the block is still open and `# comment` is still masked.
        lines = ["## Outer", "```bash", "echo one", "```bash", "# comment"]
        self.assertEqual(generate.heading_indices(lines), {0})

    def test_backtick_in_info_string_does_not_open_a_fence(self):
        # Per CommonMark an opening backtick fence's info string may not contain a
        # backtick -- this is prose like ``use ```bash`` here``, not a code block.
        lines = ["## Outer", "``` see `x` ```", "# comment", "## After"]
        self.assertEqual(generate.heading_indices(lines), {0, 2, 3})

    def test_unterminated_fence_masks_to_end_of_input(self):
        lines = ["## Outer", "```bash", "# comment", "## never closed"]
        self.assertEqual(generate.heading_indices(lines), {0})

    def test_empty_input(self):
        self.assertEqual(generate.heading_indices([]), set())


class FindSectionTest(unittest.TestCase):
    def test_span_runs_to_the_next_heading_of_any_level(self):
        # Pinned deliberately: find_section's docstring records that 9 live directives
        # rely on a `### Child` terminating its `## Parent`, so the child survives a
        # replace or drop of the parent. Depth-awareness here would silently swallow them.
        lines = ["## Parent", "body", "### Child", "child body", "## Sibling"]
        self.assertEqual(generate.find_section(lines, "## Parent"), (0, 2))

    def test_span_runs_to_end_of_file(self):
        lines = ["## Only", "body", "more"]
        self.assertEqual(generate.find_section(lines, "## Only"), (0, 3))

    def test_span_is_not_truncated_by_a_fenced_shell_comment(self):
        lines = ["## Alpha", "```bash", "# comment", "echo hi", "```", "tail", "## Beta"]
        self.assertEqual(generate.find_section(lines, "## Alpha"), (0, 6))

    def test_heading_inside_a_tagged_fence_is_not_a_match(self):
        # Failing to find it is the right outcome: apply_override raises a named
        # "heading not found" error, which is loud, instead of slicing at a shell comment.
        lines = ["## Real", "```bash", "## Not a heading", "```"]
        self.assertIsNone(generate.find_section(lines, "## Not a heading"))

    def test_heading_inside_a_markdown_fence_is_a_match(self):
        # The span swallows the closing ``` (a fence delimiter is not a heading, so it
        # cannot end a section). That is how imps.md's fenced GOAL.md template is
        # overridden today: the last replacement in the chain supplies the closing fence.
        lines = ["## Outer", "```markdown", "## Inner", "body", "```"]
        self.assertEqual(generate.find_section(lines, "## Inner"), (2, 5))

    def test_missing_heading_returns_none(self):
        self.assertIsNone(generate.find_section(["## A", "b"], "## Nope"))

    def test_trailing_whitespace_is_tolerated_but_a_leading_indent_is_not(self):
        # Trailing space is noise; a leading indent is not. HEADING_RE is anchored at
        # column 0 on purpose -- relaxing it to CommonMark's `^ {0,3}#` turns imps.md's
        # task-table header row " #  Task  Model  Type  Depends On" into a heading, which
        # truncates `## Task table` and leaks the Claude-side rows into dist/ (measured:
        # 12 wrong lines across the two imps outputs). Section starts follow the same rule
        # as section ends, so an indented heading is neither.
        self.assertEqual(generate.find_section(["## A  ", "b"], "## A"), (0, 2))
        self.assertIsNone(generate.find_section(["  ## A", "b"], "## A"))
        self.assertEqual(generate.heading_indices([" #  Task   Model   Type"]), set())

    def test_first_occurrence_wins(self):
        lines = ["## Dup", "first", "## Other", "## Dup", "second"]
        self.assertEqual(generate.find_section(lines, "## Dup"), (0, 2))


class ApplyOverrideTest(unittest.TestCase):
    def test_replacement_text_is_inserted_verbatim(self):
        out = _render(_doc("## A", "a body", "## B", "b body"), [("## A", "## A\nNEW", False)])
        self.assertIn("NEW", out)
        self.assertNotIn("a body", out)
        self.assertIn("b body", out)

    def test_drop_section_removes_it(self):
        out = _render(_doc("## A", "a body", "## B", "b body"), [("## A", None, False)])
        self.assertNotIn("a body", out)
        self.assertIn("b body", out)

    def test_fenced_comment_does_not_leak_the_section_tail(self):
        body = _doc(
            "## Alpha", "alpha body", "",
            "```bash", "# not-a-heading shell comment", "echo LEAKED", "```", "",
            "alpha tail", "",
            "## Beta", "beta body",
        )
        out = _render(body, [("## Alpha", "## Alpha\nREPLACED", False)])
        for gone in ("LEAKED", "alpha tail", "not-a-heading"):
            self.assertNotIn(gone, out)
        self.assertIn("REPLACED", out)
        self.assertIn("## Beta", out)

    def test_directive_order_does_not_change_the_result(self):
        # The bug this pins: a sentinel is not a heading, so replacing B before the A that
        # immediately precedes it makes A's span run past B's vanished heading and swallow
        # B's sentinel -- discarding B's replacement text with no error at all.
        body = _doc("## A", "a body", "## B", "b body", "## C", "c body")
        forward = _render(body, [("## A", "## A\nA-NEW", False), ("## B", "## B\nB-NEW", False)])
        reverse = _render(body, [("## B", "## B\nB-NEW", False), ("## A", "## A\nA-NEW", False)])
        self.assertEqual(forward, reverse)
        for needle in ("A-NEW", "B-NEW", "## C"):
            self.assertIn(needle, reverse)

    def test_reverse_ordered_drop_and_replace_agree(self):
        body = _doc("## A", "a body", "## B", "b body", "## C", "c body")
        forward = _render(body, [("## A", None, False), ("## B", "## B\nB-NEW", False)])
        reverse = _render(body, [("## B", "## B\nB-NEW", False), ("## A", None, False)])
        self.assertEqual(forward, reverse)
        self.assertNotIn("a body", reverse)
        self.assertIn("B-NEW", reverse)

    def test_three_adjacent_sections_in_any_order(self):
        body = _doc("## A", "a", "## B", "b", "## C", "c", "## D", "d")
        pairs = [("## A", "## A\nAX", False), ("## B", "## B\nBX", False), ("## C", "## C\nCX", False)]
        expected = _render(body, pairs)
        for order in ([2, 1, 0], [1, 0, 2], [0, 2, 1], [2, 0, 1]):
            self.assertEqual(_render(body, [pairs[i] for i in order]), expected)

    def test_non_adjacent_sections_are_independent_of_order(self):
        body = _doc("## A", "a", "## Mid", "m", "## B", "b")
        forward = _render(body, [("## A", "## A\nAX", False), ("## B", "## B\nBX", False)])
        reverse = _render(body, [("## B", "## B\nBX", False), ("## A", "## A\nAX", False)])
        self.assertEqual(forward, reverse)
        self.assertIn("## Mid", reverse)

    def test_missing_heading_raises_with_the_override_label_and_file(self):
        override = generate.Override()
        override.replacements = [("## Nope", "x", False)]
        with self.assertRaises(generate.GenerateError) as caught:
            generate.apply_override("## A\nbody", override, "plugins/p/commands/c.md")
        message = str(caught.exception)
        self.assertIn("## Nope", message)
        self.assertIn("plugins/p/commands/c.md", message)

    def test_missing_heading_still_raises_when_sorted_last(self):
        # source_position sends an unfindable heading to the back of the ordering; the
        # loop must still reach it and raise rather than quietly skipping it.
        override = generate.Override()
        override.replacements = [("## Nope", "x", False), ("## A", "## A\nAX", False)]
        with self.assertRaises(generate.GenerateError):
            generate.apply_override(_doc("## A", "body"), override, "<test>")


class RestoreOverridesTest(unittest.TestCase):
    def test_a_swallowed_sentinel_raises_instead_of_vanishing(self):
        # Directly simulates the pre-fix outcome: held text whose sentinel never made it
        # into the rendered output. Silently dropping it is always a bug, so this is the
        # backstop for any future path that loses a sentinel by some other route.
        with self.assertRaises(generate.GenerateError) as caught:
            generate.restore_overrides("no sentinels here", ["## B\nB-NEW"], "<test>")
        self.assertIn("vanished", str(caught.exception))
        self.assertIn("## B", str(caught.exception))

    def test_nothing_held_is_a_no_op(self):
        self.assertEqual(generate.restore_overrides("text", [], "<test>"), "text")

    def test_every_held_replacement_is_restored(self):
        text = (generate.SENTINEL_OVERRIDE % 0) + "\n" + (generate.SENTINEL_OVERRIDE % 1)
        out = generate.restore_overrides(text, ["first", "second"], "<test>")
        self.assertEqual(out, "first\nsecond")


class RealSourceTest(unittest.TestCase):
    """The shipped tree must keep satisfying the invariants above, not just fixtures."""

    def _markdown_sources(self):
        for kind in ("commands/*.md", "skills/*/SKILL.md"):
            yield from sorted((_ROOT / "plugins").glob("*/" + kind))

    def test_every_live_override_heading_resolves(self):
        # generate.py would fail loudly on a heading it cannot find, so this asserts the
        # weaker-but-independent thing: each directive resolves against the *source* file
        # under the current fence rules, and the file it names still exists.
        checked = 0
        for platform, kind in (("agy", "skills"), ("opencode", "commands")):
            for path in sorted((_ROOT / "build" / "overrides").glob("*/%s/%s/*.md" % (platform, kind))):
                plugin = path.relative_to(_ROOT / "build" / "overrides").parts[0]
                source = _ROOT / "plugins" / plugin / "commands" / path.name
                if not source.is_file():
                    source = _ROOT / "plugins" / plugin / "skills" / path.stem / "SKILL.md"
                self.assertTrue(source.is_file(), "no Claude source for %s" % path)
                _, body = generate.split_frontmatter(generate.read_text(source), str(source))
                lines = body.split("\n")
                for heading, _text, _is_subtree in generate.parse_override(path).replacements:
                    self.assertIsNotNone(
                        generate.find_section(lines, heading),
                        "%s: heading %r no longer resolves in %s" % (path.name, heading, source.name),
                    )
                    checked += 1
        self.assertGreater(checked, 0, "found no override directives to check")

    def test_no_shipped_source_has_an_unterminated_fence(self):
        # An unterminated fence masks every heading after it, which would make a whole
        # file's worth of sections untargetable. Cheap to assert, and it turns a confusing
        # "heading not found" into a pointed one.
        for path in self._markdown_sources():
            lines = generate.read_text(path).split("\n")
            fences = sum(1 for line in lines if generate.FENCE_RE.match(line) and line.strip())
            self.assertEqual(
                fences % 2, 0, "%s has an odd number of fence delimiters" % path.relative_to(_ROOT)
            )


if __name__ == "__main__":
    unittest.main()
