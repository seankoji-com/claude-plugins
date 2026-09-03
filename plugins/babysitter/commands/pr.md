---
name: babysitter:pr
description: >
  Use when one named pull request should be driven to mergeable and then watched until
  it merges — review comments answered, conflicts resolved, failing checks fixed, base
  drift kept down. Do not use to sweep a whole repository (/babysitter:repo) or a whole
  org (/babysitter:org).
argument-hint: "<pr-url | owner/repo#N | N> [--interval 60]"
disable-model-invocation: true
---

# /babysitter:pr — babysit one pull request until it merges

**Before executing any steps**, output this intro block:

> 🍼 **babysitter:pr** — babysitting one PR to the finish
>
> Clearing what blocks this pull request — review comments, merge conflicts, failing
> checks, drift behind the base branch — then watching it until it merges or closes.
> Fix commits are reviewed locally before they are pushed, and they go to the PR branch
> only.

---

Same machinery as `/babysitter:org`, aimed at one PR, and it stops on its own when that
PR merges or closes rather than watching indefinitely.

**Push scope.** Fix commits go to this PR's head branch only, never to its base, never
force-pushed.

---

## Step 1 — Resolve the target

Accept any of:

| the user typed | resolve to |
| --- | --- |
| `https://github.com/<owner>/<repo>/pull/<N>` | owner/repo and N |
| `owner/repo#N` | as written |
| `#N` or a bare `N` | N, with owner/repo from the current repo's origin remote |

For the bare-number form, get the repo from `gh repo view --json nameWithOwner --jq
.nameWithOwner`. If that fails — not in a repo, no origin — stop and ask for the full
URL rather than guessing which repository was meant.

Preflight the same three things `/babysitter:org` does: `gh`, `jq`, `gh auth status`.

## Step 2 — Snapshot the PR

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/list-prs.sh --repo <owner/repo> --pr <N> --all-authors
```

`--all-authors` because the user named this PR explicitly — that naming is the decision
about whose PR to touch, so the org sweep's author filter has nothing left to decide.
Drafts and forks are still filtered out by default; add `--include-drafts` or
`--include-forks` if the user asked for that PR specifically and it is one of those.

No output means the PR is closed, merged, a draft, or on a fork. Say which — re-run with
`--include-drafts --include-forks --all-authors` to distinguish "filtered out" from
"not open" — and stop.

## Step 3 — Show what is blocking it, and confirm

Print the PR title, author, base, and its blockers using the same mapping as
`/babysitter:org` Step 3 — `mergeable == "CONFLICTING"`, `failing`, and
`unresolved_threads`. Base drift is not among them for the reason given there: the
snapshot cannot tell whether this PR already contains the base branch head, and the
agent settles it from a merge-base in the worktree as its first step.

Ask for confirmation before proceeding — this pushes commits to the branch. If the PR is
already clean, say so and ask whether to watch it anyway.

## Step 4 — Prepare the worktree

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/pr-workspace.sh --repo <owner/repo> --pr <N> --branch <head_ref>
```

The path is the last line of stdout. Exit 4 means a previous run left uncommitted
changes there — report the path and stop rather than dispatching over them.

**Do not pass `isolation: "worktree"` to the Agent tool** — that isolates the repository
this session was launched in, which is not necessarily this PR's repository.

## Step 5 — Dispatch

One `babysitter:🍼` agent, `model: "haiku"`, with the worktree path, `repo`, `number`,
`url`, `head_ref`, `base_ref`, the failing check names, and the unresolved review
threads:

```bash
gh api "repos/<owner/repo>/pulls/<N>/comments" \
  --jq '[.[] | select((.body | startswith("[babysitter]")) | not)
        | {id, user: .user.login, path, line, body}]'
```

The `[babysitter]` filter drops the plugin's own replies — without it the agent answers
itself on the next pass.

If it returns `blocked`, or `partial` with a non-null `blocked_on`, re-dispatch **once**
at `model: "sonnet"` with that `blocked_on` and `notes` passed through verbatim. If it
is still blocked after that, report and leave it:
`⚠ <repo>#<N> still blocked after escalation: <reason>`

## Step 6 — Watch until it merges

```
Monitor:
  command: ${CLAUDE_PLUGIN_ROOT}/scripts/pr-events.sh --repo <owner/repo> --pr <N> --all-authors --exit-when-empty --interval <interval>
  description: "<owner/repo>#<N> — conflicts, checks, reviews, base drift"
  persistent: true
```

`--exit-when-empty` is what makes this command self-terminating: when the PR merges,
closes, or otherwise leaves scope, the script emits `GONE` then `END` and exits, and the
watch is over. Pass the same filter flags used in Step 2 so the watch sees the same PR
the sweep did.

Handle events with the same table as `/babysitter:org` Step 8:

| kind | what to do |
| --- | --- |
| `CONFLICT`, `BASE-MOVED` | re-dispatch that PR, blocker = conflict / base moved (the agent checks whether it is actually behind) |
| `CHECKS-FAILED` | re-dispatch, blocker = the named checks |
| `REVIEW`, `COMMENT`, `THREADS` | re-fetch comments (Step 5) and re-dispatch |
| `CHECKS-GREEN` | report it; nothing to do |
| `DRAFT` | the PR went back to draft — stop the watch and say so |
| `GONE` | merged, closed, or out of scope — go to Step 7 |
| `ERROR` | report; the monitor is still polling |
| `END` | go to Step 7 |

Never run two agents in this worktree at once — they will fight over the index. If
events arrive while one is running, coalesce them and re-dispatch once when it returns.

Send a PushNotification when the PR merges, when it is still blocked after escalation,
or on a repeated `ERROR`.

## Step 7 — Stop

1. TaskStop the monitor if it has not already exited.
2. Report the outcome: merged, closed, or still open with what remains blocking it.
3. If the PR merged or closed, clean up:
   `${CLAUDE_PLUGIN_ROOT}/scripts/pr-workspace.sh --repo <owner/repo> --pr <N> --remove`
   Leave the worktree in place if it is still open — the next run reuses it.
4. Append one audit line:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh \
  --plugin babysitter --command /babysitter:pr --scope project \
  --exit-status <completed|partial|blocked|failed|cancelled> \
  --duration-ms <ms since dispatch started> \
  --notes "<owner/repo>#<N>: <merged|closed|open>, <p> pushes, <b> blockers left"
```
