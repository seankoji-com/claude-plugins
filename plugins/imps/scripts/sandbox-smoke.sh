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
#   7. reading the REAL ~/.local/share/opencode/auth.json is DENIED
#
# Assertion 7 is the only test behind the credential-isolation claim: the
# sandbox gets a redirected XDG_DATA_HOME holding a copy of auth.json, and the
# original must be unreachable. If that file is absent on this host the
# assertion is reported as vacuous rather than quietly counted as a pass.
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
  local name="$1" ok="$2"
  if [ "$ok" = 1 ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
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
HOME_READ_PROBE="$HOME_CANON/.imps-sandbox-read-probe.$$"
HOME_WRITE_PROBE="$HOME_CANON/.imps-sandbox-write-probe.$$"
cleanup() { rm -rf "$WT" "$DATADIR" "$HOME_READ_PROBE" "$HOME_WRITE_PROBE"; }
trap cleanup EXIT

git -C "$WT" init -q >/dev/null 2>&1 || { echo "sandbox-smoke: git init failed in $WT" >&2; exit 2; }
GITMETA="$WT/.git"

# Note on scope: $WT lives under $TMPDIR, which the wrapper grants wholesale, so
# assertions 3-4 prove "the grant set is reachable", not "the worktree grant
# specifically works". The security-relevant assertions (1, 2, 7) are unaffected.
run() { bash "$WRAP" --worktree "$WT" --gitmeta "$GITMETA" --datadir "$DATADIR" -- "$@" >/dev/null 2>&1; }

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
if ! printf 'imps sandbox read probe\n' >"$HOME_READ_PROBE" 2>/dev/null; then
  echo "sandbox-smoke: cannot write $HOME_READ_PROBE — already running confined; skipping." >&2
  exit 77
fi
# expect_allow/expect_deny take a shell snippet run *inside* the sandbox.
expect_allow() { local n="$1"; shift; if run /bin/sh -c "$*"; then assert "$n" 1; else assert "$n" 0; fi; }
expect_deny()  { local n="$1"; shift; if run /bin/sh -c "$*"; then assert "$n" 0; else assert "$n" 1; fi; }

expect_deny  "home-write-denied"      "touch '$HOME_WRITE_PROBE'"
# Belt and braces: a backend that let the write through but reported failure
# would still be a containment breach.
[ -e "$HOME_WRITE_PROBE" ] && assert "home-write-left-no-file" 0

expect_deny  "home-read-denied"       "cat '$HOME_READ_PROBE'"
expect_allow "worktree-write-allowed" "touch '$WT/probe'"
expect_allow "gitmeta-write-allowed"  "touch '$GITMETA/imps-probe'"
expect_allow "devnull-write-allowed"  "echo probe > /dev/null"
expect_allow "git-status-ok"          "cd '$WT' && git status --porcelain"

AUTH_JSON="$HOME_CANON/.local/share/opencode/auth.json"
[ -e "$AUTH_JSON" ] || note "auth-json-denied: $AUTH_JSON absent on this host — assertion is vacuous here"
expect_deny  "auth-json-denied"       "cat '$AUTH_JSON'"

if [ "$fails" -ne 0 ]; then
  echo "sandbox-smoke: $fails assertion(s) failed" >&2
  exit 1
fi
echo "sandbox-smoke: all assertions passed"
