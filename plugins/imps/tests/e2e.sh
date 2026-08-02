#!/usr/bin/env bash
# e2e.sh — end-to-end proof that opencode-dispatch.sh does what it claims:
# a cheap open model, inside the sandbox, makes a failing fixture test pass;
# the harness commits deterministically and emits the JSON contract line.
#
#   IMPS_OPENCODE_E2E=1 bash plugins/imps/tests/e2e.sh [fixture-name]
#
# This SPENDS REAL MONEY (a few cents) and needs opencode credentials, so it
# skips — exit 77, the conventional "skipped" status — unless all four hold:
#   * uname -s is Darwin              (keeps ubuntu-latest CI green)
#   * opencode is on PATH
#   * ~/.local/share/opencode/auth.json exists
#   * IMPS_OPENCODE_E2E=1             (stops a maintainer on a Mac running
#                                      tests/run.sh from being silently billed)
#
# Assertions are about the HARNESS, not the model: a fixture that fails because
# the model is weak is not a harness bug. Hence deliberately trivial fixtures.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DISPATCH="$PLUGIN_ROOT/scripts/opencode-dispatch.sh"
SMOKE="$PLUGIN_ROOT/scripts/sandbox-smoke.sh"
FIXTURE_NAME="${1:-${IMPS_OPENCODE_E2E_FIXTURE:-fx-add-two}}"
FIXTURE="$TESTS_DIR/fixtures/$FIXTURE_NAME"
MODEL="${IMPS_OPENCODE_E2E_MODEL:-opencode-go/deepseek-v4-flash}"

skip() { echo "skip e2e: $*"; exit 77; }

