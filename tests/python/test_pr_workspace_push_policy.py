"""Exercise the real workspace helper and Git pushes against a local remote."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'plugins/babysitter/scripts/pr-workspace.sh'


class PushPolicyTest(unittest.TestCase):
    def test_reused_clone_refuses_upstream_misrouting_but_explicit_push_works(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / 'home'
            home.mkdir()
            tools = root / 'bin'
            tools.mkdir()
            (tools / 'gh').write_text('#!/bin/sh\nexit 1\n')
            (tools / 'gh').chmod(0o755)
            env = {**os.environ, 'HOME': str(home),
                   'GIT_CONFIG_GLOBAL': str(home / '.gitconfig'),
                   'GIT_CONFIG_NOSYSTEM': '1',
                   'PATH': f'{tools}:{os.environ["PATH"]}'}
            for key in list(env):
                if key.startswith('GIT_CONFIG_KEY_') or key.startswith('GIT_CONFIG_VALUE_'):
                    env.pop(key)
            env.pop('GIT_CONFIG_COUNT', None)
            env.pop('GIT_CONFIG', None)
            env.pop('GIT_DIR', None)
            env.pop('GIT_WORK_TREE', None)

            def git(path, *args, check=True):
                return subprocess.run(['git', '-C', str(path), *args], env=env,
                                      capture_output=True, text=True, check=check)

            remote = root / 'remote.git'
            git(root, 'init', '--bare', '--initial-branch=master', str(remote))
            seed = root / 'seed'
            git(root, 'init', '--initial-branch=master', str(seed))
            git(seed, 'config', 'user.email', 'test@example.invalid')
            git(seed, 'config', 'user.name', 'Test')
            git(seed, 'config', 'commit.gpgsign', 'false')
            git(seed, 'commit', '--allow-empty', '-m', 'seed')
            git(seed, 'remote', 'add', 'origin', str(remote))
            git(seed, 'push', 'origin', 'HEAD:master', 'HEAD:feature')
            git(root, 'config', '--global', f'url.{remote}.insteadOf',
                'https://github.com/test/repo.git')

            def initialize():
                result = subprocess.run(
                    ['bash', str(SCRIPT), '--repo', 'test/repo', '--pr', '1',
                     '--branch', 'feature', '--root', str(root / 'cache')],
                    env=env, capture_output=True, text=True, check=True)
                return Path(result.stdout.strip())

            worktree = initialize()
            clone = root / 'cache/repos/test__repo'
            publish = root / 'publish.git'
            git(root, 'init', '--bare', '--initial-branch=master', str(publish))
            git(clone, 'remote', 'add', 'publish', str(publish))
            git(root, 'config', '--global', 'remote.pushDefault', 'publish')
            git(clone, 'config', 'branch.babysitter/pr-1.pushRemote', 'publish')
            git(clone, 'config', 'branch.babysitter/pr-1.remote', '.')
            git(clone, 'config', 'branch.babysitter/pr-1.merge', 'refs/heads/master')
            git(root, 'config', '--global', 'branch.autoSetupMerge', 'false')
            git(clone, 'config', 'push.default', 'upstream')
            initialize()  # Existing unsafe settings must be repaired on reuse.
            self.assertEqual(git(clone, 'config', 'push.default').stdout.strip(), 'nothing')
            self.assertNotEqual(git(worktree, 'push', check=False).returncode, 0)
            self.assertNotEqual(git(publish, 'rev-parse', '--verify',
                                    'refs/heads/babysitter/pr-1', check=False).returncode, 0)
            master = git(remote, 'rev-parse', 'master').stdout.strip()
            git(worktree, 'config', 'user.email', 'test@example.invalid')
            git(worktree, 'config', 'user.name', 'Test')
            git(worktree, 'config', 'commit.gpgsign', 'false')
            git(worktree, 'branch', '--set-upstream-to=origin/master')
            git(worktree, 'commit', '--allow-empty', '-m', 'feature change')
            self.assertNotEqual(git(worktree, 'push', check=False).returncode, 0)
            self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
            git(worktree, 'push', 'origin', 'HEAD:refs/heads/feature')
            self.assertEqual(git(remote, 'rev-parse', 'feature').stdout,
                             git(worktree, 'rev-parse', 'HEAD').stdout)
            git(worktree, 'checkout', '-b', 'feature', '--track', 'origin/feature')
            git(worktree, 'commit', '--allow-empty', '-m', 'matching branch change')
            self.assertNotEqual(git(worktree, 'push', check=False).returncode, 0)
            git(worktree, 'push', 'origin', 'HEAD:refs/heads/feature')
            self.assertEqual(git(remote, 'rev-parse', 'feature').stdout,
                             git(worktree, 'rev-parse', 'HEAD').stdout)
            self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
            for key, value in [('remote.origin.push', 'HEAD:refs/heads/master'),
                               ('remote.origin.mirror', 'true')]:
                git(root, 'config', '--global', key, value)
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 3)
                self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
                git(root, 'config', '--global', '--unset', key)

