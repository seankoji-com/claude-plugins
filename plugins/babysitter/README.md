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

A worktree with uncommitted changes from a previous run is never reset over; the script
exits 4 and tells you where to look. Worktrees are kept after a run as a warm cache, and
removed with `pr-workspace.sh --repo <r> --pr <n> --remove`.

Override the root with `BABYSITTER_HOME`.

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
| `list-prs.sh` | The only GitHub reader. `--org X`, `--repo X`, or `--repo X --pr N`. One GraphQL call, one JSON object per line, open PRs only. Exit 2 bad arguments, 3 query failed. Warns on stderr when a sweep is truncated by `--limit` (GitHub caps a search page at 100 and it does not paginate). |
| `pr-events.sh` | Monitor event stream. Forwards unknown flags to `list-prs.sh` so the watch and the sweep can never disagree about scope. |
| `pr-workspace.sh` | Cache clone + per-PR worktree. Prints the path on stdout, progress on stderr. Exit 3 git failure, 4 dirty worktree left alone. |
| `ocr-gate.sh` | Pre-push review. Prints one summary line. Exit 0 clean/skipped, 1 findings, 2 could not review. |
| `audit-log.sh` | Shared appender for `~/.claude/audit.jsonl`; identical in every plugin that bundles it. |

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
