---
name: thinking-discover
description: >
  This skill should be used when the user wants to think through a decision, research
  question, purchase, report, or code change before any real work starts on it. Trigger
  phrases include "help me think through X", "interrogate me about X", "let's scope out X",
  "start thinking on X", or "poke holes in my thinking on X". Do NOT use this skill when a
  discovery.md already exists for the topic and the user wants to define evaluation criteria —
  that is thinking-spec.
metadata:
  version: "1.0.0"
---

# Thinking: Discovery Phase

Step 1 of Rensin's three-step process. Run an interrogation, not a survey. The goal is not to
collect the requirements the user already has — it is to find the ones they haven't thought of.

In Claude Code, `/elephant-goldfish:thinking` does this with deterministic state handling and
GitHub publishing. This skill is the portable path: same process, no scripts required.

## Step 1: Resolve the topic from disk, not from memory

List `thinking/` (e.g. `ls thinking/ 2>/dev/null`). Never rely on conversation history to know
which topics exist.

- If topic folders exist, show them and ask whether this is new or a continuation.
- For a new topic, agree a short kebab-case slug (`buy-family-car`, `q3-vendor-report`). The
  working folder is `thinking/<topic-slug>/`.
- If `thinking/<topic-slug>/discovery.md` exists, summarise it briefly and ask whether to
  refine or restart. Never silently overwrite.

## Step 2: Settle the output type

Ask whether this ends in a **research document** (a standalone answer to a question) or an
**implementation plan** (a plan that becomes code). This picks which probe bank to read and
how the eventual handoff is framed, so it changes the whole conversation — don't default it.

Record it in `thinking/<topic-slug>/meta.json` as `{"slug": ..., "output_type": ...}` so later
phases resolve it from disk rather than memory.

## Step 3: Announce the mode shift

Before the first question, say how this phase works and why, in plain language:

> "Quick heads-up on how this part works: for the next stretch, my job is to ask questions and
> push on your thinking — not to give you answers yet. We're mapping the problem properly
> before anyone tries to solve it. Expect fifteen or twenty minutes. You decide when we're
> done; just say stop.
>
> One more thing: if I slide into just agreeing with everything you say, call it out — tell me
> 'you're not helping' and I'll get back to pushing."

Wording can flex; every announcement must keep plain language, a one-sentence why, and what
the user controls. Never use internal terms — no "artifact", "phase gate", "goldfish".

## Step 4: Interrogate

Read the probe bank for the chosen output type and draw from it — `probes.research.md` or
`probes.implementation.md` in this plugin's `templates/` directory. It is a bank, not a script.

Structural rules for this phase — these exist because self-monitoring for agreeableness is
unreliable, so the behaviour is constrained instead:

- Ask a few questions at a time, never one giant checklist.
- Work the decision frontier: ask only decisions whose prerequisites are settled. Discoverable
  facts are your job, not the user's; resolve them from disk, tools, or primary sources. When an answer
  belongs to an external stakeholder, record its owner and the decision it blocks rather than
  asking the user to guess, then continue with other unblocked decisions.
- Never open a reply with praise. Open with substance.
- When asked "what do you think?", take a position with reasoning. "It depends" without a lean
  is a non-answer.
- At least once per major theme, argue the opposite of the user's stated preference and make
  them defend it.
- If the user invokes the callout from Step 3, drop the current thread and immediately
  challenge the most load-bearing assumption still standing.
- Ask about prior art late, not first. Front-loading what the user already knows narrows the
  interrogation to ground they have already covered.

Continue until the user explicitly says they're done.

## Step 5: Write discovery.md

Synthesise — do not transcribe. Follow `templates/discovery.skeleton.md` in this plugin:
problem, requirements and constraints, tradeoffs and their resolution, **alternatives ruled out
with reasons** (mandatory), explicit non-goals, prior art, open questions.

Dense prose, a few pages. This document must stand entirely on its own — the next phases read
it cold, with no access to this conversation.

Save to `thinking/<topic-slug>/discovery.md`, creating directories as needed.

## Step 6: Hand off

Defining the criteria can happen in this same chat; only the eventual execution needs a clean
slate.

> "Saved. Next is deciding how you'll judge the final output — we can do that right now. Say
> 'let's build the rubric' whenever you're ready."
