#!/usr/bin/env bash
# opencode-dispatch.sh — run one mechanical task on a cheap open model inside a
# sandboxed git worktree, looping it against a machine-checkable acceptance
# command ("the oracle") and giving up after N attempts.
#
# The load-bearing idea: a cheap model is good at grinding iterations against a
# hard pass/fail signal and bad at knowing when to stop. Nothing here trusts the
# model's self-report — the oracle decides, and the harness (not the model)
# makes the commit.
#
# Usage:
#   opencode-dispatch.sh --worktree <dir> --prompt-file <file> --oracle <cmd>
#                        [--model <id>] [--max-attempts <n>] [--sandbox-mode <mode>]
#                        [--attempt-timeout <secs>] [--oracle-timeout <secs>]
#                        [--oracle-guard <pathspec>] [--result-branch <name>]
#                        [--expect-oracle red|green|any]
#                        [--engine auto|opencode|agy]
#
#   --worktree        git worktree the model may edit (its only writable code path)
#   --prompt-file     the task prompt, read verbatim
#   --oracle          shell command run in the worktree; exit 0 == task done
#   --model           default opencode-go/qwen3.7-max; opencode-go/deepseek-v4-flash
#                     is the cost floor. Only opencode-go/* and opencode/* are
#                     accepted (see the model guard below).
#   --max-attempts    default 3
#   --sandbox-mode    passed through to sandbox-wrap.sh as SANDBOX_MODE
#   --attempt-timeout seconds before a stalled `opencode run` is killed; default 300.
#                     NOTE (semantic change): a kill aborts the whole DISPATCH with
#                     abort_reason:"attempt_timeout" — it is not a retryable
#                     per-attempt event. Retrying is unsound: the killed attempt's
#                     truncated edits stay in the worktree and the harness commit is
#                     `git add -A`, so a later attempt going green would ship the
#                     truncated work anyway. The oracle is deliberately NOT run after
#                     a kill, so oracle_exit stays null — the honest report.
#   --oracle-timeout  seconds before a stalled oracle is killed; default 120. Budget
#                     for TWO runs per dispatch minimum: the preflight below plus at
#                     least one in-loop run.
#   --result-branch   optional branch name to additionally point at the harness
#                     commit, created with an atomic compare-and-swap (it must not
#                     already exist). Durability itself is NOT gated on this flag —
#                     see refs/imps/dispatch/ below.
#   --expect-oracle   red|green|any (default any). The oracle is run ONCE before the
#                     first model attempt and the starting state reported as
#                     oracle_start_state. `red` requires a failing start (a green
#                     start cannot distinguish "implemented correctly" from "did
#                     nothing"); `green` requires a passing start. A mismatch aborts
#                     oracle_preflight_mismatch BEFORE any model attempt is paid for.
#   --oracle-guard    optional pathspec (e.g. a test file). If the model's own
#                     edits touch it, the attempt is reported as status:"fail"
#                     with abort_reason:"oracle_guard_violated" and the
#                     touched file(s) named in oracle_files_modified, rather
#                     than silently counted as a clean pass — a model that
#                     rewrites its own test to pass trivially is otherwise
#                     indistinguishable from one that genuinely fixed the
#                     code, and this v1's whole purpose is to produce a
#                     trustworthy pass-rate number, fail-closed by
#                     construction rather than by reader diligence.
#   --engine          auto|opencode|agy (default auto). Selects the execution
#                     engine for this dispatch. `auto` and `opencode` are
#                     identical today (both route through opencode). `agy` is
#                     recognised but not yet supported for sandboxed dispatch
#                     in this harness — an explicit `--engine agy` aborts
#                     immediately with abort_reason:"engine_unsupported",
#                     before any preflight, sandbox-smoke, or model work.
#
# Contract: the FINAL line of stdout is always exactly one JSON object —
#   {"status":"pass|fail","attempts":2,"session_id":"ses_…","cost_usd":0.0087,
#    "oracle_exit":0,"log_path":"/abs/path.jsonl","abort_reason":null,
#    "oracle_files_modified":null,"commit_sha":"a1b2c3…","oracle_start_state":"red"}
# on every exit path, including a failed preflight or a rejected model. Exit code
# is still non-zero on failure. Everything else goes to stderr. log_path is
# null unless IMPS_KEEP_DISPATCH_DIR=1 — otherwise the dispatch dir (and the
# log inside it) is removed by this same cleanup before the process exits, so
# advertising the path would point at something already gone.
#
# abort_reason values (non-exhaustive, the set grows as guards are added):
#   bad_arguments              — a flag value was malformed or out of range
#   engine_unsupported         — the requested --engine is recognised but has
#                                no sandboxed execution path in this harness
#                                yet (currently: `agy`)
#   jq_missing                 — jq is not on PATH
#   model_rejected             — --model failed the provider allowlist
#   opencode_missing           — opencode binary not on PATH
#   auth_missing               — credentials not found or not copyable
#   config_missing             — hardened opencode.json template missing or
#                                does not set the required denies
#   sandbox_bypass_refused     — IMPS_SANDBOX_DANGEROUSLY_DISABLE was set
#   preflight_smoke_failed     — sandbox-smoke.sh did not return 0 or 77
#   worktree_dirty             — worktree had uncommitted changes at start,
#                                or the preflight oracle contaminated it
#   gitmeta_tampered           — pointer files changed during dispatch
#   oracle_timeout             — oracle or preflight oracle exceeded its budget
#   oracle_sandbox_failed      — sandbox-wrap.sh failed closed on an oracle
#   oracle_preflight_mismatch  — --expect-oracle red|green did not match start
#   attempt_timeout            — a model attempt was killed by the watchdog
#   no_model_changes           — oracle went green but the model staged nothing
#   oracle_guard_violated      — the model touched the guarded oracle file(s)
#   commit_failed              — oracle went green but git commit failed
#   commit_lineage_invalid     — committed HEAD does not descend from BASE_SHA
#   result_ref_failed          — the durability ref or named branch could not
#                                be written
#   dispatch_dir_failed        — could not create the dispatch scratch dir
#   unexpected_exit            — the script exited without calling finish
#
# Durability: on every successful commit this writes
# refs/imps/dispatch/<UTC-ts>-<short-sha> UNCONDITIONALLY. A flag-gated design
# reproduces the exact loss that motivated it the moment an operator forgets the
# flag: a linked worktree's objects/ IS the common dir's, so the commit already
# survives the worktree — only a ref was missing, and any ref under refs/ is a gc
# root. refs/imps/ stays out of `git branch` and out of branch-pruning tools.
# `result_ref_failed` reports status:"fail" with commit_sha POPULATED, so an
# operator can still recover work that committed but did not get every ref it
# asked for. Read it as "at least one ref failed", not "no ref exists": the
# auto-ref is written FIRST, so on the common failure (a --result-branch name
# collision) the durability ref has already landed and only the named branch is
# missing. The stderr line says which.
#
# KNOWN CONTAMINANT — requires diff review before promotion: the IN-LOOP oracle's
# byproducts still enter `git add -A`. The preflight oracle's are neutralised
# (restore-to-clean, below) but the post-model run's are not, and cannot be
# without discarding the model's work. A `pytest` oracle can therefore carry
# .pyc files (or any other untracked, non-ignored build output) into the harness
# commit — and because that commit is now durable and mergeable, into a PR
# branch. Review the diff before promoting any dispatch result.
#
# The composite invariant a status:"pass" now asserts: red start (under
# --expect-oracle red) + green end + attempt not killed + the model actually
# staged something + the commit descends from the pre-dispatch HEAD + a durable
# ref exists. Every clause is load-bearing; each closed a distinct false pass.
#
# See plugins/imps/references/opencode-harness.md for setup, the Claude Code
# permission entry, and the measurement protocol.
set -uo pipefail

# Structural guarantee for "the final line of stdout is always exactly one
# JSON object": save the real stdout on fd 3, then redirect the script's own
# fd 1 to stderr for everything else. A stray bare `echo`/`printf` anywhere in
# this file (now, or in a future edit) lands on stderr instead of silently
# corrupting the contract — emit_contract is the only thing that writes to fd 3.
exec 3>&1
exec 1>&2

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
WRAP="$PLUGIN_ROOT/scripts/sandbox-wrap.sh"
SMOKE="$PLUGIN_ROOT/scripts/sandbox-smoke.sh"
AUDIT="$PLUGIN_ROOT/scripts/audit-log.sh"
TEMPLATE="$PLUGIN_ROOT/templates/opencode.sandbox.json"

START_SECONDS=$SECONDS

# ---------------------------------------------------------------------------
# Contract state + single-emission guarantee
# ---------------------------------------------------------------------------
STATUS="fail"
ATTEMPTS=0
SESSION_ID=""
COST=""
ORACLE_EXIT=""
LOG_PATH=""
ABORT_REASON="unexpected_exit"
ORACLE_FILES_MODIFIED=""
COMMIT_SHA=""
ORACLE_START_STATE=""
EMITTED=0
AUDIT_READY=0
DISPATCH_DIR=""
INSTALLED_CONFIG=0

log() { echo "opencode-dispatch: $*" >&2; }

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

as_json_string() {
  [ -z "${1:-}" ] && { printf 'null'; return; }
  jq -Rn --arg v "$1" '$v'
}
as_json_number() {
  local v="${1:-}"
  if [ -n "$v" ] && printf '%s' "$v" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
    printf '%s' "$v"
  else
    printf 'null'
  fi
}
# Space-separated file list -> JSON array of strings, or null if empty.
as_json_string_array() {
  if [ -z "${1:-}" ]; then
    printf 'null'
    return
  fi
  jq -Rn --arg v "$1" '$v | split(" ") | map(select(length > 0))'
}

