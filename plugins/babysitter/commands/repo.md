---
name: babysitter:repo
description: >
  Use when every open pull request in one repository should be driven to mergeable and
  then watched — including pull requests opened after the watch starts. Do not use for a
  whole org (/babysitter:org) or for one known PR (/babysitter:pr).
argument-hint: "[owner/repo] [--include-drafts] [--include-forks] [--all-authors] [--interval 60]"
disable-model-invocation: true
---

# /babysitter:repo — keep one repository's PRs unblocked

**Before executing any steps**, output this intro block:

> 🍼 **babysitter:repo** — babysitting every open PR in one repo
>
> Clearing what blocks each open pull request here — review comments, merge conflicts,
> failing checks, drift behind the base branch — then watching the repository so new
> pull requests and new events are picked up as they land. Fix commits are reviewed
> locally before they are pushed. Nothing is pushed until you approve the roster.

---

`/babysitter:org` with the blast radius of one repository. Same sweep, same agents, same
watch — the only difference is the scope of the query and the fact that you are almost
always in the repository you are asking about.

**It keeps watching after the sweep, including for pull requests that do not exist yet.**
A PR opened while the watch is running shows up as a `NEW` event on the next poll and
gets the same treatment as the ones that were there at the start. This is the reason the
watch does **not** pass `--exit-when-empty`: a repository with no open PRs right now is a
quiet repository, not a finished one.

**Push scope.** Fix commits go to PR head branches in this repository only, never to a
base or default branch, never force-pushed. The roster gate is where you approve that.

---

## Step 0 — Load what previous runs learned

Read `~/.claude/babysitter/learnings.md` if it exists — `$BABYSITTER_HOME/learnings.md`
when that variable is set. `Read` is a tool call, not Bash: it does not expand `~`, so
resolve `$HOME` yourself and pass the absolute path.

Apply the `## Active rules` section to the whole run, and the `## Per-repo notes` line
for this repository — passing it into the agent prompt in Step 5, since agents
cannot read this file. Apply both silently; a missing file is the normal first run.

The file sits outside every repository being babysat on purpose. What this command
learns is about the machine, the remote, and the runbook — none of which belong in the
repository whose PRs it is fixing.

## Taking notes while it runs

Same mechanism and the same five kinds as `/babysitter:org` (*Taking notes while the
sweep runs*), with this command's own name:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-note.sh \
  --command /babysitter:repo --kind <env|github|process|repo|policy> \
  --scope "<owner/repo, or owner/repo#N>" --note "<what happened, and what to do about it>"
```

Notes land in `~/.claude/babysitter/run-notes/<date>-babysitter-repo.md`. Write one when the
machine, the remote, this runbook, this repository, or a gate did something a future run
would want to know about. Routine progress is not a note.

## Step 1 — Preflight and resolve the repository

```bash
command -v gh >/dev/null && command -v jq >/dev/null && gh auth status
```

Stop and say which is missing if any of the three fails.

Resolve the repository, in this order:

1. `$1`, if the invocation passed one. Accept `owner/name` or a full GitHub URL.
2. Otherwise the current repository: `gh repo view --json nameWithOwner --jq .nameWithOwner`
3. Otherwise stop and ask. Do not guess.

Say which repository you resolved before going further — "the current repo" is exactly
the assumption worth stating out loud when the next step pushes commits.

## Step 2 — Enumerate

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/list-prs.sh --repo <owner/repo> [passthrough flags]
```

Forward `--include-drafts`, `--include-forks` and `--all-authors` if the user passed
them. Defaults are the same as `/babysitter:org`: open PRs authored by you or a bot,
excluding drafts and PRs whose head branch lives in a fork.

`--all-authors` is worth offering here more often than in org mode — a single repository
is a plausible thing to babysit on a team's behalf, where an org-wide sweep of everyone's
branches is not. Offer it; do not assume it.

One JSON object per line. Exit 3 means the query failed: report it and stop. A warning on
stderr about a truncated result means the repository has more open PRs than `--limit`
fetched — raise it (max 100) rather than proceeding with a partial roster.

Zero lines is not a reason to stop here, unlike in org mode: ask whether to watch the
repository anyway for PRs opened later. If the user says no, stop.

## Step 3 — Roster gate

Print one row per PR — number, author, title, and its blockers, from the snapshot:

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

A PR with none of these is `clean` — it stays on the watch roster, but no agent is
dispatched for it now.

Ask for confirmation, naming how many PRs will receive pushes. Wait for a clear yes. If
the user narrows the list, honour exactly that subset.

## Step 4 — Prepare worktrees

For each approved PR, **in the orchestrator, one at a time**:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/pr-workspace.sh --repo <owner/repo> --pr <number> --branch <head_ref>
```

The path is the last line of stdout.

Serial matters more here than anywhere else: every PR in this command shares one cache
clone, and two concurrent `git worktree add` calls on one clone corrupt its index. The
first PR pays for the clone; the rest are fast.

**One `pr-workspace.sh` call per Bash tool invocation**, and dispatch each PR's agent
(Step 5) as soon as *its* worktree is ready rather than waiting for the whole roster.
Two reasons, both learned the hard way: a `while read` loop running many of these inside
one Bash call has been seen failing from the second iteration on with `command not
found` on plain coreutils; and finishing all setup before any dispatch leaves every
agent slot idle behind the slowest clone. Only the `pr-workspace.sh` calls need to be
serial — separate worktrees cut from one clone are safe to work in concurrently.

Exit 4 means a previous run left uncommitted changes in that worktree — report the path
and skip that PR rather than resetting over the work.

**Do not pass `isolation: "worktree"` to the Agent tool.** Even when this repository *is*
the session's repository, that would isolate the session's own checkout rather than the
per-PR worktree the path above names, and two PRs would end up sharing one.

## Step 5 — Dispatch

One `babysitter:🍼` agent per PR, `model: "haiku"`, concurrently, at most 8 in flight.

Each prompt carries the worktree path, `repo`, `number`, `url`, `head_ref`, `base_ref`,
the failing check names, and the unresolved review threads:

```bash
gh api "repos/<owner/repo>/pulls/<number>/comments" \
  --jq '[.[] | select((.body | startswith("[babysitter]")) | not)
        | {id, user: .user.login, path, line, body}]'
