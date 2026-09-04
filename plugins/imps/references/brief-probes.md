# Probe bank — refining a vague imps brief

Read by `/imps:imps` Phase 1 when the triage test finds a brief too thin to decompose.
**This is a bank to draw from, not a checklist to read out.** Ask a few at a time, follow
the answers, skip what is already settled.

The goal is not to collect the requirements the operator already has — it is to find the
ones they have not thought of. A brief that survives this phase is one a stranger could
decompose into parallel work units without asking a follow-up question.

## What this phase is actually protecting against

Imps run in isolated worktrees and cannot see each other. Anything that has to hold
*across* tasks has exactly one place to live — GOAL.md's `## Global Constraints` — and it
gets there only if it surfaces here. When it does not, the observed failure is not a
crash: it is two imps shipping mutually contradictory implementations of the same
contract, each internally consistent, each passing its own gates.

So weight the interrogation toward what independent agents cannot discover for
themselves. Where a fact is discoverable — which file holds X, what the test command is,
what the default branch is — that is the agent's job, not the operator's: dispatch a
`scout` (haiku) or `Explore` subagent and put the answer in the record. Never spend an
operator's turn on something a grep would answer.

---

## What exists now

- Which files and components does this touch? Real paths, not descriptions.
- What does the current behaviour actually do — including the parts that are wrong but
  load-bearing?
- Which existing code should this match in style and structure? Where is the exemplar?
- Is there an audit, forage fingerprint, or issue this came from? If so, which specific
  gap does it claim exists — and has anyone checked it is still missing? (Twice now a
  "missing capability" turned out to already exist in full, and the plan dispatched imps
  to rebuild it.)

## The change

- What is the smallest version of this that would count as done? Push back on scope that
  arrived by association rather than need.
- What is explicitly *out* of scope?
- Is there a version where the right move is to delete something instead of adding?
- Does this split cleanly by file ownership, or would two agents end up editing the same
  file? (The answer shapes the task table more than any other single fact.)

## Cross-task invariants — the section imps exists to fill

- If two agents implement different parts of this independently, what must both get
  right for the results to fit together? Name the exact values: field names spelled out,
  the exact env vars, the exact function signature.
- Is there a contract, schema, API shape, or naming convention more than one task will
  touch?
- Which files must the change *not* touch?
- Is there a rule here a reviewer could return a verdict against from a diff alone? If
  nothing in a diff could ever falsify it, it is background, not a constraint — and it
  belongs nowhere.
- Where a gate script already enforces a rule, name the gate command rather than
  restating its threshold. A constraint that hardcodes a count the script owns will drift
  from it, and the drift is unfixable by any imp: the divergence is in the governing
  text, not the code.

## Blast radius

- What depends on the current behaviour — callers, consumers, stored data, other repos?
- What breaks if this is subtly wrong rather than obviously wrong?
- Does any persisted data change shape? Is there a migration, and is it reversible?
- Does anything here touch a production system? (If so, that task pauses for
  confirmation before it runs.)

## Access and external systems

- What data sources, APIs, or credentials will agents need?
- Is any of it unavailable to an unattended agent — an interactive login, a device
  prompt, a VPN, a locked signing agent?
- Does any task need to *mutate* live state rather than read it? A read-only task and a
  live-mutation task are dispatched differently, and a mutation task that is not marked
  as one will quietly return a diagnosis instead of doing the work.

## Constraints that make the obvious approach wrong

- What is the deadline or resource constraint?
- Any performance, security, compliance, or compatibility bound the naive version
  violates?
- What has already been tried that did not work, and how did it fail?
- What is the reason this has not already been done?

## Done, checkably

Frame it this way: the operator is briefing engineers who get one shot, cannot ask
questions, and will not be there at review.

- What must be true of the diff that a reviewer can verify without running anything?
- Which command proves it? Name it.
- Does documentation move with the code? Which docs?
- What would make you reject the whole change on sight, regardless of other merits?

**Upgrade vague criteria rather than accepting them.** Every criterion becomes a
Definition-of-Done line, and each one is later graded against the merged diff — a
criterion no diff could confirm comes back `unverifiable` and proves nothing.

> **Vague (reject):** "Add tests."
> **Checkable (accept):** "`bash tests/run.sh` passes and covers each error branch in
> `gate` — missing artifact, bad slug, absent topic. A change that only tests the happy
> path is an auto-reject."

## Prior art — after the problem is mapped, not before

- Is there an existing internal pattern for this? Where?
- What did the last person who touched this area learn the hard way?

Front-loading these narrows the interrogation to ground the operator has already
covered, which is the opposite of the point.
