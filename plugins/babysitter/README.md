<!-- PLATFORM-SUPPORT: opencode=excluded agy=excluded -->

# babysitter

Open pull requests rot. A reviewer leaves a comment, the base branch moves, a check goes
red, and the PR sits there — not because the work is hard, but because nobody has picked
it back up. This plugin picks it back up.

Pick a scope: a whole org, one repository, or one PR. Each one gives every PR its own git
worktree and its own agent, clears what is blocking it, and then keeps watching so the
next comment or red check is handled when it lands rather than the next time you look.

## Commands

| Command | Scope | Ends when |
| --- | --- | --- |
| `/babysitter:org [org]` | Every eligible open PR in a GitHub org | You stop it |
| `/babysitter:repo [owner/repo]` | Every eligible open PR in one repository | You stop it |
| `/babysitter:pr <url \| owner/repo#N \| N>` | One named PR | That PR merges or closes |

Flags on all three: `--include-drafts`, `--include-forks`, `--all-authors`,
`--interval <s>`.

## New pull requests are picked up too

In `org` and `repo` mode the watch is not limited to the PRs that existed when you
started it. A PR opened afterwards shows up as a `NEW` event on the next poll and gets
the same treatment as the rest — worktree, agent, the lot. Both commands deliberately
omit `--exit-when-empty` for this reason: a scope with nothing open right now is quiet,
not finished.

New PRs go through the roster gate the same way the first batch did. The initial
confirmation approves the PRs on the table at that moment, not every PR the org or repo
will ever have.

`/babysitter:pr` is the exception, by design — it watches one PR and exits when that PR
is done.

## What it actually does to a PR

Per PR, in this order — conflicts first, because they change the code every other fix
applies to:

1. **Base drift** — merges the base branch in. Deliberately a merge, not a rebase: a
   rebase of a published branch needs a force-push, and the plugin never force-pushes.
   On a squash or rebase merge the extra commit is invisible anyway.
2. **Merge conflicts** — resolves them by reconstructing both sides' intent from their
   commits, the PR body and the surrounding code. Never by branch precedence, never with
   a `TODO` standing in for a decision. If one side's intent cannot be reconstructed, it
   aborts the merge and reports instead.
3. **Failing checks** — every failing check, not just required ones. Reads the run logs,
   reproduces locally before changing anything, fixes the root cause. Never edits a test
   to match broken behavior. Flags infrastructure failures and flakes instead of
   "fixing" them.
4. **Review comments** — from humans, from Copilot, from any bot. Each thread ends
   either fixed (with a reply saying what changed) or rejected (with a reply saying
   why). Never silently ignored, and never rejected without an argument.

Then it reviews its own diff and pushes.

### `[babysitter]` is a reserved comment prefix

Every comment the plugin posts starts with `[babysitter]`, and it skips comments carrying
that prefix in two places: when collecting threads for an agent to answer, and when
deciding which comment is the newest for change detection. Without the second one, an
agent's own reply would look like a new comment on the next poll and re-dispatch itself
forever.

The consequence is that **a comment you write starting with `[babysitter]` will be
ignored.** Start it any other way.

The filter is on the marker rather than on the comment's author on purpose. This plugin
assumes one GitHub identity both opens the PR and reviews it — the normal case for a solo
maintainer — so filtering by author would silently hide your own review comments from the
babysitter. That is the same reasoning `imps/prs.md` records for its filter.

## Which PRs it will touch

By default: **open**, **not a draft**, **head branch in the org** (not a fork), and
**authored by you or by a bot** (Copilot, dependabot, anything ending `[bot]`).

Forks are excluded because a push to a fork's branch usually fails — babysitting one
produces work that cannot land. Drafts are excluded because a draft is not asking for
this yet. Other people's PRs are excluded because pushing commits onto a colleague's
branch uninvited is rude; `--all-authors` opts in when you actually want it.

`/babysitter:pr` implies `--all-authors` — naming a PR explicitly *is* the decision about
whose branch to touch. `/babysitter:repo` is the scope where `--all-authors` is most
often the right call: babysitting one repository on a team's behalf is plausible in a way
that sweeping everyone's branches org-wide is not.

All three commands show you the full roster and wait for a yes before anything is pushed.

## Push safety

- Fix commits go to the PR's head branch only, via `git push origin HEAD:<head-ref>`.
- Never to a base or default branch.
- Never force-pushed. A non-fast-forward rejection is handled by fetching and merging,
  never by overwriting.
- The worktree checks out a local branch named `babysitter/pr-<N>`, not the PR's branch
  name, so a reflexive `git push origin <branch>` cannot target the wrong ref.
- `push.default=upstream` is set on the clone, so even a bare `git push` can only reach
  the ref the branch tracks. Under git's `current` default it would instead have created
  a stray remote branch called `babysitter/pr-<N>` and reported success — which is how
  that setting was found.

## Pre-push review

Before every push the agent runs the diff through OpenCodeReview (`ocr`) and fixes what
comes back, up to two rounds. The point is to spend a local loop instead of a reviewer's
round-trip.

