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
  # with a non-stub model name.
  (
    cd "$test_home" && unset OLLAMA_MODEL GEMINI_MODEL
    HOME="$test_home" PATH="$STUBS:$PATH" bash "$target" "${args[@]+"${args[@]}"}" >"$out" 2>"$err"
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

# Seatbelt is last-match-wins, so deny-credentials.sbpl.in's worktrees/modules
# chain is ordered, not just present: deny the subtrees, re-allow only this
# dispatch's own gitdir, then re-deny the pointer files inside that reallow.
# Reordering any of it silently reopens an RCE — verified live that moving the
# reallow after the re-denies makes those paths writable again. The template
# carried a "each line must stay in exactly this sequence" comment and nothing
# that enforced it: sandbox-smoke.sh exercises the RENDERED profile's effects,
# so a reordered template that still happens to deny the smoke test's specific
# probes passes it. This asserts the sequence itself, on the source template,
# on every platform (no sandbox needed).
sbpl_order_check() {
  local tpl="$ROOT/plugins/imps/sandbox/deny-credentials.sbpl.in"
  if [ ! -f "$tpl" ]; then
    report "imps/sbpl-rule-order" 0 "missing $tpl"
    return
  fi
  # Rule lines only — the file's own comments quote these same forms.
  local rules ok=1 detail=""
  rules="$(grep -vE '^[[:space:]]*;' "$tpl")"
  line_of() { printf '%s\n' "$rules" | grep -nF -- "$1" | head -n 1 | cut -d: -f1; }
  local l_hooks l_modules l_worktrees l_allow l_redeny
  l_hooks="$(line_of '(subpath "@GITMETA@/hooks")')"
  l_modules="$(line_of '(subpath "@GITMETA@/modules")')"
  l_worktrees="$(line_of '(subpath "@GITMETA@/worktrees")')"
  l_allow="$(line_of '(allow file-write* (subpath "@REAL_GITDIR@"))')"
  l_redeny="$(line_of '(subpath "@REAL_GITDIR@/modules")')"
  local want
  for want in l_hooks l_modules l_worktrees l_allow l_redeny; do
    if [ -z "${!want}" ]; then
      ok=0
      detail="$detail
missing expected rule for $want"
    fi
  done
  if [ "$ok" = 1 ]; then
    # Every broad deny must precede the reallow; the reallow must precede its
    # own re-denies. Anything else and last-match-wins silently inverts.
    [ "$l_hooks" -lt "$l_allow" ] || {
      ok=0
      detail="$detail
@GITMETA@/hooks deny (line $l_hooks) must come BEFORE the @REAL_GITDIR@ reallow (line $l_allow)"
    }
    [ "$l_modules" -lt "$l_allow" ] || {
      ok=0
      detail="$detail
@GITMETA@/modules deny (line $l_modules) must come BEFORE the @REAL_GITDIR@ reallow (line $l_allow)"
    }
    [ "$l_worktrees" -lt "$l_allow" ] || {
      ok=0
      detail="$detail
@GITMETA@/worktrees deny (line $l_worktrees) must come BEFORE the @REAL_GITDIR@ reallow (line $l_allow)"
    }
    [ "$l_allow" -lt "$l_redeny" ] || {
      ok=0
      detail="$detail
the @REAL_GITDIR@ reallow (line $l_allow) must come BEFORE its own re-denies (line $l_redeny)"
    }
  fi
  report "imps/sbpl-rule-order" "$ok" "$detail"
}
sbpl_order_check

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
  0) report "imps/sandbox-smoke.sh" 1 ;;
  # 77 == "cannot run here": Seatbelt does not nest, so running this from
  # inside Claude Code's own Bash sandbox proves nothing either way.
  77) skip "imps/sandbox-smoke.sh" "sandbox cannot be applied here (nested sandbox); run it unsandboxed" ;;
  *) report "imps/sandbox-smoke.sh" 0 "$smoke_out" ;;
  esac
fi

imps_e2e="$ROOT/plugins/imps/tests/e2e.sh"
if [ -x "$imps_e2e" ]; then
  e2e_out="$(bash "$imps_e2e" 2>&1)"
  e2e_rc=$?
  case "$e2e_rc" in
  # 77 == the script's own "gate not met" status; it prints the reason itself.
  77) skip "imps/tests/e2e.sh" "$(printf '%s\n' "$e2e_out" | tail -n 1 | sed 's/^skip e2e: //')" ;;
  0) report "imps/tests/e2e.sh" 1 ;;
  *) report "imps/tests/e2e.sh" 0 "$e2e_out" ;;
  esac
else
  # Same visibility invariant as sandbox-smoke.sh above: missing/non-executable
  # must never be silent.
  skip "imps/tests/e2e.sh" "missing or not executable: $imps_e2e"
fi

# Unlike sandbox-smoke.sh/e2e.sh, this one needs no macOS sandbox, no
# credentials, and spends nothing — it's pure git plumbing, so it runs
# unconditionally (including on ubuntu-latest CI) rather than through the
# skip-gated pattern above.
imps_worktree_shape="$ROOT/plugins/imps/tests/worktree-shape.sh"
if [ -x "$imps_worktree_shape" ]; then
  worktree_shape_out="$(bash "$imps_worktree_shape" 2>&1)"
  worktree_shape_rc=$?
  if [ "$worktree_shape_rc" -eq 0 ]; then
    report "imps/tests/worktree-shape.sh" 1
  else
    report "imps/tests/worktree-shape.sh" 0 "$worktree_shape_out"
  fi
