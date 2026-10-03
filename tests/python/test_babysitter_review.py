"""Real shell adapter with local git and scripted reviewer output; no API calls."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / 'plugins/babysitter/scripts/ocr-gate.sh'

# Everything the gate (and its helpers) execute. Linked into a private PATH so the host's own
# `ocr` / `ocr-pre-pr.sh` can never leak into a fixture.
HOST_TOOLS = ('bash', 'sh', 'env', 'git', 'jq', 'python3', 'sed', 'awk', 'grep', 'dirname',
              'mktemp', 'head', 'cat', 'sleep', 'rm', 'date', 'tr', 'wc', 'basename', 'uname')

# `ocr review` bodies (run by a /bin/sh stub), one per way an LLM gateway fails.
FAILED_RESULT = json.dumps({
    'status': 'failed', 'comments': None,
    'message': 'Review failed: 0 finding(s); 1 of 1 selected item(s) failed.',
    'manifest': {'terminal_state': 'failed',
                 'coverage': {'failed': [{'path': 'code', 'classification': 'provider'}]}}})
REFUSED = ("echo 'Error: Post \"http://127.0.0.1:1/v1/chat/completions\": dial tcp 127.0.0.1:1: "
           "connect: connection refused' >&2\nexit 1")
HTTP_5XX = "echo 'Error: LLM request failed: 502 Bad Gateway' >&2\nprintf '%s\\n' '" + FAILED_RESULT + "'\nexit 1"
TLS_REJECTED = ("echo 'Post \"https://gateway.invalid/v1\": tls: failed to verify certificate: "
                "x509: OSStatus -26276' >&2\nexit 1")
HUNG = 'sleep 30'
TRUNCATED = "printf '%s' '{\"comments\": [{\"body\": \"defe'"
EMPTY_OUTPUT = 'exit 0'
EXIT_ZERO_FAILED = "printf '%s\\n' '" + json.dumps({'status': 'failed', 'comments': []}) + "'"
GATEWAY_FAILURES = (
    ('connection refused', REFUSED, {}),
    ('http 5xx', HTTP_5XX, {}),
    ('tls rejected', TLS_REJECTED, {}),
    ('timeout', HUNG, {'BABYSITTER_REVIEW_TIMEOUT': '1'}),
    ('truncated output', TRUNCATED, {}),
    ('empty output', EMPTY_OUTPUT, {}),
    ('failed status with exit 0', EXIT_ZERO_FAILED, {}),
)

# Exit 0 and a well-formed `comments` array, but files the run never reviewed.
PARTIAL_REVIEWS = (
    ('files failed', "printf '%s\\n' '" + json.dumps({
        'comments': [], 'manifest': {'terminal_state': 'partial',
                                      'coverage': {'failed': [{'path': 'code'}]}}}) + "'"),
    ('terminal state failed', "printf '%s\\n' '" + json.dumps({
        'comments': [], 'manifest': {'terminal_state': 'failed'}}) + "'"),
)

# `ocr delegate preview` bodies.
DELEGATE_OK = "printf '%s\\n' '{\"files\": [\"code\"], \"rules\": []}'"
DELEGATE_FAILS = "echo 'delegate failed' >&2\nexit 1"
DELEGATE_EMPTY = 'exit 0'

class BabysitterReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'code').write_text('base')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        subprocess.run(['git', 'clone', '--bare', '-q', str(self.repo), str(self.root / 'remote')], check=True)
        self.git('remote', 'add', 'origin', str(self.root / 'remote'))
        self.git('checkout', '-qb', 'change')
        (self.repo / 'code').write_text('change')
        self.git('commit', '-qam', 'change')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'IMPS_CODEX_PLUGIN_ROOT': str(self.root / 'missing'),
                    'IMPS_CLAUDE_PLUGINS_MANIFEST': str(self.root / 'missing.json')}
        # Keep a machine's installed custom wrapper from affecting these fixtures.
        wrapper = self.bin / 'ocr-pre-pr.sh'
        wrapper.write_text('#!/bin/sh\nocr review > "$OCR_RESULT_PATH"\n')
        wrapper.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE).decode().strip()

    def run_gate(self, payload, code=0, mutate=False):
        stub = self.bin / 'ocr'
        stub.write_text('#!/bin/sh\n[ "$1" = review ] || exit 1\n' +
                        ('printf changed-again > code\n' if mutate else '') +
                        "printf '%s\\n' '" + json.dumps(payload) + "'\nexit " + str(code) + '\n')
        stub.chmod(0o755)
        return subprocess.run(['bash', str(GATE), '--base', 'main'], cwd=self.repo, env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_valid_clean_binds_head_and_base(self):
        result = self.run_gate({'comments': []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('status=clean', result.stdout)
        self.assertIn('head=' + self.git('rev-parse', 'HEAD'), result.stdout)

    def test_missing_comments_is_not_clean(self):
        result = self.run_gate({})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('status=clean', result.stdout)

    def test_success_with_findings_stays_adverse(self):
        result = self.run_gate({'comments': [{'body': 'defect'}]})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('status=findings', result.stdout)

    def test_mutation_blocks_review(self):
        result = self.run_gate({'comments': []}, mutate=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('status=clean', result.stdout)

    def test_cached_base_is_explicit_when_refresh_fails(self):
        self.git('fetch', '-q', 'origin', 'main')
        self.git('remote', 'set-url', 'origin', str(self.root / 'unavailable'))
        result = self.run_gate({'comments': []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('base_fresh=false', result.stdout)
        self.assertIn('cached base', result.stderr)

    # --- review service unreachable or unhealthy ------------------------------------
    # The gate must fail closed: no outcome here may be exit 0 or status=clean. Each case
    # is a failure `ocr` reports (or fails to report) when its LLM gateway misbehaves, and
    # is run through both selection paths — the `ocr review` CLI and a user wrapper.

    def run_stubbed(self, review, delegate=DELEGATE_OK, wrapper=None, with_ocr=True, **env):
        """Run the gate with a scripted `ocr` on a PATH that holds nothing else of the host's.

        `wrapper` is the body of an ocr-pre-pr.sh stub, or None for no wrapper at all (so a
        wrapper installed on the machine running the tests cannot change which path is taken).
        """
        bin_dir = self.root / 'stubbed-bin'
        tools = self.root / 'tools'
        bin_dir.mkdir(exist_ok=True)
        tools.mkdir(exist_ok=True)
        for stale in bin_dir.iterdir():
            stale.unlink()
        for name in HOST_TOOLS:
            found = shutil.which(name)
            if found and not (tools / name).exists():
                (tools / name).symlink_to(found)
        if with_ocr:
            self.stub(bin_dir / 'ocr', 'case "$1" in\nreview)\n' + review + '\n;;\ndelegate)\n' + delegate + '\n;;\n*) exit 1;;\nesac')
        if wrapper is not None:
            self.stub(bin_dir / 'ocr-pre-pr.sh', wrapper)
        path = os.pathsep.join([str(bin_dir), str(tools)])
        return subprocess.run(['bash', str(GATE), '--base', 'main'], cwd=self.repo,
                              env={**self.env, 'PATH': path, **env},
                              capture_output=True, text=True, timeout=30)

    @staticmethod
    def stub(path, body):
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def assert_blocked(self, result, code):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertNotIn('status=clean', result.stdout)
        self.assertNotIn('status=skipped', result.stdout)

    def assert_delegated(self, result):
        self.assert_blocked(result, 3)
        self.assertIn('status=delegate', result.stdout)
        self.assertIn('review it yourself before pushing', result.stderr)
        spec = re.search(r'result=(\S+)', result.stdout).group(1)
        self.assertGreater(os.path.getsize(spec), 0)

    def test_gateway_failures_delegate_instead_of_passing(self):
        for name, review, env in GATEWAY_FAILURES:
            with self.subTest(name):
                self.assert_delegated(self.run_stubbed(review, **env))

    def test_gateway_failures_through_wrapper_delegate_instead_of_passing(self):
        # A wrapper reports "could not run" as exit 2 (the contract the gate documents).
        wrapper = 'ocr review > "$OCR_RESULT_PATH" || exit 2'
        for name, review, env in GATEWAY_FAILURES:
            with self.subTest(name):
                self.assert_delegated(self.run_stubbed(review, wrapper=wrapper, **env))

    def test_gateway_failure_with_failing_delegate_is_an_error(self):
        cases = [(DELEGATE_FAILS, *case) for case in GATEWAY_FAILURES] + [(DELEGATE_EMPTY, *GATEWAY_FAILURES[0])]
        for delegate, name, review, env in cases:
            with self.subTest(delegate=delegate, failure=name):
                result = self.run_stubbed(review, delegate=delegate, **env)
                self.assert_blocked(result, 2)
                self.assertIn('status=error', result.stdout)
                self.assertIn('ocr delegate also failed', result.stderr)

    def test_failing_wrapper_without_ocr_is_an_error(self):
        result = self.run_stubbed('exit 1', wrapper='echo gateway down >&2; exit 2', with_ocr=False)
        self.assert_blocked(result, 2)
        self.assertIn('status=error', result.stdout)

    def test_wrapper_that_propagates_a_gateway_failure_is_never_clean(self):
        # The default stub wrapper hands ocr's own exit status straight back.
        result = self.run_stubbed(REFUSED, wrapper='ocr review > "$OCR_RESULT_PATH"')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('status=clean', result.stdout)

    def test_wrapper_success_with_garbage_result_is_never_clean(self):
        wrapper = 'echo "<html>502</html>" > "$OCR_RESULT_PATH"'
        self.assert_delegated(self.run_stubbed('exit 1', wrapper=wrapper))
        errored = self.run_stubbed('exit 1', wrapper=wrapper, with_ocr=False)
        self.assert_blocked(errored, 2)
        self.assertIn('status=error', errored.stdout)

    def test_tls_failure_names_the_environment_not_the_diff(self):
        result = self.run_stubbed(TLS_REJECTED)
        self.assert_delegated(result)
        self.assertIn('TLS trust failure', result.stderr)
        self.assertIn('not a problem with the diff', result.stderr)

    def test_partial_review_is_not_clean(self):
        # ocr publishes partial results and exits 0 when only some files failed.
        for name, review in PARTIAL_REVIEWS:
            for wrapper in (None, 'ocr review > "$OCR_RESULT_PATH"'):
                with self.subTest(name, wrapper=wrapper is not None):
                    result = self.run_stubbed(review, wrapper=wrapper)
                    self.assert_delegated(result)
                    self.assertIn('incomplete review', result.stderr)

    def test_complete_coverage_is_still_clean(self):
        # Guards the check above from rejecting a real, finished review.
        review = "printf '%s\\n' '" + json.dumps({
            'status': 'completed', 'comments': [],
            'manifest': {'terminal_state': 'completed', 'coverage': {'failed': [], 'waived': [{'path': 'x'}]}}}) + "'"
        for wrapper in (None, 'ocr review > "$OCR_RESULT_PATH"'):
            with self.subTest(wrapper=wrapper is not None):
                result = self.run_stubbed(review, wrapper=wrapper)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('status=clean', result.stdout)

    def test_findings_survive_partial_coverage(self):
        review = "printf '%s\\n' '" + json.dumps({
            'comments': [{'body': 'defect'}],
            'manifest': {'coverage': {'failed': [{'path': 'other'}]}}}) + "'"
        result = self.run_stubbed(review)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('status=findings', result.stdout)

    def test_missing_tooling_is_skipped_unless_required(self):
        result = self.run_stubbed('exit 1', with_ocr=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('status=skipped', result.stdout)
        self.assertIn('skipped', result.stderr)
        required = self.run_stubbed('exit 1', with_ocr=False, BABYSITTER_REVIEW_REQUIRED='1')
        self.assertEqual(required.returncode, 2, required.stdout + required.stderr)
        self.assertNotIn('status=clean', required.stdout)

    def test_no_environment_switch_turns_a_failed_gate_into_a_pass(self):
        # The gate has no waiver. Setting every plausible bypass must not change the outcome.
        bypass = {'BABYSITTER_REVIEW_REQUIRED': '0', 'BABYSITTER_SKIP_REVIEW': '1',
                  'OCR_SKIP': '1', 'SKIP_OCR': '1', 'OCR_GATE_SKIP': '1', 'CI': 'true'}
        result = self.run_stubbed(REFUSED, **bypass)
        self.assert_delegated(result)