# LOG_PATH lives under $DISPATCH_DIR, which on_exit deletes unless
# IMPS_KEEP_DISPATCH_DIR=1 — so a contract that always advertised LOG_PATH
# would, on every normal run, point at a directory this same trap invocation
# is about to remove. Report it only when it will actually still exist.
effective_log_path() {
  [ "${IMPS_KEEP_DISPATCH_DIR:-}" = "1" ] && [ -n "$LOG_PATH" ] && printf '%s' "$LOG_PATH"
  return 0
}

emit_contract() {
  if [ "$HAVE_JQ" = 0 ]; then
    # jq is a hard dependency of this repo's tooling, but the contract says
    # "exactly one line, always" — so even this path emits one.
    #
    # DRIFT HAZARD: this is a hand-written literal, so adding a field to the jq
    # branch below without adding it here silently ships two different contract
    # shapes. The unit harness cannot reach this branch (HAVE_JQ is derived from
    # `command -v jq` at source time, so it is always 1 in CI), so the key-list
    # parity check lives in tests/dispatch-guards.sh, which forces this path with
    # `env -i PATH= /bin/bash`. Keep the key ORDER matching the jq object too.
    printf '{"status":"%s","attempts":%s,"session_id":null,"cost_usd":null,"oracle_exit":null,"log_path":null,"abort_reason":"jq_missing","oracle_files_modified":null,"commit_sha":null,"oracle_start_state":null}\n' \
      "$STATUS" "$ATTEMPTS" >&3
    return
  fi
  jq -nc \
    --arg     status                 "$STATUS" \
    --argjson attempts                "$(as_json_number "$ATTEMPTS")" \
    --argjson session_id              "$(as_json_string "$SESSION_ID")" \
    --argjson cost_usd                "$(as_json_number "$COST")" \
    --argjson oracle_exit             "$(as_json_number "$ORACLE_EXIT")" \
    --argjson log_path                "$(as_json_string "$(effective_log_path)")" \
    --argjson abort_reason            "$(as_json_string "$ABORT_REASON")" \
    --argjson oracle_files_modified   "$(as_json_string_array "$ORACLE_FILES_MODIFIED")" \
    --argjson commit_sha              "$(as_json_string "$COMMIT_SHA")" \
    --argjson oracle_start_state      "$(as_json_string "$ORACLE_START_STATE")" \
    '{status:$status, attempts:$attempts, session_id:$session_id, cost_usd:$cost_usd,
      oracle_exit:$oracle_exit, log_path:$log_path, abort_reason:$abort_reason,
      oracle_files_modified:$oracle_files_modified, commit_sha:$commit_sha,
      oracle_start_state:$oracle_start_state}' >&3
}

write_audit() {
  [ "$AUDIT_READY" = 1 ] || return 0
  [ -x "$AUDIT" ] || return 0
  local status_word="failed"
  local -a cost_arg=()
  [ "$STATUS" = "pass" ] && status_word="completed"
  [ "$(as_json_number "$COST")" = "null" ] || cost_arg=(--cost-usd "$COST")
  # `|| echo`, not `|| true`: audit-log.sh is already fail-soft on every
  # environmental problem, so a blanket `|| true` would mask only its exit-1
  # argument-bug path — the one case that should surface (see AGENTS.md).
  "$AUDIT" --plugin imps --command /imps:opencode-dispatch \
    --exit-status "$status_word" \
    --duration-ms "$(( (SECONDS - START_SECONDS) * 1000 ))" \
    --tier opencode --attempts "$ATTEMPTS" \
    "${cost_arg[@]+"${cost_arg[@]}"}" \
    --notes "opencode harness: model=$MODEL oracle_exit=${ORACLE_EXIT:-na} abort=${ABORT_REASON:-none}" \
    || echo "audit-log failed (non-fatal)" >&2
}

on_exit() {
  if [ "$EMITTED" = 0 ]; then
    EMITTED=1
    write_audit
    emit_contract
  fi
  # Never leave an untracked opencode.json behind: besides being messy, a
  # later unrelated `git add -A` in this same worktree (e.g. a different tool,
  # or an operator) could commit it for real — this file was never meant to
  # enter shared history.
  if [ "$INSTALLED_CONFIG" = 1 ] && [ -n "$WT" ]; then
    rm -f "$WT/opencode.json"
  fi
  # The dispatch dir holds a copy of auth.json — do not leave it lying around.
  if [ -n "$DISPATCH_DIR" ] && [ "${IMPS_KEEP_DISPATCH_DIR:-}" != "1" ]; then
    rm -rf "$DISPATCH_DIR"
  elif [ -n "$DISPATCH_DIR" ]; then
    log "kept dispatch dir (contains a copy of auth.json): $DISPATCH_DIR"
  fi
}
# EXIT alone misses SIGINT/SIGTERM in some shells/states — and on_exit's job
# here (wiping a plaintext auth.json copy) is exactly the kind of cleanup that
# must not depend on a clean shutdown. SIGKILL is still unstoppable; nothing
# can trap that.
#
# A signal trap that only runs on_exit (without calling `exit`) lets the
# script fall through and keep running afterwards — demonstrated: on TERM the
# script resumed after the interrupted `wait`, went on to run the oracle and
# `git commit`, and could exit 0 with a "fail"/unexpected_exit contract line
# already emitted on stdout. Each of these calls `exit` explicitly, which
# fires the EXIT trap above exactly once and actually ends the process.
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

finish() { # finish <status> <exit-code> [abort_reason]
  STATUS="$1"
  ABORT_REASON="${3:-}"
  exit "$2"
}
abort() { # abort <slug> <message...>
  local slug="$1"; shift
  log "$*"
  finish fail 1 "$slug"
}

# ---------------------------------------------------------------------------
# A portable timeout, deliberately bash-native rather than shelling out to
# GNU coreutils' `timeout`: SRE review flagged that binary is not on stock
# macOS, and — confirmed empirically while testing this — it cannot invoke a
# shell function by name at all (`timeout: failed to run command
# 'run_sandboxed_direct': No such file or directory`; it execs directly,
# bypassing the calling shell's function table entirely), which every call
# site here needs since $@ is always a function, not a plain binary.
# Backgrounds the command directly (no extra function-call subshell layer in
# between) so $! is the PID that will `exec` into the real sandboxed process —
# sandbox-wrap.sh's own `exec "$SAFEHOUSE_BIN" ...` preserves that PID across
# the exec, so a TERM sent here reaches the actual process, not an
# already-gone wrapper shell.
# run_with_timeout <seconds> <cmd...> — the doc'd "-- <cmd...>" form was never
# actually implemented (neither call site below passes "--", and this
# function never checks for or strips one); corrected to match reality.
run_with_timeout() {
  local secs="$1"; shift
  # `kill -TERM "$pid"` alone reaches only that one process — demonstrated:
  # the oracle's/model's own child processes (opencode's shell children, a
  # test runner it started) survive a plain-PID kill and keep running — and
  # keep writing to the worktree — afterwards, including during the
  # unsandboxed commit that follows. `set -m` gives the backgrounded job its
  # own process group (pgid == its own pid), so `kill -TERM -"$pid"`
  # (negative PID = signal the whole group) reaches every descendant that
  # hasn't detached into its own session.
  local monitor_was_on=0
  case "$-" in *m*) monitor_was_on=1 ;; esac
  set -m
  "$@" &
  local pid=$!
  [ "$monitor_was_on" = 1 ] || set +m
  # Sentinel for "the watchdog actually fired", not the raw signal-death exit
  # code: a legitimately-signalled process can also die with 143, and nothing
  # here ever produced GNU coreutils' conventional 124 despite callers
  # checking for it (dead code). Returning 124 only when this function itself
  # did the killing makes the timeout condition unambiguous to the caller.
  # `mktemp` itself CREATES the flag file (empty), so an existence check below
  # would be true from that instant regardless of whether the watchdog ever
  # fired — every call would report 124. The watchdog must WRITE a byte to it
  # on timeout, and the caller must check non-empty (-s), not existence (-f).
  #
  # FAIL CLOSED if the sentinel cannot be created. Without it the watchdog's write
  # is skipped, the 128+signal comparison below never matches, and this function
  # returns the raw 143 instead of the 124 sentinel — so the caller's
  # `attempt_timeout` check silently stops firing, the oracle runs over the killed
  # attempt's truncated edits, and a green oracle commits them and mints a durable
  # ref. That is verbatim the false pass this harness exists to prevent, arrived at
  # through a disk/inode failure nobody would think to look for. Rare, but
  # "fail-closed beats fail-open everywhere safety-relevant" (AGENTS.md), and there
  # is no safe way to run a timeout you cannot detect.
  local timed_out_flag=""
  if ! timed_out_flag="$(mktemp "${TMPDIR:-/tmp}/imps-timeout-flag.XXXXXX" 2>/dev/null)"; then
    log "cannot create the timeout sentinel — refusing to run: timeout detection would fail open"
    return 125
  fi
  # The watchdog records WHICH signal it just sent, not a constant '1', so the
  # check below can compare against 128+that signal rather than hardcoding
  # 143/137. Signal numbers are not fixed by POSIX; ask the shell for them
  # (`kill -l TERM` -> 15) and only fall back to the conventional values if
  # that ever returns something non-numeric.
  local term_signum kill_signum
  term_signum="$(kill -l TERM 2>/dev/null)"; case "$term_signum" in ''|*[!0-9]*) term_signum=15 ;; esac
  kill_signum="$(kill -l KILL 2>/dev/null)"; case "$kill_signum" in ''|*[!0-9]*) kill_signum=9  ;; esac
  (
    sleep "$secs" 2>/dev/null
    # Sentinel BEFORE the kill, not after: written after, the killed process can
    # reap and the `wait` below return while this subshell is still between the
    # two statements — the main shell then kills this watchdog before the write
    # lands, sees an empty flag, and returns the raw 143 instead of the 124
    # sentinel. Downstream that turns a timed-out oracle into an ordinary oracle
    # failure: no `oracle_timeout` abort, and another paid attempt.
    [ -n "$timed_out_flag" ] && printf '%s' "$term_signum" >"$timed_out_flag"
    kill -TERM "-$pid" 2>/dev/null
    sleep 10
    [ -n "$timed_out_flag" ] && printf '%s' "$kill_signum" >"$timed_out_flag"
    kill -KILL "-$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  local watchdog=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # Best-effort cleanup, not a closed guarantee: force-kill anything still
  # alive in the same process group now that `wait` has returned, narrowing
  # (not eliminating — a descendant that detached into its own session, per
  # the comment above, is outside this process group entirely and untouched
  # by either this or the TERM above) the window before the caller's next
  # unsandboxed git command runs. `kill -0` first: PGIDs are reused by the
  # kernel, so an unconditional `kill -KILL "-$pid"` here — well after `wait`
  # returned, unlike the watchdog's own use of this same pattern immediately
  # after sending TERM — has more time to land on a since-recycled, unrelated
  # process group. The check-then-kill has its own inherent TOCTOU gap (a
  # PGID could still be recycled between the two), but narrows the same class
  # of risk this whole line is already just narrowing, not closing.
  kill -0 "-$pid" 2>/dev/null && kill -KILL "-$pid" 2>/dev/null
  # The sentinel alone can't distinguish "the watchdog fired" from "the
  # watchdog's kill is why the process died" — a child that exits on its own
  # at ~T=secs races the watchdog's own sleep(secs) waking at the same instant.
  # `rc != 0` alone is NOT enough: verified live, it still misreports 124 on a
  # child whose OWN unrelated non-zero exit (e.g. a real oracle failure, rc=1)
  # happens to land near the same boundary — and reordering the sentinel
  # before the kill (above) made this MORE likely, not less, because the flag
  # now gets written before the watchdog's kill has to actually race anything.
  # That case is the damaging one: a real oracle failure reported as
  # oracle_timeout is terminal (no retry), where a real rc=1 would correctly
  # retry with the failure fed back to the model. What `rc` CAN tell us,
  # unambiguously, is whether the process died BY THE SIGNAL THIS WATCHDOG
  # SENT: a natural exit (whatever its code) is never 128+n for that signal.
  # The sentinel carries the signal number the watchdog actually sent, so this
  # compares rc against 128+that rather than against hardcoded 143/137 — the
  # numbers now come from the same `kill -l` the watchdog used, on whatever
  # platform this is running.
  local timed_out_signum=""
  if [ -n "$timed_out_flag" ]; then
    [ -s "$timed_out_flag" ] && timed_out_signum="$(cat "$timed_out_flag" 2>/dev/null)"
    rm -f "$timed_out_flag"
  fi
  case "$timed_out_signum" in
    ''|*[!0-9]*) ;;
    *) [ "$rc" -eq "$((128 + timed_out_signum))" ] && return 124 ;;
  esac
  return "$rc"
}

