#!/usr/bin/env bash
# sandbox-wrap.sh — apply the OS sandbox, then exec a command inside it.
#
# This is the only place the opencode execute-tier harness talks to a sandbox
# backend. opencode-dispatch.sh and sandbox-smoke.sh both go through it, so the
# smoke test necessarily asserts the *currently selected* wrapper.
#
# Usage:
#   sandbox-wrap.sh --worktree <dir> --gitmeta <dir> --datadir <dir> [--] <cmd> [args...]
#   sandbox-wrap.sh --check          # backend availability probe; no command run
#
# Grants (see plugins/imps/references/opencode-harness.md, contract §A):
#   read/write : <worktree>, <gitmeta> (minus hooks/config — see below), <datadir>,
#                /dev/null. Note: no wholesale $TMPDIR grant — the caller
#                redirects TMPDIR to a subdirectory of <datadir> before invoking
#                this wrapper, so the sandboxed process's own scratch usage
#                stays inside a path already granted via <datadir>, without
#                exposing every other process's temp files on the host.
#   read-only  : the system roots the backend grants by default, plus
#                ~/.gitconfig, ~/.gitignore_global and ~/.opencode/bin
#   denied     : everything else, explicitly including ~/.local/share/opencode,
#                ~/.ssh, ~/.aws, ~/.config/gh, ~/.claude/.credentials.json, and
#                <gitmeta>/hooks + config + config.worktree + info/exclude
#                (sandbox/deny-credentials.sbpl.in, appended last — the gitmeta
#                denies exist because opencode-dispatch.sh's own commit runs
#                OUTSIDE the sandbox with hooks live; a model that can write
#                hooks/post-commit or core.fsmonitor into the shared git common
#                dir gets that script executed at full, unsandboxed operator
#                privilege the next time anyone touches this git dir. Verified
#                as a real, working exploit during review. NOT sufficient
#                alone, though: the worktree's own `.git` redirect file is
#                necessarily writable and can point at a model-created fake
#                gitdir instead — opencode-dispatch.sh's pre/post-dispatch
#                byte-snapshot of that pointer chain (GITMETA_POINTER_BASELINE)
#                is what actually closes this, this file's denies being
#                defense in depth for the direct-write case.)
#   network    : allowed — the model API is remote
#
# NEVER pass --enable=wide-read to safehouse: it grants read across / and would
# hand a cheap `--auto` model with network egress every credential on the box.
#
# Backend selection: SANDBOX_MODE=safehouse (default) | sbpl.
# Fail-closed: exit 2 — distinct from any status the wrapped command can
# produce — if the backend is unavailable or the mode is unrecognised. There is
# deliberately no `none` mode on the flag surface; see the DANGEROUSLY_DISABLE
# block below.
# fail-soft: explicit die() guards handle critical setup errors; normal flow continues
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
DENY_TEMPLATE="$PLUGIN_ROOT/sandbox/deny-credentials.sbpl.in"

die() { echo "sandbox-wrap: $*" >&2; exit 2; }

# Canonical absolute path, no trailing slash. $TMPDIR on macOS has one, and a
# Seatbelt (subpath "…/") never matches.
canon() {
  local p="$1"
  [ -d "$p" ] || return 1
  ( cd "$p" && pwd -P )
}

WORKTREE="" GITMETA="" DATADIR="" REAL_GITDIR_ARG="" CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree)    WORKTREE="${2:-}";      shift 2 ;;
    --gitmeta)     GITMETA="${2:-}";       shift 2 ;;
    --datadir)     DATADIR="${2:-}";       shift 2 ;;
    --real-gitdir) REAL_GITDIR_ARG="${2:-}"; shift 2 ;;
    --check)       CHECK_ONLY=1; shift ;;
    --) shift; break ;;
    -*) die "unknown flag: $1" ;;
    *) break ;;
  esac
done

