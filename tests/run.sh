#!/usr/bin/env bash
# Behavioral test harness for plugins/*/scripts/*.sh — runs fixtures against
# the real scripts and diffs actual output against golden files. Static
# manifest/schema checks live in .github/workflows/validate.yml; this covers
# what those can't: does the script actually do the right thing when run.
#
# Two fixture kinds, each a leaf directory under tests/fixtures/:
#
#   exec/<plugin>/<script>/<case>/
#     Runs the real script end-to-end with external commands (gh, git)
#     replaced by tests/lib/stubs/* on PATH, from a fresh empty $PWD.
#       args             one CLI arg per line (optional)
#       stdout           exact expected stdout (optional)
#       stdout.contains  one grep -E pattern per line, each must match
#                        somewhere in actual stdout — use instead of `stdout`
#                        when the real output has non-deterministic parts
#                        (e.g. `ls -la` timestamps) (optional)
#       stderr           exact expected stderr (optional)
#       exit_code        expected exit code, default 0 (optional)
#       files/           optional dir; its contents are copied into the case's
#                        fresh $PWD before the script runs — for scripts that
#                        require an input file on disk (e.g. goldfish-judge.sh's
#                        DOC argument) that the empty-PWD harness can't otherwise
#                        supply. Exec fixtures have no mechanism to set env vars,
#                        so a stub that needs to vary its behavior per fixture
#                        must derive its mode from argv/PWD content instead (see
#                        tests/lib/stubs/gemini's header comment).
#
#   unit/<plugin>/<script>/<function>/<case>/
#     Sources the script with __SOURCED__=1 (see the guard comment in
#     goldfish-judge.sh — this stops execution before the script's "do the
#     thing" tail) and calls one function directly.
#       arg      passed as "$1" to the function (mutually exclusive w/ stdin)
#       stdin    piped to the function's stdin (mutually exclusive w/ arg)
#       expected exact expected stdout
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/tests/lib/stubs"
pass=0
fail=0

report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    [ -n "$detail" ] && printf '%s\n' "$detail"
    fail=$((fail + 1))
  fi
}

