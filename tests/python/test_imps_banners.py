#!/usr/bin/env python3
"""Subprocess-level tests for the three imps banner scripts under
plugins/imps/scripts/: dispatch-banner.py, final-banner.py, imps-intro.py.

All three execute top-level code at import time (no `if __name__ ==
"__main__"` guard) and print directly, so they are exercised here as
subprocesses via `subprocess.run([sys.executable, <path>, ...], ...)` rather
than imported. In particular, final-banner.py reads `sys.stdin` at module
level — importing it would either block on this test process's own stdin or
raise before anything useful is bound, so its `italic()` helper is
reimplemented verbatim below instead of imported.

dispatch-banner.py reads its state file from a hardcoded, non-overridable
path (`os.path.expanduser(f'~/.claude/imps/runs/{slug}.json')` — there is no
env/argument override for the path itself, only for the slug component).
Every subprocess invocation of that script in this file pins `HOME` to a
tempdir via an explicit `env=`, and fixture state files are written under
`<tempdir>/.claude/imps/runs/<slug>.json` — never under the real
`~/.claude/imps/runs/`.

Python's own uncaught-traceback coloring (PEP 657-adjacent, active in
3.13+) can vary between environments (e.g. is on locally when FORCE_COLOR is
set, off on plain CI) independently of the scripts' own `sys.stdout.isatty()`
color gating, so ANSI is stripped before every stdout/stderr substring
assertion in this file for consistency.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS_DIR = os.path.join(_HERE, "..", "..", "plugins", "imps", "scripts")
_DISPATCH_BANNER = os.path.join(_SCRIPTS_DIR, "dispatch-banner.py")
_FINAL_BANNER = os.path.join(_SCRIPTS_DIR, "final-banner.py")
_IMPS_INTRO = os.path.join(_SCRIPTS_DIR, "imps-intro.py")

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text):
    return _ANSI_RE.sub("", text)


# --- italic() reimplementation, copied verbatim from final-banner.py -------
# NOT imported: final-banner.py reads sys.stdin at module level, so importing
# it would block/raise. cap_spec/low_spec and the 0x1D434/0x1D44E base
# offsets are copied exactly (both dicts special-case a handful of letters
# whose Unicode mathematical-italic codepoints aren't in the uniform range).
_CAP_SPEC = {
    "H": 0x210B, "I": 0x2110, "L": 0x2112, "R": 0x211B,
    "B": 0x212C, "E": 0x2130, "F": 0x2131, "M": 0x2133,
}
_LOW_SPEC = {"e": 0x212F, "g": 0x210A, "h": 0x210E, "o": 0x2134}


def _italic(s):
    out = []
    for c in s:
        if "A" <= c <= "Z":
            out.append(chr(_CAP_SPEC.get(c, 0x1D434 + ord(c) - ord("A"))))
        elif "a" <= c <= "z":
            out.append(chr(_LOW_SPEC.get(c, 0x1D44E + ord(c) - ord("a"))))
        else:
            out.append(c)
    return "".join(out)


class DispatchBannerTest(unittest.TestCase):
    """dispatch-banner.py — always invoked with HOME pinned to a tempdir."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.runs_dir = os.path.join(self.home, ".claude", "imps", "runs")
        os.makedirs(self.runs_dir)

    def tearDown(self):
        self.tmp.cleanup()

    def _write_state(self, slug, tasks):
        path = os.path.join(self.runs_dir, f"{slug}.json")
        with open(path, "w") as f:
            json.dump({"tasks": tasks}, f)
        return path

    def _run(self, args, env_extra=None, cwd=None):
        env = dict(os.environ)
        env["HOME"] = self.home
        env.pop("SLUG", None)
        env.pop("CLAUDE_PROJECT_DIR", None)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            [sys.executable, _DISPATCH_BANNER] + args,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )

    _MIXED_TASKS = [
        {"id": 1, "label": "opus task", "model": "claude-opus-4", "type": "code", "deps": []},
        {
            "id": 2,
            "label": "sonnet task",
            "model": "claude-sonnet-4",
            "type": "query",
            "deps": [1],
        },
        {"id": 3, "label": "haiku task", "model": "claude-haiku-4", "type": "code", "deps": []},
    ]

    def test_imp_count_line_and_per_imp_formatting(self):
        self._write_state("myslug", self._MIXED_TASKS)
        result = self._run(["myslug"])
        self.assertEqual(result.returncode, 0)
        out = _strip_ansi(result.stdout)
        self.assertIn("3 imps handed to the wrangler", out)
        self.assertIn("#1  opus task  [opus · code]", out)
        self.assertIn("#3  haiku task  [haiku · code]", out)

    def test_deps_render_waits_when_present(self):
        self._write_state("myslug", self._MIXED_TASKS)
        result = self._run(["myslug"])
        out = _strip_ansi(result.stdout)
        self.assertIn("#2  sonnet task  [sonnet · query  waits: #1]", out)

    def test_deps_omit_waits_when_absent(self):
        self._write_state("myslug", self._MIXED_TASKS)
        result = self._run(["myslug"])
        out = _strip_ansi(result.stdout)
        # task #1 and #3 have no deps: no "waits:" text on their lines
        for line in out.splitlines():
            if "#1  opus task" in line or "#3  haiku task" in line:
                self.assertNotIn("waits:", line)

    def test_slug_precedence_argv_beats_slug_env(self):
        self._write_state("slugA", [self._MIXED_TASKS[0]])
        self._write_state("slugB", self._MIXED_TASKS[:2])
        result = self._run(["slugA"], env_extra={"SLUG": "slugB"})
        self.assertEqual(result.returncode, 0)
        self.assertIn("1 imps handed to the wrangler", _strip_ansi(result.stdout))

    def test_slug_precedence_env_used_without_argv(self):
        self._write_state("slugB", self._MIXED_TASKS[:2])
        result = self._run([], env_extra={"SLUG": "slugB"})
        self.assertEqual(result.returncode, 0)
        self.assertIn("2 imps handed to the wrangler", _strip_ansi(result.stdout))

    def test_slug_precedence_claude_project_dir_fallback(self):
        self._write_state("myproj", self._MIXED_TASKS)
        result = self._run([], env_extra={"CLAUDE_PROJECT_DIR": "/some/path/myproj"})
        self.assertEqual(result.returncode, 0)
        self.assertIn("3 imps handed to the wrangler", _strip_ansi(result.stdout))

    def test_slug_precedence_cwd_fallback(self):
        self._write_state("cwdname", self._MIXED_TASKS[:1] * 4)
        cwd_dir = os.path.join(self.home, "cwdname")
        os.makedirs(cwd_dir)
        result = self._run([], cwd=cwd_dir)
        self.assertEqual(result.returncode, 0)
        self.assertIn("4 imps handed to the wrangler", _strip_ansi(result.stdout))

    def test_missing_state_file(self):
        result = self._run(["nosuchslug"])
        self.assertNotEqual(result.returncode, 0)
        err = _strip_ansi(result.stderr)
        self.assertIn("FileNotFoundError", err)
        self.assertIn("nosuchslug.json", err)

    def test_malformed_json_state_file(self):
        path = os.path.join(self.runs_dir, "bad.json")
        with open(path, "w") as f:
            f.write("not json")
        result = self._run(["bad"])
        self.assertNotEqual(result.returncode, 0)
        err = _strip_ansi(result.stderr)
        self.assertIn("JSONDecodeError", err)


