#!/usr/bin/env bash
#
# list-prs.sh — emit a full state snapshot, one compact JSON object per line, for
# every open pull request the babysitter is allowed to touch.
#
# This is the plugin's ONLY GitHub reader. Both the initial sweep and the event
# monitor call it: the sweep uses the identity fields, pr-events.sh polls it on an
# interval and diffs consecutive snapshots to derive events. One reader means the
# eligibility rules can never disagree between "which PRs we picked up" and "which
# PRs we react to".
#
# Everything comes from a single GraphQL call per invocation — mergeability, base
# head, check rollup, review threads and the newest comment/review ids — so a poll
# loop over dozens of PRs costs one request, not one per PR per field.
#
# Usage:
#   list-prs.sh --org <org> [options]            # every eligible open PR in the org
#   list-prs.sh --repo <owner/name> [options]    # every eligible open PR in one repo
#   list-prs.sh --repo <owner/name> --pr <N>     # one specific PR
#
# Options:
#   --include-drafts   keep draft PRs (default: skipped — a draft is not ready)
#   --include-forks    keep PRs whose head branch lives in a fork (default: skipped;
#                      we usually cannot push to a fork's branch)
#   --all-authors      keep PRs by anyone (default: only the authenticated user and bots)
#   --limit <N>        max PRs to return in --org / --repo sweep mode (default 100,
#                      GitHub caps a search page at 100 and this does not paginate;
#                      a truncated result warns on stderr)
#
# Exit codes:
#   0 — snapshot written to stdout (possibly zero lines)
#   2 — precondition failed (missing gh/jq, not authenticated, bad arguments)
#   3 — the GitHub query itself failed (network, rate limit, permissions)
#
# Exit 3 is kept distinct from 2 on purpose: a poll loop should retry a failed
# query but must never retry a bad argument.

set -euo pipefail

ORG=""
REPO=""
PR_NUMBER=""
INCLUDE_DRAFTS=0
INCLUDE_FORKS=0
ALL_AUTHORS=0
LIMIT=100

die() {
  echo "list-prs.sh: $1" >&2
  exit "${2:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --org)
    ORG="${2:-}"
    shift 2
    ;;
  --repo)
    REPO="${2:-}"
    shift 2
    ;;
  --pr)
    PR_NUMBER="${2:-}"
    shift 2
    ;;
  --include-drafts)
    INCLUDE_DRAFTS=1
    shift
    ;;
  --include-forks)
    INCLUDE_FORKS=1
    shift
    ;;
  --all-authors)
    ALL_AUTHORS=1
    shift
    ;;
  --limit)
    LIMIT="${2:-}"
    shift 2
    ;;
  -h | --help)
    sed -n '2,36p' "$0"
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

case "$LIMIT" in
'' | *[!0-9]*) die "--limit must be a number, got: ${LIMIT}" ;;
esac
[ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 100 ] || die "--limit must be between 1 and 100"

# Three targets, and exactly one of them:
#   --org X            every open PR in the org        -> search
#   --repo X           every open PR in one repository -> search
#   --repo X --pr N    one specific PR                 -> repository.pullRequest
# The two search forms differ only in the qualifier, so they share a code path and
# cannot drift apart in paging, filtering, or output shape.
if [ -n "$PR_NUMBER" ] && [ -z "$REPO" ]; then
  die "--pr requires --repo <owner/name>"
fi
if [ -n "$ORG" ] && [ -n "$REPO" ]; then
  die "--org cannot be combined with --repo"
fi
if [ -n "$REPO" ]; then
  case "$REPO" in
  */*) : ;;
  *) die "--repo must be owner/name, got: ${REPO}" ;;
  esac
  if [ -n "$PR_NUMBER" ]; then
    case "$PR_NUMBER" in
    *[!0-9]*) die "--pr must be a number, got: ${PR_NUMBER}" ;;
    esac
  fi
elif [ -z "$ORG" ]; then
  die "one of --org or --repo is required"
fi

# The PullRequest selection is written once and reused by both query shapes, so a
# field added for the monitor is automatically present in the initial sweep.
read -r -d '' PR_FRAGMENT <<'GRAPHQL' || true
fragment PRState on PullRequest {
  number
  title
  url
  state
  isDraft
  isCrossRepository
  mergeable
  author { login }
  headRefName
  baseRefName
  baseRef { target { oid } }
  repository { nameWithOwner }
  comments(last: 1) { nodes { databaseId } }
  reviews(last: 1) { nodes { databaseId state } }
  reviewThreads(first: 100) {
    nodes {
      isResolved
      isOutdated
      comments(last: 1) { nodes { databaseId } }
    }
  }
  commits(last: 1) {
    nodes {
      commit {
        oid
        statusCheckRollup {
          state
          contexts(first: 100) {
            nodes {
              __typename
              ... on CheckRun { name conclusion }
              ... on StatusContext { context state }
            }
          }
        }
      }
    }
  }
}
GRAPHQL

if [ -z "$PR_NUMBER" ]; then
  if [ -n "$ORG" ]; then
    SCOPE_QUALIFIER="org:${ORG}"
  else
    SCOPE_QUALIFIER="repo:${REPO}"
  fi
  QUERY="query(\$q: String!, \$limit: Int!) {
    viewer { login }
    search(query: \$q, type: ISSUE, first: \$limit) {
      issueCount
      nodes { ...PRState }
    }
  }
  ${PR_FRAGMENT}"
  RAW=$(gh api graphql \
    -f query="$QUERY" \
    -f q="${SCOPE_QUALIFIER} is:pr is:open" \
    -F limit="$LIMIT" 2>&1) || die "GitHub query failed: ${RAW}" 3
  NODES_PATH='.data.search.nodes'

  # GitHub caps a search page at 100 and this script does not paginate. Silently
  # returning the first page would make the sweep look complete while leaving PRs
  # unbabysat, and the watch would then report each missing one as NEW only if it
  # happened to surface later. Say so instead.
  TOTAL=$(printf '%s' "$RAW" | jq -r '.data.search.issueCount // 0' 2>/dev/null || echo 0)
  case "$TOTAL" in
  '' | *[!0-9]*) TOTAL=0 ;;
  esac
  if [ "$TOTAL" -gt "$LIMIT" ]; then
    echo "list-prs.sh: ${SCOPE_QUALIFIER} has ${TOTAL} open PRs but only the first ${LIMIT} were fetched — narrow the scope or raise --limit (max 100)" >&2
  fi
else
  OWNER="${REPO%%/*}"
  NAME="${REPO##*/}"
  QUERY="query(\$owner: String!, \$name: String!, \$number: Int!) {
    viewer { login }
    repository(owner: \$owner, name: \$name) {
      pullRequest(number: \$number) { ...PRState }
    }
  }
  ${PR_FRAGMENT}"
  RAW=$(gh api graphql \
    -f query="$QUERY" \
    -f owner="$OWNER" \
    -f name="$NAME" \
    -F number="$PR_NUMBER" 2>&1) || die "GitHub query failed: ${RAW}" 3
  NODES_PATH='[.data.repository.pullRequest]'
