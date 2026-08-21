---
name: thinking-spec
description: >
  Use when discovery.md exists for a topic and the user wants to define
  how the eventual output will be judged. Trigger phrases include "let's build the rubric",
  "define the acceptance criteria for X", "how will we know the output on X is good", "thinking
  spec". Do NOT use this skill if discovery.md is missing for the topic — direct the user to
  thinking-discover first.
metadata:
  version: "1.0.0"
---

# Thinking: Spec Phase

Step 2 of Rensin's three-step process. The output is a grading rubric a stranger could apply,
not a wishlist.

## Step 1: Resolve topic and load context

List `thinking/` and confirm the slug against what is actually on disk — even if the topic was
just discussed in this chat. Read `thinking/<topic-slug>/discovery.md` in full and
`meta.json` for the output type. If discovery.md does not exist, stop:

> "There's no brief saved for this topic yet, and the rubric has to be built against one —
> otherwise we'd be defining pass/fail for work we haven't scoped. Say 'help me think through
> <topic>' and we'll build the brief first."

## Step 2: Announce the mode shift with the one-shot framing

This framing device is what forces criteria to become concrete. Use it near-verbatim:

> "New role for this part. Imagine you're about to hand this brief to someone you've never
> worked with. They get exactly one shot, and you don't get to answer follow-up questions. I'm
> going to play the skeptic who has to judge their finished work cold — and press you on what
> would need to be true for you to actually trust it."

## Step 3: Interview for checkable criteria

Draw from the Phase 2 section of the probe bank for this output type —
`templates/probes.research.md` or `templates/probes.implementation.md` in this plugin.

Refuse vague answers. Every criterion must be checkable cold as pass/fail. When the user gives
a vague one, show the upgrade rather than arguing:

- Vague (reject): "Cite reputable sources."
- Checkable (accept): "Every factual claim that influences the recommendation cites at least
  one primary source — manufacturer spec sheet, government dataset, or peer-reviewed study —
  with a working URL. Blog posts and forums may add colour but cannot be the sole support for
  any claim."

## Step 4: Write spec.md

Follow `templates/spec.skeleton.md`: pass/fail criteria, auto-reject conditions, quality bar,
grading notes. Save to `thinking/<topic-slug>/spec.md`.

## Step 5: Build the plan

`handoff.md` is the output of this whole process — the plan. Concatenate, using the matching
`templates/handoff.<output_type>.md` as the wrapper, substituting the title, slug, timestamp,
and the **full verbatim text** of discovery.md and spec.md. Do not summarise either one; the
fresh session downstream has nothing else to go on.

Save to `thinking/<topic-slug>/handoff.md`.

## Step 6: Stop — do not run step 3

State plainly that you are not going to produce the deliverable in this conversation, and why:
the whole point is that a session with no memory of this negotiation produces better work than
the one that argued its way to the brief.

Offer the paths:

1. **Fresh chat (recommended).** Paste `thinking/<topic-slug>/handoff.md` as the first message
   of a new conversation. Pasting the finished plan is not contamination — it is exactly what a
   reader would take off disk; what a new chat never sees is the back-and-forth that produced
   it, which is the point.
2. **`/imps:imps`** (Claude Code, implementation topics only) — the ready-to-run command line
   is at the top of `handoff.md`.