`scripts/ocr-gate.sh` picks the tool: `ocr-pre-pr.sh` if you have that wrapper (it writes
the HEAD-keyed cache entry a pre-PR gate reads, so babysitter pushes and hand-made pushes
are recorded the same way), otherwise `ocr review`.

**If neither is installed the gate reports `status=skipped` and the push proceeds.** That
is deliberately fail-soft, unlike the rest of this repo: `ocr` is an optional third-party
CLI, not a bundled dependency, and hard-failing would make the plugin unusable for anyone
who has not installed it. What is not soft is the reporting — a skipped review is
reported as skipped, and the agent sets `"reviewed": false`, so no push is ever described
as reviewed when nothing reviewed it.

**If the review service is unreachable, the review still happens.** `ocr` talks to an
LLM gateway over TLS, and that call can fail for reasons that have nothing to do with
the diff — a sandbox proxy whose certificate its Go TLS stack rejects is the one seen in
the wild, and it took the gate out on nearly every push of a 32-PR sweep. So the gate
falls back to `ocr delegate`, which needs no LLM: it emits a review spec (the file list,
the refs, and the resolved rules) and the agent performs the review itself, then comes
back through the gate. Reported as `status=delegate`, exit 3.

**And if even that fails, the push does not happen.** `status=error` means the agent
returns `blocked` with its fix committed but unpushed, for the orchestrator to retry.
This is the one place the plugin is strict, because it is the place where being lax is
invisible: every agent facing a broken gate has the same reasonable-sounding argument
available — *it's a TLS error, that's infrastructure, not my code* — and if each acts on
it, a whole sweep of PRs goes out unreviewed with nothing in the record saying so. The
only status that licenses an unreviewed push is `skipped`, where the gate has positively
established there is no review tool to run.

## Model routing

Agents run on **haiku**. When one returns `blocked` — a comment that needs a design
decision, a conflict whose two sides are genuinely incompatible, a check failure it
cannot explain — the orchestrator re-dispatches that one PR once on **sonnet**, carrying
the first attempt's reasoning forward. Still blocked after that is reported to you, not
retried.

`blocked` is therefore the cheap correct answer, which is the point: a guess costs a
human a review round, an escalation costs one re-dispatch.

## The event watch

The sweep is the easy half. The watch is what keeps a PR from re-rotting.

`scripts/pr-events.sh` is handed to Claude Code's Monitor tool and polls
`scripts/list-prs.sh` on an interval (default 60s, floor 30s), diffing consecutive
snapshots. Each line is one actionable change:

```
NEW  CONFLICT  BASE-MOVED  CHECKS-FAILED  CHECKS-GREEN
REVIEW  COMMENT  THREADS  DRAFT  GONE  ERROR  END
```

The first snapshot is a silent baseline — the sweep has already handled those PRs, so
replaying them as events would double-dispatch every one. A state that has not changed
emits nothing, so the monitor is not throttled for noise. `GONE`, `ERROR` and `END` exist
because silence must never be the only signal that something ended.

`/babysitter:pr` passes `--exit-when-empty`, which is what makes it self-terminating:
when the PR merges, the script emits `GONE`, then `END`, and exits.

## Worktrees

A PR in another repository cannot be isolated by a worktree of the repo your session
started in, so the plugin manages its own. One cache clone per repository under
`~/.claude/babysitter/repos/`, one worktree per PR under `~/.claude/babysitter/worktrees/`.
Two PRs in the same repo get separate checkouts and never share an index.

The orchestrator creates these serially, not the agents — two `git worktree add` calls
racing on one clone corrupt its index.

Each run also (re)applies three settings to the clone, so an existing one gets repaired
rather than staying broken: `origin` forced to an HTTPS URL, `credential.helper` reset
to just `gh`, and `push.default=upstream`. All three exist because of push failures that
looked like three unrelated problems — an ssh-agent refusing to sign, "could not read
Username ... Device not configured", a stray remote branch — and were one clone's config
each time. Fixing it on the clone fixes every PR in that repository at once.

The credential-helper reset is worth knowing about if you read the config: it writes an
empty `credential.helper` before adding `gh`'s, because git accumulates helpers across
config scopes and an empty value is what clears the inherited ones. Without it, a macOS
`osxkeychain` helper inherited from system config runs first and hangs on a TTY that
does not exist in an agent's environment. It is scoped to this plugin's own clones under
`~/.claude/babysitter/repos/` and never touches your own checkouts.

A worktree with uncommitted changes from a previous run is never reset over; the script
exits 4 and tells you where to look. Worktrees are kept after a run as a warm cache, and
removed with `pr-workspace.sh --repo <r> --pr <n> --remove`.

Override the root with `BABYSITTER_HOME`.

## What it remembers between runs

A sweep teaches you things that a summary throws away — that a credential helper does
not work headlessly, that one repository's remote only accepts HTTPS, that the pre-push
gate failed open. The plugin writes these down, in one place, outside every repository
it touches:

