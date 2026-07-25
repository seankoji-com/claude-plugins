#!/usr/bin/env bash
# sandbox-smoke.sh — assert that the *currently selected* sandbox wrapper
# actually contains what it claims to contain.
#
# Costs nothing (no model calls, no network), so it runs on any Darwin machine
# and opencode-dispatch.sh runs it as a preflight before spending money.
#
# Assertions:
#   1. write outside the grant set ($HOME) is DENIED
#   2. read outside the grant set ($HOME) is DENIED
#   3. write inside the worktree is allowed
#   4. write inside the gitmeta dir is allowed
#   5. write to /dev/null is allowed        (git dies without it)
#   6. `git status` in the worktree exits 0 (needs ~/.gitconfig read access)
#   7. every path in sandbox/deny-credentials.sbpl.in is unreadable — the REAL
#      ~/.local/share/opencode/auth.json, ~/.config/gh, ~/.ssh, ~/.aws and
#      ~/.claude/.credentials.json
#   8. gitmeta hooks/ and config are unwritable even though the rest of
#      gitmeta is (assertion 4) — the boundary that actually matters: a model
#      that could write hooks/post-commit or set core.fsmonitor would get that
#      script executed at full, unsandboxed operator privilege the moment the
#      harness's own commit runs (that commit is deliberately outside the
#      sandbox). Verified as a real, working exploit during review.
#
# Assertion group 7 is what backs the credential-isolation claim: the sandbox
# gets a redirected XDG_DATA_HOME holding a copy of auth.json, and the original
# must be unreachable. ~/.config/gh is the load-bearing member — safehouse
# GRANTS it by default, so it is the only probe here that actually exercises
# --append-profile's last-match-wins override. auth.json, ~/.ssh and ~/.aws are
# denied by safehouse's own defaults and would stay green even if that override
# silently stopped working, so they cannot stand in for it. Unlike the other
# four credential paths, this script creates a placeholder ~/.config/gh when
# absent (never touching a real one) so this specific assertion can never be
# silently skipped on a host that happens not to have `gh` installed — exactly
# the host where a regression here would otherwise go undetected.
#
# A probe whose target is absent on this host is SKIPPED, not asserted: `cat` on
# a missing file exits non-zero, so counting it as a pass would be evidence of
# nothing.
#
# Exit codes: 0 all assertions passed · 1 an assertion failed (named on stdout)
# · 2 the backend is unavailable · 77 cannot run here (Seatbelt does not nest,
# so this is meaningless from inside another sandbox — see the nesting probe).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
WRAP="$PLUGIN_ROOT/scripts/sandbox-wrap.sh"

fails=0
note() { printf 'note %s\n' "$*"; }
assert() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    [ -n "$detail" ] && printf '     %s\n' "$detail" | tail -n 5
    fails=$((fails + 1))
  fi
}

[ -x "$WRAP" ] || { echo "sandbox-smoke: missing $WRAP" >&2; exit 2; }
if ! bash "$WRAP" --check; then
  echo "sandbox-smoke: sandbox backend unavailable (SANDBOX_MODE=${SANDBOX_MODE:-safehouse})" >&2
  exit 2
fi

TMP_CANON="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 2
HOME_CANON="$(cd "$HOME" && pwd -P)" || exit 2

WT="$(mktemp -d "$TMP_CANON/imps-smoke-wt.XXXXXX")" || exit 2
DATADIR="$(mktemp -d "$TMP_CANON/imps-smoke-data.XXXXXX")" || exit 2
# A probe file we own, at a path the wrapper does NOT grant, so assertion 2 can
# never be vacuous the way a missing credentials file would make assertion 7.
# Scoped to a dedicated subdirectory rather than dropped directly in $HOME
# root: probe files at $HOME's top level can trigger file watchers, sync
# tools, and Spotlight indexing on every run of this script.
HOME_PROBE_DIR="$HOME_CANON/.imps-smoke-probes"
HOME_READ_PROBE="$HOME_PROBE_DIR/read-probe.$$"
HOME_WRITE_PROBE="$HOME_PROBE_DIR/write-probe.$$"
CREATED_HOME_PROBE_DIR=0
# Created only if ~/.config/gh is absent, so the load-bearing gh-config-denied
# assertion is never vacuous — see the header comment.
GH_CONFIG_DIR="$HOME_CANON/.config/gh"
CREATED_GH_CONFIG=0
cleanup() {
  rm -rf "$WT" "$DATADIR" "$HOME_READ_PROBE" "$HOME_WRITE_PROBE"
  [ "$CREATED_HOME_PROBE_DIR" = 1 ] && rmdir "$HOME_PROBE_DIR" 2>/dev/null
  [ "$CREATED_GH_CONFIG" = 1 ] && rmdir "$GH_CONFIG_DIR" 2>/dev/null
}
# EXIT alone can miss SIGINT/SIGTERM in some shells/states, and this cleanup's
# job (removing probe files from $HOME) matters even on an interrupted run.
trap cleanup EXIT HUP INT TERM

git -C "$WT" init -q >/dev/null 2>&1 || { echo "sandbox-smoke: git init failed in $WT" >&2; exit 2; }
GITMETA="$WT/.git"

