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
#   read/write : <worktree>, <gitmeta>, <datadir>, $TMPDIR, /dev/null
#   read-only  : the system roots the backend grants by default, plus
#                ~/.gitconfig, ~/.gitignore_global and ~/.opencode/bin
#   denied     : everything else, explicitly including ~/.local/share/opencode,
#                ~/.ssh, ~/.aws, ~/.config/gh and ~/.claude/.credentials.json
#                (sandbox/deny-credentials.sbpl.in, appended last)
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

WORKTREE="" GITMETA="" DATADIR="" CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --gitmeta)  GITMETA="${2:-}";  shift 2 ;;
    --datadir)  DATADIR="${2:-}";  shift 2 ;;
    --check)    CHECK_ONLY=1; shift ;;
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
TMP_CANON="$(canon "${TMPDIR:-/tmp}")" || die "TMPDIR is not a directory: ${TMPDIR:-/tmp}"
HOME_CANON="$(canon "$HOME")" || die "HOME is not a directory: $HOME"

# The deny rules are interpolated into an SBPL string literal. A quote or
# backslash in $HOME would break out of it; refuse rather than emit a policy
# that silently fails to parse (or, worse, parses differently than intended).
case "$HOME_CANON" in
  *'"'*|*'\'*) die "HOME contains a quote or backslash — cannot build a safe sandbox profile" ;;
esac

# Rendered profile lives in $TMPDIR (already granted, so redirection into it is
# safe — see the reference doc's note on output paths outside the grant set).
# safehouse adds its own terminal `deny file-write*` for every --append-profile
# path, so the sandboxed process cannot rewrite its own policy.
DENY_PROFILE="$(mktemp "$TMP_CANON/imps-deny-profile.XXXXXX")" || die "cannot create deny profile in $TMP_CANON"
sed "s|@HOME@|$HOME_CANON|g" "$DENY_TEMPLATE" >"$DENY_PROFILE" || die "cannot render deny profile"

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
# because Bun's own error paths crash confusingly without it.
ENV_PASS="TERM,TMPDIR,\
OPENCODE_DISABLE_LSP_DOWNLOAD,OPENCODE_DISABLE_MODELS_FETCH,OPENCODE_DISABLE_AUTOCOMPACT,\
OPENCODE_DISABLE_PRUNE,OPENCODE_DISABLE_DEFAULT_PLUGINS,OPENCODE_DISABLE_SHARE,\
OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER,\
XDG_DATA_HOME,XDG_STATE_HOME,XDG_CONFIG_HOME,XDG_CACHE_HOME"

sh_args=(
  --workdir "$WORKTREE"
  --add-dirs "$GITMETA:$DATADIR:$TMP_CANON"
  --append-profile "$DENY_PROFILE"
  --env-pass "$ENV_PASS"
)
[ -n "$RO_PATHS" ] && sh_args+=(--add-dirs-ro "$RO_PATHS")
[ "${IMPS_SANDBOX_EXPLAIN:-}" = "1" ] && sh_args+=(--explain)

# exec: the wrapped command's exit status passes through unaltered. The rendered
# profile is left behind in $TMPDIR (exec means no trap can fire); it is inert
# and reaped with the rest of $TMPDIR.
exec "$SAFEHOUSE_BIN" "${sh_args[@]}" -- "$@"
