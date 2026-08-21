---
description: >
  Steps 1 and 2 of Rensin's three-step process — interrogate the problem until it's properly
  mapped, then build a rubric a stranger could grade against — and emit `handoff.md`, the
  ready-to-paste input for step 3. Deliberately does not run step 3.
argument-hint: '[<topic-slug> | list]'
model: opus
allowed-tools: Bash(python3:*), Bash(bash:*), Bash(git:*), Bash(gh:*), Bash(ls:*), Bash(mkdir:*), Bash(date:*), Read, Write, Edit, Glob, Grep, Task, AskUserQuestion
---

# /elephant-goldfish:thinking

**Before executing any steps**, output:

> 🐘 **elephant-goldfish** — thinking before building
>
> Two guided conversations: first I interrogate the problem, then we define how the eventual
> output gets judged. You end each one when you're ready. The result is the plan —
> `handoff.md`, self-contained, ready to paste into a *fresh* session to do the actual work.
>
> I won't do that work here. Keeping it separate is the point.

## Why this command pins `model: opus`

It's the only command in this marketplace that does. Everything here is judgment work: the
value is entirely in the quality of the questions and the willingness to disagree with the
user. The failure modes this is guarding against are specific — accepting a first answer
instead of pushing on it, asking questions whose answers the user already had, softening a
disagreement into "it depends", and running out of angles after two rounds. A capable model
is the best lever available on all four.

This is a default, not a hard requirement. Nothing in the pipeline depends on it: the
structural rules in Step 2 do most of the work and help any model. If Opus access is
rate-limited or you'd rather not spend it here, delete the `model:` line from this file's
frontmatter and the command inherits the session model.

---

## What this implements

