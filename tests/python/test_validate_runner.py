"""Execute the CI runner/report seams with disposable tests and Git revisions."""
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


def step(name):
    # Read this workflow's literal step body, not a second copy of its commands.
    match = re.search(r'^      - name: ' + re.escape(name) + r'\n(.*?)(?=^      - |^  \S|\Z)',
                      WORKFLOW.read_text(), re.M | re.S)
    if not match:
        raise AssertionError('missing workflow step: ' + name)
    return match.group(1)


def command(name):
    body = step(name)
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
        behavioral = WORKFLOW.read_text().split('  behavioral-tests:\n')[1].split('  macos-syntax:\n')[0]
        checkout = behavioral.split('      - name:')[0]
        self.assertNotIn('ref:', checkout)
        self.assertIn('fetch-depth: 0', checkout)
        self.assertEqual(behavioral.count('run: bash tests/run-python.sh'), 1)
        self.assertNotIn('unittest discover', behavioral)


if __name__ == '__main__':
    unittest.main()
