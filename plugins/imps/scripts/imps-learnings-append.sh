#!/usr/bin/env bash
# imps-learnings-append.sh — append run learnings under a lock.
#
#   imps-learnings-append.sh --scope user|project --heading "<heading>" \
#       --rule "<rule>" [--rule "<rule>" ...]
#
#   --scope user     -> ~/.claude/imps/learnings.md          (shared by every repo AND run)
#   --scope project  -> <working tree>/.claude/imps/learnings.md
#
# ---------------------------------------------------------------------------
# Why a script instead of an agent editing the file
# ---------------------------------------------------------------------------
# The user-scoped learnings file is the one piece of run state that concurrent runs
# genuinely share: two runs finishing near each other both read it, both append their own
# section, and both write it back — and the second write silently drops the first run's
# learnings. An agent doing read-modify-write on markdown cannot avoid that; a locked,
# append-only writer can.
#
# The lock is a `mkdir` mutex rather than `flock`, which macOS does not ship as a binary.
# `mkdir` is atomic on every filesystem that matters, and a stale lock (from a run that
# died mid-append) is broken after LOCK_STALE_SECONDS so a crash cannot wedge the file
# permanently. Consistent with `audit-log.sh`, this is telemetry rather than a gate: it
# warns and exits 0 on an environment problem so a logging hiccup never fails a run.
# Malformed *arguments* still exit 1 — those are bugs in the caller.
set -uo pipefail

LOCK_STALE_SECONDS="${IMPS_LOCK_STALE_SECONDS:-120}"

warn() { printf 'imps-learnings-append: %s\n' "$1" >&2; }
die()  { printf 'imps-learnings-append: %s\n' "$1" >&2; exit 1; }

SCOPE=""
HEADING=""
RULES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)   [ $# -ge 2 ] || die '--scope needs a value'; SCOPE="$2"; shift 2 ;;
    --heading) [ $# -ge 2 ] || die '--heading needs a value'; HEADING="$2"; shift 2 ;;
    --rule)    [ $# -ge 2 ] || die '--rule needs a value'; RULES+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$SCOPE" in
  user|project) ;;
  *) die "--scope must be 'user' or 'project' (got: '${SCOPE:-}')" ;;
esac
[ -n "$HEADING" ] || die '--heading is required'
[ "${#RULES[@]}" -gt 0 ] || die 'at least one --rule is required'

if [ "$SCOPE" = user ]; then
  TARGET="$HOME/.claude/imps/learnings.md"
else
  if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$ROOT" ]; then
    warn 'project scope requested outside a git working tree; nothing written'
    exit 0
  fi
  TARGET="$ROOT/.claude/imps/learnings.md"
fi

if ! mkdir -p "$(dirname "$TARGET")" 2>/dev/null; then
  warn "cannot create $(dirname "$TARGET"); nothing written"
  exit 0
fi

# --- lock ------------------------------------------------------------------
# Modification time of $1, or the fallback $2 if it cannot be read as an integer.
#
# Both stat dialects must be tried AND their output validated, not just their exit
# status: BSD stat spells this `-f %m` while GNU stat spells it `-c %Y` — and GNU's `-f`
# means "filesystem info", so on a machine with GNU coreutils `stat -f %m` *succeeds*
# (exit 0) while printing something like `File: "/path"`. An exit-status-only fallback
# chain therefore accepts that text as a timestamp, and the arithmetic below then dies
# with `File: unbound variable` under `set -u`. Requiring digits is what makes this safe.
lock_mtime() {
  local out
  for fmt in "-c %Y" "-f %m"; do
    # shellcheck disable=SC2086
    out=$(stat $fmt "$1" 2>/dev/null) || continue
    case "$out" in
      ''|*[!0-9]*) continue ;;
      *) printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$2"
}

LOCK="${TARGET}.lock"
acquired=0
for _ in $(seq 1 60); do
  if mkdir "$LOCK" 2>/dev/null; then acquired=1; break; fi
  # Break a stale lock left by a run that died mid-append.
  if [ -d "$LOCK" ]; then
    now=$(date +%s)
    mtime=$(lock_mtime "$LOCK" "$now")
    if [ $((now - mtime)) -ge "$LOCK_STALE_SECONDS" ]; then
      warn "breaking stale lock $LOCK (held >${LOCK_STALE_SECONDS}s)"
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
  fi
  sleep 0.5
done

if [ "$acquired" -ne 1 ]; then
  warn "could not acquire $LOCK; nothing written (learnings for this run were not saved)"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# --- append ----------------------------------------------------------------
# Append-only: never rewrites existing content, so there is nothing for a concurrent
# writer to lose even if the lock were somehow bypassed.
{
  if [ ! -s "$TARGET" ]; then
    printf '# imps learnings\n\n## Active rules\n\n'
  fi
  printf '\n## %s\n\n' "$HEADING"
  for rule in "${RULES[@]}"; do
    printf -- '- %s\n' "$rule"
  done
} >> "$TARGET" 2>/dev/null || { warn "append to $TARGET failed"; exit 0; }

printf 'Appended %d learning(s) to %s\n' "${#RULES[@]}" "$TARGET"
