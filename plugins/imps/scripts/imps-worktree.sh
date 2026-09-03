#!/usr/bin/env bash
# imps-worktree.sh — manage the git worktrees that make concurrent /imps:imps runs safe.
#
#   imps-worktree.sh new [name]     create a run worktree (name defaults to a random slug)
#   imps-worktree.sh list           list run worktrees and whether each has a live run
#   imps-worktree.sh remove <name>  remove a run worktree (refuses if a run is live)
#
# ---------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------
# Every `/imps:imps` orchestration step — cutting the run branch, merging imp branches,
# running gates, syncing the default branch, pushing the PR, fix rounds — operates on the
# session's own working tree. Two runs sharing one working tree therefore fight over one
# HEAD: run A's `git checkout -b` lands run B's merges on the wrong branch.
#
# The fix is not to thread a path through the orchestration prompts (which would make
# correctness depend on every agent honouring a `cd`, and turn a loud collision into
# silent cross-run corruption). It is to give each run its own working tree and start its
# session there, so cwd is right by construction and no prompt has to be trusted.
#
# Per-run identity follows automatically: `imps-paths.sh` derives the slug from
# `git rev-parse --show-toplevel`, so each worktree already gets its own state file,
# GOAL.md and `.prs.json`.
set -uo pipefail

die() { printf 'imps-worktree: %s\n' "$1" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATHS_SH="$HERE/imps-paths.sh"
[ -x "$PATHS_SH" ] || die "cannot find imps-paths.sh next to this script ($PATHS_SH)"

git rev-parse --git-dir >/dev/null 2>&1 || die 'not inside a git repository'

# The "main" checkout is the worktree git considers primary; run worktrees are created as
# siblings of it so they never sit inside the repo (where gates, globs and lint would see
# them) nor inside .claude/worktrees (which the harness manages and prunes).
MAIN_ROOT=$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$MAIN_ROOT" ] || die 'could not determine the main checkout path'
REPO_NAME=$(basename "$MAIN_ROOT")
WT_HOME="$(dirname "$MAIN_ROOT")/${REPO_NAME}.imps"

RUNS_DIR="${IMPS_RUNS_DIR:-$HOME/.claude/imps/runs}"

# A run worktree is "live" if a state file exists for the slug that worktree would derive.
# Mirrors imps-paths.sh's own composition rather than re-deriving it independently.
slug_for() {
  local wt="$1" owner_repo slug
  slug=$(basename "$wt")
  if owner_repo=$(git -C "$wt" remote get-url origin 2>/dev/null); then
    owner_repo=$(printf '%s' "$owner_repo" \
      | sed -E -e 's|^https?://[^/]+/||' -e 's|^git@[^:]+:||' \
               -e 's|^ssh://[^/]+/[^/]+/||' -e 's|\.git$||' -e 's|/$||' | tr '/' '_')
    [ -n "$owner_repo" ] && [ "$owner_repo" != "$slug" ] && slug="${owner_repo}__${slug}"
  fi
  printf '%s' "$slug"
}

default_branch() {
  git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p'
}

# git's auto-gc rewrites packed-refs and prunes objects. With several orchestrator
# worktrees plus the harness's own per-imp isolated worktrees, the loose-object churn is
# exactly what trips the threshold, and a `git worktree add` racing a packed-refs rewrite
# is where "cannot lock ref" storms come from. Advise; never silently mutate git config.
gc_advisory() {
  local n="$1"
  [ "$n" -ge 2 ] || return 0
  if [ "$(git config --get gc.auto || echo unset)" = "0" ]; then return 0; fi
  cat <<EOF

  Advisory: $n run worktrees share one object store and auto-gc can race
  'git worktree add' / ref updates. To pin it off for this repo:
      git -C "$MAIN_ROOT" config gc.auto 0
  Re-enable and compact once no run is live:
      git -C "$MAIN_ROOT" config --unset gc.auto && git -C "$MAIN_ROOT" gc
EOF
}

cmd_new() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    name="run-$(date -u +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-4)"
  fi
  case "$name" in */*|.|..) die "invalid worktree name: $name" ;; esac

  local dest="$WT_HOME/$name"
  [ -e "$dest" ] && die "already exists: $dest"

  local db; db=$(default_branch)
  [ -n "$db" ] || die 'could not resolve the default branch from origin'

  mkdir -p "$WT_HOME" || die "cannot create $WT_HOME"
  git fetch origin "$db" --quiet || die "git fetch origin $db failed"

  # Detached HEAD on origin/<default>: /imps:imps Phase 2 cuts its own run branch here,
  # so claiming a branch now would only collide with the run's.
  git worktree add --detach "$dest" "origin/$db" || die 'git worktree add failed'

  printf '\nCreated run worktree:\n  %s\n  (detached at origin/%s)\n' "$dest" "$db"
  cat <<EOF

Next:
  1. Install this repo's dependencies in the new worktree — a fresh worktree has none,
     and /imps:imps runs its gates (lint/test/build) in the session's own tree:
         cd "$dest" && <your install command, e.g. npm ci>
  2. Start a Claude Code session with that worktree as its cwd, and run /imps:imps there.

The run's state file, GOAL.md and .prs.json are keyed to this worktree's slug
($(slug_for "$dest" 2>/dev/null || echo '<derived on first run>')), so it will not
collide with any other run against this repo.
EOF
  gc_advisory "$(list_worktrees | wc -l | tr -d ' ')"
}

list_worktrees() {
  [ -d "$WT_HOME" ] || return 0
  find "$WT_HOME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

cmd_list() {
  local found=0
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    found=1
    local slug state status branch
    slug=$(slug_for "$wt")
    state="$RUNS_DIR/${slug}.json"
    if [ -f "$state" ]; then
      status="live run"
      if command -v jq >/dev/null 2>&1; then
        status="live run (phase: $(jq -r '.phase // "?"' "$state" 2>/dev/null))"
      fi
    else
      status="idle"
    fi
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
    printf '%-40s  %-12s  %s\n' "$(basename "$wt")" "$branch" "$status"
  done <<EOF
$(list_worktrees)
EOF
  [ "$found" -eq 1 ] || printf 'No imps run worktrees under %s\n' "$WT_HOME"
}

cmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || die 'remove requires a worktree name (see: imps-worktree.sh list)'
  local dest="$WT_HOME/$name"
  [ -d "$dest" ] || die "no such run worktree: $dest"

  # Refuse while a run is live. Removing the tree out from under an in-flight run strands
  # its branch and its state file, and the state file is the only resume handle there is.
  local state; state="$RUNS_DIR/$(slug_for "$dest").json"
  if [ -f "$state" ]; then
    die "a run is still live for this worktree (state: $state).
  Finish or abandon that run first — deleting its worktree now would strand it."
  fi

  git worktree remove "$dest" || die "git worktree remove failed (use --force yourself if you are sure)"
  printf 'Removed %s\n' "$dest"
}

case "${1:-}" in
  new)    shift; cmd_new "$@" ;;
  list)   shift; cmd_list "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  -h|--help|'') sed -n '2,8p' "$0" ;;
  *) die "unknown command: $1 (expected new | list | remove)" ;;
esac
