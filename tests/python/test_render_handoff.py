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
from unittest import mock

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

    def test_unknown_placeholder_in_the_template_is_an_error(self):
        # The real guard: a typo in a template we ship would otherwise leave a literal
        # {{SPEC}} in the plan, and the session downstream can't know what was lost.
        with self.assertRaises(rh.RenderError) as ctx:
            rh.render("{{NOPE}}", {"ONE": "1"})
        self.assertIn("NOPE", str(ctx.exception))

    def test_braces_in_substituted_content_pass_through_verbatim(self):
        # Regression: the check used to run against the rendered output, so any {{FOO}}
        # inside the user's own discovery.md — a Mustache snippet, an {{API_KEY}} note, or
        # notes about this plugin's own templates — aborted the render of a document whose
        # whole job is to reproduce those files verbatim.
        out = rh.render("{{BODY}}", {"BODY": "text with {{LEFTOVER}} inside"})
        self.assertEqual(out, "text with {{LEFTOVER}} inside")

    def test_substituted_content_is_not_rescanned_for_substitution(self):
        # {{SPEC}} arriving via discovery.md must stay literal, not pick up the real spec.
        out = rh.render(
            "{{DISCOVERY}}|{{SPEC}}", {"DISCOVERY": "see {{SPEC}}", "SPEC": "REAL"}
        )
        self.assertEqual(out, "see {{SPEC}}|REAL")

    def test_backslashes_in_content_are_not_treated_as_escapes(self):
        # re.sub only processes \g<> style escapes for string replacements, not callables.
        out = rh.render("{{BODY}}", {"BODY": r"C:\path \g<0> \1"})
        self.assertEqual(out, r"C:\path \g<0> \1")


class TestRenderCLIWithBraceContent(unittest.TestCase):
    def test_end_to_end_render_survives_template_syntax_in_the_documents(self):
        with topic(
            discovery="Deploy uses `{{API_KEY}}` and a Mustache block `{{USER_ID}}`.",
            spec="Reject any doc that hardcodes `{{TOKEN}}`.",
        ):
            code, _, err = run(["t"])
            self.assertEqual(code, 0, err)
            body = read("thinking/t/handoff.md")
            for token in ("{{API_KEY}}", "{{USER_ID}}", "{{TOKEN}}"):
                self.assertIn(token, body)


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

    def test_issue_url_is_found_even_with_extra_stdout(self):
        # `gh` writes advisories to stdout alongside the URL; treating all of stdout as the
        # URL made int() raise ValueError on whatever the last path segment happened to be.
        noisy = (
            "A new release of gh is available: 2.40.0 -> 2.41.0\n"
            "https://github.com/o/n/issues/42\n"
        )
        match = gp.ISSUE_URL_RE.search(noisy)
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), 42)
        self.assertEqual(match.group(0), "https://github.com/o/n/issues/42")

    def test_no_issue_url_is_detectable_rather_than_a_crash(self):
        self.assertIsNone(gp.ISSUE_URL_RE.search("could not create issue"))


class TestGraphQLErrorHandling(unittest.TestCase):
    def test_dig_names_the_missing_hop(self):
        with self.assertRaises(gp.PublishError) as ctx:
            gp.dig({"data": {"createDiscussion": None}}, "data", "createDiscussion", "discussion")
        self.assertIn("data.createDiscussion", str(ctx.exception))

    def test_dig_returns_the_leaf_when_present(self):
        self.assertEqual(gp.dig({"a": {"b": {"c": 7}}}, "a", "b", "c"), 7)

    def test_graphql_errors_array_surfaces_githubs_message(self):
        # GitHub answers "Discussions disabled" and friends with HTTP 200 + an errors array,
        # so exit status alone is not evidence of success.
        payload = json.dumps({"data": None, "errors": [{"message": "Discussions are disabled"}]})
        with mock.patch.object(gp, "run", return_value=payload):
            with self.assertRaises(gp.PublishError) as ctx:
                gp.graphql("query{x}")
        self.assertIn("Discussions are disabled", str(ctx.exception))

    def test_graphql_rejects_a_payload_with_no_data_object(self):
        with mock.patch.object(gp, "run", return_value=json.dumps({"unexpected": True})):
            with self.assertRaises(gp.PublishError):
                gp.graphql("query{x}")

    def test_graphql_passes_a_healthy_payload_through(self):
        payload = json.dumps({"data": {"repository": {"id": "R_1"}}})
        with mock.patch.object(gp, "run", return_value=payload):
            self.assertEqual(gp.graphql("query{x}")["data"]["repository"]["id"], "R_1")


if __name__ == "__main__":
    unittest.main()
