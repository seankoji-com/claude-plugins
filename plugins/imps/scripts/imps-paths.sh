#!/usr/bin/env bash
# imps-paths.sh — canonical derivation of the imps run slug and every path keyed off it.
#
# This is the single source of truth for `SLUG`. `commands/imps.md` used to inline the
# same derivation snippet in five places; they drifted independently and each copy was a
# chance to key a run to the wrong file. Call this instead and `eval` its output.
#
#   eval "$("${CLAUDE_PLUGIN_ROOT}/scripts/imps-paths.sh")"
#   # -> SLUG, RUNS_DIR, STATE_PATH, GOAL_PATH, PRS_PATH, TMP_PREFIX, REPO_ROOT
#
# Flags:
#   --slug        print only the slug
#   --no-migrate  skip the legacy state-file rename (read-only callers)
#
# ---------------------------------------------------------------------------
# Why the slug is derived from the WORKING TREE, not the repository
# ---------------------------------------------------------------------------
# Concurrent `/imps:imps` runs against one repo are supported by giving each run its own
# git worktree (see `imps-worktree.sh`). That works only because the slug distinguishes
# worktrees: two runs sharing a slug would share a state file, a GOAL.md and a `.prs.json`
# and would corrupt each other.
#
# `git rev-parse --show-toplevel` returns the *worktree* path, so it is the correct and
# guaranteed source. The historical `${CLAUDE_PROJECT_DIR:-$(pwd)}` only happened to work
# when the harness left CLAUDE_PROJECT_DIR unset and cwd was the worktree — it silently
# collapses every worktree onto one slug if CLAUDE_PROJECT_DIR is ever set to the main
# checkout. Preferring git's own answer makes per-worktree identity structural.
#
# In a main checkout `--show-toplevel` equals the repo root, which is what the old
# expression produced there too, so existing main-checkout runs keep their slug and
# resume normally.
set -uo pipefail

MIGRATE=1
MODE=all
for arg in "$@"; do
  case "$arg" in
    --slug)       MODE=slug ;;
    --no-migrate) MIGRATE=0 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'imps-paths.sh: unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

# --- working tree root ------------------------------------------------------
# Fall back only when git cannot answer (not a repo). CLAUDE_PROJECT_DIR is kept as a
# second-choice fallback for non-git invocations, never as the primary.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

SLUG=$(basename "$REPO_ROOT")
OLD_SLUG="$SLUG"

# --- disambiguate with the remote so two repos sharing a directory name differ --------
if REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
  OWNER_REPO=$(printf '%s' "$REMOTE_URL" \
    | sed -E \
      -e 's|^https?://[^/]+/||' \
      -e 's|^git@[^:]+:||' \
      -e 's|^ssh://[^/]+/[^/]+/||' \
      -e 's|\.git$||' -e 's|/$||' \
    | tr '/' '_')
  if [ -n "$OWNER_REPO" ] && [ "$OWNER_REPO" != "$SLUG" ]; then
    SLUG="${OWNER_REPO}__${SLUG}"
  fi
fi

# IMPS_RUNS_DIR exists so the run registry can be pointed elsewhere in tests, matching
# the IMPS_OPENCODE_CONFIG_PATH / AUDIT_LOG_FILE overrides the sibling scripts use.
RUNS_DIR="${IMPS_RUNS_DIR:-$HOME/.claude/imps/runs}"

# --- legacy migration: basename-only slug -> owner_repo__basename ---------------------
# Unchanged in behaviour from the snippet this script replaces. Renames only; never edits
# a state file, and never overwrites a file that already exists under the new slug.
if [ "$MIGRATE" -eq 1 ] && [ "$SLUG" != "$OLD_SLUG" ] \
   && [ -f "$RUNS_DIR/$OLD_SLUG.json" ] && [ ! -f "$RUNS_DIR/$SLUG.json" ]; then
  for ext in json md prs.json; do
    if [ -f "$RUNS_DIR/$OLD_SLUG.$ext" ] && [ ! -f "$RUNS_DIR/$SLUG.$ext" ]; then
      mv "$RUNS_DIR/$OLD_SLUG.$ext" "$RUNS_DIR/$SLUG.$ext" 2>/dev/null || true
    fi
  done
fi

if [ "$MODE" = slug ]; then
  printf '%s\n' "$SLUG"
  exit 0
fi

# TMP_PREFIX namespaces this run's scratch files. Gate logs and state-patch temporaries
# used fixed names ($TMPDIR/imps-gate-<name>.log, $TMPDIR/imps-state.json), which two
# concurrent runs sharing a TMPDIR would clobber.
TMP_PREFIX="${TMPDIR:-/tmp}/imps-${SLUG}"

# Emit `KEY='value'` with embedded single quotes escaped, so `eval` survives paths
# containing spaces (a home directory like "/Users/me/My Repos/..." is enough to break an
# unquoted KEY=value line). The '\'' idiom is portable to sh, bash and zsh alike.
emit() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

emit REPO_ROOT  "$REPO_ROOT"
emit SLUG       "$SLUG"
emit RUNS_DIR   "$RUNS_DIR"
emit STATE_PATH "$RUNS_DIR/${SLUG}.json"
emit GOAL_PATH  "$RUNS_DIR/${SLUG}.md"
emit PRS_PATH   "$RUNS_DIR/${SLUG}.prs.json"
emit TMP_PREFIX "$TMP_PREFIX"