run_exec_case() {
  local case_dir="$1" rel plugin script target name
  rel="${case_dir#"$ROOT"/tests/fixtures/exec/}"
  IFS=/ read -r plugin script _ <<<"$rel"
  target="$ROOT/plugins/$plugin/scripts/$script"
  name="exec/$rel"

  local args=()
  [ -f "$case_dir/args" ] && mapfile -t args <"$case_dir/args"

  local test_home out err exit_code ok=1 detail=""
  test_home="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  # Optional per-case input files (see header comment) copied into the fresh
  # $PWD before the script runs.
  [ -d "$case_dir/files" ] && cp -R "$case_dir/files/." "$test_home/"
  # HOME is pinned to the disposable test_home so any script that defaults to a
  # $HOME/... path (e.g. audit-log.sh's ~/.claude/audit.jsonl) can't touch the real
  # user's home directory during a test run. OLLAMA_MODEL/GEMINI_MODEL are unset so a
  # maintainer's own shell config (real elephant-goldfish usage often exports these)
  # can't leak into the fixture and make goldfish-judge.sh call a real ollama/gemini
  # with a non-stub model name.
  ( cd "$test_home" && unset OLLAMA_MODEL GEMINI_MODEL
    HOME="$test_home" PATH="$STUBS:$PATH" bash "$target" "${args[@]+"${args[@]}"}" >"$out" 2>"$err" )
  exit_code=$?

  local want_exit=0
  [ -f "$case_dir/exit_code" ] && want_exit="$(cat "$case_dir/exit_code")"
  [ "$exit_code" = "$want_exit" ] || { ok=0; detail="$detail
exit code: want $want_exit, got $exit_code"; }

  if [ -f "$case_dir/stdout" ]; then
    diff -u "$case_dir/stdout" "$out" >/tmp/ape-test-diff.$$ 2>&1 || { ok=0; detail="$detail
$(cat /tmp/ape-test-diff.$$)"; }
  elif [ -f "$case_dir/stdout.contains" ]; then
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      grep -qE "$pattern" "$out" || { ok=0; detail="$detail
missing pattern in stdout: $pattern"; }
    done <"$case_dir/stdout.contains"
  fi

  if [ -f "$case_dir/stderr" ]; then
    diff -u "$case_dir/stderr" "$err" >/tmp/ape-test-diff.$$ 2>&1 || { ok=0; detail="$detail
$(cat /tmp/ape-test-diff.$$)"; }
  fi

  report "$name" "$ok" "$detail"
  rm -rf "$test_home" "$out" "$err" /tmp/ape-test-diff.$$
}

run_unit_case() {
  local case_dir="$1" rel plugin script func target name
  rel="${case_dir#"$ROOT"/tests/fixtures/unit/}"
  IFS=/ read -r plugin script func _ <<<"$rel"
  target="$ROOT/plugins/$plugin/scripts/$script"
  name="unit/$rel"

  local actual expected ok=1 detail=""
  if [ -f "$case_dir/arg" ]; then
    actual="$( (__SOURCED__=1; source "$target"; "$func" "$(cat "$case_dir/arg")") 2>&1 )"
  elif [ -f "$case_dir/stdin" ]; then
    actual="$( (__SOURCED__=1; source "$target"; "$func") <"$case_dir/stdin" 2>&1 )"
  else
    report "$name" 0 "no arg or stdin fixture"
    return
  fi

  expected="$(cat "$case_dir/expected" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || { ok=0; detail="want: $expected
got:  $actual"; }
  report "$name" "$ok" "$detail"
}

shopt -s globstar nullglob
for case_dir in "$ROOT"/tests/fixtures/exec/**/; do
  case_dir="${case_dir%/}"
  [ -f "$case_dir/args" ] || [ -f "$case_dir/stdout" ] || [ -f "$case_dir/stdout.contains" ] || [ -f "$case_dir/exit_code" ] || continue
  run_exec_case "$case_dir"
done
for case_dir in "$ROOT"/tests/fixtures/unit/**/; do
  case_dir="${case_dir%/}"
  [ -f "$case_dir/arg" ] || [ -f "$case_dir/stdin" ] || continue
  run_unit_case "$case_dir"
done

# Cross-plugin consistency: audit-log.sh is bundled identically into every plugin that
# uses it (no shared runtime path exists between independently-installed plugins — see
# AGENTS.md). Diff the copies so a future edit to one doesn't silently drift from the
# rest. Discovered dynamically so a new adopter is automatically covered.
audit_log_copies=("$ROOT"/plugins/*/scripts/audit-log.sh)
if [ -f "${audit_log_copies[0]:-}" ]; then
  first="${audit_log_copies[0]}"
  consistent=1 detail=""
  for other in "${audit_log_copies[@]:1}"; do
    if ! diff -q "$first" "$other" >/dev/null 2>&1; then
      consistent=0
      detail="$detail
${other#"$ROOT"/} differs from ${first#"$ROOT"/}"
    fi
  done
  report "consistency/audit-log.sh" "$consistent" "$detail"
fi

# opencode execute-tier harness (plugins/imps). Two extra checks that cannot be
# fixture-driven: they need a real macOS sandbox, and the E2E additionally needs
# credentials and spends real money.
#
# A skip must NOT print "ok" — `report` only knows ok/FAIL, so reusing it here
# would count a never-run E2E as a pass on ubuntu-latest CI. Skips print their
# own line and stay outside the pass/fail counters.
skip() { echo "skip $1: $2"; }

sandbox_wrap="$ROOT/plugins/imps/scripts/sandbox-wrap.sh"
sandbox_smoke="$ROOT/plugins/imps/scripts/sandbox-smoke.sh"
if [ ! -x "$sandbox_smoke" ]; then
  # A lost exec bit or a deleted file must not be silently invisible — that's
  # exactly the regression class this whole skip-vs-pass distinction exists to
  # catch, and a bare `:` here defeats it.
  skip "imps/sandbox-smoke.sh" "missing or not executable: $sandbox_smoke"
elif [ "$(uname -s)" != "Darwin" ]; then
  skip "imps/sandbox-smoke.sh" "not Darwin (uname -s = $(uname -s))"
elif ! bash "$sandbox_wrap" --check >/dev/null 2>&1; then
  skip "imps/sandbox-smoke.sh" "sandbox backend unavailable (SANDBOX_MODE=${SANDBOX_MODE:-safehouse})"
else
  smoke_out="$(bash "$sandbox_smoke" 2>&1)"
  smoke_rc=$?
  case "$smoke_rc" in
    0)  report "imps/sandbox-smoke.sh" 1 ;;
    # 77 == "cannot run here": Seatbelt does not nest, so running this from
    # inside Claude Code's own Bash sandbox proves nothing either way.
    77) skip "imps/sandbox-smoke.sh" "sandbox cannot be applied here (nested sandbox); run it unsandboxed" ;;
    *)  report "imps/sandbox-smoke.sh" 0 "$smoke_out" ;;
  esac
fi

imps_e2e="$ROOT/plugins/imps/tests/e2e.sh"
if [ -x "$imps_e2e" ]; then
  e2e_out="$(bash "$imps_e2e" 2>&1)"
  e2e_rc=$?
  case "$e2e_rc" in
    # 77 == the script's own "gate not met" status; it prints the reason itself.
    77) skip "imps/tests/e2e.sh" "$(printf '%s\n' "$e2e_out" | tail -n 1 | sed 's/^skip e2e: //')" ;;
    0)  report "imps/tests/e2e.sh" 1 ;;
    *)  report "imps/tests/e2e.sh" 0 "$e2e_out" ;;
  esac
else
  # Same visibility invariant as sandbox-smoke.sh above: missing/non-executable
  # must never be silent.
  skip "imps/tests/e2e.sh" "missing or not executable: $imps_e2e"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
