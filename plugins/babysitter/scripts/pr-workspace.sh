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
# from several worktrees without relying on implicit upstream selection.
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
  clone_diagnostics=$(mktemp "${TMPDIR:-/tmp}/babysitter-clone-error.XXXXXX") ||
    die "cannot create private clone diagnostics" 3
  report_clone_failure() {
    local category=unclassified
    if grep -Eiq 'Authentication failed|could not read Username|Permission denied|publickey' "$clone_diagnostics"; then
      category=authentication
    elif grep -Eiq 'repository .*not found|Repository not found' "$clone_diagnostics"; then
      category=repository-not-found
    elif grep -Eiq 'certificate|SSL|TLS' "$clone_diagnostics"; then
      category=TLS
    elif grep -Eiq 'Could not resolve|unable to access|Connection|proxy|timed out' "$clone_diagnostics"; then
      category=network
    elif grep -Eiq 'config|rewrite|protocol|bad boolean' "$clone_diagnostics"; then
      category=configuration
    fi
    # Raw errors may contain credential-bearing URLs, even in config-key names.
    note "clone failure category=${category}; private diagnostics retained at ${clone_diagnostics}"
  }
  clone_once() {
    if [ "$GH_READY" = "1" ]; then
      gh repo clone "https://github.com/${REPO}.git" "$CLONE" -- --quiet \
        --config "url.https://github.com/${REPO}.git.insteadOf=https://github.com/${REPO}.git" \
        --config "url.https://github.com/${REPO}.git.pushInsteadOf=https://github.com/${REPO}.git" >/dev/null 2>"$clone_diagnostics"
    else
      git clone --quiet \
        --config "url.https://github.com/${REPO}.git.insteadOf=https://github.com/${REPO}.git" \
        --config "url.https://github.com/${REPO}.git.pushInsteadOf=https://github.com/${REPO}.git" \
        "https://github.com/${REPO}.git" "$CLONE" 2>"$clone_diagnostics"
    fi
  }
  if ! clone_once; then
    note "clone of ${REPO} failed — retrying once"
    rm -rf "$CLONE"
    clone_once || {
      report_clone_failure
      if [ "$GH_READY" = "1" ]; then
        die "clone of ${REPO} failed twice" 3
      fi
      die "clone of ${REPO} failed twice (and gh is unavailable for authenticated clone)" 3
    }
  fi
  rm -f "$clone_diagnostics"
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
#      `upstream` is unsafe when another worktree tracks the default branch.
#      `nothing` refuses every implicit push, regardless of upstream names or
#      remotes; callers must use the explicit HEAD:<head> push documented above.
git -C "$CLONE" remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null ||
  die "cannot configure HTTPS origin in ${CLONE}" 3

# Exact per-clone identity mappings neutralize common inherited shorter SSH
# rewrites without editing global configuration. The resolved push URL below
# remains authoritative and refuses ambiguous exact rewrites/pushurl overrides.
for rewrite in insteadOf pushInsteadOf; do
  git -C "$CLONE" config --local --replace-all \
    "url.https://github.com/${REPO}.git.${rewrite}" "https://github.com/${REPO}.git" ||
    die "cannot scope HTTPS transport to this clone" 3
done

# Only when gh can actually serve credentials: clearing the chain and pointing it at a
# gh that is not authenticated would replace a helper that might work with one that
# certainly does not.
if [ "$GH_READY" = "1" ]; then
  git -C "$CLONE" config --local --unset-all credential.helper 2>/dev/null || true
  git -C "$CLONE" config --local --add credential.helper "" 2>/dev/null || true
  git -C "$CLONE" config --local --add credential.helper "!gh auth git-credential" 2>/dev/null || true
fi

# Remote push refspecs and mirror mode take precedence over push.default.
# Refuse inherited or reused settings rather than silently changing their meaning.
verify_push_policy() {
  local location="$1" status mirror destination fetch_destination
  destination=$(git -C "$location" remote get-url --push --all origin 2>/dev/null) ||
    die "cannot inspect origin push destination" 3
  fetch_destination=$(git -C "$location" remote get-url --all origin 2>/dev/null) ||
    die "cannot inspect origin fetch destination" 3
  if [ "$destination" != "https://github.com/${REPO}.git" ] ||
    [ "$fetch_destination" != "https://github.com/${REPO}.git" ]; then
    # Names can contain credentials in a URL base. Report only key classes/scopes.
    git -C "$location" config --null --show-origin --name-only --get-regexp \
      '^(url\..*\.(insteadof|pushinsteadof)|remote\.origin\.pushurl)$' |
      while IFS= read -r -d '' scope && IFS= read -r -d '' key; do
        case "$key" in
        url.*.insteadof) key='url.<redacted-base>.insteadof' ;;
        url.*.pushinsteadof) key='url.<redacted-base>.pushinsteadof' ;;
        remote.origin.pushurl) : ;;
        *) continue ;;
        esac
        printf 'pr-workspace.sh: inspect %s in %s (URL values redacted)\n' "$key" "$scope" >&2
      done || true
    die "origin push destination differs from required HTTPS repository; scope SSH/URL rewrites outside this cache or remove its pushurl override" 3
  fi
  local keys key
  if keys=$(git -C "$location" config --name-only --get-regexp '^remote\..*\.(push|mirror)$'); then
    :
  else
    status=$?
    [ "$status" = 1 ] || die "cannot inspect remote push configuration" 3
  fi
  # Remote names can themselves contain sensitive text. Never log names or values.
  # Read all effective configured remotes, including alternate branch push remotes.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
    *.push) die "configured remote push refspec bypasses safe push policy" 3 ;;
    *.mirror)
      if mirror=$(git -C "$location" config --bool "$key" 2>/dev/null); then
        [ "$mirror" != true ] || die "remote mirror mode bypasses safe push policy" 3
      else
        die "cannot inspect remote mirror mode" 3
      fi ;;
    esac
  done <<< "$keys"

}
verify_push_policy "$CLONE"

git -C "$CLONE" config --local push.default nothing ||
  die "cannot configure safe push policy in ${CLONE}" 3
git -C "$CLONE" config --local remote.pushDefault origin ||
  die "cannot configure push remote in ${CLONE}" 3

git -C "$CLONE" fetch --prune --quiet origin ||
  die "fetch failed in ${CLONE}" 3

git -C "$CLONE" rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null ||
  die "origin/${BRANCH} does not exist in ${REPO} — was the PR branch deleted?" 3

# ---- worktree ----------------------------------------------------------------
LOCAL_BRANCH="babysitter/pr-${PR_NUMBER}"
# Keep push selection predictable too; a stale branch pushRemote overrides
# remote.pushDefault. Explicit origin HEAD:<head> remains the supported push.
git -C "$CLONE" config --local "branch.${LOCAL_BRANCH}.pushRemote" origin ||
  die "cannot configure push remote for ${LOCAL_BRANCH}" 3

if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
  # Validate worktree overrides before even fetching from inherited destinations.
  verify_push_policy "$WORKTREE"
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

verify_push_policy "$WORKTREE"
[ "$(git -C "$WORKTREE" config --get push.default)" = nothing ] &&
  [ "$(git -C "$WORKTREE" config --get remote.pushDefault)" = origin ] &&
  [ "$(git -C "$WORKTREE" config --get "branch.${LOCAL_BRANCH}.pushRemote")" = origin ] ||
  die "effective safe push policy is not enforced for ${LOCAL_BRANCH}" 3

echo "$WORKTREE"