resolve_model_alias() {
  case "$1" in
    cheap)   echo "opencode-go/deepseek-v4-flash" ;;
    default) echo "opencode-go/qwen3.7-max" ;;
    *)       echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Durability + trust helpers. Deliberately ABOVE the __SOURCED__ guard: every
# one of them is pure git plumbing or pure string logic — no sandbox, no
# opencode, no spend — so tests/dispatch-guards.sh can prove the guarantees
# they carry (a commit that survives worktree deletion; "the model changed
# nothing") for free, on any platform, instead of only through a real paid
# dispatch on macOS.
# ---------------------------------------------------------------------------

# validate_result_branch <name> -> prints "ok" | "invalid"
# `git check-ref-format` alone is NOT sufficient: it accepts "refs/heads/-x"
# (verified), so a leading '-' would sail through and then be eaten as an
# option by whatever consumes the name. Reject empty, leading '-', and an
# explicit refs/ prefix (this flag names a BRANCH; the refs/heads/ prefix is
# added by the harness) before deferring to git for the rest.
validate_result_branch() {
  local n="${1:-}"
  case "$n" in
    '')     printf 'invalid\n'; return 1 ;;
    -*)     printf 'invalid\n'; return 1 ;;
    refs/*) printf 'invalid\n'; return 1 ;;
  esac
  if git check-ref-format "refs/heads/$n" >/dev/null 2>&1; then
    printf 'ok\n'; return 0
  fi
  printf 'invalid\n'; return 1
}

# classify_oracle_state <exit-code> -> prints "red" | "green"
# Callers MUST rule out the timeout (124) and sandbox-failure exit codes before
# calling this: a timed-out oracle has no state at all, and calling it "red"
# would fabricate a measurement rather than record one.
classify_oracle_state() {
  if [ "${1:-}" = "0" ]; then printf 'green\n'; else printf 'red\n'; fi
}

# expect_oracle_verdict <expected: red|green|any> <observed: red|green>
#   -> prints "ok" | "mismatch"
# An unrecognised <expected> is a mismatch, not an "any": fail closed, so a
# typo'd flag can never silently disable the check it was meant to add.
expect_oracle_verdict() {
  case "${1:-}" in
    any) printf 'ok\n'; return 0 ;;
    red|green)
      if [ "${1:-}" = "${2:-}" ]; then printf 'ok\n'; return 0; fi
      printf 'mismatch\n'; return 1 ;;
    *) printf 'mismatch\n'; return 1 ;;
  esac
}

# Test-only probe: same reason run_with_timeout_probe exists — tests/run.sh's
# unit harness calls "$func" "$(cat arg)", exactly one argument, so a two-arg
# function is not fixturable verbatim. Splits one newline-delimited argument
# rather than contorting the production signature to suit the harness.
expect_oracle_verdict_probe() {
  local expected="" observed=""
  { IFS= read -r expected; IFS= read -r observed; } <<<"$1"
  expect_oracle_verdict "$expected" "$observed"
}

# create_result_ref <worktree> <sha> <auto-ref> [branch]
# Writes the unconditional durability ref first, THEN the optional named
# branch, so a branch collision still leaves the work durable. Prints a
# diagnostic and returns 1 on failure.
#
# Auto-ref: a plain update-ref, not a CAS. Its name embeds the sha, so the only
# way it can already exist is a prior dispatch in the same UTC second that
# produced the identical commit — writing the same value again is a genuine
# no-op, whereas a CAS would turn it into a spurious result_ref_failed.
#
# Named branch: an atomic compare-and-swap (`update-ref <ref> <sha> ""`, where
# an empty oldvalue means "must not already exist"), never check-then-write —
# two concurrent dispatches racing a check-then-write would both "succeed" and
# one would silently clobber the other's result.
#
# -c core.hooksPath=/dev/null: update-ref fires the reference-transaction hook,
# and this runs OUTSIDE the sandbox after untrusted model output has executed.
# -c core.fsmonitor=false: this file's convention for every unsandboxed git
# command (see the commit block's comment).
create_result_ref() {
  local wt="$1" sha="$2" auto_ref="$3" branch="${4:-}" err=""
  if ! err="$(git -C "$wt" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        update-ref "$auto_ref" "$sha" 2>&1)"; then
    printf 'cannot create %s: %s\n' "$auto_ref" "$err"
    return 1
  fi
  [ -n "$branch" ] || return 0
  if ! err="$(git -C "$wt" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        update-ref "refs/heads/$branch" "$sha" "" 2>&1)"; then
    printf 'auto-ref %s LANDED and the commit is durable; only refs/heads/%s failed (it already exists, or the ref store rejected it): %s\n' "$auto_ref" "$branch" "$err"
    return 1
  fi
  return 0
}

# restore_worktree_clean <worktree> — returns 0 iff the tree is clean afterwards.
#
# The preflight oracle runs before the model does, and any untracked,
# non-ignored file it writes (build output, a test cache) would be swept up by
# the harness's own `git add -A` — making the commit succeed on a task where
# the model never edited anything, which is exactly the false pass the
# commit_failed guard used to catch. `:602`'s worktree_dirty check already
# proved the tree was clean at dispatch start, so the correct baseline is not
# "remember the dirt" but "put it back": restore tracked files and remove the
# new ones.
#
# `-- ':(exclude)opencode.json'` on the clean, so the harness's own hardened
# config (which carries the external_directory:"deny" containment the whole
# sandbox story rests on) survives — verified on git 2.55 that clean does spare
# it. No `-x`: without it, clean removes exactly the set `git add -A` would
# stage, which is precisely the set that matters here.
restore_worktree_clean() {
  local wt="$1"
  # rc deliberately unchecked: `checkout -- .` errors on a repo with zero
  # tracked files, which is not a failure of this function's postcondition.
  # The status check below is the actual contract.
  git -C "$wt" -c core.fsmonitor=false checkout -- . >/dev/null 2>&1
  git -C "$wt" -c core.fsmonitor=false clean -fdq -- ':(exclude)opencode.json' >/dev/null 2>&1
  [ -z "$(git -C "$wt" -c core.fsmonitor=false status --porcelain -- ':(exclude)opencode.json' 2>/dev/null)" ]
}

# stage_model_changes <worktree>
# Mirrors `git diff --cached --quiet`, deliberately: rc 0 == NOTHING staged
# (the model changed nothing), rc 1 == something staged.
#
# "The index is empty" IS the definition of "the model changed nothing" — an
# exact test, not a proxy — and it keeps commit_failed unambiguous downstream
# (index non-empty but the commit still failed == the machinery broke).
stage_model_changes() {
  local wt="$1"
  git -C "$wt" -c core.fsmonitor=false add -A -- ':(exclude)opencode.json'
  git -C "$wt" -c core.fsmonitor=false diff --cached --quiet
}

if [ -n "${__SOURCED__:-}" ]; then
  # Unlike audit-log.sh's own __SOURCED__ guard (registers no traps before
  # its guard line), `trap on_exit EXIT` above already ran by the time
  # sourcing reaches here — left alone, it fires on the SOURCING shell's own
  # exit and prints a stray contract-JSON line after the probe's real output,
  # breaking an exact-match test comparison. Clear it before returning.
  trap - EXIT HUP INT TERM
  return 0
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
WT="" PROMPT_FILE="" ORACLE="" MODEL="opencode-go/qwen3.7-max" MAX_ATTEMPTS=3 MODE=""
ATTEMPT_TIMEOUT=300 ORACLE_TIMEOUT=120 ORACLE_GUARD=""
RESULT_BRANCH="" RESULT_BRANCH_SET=0 EXPECT_ORACLE="any" ENGINE="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree)        WT="${2:-}";              shift 2 ;;
    --prompt-file)     PROMPT_FILE="${2:-}";      shift 2 ;;
    --oracle)          ORACLE="${2:-}";           shift 2 ;;
    --model)           MODEL="${2:-}";            shift 2 ;;
    --max-attempts)    MAX_ATTEMPTS="${2:-}";     shift 2 ;;
    --sandbox-mode)    MODE="${2:-}";             shift 2 ;;
    --attempt-timeout) ATTEMPT_TIMEOUT="${2:-}";  shift 2 ;;
    --oracle-timeout)  ORACLE_TIMEOUT="${2:-}";   shift 2 ;;
    --oracle-guard)    ORACLE_GUARD="${2:-}";     shift 2 ;;
    --result-branch)   RESULT_BRANCH="${2:-}"; RESULT_BRANCH_SET=1; shift 2 ;;
    --expect-oracle)   EXPECT_ORACLE="${2:-}";    shift 2 ;;
    --engine)          ENGINE="${2:-}";            shift 2 ;;
    *) abort bad_arguments "unknown argument: $1" ;;
  esac
done

[ "$HAVE_JQ" = 1 ] || abort jq_missing "'jq' is required"

# The permission entry that lets this script run already disables Claude Code's
# own Bash sandbox. If the wrapper's sandbox is disabled too, a cheap --auto
# model runs at full privilege with no boundary at any layer. Refuse outright.
[ -z "${IMPS_SANDBOX_DANGEROUSLY_DISABLE:-}" ] || \
  abort sandbox_bypass_refused "IMPS_SANDBOX_DANGEROUSLY_DISABLE is set — refusing to dispatch"

[ -n "$WT" ]          || abort bad_arguments "--worktree is required"
[ -n "$PROMPT_FILE" ] || abort bad_arguments "--prompt-file is required"
[ -n "$ORACLE" ]      || abort bad_arguments "--oracle is required"
[ -f "$PROMPT_FILE" ] || abort bad_arguments "prompt file not found: $PROMPT_FILE"
case "$MAX_ATTEMPTS" in ''|0|*[!0-9]*) abort bad_arguments "--max-attempts must be a positive integer, got '$MAX_ATTEMPTS'" ;; esac
case "$ATTEMPT_TIMEOUT" in ''|0|*[!0-9]*) abort bad_arguments "--attempt-timeout must be a positive integer, got '$ATTEMPT_TIMEOUT'" ;; esac
case "$ORACLE_TIMEOUT" in ''|0|*[!0-9]*) abort bad_arguments "--oracle-timeout must be a positive integer, got '$ORACLE_TIMEOUT'" ;; esac
case "$EXPECT_ORACLE" in red|green|any) ;; *) abort bad_arguments "--expect-oracle must be one of red|green|any, got '$EXPECT_ORACLE'" ;; esac
case "$ENGINE" in auto|opencode|agy) ;; *) abort bad_arguments "--engine must be one of auto|opencode|agy, got '$ENGINE'" ;; esac
[ "$ENGINE" = "agy" ] && abort engine_unsupported "--engine agy is not yet supported for sandboxed dispatch in this harness"
# Name validation here, collision check further down (it needs a resolved
# worktree). Both are deliberately BEFORE the auth_missing check, so a
# malformed or already-taken branch name fails fast and free rather than after
# the credential copy and the sandbox smoke test.
#
# Gated on RESULT_BRANCH_SET, not on `-n "$RESULT_BRANCH"`: the unset default is
# also the empty string, and `--result-branch ''` is an operator error that must
# be reported rather than silently treated as "no branch wanted".
if [ "$RESULT_BRANCH_SET" = 1 ] && [ "$(validate_result_branch "$RESULT_BRANCH")" != "ok" ]; then
  abort bad_arguments "--result-branch '$RESULT_BRANCH' is not a usable branch name (empty, leading '-', a refs/ prefix, or rejected by git check-ref-format)"
fi

# Model guard. Reject on *substring*, not prefix: `--model
# openrouter/anthropic/claude-sonnet-4` sails past a prefix check and bills a
# Claude model through opencode — the exact ToS anti-goal this tier exists to
# avoid. Allowlist the known-good providers, then re-check the whole string.
MODEL="$(resolve_model_alias "$MODEL")"
case "$MODEL" in
  opencode-go/*|opencode/*) ;;
  *) abort model_rejected "model '$MODEL' is not on the provider allowlist (opencode-go/*, opencode/*)" ;;
esac
case "$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')" in
  *claude*|*anthropic*) abort model_rejected "model '$MODEL' names a Claude/Anthropic model — route judgment work through Claude Code instead" ;;
esac

OPENCODE_BIN="$(command -v opencode 2>/dev/null)"
[ -n "$OPENCODE_BIN" ] || abort opencode_missing "'opencode' is not on PATH"

WT="$(cd "$WT" 2>/dev/null && pwd -P)" || abort bad_arguments "--worktree is not a directory"
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || abort bad_arguments "--worktree is not a git worktree: $WT"

# Cheap fail-fast for the operator. The authoritative check is the atomic CAS in
# create_result_ref at the very end — this is NOT a check-then-write substitute
# for it, just a way to report a collision now instead of after a paid dispatch.
if [ -n "$RESULT_BRANCH" ] && git -C "$WT" show-ref --verify --quiet "refs/heads/$RESULT_BRANCH"; then
  abort bad_arguments "--result-branch '$RESULT_BRANCH' already exists in this repository — pick another name or delete it first"
fi
# Every contract this harness relies on (the gitmeta-pointer snapshot below,
# the sandbox's own worktrees/*/config.worktree deny) is written against a
# LINKED worktree specifically — "the shape every real dispatch uses" — and
# was never actually enforced: a MAIN worktree (.git is a directory, not the
# linked-worktree redirect file) satisfies --is-inside-work-tree above just as
# well, but for it $REAL_GITDIR == $GITMETA exactly (not a subpath), so the
# case match below that populates GITMETA_POINTER_PATHS never fires and the
# snapshot degenerates to a single constant "MISSING" line for the whole run —
# verified live. Cheap early-exit for the common case; this alone is NOT the
# real invariant (see the strict subpath assertion once REAL_GITDIR is
# resolved below — a `git init --separate-git-dir` main worktree and a
# submodule's working dir BOTH have a '.git' FILE and pass this, yet their
# gitdir still equals $GITMETA exactly rather than living under it, verified
# live to slip past this alone).
[ -f "$WT/.git" ] || abort bad_arguments \
  "--worktree must be a LINKED worktree (a '.git' FILE pointing at the shared gitdir, not a main worktree's '.git' directory): $WT"