if [ ! -e "$GH_CONFIG_DIR" ]; then
  if mkdir -p "$GH_CONFIG_DIR" 2>/dev/null; then
    CREATED_GH_CONFIG=1
  fi
fi

# Note on scope: $WT lives under $TMPDIR, which the wrapper does NOT grant
# wholesale (only <worktree>/<gitmeta>/<datadir> specifically) — assertions
# 3-4 prove the worktree/gitmeta grants themselves work, not just that
# something under $TMPDIR happens to be reachable.
run_capture() { # run_capture <errfile> <cmd...>
  local errfile="$1"; shift
  bash "$WRAP" --worktree "$WT" --gitmeta "$GITMETA" --datadir "$DATADIR" -- "$@" >/dev/null 2>"$errfile"
}
run() { run_capture /dev/null "$@"; }

# Nesting probe. Seatbelt does not nest: applied from inside an existing sandbox
# (Claude Code's own Bash sandbox, most obviously) every wrapped call dies with
# "sandbox_apply: Operation not permitted" and every assertion below would fail
# for a reason that says nothing about this profile. Exit 77 — "skipped" — so a
# caller can tell "cannot run here" apart from "containment is broken".
if ! run /usr/bin/true; then
  echo "sandbox-smoke: cannot apply the sandbox here — Seatbelt does not nest." >&2
  echo "sandbox-smoke: re-run outside Claude Code's Bash sandbox (see references/opencode-harness.md)." >&2
  exit 77
fi
# Same reasoning: a $HOME we cannot write to means something outside this script
# is already confining us.
if [ ! -d "$HOME_PROBE_DIR" ]; then
  mkdir -p "$HOME_PROBE_DIR" 2>/dev/null && CREATED_HOME_PROBE_DIR=1
fi
if ! printf 'imps sandbox read probe\n' >"$HOME_READ_PROBE" 2>/dev/null; then
  echo "sandbox-smoke: cannot write $HOME_READ_PROBE — already running confined; skipping." >&2
  exit 77
fi
# expect_allow/expect_deny take a shell snippet run *inside* the sandbox. On
# failure, the wrapped command's own stderr is shown (not discarded) so a FAIL
# line is actually diagnosable instead of just a name.
expect_allow() {
  local n="$1"; shift
  local errfile; errfile="$(mktemp "$TMP_CANON/imps-smoke-err.XXXXXX")"
  if run_capture "$errfile" /bin/sh -c "$*"; then assert "$n" 1; else assert "$n" 0 "$(cat "$errfile")"; fi
  rm -f "$errfile"
}
expect_deny() {
  local n="$1"; shift
  local errfile; errfile="$(mktemp "$TMP_CANON/imps-smoke-err.XXXXXX")"
  if run_capture "$errfile" /bin/sh -c "$*"; then assert "$n" 0 "expected denial, command succeeded"; else assert "$n" 1; fi
  rm -f "$errfile"
}

expect_deny  "home-write-denied"      "touch '$HOME_WRITE_PROBE'"
# Belt and braces: a backend that let the write through but reported failure
# would still be a containment breach.
[ -e "$HOME_WRITE_PROBE" ] && assert "home-write-left-no-file" 0

expect_deny  "home-read-denied"       "cat '$HOME_READ_PROBE'"
expect_allow "worktree-write-allowed" "touch '$WT/probe'"
expect_allow "gitmeta-write-allowed"  "touch '$GITMETA/imps-probe'"
expect_allow "devnull-write-allowed"  "echo probe > /dev/null"
expect_allow "git-status-ok"          "cd '$WT' && git status --porcelain"

# The boundary that actually matters (see header comment group 8): the rest of
# gitmeta is writable (assertion above), but hooks/ and config specifically
# must not be — that's the write vector for full-privilege code execution via
# the harness's own (deliberately unsandboxed) commit.
expect_deny "gitmeta-hooks-write-denied"  "echo x > '$GITMETA/hooks/imps-probe'"
expect_deny "gitmeta-config-write-denied" "echo x >> '$GITMETA/config'"

# One probe per path denied by sandbox/deny-credentials.sbpl.in. `cat || ls` is
# the union of "content readable" and "metadata readable" — the profile denies
# file-read*, which covers both, so a correct profile fails both and a partial
# grant is still caught. Absent targets are skipped rather than counted, except
# gh-config-denied, whose target this script creates when absent (above).
expect_deny_path() { # expect_deny_path <name> <path>
  if [ -e "$2" ]; then
    expect_deny "$1" "cat '$2' 2>/dev/null || ls '$2'"
  else
    note "$1: $2 absent on this host — skipped, NOT counted as a pass"
  fi
}
expect_deny_path "auth-json-denied"    "$HOME_CANON/.local/share/opencode/auth.json"
expect_deny_path "gh-config-denied"    "$GH_CONFIG_DIR"
expect_deny_path "ssh-denied"          "$HOME_CANON/.ssh"
expect_deny_path "aws-denied"          "$HOME_CANON/.aws"
expect_deny_path "claude-creds-denied" "$HOME_CANON/.claude/.credentials.json"

if [ "$fails" -ne 0 ]; then
  echo "sandbox-smoke: $fails assertion(s) failed" >&2
  exit 1
fi
echo "sandbox-smoke: all assertions passed"