| Path | What it holds |
| --- | --- |
| `~/.claude/babysitter/run-notes/<date>-<command>.md` | Raw ledger, appended as the run happens. Survives a crash or a stopped watch, which a final summary does not. |
| `~/.claude/babysitter/learnings.md` | The digest kept from those ledgers — `## Active rules`, `## Per-repo notes`, `## Run log`. |
| `~/.claude/audit.jsonl` | One structured line per run, shared across plugins in this marketplace (schema in the root [`AGENTS.md`](../../AGENTS.md)). |

`## Active rules` (capped at 10) and `## Per-repo notes` are read back at the start of
every run and applied silently; the per-repo lines are also passed into that PR's agent,
which cannot read the file itself. Dispatched agents contribute through a `learnings`
array in their return JSON, so a wall one agent hit does not cost the next one a turn to
rediscover.

Nothing here is written into the repository being babysat. A sweep spans an org and
learns about the machine, the remote, and the runbook — none of which belong in someone
else's repo, and a fix commit is not the place for a note to yourself.

There is no confirmation gate on the write: a sweep runs long and often unattended, and
these are plain markdown files you can edit or delete. Point `BABYSITTER_HOME` somewhere
else to move them.

Re-read them periodically, or run `/learn` from a claude-plugins checkout to turn
recurring entries into a proposed change to the plugin itself. `process` and `policy`
notes are usually the ones that should become plugin changes rather than run-time rules.

## Prerequisites

| | |
| --- | --- |
| `gh` | required, authenticated (`gh auth status`) |
| `jq` | required |
| `git` | required |
| `ocr` or `ocr-pre-pr.sh` | optional — without it the pre-push review is skipped and reported as skipped |

## Scripts

| Script | Contract |
| --- | --- |
| `list-prs.sh` | The only GitHub reader. `--org X`, `--repo X`, or `--repo X --pr N`. One GraphQL call (retried twice on failure — an org-wide query draws a 504 often enough to be routine), one JSON object per line, open PRs only. Exit 2 bad arguments, 3 query failed. Warns on stderr when a sweep is truncated by `--limit` (GitHub caps a search page at 100 and it does not paginate). |
| `pr-events.sh` | Monitor event stream. Forwards unknown flags to `list-prs.sh` so the watch and the sweep can never disagree about scope. |
| `pr-workspace.sh` | Cache clone + per-PR worktree. Also makes the clone pushable on every run: `origin` forced to HTTPS, credential helper pinned to `gh`, `push.default=upstream`. Prints the path on stdout, progress on stderr. Exit 3 git failure, 4 dirty worktree left alone. |
| `ocr-gate.sh` | Pre-push review, with a no-LLM `ocr delegate` fallback. Prints one summary line. Exit 0 clean/skipped, 1 findings, 2 could not review at all, 3 delegated to the agent. |
| `merge-pr.sh` | Attempts the actual `gh pr merge` equivalent once a PR is driven to "mergeable", fixing only the branch-protection blockers that need no judgment: a branch fallen `BEHIND` its base (server-side `update-branch`, no worktree needed) and a review thread already answered with a `[babysitter]` reply but never marked resolved (`resolveReviewThread` — a reply is not the same action as GitHub's own conversation-resolution flag). Every `BLOCKED` outcome also tries arming GitHub's native auto-merge (`enablePullRequestAutoMerge`) as a courtesy, so a PR blocked only on something outside this script's authority — a pending required check, a review still needed — finishes on its own once that clears, with no further call needed; reported as `automerge=armed` or `automerge=unavailable` (the repo has it turned off, or GitHub declined). Never passes `--admin`; a required human reviewer, a code-scanning alert threshold, or an org ruleset it cannot satisfy comes back as `BLOCKED ... reason=branch_protection` for a human to read, not to bypass. Prints `MERGED <repo>#<n> via <method>` or `BLOCKED <repo>#<n> reason=<category> detail=<...> automerge=<armed|unavailable>`. Exit 0 merged, 2 bad arguments, 3 query failed, 4 blocked. |
| `audit-log.sh` | Shared appender for `~/.claude/audit.jsonl`; identical in every plugin that bundles it. |
| `run-note.sh` | Appends one timestamped observation to the run's notes ledger. `--command`, `--kind env\|github\|process\|repo\|policy`, `--note`, optional `--scope`. Prints the ledger path. Fail-soft: an unwritable notes directory warns and exits 0. |

## Cross-platform

Not generated for OpenCode or Agy. The live event stream this plugin is built around has
no measured equivalent on either target, and porting it would mean inventing a polling
harness and presenting it as if it worked. The reasoning is recorded in
[`build/generation-manifest.json`](../../build/generation-manifest.json); the contract is
[`docs/plans/cross-platform-compat.md`](../../docs/plans/cross-platform-compat.md).

The shell scripts are already platform-neutral, so if the platform matrix ever gains an
event-stream primitive, only the command prose needs porting.

## License

MIT.
