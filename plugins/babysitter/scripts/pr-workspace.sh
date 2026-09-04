#!/usr/bin/env bash
#
# pr-workspace.sh — give one PR its own git worktree, in the right repository.
#
# The babysitter works across a whole org, so "isolated worktree" cannot mean a
# worktree of the repo the session was launched in — each PR lives in a different
# repository. This script keeps one bare-ish cache clone per repository under
# ~/.claude/babysitter/repos/ and cuts one worktree per PR from it, so N agents on N
# PRs never share an index, and two PRs in the same repo still get separate
# checkouts.
#
# The PR's head branch is deliberately NOT checked out under its own name. The
# worktree gets a local branch `babysitter/pr-<N>` pointing at origin/<head>, and
# pushes go through `git push origin HEAD:<head>`. That keeps the same branch usable
# from several worktrees and makes an accidental push to the wrong ref impossible to
# write by habit.
#
# Usage:
#   pr-workspace.sh --repo <owner/name> --pr <N> --branch <head-ref> [--root <dir>]
#   pr-workspace.sh --repo <owner/name> --pr <N> --remove [--root <dir>]
#
# On success the worktree path is the only thing written to stdout; progress goes to
# stderr. Callers can therefore do: WT="$(pr-workspace.sh ...)"
#
# Exit codes:
#   0 — worktree ready (path on stdout), or removed
#   2 — precondition failed (bad arguments, missing git/gh)
#   3 — clone, fetch, or worktree creation failed
#   4 — the worktree exists and has uncommitted changes; left untouched

set -euo pipefail

# Prints this file's header comment as the help text. Derived from the header
# rather than a hardcoded line range: a `sed -n '2,NNp'` went stale the first time
# this header grew, printing a truncated help message with no other symptom.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

REPO=""
PR_NUMBER=""
BRANCH=""
REMOVE=0
# Left empty rather than defaulted to "${HOME}/..." directly: under `set -u` an unset
# HOME aborts with a raw "unbound variable", and defaulting HOME to "" would silently
# produce the absolute-looking /.claude/babysitter. Empty here, validated below.
ROOT="${BABYSITTER_HOME:-}"
if [ -z "$ROOT" ] && [ -n "${HOME:-}" ]; then
  ROOT="${HOME}/.claude/babysitter"
fi

die() {
  echo "pr-workspace.sh: $1" >&2
  exit "${2:-2}"
}

note() { echo "pr-workspace.sh: $1" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
  --repo)
    REPO="${2:-}"
    shift 2
    ;;
  --pr)
    PR_NUMBER="${2:-}"
    shift 2
    ;;
  --branch)
    BRANCH="${2:-}"
    shift 2
    ;;
  --root)
    ROOT="${2:-}"
    shift 2
    ;;
  --remove)
    REMOVE=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found on PATH"

# Every path this script creates, and the one it `rm -rf`s, is derived from ROOT.
# An empty ROOT — `--root ""`, or BABYSITTER_HOME set empty with HOME unset — would
# put those paths at the filesystem root and point a recursive delete at
# /worktrees/<slug>__pr-<N>. Validate before deriving anything from it.
case "$ROOT" in
'') die "root directory is empty — set --root or BABYSITTER_HOME to an absolute path" ;;
/*) : ;;
*) die "root directory must be an absolute path, got: ${ROOT}" ;;
esac

case "$REPO" in
*/*) : ;;
*) die "--repo must be owner/name, got: ${REPO:-<empty>}" ;;
esac
case "$PR_NUMBER" in
'' | *[!0-9]*) die "--pr must be a number, got: ${PR_NUMBER:-<empty>}" ;;
esac

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
SLUG="${OWNER}__${NAME}"
CLONE="${ROOT}/repos/${SLUG}"
WORKTREE="${ROOT}/worktrees/${SLUG}__pr-${PR_NUMBER}"

if [ "$REMOVE" = "1" ]; then
  if [ -d "$CLONE/.git" ] && [ -e "$WORKTREE" ]; then
    git -C "$CLONE" worktree remove --force "$WORKTREE" 2>/dev/null ||
      rm -rf "$WORKTREE"
    git -C "$CLONE" branch -D "babysitter/pr-${PR_NUMBER}" >/dev/null 2>&1 || true
    note "removed ${WORKTREE}"
  else
    note "nothing to remove at ${WORKTREE}"
  fi
  exit 0
fi

[ -n "$BRANCH" ] || die "--branch <head-ref> is required unless --remove is given"

mkdir -p "${ROOT}/repos" "${ROOT}/worktrees" || die "cannot create ${ROOT}" 3

# ---- cache clone -------------------------------------------------------------
GH_READY=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_READY=1
fi

