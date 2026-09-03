#!/usr/bin/env bash
#
# pr-events.sh — the event stream the babysitter watches. Written to be handed
# straight to Claude Code's Monitor tool: every stdout line is one actionable event,
# and the script exits when there is nothing left to watch.
#
# It polls list-prs.sh on an interval and diffs consecutive snapshots. Only a change
# that changes what the babysitter would DO becomes a line — a push that leaves the
# PR in the same state is silent, so the monitor is not throttled for noise.
#
# The first snapshot is the baseline and emits nothing: the command has already
# dispatched agents for the PRs that existed when it started, so replaying them as
# events would double-dispatch every one.
#
# Event vocabulary (first token is the kind, second is <repo>#<number>):
#   NEW            a PR entered scope after the baseline
#   CONFLICT       mergeable flipped to CONFLICTING
#   BASE-MOVED     the PR's base branch advanced — the PR is now behind
#   CHECKS-FAILED  the set of failing checks changed and is non-empty
#   CHECKS-GREEN   a PR that had failing checks now has none
#   REVIEW         a new review was submitted (state included)
#   COMMENT        a new issue comment or inline review comment landed
#   THREADS        the unresolved review-thread count went up
#   DRAFT          the PR became a draft (babysitting should pause)
#   GONE           the PR left scope — merged, closed, or no longer eligible
#   ERROR          the GitHub query failed repeatedly; still polling
#   END            nothing left to watch; the monitor is exiting
#
# Coverage note: GONE and END are emitted for the same reason ERROR is — silence
# from this script must never be the only signal that something ended. A monitor
# whose filter only matched the happy path would look identical while every PR it
# was watching got closed underneath it.
#
# Usage:
#   pr-events.sh --org <org> [--interval 60] [--exit-when-empty] [list-prs options...]
#   pr-events.sh --repo <owner/name> --pr <N> --exit-when-empty
#
# Any option this script does not recognize is forwarded verbatim to list-prs.sh, so
# --include-drafts / --include-forks / --all-authors work here too and cannot drift
# out of agreement with the initial sweep.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIST_PRS="${HERE}/list-prs.sh"

INTERVAL=60
EXIT_WHEN_EMPTY=0
PASSTHROUGH=()

die() {
  echo "pr-events.sh: $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
  --interval)
    INTERVAL="${2:-}"
    shift 2
    ;;
  --exit-when-empty)
    EXIT_WHEN_EMPTY=1
    shift
    ;;
  -h | --help)
    sed -n '2,43p' "$0"
    exit 0
    ;;
  *)
    PASSTHROUGH+=("$1")
    shift
    ;;
  esac
done

[ -x "$LIST_PRS" ] || die "list-prs.sh not found or not executable at ${LIST_PRS}"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
case "$INTERVAL" in
'' | *[!0-9]*) die "--interval must be a number of seconds, got: ${INTERVAL}" ;;
esac
# GitHub's secondary rate limits punish tight polling, and no PR event needs
# sub-30-second latency to be handled "immediately" in any meaningful sense.
[ "$INTERVAL" -ge 30 ] || die "--interval must be at least 30 seconds"
[ "${#PASSTHROUGH[@]}" -gt 0 ] || die "no target given — pass --org <org> or --repo/--pr"

PREV="$(mktemp)"
CUR="$(mktemp)"
trap 'rm -f "$PREV" "$CUR"' EXIT

# jq program shared by every poll: joins the previous and current snapshots by
# <repo>#<number> and prints one line per state change worth acting on.
read -r -d '' DIFF_PROGRAM <<'JQ' || true
def key: .repo + "#" + (.number | tostring);
def csv: if length == 0 then "-" else join(",") end;

($old | map({key: key, value: .}) | from_entries) as $o
| ($new | map({key: key, value: .}) | from_entries) as $n
| (
    [ $n | to_entries[]
      | .key as $k | .value as $p
      | if ($o | has($k) | not) then
          ["NEW \($k) \($p.url)"]
        else
          $o[$k] as $b
          | [
              (if $p.mergeable == "CONFLICTING" and $b.mergeable != "CONFLICTING"
                 then "CONFLICT \($k) base=\($p.base_ref) \($p.url)" else empty end),
              (if $p.base_oid != null and $b.base_oid != null and $p.base_oid != $b.base_oid
                 then "BASE-MOVED \($k) base=\($p.base_ref) head=\($p.base_oid[0:12]) \($p.url)" else empty end),
              (if ($p.failing | length) > 0 and $p.failing != $b.failing
                 then "CHECKS-FAILED \($k) \($p.failing | csv) \($p.url)" else empty end),
              (if ($p.failing | length) == 0 and ($b.failing | length) > 0
                 then "CHECKS-GREEN \($k) \($p.url)" else empty end),
              (if $p.last_review_id > $b.last_review_id
                 then "REVIEW \($k) \($p.last_review_state // "SUBMITTED") \($p.url)" else empty end),
              (if $p.last_comment_id > $b.last_comment_id
                  or $p.last_thread_comment_id > $b.last_thread_comment_id
                 then "COMMENT \($k) \($p.url)" else empty end),
              (if $p.unresolved_threads > $b.unresolved_threads
                 then "THREADS \($k) unresolved=\($p.unresolved_threads) \($p.url)" else empty end),
              (if $p.draft and ($b.draft | not)
                 then "DRAFT \($k) \($p.url)" else empty end)
            ]
        end
    ] | add // []
  )
  + [ $o | to_entries[]
      # Bind the entry before the has() test: inside "$n | has(.key)" the .key would
      # be evaluated against $n, not against this entry, and $n has no such field.
      | . as $e
      | select($n | has($e.key) | not)
      | "GONE \($e.key) merged, closed, or no longer eligible \($e.value.url)"
    ]
| .[]
JQ

emit_diff() {
  jq -n -r \
    --slurpfile old "$PREV" \
    --slurpfile new "$CUR" \
    "$DIFF_PROGRAM"
}

# Baseline: seed the previous snapshot without emitting. A failure here is fatal —
# starting from an empty baseline would announce every existing PR as NEW.
if ! "$LIST_PRS" "${PASSTHROUGH[@]}" >"$PREV"; then
  die "initial snapshot failed — check gh auth and the org/repo arguments"
fi

if [ "$EXIT_WHEN_EMPTY" = "1" ] && [ ! -s "$PREV" ]; then
  echo "END nothing eligible to watch"
  exit 0
fi

consecutive_failures=0
while true; do
  sleep "$INTERVAL"

  if "$LIST_PRS" "${PASSTHROUGH[@]}" >"$CUR" 2>/dev/null; then
    consecutive_failures=0
    emit_diff || true
    cp "$CUR" "$PREV"
  else
    # A single failed poll is normal (rate limit, transient 5xx) and must not kill
    # the watch. Three in a row is worth a notification, and the counter resets so
    # a long outage reports periodically instead of once.
    consecutive_failures=$((consecutive_failures + 1))
    if [ "$consecutive_failures" -ge 3 ]; then
      echo "ERROR github query failed ${consecutive_failures}x — still polling every ${INTERVAL}s"
      consecutive_failures=0
    fi
    continue
  fi

  if [ "$EXIT_WHEN_EMPTY" = "1" ] && [ ! -s "$PREV" ]; then
    echo "END all watched pull requests are merged, closed, or out of scope"
    exit 0
  fi
done
