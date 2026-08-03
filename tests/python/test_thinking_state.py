#!/usr/bin/env python3
"""Unit tests for plugins/elephant-goldfish/scripts/thinking_state.py.

Stdlib unittest only — no pytest, no new dependencies. Every test runs inside a tempdir
that is also the process CWD, because `find_legacy` inspects Path.cwd() and `--root` is
relative by default; a test that forgot to chdir would otherwise scribble a `thinking/`
directory into the repo.

The module is loaded by file path — its directory, "elephant-goldfish", has a hyphen and
isn't an importable package name. Same pattern as test_scan_perms.py.
"""

import argparse
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT_PATH = os.path.join(
    _HERE, "..", "..", "plugins", "elephant-goldfish", "scripts", "thinking_state.py"
)


def _load_module():
    spec = importlib.util.spec_from_file_location("thinking_state", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ts = _load_module()


@contextlib.contextmanager
def sandbox():
    """A tempdir that is also CWD for the duration."""
    prev = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        os.chdir(tmp)
        try:
            yield tmp
        finally:
            os.chdir(prev)


def write(path, text):
    """Write and close. Bare open().write() leaks a handle and warns under -W default."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def run(argv):
    """Invoke main() and return (exit_code, parsed_stdout_or_None)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = ts.main(argv)
    raw = buf.getvalue().strip()
    try:
        return code, json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return code, None


class TestSlugValidation(unittest.TestCase):
    def test_accepts_kebab_case(self):
        for slug in ("a", "buy-family-car", "q3-vendor-report", "abc123"):
            self.assertEqual(ts.validate_slug(slug), slug)

    def test_rejects_traversal_and_separators(self):
        # These are the ones that matter: the slug becomes a directory name and is passed
        # to `gh` downstream, so a traversal must fail loudly rather than be sanitized.
        for slug in ("../escape", "a/b", "..", "./x", "a b"):
            with self.assertRaises(ts.StateError, msg=slug):
                ts.validate_slug(slug)

    def test_rejects_shape_violations(self):
        for slug in ("", "-leading", "trailing-", "Upper", "under_score", "x" * 64):
            with self.assertRaises(ts.StateError, msg=slug):
                ts.validate_slug(slug)

    def test_rejects_subcommand_names_as_slugs(self):
        # A topic named `list` makes the command's bare $ARGUMENTS undecidable — is it the
        # list subcommand or the topic? Reserve the names so it can't be created.
        for slug in sorted(ts.RESERVED_SLUGS):
            with self.assertRaises(ts.StateError, msg=slug) as ctx:
                ts.validate_slug(slug)
            self.assertIn("reserved", str(ctx.exception))

    def test_reserved_set_matches_the_actual_subcommands(self):
        # If a subcommand is added without updating RESERVED_SLUGS the collision returns.
        parser = ts.build_parser()
        subcommands = set()
        for action in parser._actions:
            if isinstance(action, argparse._SubParsersAction):
                subcommands = set(action.choices)
        self.assertEqual(subcommands, set(ts.RESERVED_SLUGS))


class TestInit(unittest.TestCase):
    def test_creates_meta_with_expected_shape(self):
        with sandbox():
            code, out = run(["init", "topic-one", "--output-type", "research", "--github", "issue"])
            self.assertEqual(code, 0)
            self.assertEqual(out["meta"]["output_type"], "research")
            self.assertEqual(out["meta"]["github"]["mode"], "issue")
            self.assertEqual(out["meta"]["published"], {})
            self.assertEqual(out["next_phase"], "discovery")
            self.assertTrue(os.path.exists("thinking/topic-one/meta.json"))

    def test_title_defaults_to_despaced_slug(self):
        with sandbox():
            _, out = run(["init", "buy-family-car", "--output-type", "research"])
            self.assertEqual(out["meta"]["title"], "buy family car")

    def test_github_defaults_to_none(self):
        with sandbox():
            _, out = run(["init", "topic-one", "--output-type", "research"])
            self.assertEqual(out["meta"]["github"]["mode"], "none")

    def test_reinit_refuses_rather_than_resetting(self):
        # Re-running init on a live topic must not wipe output_type or the published map;
        # resume goes through `resolve`, not `init`.
        with sandbox():
            run(["init", "topic-one", "--output-type", "research"])
            code, out = run(["init", "topic-one", "--output-type", "implementation"])
            self.assertEqual(code, 1)
            self.assertIn("already initialised", out["error"])
            with open("thinking/topic-one/meta.json") as fh:
                meta = json.load(fh)
            self.assertEqual(meta["output_type"], "research")

    def test_invalid_slug_writes_no_directory(self):
        with sandbox():
            code, out = run(["init", "../escape", "--output-type", "research"])
            self.assertEqual(code, 1)
            self.assertIn("invalid slug", out["error"])
            self.assertFalse(os.path.exists("thinking"))


class TestPhaseProgression(unittest.TestCase):
    def _topic(self):
        run(["init", "t", "--output-type", "research"])

    def test_walks_discovery_spec_handoff_complete(self):
        with sandbox():
            self._topic()
            self.assertEqual(run(["resolve", "t"])[1]["next_phase"], "discovery")
            write("thinking/t/discovery.md", "d")
            self.assertEqual(run(["resolve", "t"])[1]["next_phase"], "spec")
            write("thinking/t/spec.md", "s")
            self.assertEqual(run(["resolve", "t"])[1]["next_phase"], "handoff")
            write("thinking/t/handoff.md", "h")
            self.assertEqual(run(["resolve", "t"])[1]["next_phase"], "complete")

    def test_reports_only_the_three_pipeline_artifacts(self):
        # handoff.md is the output of the process; nothing else is tracked. A stray
        # artifact name creeping back into ARTIFACTS would silently add a phase.
        with sandbox():
            self._topic()
            for name in ("discovery.md", "spec.md", "handoff.md"):
                write(f"thinking/t/{name}", "x")
            out = run(["resolve", "t"])[1]
            self.assertEqual(out["next_phase"], "complete")
            self.assertEqual(
                sorted(out["artifacts"]), ["discovery.md", "handoff.md", "spec.md"]
            )


class TestPublishTracking(unittest.TestCase):
    def test_published_flag_follows_content_not_existence(self):
        # An edited artifact must re-flag as unpublished, otherwise a corrected brief
        # would silently never reach the GitHub thread. The published map is written
        # directly here because gh_publish.py owns it — see the `set` guard below.
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            write("thinking/t/discovery.md", "first")
            digest = run(["resolve", "t"])[1]["artifacts"]["discovery.md"]["sha256"]
            self.assertFalse(run(["resolve", "t"])[1]["artifacts"]["discovery.md"]["published"])

            with open("thinking/t/meta.json") as fh:
                meta = json.load(fh)
            meta["published"]["discovery.md"] = digest
            write("thinking/t/meta.json", json.dumps(meta))
            self.assertTrue(run(["resolve", "t"])[1]["artifacts"]["discovery.md"]["published"])

            write("thinking/t/discovery.md", "edited")
            self.assertFalse(run(["resolve", "t"])[1]["artifacts"]["discovery.md"]["published"])

    def test_set_refuses_the_published_prefix(self):
        # Dotted-key nesting cannot address filenames. Silently mis-nesting here would
        # make every publish check false forever, with nothing reporting it.
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            for key in ("published", "published.discovery.md"):
                code, out = run(["set", "t", f"{key}=abc"])
                self.assertEqual(code, 1, msg=key)
                self.assertIn("gh_publish.py", out["error"])


class TestSet(unittest.TestCase):
    def test_dotted_keys_and_json_coercion(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            code, out = run(["set", "t", "github.number=42", "github.repo=o/n", "github.url=null"])
            self.assertEqual(code, 0)
            self.assertEqual(out["meta"]["github"]["number"], 42)
            self.assertEqual(out["meta"]["github"]["repo"], "o/n")
            self.assertIsNone(out["meta"]["github"]["url"])

    def test_rejects_pair_without_equals(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            code, out = run(["set", "t", "novalue"])
            self.assertEqual(code, 1)
            self.assertIn("KEY=VALUE", out["error"])

    def test_set_on_unknown_topic_refuses(self):
        with sandbox():
            code, out = run(["set", "nope", "a=b"])
            self.assertEqual(code, 1)
            self.assertIn("no topic", out["error"])


class TestGate(unittest.TestCase):
    def test_fails_closed_and_names_every_missing_artifact(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            code, out = run(["gate", "t", "--require", "discovery,spec"])
            self.assertEqual(code, 1)
            self.assertIn("discovery.md", out["error"])
            self.assertIn("spec.md", out["error"])

    def test_passes_when_all_present(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            write("thinking/t/discovery.md", "d")
            write("thinking/t/spec.md", "s")
            code, out = run(["gate", "t", "--require", "discovery,spec"])
            self.assertEqual(code, 0)
            self.assertEqual(out["gate"], "pass")

    def test_empty_and_whitespace_only_artifacts_do_not_pass(self):
        # A 0-byte discovery.md is an interrupted phase, not a completed one. Letting it
        # through moves the failure to render_handoff.py, after the gate said "pass".
        for content in ("", "   \n\t\n"):
            with self.subTest(content=repr(content)), sandbox():
                run(["init", "t", "--output-type", "research"])
                write("thinking/t/discovery.md", content)
                write("thinking/t/spec.md", "s")
                code, out = run(["gate", "t", "--require", "discovery,spec"])
                self.assertEqual(code, 1)
                self.assertIn("empty", out["error"])
                self.assertIn("discovery.md", out["error"])

    def test_reports_missing_and_empty_separately(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            write("thinking/t/discovery.md", "")
            code, out = run(["gate", "t", "--require", "discovery,spec"])
            self.assertEqual(code, 1)
            self.assertIn("missing: spec.md", out["error"])
            self.assertIn("empty: discovery.md", out["error"])

    def test_accepts_names_with_or_without_extension(self):
        with sandbox():
            run(["init", "t", "--output-type", "research"])
            write("thinking/t/discovery.md", "d")
            self.assertEqual(run(["gate", "t", "--require", "discovery.md"])[0], 0)
            self.assertEqual(run(["gate", "t", "--require", "discovery"])[0], 0)


class TestListAndLegacy(unittest.TestCase):
    def test_list_on_empty_root(self):
        with sandbox():
            code, out = run(["list"])
            self.assertEqual(code, 0)
            self.assertEqual(out["topics"], [])

    def test_list_reports_phase_per_topic(self):
        with sandbox():
            run(["init", "aaa", "--output-type", "research"])
            run(["init", "bbb", "--output-type", "implementation"])
            write("thinking/bbb/discovery.md", "d")
            topics = {t["slug"]: t for t in run(["list"])[1]["topics"]}
            self.assertEqual(topics["aaa"]["next_phase"], "discovery")
            self.assertEqual(topics["bbb"]["next_phase"], "spec")
            self.assertEqual(topics["bbb"]["output_type"], "implementation")

    def test_corrupt_meta_reports_rather_than_crashing(self):
        with sandbox():
            os.makedirs("thinking/t")
            write("thinking/t/meta.json", "{not json")
            code, out = run(["resolve", "t"])
            self.assertEqual(code, 1)
            self.assertIn("not valid JSON", out["error"])


if __name__ == "__main__":
    unittest.main()
