# Probe bank — implementation topics

**This is a bank to draw from, not a checklist to read out.** Ask a few at a time, follow the
answers, and skip anything already settled. Where the user names a file, path or command, get
it into the record verbatim — the fresh session downstream has no repo intuition and every
unstated path becomes a guess.

You may read the repo to ground your questions. Where the environment offers a cheap
read-only subagent (a haiku `scout`, or `Explore`), prefer it for mechanical recon — where
does X live, what's the test command — so the finding lands in the record without the file
dumps landing in this conversation. If neither exists, read the files directly; this is an
optimisation, not a requirement.

---

## Phase 1 — Interrogation (article step 1)

Target: a problem description precise enough that someone who has never seen this repo could
plan the change. 15–20 minutes minimum. Stop when the user says stop.

### What exists now
- Which files and components does this touch? Get real paths, not descriptions.
- What does the current behaviour actually do — including the parts that are wrong but
  load-bearing?
- Which existing code should this match in style and structure? Where's the exemplar?
- How is "it works" demonstrated today — build, test, lint, run commands?

### The change
- What's the smallest version of this that would count as done? Push back on scope that
  arrived by association rather than need.
- What's explicitly *out* of scope for this change?
- Is there a version where the right move is to delete something instead of adding?

### Blast radius
- What depends on the current behaviour — callers, consumers, stored data, other repos?
- What breaks if this is subtly wrong rather than obviously wrong?
- Does any persisted data change shape? Is there a migration, and is it reversible?
- How do you roll this back after it's shipped and something else has depended on it?

### Constraints that make the obvious approach wrong
- What's the deadline or resource constraint?
- Any performance, security, compliance or compatibility bound the naive version violates?
- What have you already tried that didn't work, and how did it fail?
- What's the reason this hasn't already been done?

### Prior art — after the problem is mapped, not before
- Is there an existing internal pattern for this? Where?
- What did the last person who touched this area learn the hard way?

---

## Phase 2 — Rubric (article step 2)

Framing: the user is briefing an engineer who gets one shot at the change, cannot ask
questions, and will not be around to explain themselves at review. Every criterion must be
checkable by a reviewer who wasn't in this conversation.

### Definition of done
- Which tests must exist and pass? Name the command that proves it.
- What must be true of the diff that a reviewer can verify without running anything?
- Which files must the change *not* touch?
- Does documentation have to move with the code? Which docs?

### Quality bar
- What separates a change that works from one you'd be happy to maintain?
- Which conventions in this repo must be matched, and where's the file that demonstrates each?
- What's the comment/readability standard for this code path?

### Auto-reject
- What fails the whole change on sight, regardless of other merits?
- Which ruled-out approaches from discovery.md must never reappear?
- Any dependency, pattern or API that is simply not allowed here?

### Upgrading vague answers
Refuse vague criteria and show the upgrade:

> **Vague (reject):** "Add tests."
> **Checkable (accept):** "`pytest tests/python/test_thinking_state.py` passes, and includes at
> least one case per error branch in `gate` — missing artifact, bad slug, absent topic. A
> change that only tests the happy path is an auto-reject."
