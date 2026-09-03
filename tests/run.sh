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

# This harness (not the scripts it tests) needs bash 4+ for `shopt -s
# globstar`, which drives the fixture discovery below. Stock macOS ships bash
# 3.2, where globstar is silently a no-op and `**/` degrades to `*/` — every
# fixture below the first level would just stop being discovered, and the run
# would report a green, much smaller pass count. Say so outright instead.
# The plugin scripts themselves are deliberately 3.2-clean: they have to run
# on the system bash of the macOS hosts this harness's Seatbelt tests target.
case "${BASH_VERSINFO[0]:-0}" in
0 | 1 | 2 | 3)
  echo "tests/run.sh needs bash 4+ (found ${BASH_VERSION:-unknown}); on macOS: brew install bash" >&2
  exit 2
  ;;
esac

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

  # A read loop, not `mapfile`: that builtin is bash 4.0+, and stock macOS —
  # the platform this repo's Seatbelt-dependent tests must run on — still
  # ships bash 3.2, where it fails with `command not found` and silently
  # leaves args empty.
  local args=() line
  if [ -f "$case_dir/args" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      args[${#args[@]}]="$line"
    done <"$case_dir/args"
  fi

  local test_home out err diff_file exit_code ok=1 detail=""
  test_home="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  diff_file="$(mktemp "${TMPDIR:-/tmp}/ape-test-diff.XXXXXX")"
  # Optional per-case input files (see header comment) copied into the fresh
  # $PWD before the script runs.
  [ -d "$case_dir/files" ] && cp -R "$case_dir/files/." "$test_home/"
  # HOME is pinned to the disposable test_home so any script that defaults to a
  # $HOME/... path (e.g. audit-log.sh's ~/.claude/audit.jsonl) can't touch the real
  # user's home directory during a test run. OLLAMA_MODEL/GEMINI_MODEL are unset so a
  # maintainer's own shell config (real elephant-goldfish usage often exports these)
  # can't leak into the fixture and make goldfish-judge.sh call a real ollama/gemini
  # with a non-stub model name. BABYSITTER_HOME is unset for the same reason and with
  # more at stake: it overrides the pinned HOME outright, so a maintainer who exports it
  # would have run-note.sh fixtures writing into their real notes ledger.
  # BABYSITTER_RETRY_BASE_SECS=0 collapses list-prs.sh's retry backoff: its
  # query-failure fixture exists to prove three attempts then exit 3, and waiting the
  # real 2s+4s to prove it made the suite a third slower for nothing.
  (
    cd "$test_home" && unset OLLAMA_MODEL GEMINI_MODEL BABYSITTER_HOME
    HOME="$test_home" PATH="$STUBS:$PATH" BABYSITTER_RETRY_BASE_SECS=0 \
      bash "$target" "${args[@]+"${args[@]}"}" >"$out" 2>"$err"
  )
  exit_code=$?

  local want_exit=0
  [ -f "$case_dir/exit_code" ] && want_exit="$(cat "$case_dir/exit_code")"
  [ "$exit_code" = "$want_exit" ] || {
    ok=0
    detail="$detail
exit code: want $want_exit, got $exit_code"
  }

  if [ -f "$case_dir/stdout" ]; then
    diff -u "$case_dir/stdout" "$out" >"$diff_file" 2>&1 || {
      ok=0
      detail="$detail
$(cat "$diff_file")"
    }
  elif [ -f "$case_dir/stdout.contains" ]; then
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      grep -qE "$pattern" "$out" || {
        ok=0
        detail="$detail
missing pattern in stdout: $pattern"
      }
    done <"$case_dir/stdout.contains"
  fi

  if [ -f "$case_dir/stderr" ]; then
    diff -u "$case_dir/stderr" "$err" >"$diff_file" 2>&1 || {
      ok=0
      detail="$detail
$(cat "$diff_file")"
    }
  fi

  report "$name" "$ok" "$detail"
  rm -rf "$test_home" "$out" "$err" "$diff_file"
}

run_unit_case() {
  local case_dir="$1" rel plugin script func target name
  rel="${case_dir#"$ROOT"/tests/fixtures/unit/}"
  IFS=/ read -r plugin script func _ <<<"$rel"
  target="$ROOT/plugins/$plugin/scripts/$script"
  name="unit/$rel"

  local actual expected ok=1 detail=""
  if [ -f "$case_dir/arg" ]; then
    actual="$( (
      __SOURCED__=1
      source "$target"
      "$func" "$(cat "$case_dir/arg")"
    ) 2>&1)"
  elif [ -f "$case_dir/stdin" ]; then
    actual="$( (
      __SOURCED__=1
      source "$target"
      "$func"
    ) <"$case_dir/stdin" 2>&1)"
  else
    report "$name" 0 "no arg or stdin fixture"
    return
  fi

  expected="$(cat "$case_dir/expected" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || {
    ok=0
    detail="want: $expected