# ---------------------------------------------------------------------------
# Escape hatch, deliberately hostile to use.
#
# The harness runs behind a Claude Code permission entry that already disables
# Claude Code's own Bash sandbox, so an unsandboxed run here has no boundary at
# any layer: a cheap model with --auto, full privilege, network egress. That is
# why there is no `--sandbox-mode none`; a flag typo must not be able to reach
# it. opencode-dispatch.sh refuses to run at all when this variable is set.
# ---------------------------------------------------------------------------
BYPASS="${IMPS_SANDBOX_DANGEROUSLY_DISABLE:-}"
if [ -n "$BYPASS" ]; then
  [ "$BYPASS" = "i-accept-full-privilege" ] || \
    die "IMPS_SANDBOX_DANGEROUSLY_DISABLE is set to something other than 'i-accept-full-privilege' — refusing"
  [ "$CHECK_ONLY" = 1 ] && exit 0
  [ $# -gt 0 ] || die "no command given"
  echo "sandbox-wrap: *** SANDBOX DISABLED (IMPS_SANDBOX_DANGEROUSLY_DISABLE) — running with full privilege ***" >&2
  exec "$@"
fi

MODE="${SANDBOX_MODE:-safehouse}"

resolve_safehouse() {
  if [ -n "${IMPS_SAFEHOUSE_BIN:-}" ]; then
    [ -x "$IMPS_SAFEHOUSE_BIN" ] && { printf '%s\n' "$IMPS_SAFEHOUSE_BIN"; return 0; }
    return 1
  fi
  local c
  c="$(command -v safehouse 2>/dev/null)" && [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
  # Homebrew keg-only install: the binary is NOT linked onto $PATH.
  for c in "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/agent-safehouse/bin/safehouse" \
           "${HOMEBREW_PREFIX:-/opt/homebrew}/bin/safehouse" \
           /usr/local/opt/agent-safehouse/bin/safehouse; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

case "$MODE" in
  safehouse)
    [ "$(uname -s)" = "Darwin" ] || die "safehouse backend requires macOS (uname -s = $(uname -s))"
    SAFEHOUSE_BIN="$(resolve_safehouse)" || die "safehouse not found (brew install agent-safehouse, or set IMPS_SAFEHOUSE_BIN)"
    [ -f "$DENY_TEMPLATE" ] || die "missing deny profile template: $DENY_TEMPLATE"
    ;;
  sbpl)
    # Reserved fallback. Stage 0 evaluated safehouse live against this exact
    # configuration and it passed every criterion, so v1 ships no hand-written
    # Seatbelt profile. Shipping an unexercised one would be worse than none:
    # a profile that is quietly too permissive still "works", and nothing here
    # would catch it. Fail closed instead of degrading.
    die "SANDBOX_MODE=sbpl is reserved but not implemented in v1 — see references/opencode-harness.md"
    ;;
  *)
    die "unrecognised SANDBOX_MODE: '$MODE' (expected safehouse or sbpl)"
    ;;
esac

[ "$CHECK_ONLY" = 1 ] && exit 0

