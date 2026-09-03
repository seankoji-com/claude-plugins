---
name: babysitter:org
description: >
  Use when every open pull request across a GitHub org should be driven to mergeable —
  review comments answered, conflicts resolved, failing checks fixed, base drift kept
  down — and then watched so new pull requests and new events are handled as they land.
  Do not use for one repository (/babysitter:repo) or one known PR (/babysitter:pr).
argument-hint: "[org] [--include-drafts] [--include-forks] [--all-authors] [--interval 60]"
disable-model-invocation: true
---

# /babysitter:org — keep every open PR in the org unblocked

**Before executing any steps**, output this intro block:

> 🍼 **babysitter:org** — babysitting every open PR in the org
>
> Finding your open pull requests, giving each one its own worktree and its own agent,
> and clearing what blocks it: review comments, merge conflicts, failing checks, and
> drift behind the base branch. Then watching for new events and handling them as they
> land. Fix commits are reviewed locally before they are pushed. Nothing is pushed
> until you approve the roster.

---

This command runs a sweep and then a watch. The sweep dispatches one agent per PR; the
watch keeps that going until you stop it.

**The watch includes pull requests that do not exist yet.** A PR opened anywhere in the
org while the watch is running surfaces as a `NEW` event on the next poll and is handled
like any other. That is why the watch does not pass `--exit-when-empty` — an org with
nothing open right now is quiet, not finished.

**Push scope.** Fix commits go to PR head branches only, never to a base or default
branch, never force-pushed. The roster gate in Step 3 is where you approve that — it is
the only confirmation, so it lists every PR that will be touched.

---

## Step 1 — Preflight

```bash
command -v gh >/dev/null && command -v jq >/dev/null && gh auth status
```

If `gh` or `jq` is missing, or auth fails, stop and say which — every later step needs
all three.

Resolve the org, in this order:

1. `$1`, if the invocation passed one.
2. Otherwise the owner of the current repo's origin remote:
   `gh repo view --json owner --jq .owner.login`
3. Otherwise stop and ask. Do not guess an org — the wrong one either finds nothing or
   finds someone else's pull requests.

## Step 2 — Enumerate

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/list-prs.sh --org <org> [passthrough flags]
```

Forward `--include-drafts`, `--include-forks` and `--all-authors` straight through if
the user passed them. By default this returns open PRs authored by you or by a bot
(Copilot, dependabot, anything ending `[bot]`), excluding drafts and excluding PRs whose
head branch lives in a fork — a fork's branch usually rejects our pushes, so babysitting
it would produce work that cannot land.

One JSON object per line. Exit 3 means the GitHub query failed: report it and stop.

If there are zero lines, say so and ask whether to watch the org anyway for PRs opened
later. Do not arm the monitor silently on an empty roster: across a whole org, zero open
PRs is more often a mistyped org name than an empty one, and that is worth a look before
committing to a long watch.

A warning on stderr about a truncated result means the org has more open PRs than
`--limit` fetched. Raise it (max 100) or narrow the scope with `/babysitter:repo` rather
than proceeding with a partial roster.

## Step 3 — Roster gate

Print one row per PR — repo#number, author, title, and what is blocking it, derived from
the snapshot:

| field in the snapshot | blocker shown |
| --- | --- |
| `mergeable == "CONFLICTING"` | conflict |
| `failing` non-empty | checks: names |
| `unresolved_threads > 0` | comments: N |

Base drift is deliberately **not** on this list. `base_oid` is the base branch head
itself, so no comparison against it is possible from a snapshot alone — telling whether
this PR already contains those commits needs a merge-base, which the agent computes in
its worktree for free. Every dispatched agent checks and merges base drift as its first
step, so a PR that is behind is handled whether or not the roster could see it.

A PR with none of these is listed as `clean` — it stays on the watch roster but no agent
is dispatched for it now.

Then ask for confirmation to proceed, naming the count of PRs that will receive pushes.
Wait for a clear yes. If the user narrows the list, honour exactly that subset.

## Step 4 — Prepare worktrees

For each approved PR, **in the orchestrator, one at a time**:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/pr-workspace.sh --repo <repo> --pr <number> --branch <head_ref>
```

The path is the last line of stdout.

Serially, and here rather than inside the agents, for a specific reason: two PRs in the
same repository share one cache clone, and two `git worktree add` calls racing on one
clone's index corrupt it. Cloning is also the slow part, and doing it here means an
agent starts with its checkout already warm.

Exit 4 means a previous run left uncommitted changes in that worktree — do not dispatch
for it; report the path and let the user look.