```

The `[babysitter]` filter drops the plugin's own replies; without it an agent answers
itself on the next pass.

## Step 6 — Deal with what came back blocked

**First, read what it was blocked on — a stronger model does not fix every blocker.**

If `blocked_on` is about pushing or the environment rather than the code — an auth or
signing failure, a network or proxy error, a gate that could not run — escalating burns
a sonnet dispatch to rediscover the same wall. The agent's work is already committed in
its worktree; the cheaper move is to finish it yourself:

```bash
git -C <worktree> push origin HEAD:<head_ref>
```

The orchestrator has options a dispatched agent does not (a sandbox bypass among them),
and in one sweep this cleared three of three push failures that had presented as three
different errors, on the first retry, with no code change. If the retry also fails, then
report it — do not escalate a wall to a bigger model.

For a blocker in the code or the judgment — a design decision, an ambiguous review
comment, two incompatible sides of a conflict — re-dispatch **that PR once** at
`model: "sonnet"`, passing `blocked_on` and `notes` through verbatim.

Once. Then report rather than retrying:
`⚠ <repo>#<number> still blocked after escalation: <reason>`

## Step 7 — Arm the watch

```
Monitor:
  command: ${CLAUDE_PLUGIN_ROOT}/scripts/pr-events.sh --repo <owner/repo> --interval <interval> [passthrough flags]
  description: "<owner/repo> — open PRs: new, conflicts, checks, reviews, base drift"
  persistent: true
```

Pass the same passthrough flags as Step 2 so the watch and the sweep agree on scope. No
`--exit-when-empty` — this watch is meant to outlive the current set of PRs. Default
interval 60s; the script refuses anything below 30s.

Say that the watch is armed, that it will pick up newly opened PRs, and that `/tasks` or
TaskStop ends it.

## Step 8 — Handle events

Each line is `<KIND> <repo>#<number> [detail] [url]`.

| kind | what to do |
| --- | --- |
| `NEW` | a PR was opened (or became eligible) — Step 4 then Step 5 for it |
| `CONFLICT`, `BASE-MOVED` | re-dispatch that PR, blocker = conflict / base moved (the agent checks whether it is actually behind) |
| `CHECKS-FAILED` | re-dispatch, blocker = the named checks |
| `REVIEW`, `COMMENT`, `THREADS` | re-fetch that PR's comments (Step 5) and re-dispatch |
| `CHECKS-GREEN` | report it; nothing to do |
| `DRAFT` | drop from the active roster; a draft is not ready |
| `GONE` | `pr-workspace.sh --repo <owner/repo> --pr <n> --remove`, drop from the roster |
| `ERROR` | report it; the monitor is still polling |
| `END` | the watch stopped — go to Step 9 |

`NEW` goes through the roster gate the same way the initial sweep did: name the PR and
its author and get a yes before pushing to it. The gate in Step 3 approved the PRs on the
table at that moment, not every PR the repository will ever have.

Two rules that keep this from thrashing:

- **One agent per PR at a time.** Events arriving for a PR whose agent is still running
  are noted and folded into one re-dispatch when it returns.
- **Coalesce a batch.** Several events for one PR in a single notification are one
  re-dispatch carrying all of them.

Send a PushNotification for anything worth acting on now — a PR still blocked after
escalation, a repeated `ERROR`. Routine green checks are not that.

## Step 9 — Stop

When the user stops the watch, or on `END`:

1. TaskStop the monitor if it is still running.
2. Summarize: PRs handled, pushes made, still blocked and why.
3. Leave the worktrees as a warm cache. Remove them only if asked:
   `pr-workspace.sh --repo <owner/repo> --pr <n> --remove`
4. Distil the run into `learnings.md` — see *Distilling the run into learnings* below.
5. Append one audit line:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh \
  --plugin babysitter --command /babysitter:repo --scope project \
  --exit-status <completed|partial|blocked|failed|cancelled> \
  --duration-ms <ms since the sweep started> \
  --notes "<owner/repo>: <n> PRs, <p> pushed, <b> still blocked"
```

Scope is `project` here, unlike `/babysitter:org` — this run really does belong to one
repository.

## Distilling the run into learnings

Exactly as in `/babysitter:org` (*Distilling the run into learnings*): read today's
ledger under `~/.claude/babysitter/run-notes/` plus the `learnings` array from every
agent that returned one, append a `## Run log` entry to
`~/.claude/babysitter/learnings.md` headed
`### <YYYY-MM-DD> — /babysitter:repo <owner/repo>`, promote anything now seen twice into
`## Active rules` (cap 10), fold `repo`-kind notes into `## Per-repo notes`, and report
it in one line. No confirmation gate.
