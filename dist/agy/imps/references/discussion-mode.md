# Discussion-seed mode — /imps

*Read by the orchestrator only when Mode detection matched a GitHub Discussion
reference. This is not a separate phase sequence like issue-driven mode — it's a fetch
step that seeds free-text mode (Phase 0 onward) with the discussion's content, then adds
one obligation the run's finalize step fulfills.*

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
replaces `$ARGUMENTS` as the input to Phase 0's brief refinement: pass
`<DISCUSSION_TASK_SEED>` to the `prompt-builder` skill instead of raw `$ARGUMENTS`, and
skip the "What's the task?" prompt — the discussion body *is* the task description.
Continue with Phase 0 onward exactly as free-text mode does from here.

**4. Record the source.** Carry `owner`, `repo`, `number`, `id` (GraphQL node ID), and
`url` as `source_discussion` in the durable state file (Phase 2 Step 6) so a `/clear`
mid-run doesn't lose the reply target.

**5. Mandatory reply obligation.** Regardless of what Phase 1 discovery answers for
"expected output artifacts," a discussion-seeded run posts one summary comment back to
the source discussion whenever finalize is reached. **The finalize step owns this** — it
posts the outcome comment in its finalize step, and on an operator `abort` at any
gate it posts a short abort notice instead, both keyed off `source_discussion` in the
state file (see `scripts/imps-run.workflow.js`'s `finalizeRun` function). It is not a
dispatched task, and Phase 1 Q2 may still surface additional artifacts (PRs, code) on top
of it. The orchestrator never posts to the discussion itself.
