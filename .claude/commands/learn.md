---
description: >
  Maintainer-only: read the accumulated learnings logs from imps, prompt-builder, and
  claude-tuneup (plus audit.jsonl and any per-project imps logs), synthesize command-body
  improvements, gate each batch with the operator, and ship approved edits as a draft PR.
argument-hint: '[plugin name to scope to, e.g. imps]'
disable-model-invocation: true
---

# /learn

**Before executing any steps**, output:

> 🧵 **/learn** — folding accumulated learnings back into the commands that produced them
>
> Reads `~/.claude/imps/learnings.md`, `~/.claude/prompt-builder/learnings.md`,
> `~/.claude/claude-tuneup.notes.md`, and `~/.claude/audit.jsonl`, proposes command-body
> edits, and gates every batch with you before writing anything.

This is a **repo-local maintainer command** — it only makes sense inside a claude-plugins
checkout, since it edits `plugins/*/commands/*.md` sources that don't exist anywhere else.
It deliberately reverses, in one reviewed pass, the "no self-edit mid-run" stance that
`imps`, `prompt-builder`, and `claude-tuneup` each state explicitly in their own bodies —
those commands stay deterministic at runtime; `/learn` is the offline, human-gated actor
that closes the loop between logged experience and command text.

## Phase 0 — Preflight (fail closed)

Require `.claude-plugin/marketplace.json` in the cwd. If it's missing, STOP and tell the
operator this command only works inside a claude-plugins checkout — do not guess a path.

Read `marketplace.json` to get the list of plugins this repo actually ships. Build the
log → command map, but only for plugins present in that list:

| Log | Target command file(s) |
|---|---|
| `~/.claude/imps/learnings.md` | `plugins/imps/commands/*.md` |
| `~/.claude/prompt-builder/learnings.md` | `plugins/prompt-builder/commands/prompt-builder.md` |
| `~/.claude/claude-tuneup.notes.md` | `plugins/claude-tuneup/commands/claude-tuneup.md` |
| `~/.claude/audit.jsonl` | cross-cutting: prioritize by `exit_status` tally per `command` |
| `<any repo>/.claude/imps/learnings.md` (found via `find ~/repos -maxdepth 4 -path "*/.claude/imps/learnings.md"`, if `~/repos` exists) | `plugins/imps/commands/*.md` — lowest-priority source, see Phase 1 |

If `$ARGUMENTS` names a specific plugin, scope everything below to that plugin only.

## Phase 1 — Ingest & cluster

These logs run tens of KB (imps' alone is routinely 80KB+) — **do not `Read` them into
this context**. Dispatch a `general-purpose` subagent per log-family (imps logs can be one
agent covering both the user-scoped and any project-scoped files; prompt-builder and
claude-tuneup can share a second agent since they're small) to read and return **only**
structured candidates, nothing raw:

```
{target_file, rule_or_pattern, evidence: [{source_path, quote_or_paraphrase}], recurrence_count, change_type}
```

Instruct each agent to:
- Prefer distilled sections (imps' `## Active rules`) over raw dated journal entries —
  those are already curated signal.
- Treat **near-identical wording repeated across multiple dated entries** as the strongest
  candidate — claude-tuneup's own notes call this out deliberately ("reuse the same
  wording across runs when the same finding recurs — exact-string matching makes it easy
  to spot... one-offs vs. recurring"). Recurring beats novel.
- Tally `audit.jsonl` `exit_status` per `command` and surface commands with a disproportionate
  `partial`/`failed` share as priority context (not standalone candidates — pair with a
  learnings-log finding when possible, since audit.jsonl notes are terse).
- Rank any candidate sourced only from a per-project `.claude/imps/learnings.md` as
  low-confidence — those skew stack-specific and rarely generalize to the shared command body.

## Phase 2 — Filter

For every candidate, `Grep` the target command file for the concept before keeping it —
the subagents in Phase 1 have no visibility into current command text, so this step is
mandatory, not optional (same discipline claude-tuneup.md uses for its own prefix-cover
pre-filter). Drop anything already reflected in the body. Drop project-specific noise that
won't generalize. What survives should be a short list per plugin, not a firehose.

## Phase 3 — Draft edits

For each surviving candidate, draft a minimal, concrete edit (old_string/new_string form)
to the target file, written in that file's own voice — match its heading structure and
tone rather than pasting the raw learnings-log wording. Respect:
- AGENTS.md's no-machine-paths invariant — `${CLAUDE_PLUGIN_ROOT}` / `~` / `$HOME` only,
  never an absolute local path.
- Any documented soft caps in the target file (e.g. a line-count cap on a section).

Group drafts by plugin.

## Phase 4 — Operator gate

For each plugin with surviving drafts, use **`AskUserQuestion`**: show the evidence trail
(which log entries, how many times seen) alongside the proposed diff, and let the operator
choose apply / skip / revise **per plugin**. Do not batch all plugins into one yes/no — a
skip on one plugin must not block applying another. If revise is chosen, take the
operator's correction and re-present before applying.

## Phase 5 — Apply + ship

If nothing was approved, stop here and say so — no worktree, no commit.

Otherwise, this is a code change: follow this session's background-job conventions —
isolate in a worktree before the first edit if not already isolated, then:
1. Apply only the approved edits.
2. **Do not touch any `plugin.json` `version` field** — `.github/workflows/version-bump.yml`
   bumps those automatically; a manual bump here would conflict with it.
3. Validate: `jq . .claude-plugin/marketplace.json` and, for every touched plugin,
   `jq -e '.name' plugins/<name>/.claude-plugin/plugin.json`.
4. Commit (only the files actually touched — never `git add -A`), push, and
   `gh pr create --draft` with a body listing each applied change and its source evidence.
5. Never push to master or force-push.

## Phase 6 — Self-log

Append one line to `~/.claude/audit.jsonl` for this `/learn` run itself, using the schema
documented in this repo's `AGENTS.md` (`id`, `ts`, `plugin: "learn"`, `command: "/learn"`,
`scope`, `project`, `exit_status`, `duration_ms`, `cost_estimate_usd: null`,
`tier: null`, `attempts: null`, `notes` truncated to 200 chars — e.g. which plugins got
edits, which were skipped, and the PR number if one was opened). This is a plain
`jq`/append — no new bundled script needed, this command isn't shipped as an installable
plugin.

## Notes

- If every candidate gets filtered out in Phase 2, that's success, not failure — say so
  plainly ("logs reviewed, nothing new to fold in") rather than manufacturing a change.
- This command reads logs; it never reads or modifies plugin runtime scripts
  (`scripts/*.sh`) — only command `.md` bodies. Script-level fixes stay a manual, reviewed
  change outside this command's scope.