Part 1 of [Rensin's article](https://drensin.medium.com/elephants-goldfish-and-the-new-golden-age-of-software-engineering-c33641a48874):

| Article step | Here | Artifact |
|---|---|---|
| 1 — "Victory loves preparation" | Phase 1 interrogation | `discovery.md` |
| 2 — "Trust but verify" | Phase 2 rubric interview | `spec.md` |
| 3 — "Profit" | **not run** — only its input is produced | `handoff.md` |

Step 3 stays out of scope on purpose. The author's claim is that a fresh session with no
memory of the negotiation produces better work than the session that argued its way to the
brief, and a command that helpfully ran step 3 at the end would destroy exactly the property
it spent an hour building.

Everything lands in `thinking/<topic-slug>/`. `handoff.md` is the output — the plan.

---

## Step 0 — Load rules, then resolve state

Read the `## Active rules` section from each of these that exists, and apply them throughout
(project-scoped wins on conflict):

- `$HOME/.claude/elephant-goldfish/learnings.md` — cross-project rules
- `.claude/elephant-goldfish/learnings.md` — rules for this repo

Then resolve state in **one call** rather than listing and reading files:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/thinking_state.py" list
```

- `$ARGUMENTS` empty and topics exist → show them with their phase, ask whether to continue
  one or start new.
- `$ARGUMENTS` is `list` → print the table and stop.
- `$ARGUMENTS` is a slug → `resolve` it and jump to the phase named in `next_phase`.

Record the start time — the audit entry in Step 7 needs a duration.

## Step 1 — Set up the topic

Agree a short kebab-case slug. Then settle three things with `AskUserQuestion`:

1. **Output type** — `research` (a standalone document answering a question) or
   `implementation` (a plan that becomes code). This picks the probe bank *and* the handoff
   format, so it genuinely changes the next hour; don't let it default silently.
2. **Storage** — local only, a GitHub Issue, or a GitHub Discussion.
3. **Confirm publishing, if chosen.** Say plainly which repo it will post to and that Issues
   and Discussions on a public repo are public. Getting a yes here authorizes the artifact
   posts for *this run only*.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/thinking_state.py" init <slug> \
  --output-type <research|implementation> --title "<title>" --github <issue|discussion|none>
```

If publishing, create the container now so the thread opens before the first artifact:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/gh_publish.py" ensure <slug> --mode <issue|discussion>
```

Exit 2 means no `gh` or no repo — say so, fall back to local-only, and carry on. A publishing
gap must never cost the user their interrogation.

## Step 2 — Phase 1: interrogate (article step 1)

Read the probe bank for this output type — **only** the one that applies:

- `${CLAUDE_PLUGIN_ROOT}/templates/probes.research.md`
- `${CLAUDE_PLUGIN_ROOT}/templates/probes.implementation.md`

Announce the mode shift first, in plain language. Three things every announcement in this
command must contain: what's about to happen, a one-sentence why, and what the user controls.
Never use internal vocabulary — no "artifact", "phase gate", "probe bank", "goldfish".

> "For the next stretch my job is to ask questions and push on your thinking, not to give you
> answers yet — we're mapping this properly before anyone tries to solve it. Expect fifteen or
> twenty minutes. You decide when we're done; just say stop.
>
> And if I start agreeing with everything you say, call it out — say 'you're not helping' and
> I'll get back to pushing."

Then interrogate. **Structural rules — these are constraints, not aspirations**, because
self-monitoring for agreeableness doesn't work:

- Questions a few at a time. Never a giant checklist. A user who feels handed a form gives
  you the answers they already had; this phase exists for the ones they didn't.
- Work the decision frontier: ask only decisions whose prerequisites are settled. Discoverable
  facts are your job, not the user's — resolve them from the repo, tools, or primary sources.
  If an answer lives with an external stakeholder, record the owner and the downstream decision
  it blocks instead of asking the user to guess. Continue with other unblocked decisions.
- Never open a reply with praise. Open with substance.
- Asked "what do you think?", take a position with reasoning. "It depends" without a lean is
  a non-answer.
- At least once per major theme, argue the opposite of the user's stated preference and make
  them defend it.
- If the user invokes the callout, drop the thread and challenge the most load-bearing
  assumption still standing.
- Ask prior art *late*, once the problem is mapped. Front-loading what they already know
  narrows the interrogation to ground they've already covered.
- For `implementation`, ground questions in the repo. Delegate mechanical recon — where does
  X live, what's the test command — to a cheap read-only subagent so findings arrive without
  file dumps landing in this conversation. Use whichever this environment actually provides:
  a haiku `scout` if one is defined, otherwise `Explore`, otherwise just read the files
  yourself. This plugin deliberately registers no agents of its own, because shipping a
  generic name like `scout` would collide with the one many setups already define — so treat
  the delegation as an optimisation, never a dependency.

Continue until the user explicitly stops. Do not stop at a question count.

## Step 3 — Write and publish `discovery.md`

Synthesise, don't transcribe. Follow `${CLAUDE_PLUGIN_ROOT}/templates/discovery.skeleton.md`
exactly — every section, in order. Section 4 (alternatives ruled out, with reasons) is
mandatory and is the single most valuable thing in the file: it answers "why did we choose
this?" for whoever arrives later, and it's the guardrail that stops step 3 from confidently
re-proposing something already rejected.

Write to `thinking/<slug>/discovery.md`, then publish if enabled:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/gh_publish.py" post <slug> discovery.md
```

## Step 4 — Phase 2: build the rubric (article step 2)

Same probe bank, Phase 2 section. Announce the shift with the one-shot framing near-verbatim —
this device is what forces criteria to become concrete, so don't paraphrase it away:

> "New role for this part. Imagine you're handing this brief to someone you've never worked
> with. They get exactly one shot, and you don't get to answer follow-up questions. I'm going
> to play the skeptic who has to judge their finished work cold — and press you on what would
> need to be true for you to actually trust it."

Interview until every criterion is checkable cold as pass/fail. Refuse vague answers, and show
the upgrade rather than arguing about it — the probe bank has a worked example to reuse.

## Step 5 — Write and publish `spec.md`

Follow `${CLAUDE_PLUGIN_ROOT}/templates/spec.skeleton.md`. Then:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/gh_publish.py" post <slug> spec.md
```

## Step 6 — Render the plan

**Never write `handoff.md` yourself.** It is pure concatenation of two files already on disk;
generating it costs output-token prices to reproduce bytes that exist, and risks paraphrasing
the brief it's meant to reproduce verbatim.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/thinking_state.py" gate <slug> --require discovery,spec \
  && python3 "${CLAUDE_PLUGIN_ROOT}/scripts/render_handoff.py" <slug> \
  && python3 "${CLAUDE_PLUGIN_ROOT}/scripts/gh_publish.py" post <slug> handoff.md
```

The gate is fail-closed: a missing input stops the render rather than producing a plan with a
hole in it.

## Step 7 — Self-improvement

Ask the user what, if anything, should change about how this command runs next time — a probe
that kept missing, a section that's always empty, a framing that landed badly. Propose each
candidate rule and let them confirm before writing. Append confirmed rules under
`## Active rules` in the user- or project-scoped `learnings.md`, classifying scope yourself
(stack-agnostic → user; specific to this repo → project).

Then log one audit line — best-effort telemetry, never a gate:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh" --plugin elephant-goldfish \
  --command /elephant-goldfish:thinking --exit-status "${AUDIT_STATUS:-completed}" \
  --duration-ms <ms> --notes "<slug>: <output_type>, <n> artifacts"
```

## Step 8 — Hand off

Show the user where everything landed, and give them the next command verbatim. For
`implementation`, that's the `/imps:imps` line at the top of `handoff.md`. For `research`,
it's: open a fresh session and paste `thinking/<slug>/handoff.md` as the first message.

Say explicitly that you are not going to do that work here, and why.

---

## Limitations

- **A rubric is not a guarantee.** `spec.md` constrains what step 3 is graded against; it
  cannot make step 3 competent.
- **Publishing is one-way.** Issue and Discussion comments on a public repo are public and may
  be indexed. The per-run confirmation in Step 1 is the only gate.
