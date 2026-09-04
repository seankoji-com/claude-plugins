#!/usr/bin/env bash
#
# merge-pr.sh — attempt to actually land one pull request, fixing exactly the
# merge-blockers that are safe to fix without a human's judgment.
#
# The rest of this plugin drives a PR to "mergeable": no conflicts, checks green,
# every review comment answered. That is not the same thing as "GitHub will accept
# `gh pr merge` right now" — a PR can be `mergeable: MERGEABLE` with all checks green
# and still be rejected by branch protection for reasons list-prs.sh's snapshot never
# looked at: the head branch fell behind the base again after another PR merged
# (`strict_required_status_checks_policy`), a review thread the agent answered was
# never actually resolved (`required_review_thread_resolution` keys on GitHub's
# `isResolved` flag, which a `[babysitter]` *reply* does not set), or an org ruleset
# this script has no authority to satisfy at all (a required human approval, a
# code-scanning alert over the org's severity threshold). This script tells those
# three apart and acts only on the first two — the ones that are "finish the job",
# not "override a safety rule".
#
# Every network call goes over curl, not `gh api` / `gh pr merge` — same reason as
# list-prs.sh (see its header): under the Claude Code sandbox, gh's Go TLS stack
# fails cert verification against api.github.com while curl completes the identical
# handshake cleanly. `gh` is used only for `gh auth token`, a local credential read.
#
# Usage:
#   merge-pr.sh --repo <owner/name> --pr <N> [--method squash|merge|rebase]
#
# Without --method, tries squash, then merge, then rebase, stopping at the first the
# repository accepts — GitHub's own error names any method the repo disallows, which
# is simpler and more current than caching each repo's `allowed_merge_methods` here.
#
# Every BLOCKED outcome also tries arming GitHub's native auto-merge before it
# reports — the courtesy costs one extra mutation and means a PR blocked only on
# something outside this script's authority (a pending required check, a review
# still needed) finishes on its own the moment that condition clears, with no further
# call to this script needed. Arming it changes nothing about whether THIS run
# considers the PR blocked; the exit code and reason are unaffected.
#
# Exit codes:
#   0 — merged (stdout: "MERGED <repo>#<pr> via <method>")
#   2 — precondition failed (missing gh/curl/jq, bad arguments)
#   3 — the GitHub query itself failed (network, rate limit, permissions)
#   4 — blocked on something this script will not act on unasked: a required human
#       approval, a code-scanning threshold, an unresolved thread with no
#       `[babysitter]` reply yet, or a merge conflict. Never retried, never
#       overridden with admin/force. (stdout: "BLOCKED <repo>#<pr> reason=<category>
#       detail=<...> automerge=<armed|unavailable>")
#
# What this script will NOT do, on purpose:
#   - Never passes `--admin` to bypass branch protection. A required check, a
#     required reviewer, or an org ruleset exists on purpose; the fix for a PR that
#     cannot satisfy one is either satisfying it for real or a human's call to waive
#     it, never a flag this script reaches for on its own.
#   - Never resolves a review thread that has no `[babysitter]` reply. Resolving a
#     thread nobody answered would silently drop the reviewer's comment rather than
#     satisfy it — the whole point of `required_review_thread_resolution` is that
#     someone looked at it.
#   - Never rebases or force-pushes the PR branch itself. `--method rebase` is
#     GitHub's server-side "rebase and merge" against the *base* branch (replays the
#     PR's commits, then fast-forwards the base) — it never rewrites or force-pushes
#     the PR's own branch, so it does not conflict with the agent's "never
#     force-push" rule, which is about that branch's own history.

set -euo pipefail

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

REPO=""
PR_NUMBER=""
METHOD=""

die() {
  echo "merge-pr.sh: $1" >&2
  exit "${2:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --repo)
    REPO="${2:-}"
    shift 2
    ;;
  --pr)
    PR_NUMBER="${2:-}"
    shift 2
    ;;
  --method)
    METHOD="${2:-}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[ -n "$REPO" ] || die "--repo is required"
case "$PR_NUMBER" in '' | *[!0-9]*) die "--pr must be a number, got: ${PR_NUMBER}" ;; esac
case "$METHOD" in
'' | squash | merge | rebase) ;;
*) die "--method must be squash, merge, or rebase, got: ${METHOD}" ;;
esac

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

