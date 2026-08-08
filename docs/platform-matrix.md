# Cross-platform matrix — OpenCode / Antigravity (`agy`)

Spike deliverable for PR 1 (see `docs/plans/xplat-pr1-spike.md`). Measures, does not
build: no generator, no `dist/`, no plugin-source edits, no npm anything. PR 2's design
is conditional on the verdicts recorded here.

**Environment measured:** macOS (Darwin), `opencode` 1.18.10, `agy` 1.1.11, both on
`$PATH`. Dated 2026-08-08.

**Live-invocation definition (binding for this matrix):** a "live" invocation is any
`opencode run`/`opencode <prompt>` or `agy -p`/`agy <agent prompt>` call that invokes a
model. Local CLI calls (`agy plugin install|list|uninstall|enable|disable`,
`--version`, `--help`) are free and unbudgeted but still ledgered when they touch
`$HOME`. Budget: 12 live invocations for this run. Items 0, 3, 5, 7, 9 each require at
least one live-kind ledger citation — `derived` is not accepted for those five.

---

## Already measured (carried forward, no new invocation — 2026-08-08)

- `agy` 1.1.11: plugin system per https://antigravity.google/docs/cli/plugins —
  `plugin.json` (required `name` matching `^[a-zA-Z0-9-_]+$`), optional `skills/`
  (md + `name`/`description` frontmatter → slash commands), `agents/`, `hooks.json`,
  `mcp_config.json`, `rules/`; `agy plugin install <path>` →
  `~/.gemini/antigravity-cli/plugins/<name>/`; list/enable/disable/uninstall
  subcommands; CLI has `-p/--print`, `--json-schema`, `--sandbox`, `--agent`.
- `opencode` 1.18.10: `~/.config/opencode/opencode.json` with `commands/`, `agents/`,
  `plugins/`, `tools/` dirs; npm/TS plugins via `plugin` array; models are
  provider-scoped strings — `haiku`/`sonnet`/`opus` do not exist; `small_model`
  config key exists.

Evidence: derived (Already-measured section)

---

## Item 0 — Script self-resolution (both platforms)

_NOT MEASURED YET_

## Item 1 — `agy plugin install` semantics

_NOT MEASURED YET_

## Item 2 — OpenCode non-interactive invocation

_NOT MEASURED YET_

## Item 3 — OpenCode command-file frontmatter schema

_NOT MEASURED YET_

## Item 4 — OpenCode npm plugin command-file delivery

_NOT MEASURED YET_

## Item 5 — OpenCode command namespace collision

_NOT MEASURED YET_

## Item 6 — Minimal Agy plugin installs + skill invokes

_NOT MEASURED YET_

## Item 7 — Agy GEMINI.md / AGENTS.md auto-load

_NOT MEASURED YET_

## Item 8 — Agy serial-dispatch viability

_NOT MEASURED YET_

## Item 9 — Security-gate equivalents per platform

_NOT MEASURED YET_

## Item 10 — Agy MCP registration shape (`mcp_config.json`)

_NOT MEASURED YET_

---

## Ledger

Format: `| N | kind=live\|free | exact command | purpose | UTC timestamp | exit=code |`
followed by a fenced block of real stdout/stderr (or its meaningful tail).

_(none yet)_

---

## Mutations

Every file/dir written outside the repo, logged at write time, prefixed `spike-`. Each
row ends in exactly `— CLEANED` or `— UNCLEANED`.

_(none yet)_

---

## Status

In progress — items not yet measured.
