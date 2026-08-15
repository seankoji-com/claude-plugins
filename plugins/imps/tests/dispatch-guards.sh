#!/usr/bin/env bash
# dispatch-guards.sh — proves the guards that make an opencode-dispatch.sh
# status:"pass" mean something, and the durability that makes a pass worth
# having.
#
# Sibling of worktree-shape.sh, which owns the --worktree shape gate; this file
# owns everything else that can be checked without a sandbox. Costs nothing —
# no model calls, no network, no credentials, no macOS-only Seatbelt — so it
# runs on any platform including ubuntu-latest CI.
#
# What it covers, and why each is here rather than "untestable":
#
#   1. Every new bad_arguments path (--expect-oracle, --result-branch: bad
#      name, and collision). All of them abort BEFORE the auth_missing check,
#      so they are reachable for free on a host with no opencode credentials.
#   2. create_result_ref, against a real scratch linked worktree — including
#      DELETING the worktree and its branches, expiring the reflogs, running
#      `gc --prune=now`, and asserting the commit is STILL reachable. That is
#      the whole durability claim, proven rather than eyeballed. A dangling
#      commit created alongside it is the control: if gc doesn't prune that,
#      the survival assertion is vacuous and this test says so.
#   3. restore_worktree_clean + stage_model_changes, i.e. the no_model_changes
#      guard. Pure git plumbing, so the "a green oracle over an untouched
#      worktree is not a pass" claim needs no paid dispatch to verify.
#   4. Contract key parity between emit_contract's jq branch and its
#      hand-written no-jq fallback literal. That literal drifts silently — the
#      unit harness structurally cannot reach it (HAVE_JQ comes from
#      `command -v jq` at source time, so it is always 1 in CI, and the harness
#      cannot set env vars), which is exactly why the check lives here.
#
# COVERAGE, stated precisely — three of opencode-dispatch.sh's guards need the
# macOS sandbox and a real model attempt for end-to-end proof: attempt_timeout,
# oracle_preflight_mismatch, and no_model_changes. What is closed here for free is
# their DECISION LOGIC — expect_oracle_verdict (via its expect_oracle_verdict_probe
# fixture vehicle, the harness only fixtures one-arg functions) / classify_oracle_state
# as unit fixtures, restore_worktree_clean / stage_model_changes against a real scratch
# worktree. The CALL SITES that wire those decisions into an abort
# (opencode-dispatch.sh's preflight block and its oracle-green block) sit behind
# run_oracle_sandboxed -> sandbox-wrap.sh -> Seatbelt, so they are reviewed, not
# executed. The post-merge validation round ticks all three.
#
# Do not read "the helper is tested" as "the guard is tested". An earlier draft of
# this header claimed only attempt_timeout was sandbox-gated, and two Definition-
# of-Done items were ticked on that claim.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DISPATCH="$PLUGIN_ROOT/scripts/opencode-dispatch.sh"

command -v git >/dev/null 2>&1 || { echo "dispatch-guards: git is required" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "dispatch-guards: jq is required"  >&2; exit 2; }

