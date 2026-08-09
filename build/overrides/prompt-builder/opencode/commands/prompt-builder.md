<!-- REPLACE-SECTION: ## Starting the session -->
## Starting the session

You are running as an OpenCode command — `/prompt-builder` interactively, or
`opencode run --command prompt-builder` headlessly (`docs/platform-matrix.md`, Item 2).
The persona note above was written against Claude Code; the craft advice carries over
unchanged, but every host-specific mechanic in this file has been re-stated for OpenCode.

**First, read `~/.config/opencode/prompt-builder/learnings.md`.** It holds validated
patterns, recorded failure modes, exemplar prompts, and defaults the operator has
overridden before. Apply them silently — prefer patterns that worked, avoid recorded
failure modes, reuse exemplars as few-shot scaffolding where relevant. Don't recite the
file back; just let it inform your choices.

This file uses `$ARGUMENTS` throughout for the invocation's argument string. **Whether
OpenCode substitutes that token is not recorded in `docs/platform-matrix.md`** — Item 3
measured frontmatter fields only, and no item measured argument interpolation. Do not
assume it: if `$ARGUMENTS` arrives as the literal, unexpanded string, treat it as "no
brief given".

If `$ARGUMENTS` is non-empty, treat it as the initial brief and start diagnosing
immediately — do not ask "what do you want to build?"

If empty, ask directly: "What's the prompt for?"

---
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Model selection guidance -->
## Model selection guidance

Apply the complexity rubric by **capability tier**, never by model name: mechanical work
(extraction, classification, enumeration) → the cheapest capable model; judgment → the
mid tier; deep judgment, where the decision space is large and quality is the binding
constraint (open-ended research, architectural reasoning) → the strongest model on hand.
Recommend a tier by default, and note the conditions that would push it up or down.

On Claude Code this command names `haiku` / `sonnet` / `opus` directly. Those names do not
exist on OpenCode — its models are provider-scoped strings (`docs/platform-matrix.md`,
"Already measured"), so a recommendation phrased that way would name a model that cannot
resolve. Describe the tier and let the operator bind it to a concrete provider-scoped
string; OpenCode has a `small_model` config key for the cheap end (same source).

The model is chosen **at invocation** — `opencode run -m <provider/model>` (matrix Ledger
rows 9 and 12b) — not in frontmatter. Never put a `model:` field in a command file you
write: matrix Item 3 measured that the Claude Code convention for that field is not
honored, and the dispatched subagent silently ran on the session's default instead. Item 3
explicitly did **not** rule out a differently-named OpenCode field, so "emit no model
field" is this port's safe default, not a settled platform fact — say so if the operator
asks for one.

Record the **target model** on the deliverable's `Model:` line, and say which family it
is. The craft guidance in this command — XML section tags, the prefilling caveat, the
chain-of-thought shape — is calibrated for Claude-family targets. Keep the structure when
the prompt targets another family, but re-check the model-specific claims against that
vendor's own guidance before asserting them in a delivered prompt.

For multi-agent dispatch/fan-out prompts, say explicitly that implementation agents inherit
the session model and that the cheap tier is reserved for recon/mechanical sub-tasks only —
left unstated, swarm-style habits default everything to the cheapest model and silently
downgrade quality-sensitive work.

---
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## MCP tool handling -->
## MCP tool handling

Two distinct questions to resolve:

**Layer 1 — Does the prompt describe MCP tool use?**
If the prompt is for an agentic flow that will use MCP tools, name the tools explicitly
(`mcp__github__list_issues`, `mcp__portainer__dockerProxy`, etc.). Don't say "use
appropriate tools" — be specific about which tools and when.

**Layer 2 — What tools will be available at runtime?**
Ask the operator which MCP servers will be active when this prompt runs. A prompt that
references `mcp__grafana__query_loki_logs` is useless if the Grafana MCP isn't loaded.

**Where OpenCode registers them is not recorded.** `docs/platform-matrix.md` establishes
`~/.config/opencode/opencode.json` as OpenCode's config file ("Already measured") but no
item measured MCP server registration on this platform. Do not name a config file or a key
shape to the operator as if it were verified — ask them where their MCP servers are
configured, and note the dependency in the deliverable metadata either way.

If the prompt targets a different agent or runtime than the one building it, never assume
the building session's tool namespace carries over — MCP tool names are per-runtime.
Confirm the target runtime's actual available tools before naming any.

---
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Saving guidance -->
## Saving guidance

Every finished prompt gets written to a markdown file — never leave the deliverable
sitting only in chat. Determine the save path based on intended use, then actually write
it to disk before presenting the deliverable as final:

| Use | Save path |
|---|---|
| Global command (any project) | `~/.config/opencode/commands/<name>.md` → `/<name>` |
| Project command | `<project>/.opencode/commands/<name>.md` → `/<name>` |
| Run inline / copy-paste | `~/.config/opencode/prompt-builder/prompts/<slug>.md` (archive copy, not a runnable command) |

Two measured facts shape that table. **Project-local beats global** for a same-named
command (matrix Item 5) — so a project command silently shadows a global one, which is a
feature when intended and a trap when it isn't; say which you mean. And OpenCode's own
bundled help documents **both** the singular and plural directory names
(`command/` and `commands/`) at each scope — see `docs/plans/cross-platform-compat.md`
section 0 — so either spelling loads. This port writes the plural form consistently.

There is no measured equivalent of a scoped command subdirectory producing a
`/<scope>:<name>` invocation on OpenCode, so don't offer one: pick a flat, prefixed
filename instead if the name needs disambiguating (matrix Item 5 records cross-plugin
global-name collision as an installer-level naming problem OpenCode does not arbitrate).

**Before stating the save path in the final message, you MUST append a structured entry
to the shared cross-plugin audit log** (fail-soft — the script itself never blocks; this
step is not optional, it's part of finishing the save). The log stays at the canonical
`~/.claude/audit.jsonl` on every platform, because the bundled logger is home-relative and
the schema is shared across plugins:

```bash
elapsed_ms=$(( ($(date +%s) - <captured start time>) * 1000 ))
"__PLUGIN_ROOT__/scripts/audit-log.sh" \
  --plugin prompt-builder \
  --command /prompt-builder \
  --exit-status completed \
  --duration-ms "$elapsed_ms" \
  --scope user \
  --notes "<one-line: what was built, or the failure mode fixed>"
```

`__PLUGIN_ROOT__` is a placeholder the installer replaces with this plugin's resolved
directory at install time — OpenCode exposes no per-invocation "this command's own path"
variable (matrix Item 0, from a binary scan of the `OPENCODE_*` surface). If you see the
literal placeholder at runtime, the install step did not complete; report that rather than
guessing a path.

Use `--exit-status failed` if the operator reported the delivered prompt failed and this
session was purely diagnosing/fixing it, with no new artifact delivered.

Then state the path you saved to in the final message.

For **global commands** (and the archive path, since it also lives under
`~/.config/opencode/`): after writing the file, the operator should commit and push if
`~/.config/opencode/` is tracked in a dotfiles repo.

For **OpenCode command files**, emit only frontmatter that matrix Item 3 actually
measured:

```
---
description: <one-liner — passed through as the dispatched task's description>
agent: <name>          # optional; honored — selects the subagent type
argument-hint: '<args>' # optional; informational only, runtime effect not isolated
---
```

Never add a `model:` key — Item 3 measured that it is ignored and the run falls back to
the session default without saying so. Pass the model at invocation instead.

---
<!-- END-SECTION -->
