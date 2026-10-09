"""Exercise the real workspace helper and Git pushes against a local remote."""
import os
import shutil
import sys
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
                   'PATH': f'{tools}:{os.environ["PATH"]}', 'TMPDIR': str(root)}
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
            # Route only transport operations to the local bare remote. Configuration
            # inspection still uses real Git and sees the production HTTPS destination.
            real_git = shutil.which('git')
            wrapper = tools / 'git'
            wrapper.write_text(
                f'#!{sys.executable}\n'
                'import os, subprocess, sys\n'
                f'real_git = {real_git!r}\nremote = {str(remote)!r}\n'
                'args = sys.argv[1:]\nuses_origin = "origin" in args\n'
                'action = next((item for item in ("clone", "fetch", "push") if item in args), None)\n'
                'if action == "clone" and os.environ.get("CLONE_ATTEMPT_MARKER"):\n'
                ' open(os.environ["CLONE_ATTEMPT_MARKER"], "w").close()\n'
                'if action == "clone" and os.environ.get("TEST_CLONE_FAILURE"):\n'
                ' sys.stderr.write("fatal: Authentication failed for https://user:PRIVATE_TOKEN@github.com/test/repo.git\\n"); sys.exit(1)\n'
                'if action is not None:\n'
                ' args = [remote if item == "https://github.com/test/repo.git" or item == "origin" else item for item in args]\n'
                ' if action == "fetch": args.append("+refs/heads/*:refs/remotes/origin/*")\n'
                'result = subprocess.call([real_git, *args])\n'
                'if action == "push" and uses_origin and result == 0:\n'
                ' subprocess.check_call([real_git, *args[:args.index("push")], "fetch", "--quiet", remote, "+refs/heads/*:refs/remotes/origin/*"])\n'
                'sys.exit(result)\n')
            wrapper.chmod(0o755)

            def initialize(cache="cache"):
                result = subprocess.run(
                    ['bash', str(SCRIPT), '--repo', 'test/repo', '--pr', '1',
                     '--branch', 'feature', '--root', str(root / cache)],
                    env=env, capture_output=True, text=True, check=True)
                return Path(result.stdout.strip())

            git(root, 'config', '--global', 'url.git@github.com:.insteadOf', 'https://github.com/')
            worktree = initialize()
            self.assertEqual(git(worktree, 'remote', 'get-url', 'origin').stdout.strip(),
                             'https://github.com/test/repo.git')
            git(root, 'config', '--global', '--unset', 'url.git@github.com:.insteadOf')
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
            git(clone, 'config', 'extensions.worktreeConfig', 'true')
            for override in ['upstream', 'current']:
                git(worktree, 'config', '--worktree', 'push.default', override)
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 3)
                self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
                dirty = worktree / 'preserved-dirty-file'
                dirty.write_text('preserve pending work')
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 3)
                self.assertEqual(dirty.read_text(), 'preserve pending work')
                git(worktree, 'config', '--worktree', '--unset', 'push.default')
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 4)
                self.assertEqual(dirty.read_text(), 'preserve pending work')
                dirty.unlink()
            for scope, key, value in [
                ('--local', 'remote.origin.pushurl', str(publish)),
                ('--global', f'url.{publish}.pushInsteadOf',
                 'https://github.com/test/repo.git'),
                ('--global', 'url.PRIVATE_TOKEN@github.com:.insteadOf', 'https://github.com/test/repo.git'),
                ('--global', 'url.PRIVATE_TOKEN@github.com:.pushInsteadOf', 'https://github.com/test/repo.git')]:
                git(clone, 'config', scope, key, value)
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 3)
                self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
                if key.startswith('url.'):
                    self.assertIn('url.<redacted-base>.', caught.exception.stderr)
                    self.assertIn(str(home / '.gitconfig'), caught.exception.stderr)
                self.assertNotIn('PRIVATE_TOKEN', caught.exception.stderr)
                git(clone, 'config', scope, '--unset', key)
            for key, value in [('remote.origin.push', 'HEAD:refs/heads/master'),
                               ('remote.origin.mirror', 'true')]:
                git(root, 'config', '--global', key, value)
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    initialize()
                self.assertEqual(caught.exception.returncode, 3)
                self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
                git(root, 'config', '--global', '--unset', key)


            # Common shorter SSH rewrites are repaired only for this cache URL.
            for suffix in ['insteadOf', 'pushInsteadOf']:
                key = f'url.git@github.com:.{suffix}'
                git(root, 'config', '--global', key, 'https://github.com/')
                initialize()
                self.assertEqual(git(worktree, 'remote', 'get-url', '--push', 'origin').stdout.strip(),
                                 'https://github.com/test/repo.git')
                self.assertEqual(git(root, 'config', '--global', key).stdout.strip(), 'https://github.com/')
                git(root, 'config', '--global', '--unset', key)
            # An alternate remote's configured refspec/mirror bypasses defaults;
            # reject it in both clone and effective worktree configuration.
            for scope in ['--global', '--local', '--worktree']:
                for key, value in [('remote.publish.push', 'HEAD:refs/heads/master'),
                                   ('remote.publish.mirror', 'true'),
                                   ('remote.publish.mirror', 'https://PRIVATE_TOKEN@example.invalid')]:
                    location = worktree if scope == '--worktree' else clone
                    git(location, 'config', scope, key, value)
                    git(clone, 'config', 'branch.feature.pushRemote', 'publish')
                    with self.assertRaises(subprocess.CalledProcessError) as caught:
                        initialize()
                    self.assertEqual(caught.exception.returncode, 3)
                    self.assertNotIn('PRIVATE_TOKEN', caught.exception.stderr)
                    self.assertNotEqual(git(publish, 'rev-parse', '--verify', 'master', check=False).returncode, 0)
                    self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)
                    git(location, 'config', scope, '--unset', key)
            initialize()
            self.assertNotEqual(git(worktree, 'push', 'publish', check=False).returncode, 0)
            git(worktree, 'checkout', 'feature')
            self.assertNotEqual(git(worktree, 'push', check=False).returncode, 0)
            self.assertEqual(git(remote, 'rev-parse', 'master').stdout.strip(), master)

            # First-time clone failures remain diagnosable without exposing URLs.
            env['TEST_CLONE_FAILURE'] = '1'
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                initialize('failed-cache')
            self.assertEqual(caught.exception.returncode, 3)
            self.assertNotIn('PRIVATE_TOKEN', caught.exception.stderr)
            self.assertIn('category=authentication', caught.exception.stderr)
            self.assertEqual(list(root.glob('babysitter-clone-error.*')), [])
            env.pop('TEST_CLONE_FAILURE')
            marker = root / 'transport-attempted'
            env['CLONE_ATTEMPT_MARKER'] = str(marker)
            key = 'url.ssh://git@alternate.example/test/repo.git.insteadOf'
            git(root, 'config', '--global', key, 'https://github.com/test/repo.git')
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                initialize('unsafe-first-clone')
            self.assertEqual(caught.exception.returncode, 3)
            self.assertIn('initial clone transport differs', caught.exception.stderr)
            self.assertNotIn('alternate.example', caught.exception.stderr)
            self.assertFalse(marker.exists(), 'unsafe clone transport was attempted')
            self.assertEqual(list(root.glob('babysitter-clone-error.*')), [])
            git(root, 'config', '--global', '--unset', key)
