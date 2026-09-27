#!/usr/bin/env bash
#
# merge-pr.sh — attempt to actually land one pull request, fixing exactly the
# merge-blockers that are safe to fix without a human's judgment.
#
# Reads current PR state, updates a behind branch, and pins each merge request to
# the checked head SHA. Review threads must already be explicitly resolved after
# verification. A comment prefix cannot prove that a finding was addressed.
# Incomplete snapshots and changed heads stop without arming auto-merge.
#
# Every network call goes over curl, not `gh api` / `gh pr merge` — same reason as
# list-prs.sh (see its header): under the Claude Code sandbox, gh's Go TLS stack
# fails cert verification against api.github.com while curl completes the identical
# handshake cleanly. `gh` is used only for `gh auth token`, a local credential read.
#
# Usage:
#   merge-pr.sh --repo <owner/name> --pr <N> [--method squash|merge|rebase] [--no-auto]
#   merge-pr.sh --repo <owner/name> --pr <N> --resolve-thread <ID> --verified-head <SHA>
#
# The resolution mode is a separate, explicit action after the agent verifies the
# finding and posts its evidence. It checks thread ownership and the verified head,
# resolves that one thread, and exits without attempting a merge or auto-merge.
#
# Without --method, tries squash, then merge, then rebase, stopping at the first the
# repository accepts — GitHub's own error names any method the repo disallows, which
# is simpler and more current than caching each repo's `allowed_merge_methods` here.
#
# The REST merge call is only attempted when GitHub reports mergeStateStatus CLEAN
# and the head commit's check rollup is SUCCESS. Any other state — a check still
# PENDING/EXPECTED, no rollup yet (a fresh head whose checks have not registered),
# a BLOCKED/UNSTABLE/HAS_HOOKS/UNKNOWN merge state — is reported as blocked
# (checks_pending / not_clean / branch_protection) instead of merged, and auto-merge
# is armed where GitHub allows it. See "What this script will NOT do" below for why
# that gate cannot be left to GitHub.
#
# Eligible BLOCKED outcomes also try arming GitHub's native auto-merge before it
# reports — the courtesy costs one extra mutation and means a PR blocked only on
# something outside this script's authority (a pending required check, a review
# still needed) finishes on its own the moment that condition clears, with no further
# call to this script needed. Auto-merge fires only once GitHub's merge requirements
# are met (it does not act on the arming user's bypass), so it is the safe hand-off
# for a not-yet-CLEAN PR. GitHub refuses to arm it on a PR that is already CLEAN or
# UNSTABLE; that is reported as automerge=unavailable. Arming it changes nothing about whether THIS run considers the PR blocked; the
# exit code and reason are unaffected.
#
# Exit codes:
#   0 — merged, or explicit resolution mode printed "RESOLVED <repo>#<pr> ..."
#   2 — precondition failed (missing gh/curl/jq, bad arguments)
#   3 — the GitHub query itself failed (network, rate limit, permissions)
#   4 — blocked on something this script will not act on unasked: a required human
#       approval, a code-scanning threshold, a check still running, a merge state
#       other than CLEAN, an unresolved thread with no
#       verified resolution yet, or a merge conflict. Never retried, never
#       overridden with admin/force. (stdout: "BLOCKED <repo>#<pr> reason=<category>
#       detail=<...> automerge=<armed|unavailable>")
#
# What this script will NOT do, on purpose:
#   - Never merges past branch protection or a ruleset. Not passing `--admin` is
#     NOT enough to guarantee that: when the caller's token belongs to someone on a
#     ruleset's bypass list with bypass mode "always" (org admins on seankoji-com's
#     "Universal rules" and "PR gatekeeper" rulesets), GitHub applies the bypass
#     implicitly to a plain REST merge — no flag, no warning — and accepts it while
#     required checks are still pending. seankoji-com/careynas.net#2635 merged that
#     way at 08:49:42 UTC (18:49 AEST, Sun 27 Sep 2026) with its rollup PENDING. The
#     guard is this script's own: merge only when mergeStateStatus is CLEAN and the
#     rollup is SUCCESS (the rollup does not depend on who is asking), and hand
#     everything else to auto-merge. The merge PUT pins the checked head SHA, so a new
#     commit is refused (409); a check re-queued on the SAME head between the read and
#     the PUT is a residual window REST merge cannot close. A required check, a required reviewer, or an org ruleset exists on
#     purpose; the fix for a PR that cannot satisfy one is either satisfying it for
#     real or a human's call to waive it, never something this script does on its own.
#   - Never resolves review threads as part of merging. Resolution requires the
#     separate --resolve-thread action and the agent's --verified-head assertion.
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
RESOLVE_THREAD=""
VERIFIED_HEAD=""
AUTO_MERGE=1

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
  --resolve-thread)
    RESOLVE_THREAD="${2:-}"
    shift 2
    ;;
  --verified-head)
    VERIFIED_HEAD="${2:-}"
    shift 2
    ;;
  --no-auto)
    AUTO_MERGE=0
    shift
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
if [ -n "$RESOLVE_THREAD" ] || [ -n "$VERIFIED_HEAD" ]; then
  [ -n "$RESOLVE_THREAD" ] && [ -n "$VERIFIED_HEAD" ] || die "resolution requires both --resolve-thread and --verified-head"
  [[ "$VERIFIED_HEAD" =~ ^[0-9a-f]{40}$ ]] || die "--verified-head must be a full lowercase commit SHA"
  [ -z "$METHOD" ] || die "resolution mode cannot also select a merge method"