GH_TOKEN=""
gh_token() {
  if [ -z "$GH_TOKEN" ]; then
    if ! GH_TOKEN="$(gh auth token 2>&1)"; then
      echo "merge-pr.sh: gh auth token failed: ${GH_TOKEN}" >&2
      return 1
    fi
  fi
  printf '%s' "$GH_TOKEN"
}

# POSTs a GraphQL body, retrying twice on a non-200. Mirrors list-prs.sh's
# curl_graphql_retry exactly (see its comment for why curl, not `gh api graphql`) —
# duplicated rather than sourced, matching this plugin's existing pattern of each
# script standing alone (no intra-plugin require path; see pr-workspace.sh,
# pr-events.sh, run-note.sh).
curl_graphql_retry() {
  local body="$1" attempt=1 code="" content="" tmp errfile token
  token="$(gh_token)" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/babysitter-graphql.XXXXXX")" || return 1
  errfile="${tmp}.err"
  while :; do
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: bearer ${token}" \
      -H "Content-Type: application/json" \
      -X POST --data "$body" \
      https://api.github.com/graphql 2>"$errfile")" || code="000"
    if [ "$code" = "200" ]; then
      cat "$tmp"
      rm -f "$tmp" "$errfile"
      return 0
    fi
    content="$(cat "$tmp" "$errfile" 2>/dev/null)"
    if [ "$attempt" -ge 3 ]; then
      printf '%s' "$content" >&2
      rm -f "$tmp" "$errfile"
      return 1
    fi
    sleep "$((attempt * 2))"
    attempt=$((attempt + 1))
  done
}

# A REST call over curl for the same TLS reason as the GraphQL helper above.
# Prints "<http_code>\n<body>"; caller splits on the first newline. Returns 1 on a
# transport failure (curl itself could not complete the request — DNS, TLS, a
# dropped connection) rather than folding it into a fake "000" HTTP code with
# exit 0: a caller that only compares `code` against expected values would
# otherwise treat "the request never happened" the same as "GitHub answered with
# some code I did not expect", and could misreport a network blip as a real
# branch-protection block.
curl_rest() {
  local method="$1" path="$2" data="${3:-}" token code tmp curl_rc=0
  token="$(gh_token)" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/babysitter-rest.XXXXXX")" || return 1
  if [ -n "$data" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -X "$method" --data "$data" \
      "https://api.github.com${path}")" || curl_rc=$?
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -X "$method" \
      "https://api.github.com${path}")" || curl_rc=$?
  fi
  if [ "$curl_rc" -ne 0 ]; then
    echo "merge-pr.sh: curl transport failure (exit ${curl_rc}) calling ${method} ${path}: $(cat "$tmp" 2>/dev/null)" >&2
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$code"
  cat "$tmp"
  rm -f "$tmp"
}

# Fetches mergeable/mergeStateStatus/reviewThreads fresh — called both up front and
# after any fix, since GitHub's mergeStateStatus lags the action that resolves it by
# a few seconds (queued background work, not synchronous).
fetch_state() {
  local query resp
  query=$(jq -n --arg owner "$OWNER" --arg name "$NAME" --argjson number "$PR_NUMBER" '{
    query: "query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ id mergeable mergeStateStatus baseRefName headRefName autoMergeRequest{ enabledAt } reviewThreads(first:100){ nodes{ id isResolved isOutdated comments(last:100){ nodes{ body } } } } commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } } } } }",
    variables: { owner: $owner, name: $name, number: $number }
  }')
  resp="$(curl_graphql_retry "$query")" || { echo "merge-pr.sh: state query failed: $resp" >&2; return 1; }
  if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
    echo "merge-pr.sh: GraphQL returned errors: $(jq -c '.errors' <<<"$resp")" >&2
    return 1
  fi
  echo "$resp"
}

# True if any comment in the thread already carries the plugin's own reply marker —
# the signal that a babysitter agent looked at this thread and answered it (fixed or
# rejected), as opposed to a thread nobody has touched yet.
thread_has_babysitter_reply() {
  jq -e '[.comments.nodes[]? | select(.body | startswith("[babysitter]"))] | length > 0' >/dev/null 2>&1 <<<"$1"
}