fails=0
assert() { # assert <name> <ok:0|1> [detail]
  if [ "$2" = 1 ]; then
    printf 'ok   dispatch-guards/%s\n' "$1"
  else
    printf 'FAIL dispatch-guards/%s\n' "$1"
    [ -n "${3:-}" ] && printf '     %s\n' "$3" | tail -n 5
    fails=$((fails + 1))
  fi
}
assert_eq() { # assert_eq <name> <actual> <want>
  if [ "$2" = "$3" ]; then assert "$1" 1; else assert "$1" 0 "got [$2] want [$3]"; fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM

# Neutralise the operator's own git setup for every scratch repo below. Two
# concrete failures this prevents, both of which read as green on CI and red
# only on a real dev box:
#   * commit signing (this maintainer's ~/.gitconfig signs via the 1Password
#     SSH agent) — same trap worktree-shape.sh documents.
#   * core.excludesFile — a global ~/.gitignore_global with a `__pycache__/`
#     entry (verified present on this maintainer's machine) makes an
#     "untracked byproduct" fixture silently ignored, so `git clean` spares it
#     and the restore_worktree_clean assertion below tests nothing.
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig"
: >"$GIT_CONFIG_GLOBAL"
export HOME="$SCRATCH/home"
mkdir -p "$HOME"

git_c() { # git_c <dir> <args...> — a scratch-repo git with identity pinned
  local d="$1"; shift
  git -C "$d" -c user.email=a@b -c user.name=a -c commit.gpgsign=false "$@"
}

# Run a helper from opencode-dispatch.sh without a dispatch. The script saves
# real stdout on fd 3 and redirects its own fd 1 to stderr at source time (its
# "the final line of stdout is always the contract" guarantee), so fd 1 has to
# be restored from fd 3 before a helper's stdout is capturable here.
# shellcheck source=/dev/null  # $DISPATCH is resolved at runtime
src() { __SOURCED__=1; . "$DISPATCH"; exec 1>&3; }

# ---------------------------------------------------------------------------
# 1. bad_arguments paths — all free, all before auth_missing
# ---------------------------------------------------------------------------
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
echo "dispatch-guards: stub opencode should never actually run" >&2
exit 1
EOF
chmod +x "$STUB_BIN/opencode"

PROMPT_FILE="$SCRATCH/prompt.txt"
echo "prompt" >"$PROMPT_FILE"
DISPATCH_ERR="$SCRATCH/dispatch-stderr"

# A genuine linked worktree, so these cases fail on the flag under test and not
# on the shape gate worktree-shape.sh already owns.
ARG_BASE="$SCRATCH/arg-base"
ARG_LINKED="$SCRATCH/arg-linked"
git init -q "$ARG_BASE"
git_c "$ARG_BASE" commit -q --allow-empty -m init
git_c "$ARG_BASE" worktree add -q "$ARG_LINKED" -b guards-existing-branch >/dev/null 2>&1

run_dispatch() { # run_dispatch <extra args...>
  PATH="$STUB_BIN:$PATH" bash "$DISPATCH" \
    --worktree "$ARG_LINKED" --prompt-file "$PROMPT_FILE" --oracle true "$@" 2>"$DISPATCH_ERR"
}
reason_of() { printf '%s' "$1" | jq -r '.abort_reason // "null"' 2>/dev/null; }

out="$(run_dispatch --expect-oracle sideways)"
assert_eq "expect-oracle-rejects-unknown-word" "$(reason_of "$out")" "bad_arguments"

out="$(run_dispatch --expect-oracle RED)"
assert_eq "expect-oracle-is-case-sensitive" "$(reason_of "$out")" "bad_arguments"

# `--result-branch ''` must be reported, not silently read as "no branch
# wanted" — the unset default is the empty string too, so this is the one case
# a naive `-n` guard gets wrong.
out="$(run_dispatch --result-branch "")"
assert_eq "result-branch-rejects-empty" "$(reason_of "$out")" "bad_arguments"

# git check-ref-format ACCEPTS refs/heads/-x, so this is not redundant with it.
out="$(run_dispatch --result-branch "-x")"
assert_eq "result-branch-rejects-leading-dash" "$(reason_of "$out")" "bad_arguments"

out="$(run_dispatch --result-branch "refs/heads/x")"
assert_eq "result-branch-rejects-refs-prefix" "$(reason_of "$out")" "bad_arguments"

out="$(run_dispatch --result-branch "has space")"
assert_eq "result-branch-rejects-malformed" "$(reason_of "$out")" "bad_arguments"

# Collision: the linked worktree above is checked out on this branch.
out="$(run_dispatch --result-branch "guards-existing-branch")"
assert_eq "result-branch-rejects-collision" "$(reason_of "$out")" "bad_arguments"

# Positive control. Asserted as "did NOT abort with bad_arguments" rather than
# pinning the exact downstream slug, for the same reason worktree-shape.sh
# does: every rejection these new flags can produce is bad_arguments, so this
# still catches the only regression it exists for (valid flags wrongly
# rejected) without breaking when an unrelated check is added downstream.
out="$(run_dispatch --expect-oracle red --result-branch "guards-fresh-name")"
reason="$(reason_of "$out")"
if [ "$reason" = "bad_arguments" ]; then
  assert "valid-new-flags-pass-argument-gate" 0 \
    "valid --expect-oracle/--result-branch rejected: raw=$out stderr=$(cat "$DISPATCH_ERR" 2>/dev/null)"
else
  assert "valid-new-flags-pass-argument-gate" 1
fi

# ---------------------------------------------------------------------------
# 1b. --engine auto|opencode|agy — issue #96's engine-selection flag. Full
#     agy execution is out of scope (no sandboxed agy support exists yet), so
#     an explicit `--engine agy` must abort immediately and distinctly rather
#     than silently falling through to opencode or being rejected as an
#     unrecognized argument.
# ---------------------------------------------------------------------------
out="$(run_dispatch --engine bogus)"
assert_eq "engine-rejects-unknown-word" "$(reason_of "$out")" "bad_arguments"

out="$(run_dispatch --engine agy)"
assert_eq "engine-agy-is-unsupported" "$(reason_of "$out")" "engine_unsupported"

# Positive controls, same style as the --expect-oracle/--result-branch check
# above: assert "did not reject at the argument gate" rather than pinning the
# exact downstream slug, so this doesn't break when an unrelated check is
# added further down the same path.
for engine_case in "--engine opencode" ""; do
  # shellcheck disable=SC2086 # intentional: "" must expand to zero args, not one empty arg
  out="$(run_dispatch $engine_case)"
  reason="$(reason_of "$out")"
  if [ "$reason" = "bad_arguments" ] || [ "$reason" = "engine_unsupported" ]; then
    assert "engine-valid-value-passes-argument-gate: [$engine_case]" 0 \
      "raw=$out stderr=$(cat "$DISPATCH_ERR" 2>/dev/null)"
  else
    assert "engine-valid-value-passes-argument-gate: [$engine_case]" 1
  fi
done

# ---------------------------------------------------------------------------
# 2. create_result_ref — the durability claim (DoD: the commit survives
#    deletion of the dispatch worktree)
# ---------------------------------------------------------------------------
REF_BASE="$SCRATCH/ref-base"
REF_LINKED="$SCRATCH/ref-linked"
git init -q "$REF_BASE"
git_c "$REF_BASE" commit -q --allow-empty -m init
git_c "$REF_BASE" worktree add -q "$REF_LINKED" -b guards-dispatch-wt >/dev/null 2>&1
echo "model work" >"$REF_LINKED/work.txt"
git_c "$REF_LINKED" add -A
git_c "$REF_LINKED" commit -q -m "harness commit"
SHA="$(git -C "$REF_LINKED" rev-parse HEAD)"
AUTO_REF="refs/imps/dispatch/19700101T000000Z-$(printf '%s' "$SHA" | cut -c1-12)"

ref_out="$( ( src; create_result_ref "$REF_LINKED" "$SHA" "$AUTO_REF" "guards-result" ) 2>&1 )"
ref_rc=$?
assert "create-result-ref-succeeds" "$([ "$ref_rc" -eq 0 ] && echo 1 || echo 0)" "rc=$ref_rc out=$ref_out"
assert_eq "auto-ref-points-at-commit" "$(git -C "$REF_BASE" rev-parse --verify -q "$AUTO_REF" 2>/dev/null)" "$SHA"
assert_eq "named-branch-points-at-commit" "$(git -C "$REF_BASE" rev-parse --verify -q "refs/heads/guards-result" 2>/dev/null)" "$SHA"

# refs/imps/ deliberately stays out of `git branch` (and therefore out of
# branch-pruning tooling) — that is why the auto-ref lives there and not in
# refs/heads/.
if git -C "$REF_BASE" branch --list --all 2>/dev/null | grep -q 'imps/dispatch'; then
  assert "auto-ref-invisible-to-git-branch" 0 "$(git -C "$REF_BASE" branch --list --all)"
else
  assert "auto-ref-invisible-to-git-branch" 1
fi

# The named branch is created with an atomic CAS (empty oldvalue == "must not
# already exist"), so a second attempt at the same name must FAIL rather than
# clobber. A check-then-write would race here.
ref_out2="$( ( src; create_result_ref "$REF_LINKED" "$SHA" "${AUTO_REF}-again" "guards-result" ) 2>&1 )"
ref_rc2=$?
assert "named-branch-cas-refuses-existing" "$([ "$ref_rc2" -ne 0 ] && echo 1 || echo 0)" \
  "expected non-zero, got rc=$ref_rc2 out=$ref_out2"
# ...and the auto-ref still landed first, so a branch collision never costs the
# operator the work itself.
assert_eq "auto-ref-written-before-branch-cas" \
  "$(git -C "$REF_BASE" rev-parse --verify -q "${AUTO_REF}-again" 2>/dev/null)" "$SHA"

# A commit with no ref at all — the control. If gc below does not prune this,
# then "the harness commit survived" proves nothing.
DANGLING="$(git_c "$REF_BASE" commit-tree "$SHA^{tree}" -p "$SHA" -m dangling 2>/dev/null)"

# Now destroy every ordinary way of reaching the harness commit: remove the
# dispatch worktree, delete its branch, delete the named result branch, expire
# the reflogs, and gc. Only the refs/imps/ auto-ref is left holding it.
git -C "$REF_BASE" worktree remove --force "$REF_LINKED" >/dev/null 2>&1
git -C "$REF_BASE" branch -D guards-dispatch-wt >/dev/null 2>&1
git -C "$REF_BASE" branch -D guards-result >/dev/null 2>&1
git -C "$REF_BASE" update-ref -d "${AUTO_REF}-again" >/dev/null 2>&1
git -C "$REF_BASE" reflog expire --expire=now --expire-unreachable=now --all >/dev/null 2>&1
git -C "$REF_BASE" gc --prune=now --quiet >/dev/null 2>&1

if git -C "$REF_BASE" cat-file -e "$DANGLING^{commit}" 2>/dev/null; then
  assert "gc-control-prunes-unreferenced-commit" 0 \
    "gc did not prune an unreferenced commit — the survival assertion below would be vacuous"
else
  assert "gc-control-prunes-unreferenced-commit" 1
fi

worktree_gone=1
[ -e "$REF_LINKED" ] && worktree_gone=0
assert "dispatch-worktree-actually-removed" "$worktree_gone" "$REF_LINKED still exists"

if git -C "$REF_BASE" cat-file -e "$SHA^{commit}" 2>/dev/null; then
  assert "commit-survives-worktree-deletion-and-gc" 1
else
  assert "commit-survives-worktree-deletion-and-gc" 0 "$SHA is gone after gc --prune=now"
fi
assert_eq "auto-ref-still-resolves-after-gc" \
  "$(git -C "$REF_BASE" rev-parse --verify -q "$AUTO_REF" 2>/dev/null)" "$SHA"

# ---------------------------------------------------------------------------
# 3. restore_worktree_clean + stage_model_changes — the no_model_changes guard
# ---------------------------------------------------------------------------
CLN_BASE="$SCRATCH/clean-base"
CLN_LINKED="$SCRATCH/clean-linked"
git init -q "$CLN_BASE"
echo "original" >"$CLN_BASE/tracked.txt"
git_c "$CLN_BASE" add -A
git_c "$CLN_BASE" commit -q -m init
git_c "$CLN_BASE" worktree add -q "$CLN_LINKED" -b guards-clean-wt >/dev/null 2>&1

# The shape a real dispatch is in immediately after its preflight oracle: the
# harness's own hardened config installed, plus whatever untracked byproduct
# the oracle wrote, plus (worst case) a tracked file the oracle rewrote.
echo '{"permission":{"external_directory":"deny"}}' >"$CLN_LINKED/opencode.json"
mkdir -p "$CLN_LINKED/oracle-byproduct"
echo "bytecode" >"$CLN_LINKED/oracle-byproduct/out.bin"
echo "clobbered by the oracle" >"$CLN_LINKED/tracked.txt"

( src; restore_worktree_clean "$CLN_LINKED" )
restore_rc=$?
assert "restore-reports-clean" "$([ "$restore_rc" -eq 0 ] && echo 1 || echo 0)" "rc=$restore_rc"
assert "restore-removes-oracle-byproduct" \
  "$([ ! -e "$CLN_LINKED/oracle-byproduct" ] && echo 1 || echo 0)" "byproduct dir survived the clean"
# Load-bearing: opencode.json carries permission.external_directory="deny", the
# containment the whole sandbox story rests on. Cleaning it away would silently
# uncontain the model on the very next attempt.
assert "restore-spares-opencode-json" \
  "$([ -f "$CLN_LINKED/opencode.json" ] && echo 1 || echo 0)" "opencode.json was removed by the clean"
assert_eq "restore-reverts-tracked-file" "$(cat "$CLN_LINKED/tracked.txt" 2>/dev/null)" "original"

# The actual no_model_changes decision: rc 0 == nothing staged.
( src; stage_model_changes "$CLN_LINKED" )
staged_rc=$?
assert "nothing-staged-when-model-did-nothing" "$([ "$staged_rc" -eq 0 ] && echo 1 || echo 0)" \
  "expected rc 0 (nothing staged), got $staged_rc: $(git -C "$CLN_LINKED" diff --cached --name-only)"

# ...and it must not fire on a genuine edit, or every real pass turns into a
# no_model_changes abort.
echo "a real fix" >>"$CLN_LINKED/tracked.txt"
( src; stage_model_changes "$CLN_LINKED" )
staged_rc2=$?
assert "something-staged-after-a-real-edit" "$([ "$staged_rc2" -ne 0 ] && echo 1 || echo 0)" \
  "expected non-zero (something staged), got $staged_rc2"

# ---------------------------------------------------------------------------
# 4. emit_contract key parity: jq branch vs the hand-written no-jq literal
# ---------------------------------------------------------------------------
# `env -i PATH= bash` cannot execute at all: env -i clears the environment,
# then `bash` is resolved against the now-empty PATH. An absolute interpreter
# is required, and the liveness precondition below matters just as much —
# without it a broken invocation makes this test compare two empty strings and
# pass vacuously.
nojq_line="$(env -i PATH= /bin/bash "$DISPATCH" --worktree /nonexistent 2>/dev/null | tail -n1)"
jq_line="$(PATH="$STUB_BIN:$PATH" bash "$DISPATCH" --worktree /nonexistent 2>/dev/null | tail -n1)"

if [ -z "$nojq_line" ]; then
  assert "no-jq-fallback-emits-a-line" 0 "no-jq path produced no contract line at all"
elif ! printf '%s' "$nojq_line" | jq -e . >/dev/null 2>&1; then
  assert "no-jq-fallback-emits-a-line" 0 "fallback line is not JSON: $nojq_line"
else
  assert "no-jq-fallback-emits-a-line" 1
fi
assert_eq "no-jq-fallback-is-the-jq_missing-path" \
  "$(printf '%s' "$nojq_line" | jq -r '.abort_reason // "null"' 2>/dev/null)" "jq_missing"
assert "jq-branch-emits-a-line" \
  "$(printf '%s' "$jq_line" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)" "not JSON: $jq_line"

# Explicit, so parity cannot be satisfied by BOTH branches omitting a field.
for key in commit_sha oracle_start_state; do
  assert_eq "jq-branch-has-$key" \
    "$(printf '%s' "$jq_line" | jq -r "has(\"$key\")" 2>/dev/null)" "true"
done

nojq_keys="$(printf '%s' "$nojq_line" | jq -S -r 'keys | join(",")' 2>/dev/null)"
jq_keys="$(printf '%s' "$jq_line"   | jq -S -r 'keys | join(",")' 2>/dev/null)"
if [ -z "$jq_keys" ]; then
  assert "contract-key-parity" 0 "could not read keys from the jq-branch line: $jq_line"
else
  assert_eq "contract-key-parity" "$nojq_keys" "$jq_keys"
fi

echo "---"
if [ "$fails" -ne 0 ]; then
  echo "dispatch-guards: $fails assertion(s) failed" >&2
  exit 1
fi
echo "dispatch-guards: all assertions passed"
