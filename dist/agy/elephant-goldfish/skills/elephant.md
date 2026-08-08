---
name: elephant
description: >
  Write or update elephant.md — a durable design doc — then cold-validate it against a
  different-lineage judge with no repo access. `check` = read-only factual drift pass
  instead of the judge. Anything else = a goldfish's failure report to fold in.
---

# /elephant

**Before executing any steps**, output:

> 🐘 **elephant-goldfish** — keeping your design doc honest
>
> Writes or updates `elephant.md`, then cold-reads it with a different-lineage model that
> has no repo access. A PASS means the doc is *plausible enough to bootstrap from* — not
> that every claim in it is true. See **Limitations** below before trusting one.

## What this does

1. **Write** — draft or revise `elephant.md` at the repo root. Structure it as: **The
   Problem** (why this exists), **The Technical Plan** (components + how they relate, each
   citing the path that owns it), **Alternatives** (considered and rejected, with
   reasoning — preserve existing human rationale verbatim, mark superseded items rather
   than deleting them), **Detailed Implementation** (file map, build/test/run commands).
   Ground every concrete claim in a real `path`/`path:line`; mark anything unconfirmed as
   `_(inferred — confirm)_` instead of asserting it.
2. **Judge** — run the doc past `scripts/goldfish-judge.sh`, a cold reader with the doc
   inlined into its prompt and NO other access to this repo. It prints `VERDICT: READY` or
   `VERDICT: NOT READY` plus a numbered list of bootstrap gaps.
3. **Iterate** — on NOT READY, patch exactly the named gaps in place (don't rewrite
   unrelated sections) and re-judge the whole doc. Stop after 5 rounds without a PASS and
   report to the user rather than looping forever.

If `$ARGUMENTS` is a goldfish failure report (pasted back from a prior run's output), skip
straight to patching those gaps — don't rewrite the whole doc.

## Running the judge

```bash
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-pro}" OLLAMA_MODEL="${OLLAMA_MODEL:-}" \
  bash "__PLUGIN_ROOT__/scripts/goldfish-judge.sh" elephant.md; RC=$?
```

- `RC=0` → READY. Remind the user to commit `elephant.md` — it's a first-class deliverable
  alongside the code, not a generated artefact to gitignore.
- `RC=10` → NOT READY. stdout is the failure report — patch those gaps (**Iterate** above).
- `RC=2` → judge error (no usable verdict, or the configured CLI is missing). Stop and
  report to the user — never treat this as a pass or loop on it.

## Fact-check mode (`check`)

`$ARGUMENTS == check`: run a read-only pass that (a) verifies every `path`/`path:line`
citation in `elephant.md` against what that file actually contains, and (b) spot-checks
`git ls-files` for major additions the doc never mentions.

On Claude Code this spawns a cheap `model: haiku` subagent. No per-skill model field is
recorded for this platform in `docs/platform-matrix.md`, so none is emitted — pick the model
at invocation with `--model <name>` (matrix Item 8) or run the pass inline.

Report drift as `doc says X / code does Y (path:line)` or `code has X / doc never mentions it
(path)`. **Read-only — never writes `elephant.md`.** This is the complement to the judge
above: it catches wrong-but-plausible claims the cold judge structurally cannot (see
Limitations).

## Limitations — read before trusting a PASS

- **Plausibility, not truth.** The judge reads only the doc, never the code, by design —
  if the doc omits something, a true cold reader wouldn't know it either, so giving the
  judge repo access would let the doc cheat its own gaps. But the same design means a
  confidently wrong doc can still pass: the judge has no way to catch a claim that's
  fluent, specific, and false. Use `check` (above) for factual accuracy.
- **Different lineage matters.** The judge must not be a Claude model — that would share
  this author's priors and let the loop certify its own guesses. Never point
  `GEMINI_MODEL`/`OLLAMA_MODEL` at a Claude model.
