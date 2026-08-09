<!-- PLATFORM-SUPPORT: opencode=full agy=full -->

# prompt-builder

Iteratively build high-quality, reusable Claude prompts. Diagnoses your brief, structures
it using Anthropic's evidence-based prompting techniques, drafts, critiques, and delivers
a finished artefact — complete with test cases, known failure modes, and a recommended
model.

## Platforms

| Claude Code | OpenCode | Agy |
| --- | --- | --- |
| native (this README) | full — generated | full — generated |

A single self-contained command with no harness dependency beyond the bundled audit
logger, so the only platform-specific content is the audit-log invocation path.
Generated output lives under `dist/opencode/` and `dist/agy/prompt-builder/`; see
[`docs/plans/cross-platform-compat.md`](../../docs/plans/cross-platform-compat.md) and
[`docs/platform-matrix.md`](../../docs/platform-matrix.md) for how and why.

## What it does

1. **Diagnose** — asks targeted questions (hard cap: 20 per session) to nail down goal, inputs, output format, constraints, and success criteria. If the cap is hit before diagnosis is complete, it proceeds on explicitly-flagged assumptions rather than stalling.
2. **Structure** — applies evidence-based techniques (see below) instead of a named acronym framework — none of those are evidence-based, and picking between near-identical ones wastes time without changing the output.
3. **Draft** — produces a structured prompt with variables documented, format locked down, and constraints phrased as what to do (not just what to avoid).
4. **Critique** — runs a pre-delivery quality checklist internally before presenting.
5. **Deliver** — outputs a complete artefact: prompt body, test cases, known failure modes, model recommendation, and suggested save path.
6. **Refine** — loops until you're satisfied, then optionally logs learnings for future sessions.

## Techniques applied

Sourced from Anthropic's own prompting guidance, not acronym-framework folklore:

| Technique | When it's used |
|---|---|
| **XML-tag structuring** | Every prompt — separates instructions, context, input data, and examples unambiguously |
| **Context/motivation** | Explaining *why* an instruction matters, not just stating it |
| **Long-context layout** | Long or multiple input documents — placed above the query, quote-grounded |
| **Chain-of-Thought** (`<thinking>`/`<answer>` tags + self-check) | Reasoning-heavy tasks (maths, debugging, multi-hop logic) |
| **Prompt chaining** (self-correction loop) | Multi-stage work needing an inspectable intermediate output |
| **Few-shot examples** | Pattern-matching or classification tasks |
| **Do-vs-don't phrasing** | Every constraint — states the target style, not just the forbidden one |

Prefilling is deliberately **not** used — it's deprecated on current models.

## Prerequisites

None required. The skill's own logic is pure instruction — no MCP servers, no shell dependencies for diagnosis, drafting, or critique. It bundles one small script, `scripts/audit-log.sh`, that appends a structured entry to `~/.claude/audit.jsonl` at the end of a session; it needs `jq` on `PATH` and skips itself with a warning (not a failure) if `jq` is missing.

**Optional:** `~/.claude/prompt-builder/learnings.md` — if present, the skill reads it at session start to apply validated patterns, avoid recorded failure modes, and reuse exemplar prompts as few-shot scaffolding. It grows automatically as you use the skill.

**Also written:** `~/.claude/audit.jsonl` — one JSON line per full (non-embedded) session: `{plugin, command, exit_status, duration_ms, ...}`. Shared across every plugin in this marketplace that logs a structured audit trail; see the marketplace's `AGENTS.md` for the schema.

## Install

```sh
claude plugin marketplace add seankoji/claude-plugins
claude plugin install prompt-builder@seankoji
```

## Usage

```sh
/prompt-builder:prompt-builder [initial brief]
```

Pass an initial brief to skip the opening question and jump straight to diagnosis:

```sh
/prompt-builder:prompt-builder a prompt that reviews PRs for security issues
```

Or invoke with no arguments to be prompted interactively.

## Self-improvement

The skill improves across sessions by logging, not by rewriting itself. At the end of each
session, it may append validated patterns, failure modes, exemplar prompts, or overridden
defaults to `~/.claude/prompt-builder/learnings.md`, and reads that file back at the start
of future sessions to apply them silently. It always tells you what it recorded. The log
has a ~150-line soft cap; stale entries are consolidated when sections fill up.

It does not propose or apply edits to its own command body — if a logged pattern seems
worth promoting into the command permanently, it says so and leaves that edit to you (or,
on a specific occasion, if you explicitly ask it to draft the diff).

If your `~/.claude/` is tracked in a dotfiles repo, the skill will prompt you to commit after any write to `learnings.md`.

## Example output

A finished deliverable looks like this (abridged, from the brief "a prompt that reviews PRs for security issues"):

```
## Prompt: PR Security Reviewer

**Use when:** reviewing a pull request's diff for security issues before merge
**Model:** claude-sonnet-5.0
**Variables:** `{{repo_name}}` (required), `{{pr_number}}` (required)
**MCP dependencies:** mcp__github__pull_request_read, mcp__github__get_file_contents
**Save as:** `.claude/commands/security-review-pr.md`

---

You are a security-focused code reviewer. Fetch the diff for PR {{pr_number}} in
{{repo_name}} using mcp__github__pull_request_read. Flag only concrete, exploitable
issues (injection, auth bypass, secrets, unsafe deserialization) — do not report
style or performance concerns. For each finding, cite the file, line, and a one-line
exploit scenario. If none found, state that explicitly; do not invent findings.

---

**Test cases**
1. A PR adding a new API endpoint with unsanitised user input passed to a DB query.
2. A PR that changes only comments/docs (expect: no findings, explicit "none found").
3. A PR that fixes one vulnerability but introduces a second, subtler one nearby.

**Known failure modes**
- May under-report when the vulnerable code is in a file not directly touched by the diff but reachable from it (the prompt only reviews changed lines).
- Long diffs (500+ lines) risk the model skimming later hunks — split large PRs before running.
```

## License

MIT
