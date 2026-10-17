"""Execute the CI runner/report seams with disposable tests and Git revisions."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/validate.yml'
# The next job key. A two-space comment is not a boundary: it can sit inside a job.
NEXT_JOB = r'^  [A-Za-z0-9_-]+:[ \t]*$'


def step(name, workflow=WORKFLOW):
    # Read this workflow's literal step body, not a second copy of its commands.
    match = re.search(r'^      - name: ' + re.escape(name) + r'\n(.*?)(?=^      - |' + NEXT_JOB + r'|\Z)',
                      workflow.read_text(), re.M | re.S)
    if not match:
        raise AssertionError('missing workflow step: ' + name)
    return match.group(1)


def job(name, workflow=WORKFLOW):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=' + NEXT_JOB + r'|\Z)',
                      workflow.read_text(), re.M | re.S)
    if not match:
        raise AssertionError('missing workflow job: ' + name)
    return match.group(1)


def command(name, workflow=WORKFLOW):
    body = step(name, workflow)
    match = re.search(r'^        run: (.*)\n', body, re.M)
    if not match:
        raise AssertionError('missing run command: ' + name)
    if match.group(1) != '|':
        return match.group(1)
    return textwrap.dedent(body[match.end():])


class ValidateRunnerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / 'tests/python').mkdir(parents=True)
        for name in ('run-python.sh', 'run-python.py'):
            source = ROOT / 'tests' / name
            if source.exists():
                shutil.copy(source, self.root / 'tests' / name)
        shutil.copy(ROOT / '.coveragerc', self.root)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('COVERAGE_')}
        self.env['PATH'] = str(Path(sys.executable).parent) + os.pathsep + os.environ['PATH']

    def run_shell(self, script, **env):
        return subprocess.run(['bash', '-eo', 'pipefail', '-c', script], cwd=self.root,
                              env={**self.env, **env}, capture_output=True, text=True, timeout=30)

    def fixture(self, failing=False):
        (self.root / 'child.py').write_text('from pathlib import Path\nPath("child-hit").write_text("child")\n')
        (self.root / 'unused_namespace.py').write_text('def never_imported(value):\n    if value:\n        return 42\n    return 0\n')
        (self.root / 'tests/python/test_fixture.py').write_text(textwrap.dedent('''\
            import subprocess, sys, unittest
            from pathlib import Path
            class Fixture(unittest.TestCase):
                def test_once(self):
                    with Path('hits').open('a') as out: out.write('once\\n')
                    subprocess.run([sys.executable, 'child.py'], check=True)
                    self.assertTrue(SUCCESS)
            ''').replace('SUCCESS', repr(not failing)))

    def test_instrumented_failure_enforces_and_runs_once_with_child_coverage(self):
        self.fixture(failing=True)
        result = self.run_shell(command('Run tests/run-python.sh'))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertEqual((self.root / 'hits').read_text(), 'once\n')
        self.assertTrue((self.root / 'child-hit').is_file())
        self.assertNotIn('continue-on-error:', step('Run tests/run-python.sh'))
        self.assertNotIn('if:', step('Run tests/run-python.sh'))
        reports = list(self.root.glob('.coverage.*'))
        self.assertGreaterEqual(len(reports), 2, reports)
        report = self.run_shell(command('Measure Python coverage (advisory)'))
        self.assertEqual(report.returncode, 0, report.stdout + report.stderr)
        xml = ET.parse(self.root / 'coverage.xml')
        measured = {item.get('filename'): item for item in xml.findall('.//class')}
        self.assertIn('child.py', measured)
        self.assertEqual(measured['child.py'].get('line-rate'), '1')
        self.assertIn('unused_namespace.py', measured)
        self.assertEqual(measured['unused_namespace.py'].get('line-rate'), '0')
        self.assertGreater(int(xml.getroot().get('branches-valid')), 0)

    def test_success_and_plain_runner_execute_once(self):
        self.fixture()
        for argv in ('bash tests/run-python.sh', command('Run tests/run-python.sh')):
            with self.subTest(argv=argv):
                result = self.run_shell(argv)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.root / 'hits').read_text(), 'once\n')
                (self.root / 'hits').unlink()

    def test_empty_discovery_and_import_errors_enforce(self):
        for contents in ('', 'raise RuntimeError("broken import")\n'):
            (self.root / 'tests/python/test_fixture.py').write_text(contents)
            for argv in ('bash tests/run-python.sh', command('Run tests/run-python.sh')):
                with self.subTest(contents=contents, argv=argv):
                    result = self.run_shell(argv)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('broken import' if contents else 'ERROR: no Python tests discovered', result.stderr)

    def test_missing_report_fails_reporting_but_remains_advisory(self):
        result = self.run_shell(command('Measure Python coverage (advisory)'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No data to combine', result.stdout)
        self.assertFalse((self.root / 'coverage.xml').exists())
        reporting = step('Measure Python coverage (advisory)')
        upload = step('Retain Python coverage (advisory)')
        self.assertIn('continue-on-error: true', reporting)
        self.assertIn("if: ${{ !cancelled() }}", reporting)
        self.assertNotIn('unittest', reporting)
        self.assertIn('continue-on-error: true', upload)
        self.assertIn("!cancelled() && steps.python-coverage.outcome == 'success'", upload)
        self.assertIn('if-no-files-found: error', upload)
        self.assertIn("coverage==7.16.1", command('Install Python coverage'))

    def test_wrong_ref_rejects_head_in_place_of_merge_revision(self):
        # Local Git objects only. HEAD and the synthetic merge ref stay distinct.
        for argv in (['init', '-q'], ['config', 'user.name', 'Fixture'],
                     ['config', 'user.email', 'fixture@example.invalid']):
            subprocess.run(['git', *argv], cwd=self.root, check=True, capture_output=True)
        revisions = []
        for value in ('head', 'merge'):
            (self.root / 'value').write_text(value)
            subprocess.run(['git', 'add', 'value'], cwd=self.root, check=True)
            subprocess.run(['git', '-c', 'commit.gpgsign=false', 'commit', '-qm', value],
                           cwd=self.root, check=True, capture_output=True)
            revisions.append(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.root, text=True).strip())
        for expected, exit_code in ((revisions[0], 1), (revisions[1], 0)):
            result = self.run_shell(command('Verify checkout revision'), GITHUB_SHA=expected,
                                    GITHUB_HEAD_REF='fixture-head')
            self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        behavioral = job('behavioral-tests')
        shell_js = job('shell-js-tests')
        for body in (behavioral, shell_js):
            checkout = body.split('      - name:')[0]
            self.assertNotIn('ref:', checkout)
            self.assertIn('fetch-depth: 0', checkout)
            self.assertIn('      - name: Verify checkout revision\n', body)
        self.assertEqual(behavioral.count('run: bash tests/run-python.sh'), 1)
        self.assertNotIn('unittest discover', behavioral)
        # Each suite runs exactly once across the workflow, in an enforcing job.
        for suite in ('tests/run.sh', 'tests/run-js.sh'):
            self.assertEqual(shell_js.count('run: bash ' + suite + '\n'), 1, suite)
            self.assertEqual(WORKFLOW.read_text().count('run: bash ' + suite + '\n'), 1, suite)
        self.assertNotIn('continue-on-error', shell_js)
        self.assertNotIn('if:', shell_js)

    def test_slices_end_at_job_keys_not_two_space_comments(self):
        workflow = self.root / 'fixture.yml'
        workflow.write_text(textwrap.dedent('''\
            jobs:
              first:
                runs-on: ubuntu-latest
              # two-space comment inside a job
                continue-on-error: true
                steps:
                  - name: Only
              # two-space comment inside a step
                    continue-on-error: true
                    run: bash tests/run.sh

              # two-space comment between jobs
              last:
                steps:
                  - name: Final
                    run: echo last
            '''))
        first = job('first', workflow)
        self.assertIn('    continue-on-error: true\n    steps:', first)
        self.assertNotIn('last', first)
        self.assertIn('continue-on-error: true', step('Only', workflow))
        self.assertEqual(command('Only', workflow), 'bash tests/run.sh')
        self.assertTrue(job('last', workflow).endswith('run: echo last\n'))

    def test_workflow_syntax_compiles_every_file_without_executing(self):
        scripts = self.root / 'plugins/fixture/scripts'
        scripts.mkdir(parents=True)
        marker = 'require("node:fs").writeFileSync("executed", "bad");'
        (scripts / 'first.workflow.js').write_text(
            'export const meta = {name: "fixture"};\n' + marker + '\nreturn await agent(args);\n')
        (scripts / 'second.workflow.js').write_text('export const meta = {};\nreturn 1;\n')
        (scripts / 'ordinary.js').write_text(marker)
        result = self.run_shell(command('node --check all shipped Workflow scripts'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ('first.workflow.js', 'second.workflow.js', 'ordinary.js'):
            self.assertIn('Checking plugins/fixture/scripts/' + name, result.stdout)
        self.assertFalse((self.root / 'executed').exists())
        for name, source in (
            ('first.workflow.js', 'export const meta = {};\nreturn await (;'),
            ('second.workflow.js', 'export const meta = {};\nexport const unexpected = 1;'),
            ('ordinary.js', 'const broken = ;'),
        ):
            target = scripts / name
            original = target.read_text()
            try:
                target.write_text(source)
                result = self.run_shell(command('node --check all shipped Workflow scripts'))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('SyntaxError', result.stderr)
            finally:
                target.write_text(original)

    def test_version_bump_push_preserves_literal_head_ref(self):
        workflow = ROOT / '.github/workflows/version-bump.yml'
        name = 'Commit version bumps'
        self.assertIn('HEAD_REF: ${{ github.head_ref }}', step(name, workflow))
        script = command(name, workflow)
        self.assertNotIn('${{', script)
        stubs = self.root / 'bin'
        stubs.mkdir()
        git = stubs / 'git'
        git.write_text('#!/usr/bin/env python3\nimport json, sys\n'
                       'with open("git-argv.jsonl", "a") as out: out.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        git.chmod(0o755)
        head = 'repair/";$(touch injected);`touch injected-too`'
        result = self.run_shell(script, HEAD_REF=head, PATH=str(stubs) + os.pathsep + self.env['PATH'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / 'git-argv.jsonl').read_text().splitlines()]
        self.assertEqual(calls[-1], ['push', 'origin', 'HEAD:' + head])
        self.assertFalse((self.root / 'injected').exists())
        self.assertFalse((self.root / 'injected-too').exists())


if __name__ == '__main__':
    unittest.main()