else
  skip "imps/tests/worktree-shape.sh" "missing or not executable: $imps_worktree_shape"
fi

# Same visibility invariant, and the same "no macOS sandbox needed" shape as
# worktree-shape.sh above: this exercises sandbox-wrap.sh's own pure logic
# (SBPL render, ENV_PASS/sh_args construction, SANDBOX_MODE/bypass dispatch,
# metachar rejection) via stubbed uname/safehouse, never a real sandbox
# apply — runs unconditionally, including on ubuntu-latest CI.
imps_sandbox_wrap_shape="$ROOT/plugins/imps/tests/sandbox-wrap-shape.sh"
if [ -x "$imps_sandbox_wrap_shape" ]; then
  sandbox_wrap_shape_out="$(bash "$imps_sandbox_wrap_shape" 2>&1)"
  sandbox_wrap_shape_rc=$?
  if [ "$sandbox_wrap_shape_rc" -eq 0 ]; then
    report "imps/tests/sandbox-wrap-shape.sh" 1
  else
    report "imps/tests/sandbox-wrap-shape.sh" 0 "$sandbox_wrap_shape_out"
  fi
else
  skip "imps/tests/sandbox-wrap-shape.sh" "missing or not executable: $imps_sandbox_wrap_shape"
fi

# Same visibility invariant and shape as sandbox-wrap-shape.sh above, one
# layer up the stack: this proves sandbox-smoke.sh's OWN assertion/counting/
# exit-code logic (not real containment — only the Darwin+SANDBOX_MODE inline
# run further down proves that) by running sandbox-smoke.sh as a real
# subprocess against a stubbed sandbox-wrap.sh selected via CLAUDE_PLUGIN_ROOT.
# No macOS sandbox, no credentials, no spend — runs unconditionally, including
# on ubuntu-latest CI, which is exactly where the Darwin-gated block below
# cannot run at all.
imps_sandbox_smoke_shape="$ROOT/plugins/imps/tests/sandbox-smoke-shape.sh"
if [ -x "$imps_sandbox_smoke_shape" ]; then
  sandbox_smoke_shape_out="$(bash "$imps_sandbox_smoke_shape" 2>&1)"
  sandbox_smoke_shape_rc=$?
  if [ "$sandbox_smoke_shape_rc" -eq 0 ]; then
    report "imps/tests/sandbox-smoke-shape.sh" 1
  else
    report "imps/tests/sandbox-smoke-shape.sh" 0 "$sandbox_smoke_shape_out"
  fi
else
  skip "imps/tests/sandbox-smoke-shape.sh" "missing or not executable: $imps_sandbox_smoke_shape"
fi

# Sibling of worktree-shape.sh (which owns the --worktree shape gate); this one
# owns opencode-dispatch.sh's other free guards: the new --expect-oracle /
# --result-branch bad_arguments paths, create_result_ref's durability claim
# (commit survives worktree deletion + gc), the no_model_changes pair
# (restore_worktree_clean / stage_model_changes), and emit_contract key parity
# between its jq branch and its hand-written no-jq fallback literal. Pure git
# plumbing and string logic — no sandbox, no credentials, no spend — so it runs
# unconditionally, including on ubuntu-latest CI.
imps_dispatch_guards="$ROOT/plugins/imps/tests/dispatch-guards.sh"
if [ -x "$imps_dispatch_guards" ]; then
  dispatch_guards_out="$(bash "$imps_dispatch_guards" 2>&1)"
  dispatch_guards_rc=$?
  if [ "$dispatch_guards_rc" -eq 0 ]; then
    report "imps/tests/dispatch-guards.sh" 1
  else
    report "imps/tests/dispatch-guards.sh" 0 "$dispatch_guards_out"
  fi
else
  skip "imps/tests/dispatch-guards.sh" "missing or not executable: $imps_dispatch_guards"
fi

# /imps state-schema round-trip (schema 3: per-task oracle/executor plus a
# top-level escalated_tasks, all of which must survive repeated patchState()
# heartbeats). Same free, unconditional shape as the two above.
#
# The wiring is deliberately here ahead of the file: whoever owns
# state-schema.sh does not own this harness, so without a pre-placed block a
# forgotten test is invisible. With it, a missing or non-executable file
# surfaces as a `skip` line — the file's standing invariant (see the
# sandbox-smoke.sh block above): never silent, and never counted as a pass.
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

# Cross-platform e2e (OpenCode npm channel, Agy plugin channel). These exercise real
# package-manager/registry machinery (tests/npm-install-smoke.sh talks to the npm
# registry even for a local tarball path) or a live `agy` binary — neither of which a
# sandboxed imp run may reach or invoke (see docs/plans/cross-platform-compat.md's
# "No live opencode or agy model invocations" constraint). Off by default; a maintainer
# opts in explicitly with XPLAT_E2E=1 (both channels) or the per-channel OPENCODE_E2E=1
# / AGY_E2E=1. Same skip-vs-pass shape as sandbox-smoke.sh/imps-e2e.sh above: unset means
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