fi

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
    query: "query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ id state headRefOid mergeable mergeStateStatus reviewDecision baseRefName headRefName autoMergeRequest{ enabledAt } reviewThreads(first:100){ pageInfo{ hasNextPage } nodes{ id isResolved } } commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } } } } }",
    variables: { owner: $owner, name: $name, number: $number }
  }')
  resp="$(curl_graphql_retry "$query")" || { echo "merge-pr.sh: state query failed: $resp" >&2; return 1; }
  if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
    echo "merge-pr.sh: GraphQL returned errors: $(jq -c '.errors' <<<"$resp")" >&2
    return 1
  fi
  if ! jq -e '.data.repository.pullRequest | if .state == "MERGED" or .state == "CLOSED" then true else .state == "OPEN" and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$")) and (.reviewThreads.nodes | type == "array") and (.reviewThreads.pageInfo.hasNextPage | type == "boolean") end' >/dev/null 2>&1 <<<"$resp"; then
    echo "merge-pr.sh: missing or invalid PR state" >&2
    return 1
  fi
  echo "$resp"
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
  local pr_id already m mutation resp state expected_head
  # update-branch can succeed before mergeStateStatus catches up. Arm against a
  # fresh head and complete review state, never the pre-update snapshot.
  state="$(fetch_state)" || return 1
  handle_terminal_state "${1:-}"
  expected_head="$(jq -r '.data.repository.pullRequest.headRefOid' <<<"$state")"
  jq -e '.data.repository.pullRequest.reviewThreads | .pageInfo.hasNextPage == false and all(.nodes[]; .isResolved == true)' >/dev/null <<<"$state" || return 1
  pr_id="$(jq -r '.data.repository.pullRequest.id // empty' <<<"$state")"
  [ -n "$pr_id" ] || return 1
  already="$(jq -r '.data.repository.pullRequest.autoMergeRequest.enabledAt // empty' <<<"$state")"
  [ -n "$already" ] && return 2
  local methods_upper=(SQUASH MERGE REBASE)
  [ -n "$METHOD" ] && methods_upper=("$(tr '[:lower:]' '[:upper:]' <<<"$METHOD")")
  for m in "${methods_upper[@]}"; do
    mutation=$(jq -n --arg id "$pr_id" --arg m "$m" --arg sha "$expected_head" '{
      query: "mutation($id:ID!,$m:PullRequestMergeMethod!,$sha:GitObjectID!){ enablePullRequestAutoMerge(input:{pullRequestId:$id, mergeMethod:$m, expectedHeadOid:$sha}){ pullRequest{ autoMergeRequest{ enabledAt } } } }",
      variables: { id: $id, m: $m, sha: $sha }
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
  local reason="$1" detail="$2" automerge="unavailable" arm_rc
  if jq -e '.data.repository.pullRequest.autoMergeRequest.enabledAt' >/dev/null 2>&1 <<<"${state:-}"; then
    automerge="preexisting"
  fi
  if [ "$AUTO_MERGE" = 1 ]; then
    case "$reason" in
    head_changed | conflict | behind | incomplete_review_state | unanswered_threads | closed | automerge_already_enabled | verified_head_changed | thread_not_on_pr | permission_denied | validation_failed) ;;
    *)
      if enable_automerge "$reason"; then
        automerge="armed"
      else
        arm_rc=$?
        [ "$arm_rc" != 2 ] || automerge="preexisting"
      fi
      ;;
    esac
  fi
  echo "BLOCKED ${REPO}#${PR_NUMBER} reason=${reason} detail=${detail} automerge=${automerge}"
  exit 4
}

