#!/usr/bin/env bash
# worktree-shape.sh — proves opencode-dispatch.sh's --worktree precondition
# (the gitdir must be a strict subpath of the git common dir, i.e. a genuine
# LINKED worktree) actually rejects every shape it's supposed to, not just the
# one shape a hand-run repro happened to try.
#
# Costs nothing (no model calls, no network, no macOS-only sandbox), so unlike
# sandbox-smoke.sh/e2e.sh this runs on any platform including ubuntu-latest CI.
#
# Why this exists: three review rounds in a row shipped a "verified live"
# fix for this exact gate that a later round found a live-reproducible gap
# in (a proxy check that two different `.git`-file shapes still slipped
# past, degenerating the harness's own pointer snapshot to a constant
# "MISSING" line). A fix "verified live" by one throwaway repro and never
# checked in as a test is a fix that can silently regress on the very next
# edit to this file — this is the regression net for that gate specifically.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DISPATCH="$PLUGIN_ROOT/scripts/opencode-dispatch.sh"

command -v git >/dev/null 2>&1 || { echo "worktree-shape: git is required" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "worktree-shape: jq is required"  >&2; exit 2; }

fails=0
assert() { # assert <name> <ok:0|1> [detail]
  if [ "$2" = 1 ]; then
    printf 'ok   worktree-shape/%s\n' "$1"
  else
    printf 'FAIL worktree-shape/%s\n' "$1"
    [ -n "${3:-}" ] && printf '     %s\n' "$3" | tail -n 5
    fails=$((fails + 1))
  fi
}
assert_reason() { # assert_reason <name> <actual reason> <want reason> <raw output>
  if [ "$2" = "$3" ]; then
    assert "$1" 1
  else
    assert "$1" 0 "abort_reason=$2 (want $3) raw=$4"
  fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM

# A stub `opencode` on PATH so the script's own `command -v opencode` check
# (which runs BEFORE the --worktree checks this script targets) doesn't abort
# first with opencode_missing on a host without the real binary installed —
# it's never actually invoked, since every case here aborts before that point.
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
echo "worktree-shape: stub opencode should never actually run" >&2
exit 1
EOF
chmod +x "$STUB_BIN/opencode"

PROMPT_FILE="$SCRATCH/prompt.txt"
echo "prompt" >"$PROMPT_FILE"

run_dispatch() { # run_dispatch <worktree>
  PATH="$STUB_BIN:$PATH" HOME="$SCRATCH/home-$$" \
    bash "$DISPATCH" --worktree "$1" --prompt-file "$PROMPT_FILE" --oracle true 2>/dev/null
}

# --- Shape 1: a MAIN worktree (.git is a directory) ---------------------
main_wt="$SCRATCH/main"
git init -q "$main_wt"
git -C "$main_wt" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
out="$(run_dispatch "$main_wt")"
reason="$(printf '%s' "$out" | jq -r '.abort_reason // "null"' 2>/dev/null)"
assert_reason "main-worktree-rejected" "$reason" "bad_arguments" "$out"

# --- Shape 2: `git init --separate-git-dir` (a .git FILE, but its gitdir
#     equals the common dir exactly — not a subpath — same as shape 1's
#     underlying invariant, just via a different .git-is-a-file route) ------
sgd_wt="$SCRATCH/sgd"
sgd_meta="$SCRATCH/sgd-meta"
git init -q --separate-git-dir="$sgd_meta" "$sgd_wt"
git -C "$sgd_wt" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
out="$(run_dispatch "$sgd_wt")"
reason="$(printf '%s' "$out" | jq -r '.abort_reason // "null"' 2>/dev/null)"
assert_reason "separate-git-dir-rejected" "$reason" "bad_arguments" "$out"

# --- Shape 3: a submodule's working directory (also a .git FILE whose
#     gitdir equals its own common dir, under the PARENT's .git/modules/) ---
sub_parent="$SCRATCH/sub-parent"
sub_child="$SCRATCH/sub-child"
git init -q "$sub_child"
git -C "$sub_child" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
git init -q "$sub_parent"
git -C "$sub_parent" -c protocol.file.allow=always -c user.email=a@b -c user.name=a \
  submodule add -q "$sub_child" kid >/dev/null 2>&1
git -C "$sub_parent" -c user.email=a@b -c user.name=a commit -q -m "add submodule" >/dev/null 2>&1
out="$(run_dispatch "$sub_parent/kid")"
reason="$(printf '%s' "$out" | jq -r '.abort_reason // "null"' 2>/dev/null)"
assert_reason "submodule-rejected" "$reason" "bad_arguments" "$out"

# --- Positive control: a GENUINE linked worktree must clear this gate ------
# (and then fail downstream for an entirely different, expected reason —
# auth_missing, since HOME points at a fresh scratch dir with no opencode
# credentials — proving it actually passed the worktree-shape check rather
# than the whole script being broken in some way that accepts everything).
lw_base="$SCRATCH/lw-base"
lw_linked="$SCRATCH/lw-linked"
git init -q "$lw_base"
git -C "$lw_base" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
git -C "$lw_base" worktree add -q "$lw_linked" -b worktree-shape-linked >/dev/null 2>&1
out="$(run_dispatch "$lw_linked")"
reason="$(printf '%s' "$out" | jq -r '.abort_reason // "null"' 2>/dev/null)"
assert_reason "linked-worktree-passes-gate" "$reason" "auth_missing" "$out"

echo "---"
if [ "$fails" -ne 0 ]; then
  echo "worktree-shape: $fails assertion(s) failed" >&2
  exit 1
fi
echo "worktree-shape: all assertions passed"
