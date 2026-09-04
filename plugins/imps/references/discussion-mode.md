# Discussion-seed mode — /imps:imps

*Read by the orchestrator only when Mode detection matched a GitHub Discussion
reference. This is not a separate phase sequence like issue-driven mode — it's a fetch
step that seeds free-text mode (Phase 1 onward) with the discussion's content, then adds
one obligation the Workflow script fulfills at finalize.*

**1. Resolve owner/repo/number.**
- Full URL → strip any `?query` or `#fragment` first, then parse `owner`, `repo`, `number`
  from the remaining path segments (a permalink like `.../discussions/284#discussioncomment-98765`
  still resolves to discussion `284`).
- Bare `discussion N` / `discussion #N` → resolve `owner/repo` from the current repo:
  `gh repo view --json nameWithOwner -q .nameWithOwner`.

**2. Fetch the discussion via GraphQL** (Discussions have no REST endpoint — this
mirrors the `publish`-type convention already used for Discussion creation in
`agents/imp.md`):

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    discussion(number:$num){
      id title body url
      category { name }
      author { login }
      comments(first:20){ nodes { body author { login } isAnswer } }
    }
  }
}' -f owner="<owner>" -f repo="<repo>" -F num=<number>
```

Extract `id` (the GraphQL node ID — required later to post a reply, keep it verbatim,
never re-derive it from the number), `title`, `body`, `url`, `category.name`, and the
comment bodies.

**3. Seed the task.** Build `<DISCUSSION_TASK_SEED>` from the title + body (+ any
comments that add requirements or constraints — skip pure "+1"/social replies). This
replaces `$ARGUMENTS` as the input to Phase 1: the discussion body *is* the task
description, so Phase 1's triage sets `<REFINED_TASK>` from `<DISCUSSION_TASK_SEED>` and
**never runs the interrogation** — compressing a whole discussion thread into a couple of
sentences before decomposition throws away the run's richest input. Phase 2's discovery
questions still run. Continue with Phase 1 onward exactly as free-text mode does.

**4. Record the source.** Carry `owner`, `repo`, `number`, `id` (GraphQL node ID), and
`url` as `source_discussion` in the durable state file (Phase 2 Step 7) so a `/clear`
mid-run doesn't lose the reply target.

**5. Mandatory reply obligation.** Regardless of what Phase 2 discovery answers for
"expected output artifacts," a discussion-seeded run posts one summary comment back to
the source discussion whenever finalize is reached. **The Workflow script owns this** — it
posts the outcome comment in its finalize step, and on an operator `abort` at any
gate it posts a short abort notice instead, both keyed off `source_discussion` in the
state file (see `scripts/imps-run.workflow.js`'s `finalizeRun` function). It is not a
dispatched task, and Phase 2 Q2 may still surface additional artifacts (PRs, code) on top
of it. The orchestrator never posts to the discussion itself.