fi

# A GraphQL error can arrive with HTTP 200 and a null data block; gh does not treat
# that as a failure, so check for it rather than emitting an empty snapshot that
# looks like "no PRs".
if ! printf '%s' "$RAW" | jq -e '.data' >/dev/null 2>&1; then
  die "GitHub returned no data: $(printf '%s' "$RAW" | head -c 400)" 3
fi

printf '%s' "$RAW" | jq -c \
  --argjson include_drafts "$INCLUDE_DRAFTS" \
  --argjson include_forks "$INCLUDE_FORKS" \
  --argjson all_authors "$ALL_AUTHORS" \
  --arg nodes_path "$NODES_PATH" '
  def is_bot($login):
    $login != null and (
      ($login | endswith("[bot]"))
      or ($login | ascii_downcase | startswith("copilot"))
      or ($login | ascii_downcase) == "dependabot"
    );

  # A check is failing only once it has finished and finished badly. A run that has
  # not concluded yet is pending, not failing — dispatching an agent to "fix" a job
  # that is still queued is how a babysitter invents work for itself.
  #
  # The inner parentheses around the `not` are load-bearing: in jq the pipe binds
  # looser than "and", so "a and b | not" means "(a and b) | not", which inverts the
  # null guard along with the test and selects every queued run.
  #
  # (No apostrophes in this block. The whole program is a single-quoted shell
  # argument, and one stray apostrophe ends it and hands the rest to bash.)
  #
  # NEUTRAL and SKIPPED are passes. CANCELLED, TIMED_OUT, STALE and ACTION_REQUIRED
  # are failures — an abandoned job blocks a merge exactly as hard as a red one.
  def failing_contexts:
    [ .[]?
      | if .__typename == "CheckRun" then
          select(.conclusion != null
            and ((.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) | not))
          | .name
        else
          select(.state != null and (.state | IN("FAILURE", "ERROR")))
          | .context
        end
    ] | unique;

  . as $root
  | (.data.viewer.login) as $viewer
  | (if $nodes_path == "[.data.repository.pullRequest]"
     then [$root.data.repository.pullRequest]
     else $root.data.search.nodes end)
  | map(select(. != null and .number != null))
  | map(
      (.author.login) as $author
      | (.commits.nodes[0].commit) as $head
      | {
          repo: .repository.nameWithOwner,
          number: .number,
          url: .url,
          title: .title,
          author: $author,
          bot: is_bot($author),
          mine: ($author == $viewer),
          draft: .isDraft,
          fork: .isCrossRepository,
          state: .state,
          head_ref: .headRefName,
          base_ref: .baseRefName,
          base_oid: (.baseRef.target.oid // null),
          head_oid: ($head.oid // null),
          mergeable: .mergeable,
          checks_state: ($head.statusCheckRollup.state // null),
          failing: ($head.statusCheckRollup.contexts.nodes // [] | failing_contexts),
          unresolved_threads: (
            [.reviewThreads.nodes[]? | select(.isResolved == false and .isOutdated == false)]
            | length
          ),
          last_thread_comment_id: (
            [.reviewThreads.nodes[]?.comments.nodes[]?.databaseId] | max // 0
          ),
          last_comment_id: (.comments.nodes[0].databaseId // 0),
          last_review_id: (.reviews.nodes[0].databaseId // 0),
          last_review_state: (.reviews.nodes[0].state // null)
        }
    )
  # Open only. In --org mode the search query already says is:open, but the
  # single-PR query has no such filter and happily returns a merged or closed PR.
  # Two things depend on this: babysitting a merged PR is pointless work, and
  # pr-events.sh --exit-when-empty terminates precisely because a merged PR drops
  # out of the snapshot. Without this line that watch would never end.
  | map(select(.state == "OPEN"))
  | map(select($all_authors == 1 or .mine or .bot))
  | map(select($include_drafts == 1 or (.draft | not)))
  | map(select($include_forks == 1 or (.fork | not)))
  | sort_by(.repo, .number)
  | .[]
'
