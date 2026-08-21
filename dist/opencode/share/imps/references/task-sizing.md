# Task-sizing heuristic

Shared by the planner (`commands/imps.md` Step 1) and the Head Imp's plan-review
checklist (`agents/head-imp.md`) — cite this file from both instead of restating it.

**One task = one independently verifiable output.** Prefer a narrow vertical slice that
delivers observable behavior through every layer it needs; a task that edits only schema,
only implementation, or only tests leaves its own behavior unverifiable. Parallel tasks
also run in isolated worktrees, so slices need disjoint file ownership. If two useful slices
must touch the same files, make the dependency explicit or keep them as one task instead of
manufacturing a merge conflict.

- **Good scope:** "reject requests with an invalid HMAC-SHA256 signature, with a seam-level
  regression test" — one bounded behavior, independently verifiable.
- **Bad scope:** "rebuild the authentication system" — several independent concerns
  (routing, hashing, session storage, tests) that belong in separate tasks.

**Wide mechanical refactors are the exception.** When one rename or shared-type change has a
blast radius too wide for any slice to stay green, use expand–migrate–contract: add the new
form beside the old; migrate disjoint caller batches that depend on the expansion; remove the
old form only after every batch completes. Never split a behavior horizontally merely to
create more parallel rows.

Applied by the planner when decomposing work into the task table, and by the Head Imp
when reviewing a plan artifact (`GOAL.md`) before it's committed to: any task that fails
this test is a `[major]` "wrong boundaries" finding under the Technical Architect persona.
