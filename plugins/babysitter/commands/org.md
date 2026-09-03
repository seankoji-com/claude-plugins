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

## Step 0 — Load what previous runs learned

Read `~/.claude/babysitter/learnings.md` if it exists — `$BABYSITTER_HOME/learnings.md`
when that variable is set. `Read` is a tool call, not Bash: it does not expand `~`, so
resolve `$HOME` yourself and pass the absolute path.

Two sections matter:

- **`## Active rules`** — apply to the whole run.
- **`## Per-repo notes`** — apply only where the roster touches that repository, and pass
  the matching lines into that PR's agent prompt in Step 5. Agents cannot read this file.

Apply them silently. Do not recite the file back or announce that you read it. A missing
file is the normal first run — say nothing and carry on.

The file lives outside every repository being babysat, deliberately. A sweep spans an
org, and what it learns is about this machine, the remote, and this command — not about
whichever repository the session happened to start in.

## Taking notes while the sweep runs

An org sweep runs for hours and discovers most of what is worth knowing in the middle,
where a final summary will not reach it. Write each one down as it happens:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-note.sh \
  --command /babysitter:org --kind <env|github|process|repo|policy> \
  --scope "<org, owner/repo, or owner/repo#N>" --note "<what happened, and what to do about it>"
```

It appends one line to `~/.claude/babysitter/run-notes/<date>-babysitter-org.md` and
prints the path. It never fails the sweep — an unwritable notes directory warns and
exits 0.

Write a note when, and only when, a future run would want it:

| kind | write one when |
| --- | --- |
| `env` | the machine or sandbox got in the way — credentials, TLS, signing, a denied path, a permission wall |
| `github` | the remote misbehaved — a 504, a rate limit, a clone that stalled or died |
| `process` | this runbook cost time or capacity — ordering, batching, a dispatch shape that idled agents |
| `repo` | you learned something about one repository that will still be true next run — an SSH-only remote, a clone slow enough to block a batch |
| `policy` | a gate failed, fired wrongly, or was bypassed — the pre-push review is the one that matters most |

Routine progress is not a note. A blocker you hit twice is.

## Step 1 — Preflight

```bash
command -v gh >/dev/null && command -v jq >/dev/null && gh auth status
```

If `gh` or `jq` is missing, or auth fails, stop and say which — every later step needs
all three.

**One failure here is not what it looks like.** `operation not permitted` reading
`~/.config/gh/config.yml` is the sandbox denying that path, not broken authentication —
`gh` is fine and the sweep should continue. Retry the check with the sandbox bypassed
before concluding anything, and expect the same for `gh` and `git` calls later in the
run. If that is happening on every call, adding `~/.config/gh` to the sandbox read
allowlist fixes it once instead of per call.

Also, while writing shell for later steps: this machine's login shell may be zsh, where
`status` is a read-only builtin variable. `status=$?` fails with `read-only variable`.
Use `rc=$?`.

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

**Count with `jq`, never by eye.** Pipe the snapshot through an explicit filter and use
the number it returns:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/list-prs.sh --org <org> [flags] > /tmp/roster.jsonl
jq -s '[.[] | select(.mergeable == "CONFLICTING" or (.failing | length) > 0 or .unresolved_threads > 0)] | length' /tmp/roster.jsonl
```

A miscount here is not cosmetic — it is the number the user says yes to. Counting rows
in a 40-row table you just rendered is exactly the kind of thing that comes out three
short, and the mistake only surfaces after the gate.

Also note what the roster is **not**: if Step 2 warned about truncation, the count in
that warning is GitHub's raw open-PR total before this plugin's author/draft/fork
filters. It will not match your roster and is not supposed to. Never reconcile against
it.

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

**One `pr-workspace.sh` call per Bash tool invocation.** Do not wrap the roster in a
shell `while read` loop and run the whole thing in one call. A loop like that has been
observed failing from the second iteration onward with `command not found` on plain
coreutils — `cat`, `wc` — while `$PATH` still printed intact, which looks like a
subprocess limit rather than anything wrong with the script. Sequential separate calls
were reliable every time. It is chattier; take the chattiness.

Exit 4 means a previous run left uncommitted changes in that worktree — do not dispatch
for it; report the path and let the user look.

**Do not pass `isolation: "worktree"` to the Agent tool.** That would create a worktree
of the repository this session was launched in, which is the wrong repository for every
PR but at most one. The isolation comes from the path above.

### Interleave this with Step 5 — do not finish it first

Preparing every worktree before dispatching anything makes the sweep take
`sum(all setup) + max(agent runtime)`, with every agent slot idle for the whole setup
phase. One slow clone is enough for that to hurt: a large repository taking minutes to
clone has held up the tail of a roster while eight agent slots sat empty.

Prepare one, dispatch it, prepare the next, dispatch it — a single serial stream of
`pr-workspace.sh` calls feeding a dispatch pool that runs up to 8 agents at once. Do not
wait for the roster to finish preparing.

