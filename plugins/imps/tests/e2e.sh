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
WT="$(mktemp -u "$TMP_CANON/imps-e2e-wt.XXXXXX")"
cleanup() {
  if [ "${IMPS_KEEP_E2E_WORKTREE:-}" = "1" ]; then return; fi
  git -C "$BASE" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$BASE" branch -D "imps-e2e-fixture-$$" >/dev/null 2>&1
}
trap cleanup EXIT

git -C "$BASE" worktree add -q -b "imps-e2e-fixture-$$" "$WT" HEAD

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
   has("oracle_files_modified")] | all' 2>/dev/null)"
assert "contract-has-all-keys" "$([ "$has_keys" = "true" ] && echo 1 || echo 0)" "$CONTRACT"

# Exactly one contract line, always — a second would break every consumer.
line_count="$(printf '%s\n' "$out" | grep -c '^{' || true)"
assert "contract-emitted-once" "$([ "$line_count" = "1" ] && echo 1 || echo 0)" "found $line_count JSON lines on stdout"

status="$(printf '%s' "$CONTRACT" | jq -r '.status // ""' 2>/dev/null)"
assert "status-pass" "$([ "$status" = "pass" ] && echo 1 || echo 0)" "status=$status (exit $dispatch_rc)"

assert "exit-zero-on-pass" "$([ "$dispatch_rc" -eq 0 ] && echo 1 || echo 0)" "dispatch exited $dispatch_rc"

# A genuine fix should never need to touch the fixture's own test file — if it
# did, oracle_files_modified would be non-null here, which would mean the
# model gamed its own oracle rather than fixing the code. This assertion is
# specifically about the measurement-integrity claim, not the sandbox.
guard_hit="$(printf '%s' "$CONTRACT" | jq -r '.oracle_files_modified // empty' 2>/dev/null)"
assert "oracle-guard-not-triggered" "$([ -z "$guard_hit" ] && echo 1 || echo 0)" "oracle_files_modified=$guard_hit — the model edited its own test file"

log_path="$(printf '%s' "$CONTRACT" | jq -r '.log_path // ""' 2>/dev/null)"
case "$log_path" in
  "$WT"/*) assert "log-path-outside-worktree" 0 "$log_path is inside the worktree" ;;
  "") assert "log-path-outside-worktree" 0 "log_path is null" ;;
  *) assert "log-path-outside-worktree" 1 ;;
esac

# --- 4. the commit ----------------------------------------------------------
NOW_COMMITS="$(git -C "$WT" rev-list --count HEAD)"
assert "harness-made-a-commit" "$([ "$NOW_COMMITS" -gt "$BASE_COMMITS" ] && echo 1 || echo 0)" \
  "commits before=$BASE_COMMITS after=$NOW_COMMITS"
author="$(git -C "$WT" log -1 --format=%an)"
assert "commit-authored-by-harness" "$([ "$author" = "imps-opencode" ] && echo 1 || echo 0)" "author=$author"

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
