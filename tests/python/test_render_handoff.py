#!/usr/bin/env python3
"""Unit tests for plugins/elephant-goldfish/scripts/render_handoff.py and gh_publish.py.

Stdlib unittest only. Covers the two properties that matter most for handoff.md — it must
reproduce discovery.md and spec.md *verbatim*, and it must never ship with an
unsubstituted placeholder — plus gh_publish's pure guards. No test here invokes `gh`;
network-touching paths are exercised only through --dry-run at the shell level.
"""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN = os.path.join(_HERE, "..", "..", "plugins", "elephant-goldfish")
_TEMPLATES = os.path.join(_PLUGIN, "templates")


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_PLUGIN, "scripts", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rh = _load("render_handoff", "render_handoff.py")
gp = _load("gh_publish", "gh_publish.py")


@contextlib.contextmanager
def topic(output_type="research", discovery="DISCOVERY BODY", spec="SPEC BODY", title="A Title"):
    prev = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        os.chdir(tmp)
        os.makedirs("thinking/t")
        meta = {"slug": "t", "title": title, "output_type": output_type, "github": {"mode": "none"}, "published": {}}
        with open("thinking/t/meta.json", "w") as fh:
            json.dump(meta, fh)
        if discovery is not None:
            write("thinking/t/discovery.md", discovery)
        if spec is not None:
            write("thinking/t/spec.md", spec)
        try:
            yield tmp
        finally:
            os.chdir(prev)


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def run(argv):
    buf, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        code = rh.main(argv + ["--template-dir", _TEMPLATES])
    return code, buf.getvalue(), err.getvalue()


class TestRenderPure(unittest.TestCase):
    def test_substitutes_known_placeholders(self):
        out = rh.render("a {{ONE}} b {{TWO}}", {"ONE": "1", "TWO": "2"})
        self.assertEqual(out, "a 1 b 2")

    def test_unknown_placeholder_is_an_error(self):
        with self.assertRaises(rh.RenderError):
            rh.render("{{NOPE}}", {"ONE": "1"})

    def test_substituted_value_containing_placeholder_syntax_is_caught(self):
        # A discovery.md that literally contains "{{FOO}}" would otherwise smuggle an
        # unsubstituted-looking token into the brief handed to a fresh session.
        with self.assertRaises(rh.RenderError) as ctx:
            rh.render("{{BODY}}", {"BODY": "text with {{LEFTOVER}} inside"})
        self.assertIn("LEFTOVER", str(ctx.exception))


class TestRenderCLI(unittest.TestCase):
    def test_writes_handoff_with_verbatim_bodies(self):
        with topic(discovery="## Problem\n\nUNIQUE-D-STRING", spec="## Criteria\n\nUNIQUE-S-STRING"):
            code, out, _ = run(["t"])
            self.assertEqual(code, 0)
            body = read("thinking/t/handoff.md")
            self.assertIn("UNIQUE-D-STRING", body)
            self.assertIn("UNIQUE-S-STRING", body)
            self.assertIn("A Title", body)
            self.assertNotIn("{{", body)
            self.assertIn("thinking/t/handoff.md", out)

    def test_research_and_implementation_use_different_templates(self):
        with topic(output_type="research"):
            run(["t"])
            research = read("thinking/t/handoff.md")
        with topic(output_type="implementation"):
            run(["t"])
            implementation = read("thinking/t/handoff.md")
        self.assertIn("/imps:imps", implementation)
        self.assertNotIn("/imps:imps", research)
        self.assertIn("Research brief", research)

    def test_stdout_mode_writes_no_file(self):
        with topic():
            code, out, _ = run(["t", "--stdout"])
            self.assertEqual(code, 0)
            self.assertIn("DISCOVERY BODY", out)
            self.assertFalse(os.path.exists("thinking/t/handoff.md"))

    def test_missing_input_fails_closed(self):
        for missing, absent in (("discovery.md", dict(discovery=None)), ("spec.md", dict(spec=None))):
            with self.subTest(missing=missing), topic(**absent):
                code, _, err = run(["t"])
                self.assertEqual(code, 1)
                self.assertIn(missing, err)
                self.assertFalse(os.path.exists("thinking/t/handoff.md"))

    def test_empty_input_is_treated_as_missing(self):
        with topic(discovery=""):
            code, _, err = run(["t"])
            self.assertEqual(code, 1)
            self.assertIn("empty", err)

    def test_unknown_topic_and_bad_output_type(self):
        with topic():
            self.assertEqual(run(["nope"])[0], 1)
        with topic(output_type="sideways"):
            code, _, err = run(["t"])
            self.assertEqual(code, 1)
            self.assertIn("output_type", err)


class TestPublishGuards(unittest.TestCase):
    def test_body_carries_a_heading_and_the_file_contents(self):
        with topic():
            from pathlib import Path

            body = gp.body_for(Path("thinking/t/discovery.md"), "t")
            self.assertIn(gp.ARTIFACT_HEADINGS["discovery.md"], body)
            self.assertIn("DISCOVERY BODY", body)
            self.assertIn("t/discovery.md", body)

    def test_oversize_body_refuses_rather_than_truncating(self):
        # Silently clipping makes the thread look complete while missing the clipped part.
        with topic(discovery="x" * (gp.MAX_BODY + 1)):
            from pathlib import Path

            with self.assertRaises(gp.PublishError) as ctx:
                gp.body_for(Path("thinking/t/discovery.md"), "t")
            self.assertIn(str(gp.MAX_BODY), str(ctx.exception))

    def test_headings_cover_exactly_the_pipeline_artifacts(self):
        self.assertEqual(
            sorted(gp.ARTIFACT_HEADINGS), ["discovery.md", "handoff.md", "spec.md"]
        )


if __name__ == "__main__":
    unittest.main()