got:  $actual"
  }
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

# Bundled-asset consistency: every plugin command that references
# ${CLAUDE_PLUGIN_ROOT}/... must ship every path it names. A renamed or deleted
# asset leaves the command syntactically fine and semantically broken at runtime.
# Check ALL commands, not just thinking.md — the regression class the original
# elephant-goldfish-only check was written to catch is equally relevant to every
# other command.
bundled_asset_ref_is_safe() {
  case "/$1/" in
  *"/../"*) return 1 ;;
  *) return 0 ;;
  esac
}

if bundled_asset_ref_is_safe "scripts/tool.sh" &&
  ! bundled_asset_ref_is_safe "scripts/../../outside.sh"; then
  report "consistency/bundled-assets-path-safety" 1
else
  report "consistency/bundled-assets-path-safety" 0 "path traversal guard failed"
fi

bundled_assets_check() {
  local ok=1 detail=""
  shopt -s nullglob
  local commands=("$ROOT"/plugins/*/commands/*.md)
  shopt -u nullglob

  if [ "${#commands[@]}" -eq 0 ]; then
    report "consistency/bundled-assets" 0 "no command files found"
    return
  fi

  for command_file in "${commands[@]}"; do
    # Derive plugin dir: "plugins/<plugin>/commands/<name>.md" -> plugin dir is
    # "plugins/<plugin>".
    local rel="${command_file#"$ROOT"/}"
    local plugin_dir="${rel%%/commands/*}"

    # Pre-filter: only files with ${CLAUDE_PLUGIN_ROOT}/<path> (path-based refs
    # with a trailing / and at least one alphanum). Excludes bare ${CLAUDE_PLUGIN_ROOT}
    # without a path — those are just informational, not bundled-asset references.
    if ! grep -qE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9]' "$command_file"; then
      continue
    fi

    local cs_ok=1 cs_detail="" cs_found=0 cs_skipped=0

    # Extract every ${CLAUDE_PLUGIN_ROOT}/<subpath> reference, deduplicated.
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      cs_found=$((cs_found + 1))

      # Skip template patterns like <script>.py*, <slug>.md, scripts/* —
      # these describe a convention, not a specific bundled asset.
      case "$ref" in
      *[\<\>\*\?]*)
        cs_skipped=$((cs_skipped + 1))
        continue
        ;;
      esac

      if ! bundled_asset_ref_is_safe "$ref"; then
        cs_ok=0
        cs_detail="$cs_detail
${rel} references unsafe \${CLAUDE_PLUGIN_ROOT}/$ref (parent traversal is not allowed)"
        continue
      fi

      # Use -e (not -f): references may name directories (e.g. scripts/, personas/)
      # as well as regular files.
      if [ ! -e "$ROOT/$plugin_dir/$ref" ]; then
        cs_ok=0
        cs_detail="$cs_detail
${rel} references \${CLAUDE_PLUGIN_ROOT}/$ref, which does not exist"
      fi
    done <<EOF
$(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$command_file" |
      sed 's|\${CLAUDE_PLUGIN_ROOT}/||' | sort -u)
EOF

    # Vacuous-pass guard: the file matched the pre-filter (it has path-based
    # ${CLAUDE_PLUGIN_ROOT} references), so if extraction yields zero total
    # matches the regex is broken — fail rather than reporting a vacuous pass.
    if [ "$cs_found" -lt 1 ]; then
      cs_ok=0
      cs_detail="$cs_detail
${rel} contains \${CLAUDE_PLUGIN_ROOT}/ references but none were extracted (extraction failure)"
    fi

    if [ "$cs_ok" -eq 0 ]; then
      ok=0
      detail="$detail$cs_detail"
    fi
  done

  report "consistency/bundled-assets" "$ok" "$detail"
}

bundled_assets_check

# A skip must NOT print "ok" — `report` only knows ok/FAIL, so reusing it here
# would count a never-run check as a pass on ubuntu-latest CI. Skips print their
# own line and stay outside the pass/fail counters.
skip() { echo "skip $1: $2"; }

# /imps state-schema round-trip (schema 4 review-discipline fields, which must
# survive repeated patchState() heartbeats). Pure node, no sandbox, no spend —
# runs unconditionally, including on ubuntu-latest CI.
#
# The wiring is deliberately here ahead of the file: whoever owns
# state-schema.sh does not own this harness, so without a pre-placed block a
# forgotten test is invisible. With it, a missing or non-executable file
# surfaces as a `skip` line: never silent, and never counted as a pass.
imps_state_schema="$ROOT/plugins/imps/tests/state-schema.sh"
if [ -x "$imps_state_schema" ]; then
  state_schema_out="$(bash "$imps_state_schema" 2>&1)"
  state_schema_rc=$?
  if [ "$state_schema_rc" -eq 0 ]; then
    report "imps/tests/state-schema.sh" 1
  else
    report "imps/tests/state-schema.sh" 0 "$state_schema_out"
  fi
else
  skip "imps/tests/state-schema.sh" "missing or not executable: $imps_state_schema"
fi

imps_ocr_review="$ROOT/plugins/imps/tests/run-ocr.sh"
if [ -x "$imps_ocr_review" ]; then
  ocr_review_out="$(bash "$imps_ocr_review" 2>&1)"
  ocr_review_rc=$?
  if [ "$ocr_review_rc" -eq 0 ]; then
    report "imps/tests/run-ocr.sh" 1
  else
    report "imps/tests/run-ocr.sh" 0 "$ocr_review_out"
  fi
else
  skip "imps/tests/run-ocr.sh" "missing or not executable: $imps_ocr_review"
fi

# Cross-platform e2e (OpenCode npm channel, Agy plugin channel). These exercise real
# package-manager/registry machinery (tests/npm-install-smoke.sh talks to the npm
# registry even for a local tarball path) or a live `agy` binary — neither of which a
# sandboxed imp run may reach or invoke (see docs/plans/cross-platform-compat.md's
# "No live opencode or agy model invocations" constraint). Off by default; a maintainer
# opts in explicitly with XPLAT_E2E=1 (both channels) or the per-channel OPENCODE_E2E=1
# / AGY_E2E=1. Same skip-vs-pass shape as the state-schema.sh block above: unset means
# skip, never a silent "ok".
xplat_npm_smoke="$ROOT/tests/npm-install-smoke.sh"
if [ -n "${XPLAT_E2E:-}" ] || [ -n "${OPENCODE_E2E:-}" ]; then
  if [ ! -x "$xplat_npm_smoke" ]; then
    skip "xplat/npm-install-smoke.sh" "missing or not executable: $xplat_npm_smoke"
  else
    xplat_npm_out="$(bash "$xplat_npm_smoke" 2>&1)"
    xplat_npm_rc=$?
    if [ "$xplat_npm_rc" -eq 0 ] && printf '%s\n' "$xplat_npm_out" | grep -q '^skip:'; then
      # npm-install-smoke.sh exits 0 on its own early "npm not on PATH" /
      # "dist/opencode missing" outs — a real skip, not a pass. rc==0 alone
      # cannot tell those apart from an actual pass, so the reason line it
      # printed is what does: without this, an opted-in (XPLAT_E2E=1) run on a
      # box with no npm would report "ok" here, exactly the silent-green
      # signal the comment above promises this block never produces.
      skip "xplat/npm-install-smoke.sh" "$(printf '%s\n' "$xplat_npm_out" | grep '^skip:' | head -1)"
    elif [ "$xplat_npm_rc" -eq 0 ]; then
      report "xplat/npm-install-smoke.sh" 1
    else
      report "xplat/npm-install-smoke.sh" 0 "$xplat_npm_out"
    fi
  fi
else
  skip "xplat/npm-install-smoke.sh" "cross-platform e2e disabled by default (set OPENCODE_E2E=1 or XPLAT_E2E=1 to enable; needs npm registry access)"
fi

if [ -n "${XPLAT_E2E:-}" ] || [ -n "${AGY_E2E:-}" ]; then
  # Even opted in, this run must not perform a live `agy` invocation itself — that proof
  # is operator-run only (docs/plans/cross-platform-compat.md item 13: "proof plugin
  # installs and invokes on both platforms" is [OPERATOR-RUN — not dispatchable]).
  skip "xplat/agy-live-invocation" "AGY_E2E/XPLAT_E2E enabled, but live agy install+invoke proof is operator-run only — see docs/plans/cross-platform-compat.md item 13"
else
  skip "xplat/agy-live-invocation" "cross-platform e2e disabled by default (set AGY_E2E=1 or XPLAT_E2E=1 to enable; needs a live agy binary)"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