What must stay serial is only the `pr-workspace.sh` calls themselves, which is what
Step 4 already requires. You do **not** need to hold a repository's second PR until its
first PR's agent finishes: separate worktrees cut from one clone share an object store
that git locks for exactly this, and a 32-PR sweep exercised it throughout without
incident. Serialising on agents instead would collapse a single-repo stretch of the
roster to one agent at a time, which is worse than the problem.

## Step 5 — Dispatch

One `babysitter:🍼` agent per PR, `model: "haiku"`, concurrently — but at most 8 in
flight at once, so a large org does not stampede the GitHub API or the machine.

Each prompt must carry: the worktree path, `repo`, `number`, `url`, `head_ref`,
`base_ref`, the `## Per-repo notes` line for that repository if `learnings.md` had one,
and the specific blockers from Step 3 with their details — the failing check names, and
the unresolved review threads.

**How you pass the threads depends on how many there are.** Fetch the count first:

```bash
gh api "repos/<repo>/pulls/<number>/comments" \
  --jq '[.[] | select((.body | startswith("[babysitter]")) | not)
        | {id, user: .user.login, path, line, body}]'
```

Filter out `[babysitter]`-prefixed comments — those are the plugin's own replies, and
feeding them back produces an agent answering itself.

- **Roughly 5 threads or fewer, and short** — paste them into the prompt. It saves the
  agent a round-trip and costs you little.
- **More than that, or long ones** — pass the *count* and the command above, and tell
  the agent to run it itself. A heavily-reviewed PR can carry 36 threads and 40KB+ of
  comment JSON; putting that in the prompt duplicates the whole payload into your
  context and the agent's for no gain, when the agent has `gh` and can fetch and filter
  it in one call.

Tell the agent to follow its own instructions and return the JSON schema they define.

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

For everything else — a design decision, an ambiguous review comment, two incompatible
sides of a conflict, a check whose failure the agent could not explain — re-dispatch
**that PR once** at `model: "sonnet"`, passing the haiku agent's `blocked_on` and
`notes` verbatim so it starts where the first attempt stopped.

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

Step 6 applies to re-dispatches too — push retry first, then at most one
escalation per event batch, then report.

Send a PushNotification for anything the user would act on now — a PR still blocked
after escalation, or a repeated `ERROR`. Routine green checks are not that.

## Step 9 — Stop

When the user stops the watch, or on `END`:

1. TaskStop the monitor if it is still running.
2. Print a summary: PRs handled, pushes made, still blocked and why.
3. Leave the worktrees in place — they are the cache for the next run. Remove them only
   if the user asks: `pr-workspace.sh --repo <repo> --pr <n> --remove`
4. Distil the run into `learnings.md` — see *Distilling the run into
   learnings* below.
5. Append one audit line:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh \
  --plugin babysitter --command /babysitter:org --scope user \
  --exit-status <completed|partial|blocked|failed|cancelled> \
  --duration-ms <ms since the sweep started> \
  --notes "<org>: <n> PRs, <p> pushed, <b> still blocked"
```

Scope is `user`, not `project`: a sweep spans many repositories, so pinning it to
whichever one the session happened to start in would mislabel the record.

## Distilling the run into learnings

Read today's ledger under `~/.claude/babysitter/run-notes/` — every `run-note.sh` call
printed its path — together with the `learnings` array from every agent that returned
one. Those two sources are the run's raw material; `learnings.md` is the digest kept
from it.

If both are empty, write nothing and say nothing. A run that hit no wall taught you
nothing, and a run-log entry saying so costs a real one its place in the window the
pruning rule below keeps.

Append to `~/.claude/babysitter/learnings.md`, creating it with this skeleton if it is
missing:

```markdown
# babysitter learnings

## Active rules

## Per-repo notes

## Run log
```

The new entry goes at the top of `## Run log`, newest first:

```markdown
### <YYYY-MM-DD> — /babysitter:org <org>

**Outcome:** <n eligible, p pushed, b still blocked, e escalated>
**Worked** — <what to keep doing>
**Cost time or needed a human** — <what to change, and where in the runbook>
**Environment** — <credentials, TLS, signing, network: what a future run will hit again>
```

Then promote and prune in the same write — an unread log tunes nothing, and only these
two sections are read back at Step 0:

- Something that has now appeared in **two** run entries becomes an **Active rule**: one
  imperative line saying what to do next time, not a retelling of what happened. Cap the
  section at 10 bullets. To add an eleventh, drop whichever rule has gone longest
  without being relevant.
- A `repo`-kind note becomes a `## Per-repo notes` line keyed by `owner/repo`, merged
  into the line already there rather than added beside it.
- Past roughly 10 run entries, fold the oldest into those two sections and delete it. The
  ledgers under `run-notes/` keep the long form; this file is the digest.

Report it in one line and move on:

```
Learnings: <n> notes → <r> new rules, <p> repo notes · ~/.claude/babysitter/learnings.md
```

Do not ask the operator to confirm each candidate. A sweep is long and frequently
unattended, and this is a working note in plain markdown they can edit or delete — not a
commitment that needs a gate.

This command does not edit its own body from the log. `/learn`, run from a
claude-plugins checkout, is what periodically turns recurring entries into a proposed,
operator-gated change to the plugin — the `process` and `policy` kinds are the ones that
usually belong there rather than in an Active rule.
