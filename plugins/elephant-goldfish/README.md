# elephant-goldfish

Two commands from [Rensin's article](https://drensin.medium.com/elephants-goldfish-and-the-new-golden-age-of-software-engineering-c33641a48874), covering both halves of it:

| Command | Article | What it does |
|---|---|---|
| [`/elephant-goldfish:thinking`](#elephant-goldfishthinking--think-before-building) | Part 1, steps 1–2 | Interrogates a problem, then builds a grading rubric, and emits the plan — ready to paste into a fresh session. Does not run step 3. |
| [`/elephant-goldfish:elephant`](#what-it-does) | Part 2 | Writes and cold-checks a repo's durable design document, `elephant.md`, using a different-lineage Gemini reader as the judge. |

They compose: `thinking` maps a problem before any code exists; `elephant` keeps the resulting
design honest once it does. Neither requires the other.

If you installed the `recon` plugin, it was removed from this marketplace in 0.2.0 — run
`claude plugin uninstall recon@seankoji`.

---

## `/elephant-goldfish:thinking` — think before building

Two guided conversations, then a document.

1. **Interrogate** (article step 1) — 15–20 minutes of adversarial questioning that hunts the
   constraints you haven't thought of, not the ones you already have. You end it, not the
   command. → `discovery.md`
2. **Build the rubric** (article step 2) — a skeptic interview framed around "you get exactly
   one shot and can't ask follow-ups", which is what forces criteria to be concrete enough for
   a stranger to grade. → `spec.md`
3. **Emit the plan** — `handoff.md`, assembled deterministically by script from the two
   documents above. → paste into a fresh session, or run the `/imps:imps` line at the top of
   it.

The plan is the output. Step 3 is deliberately not run: the author's claim is that a session
with no memory of the negotiation produces better work than the one that argued its way to the
brief, and a command that helpfully finished the job would destroy the property it spent an
hour building.

```
/elephant-goldfish:thinking          # start, or pick up an existing topic
/elephant-goldfish:thinking list     # what's in flight
```

**Output type** is chosen per topic and changes both the questions and the handoff format:
`research` (a standalone answer) or `implementation` (a plan that becomes code, handed to
`/imps:imps`).

**Storage.** Everything lands in `thinking/<topic-slug>/` — `meta.json`, `discovery.md`,
`spec.md`, `handoff.md`. Optionally each artifact is also posted, as it completes, as a comment
on one GitHub Issue or Discussion per topic, so the thread reads as the progression of the
thinking. You confirm the target once per run; nothing is published without that yes.

**Why this command pins `model: opus`** — the only one in this marketplace that does. It is
entirely judgment work, and smaller models are measurably more agreeable and ask flatter
questions, which is the exact failure mode steps 1 and 2 exist to defeat. Only the
conversation is pinned — mechanical recon is delegated to whatever cheap read-only subagent
the environment provides (a haiku `scout`, `Explore`), falling back to reading files
directly. The plugin registers no agents of its own, so there is nothing to collide with a
`scout` you already define.

### Bundled scripts

| Script | Job |
|---|---|
| `thinking_state.py` | One compact JSON per call — topic resolution, phase, artifact digests, publish status. Replaces `ls`/`cat`/`stat` round-trips that would otherwise pull whole documents into context to recover a few bytes of state. Includes a fail-closed `gate`. |
| `render_handoff.py` | Assembles `handoff.md` from `discovery.md` + `spec.md` and a template. Deterministic concatenation — the model never regenerates text that is already on disk. |
| `gh_publish.py` | Find-or-create the topic's Issue/Discussion, post artifacts as comments. Idempotent by content digest, so an unchanged file is skipped and an edited one re-posts. `--dry-run` on every mutating subcommand. |

### Cowork

The same process ships as two skills — `thinking-discover` and `thinking-spec` — which share
the `templates/` directory with the command and need no scripts. Trigger them with "help me
think through X" and "let's build the rubric".

---

## `/elephant-goldfish:elephant`

### What it does

> "Design is the new code." — One repo = one `elephant.md` that lets a zero-context session re-bootstrap the project without reading all the code.

The command writes or updates `elephant.md` grounded in the repo, then runs a closed
judge → patch → re-judge loop (up to 5 rounds) where the judge is a cold Gemini read via
the `gemini` CLI — a different model lineage from the Claude author, with the doc inlined
into its prompt and no other repo access. A PASS means *a real zero-context reader can
bootstrap from this doc* — see **Limitations** below for what a PASS does **not** mean.

**Invocations:**

| Invocation | What it does |
|---|---|
| `/elephant-goldfish:elephant` | Write/update `elephant.md`, then run the judge loop |
| `/elephant-goldfish:elephant check` | Read-only factual drift check (citations + structure); no writes, no judge |
| `/elephant-goldfish:elephant <failure report>` | Fold in a goldfish failure report pasted back from a prior run |

## Limitations — read before trusting a PASS

The judge measures **plausibility, not truth**. It reads only the doc, by design — repo
access would let the doc cheat its own gaps — but that same design means a confidently
wrong doc can still pass; the judge has no way to catch a claim that's fluent, specific,
and false. Use `check` mode for factual accuracy; use the judge for bootstrap-sufficiency.
The two are complementary, not interchangeable.

---

## Prerequisites

| | `elephant` | `thinking` |
|---|---|---|
| `gemini` CLI | **required** | not used |
| `python3` | not used | **required** (3.9+, stdlib only) |
| `gh` CLI | not used | optional — only for GitHub publishing; local-only storage needs nothing |

**For `elephant`, the `gemini` CLI must be on your PATH.**

The goldfish judge calls `gemini` for a cold, different-lineage read. If it's missing or
returns empty output, the judge fails **closed** (exit 2 — never a false pass). It will
not silently skip validation.

Do **not** point `GEMINI_MODEL` at a Claude model — that reintroduces the "clone grading
its own homework" problem.

Verify before using:

```sh
gemini --help
gemini -p "say VERDICT: READY"   # should print a VERDICT line
```

---

## Install

```bash
claude plugin marketplace add seankoji/claude-plugins
claude plugin install elephant-goldfish@seankoji
```

---

## Usage

Run from the root of any git repo:

```
/elephant-goldfish:elephant
```

The command runs interactively inside a Claude Code session. Auto / accept-edits mode is recommended — the judge loop runs Bash (the judge) and Writes the doc multiple times without prompting.

### Env vars you can override

| Var | Default | Notes |
|---|---|---|
| `GEMINI_MODEL` | `gemini-2.5-pro` | Any Gemini model name accepted by `gemini` |
| `OLLAMA_MODEL` | _(unset)_ | Optional second-opinion judge via `ollama run`, run sequentially after `gemini`. Set to any model name `ollama` accepts (e.g. `qwen3:14b-q8_0`). READY requires both judges to agree. Honors `OLLAMA_HOST` for a remote instance. Do not use a Claude model. |
| `OLLAMA_NO_THINK` | `true` | Prepend `/no_think` to the Ollama prompt to suppress thinking-model preamble (qwen3, etc.) so `VERDICT:` is the first output line. Set `false` for non-thinking models that don't recognise the token. |
| `OLLAMA_HOST` | _(ollama default)_ | Override Ollama endpoint, e.g. a LAN host, for a remote instance. |
| `JUDGE_TIMEOUT` | `180` | Seconds before a hung `gemini`/`ollama` judge call is killed (needs `timeout` or `gtimeout` on PATH; otherwise unguarded) |

---

## The `goldfish-judge.sh` script

The bundled `scripts/goldfish-judge.sh` is the per-round oracle — a cold, read-only Gemini
pass (primary, doc inlined into the prompt, no file access or sandbox needed) plus an
optional local second opinion via Ollama. All judges must produce a `VERDICT: READY` or
`VERDICT: NOT READY` line; anything else, or a disagreement, is **exit 2** (fail-closed).
Consensus is AND: READY only when every judge that ran says READY. See the script's header
comments for full behavioral notes.

Run it standalone to test:

```bash
bash /path/to/goldfish-judge.sh ./elephant.md
echo "exit: $?"

# With a second opinion from a local Ollama model:
OLLAMA_MODEL=llama3.1 bash /path/to/goldfish-judge.sh ./elephant.md
echo "exit: $?"
```

Exit codes: `0` = all judges READY · `10` = any judge NOT READY · `2` = any judge errored / empty / no verdict.

---

## License

MIT
