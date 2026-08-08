<!-- Antigravity (agy) overrides for /prs. -->
<!-- The Claude source reads state written by a Workflow script and spawns registered -->
<!-- Claude agent types by model alias. Neither exists here, so the framing section, the -->
<!-- dispatch section and the three fixer sub-steps are replaced. Platform facts come -->
<!-- from docs/platform-matrix.md. Nothing here measures a platform. -->

<!-- REPLACE-SECTION: # /imps:prs — proactive PR monitor -->
# /prs — proactive PR monitor

**Before executing any steps**, output the following intro block so the user knows
what's happening:

> 🦇 **/prs** — keeping your PR clean automatically
>
> Watching the open PR from your imps run and addressing review comments, CI failures,
> and merge conflicts as they appear. Fix commits are pushed directly to the PR branch
> without manual intervention. Self-terminates when the PR is merged or closed.

---

This command is a self-pacing monitor. It reads the PR state written by the finalize
step of `/imps` (`<slug>.prs.json`), inspects the open PR, dispatches fixing runs as
needed, and reschedules itself. It is invoked by `/imps` after a successful push and
self-terminates when done.

(On Claude Code that state file is written by the run's background Workflow script; the
file and its schema are identical either way.)

**Autonomous push scope:** this command pushes fix commits to the PR branch without
asking. It does NOT touch the default branch. If it cannot fix an issue confidently, it
flags it to the user instead of guessing.
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Step 4 — Dispatch fixing agents -->
## Step 4 — Dispatch fixing runs

Dispatch the needed fixes **one at a time** — there is no parallel agent primitive on
this platform, and no registered agent type to name. Each fix is one ordinary
dispatched run at the `standard` tier, resolved to a model id and passed as `agy -p --model <id>` at
invocation, never in frontmatter (matrix Item 8 records that `agy -p` takes `--model` at the call site; no per-skill model field is established for this platform).

Fixing runs work on the PR branch — they must fetch it fresh in their own worktree and
push via `git push origin HEAD:<branch>` (never `git checkout <branch>` directly, as
that branch may already be checked out elsewhere).

(On Claude Code these are concurrent `imps:🦇` agent-type spawns.)
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ### 4a — Resolve merge conflict -->
### 4a — Resolve merge conflict

Dispatch one `standard`-tier run, with this prompt:

```
PR #<pr_number> (<pr_url>) has a merge conflict between branch "<branch>" and base "<base_branch>".
Repo: <repo>.

Steps:
1. git fetch origin <base_branch> <branch>
2. git checkout -b pr-conflict-fix origin/<branch>
3. git merge origin/<base_branch>   # conflicts expected
4. Resolve conflicts: prefer the PR branch's intent. Keep both sides when unsure; add a
   TODO comment only if the resolution is genuinely ambiguous.
5. git add -A && git commit -m "chore: resolve merge conflicts with <base_branch>"
6. git push origin HEAD:<branch>

Return JSON: { "resolved": true|false, "conflict_files": [...], "pushed": true|false,
               "reason": "<if resolved=false, why>" }
```

After the agent returns: if `resolved == false`, print:
`⚠ Merge conflict on PR #<N> needs human attention: <reason>`
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ### 4b — Fix CI failure -->
### 4b — Fix CI failure

For each failing check with `ci_fix_attempts[name] < 2`:

Fetch failure logs:
```bash
RUN_ID=$(gh run list --repo <repo> --branch <branch> --json databaseId --jq '.[0].databaseId' 2>/dev/null)
[ -n "$RUN_ID" ] && gh run view "$RUN_ID" --log-failed --repo <repo> 2>/dev/null | head -150
```

If logs are empty or unavailable, increment `ci_fix_attempts[name]` and print:
`⚠ CI fix skipped — could not fetch logs for "<name>" on PR #<N>`.

Otherwise dispatch one `standard`-tier run per failing check, with this prompt:

```
PR #<pr_number> (<pr_url>) has a failing CI check: "<check_name>".
Branch: <branch>. Repo: <repo>.

Failure logs:
<logs — truncated to 150 lines>

Steps:
1. git fetch origin <branch>
2. git checkout -b ci-fix-<check_name_slug> origin/<branch>
3. Diagnose the root cause from the logs. Make the minimal fix.
4. Do NOT change test assertions to match broken behaviour — fix the actual bug.
5. If the failure is infrastructure / flaky (not your code), return { "fixed": false,
   "reason": "flaky/infra: <detail>" } without pushing anything.
6. git add -A && git commit -m "fix(ci): <short description>"
7. git push origin HEAD:<branch>

Return JSON: { "fixed": true|false, "reason": "...", "pushed": true|false }
```

After each agent returns:
- Increment `ci_fix_attempts[name]` in the state file regardless of outcome.
- If `fixed == false`: print `⚠ CI fix needed on PR #<N> (<name>): <reason>`
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ### 4c — Address review comment -->
### 4c — Address review comment

For each unhandled comment, dispatch one `standard`-tier run, with this prompt:

```
PR #<pr_number> (<pr_url>) has a review comment to address.
Branch: <branch>. Repo: <repo>.

Comment #<id> by @<user> on <path> line <line>:
<body>

Steps:
1. git fetch origin <branch>
2. git checkout -b review-fix-<id> origin/<branch>
3. Read <path> at the relevant line and understand what the reviewer is asking.
4. If the request is ambiguous, requires architectural decisions, or is outside the scope
   of this PR, return { "addressed": false, "reason": "<why>" } without pushing.
5. Otherwise make the minimal change and commit:
   git add -A && git commit -m "fix: address review comment from @<user>"
6. git push origin HEAD:<branch>
7. Reply to the comment using mcp__github__add_reply_to_pull_request_comment with a
   one-line confirmation prefixed with the `[imps-fix]` marker (e.g. "[imps-fix] Done —
   <what changed>") — the marker is what keeps this reply from being picked up as a fresh
   unhandled comment on the next poll (see Step 4d's filter above).

Return JSON: { "addressed": true|false, "reason": "...", "pushed": true|false }
```

After each agent returns:
- If `addressed == true`: add `id` to `handled_comment_ids` in the state file.
- If `addressed == false`: print `⚠ Review comment on PR #<N> needs human attention
  (@<user>): <reason>`

---
<!-- END-SECTION -->
