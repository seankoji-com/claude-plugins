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
#   9. info/attributes and objects/info/alternates are unwritable too (same
#      filter/attribute or object-redirect risk as assertion 8), and — set up
#      via two actual `git worktree add`s, since this is the shape every real
#      dispatch uses — the PER-WORKTREE config.worktree under
#      worktrees/<name>/ is unwritable both for THIS dispatch's own linked
#      worktree and, separately, for an unrelated SIBLING worktree of the same
#      repo (the cross-dispatch case a wholesale $GITMETA read-write grant
#      otherwise leaves open — verified live as a full RCE against the
#      harness's own unsandboxed commit before this rule existed), while an
#      ordinary commit inside the dispatch's own worktree still succeeds
#      (the reallow this needs isn't so narrow it breaks normal use). Each of
#      these three checks carries its own positive control in the same
#      sandboxed invocation as the denied write, so a wrapper-level failure
#      (not the SBPL rule) can't silently report the assertion green for the
#      wrong reason.
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
mkdir -p "$GITMETA/info" "$GITMETA/objects/info" 2>/dev/null
expect_deny "gitmeta-info-attributes-write-denied"   "echo x >> '$GITMETA/info/attributes'"
expect_deny "gitmeta-objects-alternates-write-denied" "echo x >> '$GITMETA/objects/info/alternates'"

# Every submodule's own gitdir (its config, its hooks/) lives under
# $GITMETA/modules/<name>/, reachable through the wholesale read-write gitmeta
# grant and covered by nothing above. The deny that closes it shipped one
# round with NO probe at all: mutation-verified that deleting
# `(deny file-write* (subpath "@GITMETA@/modules"))` from the profile left
# this whole file green. Probe a NESTED path, not the container: the deny is a
# subpath rule and the payload path is always modules/<name>/config.
mkdir -p "$GITMETA/modules/imps-smoke-sub" 2>/dev/null
expect_deny "gitmeta-modules-write-denied" "echo x > '$GITMETA/modules/imps-smoke-sub/config'"

# $GITMETA is itself a gitdir, and git reads <gitdir>/commondir from ANY
# gitdir — so writing this one file repoints $GIT_COMMON_DIR for the
# OPERATOR's main checkout at a fake common dir carrying its own
# core.fsmonitor, executed at full operator privilege on their next plain
# `git status`. Nothing else catches it: every command the harness runs is
# -C "$WT" and resolves the per-worktree commondir instead.
expect_deny "gitmeta-commondir-write-denied" "echo x > '$GITMETA/commondir'"
expect_deny "gitmeta-gitdir-write-denied"    "echo x > '$GITMETA/gitdir'"