resolve_gitpath() { # resolve_gitpath <git rev-parse flag>
  local p
  p="$(git -C "$WT" rev-parse "$1" 2>/dev/null)" || return 1
  case "$p" in /*) ;; *) p="$WT/$p" ;; esac
  ( cd "$p" && pwd -P )
}
# The COMMON dir, not --git-dir: gitrepository-layout says `info/` is ignored
# when $GIT_COMMON_DIR is set, so in a linked worktree an exclude written to the
# per-worktree git dir is silently never read (verified — opencode.json stayed
# untracked-and-visible).
GITMETA="$(resolve_gitpath --git-common-dir)" || abort bad_arguments "cannot resolve --git-common-dir for $WT"
BASE_SHA="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || abort bad_arguments "cannot resolve HEAD in $WT"

# A dirty worktree would get folded into the model's own harness commit below
# (`git add -A` doesn't distinguish operator WIP from the model's edits), and
# would poison the oracle-guard diff (`git diff "$BASE_SHA" -- "$ORACLE_GUARD"`)
# by misattributing already-dirty guarded files to the model. This v1's whole
# purpose is an uncontaminated measurement — refuse rather than silently mix
# pre-existing changes into the reported result.
#
# -c core.fsmonitor=false: this is the one unsandboxed, index-reading git
# command in this file that ran without it before this line was added — every
# other one carries it as belt-and-braces (see the pointer-snapshot comment
# below). This runs before THIS dispatch's own model turn, but $GITMETA is
# shared and long-lived: an earlier dispatch, a sibling imp, or a stale
# planted config from before this file's own denies existed could still fire
# it at operator privilege here first.
if [ -n "$(git -C "$WT" -c core.fsmonitor=false status --porcelain 2>/dev/null)" ]; then
  abort worktree_dirty "worktree has uncommitted changes before dispatch — commit or stash them first: $WT"
fi

# The pointer files that decide WHICH config/hooks git actually reads for this
# worktree — not the config/hooks files themselves. Denying writes to
# <gitmeta>/hooks and <gitmeta>/config (deny-credentials.sbpl.in) does nothing
# if the model instead rewrites $WT/.git — a plain-text redirect file,
# necessarily writable since it lives inside the granted worktree — to point
# at a model-created fake gitdir also inside the worktree, complete with its
# own config setting core.fsmonitor (or a clean/smudge filter) to an arbitrary
# command. The harness's own `git add`/`commit` below run OUTSIDE the sandbox
# and would follow that redirect and execute the model's command at full
# operator privilege — reproduced live during review against exactly this
# grant shape. <gitmeta>/worktrees/<name>/commondir is the second half of the
# same redirect chain and is likewise inside the writable gitmeta grant.
# Snapshotting these bytes before the model ever runs and refusing to commit
# if they changed closes this regardless of which pointer gets rewritten.
# shasum -a 256, not cksum: cksum is CRC32+length, an affine checksum forgeable
# at fixed length with a handful of chosen bytes — and the model can read every
# one of these pointer files (they're inside its own grants) and run cksum
# itself inside the sandbox to find a colliding rewrite. This snapshot is the
# load-bearing check for the whole boundary; a real hash removes that class.
REAL_GITDIR="$(resolve_gitpath --git-dir)" || abort bad_arguments "cannot resolve --git-dir for $WT"
# The actual invariant every pointer-snapshot path below depends on: REAL_GITDIR
# must be a STRICT subpath of GITMETA (the per-worktree gitdir living under the
# common dir's worktrees/ subtree), not merely equal to it. The `-f "$WT/.git"`
# check above is only a cheap proxy and is NOT sufficient on its own — verified
# live that both a `git init --separate-git-dir` main worktree and a
# submodule's working directory have a '.git' FILE (satisfying that check) yet
# resolve REAL_GITDIR == GITMETA exactly, silently degenerating the snapshot
# below to a single "$WT/.git: MISSING" line for the whole run. Assert the real
# invariant here, where GITMETA is actually known, rather than trust the proxy.
case "$REAL_GITDIR" in
  "$GITMETA"/*) : ;;  # OK — genuinely a linked worktree's own gitdir
  *) abort bad_arguments \
       "--worktree's gitdir ($REAL_GITDIR) is not a subdirectory of the shared common dir ($GITMETA) — got a main worktree, a --separate-git-dir repo, or a submodule, not a linked worktree of a normal repo" ;;
esac
GITMETA_POINTER_PATHS=("$WT/.git")
# config.worktree in the PER-WORKTREE gitdir, not just the common dir.
# deny-credentials.sbpl.in denies (literal "@GITMETA@/config.worktree"), but
# @GITMETA@ is the git COMMON dir, and for a linked worktree — the shape every
# real dispatch uses — git reads $GIT_DIR/config.worktree, i.e.
# <gitmeta>/worktrees/<name>/config.worktree (verified live). That path sits
# inside the read-write --add-dirs "$GITMETA" grant and is not denied, so a
# model can drop a `[filter "x"] clean = <cmd>` there (plus a .gitattributes in
# the worktree) and the harness's own UNSANDBOXED `git add -A` below executes
# <cmd> at operator privilege — `-c core.fsmonitor=false` covers fsmonitor, not
# filters. Snapshotting these bytes catches it regardless of
# extensions.worktreeConfig, which is the only reason the deny list's gap is
# not already exploitable everywhere.
# NOTE: "$REAL_GITDIR/config" (the per-worktree gitdir's own "config" file) is
# never consulted by git for a linked worktree in either worktreeConfig mode —
# verified live — so it isn't snapshotted. "$GITMETA/config" (the COMMON dir's
# config, the file git actually reads and the one deny-credentials.sbpl.in's
# own header calls the load-bearing risk) was missing from this list entirely;
# it's now included alongside the per-worktree config.worktree. No `case` guard
# needed here — the assertion above already refused to reach this line unless
# REAL_GITDIR is confirmed under GITMETA.
# "$GITMETA/commondir" (and "$GITMETA/gitdir" beside it): git reads
# <gitdir>/commondir from ANY gitdir, so the COMMON dir's own commondir
# repoints $GIT_COMMON_DIR for the main checkout — verified live as arbitrary
# execution at operator privilege on the operator's own next `git status`,
# since every command this harness runs uses -C "$WT" and resolves
# "$REAL_GITDIR/commondir" instead, never noticing. Denied outright in
# deny-credentials.sbpl.in; snapshotted here too because the deny list is one
# rendered profile away from a regression and this check is cheap.
GITMETA_POINTER_PATHS+=("$REAL_GITDIR/commondir" "$REAL_GITDIR/gitdir" "$REAL_GITDIR/HEAD" \
                        "$REAL_GITDIR/config.worktree" \
                        "$GITMETA/config" "$GITMETA/config.worktree" \
                        "$GITMETA/commondir" "$GITMETA/gitdir")
snapshot_gitmeta_pointers() {
  local p
  for p in "${GITMETA_POINTER_PATHS[@]}"; do
    if [ -f "$p" ]; then shasum -a 256 "$p" 2>/dev/null; else printf '%s: MISSING\n' "$p"; fi
  done
}
GITMETA_POINTER_BASELINE="$(snapshot_gitmeta_pointers)"

REAL_TMP_CANON="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || abort bad_arguments "TMPDIR is not a directory"

# ---------------------------------------------------------------------------
# Credential isolation (contract §D): redirect ALL FOUR XDG dirs, copy only
# auth.json into the redirected data dir, and let sandbox-wrap.sh's terminal
# deny make the originals unreadable. Redirecting XDG_CONFIG_HOME also means
# the real ~/.config/opencode/opencode.json is never found or merged, so the
# worktree-level opencode.json below is the sandbox's ONLY effective config.
# ---------------------------------------------------------------------------
AUTH_SRC="$HOME/.local/share/opencode/auth.json"
[ -f "$AUTH_SRC" ] || abort auth_missing "opencode credentials not found at $AUTH_SRC"

DISPATCH_DIR="$(mktemp -d "$REAL_TMP_CANON/imps-opencode.XXXXXX")" || abort dispatch_dir_failed "cannot create dispatch dir under $REAL_TMP_CANON"
mkdir -p "$DISPATCH_DIR/data/opencode" "$DISPATCH_DIR/state" "$DISPATCH_DIR/config" "$DISPATCH_DIR/cache" "$DISPATCH_DIR/tmp" \
  || abort dispatch_dir_failed "cannot populate $DISPATCH_DIR"
cp "$AUTH_SRC" "$DISPATCH_DIR/data/opencode/auth.json" || abort auth_missing "cannot copy $AUTH_SRC"
chmod 600 "$DISPATCH_DIR/data/opencode/auth.json"

export XDG_DATA_HOME="$DISPATCH_DIR/data"
export XDG_STATE_HOME="$DISPATCH_DIR/state"
export XDG_CONFIG_HOME="$DISPATCH_DIR/config"
export XDG_CACHE_HOME="$DISPATCH_DIR/cache"

# Scope TMPDIR itself to a subdirectory of the dispatch dir before anything
# downstream (including the sandboxed process's own scratch usage, passed
# through by sandbox-wrap.sh's --env-pass) sees it. Without this, the
# sandboxed model would need $TMPDIR granted wholesale for its own runtime
# scratch files — exposing every other process's temp files on the host, not
# just this dispatch's own. Everything this script itself creates from here
# on (the log, the deny profile via sandbox-wrap.sh, oracle output capture)
# also lands under here, so it is covered by the --datadir grant with no
# separate $TMPDIR grant needed at all.
export TMPDIR="$DISPATCH_DIR/tmp"

# Unattended-run switches (contract §C).
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_AUTOCOMPACT=1
export OPENCODE_DISABLE_PRUNE=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
export OPENCODE_DISABLE_SHARE=1
export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER=1

[ -n "$MODE" ] && export SANDBOX_MODE="$MODE"

# Event-stream log lives under the dispatch dir — outside the worktree (the
# harness runs `git add -A`, so a log written inside would be committed: a
# multi-MB JSONL in the diff, with the "a commit exists" assertion still
# passing) and outside the real $TMPDIR (see the TMPDIR note above).
LOG_PATH="$DISPATCH_DIR/dispatch.jsonl"
: >"$LOG_PATH" || abort log_path_failed "cannot write $LOG_PATH"

# ---------------------------------------------------------------------------
# Hardened worktree config (contract §E)
# ---------------------------------------------------------------------------
[ -f "$TEMPLATE" ] || abort config_missing "missing template: $TEMPLATE"
if [ -f "$WT/opencode.json" ]; then
  INSTALLED_CONFIG=0
else
  cp "$TEMPLATE" "$WT/opencode.json" || abort config_missing "cannot install opencode.json into $WT"
  INSTALLED_CONFIG=1
fi
# Assert CONTENT, not presence: a presence-only check guards nothing, and --auto
# with the default external_directory:"ask" runs silently uncontained.
jq -e '.permission.external_directory == "deny"' "$WT/opencode.json" >/dev/null 2>&1 \
  || abort config_missing "$WT/opencode.json does not set permission.external_directory=\"deny\""
# Deliberately NOT written to $GITMETA/info/exclude: GITMETA is the git COMMON
# dir, shared by the main checkout and every linked worktree of this repo — a
# write there would permanently exclude opencode.json everywhere, forever,
# with no cleanup. The scoped pathspec on the commit's `git add -A` below
# keeps the exclusion local to this one dispatch instead, and on_exit removes
# the file itself if this dispatch installed it (see on_exit).

AUDIT_READY=1

# ---------------------------------------------------------------------------
# Preflight — free, and it is the only thing standing between a misconfigured
# sandbox and a paid --auto run with no containment.
# ---------------------------------------------------------------------------
log "preflight: sandbox smoke test"
bash "$SMOKE" 1>&2
smoke_rc=$?
# 77 is sandbox-smoke.sh's "cannot run here" (nested sandbox). Treated as a hard
# stop, not a skip: an unverifiable sandbox is not a verified one, and the next
# step spends money on an --auto model.
[ "$smoke_rc" -eq 77 ] && abort preflight_smoke_failed "sandbox cannot be applied here (nested sandbox) — run this unsandboxed"
[ "$smoke_rc" -eq 0 ] || abort preflight_smoke_failed "sandbox-smoke.sh exited $smoke_rc — refusing to dispatch"

# ---------------------------------------------------------------------------
# Oracle loop
# ---------------------------------------------------------------------------
extract_session() {
  jq -R -c 'fromjson? // empty' "$LOG_PATH" 2>/dev/null \
    | jq -rs '[.. | objects | to_entries[] | select(.key | test("^session_?id$"; "i")) | .value
               | select(type == "string")] | last // empty' 2>/dev/null
}
extract_cost() {
  # Prefer the per-step accounting opencode emits on step_finish; fall back to
  # the last bare `cost` number in the stream. Best-effort by design — the
  # contract allows null.
  jq -R -c 'fromjson? // empty' "$LOG_PATH" 2>/dev/null \
    | jq -rs '([.. | objects | select((.type? // "") == "step_finish") | .cost? | numbers]) as $steps
              | if ($steps | length) > 0 then ($steps | add)
                else ([.. | objects | .cost? | numbers] | last) end
              | if . == null then empty else . end' 2>/dev/null
}

# Direct invocation, not through a shell-function wrapper: run_with_timeout
# needs $! to be the PID that execs into the real sandboxed process.
#
# --real-gitdir "$REAL_GITDIR": this is the value computed and validated ONCE,
# above, before the model has ever run — never re-derived here from $WT/.git,
# which is necessarily writable and gets rewritten by the model on attempt
# 1 for every subsequent sandboxed call this function makes (the oracle run,
# every retry's model turn). sandbox-wrap.sh re-resolving its own REAL_GITDIR
# from $WT/.git on each call was verified live to be a full RCE: a model that
# redirects .git to a sibling worktree's gitdir (or an unrelated repo
# entirely) before the oracle run gets that gitdir's write access granted
# INSIDE the sandbox on this very call, since sandbox-wrap.sh has no way to
# know a redirect happened. Passing the pre-dispatch value explicitly on
# every call closes that regardless of what $WT/.git says by the time this
# runs.
run_sandboxed_direct() {
  bash "$WRAP" --worktree "$WT" --gitmeta "$GITMETA" --real-gitdir "$REAL_GITDIR" --datadir "$DISPATCH_DIR" -- "$@"
}

run_oracle_sandboxed() { # run_oracle_sandboxed <output-file>
  # $ORACLE is passed as a positional parameter into a single-quoted -c body,
  # not interpolated into a double-quoted string — a double-quote inside
  # $ORACLE (e.g. a pytest -k filter) would otherwise terminate the -c
  # argument early and corrupt the invocation.
  run_with_timeout "$ORACLE_TIMEOUT" run_sandboxed_direct /bin/bash -c 'cd "$1" && eval "$2"' _ "$WT" "$ORACLE" \
    >"$1" 2>&1
}

# ---------------------------------------------------------------------------
# Oracle preflight (runs BEFORE the first model attempt, and unconditionally —
# including under --expect-oracle any, because recording the starting state is
# itself the point).
#
# A green-at-start oracle cannot distinguish "implemented correctly" from "did
# nothing" — that is a structural property, not a model weakness, and it is how
# the measurement round produced false passes. `--expect-oracle red` turns that
# into a precondition. `green` catches the opposite failure: a contaminated
# worktree where the task is already done (which once burned five paid attempts
# before anyone noticed).
# ---------------------------------------------------------------------------
PREFLIGHT_OUT_FILE="$DISPATCH_DIR/oracle-out.preflight"
run_oracle_sandboxed "$PREFLIGHT_OUT_FILE"
preflight_rc=$?
preflight_out="$(cat "$PREFLIGHT_OUT_FILE" 2>/dev/null)"
rm -f "$PREFLIGHT_OUT_FILE"

# The preflight just executed a command inside the sandbox, so the SAME
# invariant the post-model check enforces applies here. This sits ahead of EVERY
# other preflight exit, deliberately: under `--expect-oracle red` (which the
# /imps:go executor tier passes unconditionally) the mismatch abort below is the
# ROUTINE exit for any green-at-start task, not an exceptional one. Checking only
# on the paths that continue would leave the common path exiting without ever
# comparing the pointers — and the next dispatch into this worktree re-baselines
# GITMETA_POINTER_BASELINE from whatever was left behind, making a preflight-time
# redirect permanently invisible. Nothing between here and the restore below is a
# git command, so hoisting this costs nothing and strictly widens coverage.
if [ "$(snapshot_gitmeta_pointers)" != "$GITMETA_POINTER_BASELINE" ]; then
  abort gitmeta_tampered "SANDBOX ESCAPE SUSPECTED: worktree/gitmeta pointer files changed during the oracle preflight — refused to continue. Inspect $WT/.git and $GITMETA before running any git command against this repo."
fi

# Rule out "no state at all" BEFORE classifying red/green. A timed-out or
# sandbox-broken oracle has no starting state, and recording it as "red" would
# fabricate a measurement instead of taking one. Same two reasons the in-loop
# oracle treats these as terminal, distinguished only by the message.
if [ "$preflight_rc" -eq 125 ]; then
  abort dispatch_dir_failed "run_with_timeout could not create its timeout sentinel under \$TMPDIR during the oracle preflight — refusing to dispatch without working timeout detection"
fi
if [ "$preflight_rc" -eq 124 ]; then
  abort oracle_timeout "preflight oracle did not finish within ${ORACLE_TIMEOUT}s — cannot establish the starting state, refusing to spend a model attempt"
fi
if [ "$preflight_rc" -eq 2 ] && printf '%s' "$preflight_out" | grep -q '^sandbox-wrap:'; then
  abort oracle_sandbox_failed "sandbox-wrap.sh failed closed while running the preflight oracle: $(printf '%s' "$preflight_out" | grep '^sandbox-wrap:' | head -1)"
fi

ORACLE_START_STATE="$(classify_oracle_state "$preflight_rc")"
log "oracle preflight: starts $ORACLE_START_STATE (exit $preflight_rc); --expect-oracle $EXPECT_ORACLE"
if [ "$(expect_oracle_verdict "$EXPECT_ORACLE" "$ORACLE_START_STATE")" != "ok" ]; then
  abort oracle_preflight_mismatch "oracle starts $ORACLE_START_STATE but --expect-oracle $EXPECT_ORACLE was required — aborting before any model attempt is paid for"
fi

# The pointer snapshot was compared immediately after the preflight oracle
# returned, above — ahead of every abort, so the routine `--expect-oracle`
# mismatch exit is covered too. It must precede restore_worktree_clean, which is
# the first UNSANDBOXED, index-reading git command afterwards, because an
# index-reading git command executes a configured core.fsmonitor hook: with the
# check after, the restore itself is what fires a redirected hook at operator
# privilege.

# Restore-to-clean, not a dirt baseline. Without this the preflight's own
# untracked byproducts get swept into the harness's `git add -A` and the commit
# SUCCEEDS on a task where the model never edited anything — silently defeating
# the commit_failed guard that is currently the only thing catching a zero-edit
# attempt. worktree_dirty above already proved the pre-preflight tree was clean,
# so restoring it is exact.
#
# SLUG OVERLOAD, deliberate: `worktree_dirty` now covers two distinct causes —
# "the operator had uncommitted WIP at dispatch start" (:602) and "the preflight
# oracle contaminated the tree unrecoverably" (here). The messages distinguish
# them; the slug does not, so a consumer bucketing purely on abort_reason
# conflates them. Reused rather than adding a reason because both mean the same
# thing to a caller — the worktree is not in a fit state to dispatch into, and
# neither is worth a retry. A caller that must tell them apart should key off
# oracle_start_state, which is null for the first and populated for this one.
restore_worktree_clean "$WT" || \
  abort worktree_dirty "the preflight oracle left changes that could not be restored — refusing to dispatch into a contaminated worktree: $WT"

# Kept separately from $prompt so a retry can always re-supply full task
# context. --session normally makes this redundant (opencode has its own
# history), but if attempt 1 dies before opencode ever emits a session id (see
# the oc_rc!=0 handling below), SESSION_ID stays empty on retry, --session is
# never added, and a fresh session with only the oracle failure message would
# get zero task context — guaranteed-useless on exactly the failure path this
# loop exists for.
TASK="$(cat "$PROMPT_FILE")"
prompt="$TASK"
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  ATTEMPTS="$attempt"
  oc_args=("$OPENCODE_BIN" run --dir "$WT" --model "$MODEL" --format json --auto)
  [ -n "$SESSION_ID" ] && oc_args+=(--session "$SESSION_ID")
  oc_args+=("$prompt")

  log "attempt $attempt/$MAX_ATTEMPTS — model=$MODEL (timeout ${ATTEMPT_TIMEOUT}s)"
  # Append directly to a regular file, not `| tee`. Live-verified 2026-07-27:
  # piping this call's stdout to `tee` makes it the write end of a pipe
  # inherited across run_with_timeout's `set -m` + `&` backgrounding into the
  # sandbox-exec boundary — and something about that specific fd's lineage
  # makes Bun's internal color-detection code crash with `EPERM: operation
  # not permitted, fstat` while formatting an unrelated startup error,
  # intermittently but on 9+ consecutive real attempts in one session. The
  # oracle call two blocks below already redirects straight to a file with no
  # such failures; this now matches it. Trade-off: no more live echo to
  # stderr while a dispatch runs — read $LOG_PATH (or tail -f it) instead.
  run_with_timeout "$ATTEMPT_TIMEOUT" run_sandboxed_direct "${oc_args[@]}" >>"$LOG_PATH" 2>&1
  oc_rc=$?

  # 125 is run_with_timeout refusing to run because it could not create its
  # timeout sentinel. Terminal: without the sentinel a kill is indistinguishable
  # from a clean exit, so nothing downstream could be trusted.
  if [ "$oc_rc" -eq 125 ]; then
    abort dispatch_dir_failed "run_with_timeout could not create its timeout sentinel under \$TMPDIR — refusing to dispatch without working timeout detection"
  fi

  # Session id and cost are harvested BEFORE the timeout abort below, so a
  # killed attempt still reports what it spent — the operator needs that number
  # even (especially) on the failure path.
  sid="$(extract_session)"
  [ -n "$sid" ] && SESSION_ID="$sid"
  cost="$(extract_cost)"
  [ -n "$cost" ] && COST="$cost"

  # A killed attempt is TERMINAL, not retryable. Retrying is unsound: the
  # killed attempt's truncated edits stay in the worktree, the harness commit is
  # `git add -A`, and so a LATER attempt going green would ship the truncated
  # work anyway — which is exactly how a measurement-round task shipped
  # half-finished code as a pass. The oracle is deliberately not run either: it
  # cannot produce a commit from here, and leaving oracle_exit null is the
  # honest report of "we never got a reading". This matches the precedent
  # already set by the oracle's own rc 124, which has always been terminal.
  if [ "$oc_rc" -eq 124 ]; then
    abort attempt_timeout "attempt $attempt was killed after ${ATTEMPT_TIMEOUT}s — aborting the dispatch: the worktree now holds truncated edits that any later attempt's commit would sweep up"
  fi
  # 2 is also sandbox-wrap.sh's own fail-closed status. It cannot be told apart
  # from an opencode exit 2 here, and the preflight already exercised the
  # backend end-to-end, so this is a warning rather than an abort — the oracle
  # still decides.
  [ "$oc_rc" -eq 2 ] && log "exit 2 — could be opencode, or sandbox-wrap.sh failing closed; check stderr above"

  [ "$oc_rc" -ne 0 ] && log "opencode exited $oc_rc — running the oracle anyway; the oracle decides"

  # The oracle runs inside the sandbox too: the model has just edited this
  # worktree, and executing whatever it wrote outside the boundary would hand
  # back everything the boundary was for. Same call shape as the preflight —
  # they share run_oracle_sandboxed precisely so the two measurements stay
  # comparable.
  ORACLE_OUT_FILE="$DISPATCH_DIR/oracle-out.$attempt"
  run_oracle_sandboxed "$ORACLE_OUT_FILE"
  ORACLE_EXIT=$?
  oracle_out="$(cat "$ORACLE_OUT_FILE" 2>/dev/null)"
  rm -f "$ORACLE_OUT_FILE"
  log "oracle exit $ORACLE_EXIT"

  if [ "$ORACLE_EXIT" -eq 125 ]; then
    abort dispatch_dir_failed "run_with_timeout could not create its timeout sentinel under \$TMPDIR while running the oracle — refusing to trust an oracle result whose timeout cannot be detected"
  fi
  if [ "$ORACLE_EXIT" -eq 124 ]; then
    abort oracle_timeout "oracle did not finish within ${ORACLE_TIMEOUT}s on attempt $attempt"
  fi
  # Exit 2 from the oracle call is ambiguous by design (sandbox-wrap.sh's own
  # fail-closed status collides with any oracle command that happens to use
  # exit code 2 for its own reasons — pytest does, for "execution interrupted").
  # Disambiguate the one way available without changing the wrapper's own exit
  # code: sandbox-wrap.sh's die() always prefixes its message with
  # "sandbox-wrap:" on stderr, which is captured into oracle_out (2>&1 above).
  # Retrying against a broken sandbox wastes a paid attempt on a problem the
  # model cannot fix — abort instead.
  if [ "$ORACLE_EXIT" -eq 2 ] && printf '%s' "$oracle_out" | grep -q '^sandbox-wrap:'; then
    abort oracle_sandbox_failed "sandbox-wrap.sh failed closed while running the oracle on attempt $attempt: $(printf '%s' "$oracle_out" | grep '^sandbox-wrap:' | head -1)"
  fi

  if [ "$ORACLE_EXIT" -eq 0 ]; then
    # This must run BEFORE any other unsandboxed git command touching the
    # worktree — including the oracle-guard diff just below. Index-reading git
    # commands execute a configured core.fsmonitor hook, so if the model
    # redirected $WT/.git to a fake gitdir, the FIRST unsandboxed git
    # invocation after the model ran is what pays for it, regardless of which
    # one it is. Reproduced live: with this check placed after the guard diff,
    # the guard diff itself fired the redirected hook at operator privilege
    # before this check ever got a chance to say gitmeta_tampered. Denying
    # writes to <gitmeta>/hooks and <gitmeta>/config (deny-credentials.sbpl.in)
    # means nothing if the model instead redirected $WT/.git to a fake gitdir
    # of its own — this snapshot comparison is what actually closes that.
    if [ "$(snapshot_gitmeta_pointers)" != "$GITMETA_POINTER_BASELINE" ]; then
      abort gitmeta_tampered "SANDBOX ESCAPE SUSPECTED: worktree/gitmeta pointer files changed during dispatch — refused to commit. Inspect $WT/.git and $GITMETA before running any git command against this repo."
    fi

    # "The model changed nothing" — an EXACT test, not a proxy: stage what the
    # commit would stage, then ask whether the index differs from HEAD. A green
    # oracle proves the acceptance command passes; it says nothing about whether
    # the model did the work, and on a task whose oracle was already green (or
    # was made green by a byproduct) the two are indistinguishable without this.
    #
    # Staged HERE, before the oracle-guard block rather than immediately before
    # the commit, because the abort must happen before anything else reports a
    # verdict. Verified on git 2.55 that this does NOT weaken the guard's
    # untracked-file detection: `add -A` moves non-ignored untracked files out
    # of `ls-files --others` but into `diff --name-only $BASE_SHA`, while
    # *ignored* files (which `add -A` skips) stay in `ls-files --others`
    # exactly as before — so the union the guard actually consumes is unchanged.
    if stage_model_changes "$WT"; then
      abort no_model_changes "oracle went green on attempt $attempt but the model staged no changes — a green oracle over an unmodified worktree is not a pass"
    fi

    # Surface, don't silently swallow: did the model's own edits touch the
    # file(s) the oracle depends on? A model that rewrites its own test to
    # pass trivially is otherwise byte-identical, in this contract, to one
    # that genuinely fixed the code — and this v1's only real output is a
    # pass-rate number that has to mean something. Reported as a FAIL, not a
    # tainted pass: a naive `jq -r .status` consumer (the shape every
    # automated aggregator actually takes) would otherwise miscount a gamed
    # oracle as a genuine one. -c core.fsmonitor=false: this is itself an
    # unsandboxed, index-reading git command, so it gets the same defense in
    # depth as the commit below — the gitmeta_tampered check above is what
    # actually closes the hole, this is belt and braces.
    if [ -n "$ORACLE_GUARD" ]; then
      # `git diff` alone sees only TRACKED changes — verified: a brand-new file
      # under the guarded pathspec is invisible to it. That is the cheapest way
      # to game the oracle without tripping this guard: with --oracle-guard
      # 'tests/*' and an oracle of `pytest -q`, a model that creates a NEW
      # tests/conftest.py emptying the collected item list turns the oracle
      # green while this diff stays empty, and the run is reported as a clean
      # pass. `ls-files --others` is the untracked half of the same question.
      #
      # A prior version of this fix dropped `--exclude-standard` on the theory
      # that ignore rules are unconditionally attacker-controlled, replacing it
      # with a fixed junk-name filter — that traded the bypass for a WORSE one
      # (verified live): the filter is itself an allowlist for the attacker
      # (e.g. a crafted tests/node_modules/<pkg>/... shadowing the module under
      # test via ordinary Node resolution, stripped by the node_modules/ filter
      # entry) and it only recognises Python/Node byproducts, false-positiving
      # this guard on ordinary ignored artifacts in any other stack (Rust, Go,
      # even a stray macOS .DS_Store) that were never touched during dispatch.
      #
      # The actual distinction that matters isn't "does an ignore rule exist"
      # (pre-existing rules the operator wrote are trustworthy — they're what
      # `worktree_dirty` above already verified the tree against) but "did the
      # MODEL change what's ignored during this dispatch". That's cheap to
      # check directly: refuse if any .gitignore, tracked or newly-created
      # untracked, differs from $BASE_SHA. $GITMETA/info/exclude is already
      # sandbox-denied and core.excludesFile lives in the read-only
      # ~/.gitconfig, so once .gitignore itself is verified unchanged, every
      # remaining ignore-rule source is outside the model's reach and
      # `--exclude-standard` is trustworthy again.
      #
      # Scoped to .gitignore files that could actually affect $ORACLE_GUARD's
      # own pathspec — its own directory, every ancestor (parent .gitignore
      # rules cascade down), everything beneath it, and the repo root (rules
      # apply everywhere) — rather than every .gitignore anywhere in the
      # repo. This is git's own directory-scoped .gitignore semantics, not an
      # attacker-gameable allowlist: a .gitignore inside an unrelated sibling
      # directory (e.g. node_modules/<pkg>/.gitignore, an ordinary dependency
      # -install byproduct with no relation to this operator-chosen guard
      # pathspec) structurally cannot affect files under a guard elsewhere in
      # the tree, so flagging it would only ever be a false positive, never a
      # missed attack. Only applied when $ORACLE_GUARD has an explicit
      # directory prefix (the documented usage, e.g. 'tests/*') — a bare
      # pattern with no "/" can match at any depth under git's own pathspec
      # rules, which this scoping can't safely narrow, so it falls back to
      # checking every .gitignore in that case (the original, safe behavior).
      # An empty GUARD_DIR means "unscoped" — flag every changed .gitignore in
      # the repo. That is the SAFE direction (over-flagging, never missing),
      # so every form this scoping cannot reason about normalizes to it.
      # './tests/*' is a pathspec git accepts, but `git diff --name-only` and
      # `ls-files --others` both report repo-relative paths ('tests/.gitignore'),
      # so a raw './tests' prefix matches neither direction of the comparison
      # below and silently disables the check entirely — the exact attack it
      # exists to catch (a tests/.gitignore hiding a new tests/conftest.py from
      # --exclude-standard) would sail through as a clean pass. Strip the
      # leading './' so it compares against what git actually prints, and treat
      # leading pathspec magic (':(glob)', ':!', ...) as unscopable.
      case "$ORACLE_GUARD" in
        :*)  GUARD_DIR="" ;;
        */*) GUARD_DIR="${ORACLE_GUARD%/*}"
             while [ "$GUARD_DIR" != "${GUARD_DIR#./}" ]; do GUARD_DIR="${GUARD_DIR#./}"; done
             [ "$GUARD_DIR" = "." ] && GUARD_DIR=""
             ;;
        *)   GUARD_DIR="" ;;
      esac
      IGNORE_FILES_CHANGED=""
      while IFS= read -r ign_f; do
        [ -n "$ign_f" ] || continue
        if [ -z "$GUARD_DIR" ]; then
          IGNORE_FILES_CHANGED="${IGNORE_FILES_CHANGED:+$IGNORE_FILES_CHANGED }$ign_f"
          continue
        fi
        case "$ign_f" in
          */.gitignore) ign_dir="${ign_f%/.gitignore}" ;;
          .gitignore)   ign_dir="." ;;
          *)            continue ;;
        esac
        if [ "$ign_dir" = "." ]; then
          IGNORE_FILES_CHANGED="${IGNORE_FILES_CHANGED:+$IGNORE_FILES_CHANGED }$ign_f"
        else
          # `case STRING in PATTERN)` — STRING is the value being tested, so
          # the two directions read as: "is GUARD_DIR under ign_dir?" (the
          # .gitignore is an ANCESTOR of the guard, its rules cascade down)
          # then "is ign_dir under GUARD_DIR?" (it sits INSIDE the guard).
          # Both quoted, so a literal `*` in either value stays literal rather
          # than becoming an active glob in the pattern.
          case "$GUARD_DIR/" in
            "$ign_dir/"*) IGNORE_FILES_CHANGED="${IGNORE_FILES_CHANGED:+$IGNORE_FILES_CHANGED }$ign_f" ;;  # ancestor
            *) case "$ign_dir/" in
                 "$GUARD_DIR/"*) IGNORE_FILES_CHANGED="${IGNORE_FILES_CHANGED:+$IGNORE_FILES_CHANGED }$ign_f" ;;  # descendant
               esac ;;
          esac
        fi
      # Process substitution, not a heredoc wrapping a command substitution:
      # the loop body has to assign IGNORE_FILES_CHANGED in THIS shell (a pipe
      # would put it in a subshell and lose it), and `< <(...)` gets that
      # without the heredoc's quoting hazards — no delimiter a git-reported
      # path could collide with, and the git output is never re-parsed.
      done < <( { git -C "$WT" -c core.fsmonitor=false diff --name-only "$BASE_SHA" 2>/dev/null
                  git -C "$WT" -c core.fsmonitor=false ls-files --others 2>/dev/null
                } | grep -E '(^|/)\.gitignore$' | sort -u )
      if [ -n "$IGNORE_FILES_CHANGED" ]; then
        abort oracle_guard_violated "model modified or added .gitignore file(s) during dispatch, not counted as a pass: $IGNORE_FILES_CHANGED"
      fi
      ORACLE_FILES_MODIFIED="$( { git -C "$WT" -c core.fsmonitor=false diff --name-only "$BASE_SHA" -- "$ORACLE_GUARD" 2>/dev/null
                                  git -C "$WT" -c core.fsmonitor=false ls-files --others --exclude-standard -- "$ORACLE_GUARD" 2>/dev/null
                                } | sort -u | tr '\n' ' ')"
      ORACLE_FILES_MODIFIED="${ORACLE_FILES_MODIFIED% }"
      if [ -n "$ORACLE_FILES_MODIFIED" ]; then
        abort oracle_guard_violated "model modified guarded oracle file(s), not counted as a pass: $ORACLE_FILES_MODIFIED"
      fi
    fi

    # Re-check the pointer snapshot immediately before the add/commit below,
    # not just once at the top of this block: the oracle-guard diff just above
    # is itself an unsandboxed, index-reading git command, and the comment at
    # the top of run_with_timeout concedes `kill -TERM -"$pid"` can miss a
    # descendant that detached into its own session — such a process has the
    # whole span from the first snapshot check to here to land a redirect.
    # Narrower, not zero: doesn't shrink to zero, since add/commit below are
    # themselves further unsandboxed git commands after this point.
    if [ "$(snapshot_gitmeta_pointers)" != "$GITMETA_POINTER_BASELINE" ]; then
      abort gitmeta_tampered "SANDBOX ESCAPE SUSPECTED: worktree/gitmeta pointer files changed during dispatch — refused to commit. Inspect $WT/.git and $GITMETA before running any git command against this repo."
    fi

    # Commit deterministically — never delegate this to the model, which is
    # exactly what the oracle premise says not to trust.
    #
    # Deliberately UNSIGNED: this operator's global gitconfig signs via an SSH
    # key served by the 1Password agent, which is (correctly) unreachable from
    # inside the sandbox. Granting it would mean handing a cheap --auto model
    # live signing credentials. This is a synthetic bot commit in an ephemeral,
    # throwaway worktree — not final shared history. Promoting this work into a
    # shared branch goes through the normal reviewed, signed flow.
    #
    # -c core.hooksPath=/dev/null --no-verify: defense in depth alongside
    # sandbox-wrap.sh's own deny on $GITMETA/hooks and $GITMETA/config. This
    # commit runs OUTSIDE the sandbox — if a hook somehow still exists (a
    # pre-existing one in this repo, not model-planted), it must not fire at
    # full operator privilege from a script whose whole point is to run
    # untrusted model output. -c core.fsmonitor=false is the same defense for
    # the pointer-redirect variant of this attack — belt and braces alongside
    # the byte-snapshot check above, not a substitute for it, since a fake
    # config could still trigger arbitrary commands via other mechanisms this
    # override doesn't cover (e.g. a clean/smudge filter).
    #
    # No `git add -A` here: stage_model_changes above already staged exactly
    # this set (same command, same pathspec) as the no_model_changes test, and
    # re-running it would only add another unsandboxed index write for nothing.
    if git -C "$WT" -c user.name=imps-opencode -c user.email=imps@local \
        -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        commit -q -m "opencode: $(basename "$PROMPT_FILE") (attempt $attempt)" --no-gpg-sign --no-verify; then
      # Belt and braces alongside the pointer-snapshot check above: confirm
      # the commit that just landed actually descends from the pre-dispatch
      # HEAD, not a root commit in some other gitdir the .git file got
      # redirected to.
      #
      # ORDER IS LOAD-BEARING: the lineage check gates ref creation, and
      # COMMIT_SHA stays null on commit_lineage_invalid. Publishing a ref first
      # would mint a durable, mergeable gc-rooted pointer to what might be a
      # root commit in a model-redirected fake gitdir — turning the one check
      # that catches that into a check that only reports it after the damage.
      if ! git -C "$WT" merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
        abort commit_lineage_invalid "committed HEAD does not descend from pre-dispatch HEAD ($BASE_SHA) — refusing to report pass"
      fi
      COMMIT_SHA="$(git -C "$WT" -c core.fsmonitor=false rev-parse HEAD 2>/dev/null)"
      [ -n "$COMMIT_SHA" ] || \
        abort result_ref_failed "commit reported success but HEAD could not be resolved — no durable result to publish"

      # Durable by default. The commit already survives the worktree (a linked
      # worktree's objects/ IS the common dir's) — it is the missing REF that
      # made three measurement-round passes evaporate. Auto-ref first, named
      # branch second, so a branch CAS collision still leaves the work durable.
      RESULT_REF="refs/imps/dispatch/$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$COMMIT_SHA" | cut -c1-12)"
      if ! ref_err="$(create_result_ref "$WT" "$COMMIT_SHA" "$RESULT_REF" "$RESULT_BRANCH")"; then
        abort result_ref_failed "commit $COMMIT_SHA landed but AT LEAST ONE ref failed — read the stderr line above to see which survived: on the common case (a --result-branch name collision) the auto-ref under refs/imps/dispatch/ DID land and the work is already durable. Recover from commit_sha before deleting the worktree; list survivors with: git for-each-ref 'refs/imps/dispatch/*'. Detail: $ref_err"
      fi
      log "durable ref $RESULT_REF -> $COMMIT_SHA"
      [ -n "$RESULT_BRANCH" ] && log "result branch $RESULT_BRANCH -> $COMMIT_SHA"
      log "oracle green on attempt $attempt — committed"
      finish pass 0
    fi
    # Commit failed — this is NOT a pass. An oracle that went green with no
    # surviving commit is indistinguishable from a broken harness unless this
    # is reported as a real failure. "Nothing staged" no longer lands here: the
    # no_model_changes check above owns that case explicitly, which is what
    # keeps this reason unambiguous — index non-empty but the commit still
    # failed means the machinery broke (disk full, a rejected ref update),
    # never "the model did nothing".
    abort commit_failed "oracle went green on attempt $attempt but git commit failed — no work was preserved"
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    # Last-50-lines-only systematically drops the most useful diagnostic
    # context: for verbose test runners the failing test name and assertion
    # error are often near the TOP of the output, with the tail being just a
    # summary banner. Head+tail at a similar total budget keeps both ends.
    oracle_head="$(printf '%s\n' "$oracle_out" | head -n 10)"
    oracle_tail="$(printf '%s\n' "$oracle_out" | tail -n 40)"
    prompt="$TASK
---
The acceptance command still fails. Fix the code in this worktree so it passes.
Do not weaken, delete, or rewrite the acceptance command or its test file to make it pass trivially.

\$ $ORACLE
### first output:
$oracle_head
### last output:
$oracle_tail"
  fi
  attempt=$((attempt + 1))
done

log "oracle never went green in $MAX_ATTEMPTS attempt(s)"
finish fail 1 ""
