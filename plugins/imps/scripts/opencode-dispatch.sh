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
#                        [--oracle-guard <pathspec>]
#
#   --worktree        git worktree the model may edit (its only writable code path)
#   --prompt-file     the task prompt, read verbatim
#   --oracle          shell command run in the worktree; exit 0 == task done
#   --model           default opencode-go/qwen3.7-max; opencode-go/deepseek-v4-flash
#                     is the cost floor. Only opencode-go/* and opencode/* are
#                     accepted (see the model guard below).
#   --max-attempts    default 3
#   --sandbox-mode    passed through to sandbox-wrap.sh as SANDBOX_MODE
#   --attempt-timeout seconds before a stalled `opencode run` is killed; default 300
#   --oracle-timeout  seconds before a stalled oracle is killed; default 120
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
#
# Contract: the FINAL line of stdout is always exactly one JSON object —
#   {"status":"pass|fail","attempts":2,"session_id":"ses_…","cost_usd":0.0087,
#    "oracle_exit":0,"log_path":"/abs/path.jsonl","abort_reason":null,
#    "oracle_files_modified":null}
# on every exit path, including a failed preflight or a rejected model. Exit code
# is still non-zero on failure. Everything else goes to stderr. log_path is
# null unless IMPS_KEEP_DISPATCH_DIR=1 — otherwise the dispatch dir (and the
# log inside it) is removed by this same cleanup before the process exits, so
# advertising the path would point at something already gone.
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
    printf '{"status":"%s","attempts":%s,"session_id":null,"cost_usd":null,"oracle_exit":null,"log_path":null,"abort_reason":"jq_missing","oracle_files_modified":null}\n' \
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
    '{status:$status, attempts:$attempts, session_id:$session_id, cost_usd:$cost_usd,
      oracle_exit:$oracle_exit, log_path:$log_path, abort_reason:$abort_reason,
      oracle_files_modified:$oracle_files_modified}' >&3
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
run_with_timeout() { # run_with_timeout <seconds> -- <cmd...>
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
  local timed_out_flag=""
  timed_out_flag="$(mktemp "${TMPDIR:-/tmp}/imps-timeout-flag.XXXXXX" 2>/dev/null)" || timed_out_flag=""
  (
    sleep "$secs" 2>/dev/null
    # Sentinel BEFORE the kill, not after: written after, the killed process can
    # reap and the `wait` below return while this subshell is still between the
    # two statements — the main shell then kills this watchdog before the write
    # lands, sees an empty flag, and returns the raw 143 instead of the 124
    # sentinel. Downstream that turns a timed-out oracle into an ordinary oracle
    # failure: no `oracle_timeout` abort, and another paid attempt.
    [ -n "$timed_out_flag" ] && printf '1' >"$timed_out_flag"
    kill -TERM "-$pid" 2>/dev/null
    sleep 10
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
  # unsandboxed git command runs.
  kill -KILL "-$pid" 2>/dev/null
  # The sentinel now means "the watchdog decided to kill", not "the watchdog's
  # kill is why the process died": a child that exits 0 at exactly $secs can
  # have the watchdog write the sentinel (now the first statement) before its
  # own `kill -TERM` no-ops on an already-dead pid. Require rc != 0 too, or a
  # clean on-time exit gets reported as a false 124 (oracle_timeout on a green
  # oracle: no commit, no retry, work discarded).
  if [ "$rc" -ne 0 ] && [ -n "$timed_out_flag" ] && [ -s "$timed_out_flag" ]; then
    rm -f "$timed_out_flag"
    return 124
  fi
  [ -n "$timed_out_flag" ] && rm -f "$timed_out_flag"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
WT="" PROMPT_FILE="" ORACLE="" MODEL="opencode-go/qwen3.7-max" MAX_ATTEMPTS=3 MODE=""
ATTEMPT_TIMEOUT=300 ORACLE_TIMEOUT=120 ORACLE_GUARD=""
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

# Model guard. Reject on *substring*, not prefix: `--model
# openrouter/anthropic/claude-sonnet-4` sails past a prefix check and bills a
# Claude model through opencode — the exact ToS anti-goal this tier exists to
# avoid. Allowlist the known-good providers, then re-check the whole string.
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
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
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
# it's now included alongside the per-worktree config.worktree.
case "$REAL_GITDIR" in
  "$GITMETA"/*) GITMETA_POINTER_PATHS+=("$REAL_GITDIR/commondir" "$REAL_GITDIR/gitdir" "$REAL_GITDIR/HEAD" \
                                        "$REAL_GITDIR/config.worktree" \
                                        "$GITMETA/config" "$GITMETA/config.worktree") ;;
esac
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
run_sandboxed_direct() {
  bash "$WRAP" --worktree "$WT" --gitmeta "$GITMETA" --datadir "$DISPATCH_DIR" -- "$@"
}

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
  run_with_timeout "$ATTEMPT_TIMEOUT" run_sandboxed_direct "${oc_args[@]}" | tee -a "$LOG_PATH" >&2
  oc_rc="${PIPESTATUS[0]}"
  if [ "$oc_rc" -eq 124 ]; then
    log "attempt $attempt timed out after ${ATTEMPT_TIMEOUT}s"
  fi
  # 2 is also sandbox-wrap.sh's own fail-closed status. It cannot be told apart
  # from an opencode exit 2 here, and the preflight already exercised the
  # backend end-to-end, so this is a warning rather than an abort — the oracle
  # still decides.
  [ "$oc_rc" -eq 2 ] && log "exit 2 — could be opencode, or sandbox-wrap.sh failing closed; check stderr above"

  sid="$(extract_session)"
  [ -n "$sid" ] && SESSION_ID="$sid"
  cost="$(extract_cost)"
  [ -n "$cost" ] && COST="$cost"
  [ "$oc_rc" -ne 0 ] && log "opencode exited $oc_rc — running the oracle anyway; the oracle decides"

  # The oracle runs inside the sandbox too: the model has just edited this
  # worktree, and executing whatever it wrote outside the boundary would hand
  # back everything the boundary was for. $ORACLE is passed as a positional
  # parameter into a single-quoted -c body, not interpolated into a
  # double-quoted string — a double-quote inside $ORACLE (e.g. a pytest -k
  # filter) would otherwise terminate the -c argument early and corrupt the
  # invocation.
  ORACLE_OUT_FILE="$DISPATCH_DIR/oracle-out.$attempt"
  run_with_timeout "$ORACLE_TIMEOUT" run_sandboxed_direct /bin/bash -c 'cd "$1" && eval "$2"' _ "$WT" "$ORACLE" \
    >"$ORACLE_OUT_FILE" 2>&1
  ORACLE_EXIT=$?
  oracle_out="$(cat "$ORACLE_OUT_FILE" 2>/dev/null)"
  rm -f "$ORACLE_OUT_FILE"
  log "oracle exit $ORACLE_EXIT"

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
      abort gitmeta_tampered "worktree/gitmeta pointer files changed during dispatch — refusing to commit (possible sandbox-escape attempt via a .git redirect)"
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
      # NOT `--exclude-standard`: ignore rules (.gitignore et al.) are
      # attacker-controlled input inside the model's own worktree — verified
      # live that a 2-file attack (write tests/conftest.py, then add its name
      # to the repo-root .gitignore) makes `ls-files --others --exclude-standard`
      # report nothing, defeating this exact guard. A fixed, harness-owned
      # junk filter instead — narrow enough that it also stops ordinary pytest
      # byproducts (__pycache__/*.pyc) from false-positiving this guard on any
      # machine without a global ignore covering them.
      ORACLE_FILES_MODIFIED="$( { git -C "$WT" -c core.fsmonitor=false diff --name-only "$BASE_SHA" -- "$ORACLE_GUARD" 2>/dev/null
                                  git -C "$WT" -c core.fsmonitor=false ls-files --others -- "$ORACLE_GUARD" 2>/dev/null
                                } | grep -Ev '(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|node_modules)/|\.pyc$' \
                                  | sort -u | tr '\n' ' ')"
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
      abort gitmeta_tampered "worktree/gitmeta pointer files changed during dispatch — refusing to commit (possible sandbox-escape attempt via a .git redirect)"
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
    git -C "$WT" -c core.fsmonitor=false add -A -- ':(exclude)opencode.json'
    if git -C "$WT" -c user.name=imps-opencode -c user.email=imps@local \
        -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        commit -q -m "opencode: $(basename "$PROMPT_FILE") (attempt $attempt)" --no-gpg-sign --no-verify; then
      # Belt and braces alongside the pointer-snapshot check above: confirm
      # the commit that just landed actually descends from the pre-dispatch
      # HEAD, not a root commit in some other gitdir the .git file got
      # redirected to.
      if ! git -C "$WT" merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
        abort commit_lineage_invalid "committed HEAD does not descend from pre-dispatch HEAD ($BASE_SHA) — refusing to report pass"
      fi
      log "oracle green on attempt $attempt — committed"
      finish pass 0
    fi
    # Commit failed (nothing staged, disk full, etc.) — this is NOT a pass.
    # An oracle that went green with no surviving commit is indistinguishable
    # from a broken harness unless this is reported as a real failure.
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