[ "$(uname -s)" = "Darwin" ] || skip "not Darwin (uname -s = $(uname -s))"
command -v opencode >/dev/null 2>&1 || skip "opencode is not on PATH"
[ -f "$HOME/.local/share/opencode/auth.json" ] || skip "no opencode credentials at ~/.local/share/opencode/auth.json"
[ "${IMPS_OPENCODE_E2E:-}" = "1" ] || skip "IMPS_OPENCODE_E2E != 1 (this test spends real money)"
[ -d "$FIXTURE" ] || { echo "e2e: no such fixture: $FIXTURE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "e2e: jq is required" >&2; exit 1; }

fails=0
assert() { # assert <name> <ok:0|1> [detail]
  if [ "$2" = 1 ]; then
    printf 'ok   e2e/%s\n' "$1"
  else
    printf 'FAIL e2e/%s\n' "$1"
    [ -n "${3:-}" ] && printf '     %s\n' "$3"
    fails=$((fails + 1))
  fi
}

# --- 1. escape probes -------------------------------------------------------
# The sandbox assertions live in sandbox-smoke.sh so they are exercised by the
# free test too; re-running them here ties the E2E's DoD line to real output.
echo "== sandbox smoke =="
smoke_out="$(bash "$SMOKE" 2>&1)"
smoke_rc=$?
printf '%s\n' "$smoke_out"
[ "$smoke_rc" -eq 77 ] && skip "sandbox cannot be applied here (nested sandbox); run this unsandboxed"
assert "escape-probes-denied" "$([ "$smoke_rc" -eq 0 ] && echo 1 || echo 0)" "sandbox-smoke.sh exited $smoke_rc"
[ "$smoke_rc" -eq 0 ] || { echo "e2e: aborting before spending money — the sandbox is not sound" >&2; exit 1; }

# --- 2. scratch worktree ----------------------------------------------------
# A genuine LINKED worktree off the repo this test is actually running inside
# (not a synthetic throwaway repo) — real dispatch always targets a linked
# worktree of a real, substantial project, and the two are not interchangeable
# under the sandbox: identical sandbox-wrap.sh invocations succeed against a
# real repo's worktree and fail against a minimal/near-empty repo's worktree
# (single commit, no tracked files) with opencode's generic "An unknown error
# occurred (Unexpected)" and ZERO Seatbelt denials in the kernel log — not a
# permissions gap, and confirmed independent of both /tmp-vs-$TMPDIR placement
# and a configured remote. Root cause not further identified (smells like an
# opencode-side quirk with near-empty repos); matching real dispatch's shape
# — a worktree of whatever real repo the harness is invoked from — sidesteps
# it rather than chasing it further, and is also simply more representative.
BASE="$(cd "$PLUGIN_ROOT" && git rev-parse --show-toplevel)" || exit 1
TMP_CANON="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
# mktemp -u prints a path without creating it — a classic TOCTOU: a stale or
# squatted directory from a crashed prior run can already occupy that path by
# the time `git worktree add` gets to it, silently changing behavior. `mktemp
# -d` claims the path atomically; `git worktree add` then wants the target to
# NOT exist, so remove the (empty, just-created) directory immediately before
# handing the now-reserved-in-name-only path to it — same TOCTOU window as
# before, but now bounded to a single, immediate rmdir instead of the whole
# rest of this script's runtime.
WT="$(mktemp -d "$TMP_CANON/imps-e2e-wt.XXXXXX")" || exit 1
rmdir "$WT" || exit 1
BRANCH="imps-e2e-fixture-$$"
RESULT_BRANCH="imps-e2e-result-$$"
# Snapshot the durability namespace BEFORE dispatch. The harness now writes
# refs/imps/dispatch/<ts>-<sha> unconditionally on every successful commit, so
# without this the E2E leaks one permanent ref into the maintainer's real repo
# per run. Diffing before/after is what makes cleanup exact — deleting the
# whole namespace would destroy refs from real dispatches, which is precisely
# the work this ref exists to protect.
PRE_DISPATCH_REFS="$(git -C "$BASE" for-each-ref --format='%(refname)' 'refs/imps/dispatch/*' 2>/dev/null)"
cleanup() {
  if [ "${IMPS_KEEP_E2E_WORKTREE:-}" = "1" ]; then return; fi
  git -C "$BASE" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$BASE" branch -D "$BRANCH" >/dev/null 2>&1
  git -C "$BASE" branch -D "$RESULT_BRANCH" >/dev/null 2>&1
  local ref
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf '%s\n' "$PRE_DISPATCH_REFS" | grep -qxF "$ref" && continue
    git -C "$BASE" update-ref -d "$ref" >/dev/null 2>&1
  done <<EOF
$(git -C "$BASE" for-each-ref --format='%(refname)' 'refs/imps/dispatch/*' 2>/dev/null)
EOF
}
trap cleanup EXIT HUP INT TERM

# Unchecked, this cascades into confusing secondary failures (cp into a
# nonexistent dir, git errors) instead of one clear "worktree add failed"
# message — e.g. a leftover branch/worktree from a killed prior run.
if ! git -C "$BASE" worktree add -q -b "$BRANCH" "$WT" HEAD; then
  echo "e2e: git worktree add failed for $WT (branch $BRANCH) — a prior run may have left stale state" >&2
  exit 1
fi

for f in "$FIXTURE"/*; do
  case "$(basename "$f")" in
    fx-prompt.md|fx-oracle) continue ;;
  esac
  cp "$f" "$WT/"
done

git -C "$WT" -c user.name=imps-fixture -c user.email=imps@local add -A
git -C "$WT" -c user.name=imps-fixture -c user.email=imps@local \
  commit -q -m "fixture: $FIXTURE_NAME baseline" --no-gpg-sign
BASE_COMMITS="$(git -C "$WT" rev-list --count HEAD)"

ORACLE="$(cat "$FIXTURE/fx-oracle")"

# Sanity: the fixture must actually be failing to start with, or a "pass" proves
# nothing at all.
( cd "$WT" && eval "$ORACLE" ) >/dev/null 2>&1
baseline_rc=$?
assert "fixture-starts-red" "$([ "$baseline_rc" -ne 0 ] && echo 1 || echo 0)" "oracle already passes before dispatch"

# --- 3. dispatch ------------------------------------------------------------
echo "== dispatch (model=$MODEL, fixture=$FIXTURE_NAME) =="
err="$(mktemp "$TMP_CANON/imps-e2e-err.XXXXXX")"
# AUDIT_LOG_FILE redirected to a scratch file, not the real ~/.claude/audit.jsonl:
# every E2E run — trivial fixtures, deliberately fast first-pass — would
# otherwise land in the same log the measurement protocol reads to decide
# /imps:go, with no marker distinguishing a fixture run from a real hand-routed
# task. Confirmed as a real, already-present pollution source during review,
# not a hypothetical one.
# --oracle-guard '*test*' matches every bundled fixture's own test-file naming
# convention (fx_*_test.py, fx-*-test.sh) — demonstrates oracle_files_modified
# staying null on a genuine fix, not just documents the flag exists.
out="$(AUDIT_LOG_FILE="$TMP_CANON/imps-e2e-audit.jsonl" bash "$DISPATCH" \
        --worktree "$WT" \
        --prompt-file "$FIXTURE/fx-prompt.md" \
        --oracle "$ORACLE" \
        --model "$MODEL" \
        --max-attempts "${IMPS_OPENCODE_E2E_ATTEMPTS:-3}" \
        --attempt-timeout "${IMPS_OPENCODE_E2E_ATTEMPT_TIMEOUT:-90}" \
        --oracle-timeout "${IMPS_OPENCODE_E2E_ORACLE_TIMEOUT:-60}" \
        --expect-oracle red \
        --result-branch "$RESULT_BRANCH" \
        --oracle-guard '*test*' 2>"$err")"
dispatch_rc=$?
sed 's/^/  | /' "$err" >&2
rm -f "$err"

CONTRACT="$(printf '%s\n' "$out" | tail -n 1)"
echo "contract: $CONTRACT"

if printf '%s' "$CONTRACT" | jq -e . >/dev/null 2>&1; then
  assert "contract-line-parses" 1
else
  assert "contract-line-parses" 0 "final stdout line is not JSON: $CONTRACT"
fi

has_keys="$(printf '%s' "$CONTRACT" | jq -r '
  [has("status"), has("attempts"), has("session_id"), has("cost_usd"),
   has("oracle_exit"), has("log_path"), has("abort_reason"),
   has("oracle_files_modified"), has("commit_sha"),
   has("oracle_start_state")] | all' 2>/dev/null)"
assert "contract-has-all-keys" "$([ "$has_keys" = "true" ] && echo 1 || echo 0)" "$CONTRACT"

# Exactly one contract line, always — a second would break every consumer.
line_count="$(printf '%s\n' "$out" | grep -c '^{' || true)"
assert "contract-emitted-once" "$([ "$line_count" = "1" ] && echo 1 || echo 0)" "found $line_count JSON lines on stdout"

status="$(printf '%s' "$CONTRACT" | jq -r '.status // ""' 2>/dev/null)"
assert "status-pass" "$([ "$status" = "pass" ] && echo 1 || echo 0)" "status=$status (exit $dispatch_rc)"

assert "exit-zero-on-pass" "$([ "$dispatch_rc" -eq 0 ] && echo 1 || echo 0)" "dispatch exited $dispatch_rc"

# --- 3b. the two new trust/durability fields --------------------------------
# `has()` above only proves the KEYS exist; a field that is null on every run
# would satisfy it forever. These check the values, and only on a pass — on a
# failure both are legitimately null.
oracle_start_state="$(printf '%s' "$CONTRACT" | jq -r '.oracle_start_state // "null"' 2>/dev/null)"
commit_sha="$(printf '%s' "$CONTRACT" | jq -r '.commit_sha // "null"' 2>/dev/null)"

# Deliberately NOT a replacement for the independent `fixture-starts-red` probe
# above: that one runs the oracle directly, this one reads what the harness
# measured through its own sandboxed preflight. Two independent measurements of
# one fact is the entire point — they can only agree if both are honest, and a
# preflight that fabricated a state (e.g. classifying a timeout as red) shows up
# here as a disagreement rather than as a plausible-looking value.
if [ "$baseline_rc" -ne 0 ]; then
  assert "oracle-start-state-agrees-with-independent-probe" \
    "$([ "$oracle_start_state" = "red" ] && echo 1 || echo 0)" \
    "independent probe says red (rc=$baseline_rc) but the harness reported oracle_start_state=$oracle_start_state"
else
  assert "oracle-start-state-agrees-with-independent-probe" \
    "$([ "$oracle_start_state" = "green" ] && echo 1 || echo 0)" \
    "independent probe says green but the harness reported oracle_start_state=$oracle_start_state"
fi

if [ "$status" = "pass" ]; then
  assert "commit-sha-populated-on-pass" \
    "$([ "$commit_sha" != "null" ] && [ -n "$commit_sha" ] && echo 1 || echo 0)" \
    "commit_sha=$commit_sha on a status:\"pass\" run"
  # The durability claim, end to end: the ref the harness minted must exist in
  # the real repo and point at the commit it reported.
  auto_ref="$(git -C "$BASE" for-each-ref --format='%(refname) %(objectname)' 'refs/imps/dispatch/*' 2>/dev/null \
              | grep -F " $commit_sha" | head -n 1 | cut -d' ' -f1)"
  assert "durable-auto-ref-created" "$([ -n "$auto_ref" ] && echo 1 || echo 0)" \
    "no refs/imps/dispatch/* ref points at $commit_sha"
  assert "result-branch-created" \
    "$([ "$(git -C "$BASE" rev-parse --verify -q "refs/heads/$RESULT_BRANCH" 2>/dev/null)" = "$commit_sha" ] && echo 1 || echo 0)" \
    "refs/heads/$RESULT_BRANCH does not point at $commit_sha"
fi

# A genuine fix should never need to touch the fixture's own test file — if it
# did, oracle_files_modified would be non-null here, which would mean the
# model gamed its own oracle rather than fixing the code. This assertion is
# specifically about the measurement-integrity claim, not the sandbox.
guard_hit="$(printf '%s' "$CONTRACT" | jq -r '.oracle_files_modified // empty' 2>/dev/null)"
assert "oracle-guard-not-triggered" "$([ -z "$guard_hit" ] && echo 1 || echo 0)" "oracle_files_modified=$guard_hit — the model edited its own test file"

# log_path is null by default (the dispatch dir it lives in is deleted on
# exit unless IMPS_KEEP_DISPATCH_DIR=1, which this invocation doesn't set) —
# that is now the CORRECT value, not a gap. The only real invariant left to
# check is that it's never advertised as living inside the worktree (which
# would put it in the diff the next `git add -A` touches).
log_path="$(printf '%s' "$CONTRACT" | jq -r '.log_path // ""' 2>/dev/null)"
case "$log_path" in
  "$WT"/*) assert "log-path-not-inside-worktree" 0 "$log_path is inside the worktree" ;;
  *) assert "log-path-not-inside-worktree" 1 ;;
esac

# --- 4. the commit ----------------------------------------------------------
NOW_COMMITS="$(git -C "$WT" rev-list --count HEAD)"
assert "harness-made-a-commit" "$([ "$NOW_COMMITS" -gt "$BASE_COMMITS" ] && echo 1 || echo 0)" \
  "commits before=$BASE_COMMITS after=$NOW_COMMITS"
author="$(git -C "$WT" log -1 --format=%an)"
assert "commit-authored-by-harness" "$([ "$author" = "imps-opencode" ] && echo 1 || echo 0)" "author=$author"

# The most important check in this file: everything above confirms the
# contract SAYS "pass" and that a commit exists — never that the worktree
# actually satisfies the oracle. A harness bug that commits without a green
# oracle (or a model that stages files without truly fixing the bug) would
# sail through every assertion above undetected. Re-run the oracle
# independently of the contract's own self-report — but through the SAME
# sandbox boundary opencode-dispatch.sh uses, not bare `eval`: the worktree
# now contains the model's own edits, and executing them unsandboxed here
# would cross exactly the boundary this harness exists to enforce.
POST_GITMETA="$(git -C "$WT" rev-parse --git-common-dir)" || exit 1
case "$POST_GITMETA" in /*) ;; *) POST_GITMETA="$WT/$POST_GITMETA" ;; esac
POST_GITMETA="$(cd "$POST_GITMETA" && pwd -P)" || exit 1
POST_DATADIR="$(mktemp -d "$TMP_CANON/imps-e2e-postcheck.XXXXXX")" || exit 1
bash "$PLUGIN_ROOT/scripts/sandbox-wrap.sh" --worktree "$WT" --gitmeta "$POST_GITMETA" --datadir "$POST_DATADIR" \
  -- /bin/bash -c 'cd "$1" && eval "$2"' _ "$WT" "$ORACLE" >/dev/null 2>&1
oracle_post_rc=$?
rm -rf "$POST_DATADIR"
assert "oracle-green-post-dispatch" "$([ "$oracle_post_rc" -eq 0 ] && echo 1 || echo 0)" \
  "oracle exited $oracle_post_rc against the post-dispatch worktree (sandboxed)"

# The event-stream log must never end up in the diff.
if git -C "$WT" ls-files | grep -q '\.jsonl$'; then
  assert "no-log-committed" 0 "a .jsonl file was committed"
else
  assert "no-log-committed" 1
fi
# opencode.json is installed into the worktree but excluded from the index.
if git -C "$WT" ls-files | grep -qx 'opencode.json'; then
  assert "opencode-json-excluded" 0 "opencode.json was committed"
else
  assert "opencode-json-excluded" 1
fi

echo "== evidence =="
echo "contract: $CONTRACT"
git -C "$WT" log --oneline -1

echo "---"
if [ "$fails" -ne 0 ]; then
  echo "e2e: $fails assertion(s) failed"
  exit 1
fi
echo "e2e: all assertions passed"