# A real dispatch is always a linked worktree, where git reads config.worktree
# from the PER-WORKTREE gitdir (worktrees/<name>/config.worktree), not the
# plain literal path above — set two up (this dispatch's own, and a sibling,
# modeling /imps running several imps in sibling worktrees off one repo) to
# prove the subtree-deny/reallow/redeny in deny-credentials.sbpl.in covers
# both: its own gitdir's config.worktree, AND a completely different sibling
# worktree's, which a wholesale per-worktree "$REAL_GITDIR only" deny (an
# earlier version of this fix) verified live to miss entirely.
LINKED_WT="$(mktemp -d "$TMP_CANON/imps-smoke-linked.XXXXXX")" && rmdir "$LINKED_WT"
SIBLING_WT="$(mktemp -d "$TMP_CANON/imps-smoke-sibling.XXXXXX")" && rmdir "$SIBLING_WT"
setup_errfile="$(mktemp "$TMP_CANON/imps-smoke-err.XXXXXX")"
if { git -C "$WT" -c user.email=imps-smoke@example.com -c user.name=imps-smoke \
       commit -q --allow-empty -m "imps-smoke root commit"
     git -C "$WT" worktree add -q "$LINKED_WT" -b imps-smoke-linked
     git -C "$WT" worktree add -q "$SIBLING_WT" -b imps-smoke-sibling
   } >/dev/null 2>"$setup_errfile"; then
  LINKED_GITDIR="$(git -C "$LINKED_WT" rev-parse --git-dir)"
  case "$LINKED_GITDIR" in /*) : ;; *) LINKED_GITDIR="$LINKED_WT/$LINKED_GITDIR" ;; esac
  SIBLING_GITDIR="$(git -C "$SIBLING_WT" rev-parse --git-dir)"
  case "$SIBLING_GITDIR" in /*) : ;; *) SIBLING_GITDIR="$SIBLING_WT/$SIBLING_GITDIR" ;; esac

  # Positive control in the SAME sandboxed invocation as the denied write: a
  # command that only reports "denied" because of a wrapper-level failure
  # (a die() from the new REAL_GITDIR resolution, a profile-render error, a
  # mktemp failure) rather than the SBPL rule actually firing would otherwise
  # report this assertion green for the wrong reason — exactly the class of
  # bug that made an earlier round's fail-open regex invisible to this script.
  # --real-gitdir "$LINKED_GITDIR": matches how opencode-dispatch.sh actually
  # invokes sandbox-wrap.sh for a real dispatch (the pre-computed, trusted
  # value, never re-derived from --worktree's own .git file — see
  # sandbox-wrap.sh's own comment on REAL_GITDIR_ARG).
  errfile="$(mktemp "$TMP_CANON/imps-smoke-err.XXXXXX")"
  marker="$LINKED_WT/.smoke-ok.$$"
  if bash "$WRAP" --worktree "$LINKED_WT" --gitmeta "$GITMETA" --real-gitdir "$LINKED_GITDIR" --datadir "$DATADIR" \
       -- /bin/sh -c "touch '$marker' && echo x > '$LINKED_GITDIR/config.worktree'" \
       >/dev/null 2>"$errfile"; then
    assert "gitmeta-linked-worktree-config-denied" 0 "expected denial, command succeeded"
  elif [ -e "$marker" ]; then
    assert "gitmeta-linked-worktree-config-denied" 1
  else
    assert "gitmeta-linked-worktree-config-denied" 0 "sandbox-wrap failed before reaching the probe (marker never created): $(cat "$errfile")"
  fi
  rm -f "$marker"

  # Same positive-control shape, against a SIBLING worktree's config.worktree
  # — the actual RCE this round closed. --worktree stays LINKED_WT throughout;
  # only the target path (SIBLING_GITDIR, not LINKED_GITDIR) changes.
  sibling_marker="$LINKED_WT/.smoke-ok-sibling.$$"
  if bash "$WRAP" --worktree "$LINKED_WT" --gitmeta "$GITMETA" --real-gitdir "$LINKED_GITDIR" --datadir "$DATADIR" \
       -- /bin/sh -c "touch '$sibling_marker' && echo x > '$SIBLING_GITDIR/config.worktree'" \
       >/dev/null 2>"$errfile"; then
    assert "gitmeta-sibling-worktree-config-denied" 0 "expected denial, command succeeded"
  elif [ -e "$sibling_marker" ]; then
    assert "gitmeta-sibling-worktree-config-denied" 1
  else
    assert "gitmeta-sibling-worktree-config-denied" 0 "sandbox-wrap failed before reaching the probe (marker never created): $(cat "$errfile")"
  fi
  rm -f "$sibling_marker"

  # $REAL_GITDIR is re-allowed wholesale as a subpath, so this dispatch's OWN
  # nested modules/ (a worktree with an initialized submodule) is denied only
  # by the re-deny line that follows the reallow — a completely separate rule
  # from the $GITMETA/modules probe above, and likewise mutation-verified to
  # have had no coverage at all. The directory is created OUT of the sandbox
  # first so the write can only fail on the deny, never on ENOENT.
  mkdir -p "$LINKED_GITDIR/modules/imps-smoke-sub" 2>/dev/null
  modules_marker="$LINKED_WT/.smoke-ok-modules.$$"
  if bash "$WRAP" --worktree "$LINKED_WT" --gitmeta "$GITMETA" --real-gitdir "$LINKED_GITDIR" --datadir "$DATADIR" \
       -- /bin/sh -c "touch '$modules_marker' && echo x > '$LINKED_GITDIR/modules/imps-smoke-sub/config'" \
       >/dev/null 2>"$errfile"; then
    assert "gitmeta-own-gitdir-modules-denied" 0 "expected denial, command succeeded"
  elif [ -e "$modules_marker" ]; then
    assert "gitmeta-own-gitdir-modules-denied" 1
  else
    assert "gitmeta-own-gitdir-modules-denied" 0 "sandbox-wrap failed before reaching the probe (marker never created): $(cat "$errfile")"
  fi
  rm -f "$modules_marker"
  rm -rf "$LINKED_GITDIR/modules"

  # The actual attack this round found: rewrite LINKED_WT/.git itself (a
  # model-writable redirect file) to point at the SIBLING's gitdir instead —
  # simulating a model doing this between the dispatch's own model-turn call
  # and its next sandboxed call (the oracle run) — and prove that with
  # --real-gitdir carrying the ORIGINAL, pre-redirect trusted value (exactly
  # what opencode-dispatch.sh always passes, computed once before the model
  # ever runs), the corrupted .git file is never consulted for this at all.
  # Probes an ARBITRARY new filename in the sibling's gitdir root, not
  # config.worktree specifically — verified live that config.worktree alone
  # does NOT distinguish this fix from the prior self-deriving version, since
  # the re-deny rule tracks whatever REAL_GITDIR resolves to either way
  # (both the reallow and the re-deny would shift onto the sibling together
  # if self-derivation followed the redirect, leaving config.worktree
  # coincidentally still covered). An arbitrary filename has no such re-deny
  # regardless of which gitdir it's under, so it isolates exactly what
  # --real-gitdir changes: whether the ALLOW's scope can be moved by a
  # model-written redirect at all. Verified live: identical probe against
  # sandbox-wrap.sh WITHOUT --real-gitdir (self-derivation) succeeds.
  real_git_backup="$(cat "$LINKED_WT/.git")"
  printf 'gitdir: %s\n' "$SIBLING_GITDIR" >"$LINKED_WT/.git"
  redirect_marker="$TMP_CANON/imps-smoke-redirect-ok.$$"
  if bash "$WRAP" --worktree "$LINKED_WT" --gitmeta "$GITMETA" --real-gitdir "$LINKED_GITDIR" --datadir "$DATADIR" \
       -- /bin/sh -c "touch '$redirect_marker' && echo x > '$SIBLING_GITDIR/imps-smoke-arbitrary-probe'" \
       >/dev/null 2>"$errfile"; then
    assert "gitmeta-dotgit-redirect-does-not-grant-target" 0 "expected denial, command succeeded"
  elif [ -e "$redirect_marker" ]; then
    assert "gitmeta-dotgit-redirect-does-not-grant-target" 1
  else
    assert "gitmeta-dotgit-redirect-does-not-grant-target" 0 "sandbox-wrap failed before reaching the probe (marker never created): $(cat "$errfile")"
  fi
  rm -f "$redirect_marker" "$SIBLING_GITDIR/imps-smoke-arbitrary-probe"
  printf '%s\n' "$real_git_backup" >"$LINKED_WT/.git"

  # The subtree-deny/reallow must not break ORDINARY use of this dispatch's
  # own gitdir — prove a ubiquitous, legitimate write (an index update via a
  # real commit) still succeeds inside it. A dedicated invocation, not the
  # shared expect_allow/run_capture helpers above: those hardcode
  # --worktree "$WT" (the outer, non-linked main worktree used by every
  # other assertion in this file), so reusing them here would sandbox the
  # command against the WRONG worktree entirely rather than $LINKED_WT.
  # -c commit.gpgsign=false: this sandboxed probe commit has nothing to do
  # with the operator's real signing setup, and the sandbox correctly has no
  # access to the SSH-signing agent socket — without this override the
  # commit would fail on that, not on anything this assertion is testing.
  own_errfile="$(mktemp "$TMP_CANON/imps-smoke-err.XXXXXX")"
  if bash "$WRAP" --worktree "$LINKED_WT" --gitmeta "$GITMETA" --real-gitdir "$LINKED_GITDIR" --datadir "$DATADIR" \
       -- /bin/sh -c "cd '$LINKED_WT' && echo x > probe.txt \
         && git -c core.fsmonitor=false add probe.txt \
         && git -c user.email=a@b -c user.name=a -c core.fsmonitor=false -c commit.gpgsign=false commit -q -m probe" \
       >/dev/null 2>"$own_errfile"; then
    assert "gitmeta-own-worktree-commit-still-allowed" 1
  else
    assert "gitmeta-own-worktree-commit-still-allowed" 0 "$(cat "$own_errfile")"
  fi
  rm -f "$own_errfile"

  rm -f "$errfile"
  git -C "$WT" worktree remove --force "$LINKED_WT" >/dev/null 2>&1
  git -C "$WT" worktree remove --force "$SIBLING_WT" >/dev/null 2>&1
  rm -rf "$LINKED_WT" "$SIBLING_WT"
else
  # Unlike the credential-path skips below, this setup (an empty commit and a
  # couple of `git worktree add`s, all against a repo this script just
  # created) is entirely under this script's own control — a failure here is
  # a defect in the script, not evidence the target is absent, so each
  # assertion it would have driven counts as failed (with the actual error
  # surfaced) rather than a silent skip that would let them go vacuously
  # missing.
  assert "gitmeta-linked-worktree-config-denied" 0 "could not set up linked worktrees: $(cat "$setup_errfile")"
  assert "gitmeta-sibling-worktree-config-denied" 0 "could not set up linked worktrees: $(cat "$setup_errfile")"
  assert "gitmeta-dotgit-redirect-does-not-grant-target" 0 "could not set up linked worktrees: $(cat "$setup_errfile")"
  assert "gitmeta-own-worktree-commit-still-allowed" 0 "could not set up linked worktrees: $(cat "$setup_errfile")"
  rm -rf "$LINKED_WT" "$SIBLING_WT"
fi
rm -f "$setup_errfile"

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
