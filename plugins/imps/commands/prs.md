---
name: imps:prs
description: >
  Proactive PR monitor for /imps:imps runs. Polls the main-branch PR for review comments,
  CI failures, and merge conflicts, then spawns agents to fix them automatically.
  Self-reschedules via ScheduleWakeup; stops when the PR is merged, closed, or 48 h old.
disable-model-invocation: true
---

# /imps:prs — proactive PR monitor

**Before executing any steps**, output the following intro block so the user knows what's happening:

> 🦇 **imps:prs** — keeping your PR clean automatically
>
> Watching the open PR from your imps run and addressing review comments, CI failures, and
> merge conflicts as they appear. Fix commits are pushed directly to the PR branch without
> manual intervention. Self-terminates when the PR is merged or closed.

---

This command is a self-pacing monitor. It reads the PR state written by the Workflow script at finalize (`<slug>.prs.json`),
inspects the open PR, dispatches fixing agents as needed, and reschedules itself.
It is invoked by `/imps:imps` after a successful push and self-terminates when done.

**Autonomous push scope:** this command pushes fix commits to the PR branch without
asking. It does NOT touch the main/master branch. If it cannot fix an issue confidently,
it flags it to the user instead of guessing.

---

## Step 1 — Check for state file

```bash
ls ~/.claude/imps/runs/*.prs.json 2>/dev/null || true
```

If no `.prs.json` files exist:
```
f  no tracked PRs — stopping PR monitor
```
Do **not** call `ScheduleWakeup`. Return immediately.

---

## Step 2 — Read state and check lifetime

For each `.prs.json` file found, read:
`repo`, `pr_number`, `pr_url`, `branch`, `base_branch`,
`poll_interval_seconds`, `started_at`, `handled_comment_ids`,
`ci_fix_attempts`, `max_age_hours`.

**Lifetime check:** compute age in hours:
```bash
python3 -c "
from datetime import datetime, timezone
started = datetime.fromisoformat('<started_at>'.replace('Z','+00:00'))
age_h = (datetime.now(timezone.utc) - started).total_seconds() / 3600
print(f'{age_h:.1f}')
"
```
If `age_h >= max_age_hours`:
- Print: `⚠ PR #<N> monitor expired after <max_age_hours>h — stopping. Check the PR manually: <pr_url>`
- Delete the `.prs.json` file.
- Do not reschedule (proceed to Step 6 to check remaining files).

---

## Step 3 — Fetch current PR state

Load the GitHub PR read tool if not already loaded:
```
ToolSearch: "select:mcp__github__pull_request_read"
```

Call `mcp__github__pull_request_read` with:
- `owner`: the owner part of `repo` (e.g. `"your-org"` from `"your-org/my-app"`)
- `repo`: the name part (e.g. `"my-app"`)
- `pullNumber`: `pr_number`

From the response, determine:

**a. PR lifecycle:**
- `state == "closed"` or `merged == true` → PR is done; print
  `  ✓ PR #<N> merged/closed — monitor complete` and delete the state file.
- `draft == true` → skip all fixes this tick (draft PRs aren't ready for review);
  go to Step 6.

**b. Merge conflict:** `mergeable == "CONFLICTING"` → needs conflict resolution (Step 4a).

**c. CI failures:**
```bash
gh pr checks <pr_number> --repo <repo> --json name,state,conclusion,detailsUrl 2>/dev/null
```
Parse JSON. Collect checks where `conclusion` is `"failure"`, `"error"`, or `"timed_out"`.
For each failing check, look up `ci_fix_attempts[<name>]` (default 0). If attempts < 2,
this check needs a fix (Step 4b). If attempts >= 2, flag it:
`⚠ PR #<N>: CI check "<name>" failed after 2 fix attempts — needs human attention`.

**d. Review comments:**
```bash
gh api repos/<repo>/pulls/<pr_number>/comments \
  --jq '[.[] | {id: .id, body: .body, path: .path, line: .line, user: (.user.login)}]'
```
Filter for comments whose `id` is NOT in `handled_comment_ids` and whose `body` does NOT
begin with `[Persona:` (the panel's own comments), `[imps-status]` (the orchestrator's own
handoff/status comments, e.g. issue-mode's Phase 6 final PR comment), or `[imps-fix]`
(this command's own confirmation replies from Step 4c below) — skipping all three markers
is what avoids self-review loops. Note that Step 4c's confirmation is a *reply* to the
original comment, which gets its own `id` distinct from the one added to
`handled_comment_ids` — without the `[imps-fix]` marker, every confirmation reply would
itself show up as a fresh unhandled comment on the next poll and get "handled" again,
forever. **Do not filter by author identity:** this plugin assumes a single `gh` identity
opens the PR *and* leaves review feedback, so filtering out the PR author would hide a
solo maintainer's own comments (the normal case). Each remaining unhandled comment needs a
response (Step 4c).

---

## Step 4 — Dispatch fixing agents

Dispatch all needed fixes concurrently using the `Agent` tool (not Workflow).
Each agent uses the `imps:🦇` agent type — the bare `imp` name is unregistered and the
spawn will fail. Fixing agents work on the PR branch — they must
fetch it fresh in their worktree and push via `git push origin HEAD:<branch>` (never
`git checkout <branch>` directly, as that branch may already be checked out elsewhere).

### 4a — Resolve merge conflict

Spawn one `imps:🦇` agent, model `sonnet`, with this prompt:

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

### 4b — Fix CI failure

For each failing check with `ci_fix_attempts[name] < 2`:

Fetch failure logs:
```bash
RUN_ID=$(gh run list --repo <repo> --branch <branch> --json databaseId --jq '.[0].databaseId' 2>/dev/null)
[ -n "$RUN_ID" ] && gh run view "$RUN_ID" --log-failed --repo <repo> 2>/dev/null | head -150
```

If logs are empty or unavailable, increment `ci_fix_attempts[name]` and print:
`⚠ CI fix skipped — could not fetch logs for "<name>" on PR #<N>`.

Otherwise spawn one `imps:🦇` agent per failing check, model `sonnet`, with this prompt:

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

### 4c — Address review comment

For each unhandled comment, spawn one `imps:🦇` agent, model `sonnet`, with this prompt:

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

## Step 5 — Write updated state

Write the updated `.prs.json` back with the new values of:
`handled_comment_ids`, `ci_fix_attempts`.

---

## Step 6 — Reschedule or stop

```bash
ls ~/.claude/imps/runs/*.prs.json 2>/dev/null || true
```

If no files remain: print `f  all PRs resolved — stopping PR monitor` and return WITHOUT
calling `ScheduleWakeup`.

Otherwise, read `poll_interval_seconds` from the remaining files (use the minimum).
Call `ScheduleWakeup` with:
- `delaySeconds`: `<poll_interval_seconds>`
- `prompt`: `/imps:prs`
- `reason`: `imps PR monitor — PR #<N> still open`