**Do not pass `isolation: "worktree"` to the Agent tool.** That would create a worktree
of the repository this session was launched in, which is the wrong repository for every
PR but at most one. The isolation comes from the path above.

## Step 5 — Dispatch

One `babysitter:🍼` agent per PR, `model: "haiku"`, concurrently — but at most 8 in
flight at once, so a large org does not stampede the GitHub API or the machine.

Each prompt must carry: the worktree path, `repo`, `number`, `url`, `head_ref`,
`base_ref`, and the specific blockers from Step 3 with their details — the failing check
names, and the unresolved review threads with their comment ids, authors, paths and
bodies:

```bash
gh api "repos/<repo>/pulls/<number>/comments" \
  --jq '[.[] | select((.body | startswith("[babysitter]")) | not)
        | {id, user: .user.login, path, line, body}]'
```

Filter out `[babysitter]`-prefixed comments — those are the plugin's own replies, and
feeding them back produces an agent answering itself.

Tell the agent to follow its own instructions and return the JSON schema they define.

## Step 6 — Escalate what came back blocked

For every agent returning `status` of `blocked` or `partial` with a non-null
`blocked_on`, re-dispatch **that PR once** at `model: "sonnet"`, passing the haiku
agent's `blocked_on` and `notes` verbatim so it starts where the first attempt stopped.

Once. A second escalation is a human's call — report it instead:
`⚠ <repo>#<number> still blocked after escalation: <reason>`

This is the whole reason `blocked` is a cheap answer: judgment work that haiku declines
gets a stronger model rather than a guess.

## Step 7 — Arm the watch

```
Monitor:
  command: ${CLAUDE_PLUGIN_ROOT}/scripts/pr-events.sh --org <org> --interval <interval> [passthrough flags]
  description: "open PRs in <org> — conflicts, checks, reviews, base drift"
  persistent: true
```

Pass the same passthrough flags as Step 2, so the watch and the sweep agree on which
PRs exist. Default interval 60s; the script refuses anything below 30s.

Say that the watch is armed and that `/tasks` or TaskStop ends it.

## Step 8 — Handle events

Each line is `<KIND> <repo>#<number> [detail] [url]`.

| kind | what to do |
| --- | --- |
| `NEW` | a PR was opened (or became eligible) — Step 4 then Step 5 for it |
| `CONFLICT`, `BASE-MOVED` | re-dispatch that PR, blocker = conflict / base moved (the agent checks whether it is actually behind) |
| `CHECKS-FAILED` | re-dispatch, blocker = the named checks |
| `REVIEW`, `COMMENT`, `THREADS` | re-fetch that PR's comments (Step 5's filter) and re-dispatch |
| `CHECKS-GREEN` | nothing to do — report it |
| `DRAFT` | drop from the active roster; a draft is not ready |
| `GONE` | `pr-workspace.sh --repo <repo> --pr <n> --remove`, drop from the roster |
| `ERROR` | report it; the monitor is still polling |
| `END` | the watch has stopped — go to Step 9 |

`NEW` goes through the roster gate the same way the initial sweep did: name the PR and
its author and get a yes before pushing to it. Step 3 approved the PRs on the table at
that moment, not every PR the org will ever have.

Two rules that keep this from thrashing:

- **One agent per PR at a time.** If events arrive for a PR whose agent is still
  running, note them and re-dispatch once when it returns. Two agents in one worktree
  will fight over the index.
- **Coalesce a batch.** Several events for the same PR in one notification are one
  re-dispatch carrying all of them, not one each.

Escalation (Step 6) applies to re-dispatches too: once per event batch, then report.

Send a PushNotification for anything the user would act on now — a PR still blocked
after escalation, or a repeated `ERROR`. Routine green checks are not that.

## Step 9 — Stop

When the user stops the watch, or on `END`:

1. TaskStop the monitor if it is still running.
2. Print a summary: PRs handled, pushes made, still blocked and why.
3. Leave the worktrees in place — they are the cache for the next run. Remove them only
   if the user asks: `pr-workspace.sh --repo <repo> --pr <n> --remove`
4. Append one audit line:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh \
  --plugin babysitter --command /babysitter:org --scope user \
  --exit-status <completed|partial|blocked|failed|cancelled> \
  --duration-ms <ms since the sweep started> \
  --notes "<org>: <n> PRs, <p> pushed, <b> still blocked"
```

Scope is `user`, not `project`: a sweep spans many repositories, so pinning it to
whichever one the session happened to start in would mislabel the record.
