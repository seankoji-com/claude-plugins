#!/usr/bin/env bash
# run-note.sh — append one observation to this run's live notes ledger.
#
# A `/babysitter:org` sweep can run for hours across dozens of repositories, and the
# things worth learning from it (a credential helper that fails headlessly, a repo whose
# clone is SSH-only, a gate that failed open) are discovered mid-run and forgotten by the
# summary. This writes each one down as it happens, outside every repository being
# babysat, so the run's notes survive a crash, a /compact, or a stopped watch.
#
# The ledger is raw and append-only. The command's stop step distils it into the durable
# `learnings.md` alongside it; nothing reads this file automatically.
#
# Usage:
#   run-note.sh --command <slash-command> --kind <kind> --note <text> [--scope <label>]
#
#   kind:  env | github | process | repo | policy
#     env      the machine or sandbox — credentials, TLS, PATH, permissions
#     github   the API or a remote — 504s, rate limits, stalled clones
#     process  this command's own runbook — ordering, batching, dispatch shape
#     repo     a fact about one repository that will still be true next run
#     policy   a gate or safety rule that failed, fired wrongly, or was bypassed
#   scope: free label for what the note is about — an org, `owner/repo`, `owner/repo#N`
#
# Prints the ledger path on stdout.
#
# Best-effort by design, exactly like audit-log.sh: an unwritable notes directory warns
# on stderr and exits 0 rather than breaking a sweep that is otherwise going fine — this
# is a notebook, not a gate. Malformed arguments still exit 1; those are bugs in the
# calling command, not the environment.
set -uo pipefail

# Kept above the arg loop so the unit test harness (which sources this script with
# __SOURCED__=1 and calls one function directly) can exercise it without going through
# argv parsing — same arrangement as audit-log.sh's json helpers.
#
# /babysitter:org -> babysitter-org, so the ledger name is a usable filename on any
# platform and one command's notes never land in another's file. Collapsing runs of
# separators rather than mapping each one keeps `/babysitter::org` from becoming
# `babysitter--org` and splitting a command's notes across two files on a typo.
slugify() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//'
}
${__SOURCED__:+false} : || return 0

command_name="" kind="" note="" scope=""

while [ $# -gt 0 ]; do
  case "$1" in
    --command) command_name="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    --scope) scope="${2:-}"; shift 2 ;;
    *) echo "run-note.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$kind" in
  env|github|process|repo|policy) ;;
  *) echo "run-note.sh: --kind must be one of env|github|process|repo|policy, got '$kind'" >&2; exit 1 ;;
esac

[ -n "$command_name" ] || { echo "run-note.sh: --command is required" >&2; exit 1; }
[ -n "$note" ] || { echo "run-note.sh: --note is required" >&2; exit 1; }

# Same empty-root reasoning as pr-workspace.sh: an unset HOME under `set -u` aborts with
# a raw "unbound variable", and defaulting it to "" yields the absolute-looking
# /.claude/babysitter. Resolve to empty here and fail cleanly below.
ROOT="${BABYSITTER_HOME:-}"
if [ -z "$ROOT" ] && [ -n "${HOME:-}" ]; then
  ROOT="${HOME}/.claude/babysitter"
fi
if [ -z "$ROOT" ]; then
  echo "run-note.sh: no notes root — set BABYSITTER_HOME or HOME; skipping note" >&2
  exit 0
fi

slug="$(slugify "$command_name")"
[ -n "$slug" ] || slug="babysitter"

notes_dir="${ROOT}/run-notes"
ledger="${notes_dir}/$(date -u +%Y-%m-%d)-${slug}.md"

if ! mkdir -p "$notes_dir" 2>/dev/null; then
  echo "run-note.sh: cannot create ${notes_dir} — skipping note" >&2
  exit 0
fi

if [ ! -e "$ledger" ]; then
  {
    echo "# ${command_name} run notes — $(date -u +%Y-%m-%d)"
    echo
    echo "Raw, append-only. Written as the run happens; distilled into \`../learnings.md\`"
    echo "when the run stops. Several runs of this command on one day share this file."
    echo
  } >> "$ledger" 2>/dev/null
fi

# Newlines in a note would break the one-bullet-per-observation shape the distil step
# reads, so fold them into spaces rather than rejecting a multi-line note outright.
flat_note="$(printf '%s' "$note" | tr '\n' ' ')"
entry="- **$(date -u +%H:%M:%SZ)** · \`${kind}\`"
[ -n "$scope" ] && entry="${entry} · ${scope}"
entry="${entry} — ${flat_note}"

if ! printf '%s\n' "$entry" >> "$ledger" 2>/dev/null; then
  echo "run-note.sh: failed to write to ${ledger}" >&2
  exit 0
fi

printf '%s\n' "$ledger"