handle_terminal_state() {
  case "$(jq -r '.data.repository.pullRequest.state' <<<"$state")" in
    MERGED) echo "MERGED ${REPO}#${PR_NUMBER} via preexisting${1:+ prior_blocker=$1}"; exit 0 ;;
    CLOSED) blocked "closed" "PR was closed without merging; no action taken${1:+; prior_blocker=$1}" ;;
  esac
}

try_merge() {
  local method="$1" resp code body
  resp="$(curl_rest PUT "/repos/${REPO}/pulls/${PR_NUMBER}/merge" "$(jq -n --arg m "$method" --arg sha "$expected_head" '{merge_method:$m,sha:$sha}')")" || return 2
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [ "$code" = "200" ] && jq -e '.merged == true' >/dev/null 2>&1 <<<"$body"; then
    echo "MERGED ${REPO}#${PR_NUMBER} via ${method}"
    return 0
  fi
  # 405: "Pull Request is not mergeable" (or a merge-method the repo disallows) —
  # the caller tries the next method / classifies the message. A 409 means the
  # checked head changed: never retry another method or arm auto-merge for it.
  printf '%s' "$body" >&2
  echo "$code"
}

state="$(fetch_state)" || die "could not read PR state" 3
handle_terminal_state
expected_head="$(jq -r '.data.repository.pullRequest.headRefOid' <<<"$state")"
if jq -e '.data.repository.pullRequest.autoMergeRequest.enabledAt' >/dev/null <<<"$state"; then
  if [ "$AUTO_MERGE" = 0 ] || ! jq -e '.data.repository.pullRequest.reviewThreads | .pageInfo.hasNextPage == false and all(.nodes[]; .isResolved == true)' >/dev/null <<<"$state"; then
    blocked "automerge_already_enabled" "auto-merge may land independently; disable the existing request before continuing this verification flow"
  fi
fi
if [ -n "$RESOLVE_THREAD" ]; then
  [ "$VERIFIED_HEAD" = "$expected_head" ] || blocked "verified_head_changed" "re-verify the finding against the new head before resolving"
  # Query the node directly so resolution works beyond the first 100 threads too.
  query=$(jq -n --arg id "$RESOLVE_THREAD" '{query:"query($id:ID!){node(id:$id){... on PullRequestReviewThread{id pullRequest{id headRefOid}}}}",variables:{id:$id}}')
  thread_state="$(curl_graphql_retry "$query")" || die "thread query failed" 3
  pr_id="$(jq -r '.data.repository.pullRequest.id' <<<"$state")"
  jq -e --arg id "$pr_id" --arg sha "$VERIFIED_HEAD" '.errors == null and .data.node.pullRequest.id == $id and .data.node.pullRequest.headRefOid == $sha' >/dev/null <<<"$thread_state" || blocked "thread_not_on_pr" "thread is not on this PR at the verified head; refresh its identity and the finding"
  mutation=$(jq -n --arg id "$RESOLVE_THREAD" '{query:"mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}",variables:{id:$id}}')
  resolution="$(curl_graphql_retry "$mutation")" || die "thread resolution outcome unknown; refresh before retrying" 3
  jq -e '.errors == null and .data.resolveReviewThread.thread.isResolved == true' >/dev/null <<<"$resolution" || die "thread resolution failed" 3
  echo "RESOLVED ${REPO}#${PR_NUMBER} thread=${RESOLVE_THREAD} head=${VERIFIED_HEAD}"
  exit 0
