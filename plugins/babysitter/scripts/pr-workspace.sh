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
ROOT="${BABYSITTER_HOME:-${HOME}/.claude/babysitter}"

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
if [ ! -d "$CLONE/.git" ]; then
  note "cloning ${REPO} (first PR seen in this repo)"
  # gh inherits the user's existing GitHub auth, which a bare `git clone` of a
  # private repo would not. Fall back to git for a host without gh configured.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$REPO" "$CLONE" -- --quiet >/dev/null 2>&1 ||
      die "clone of ${REPO} failed" 3
  else
    git clone --quiet "https://github.com/${REPO}.git" "$CLONE" ||
      die "clone of ${REPO} failed (and gh is unavailable for authenticated clone)" 3
  fi
fi

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