resolve_thread() {
  local thread_id="$1" mutation resp
  mutation=$(jq -n --arg id "$thread_id" '{
    query: "mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ id isResolved } } }",
    variables: { id: $id }
  }')
  resp="$(curl_graphql_retry "$mutation")" || return 1
  jq -e '.data.resolveReviewThread.thread.isResolved == true' >/dev/null 2>&1 <<<"$resp"
}

# PUTs the update-branch endpoint (server-side merge of base into head — the same
# non-destructive operation as `git merge origin/<base>`, just without a worktree)
# and polls briefly for mergeStateStatus to leave BEHIND. Bounded at 5 polls / ~15s:
# long enough for GitHub's queued merge to land, short enough that a genuinely stuck
# state falls through to being reported rather than hanging the caller.
sync_behind_branch() {
  local resp code body
  resp="$(curl_rest PUT "/repos/${REPO}/pulls/${PR_NUMBER}/update-branch")" || return 1
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  case "$code" in
  2*) ;;
  *)
    echo "merge-pr.sh: update-branch failed (HTTP ${code}): ${body}" >&2
    return 1
    ;;
  esac
  local i state
  for i in 1 2 3 4 5; do
    sleep 3
    state="$(fetch_state)" || return 1
    if [ "$(jq -r '.data.repository.pullRequest.mergeStateStatus' <<<"$state")" != "BEHIND" ]; then
      return 0
    fi
  done
  echo "merge-pr.sh: mergeStateStatus still BEHIND after update-branch + ${i} polls" >&2
  return 1
}

# Arms GitHub's native auto-merge on the current PR (idempotent — re-arming an
# already-armed PR just re-confirms it), trying the same method order as try_merge.
# Returns 1 if the repository does not allow auto-merge at all (the setting is off in
# repo settings) or every method is rejected; the caller treats that as informational,
# never as a reason to change what it reports.
enable_automerge() {
  local pr_id already m mutation resp
  pr_id="$(jq -r '.data.repository.pullRequest.id // empty' <<<"$state")"
  [ -n "$pr_id" ] || return 1
  already="$(jq -r '.data.repository.pullRequest.autoMergeRequest.enabledAt // empty' <<<"$state")"
  [ -n "$already" ] && return 0
  local methods_upper=(SQUASH MERGE REBASE)
  [ -n "$METHOD" ] && methods_upper=("$(tr '[:lower:]' '[:upper:]' <<<"$METHOD")")
  for m in "${methods_upper[@]}"; do
    mutation=$(jq -n --arg id "$pr_id" --arg m "$m" '{
      query: "mutation($id:ID!,$m:PullRequestMergeMethod!){ enablePullRequestAutoMerge(input:{pullRequestId:$id, mergeMethod:$m}){ pullRequest{ autoMergeRequest{ enabledAt } } } }",
      variables: { id: $id, m: $m }
    }')
    resp="$(curl_graphql_retry "$mutation")" || continue
    if jq -e '.data.enablePullRequestAutoMerge.pullRequest.autoMergeRequest.enabledAt' >/dev/null 2>&1 <<<"$resp"; then
      return 0
    fi
  done
  return 1
}

# Reports a BLOCKED outcome, arming auto-merge first (best-effort) so a condition
# outside this run's control — a required check still to pass, a review still
# needed — resolves on its own without another call to this script. Exit code and
# reason are the same whether or not auto-merge could be armed.
blocked() {
  local reason="$1" detail="$2" automerge="unavailable"
  enable_automerge && automerge="armed"
  echo "BLOCKED ${REPO}#${PR_NUMBER} reason=${reason} detail=${detail} automerge=${automerge}"
  exit 4
}

try_merge() {
  local method="$1" resp code body
  resp="$(curl_rest PUT "/repos/${REPO}/pulls/${PR_NUMBER}/merge" "$(jq -n --arg m "$method" '{merge_method:$m}')")" || return 2
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [ "$code" = "200" ]; then
    echo "MERGED ${REPO}#${PR_NUMBER} via ${method}"
    return 0
  fi
  # 405: "Pull Request is not mergeable" (or a merge-method the repo disallows) —
  # the caller tries the next method / classifies the message. 409: sha mismatch,
  # irrelevant here since no expected head sha is sent. Anything else is a hard stop.
  printf '%s' "$body" >&2
  echo "$code"
}