class FinalBannerTest(unittest.TestCase):
    """final-banner.py — reads its JSON checkpoint from stdin."""

    def _run(self, payload_obj):
        return subprocess.run(
            [sys.executable, _FINAL_BANNER],
            input=json.dumps(payload_obj),
            capture_output=True,
            text=True,
        )

    def test_pluralization_multiple_imps(self):
        payload = {"run_stats": {"tasks": [
            {"id": 1, "model": "opus"},
            {"id": 2, "model": "sonnet"},
            {"id": 3, "model": "haiku"},
        ]}}
        result = self._run(payload)
        self.assertEqual(result.returncode, 0)
        out = _strip_ansi(result.stdout)
        self.assertIn(_italic("all 3 imps back"), out)

    def test_pluralization_singular_imp(self):
        payload = {"run_stats": {"tasks": [{"id": 1, "model": "haiku"}]}}
        result = self._run(payload)
        self.assertEqual(result.returncode, 0)
        out = _strip_ansi(result.stdout)
        self.assertIn(_italic("all 1 imp back"), out)
        self.assertNotIn(_italic("all 1 imps back"), out)

    def test_model_counts_fallback_when_no_tasks(self):
        payload = {"run_stats": {"model_counts": {"haiku": 1, "sonnet": 2, "opus": 0}}}
        result = self._run(payload)
        self.assertEqual(result.returncode, 0)
        out = _strip_ansi(result.stdout)
        # 1 haiku + 2 sonnet + 0 opus = 3 synthesized tasks
        self.assertIn(_italic("all 3 imps back"), out)


class ImpsIntroTest(unittest.TestCase):
    """imps-intro.py — fixed cosmetic banner, no meaningful input."""

    def test_smoke_output_well_formed(self):
        result = subprocess.run(
            [sys.executable, _IMPS_INTRO],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        out = _strip_ansi(result.stdout)
        self.assertTrue(out.strip())
        self.assertIn("Summoning the implementation imps", out)
        self.assertIn("\U000F0B5F", out)  # bat glyph, printed 6 times
        self.assertIn("♜", out)  # tower


if __name__ == "__main__":
    unittest.main()