fi
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
  handle_terminal_state
fi

# A bounded query must not silently certify a partial review snapshot.
if jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' >/dev/null <<<"$state"; then
  blocked "incomplete_review_state" "more than 100 review threads; inspect all pages and merge through the host's verified PR flow"
fi
unanswered_count="$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved != true)] | length' <<<"$state")"

if [ "$unanswered_count" -gt 0 ]; then
  thread_ids="$(jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved != true) | .id] | join(",")' <<<"$state")"
  blocked "unanswered_threads" "${unanswered_count} unresolved review thread(s); threads=${thread_ids}; verify each finding and explicitly resolve it before merging"
fi

expected_head="$(jq -r '.data.repository.pullRequest.headRefOid' <<<"$state")"

# Checked here, after fixing what could be fixed, rather than at the very top: base
# drift or an unanswered thread can be the reason a required check never ran at all
# (queued behind the branch update), so re-reading it now — not the possibly-stale
# copy from the very first fetch_state call — is what makes this an accurate report
# instead of a guess.
#
# This is the gate that stops the implicit admin bypass (see the header): GitHub
# would accept a merge here for a ruleset-bypass actor whatever the rollup says, so
# nothing short of CLEAN + SUCCESS reaches try_merge. A null rollup is treated as
# pending, not green: right after update-branch (or any push) the new head has no
# check suites yet, and a bypass-capable token must not merge into that gap.
checks_state="$(jq -r '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state // "NONE"' <<<"$state")"
merge_state="$(jq -r '.data.repository.pullRequest.mergeStateStatus // "UNKNOWN"' <<<"$state")"
if [ "$merge_state" = "DIRTY" ]; then
  blocked "conflict" "mergeStateStatus=DIRTY; resolve in a worktree first, not here"
fi
case "$checks_state" in
FAILURE | ERROR)
  blocked "failing_checks" "required status checks are red (rollup=${checks_state}) — that is a code/CI fix, not something this script can resolve"
  ;;
PENDING | EXPECTED | NONE)
  blocked "checks_pending" "checks have not finished (rollup=${checks_state}, mergeStateStatus=${merge_state}); not merging until they pass"
  ;;
SUCCESS) ;;
*)
  blocked "checks_pending" "unrecognised check rollup (rollup=${checks_state}, mergeStateStatus=${merge_state}); not merging until it reads SUCCESS"
  ;;
esac
review_decision="$(jq -r '.data.repository.pullRequest.reviewDecision // "NONE"' <<<"$state")"
if [ "$merge_state" = "BLOCKED" ]; then
  case "$review_decision" in
  REVIEW_REQUIRED | CHANGES_REQUESTED)
    blocked "branch_protection" "mergeStateStatus=BLOCKED with reviewDecision=${review_decision}; a required human review is outstanding"
    ;;
  esac
fi
if [ "$merge_state" != "CLEAN" ]; then
  blocked "not_clean" "mergeStateStatus=${merge_state} (rollup=${checks_state}); merging now could apply a ruleset bypass, so only CLEAN is merged directly"
fi

methods=("$METHOD")
[ -z "$METHOD" ] && methods=(squash merge rebase)

last_code=""
for m in "${methods[@]}"; do
  out="$(try_merge "$m")" || die "merge request failed; outcome unknown, refresh PR state before retrying" 3
  if [[ "$out" == MERGED* ]]; then
    echo "$out"
    exit 0
  fi
  if [ "$out" = "409" ]; then
    blocked "head_changed" "PR head changed after verification; inspect the new commit and rerun"
  fi
  if [ "$out" = "403" ]; then
    blocked "permission_denied" "GitHub rejected the merge (HTTP 403); inspect the API error and repository permissions or rules before retrying"
  fi
  if [ "$out" = "422" ]; then
    blocked "validation_failed" "GitHub rejected the merge input (HTTP 422); inspect the API error and correct the request before retrying"
  fi
  if [ "$out" != "405" ]; then
    die "merge request returned HTTP ${out}; refresh PR state before retrying" 3
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
handle_terminal_state
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
