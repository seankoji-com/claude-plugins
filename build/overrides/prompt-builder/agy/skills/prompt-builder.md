<!-- REPLACE-SECTION: ## Starting the session -->
## Starting the session

You are running as an Antigravity (`agy`) skill, invoked `/`-prefixed as
`/prompt-builder` — interactively, or headlessly as
`agy -p "/prompt-builder" --model <name>` (`docs/platform-matrix.md`, Item 6 and Ledger
rows 10 and 11). The persona note above was written against Claude Code; the craft advice
carries over unchanged, but every host-specific mechanic in this file has been re-stated
for Antigravity.

**First, read `~/.gemini/config/prompt-builder/learnings.md`.** It holds validated
patterns, recorded failure modes, exemplar prompts, and defaults the operator has
overridden before. Apply them silently — prefer patterns that worked, avoid recorded
failure modes, reuse exemplars as few-shot scaffolding where relevant. Don't recite the
file back; just let it inform your choices.

This file uses `$ARGUMENTS` throughout for the invocation's argument string. **Whether
Antigravity substitutes that token is not recorded in `docs/platform-matrix.md`** — no
item measured argument interpolation into a skill body. Do not assume it: if `$ARGUMENTS`
arrives as the literal, unexpanded string, treat it as "no brief given". Everything after
the skill name in the invocation is the brief.

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

On Claude Code this command names `haiku` / `sonnet` / `opus` directly. Those names name no
Antigravity model — the models exercised in `docs/platform-matrix.md`'s Ledger are
differently named — so a recommendation phrased that way would name a model that cannot
resolve. Describe the tier and let the operator bind it to a concrete model name.

The model is chosen **at invocation** — `agy -p "..." --model <name>` (matrix Ledger rows
10, 11, 13, 15 and 16) — not in frontmatter. No per-skill model field is recorded for this
platform anywhere in the matrix, so this port emits none; that is an absence of evidence,
not a measured "unsupported". Say so plainly if the operator asks for one, rather than
inventing a field name.

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

Antigravity registers MCP servers in `~/.gemini/config/mcp_config.json` — a top-level
`mcpServers` object keyed by server name, each entry a `{command, args}` stdio spec
(matrix Item 10, read from a real working config). If the prompt's server needs
environment variables, the passthrough key is `environment`, recorded in the matrix's
`## PR 2 re-verification` section as `ENV_PASSTHROUGH: supported:environment` and derived
from the binary rather than from a live run — flag it as such if the operator relies on it
for credentials.

If the prompt targets a different agent or runtime than the one building it, never assume
the building session's tool namespace carries over — MCP tool names are per-runtime.
Confirm the target runtime's actual available tools before naming any.

---
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Saving guidance -->
## Saving guidance

Every finished prompt gets written to a markdown file — never leave the deliverable
sitting only in chat. Determine the save path based on intended use, then actually write
it to disk before presenting the deliverable as final.

**Antigravity has no drop-in commands directory.** A reusable skill only becomes
invokable by being part of an installed plugin: `agy plugin install <dir>` copies the
whole directory to `~/.gemini/config/plugins/<name>/` and registers it in
`~/.gemini/config/import_manifest.json` (matrix Item 1, and the
`AGY_INSTALL_MODE: copy` token under `## PR 2 re-verification`). So the save paths are:

| Use | Save path |
|---|---|
| Reusable skill | `<plugin-dir>/skills/<name>.md` alongside a `<plugin-dir>/plugin.json`, then `agy plugin install <plugin-dir>` → `/<name>` |
| Run inline / copy-paste | `~/.gemini/config/prompt-builder/prompts/<slug>.md` (archive copy, not an installed skill) |

Re-running `agy plugin install` over an existing name silently overwrites it (exit 0, no
force flag), and `agy plugin uninstall <name>` removes both the registry entry and the
on-disk directory — that is the whole update story, so tell the operator to edit the
source directory and reinstall rather than hand-editing the installed copy (matrix
Item 1).

**Before stating the save path in the final message, you MUST append a structured entry
to the shared cross-plugin audit log** (fail-soft — the script itself never blocks; this
step is not optional, it's part of finishing the save). The log stays at the canonical
`~/.claude/audit.jsonl` on every platform, because the bundled logger is home-relative and
the schema is shared across plugins:

Set `AUDIT_STATUS` to `completed`, `partial`, `blocked`, `failed`, or `cancelled` before
running the command below. The default keeps the example runnable; replace it when the run did
not complete successfully.

```bash
elapsed_ms=$(( ($(date +%s) - <captured start time>) * 1000 ))
AUDIT_STATUS="${AUDIT_STATUS:-completed}"
"__PLUGIN_ROOT__/scripts/audit-log.sh" \
  --plugin prompt-builder \
  --command /prompt-builder \
  --exit-status "$AUDIT_STATUS" \
  --duration-ms "$elapsed_ms" \
  --scope user \
  --notes "<one-line: what was built, or the failure mode fixed>"
```

`__PLUGIN_ROOT__` is a placeholder the installer replaces with this plugin's resolved
directory at install time. Antigravity also exposes each skill's own absolute installed
path in the model's system prompt under a `<plugins>` section, so the plugin root is
derivable as `dirname(dirname(<this file's path>))` if the placeholder is ever left
unsubstituted (matrix Item 0). Report an unsubstituted placeholder rather than silently
guessing a path.

Use `blocked` when a tool or permission refusal stopped the requested work. Preserve the exact
refusal in `--notes`. Use `failed` when no usable artifact was delivered and `partial` when the
file exists but a required follow-up failed.

Then state the path you saved to in the final message.

For the archive path (it lives under `~/.gemini/config/`): after writing the file, the
operator should commit and push if `~/.gemini/config/` is tracked in a dotfiles repo.

For **Antigravity skill files**, the frontmatter the matrix records as load-bearing is
`name` plus `description` — a markdown file carrying both becomes a slash command
("Already measured", plus Item 6's live install-and-invoke). The sibling `plugin.json`
needs a `name` matching `^[a-zA-Z0-9-_]+$`:

```
---
name: <slug matching ^[a-zA-Z0-9-_]+$>
description: <one-liner>
---
```

Don't add a model field — see Model selection guidance above; none is recorded for this
platform, and inventing one would be a claim the matrix does not support.

---
<!-- END-SECTION -->
