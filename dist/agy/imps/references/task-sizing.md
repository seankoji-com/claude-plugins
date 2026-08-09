# Task-sizing heuristic

Shared by the planner (`commands/imps.md` Step 1) and the Head Imp's plan-review
checklist (`agents/head-imp.md`) — cite this file from both instead of restating it.

**One task = one output artifact.** Draw the boundary at non-overlapping *concerns*, not
at features — parallel tasks run in isolated worktrees, so two tasks touching the same
file collide at merge time even when they're conceptually related.

- **Good scope:** "add HMAC-SHA256 signature validation to the auth middleware" — one
  bounded concern, one file area.
- **Bad scope:** "rebuild the authentication system" — several independent concerns
  (routing, hashing, session storage, tests) that belong in separate tasks.

Applied by the planner when decomposing work into the task table, and by the Head Imp
when reviewing a plan artifact (`GOAL.md`) before it's committed to: any task that fails
this test is a `[major]` "wrong boundaries" finding under the Technical Architect persona.