if [ ! -d "$CLONE/.git" ]; then
  note "cloning ${REPO} (first PR seen in this repo)"
  # gh inherits the user's existing GitHub auth, which a bare `git clone` of a
  # private repo would not. Fall back to git for a host without gh configured.
  #
  # Retried once, because a clone here fails transiently more often than it fails
  # for real: a large repo has been observed stalling for minutes against an
  # ESTABLISHED connection and then dying, where an immediate bare retry succeeded.
  # A partial clone directory left by the first attempt would make the second one
  # fail on a non-empty target, so it goes first.
  clone_once() {
    if [ "$GH_READY" = "1" ]; then
      gh repo clone "$REPO" "$CLONE" -- --quiet >/dev/null 2>&1
    else
      git clone --quiet "https://github.com/${REPO}.git" "$CLONE"
    fi
  }
  if ! clone_once; then
    note "clone of ${REPO} failed — retrying once"
    rm -rf "$CLONE"
    clone_once || {
      if [ "$GH_READY" = "1" ]; then
        die "clone of ${REPO} failed twice" 3
      fi
      die "clone of ${REPO} failed twice (and gh is unavailable for authenticated clone)" 3
    }
  fi
fi

# ---- make this clone pushable ------------------------------------------------
# Applied on every run, not just on a fresh clone, so a clone made by an earlier
# version of this script — or by a `gh` whose git_protocol was set differently at the
# time — gets repaired rather than staying broken forever. Worktrees share the clone's
# config, so fixing it here fixes every PR in the repo at once.
#
# Each of these three closes a push failure that has actually happened in a sweep, and
# each one presented as a different, misleading error:
#
#   1. An SSH origin is a dead end wherever the ssh-agent cannot sign ("agent refused
#      operation"). One repo in an org cloning over SSH while the rest come down over
#      HTTPS is enough to strand every PR in it, and no retry helps.
#   2. A global credential.helper that cannot run headlessly (macOS `osxkeychain` is
#      the usual one) does not cleanly fall through to the next helper in the chain;
#      git ends up trying to prompt on a TTY that is not there and reports "could not
#      read Username ... Device not configured", or a SOCKS/proxy error, depending on
#      which fallback it reached. The empty value first is what resets the inherited
#      chain — `credential.helper` accumulates across config scopes, so adding the gh
#      helper without clearing would leave the broken one still in front of it.
#   3. `push.default=current` pushes the *local* branch name to a same-named remote
#      ref. The local branch here is deliberately `babysitter/pr-<N>`, so under that
#      setting a bare `git push` silently creates a stray remote branch instead of
#      updating the PR — worse than an error, because nothing says it went wrong.
#      `upstream` can only push to the ref the branch tracks, which is the PR head.
git -C "$CLONE" remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null || true

# Only when gh can actually serve credentials: clearing the chain and pointing it at a
# gh that is not authenticated would replace a helper that might work with one that
# certainly does not.
if [ "$GH_READY" = "1" ]; then
  git -C "$CLONE" config --local --unset-all credential.helper 2>/dev/null || true
  git -C "$CLONE" config --local --add credential.helper "" 2>/dev/null || true
  git -C "$CLONE" config --local --add credential.helper "!gh auth git-credential" 2>/dev/null || true
fi

git -C "$CLONE" config --local push.default upstream 2>/dev/null || true

git -C "$CLONE" fetch --prune --quiet origin ||
  die "fetch failed in ${CLONE}" 3

git -C "$CLONE" rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null ||
  die "origin/${BRANCH} does not exist in ${REPO} — was the PR branch deleted?" 3

# ---- worktree ----------------------------------------------------------------
LOCAL_BRANCH="babysitter/pr-${PR_NUMBER}"

if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
  # Reuse. Never discard work: if a previous agent left changes behind, say so and
  # let the caller decide rather than resetting over them.
  if [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ]; then
    echo "$WORKTREE"
    die "worktree ${WORKTREE} has uncommitted changes — inspect it before reusing" 4
  fi
  git -C "$WORKTREE" fetch --quiet origin "$BRANCH" || die "fetch failed in worktree" 3
  git -C "$WORKTREE" checkout --quiet -B "$LOCAL_BRANCH" "origin/${BRANCH}" ||
    die "could not point ${LOCAL_BRANCH} at origin/${BRANCH}" 3
  note "reused ${WORKTREE}"
else
  rm -rf "$WORKTREE"
  git -C "$CLONE" worktree prune
  git -C "$CLONE" worktree add --quiet -B "$LOCAL_BRANCH" "$WORKTREE" "origin/${BRANCH}" ||
    die "could not create worktree for ${REPO}#${PR_NUMBER}" 3
  note "created ${WORKTREE} on ${LOCAL_BRANCH} (tracking origin/${BRANCH})"
fi

echo "$WORKTREE"
