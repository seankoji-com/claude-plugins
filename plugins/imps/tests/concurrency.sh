#!/usr/bin/env bash
# concurrency.sh — guards the properties that let two /imps runs share one repo.
#
# Concurrency here rests on one structural fact: two git worktrees of the same repo derive
# two different slugs, so they never share a state file, GOAL.md or .prs.json. Everything
# else (the run branch, the PR) follows from the slug. That fact is easy to break by
# "tidying" the derivation back to ${CLAUDE_PROJECT_DIR:-$(pwd)}, and the breakage is
# silent — two runs would just start writing the same state file. Hence a test.
#
# Asserts:
#   A. two worktrees of one repo -> two distinct slugs; the main checkout keeps the
#      historical owner_repo__basename form (so existing runs still resume)
#   B. CLAUDE_PROJECT_DIR pointing at the main checkout does NOT collapse a worktree's
#      slug onto the main one (the specific regression that would silently re-enable
#      state-file sharing)
#   C. eval-safety: a path containing a space survives `eval "$(imps-paths.sh)"`
#   D. imps-worktree.sh refuses to remove a worktree whose run is still live
#   E. concurrent imps-learnings-append.sh writers all land (no lost updates)
#
# Pure git + bash. No network, no LLM, no spend.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
PATHS_SH="$PLUGIN_ROOT/scripts/imps-paths.sh"
WT_SH="$PLUGIN_ROOT/scripts/imps-worktree.sh"
LEARN_SH="$PLUGIN_ROOT/scripts/imps-learnings-append.sh"

for f in "$PATHS_SH" "$WT_SH" "$LEARN_SH"; do
  [ -x "$f" ] || { echo "concurrency: missing or not executable: $f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "concurrency: git is required" >&2; exit 2; }

fails=0
assert() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then echo "ok   concurrency/$name"; return; fi
  fails=$((fails + 1)); echo "FAIL concurrency/$name"
  [ -n "$detail" ] && echo "     $detail"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/imps-concurrency.XXXXXX")" || exit 2
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# A real origin, so remote-based disambiguation exercises its actual code path.
git init -q --bare "$TMP/origin.git" -b main
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
git -C "$TMP/repo" config user.email t@example.com
git -C "$TMP/repo" config user.name  t
echo seed > "$TMP/repo/seed.txt"
git -C "$TMP/repo" add seed.txt
git -C "$TMP/repo" commit -qm seed
git -C "$TMP/repo" push -q origin main

export IMPS_RUNS_DIR="$TMP/runs"
mkdir -p "$IMPS_RUNS_DIR"

slug_in() { (cd "$1" && "$PATHS_SH" --slug --no-migrate); }

# --- A: distinct slugs per worktree ----------------------------------------
(cd "$TMP/repo" && "$WT_SH" new alpha >/dev/null 2>&1)
(cd "$TMP/repo" && "$WT_SH" new beta  >/dev/null 2>&1)

main_slug=$(slug_in "$TMP/repo")
alpha_slug=$(slug_in "$TMP/repo.imps/alpha")
beta_slug=$(slug_in "$TMP/repo.imps/beta")

assert "worktrees-get-distinct-slugs" \
  "$([ -n "$alpha_slug" ] && [ -n "$beta_slug" ] && [ "$alpha_slug" != "$beta_slug" ] && [ "$alpha_slug" != "$main_slug" ] && echo 1 || echo 0)" \
  "main=$main_slug alpha=$alpha_slug beta=$beta_slug"

assert "main-checkout-slug-shape" \
  "$([ "$main_slug" = "$(basename "$(dirname "$TMP/repo")")_origin__repo" ] || case "$main_slug" in *__repo) echo 1;; *) echo 0;; esac)" \
  "expected an owner_repo__repo form, got: $main_slug"

# --- B: CLAUDE_PROJECT_DIR must not collapse worktree identity --------------
# The regression this guards: preferring CLAUDE_PROJECT_DIR over the git working tree.
# A harness that sets it to the main checkout would give every worktree the main slug,
# silently pointing every concurrent run at one state file.
hijacked=$(cd "$TMP/repo.imps/alpha" && CLAUDE_PROJECT_DIR="$TMP/repo" "$PATHS_SH" --slug --no-migrate)
assert "claude-project-dir-does-not-collapse-slug" \
  "$([ "$hijacked" = "$alpha_slug" ] && echo 1 || echo 0)" \
  "with CLAUDE_PROJECT_DIR=<main checkout>, alpha's slug became '$hijacked' (want '$alpha_slug')"

# --- C: eval-safety with spaces in the path --------------------------------
spacey="$TMP/dir with space"
mkdir -p "$spacey"
git init -q "$spacey/repo"
( cd "$spacey/repo" || exit 1
  eval "$("$PATHS_SH" --no-migrate)"
  # STATE_PATH must round-trip intact; an unquoted emit would split on the space and
  # leave STATE_PATH holding only the first word.
  case "$STATE_PATH" in
    */runs/*repo.json) echo "SPACE_OK" ;;
    *) echo "SPACE_BAD:$STATE_PATH" ;;
  esac
) > "$TMP/space.out" 2>&1
assert "eval-survives-spaces-in-path" \
  "$(grep -q '^SPACE_OK$' "$TMP/space.out" && echo 1 || echo 0)" \
  "$(cat "$TMP/space.out")"

# --- D: remove refuses while a run is live ---------------------------------
printf '{"phase":"wrangler_running"}\n' > "$IMPS_RUNS_DIR/$alpha_slug.json"
live_out=$( (cd "$TMP/repo" && "$WT_SH" remove alpha) 2>&1 ); live_rc=$?
assert "remove-refuses-while-run-is-live" \
  "$([ "$live_rc" -ne 0 ] && [ -d "$TMP/repo.imps/alpha" ] && echo 1 || echo 0)" \
  "rc=$live_rc out=$live_out"

rm -f "$IMPS_RUNS_DIR/$alpha_slug.json"
idle_out=$( (cd "$TMP/repo" && "$WT_SH" remove alpha) 2>&1 ); idle_rc=$?
assert "remove-succeeds-when-idle" \
  "$([ "$idle_rc" -eq 0 ] && [ ! -d "$TMP/repo.imps/alpha" ] && echo 1 || echo 0)" \
  "rc=$idle_rc out=$idle_out"

# --- E: concurrent learnings appends do not lose updates -------------------
# The user-scoped learnings file is the one mutable file concurrent runs truly share.
N=12
( cd "$TMP/repo" || exit 1
  for i in $(seq 1 $N); do
    "$LEARN_SH" --scope project --heading "run-$i" --rule "rule-from-run-$i" >/dev/null 2>&1 &
  done
  wait
)
learn="$TMP/repo/.claude/imps/learnings.md"
landed=$(grep -c '^- rule-from-run-' "$learn" 2>/dev/null || echo 0)
assert "concurrent-learnings-appends-all-land" \
  "$([ "$landed" -eq "$N" ] && echo 1 || echo 0)" \
  "$landed/$N rules landed in $learn"
assert "learnings-lock-released" \
  "$([ ! -d "$learn.lock" ] && echo 1 || echo 0)" \
  "lock directory left behind: $learn.lock"

if [ "$fails" -eq 0 ]; then
  echo "concurrency: all assertions passed"
  exit 0
fi
echo "concurrency: $fails assertion(s) failed" >&2
exit 1