[ -n "$WORKTREE" ] || die "--worktree is required"
[ -n "$GITMETA" ]  || die "--gitmeta is required"
[ -n "$DATADIR" ]  || die "--datadir is required"
[ $# -gt 0 ]       || die "no command given (use -- before the command)"

WORKTREE="$(canon "$WORKTREE")" || die "--worktree is not a directory: $WORKTREE"
GITMETA="$(canon "$GITMETA")"   || die "--gitmeta is not a directory: $GITMETA"
DATADIR="$(canon "$DATADIR")"   || die "--datadir is not a directory: $DATADIR"
HOME_CANON="$(canon "$HOME")" || die "HOME is not a directory: $HOME"

# The deny rules are interpolated into SBPL string literals via `sed`, and the
# resulting paths are also joined with `:` into --add-dirs/--add-dirs-ro. A
# quote or backslash would break out of the SBPL literal; refuse rather than
# emit a policy that silently fails to parse (or, worse, parses differently
# than intended). `&` is the same class of bug but FAILS OPEN instead of
# refusing: in a sed replacement string, `&` means "the whole match" — a HOME
# containing it (e.g. "/Users/foo&bar") renders syntactically VALID SBPL that
# denies a path which doesn't exist, leaving the real one unprotected, with no
# parse error to catch it (demonstrated during review). `:` doesn't touch sed
# at all, but corrupts the colon-joined --add-dirs/--add-dirs-ro arguments
# below, mis-granting an unintended path. Reject all four rather than
# interpolate them.
case "$HOME_CANON" in
  *'"'*|*'\'*|*'&'*|*':'*) die "HOME contains a quote, backslash, ampersand, or colon — cannot build a safe sandbox profile" ;;
esac
case "$GITMETA" in
  *'"'*|*'\'*|*'&'*|*':'*) die "--gitmeta contains a quote, backslash, ampersand, or colon — cannot build a safe sandbox profile" ;;
esac

resolve_and_validate_gitdir() {
  local real_gitdir_arg="$1" worktree="$2" gitmeta="$3"
  local real_gitdir=""

  # For a linked worktree — the shape every real dispatch uses — git reads
  # config.worktree from the PER-WORKTREE gitdir (<gitmeta>/worktrees/<name>/),
  # not from $GITMETA's own root; deny-credentials.sbpl.in's literal rule for
  # $GITMETA/config.worktree never covers it. A prior version of this fix
  # RE-DERIVED this gitdir on every call via `git -C "$WORKTREE" rev-parse
  # --git-dir` — verified live to be a full RCE of its own: $WORKTREE/.git is
  # necessarily writable (it lives inside the granted worktree), so a model
  # that rewrites it before the oracle run (a SEPARATE, later sandbox-wrap.sh
  # invocation, after the model has already had its turn) gets whatever gitdir
  # it names fed straight into `(allow file-write* (subpath @REAL_GITDIR@))` —
  # reproduced live redirecting to a sibling worktree's gitdir (reopening the
  # RCE this whole rule exists to close) and to an entirely unrelated repo's
  # gitdir (writing that repo's hooks/config from inside this sandbox).
  #
  # --real-gitdir is the fix: the caller (opencode-dispatch.sh) computes and
  # validates this gitdir ONCE, from a clean pre-dispatch snapshot, before the
  # model has ever run, and passes that SAME value explicitly to every
  # subsequent sandboxed invocation for this dispatch — this script must never
  # re-derive it from $WORKTREE/.git at call time for a real dispatch. The
  # self-resolving fallback below exists only for callers with no adversarial
  # model in the loop (sandbox-smoke.sh's own direct, fully test-controlled
  # invocations) and is never the path a real dispatch takes.
  if [ -n "$real_gitdir_arg" ]; then
    real_gitdir="$(canon "$real_gitdir_arg")" || die "--real-gitdir is not a directory: $real_gitdir_arg"
  else
    # -c core.fsmonitor=false and a scrubbed GIT_DIR/GIT_COMMON_DIR: this runs
    # OUTSIDE the sandbox, so it gets the same defensive posture as every other
    # unsandboxed git call in this harness, even though `rev-parse --git-dir`
    # specifically was verified live not to trigger core.fsmonitor today
    # (unlike `git status`, which does) — belt and braces against that
    # changing, not a response to a demonstrated exploit in THIS fallback path.
    real_gitdir="$(env -u GIT_DIR -u GIT_COMMON_DIR git -C "$worktree" -c core.fsmonitor=false rev-parse --git-dir 2>/dev/null)" || real_gitdir=""
    if [ -n "$real_gitdir" ]; then
      case "$real_gitdir" in /*) ;; *) real_gitdir="$worktree/$real_gitdir" ;; esac
      real_gitdir="$(canon "$real_gitdir")" || real_gitdir=""
    fi
  fi
  # A literal newline or `|` would corrupt the SBPL string literal / the `sed
  # s|...|...|` delimiter it's interpolated through below respectively (the
  # `|` case would very likely make that whole `sed` invocation fail outright
  # on the mismatched-delimiter syntax, which the existing `|| die` below
  # already fails closed on — rejected explicitly anyway rather than relying on
  # that as the only backstop). Same class of bug `&` is rejected for above.
  case "$real_gitdir" in
    *'"'*|*'\'*|*'&'*|*':'*|*'|'*) die "resolved worktree gitdir contains a quote, backslash, ampersand, colon, or pipe — cannot build a safe sandbox profile" ;;
    *[$'\n']*) die "resolved worktree gitdir contains a newline — cannot build a safe sandbox profile" ;;
  esac
  # A MAIN worktree's gitdir equals $GITMETA exactly — there's no separate
  # per-worktree gitdir to re-allow, and reallowing "$GITMETA" itself would
  # reopen the whole tree the specific-file denies above just closed: the
  # profile's `(allow file-write* (subpath @REAL_GITDIR@))` rule is a later,
  # broader match than those, so under last-match-wins it would silently
  # override every one of them — verified live (hooks/config/info/attributes/
  # alternates all reported writable again with this left unguarded). Treat
  # "resolved to exactly $GITMETA" the same as unresolved so that reallow
  # becomes inert instead: nothing here needs it, since $GITMETA's own root is
  # already covered by the base --add-dirs grant.
  #
  # This normalization runs BEFORE the fail-closed check below, not after: the
  # two collapse to the same state (an empty REAL_GITDIR, hence an inert
  # reallow), so with the old ordering `--real-gitdir "$GITMETA"` against a
  # gitmeta that HAS a worktrees/ subtree slipped past the guard and ran with
  # that whole subtree denied and nothing re-allowed — verified live to exit 0 —
  # which is precisely the broken-dispatch outcome the comment below refuses.
  if [ "$real_gitdir" = "$gitmeta" ]; then
    real_gitdir=""
  fi
  # A linked-worktree gitmeta (one with a worktrees/ subtree) gets that whole
  # subtree denied below, with only THIS dispatch's own REAL_GITDIR re-allowed —
  # so an unresolved REAL_GITDIR here would deny every worktrees/*/ path,
  # including the one this very dispatch needs to operate (ordinary index
  # writes, HEAD updates, etc.), for a linked-worktree gitmeta that plainly has
  # one. Fail closed instead of silently degrading a real dispatch to a broken
  # one: die rather than fall through to the inert placeholder in that specific
  # case. A non-worktree $GITMETA (no worktrees/ subtree — the plain-gitdir
  # shape sandbox-smoke.sh itself uses) has no such subtree to deny in the
  # first place, so the placeholder stays safe there.
  if [ -z "$real_gitdir" ] && [ -d "$gitmeta/worktrees" ]; then
    die "cannot resolve the worktree's gitdir, but $gitmeta/worktrees exists — refusing to run with the whole linked-worktree subtree denied"
  fi
  # Structural containment check, regardless of source (explicit --real-gitdir
  # or the self-resolved fallback): REAL_GITDIR must be a worktrees/*/
  # subdirectory of THIS EXACT $GITMETA, or empty. This alone does NOT defeat a
  # sibling-worktree redirect (a sibling's gitdir is validly worktrees/*/-shaped
  # too) — that's exactly why the --real-gitdir path above never re-derives
  # from the model-writable .git file to begin with; this check is defense in
  # depth against a caller bug or an unexpected value, not the primary control.
  if [ -n "$real_gitdir" ]; then
    case "$real_gitdir" in
      "$gitmeta"/worktrees/*) ;;
      *) die "resolved gitdir is not under $gitmeta/worktrees: $real_gitdir" ;;
    esac
  fi
  # Empty (couldn't resolve, or resolved to $GITMETA itself — see above; either
  # way $GITMETA/worktrees not existing means there's nothing the subtree deny
  # below needs re-allowing) renders as a literal, unambiguously-impossible path
  # — nothing can exist under /dev/null, which is a device file, not a
  # directory — so these rules become inert rather than an accidental match on
  # something real. Deliberately not a "@TOKEN@"-shaped placeholder: that reads,
  # to a future reader of the rendered profile, like a template substitution
  # that failed, not an intentional inert value.
  [ -n "$real_gitdir" ] || real_gitdir="/dev/null/unresolved-real-gitdir"

  printf '%s\n' "$real_gitdir"
}

REAL_GITDIR="$(resolve_and_validate_gitdir "$REAL_GITDIR_ARG" "$WORKTREE" "$GITMETA")" || exit 2
# Not interpolated via sed, but still joined with `:` into --add-dirs below —
# a colon in either would silently mis-grant a different path than intended.
case "$WORKTREE" in
  *':'*) die "--worktree contains a colon — cannot build a safe --add-dirs argument" ;;
esac
case "$DATADIR" in
  *':'*) die "--datadir contains a colon — cannot build a safe --add-dirs argument" ;;
esac

# Rendered profile lives under $DATADIR — already granted read/write below, and
# already cleaned up by the caller as part of its own datadir lifecycle (no
# separate cleanup needed here). safehouse adds its own terminal
# `deny file-write*` for every --append-profile path, so the sandboxed process
# cannot rewrite its own policy.
DENY_PROFILE="$(mktemp "$DATADIR/imps-deny-profile.XXXXXX")" || die "cannot create deny profile in $DATADIR"
sed -e "s|@HOME@|$HOME_CANON|g" -e "s|@GITMETA@|$GITMETA|g" -e "s|@REAL_GITDIR@|$REAL_GITDIR|g" \
  "$DENY_TEMPLATE" >"$DENY_PROFILE" \
  || die "cannot render deny profile"

# Read-only extras. Without .gitconfig/.gitignore_global, git inside the sandbox
# fails outright with "fatal: unable to access '<home>/.gitconfig': Operation not
# permitted" — verified in Stage 0. Only existing paths are passed; safehouse
# rejects grants for paths that are not there.
RO_PATHS=""
for p in "$HOME_CANON/.gitconfig" "$HOME_CANON/.gitignore_global" "$HOME_CANON/.opencode/bin"; do
  [ -e "$p" ] || continue
  RO_PATHS="${RO_PATHS:+$RO_PATHS:}$p"
done

# safehouse sanitizes the environment by default, so anything the wrapped
# command needs must be named here or it silently vanishes. TERM is included
# because Bun's own error paths crash confusingly without it. TMPDIR is passed
# through too — the caller (opencode-dispatch.sh) is expected to have already
# overridden its own $TMPDIR to a subdirectory of --datadir before invoking
# this wrapper, so the value that reaches the sandboxed process is scoped, not
# the real host tmpdir.
ENV_PASS="TERM,TMPDIR,\
OPENCODE_DISABLE_LSP_DOWNLOAD,OPENCODE_DISABLE_MODELS_FETCH,OPENCODE_DISABLE_AUTOCOMPACT,\
OPENCODE_DISABLE_PRUNE,OPENCODE_DISABLE_DEFAULT_PLUGINS,OPENCODE_DISABLE_SHARE,\
OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER,\
XDG_DATA_HOME,XDG_STATE_HOME,XDG_CONFIG_HOME,XDG_CACHE_HOME"

sh_args=(
  --workdir "$WORKTREE"
  --add-dirs "$GITMETA:$DATADIR"
  --append-profile "$DENY_PROFILE"
  --env-pass "$ENV_PASS"
)
[ -n "$RO_PATHS" ] && sh_args+=(--add-dirs-ro "$RO_PATHS")
[ "${IMPS_SANDBOX_EXPLAIN:-}" = "1" ] && sh_args+=(--explain)

# exec: the wrapped command's exit status passes through unaltered.
exec "$SAFEHOUSE_BIN" "${sh_args[@]}" -- "$@"