state="$(fetch_state)" || die "could not read PR state" 3
mergeable="$(jq -r '.data.repository.pullRequest.mergeable' <<<"$state")"
merge_state="$(jq -r '.data.repository.pullRequest.mergeStateStatus' <<<"$state")"

if [ "$mergeable" = "CONFLICTING" ]; then
  blocked "conflict" "merge conflicts against the base branch; resolve in a worktree first, not here"
fi

if [ "$merge_state" = "BEHIND" ]; then
  if ! sync_behind_branch; then
    blocked "behind" "update-branch did not clear BEHIND in time"
  fi
  state="$(fetch_state)" || die "could not re-read PR state after update-branch" 3
fi

# required_review_thread_resolution keys on isResolved alone (isOutdated is
# irrelevant to it — see list-prs.sh). Resolve only threads a babysitter agent
# already answered; anything else is a real open question for a human, not this
# script's to close.
unresolved_json="$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved == false)]' <<<"$state")"
unanswered_count=0
while IFS= read -r thread; do
  [ -z "$thread" ] && continue
  if thread_has_babysitter_reply "$thread"; then
    tid="$(jq -r '.id' <<<"$thread")"
    resolve_thread "$tid" || echo "merge-pr.sh: could not resolve thread ${tid}, leaving it open" >&2
  else
    unanswered_count=$((unanswered_count + 1))
  fi
done < <(jq -c '.[]' <<<"$unresolved_json")

if [ "$unanswered_count" -gt 0 ]; then
  blocked "unanswered_threads" "${unanswered_count} review thread(s) have no [babysitter] reply yet — answer them before this PR can merge"
fi

# Checked here, after fixing what could be fixed, rather than at the very top: base
# drift or an unanswered thread can be the reason a required check never ran at all
# (queued behind the branch update), so re-reading it now — not the possibly-stale
# copy from the very first fetch_state call — is what makes this an accurate report
# instead of a guess. FAILURE and ERROR are the only rollup states worth naming
# specifically; PENDING is still running and gets folded into the generic
# branch_protection report below rather than a separate reason, since retrying
# immediately would not help either way.
checks_state="$(jq -r '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state // "UNKNOWN"' <<<"$state")"
case "$checks_state" in
FAILURE | ERROR)
  blocked "failing_checks" "required status checks are red (rollup=${checks_state}) — that is a code/CI fix, not something this script can resolve"
  ;;
esac

methods=("$METHOD")
[ -z "$METHOD" ] && methods=(squash merge rebase)

last_code=""
for m in "${methods[@]}"; do
  out="$(try_merge "$m")"
  if [[ "$out" == MERGED* ]]; then
    echo "$out"
    exit 0
  fi
  last_code="$out"
done

# Every method failed. Re-fetch once more to give an accurate reason: a stale
# `mergeable`/`mergeStateStatus` read from the top of this script is a common way to
# misreport a review that landed CHANGES_REQUESTED or a code-scanning alert that
# posted in between.
#
# Deliberately not `<<<"${state:-{}}"`: bash's `${var:-word}` parser closes the
# expansion at the first unescaped `}` it sees — a literal `{}` in `word` is not
# tracked as nested — so that form silently appends a stray extra `}` after a
# non-empty `$state` and makes jq fail with "Unmatched '}'" on every successful
# fetch. Guard explicitly instead.
state="$(fetch_state)" || true
[ -n "$state" ] || state='{}'
merge_state="$(jq -r '.data.repository.pullRequest.mergeStateStatus // "UNKNOWN"' <<<"$state")"
case "$merge_state" in
BLOCKED)
  blocked "branch_protection" "GitHub reports BLOCKED after every merge method failed (last HTTP ${last_code}) — likely a required reviewer, an org ruleset (e.g. approval required for unattributed changes), or a code-scanning alert at or above the org's threshold; none of these are safe for this script to satisfy on its own"
  ;;
DIRTY)
  blocked "conflict" "mergeStateStatus flipped to DIRTY between the top of this run and the merge attempt"
  ;;
*)
  blocked "unknown" "every merge method failed (last HTTP ${last_code}), mergeStateStatus=${merge_state}"
  ;;
esac
