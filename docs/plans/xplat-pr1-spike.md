# GOAL — PR 1 of 2: cross-platform spike (measure everything, build nothing)

Handoff: `/imps:imps docs/plans/xplat-pr1-spike.md`. Branch off `master`; PR to
`master`. Deliverable: **`docs/platform-matrix.md` and nothing else** — no generator,
no dist, no file moves. The operator reviews the merged matrix before PR 2
(`docs/plans/xplat-pr2-build.md`) is dispatched. PR 2's content is conditional on
this PR's verdicts; do not start it.

## Verify convention (binding for every item)

`Verify:` is a shell command whose **exit 0 means the Done-when holds** — never the
inverse. Expect-empty states are written `test -z "$(...)"`; expect-present states
use `grep -q`; counts use `test ... -eq/-ge`. An item whose verify cannot fail is a
defect in the plan — flag it, don't dispatch it.

## Budget and hygiene (read before any live invocation)

- **Quota**: live `opencode` / `agy` invocations are capped at **12 total** for this
  spike. Each is recorded (command, purpose, timestamp) in a ledger section of the
  matrix. This repo has a documented mid-run quota death
  (`plugins/imps/references/opencode-harness.md`, "OpenCode Go 5-hour usage cap") —
  if any invocation fails in a way consistent with rate limiting, STOP the phase and
  report; do not burn attempts diagnosing.
- **Machine mutations**: every file written outside the repo (test commands in
  `~/.config/opencode/commands/`, test plugins under
  `~/.gemini/antigravity-cli/plugins/`) is logged in a "Mutations" section of the
  matrix at write time. The final item verifies cleanup.
- Never pass `--dangerously-skip-permissions` to anything.

## Already measured (2026-08-08 — carry into the matrix with this evidence line)

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

## Items

**Item zero — the fact the whole architecture sits on.**

- [ ] Script self-resolution is answered for both platforms: what, if anything, plays the role of `${CLAUDE_PLUGIN_ROOT}` — i.e. how can a command file installed on OpenCode / Agy locate its plugin's bundled `scripts/*.sh` without a machine path?
      Verify: grep -qiE 'script self-resolution|plugin root' docs/platform-matrix.md && test -z "$(sed -n '/[Ss]cript self-resolution/,/^## /p' docs/platform-matrix.md | grep -iE 'TBD|TODO|unknown')"
      Done when: per platform, either the working mechanism is named with a demonstrated example, or the matrix records "none exists" **and names the degradation branch** PR 2 must take (candidates: scripts installed adjacent to commands and resolved relative to the command file; a generated absolute path written at install time by the installer; scripts inlined into command bodies for script-light plugins; feature refused on that platform). This row gates the entire generation architecture.

- [ ] `agy plugin install` semantics are measured: copy or symlink; behavior on reinstall over an existing name; uninstall cleanliness
      Verify: grep -qiE 'copy|symlink' docs/platform-matrix.md && grep -qi 'reinstall' docs/platform-matrix.md
      Done when: all three answers recorded with transcripts. If symlink: the matrix states the delete-the-clone hazard and PR 2's install docs must warn. If copy: the update story is "reinstall", stated explicitly.

- [ ] OpenCode non-interactive invocation is measured **before** any item that depends on invoking a command headlessly
      Verify: grep -qiE 'non-interactive|headless' docs/platform-matrix.md
      Done when: the matrix records whether OpenCode has a scriptable invocation path (e.g. a `run` subcommand) or whether verification must be interactive-with-transcript — and later items' evidence matches whichever it is.

- [ ] OpenCode command-file frontmatter schema is documented from a working command, not docs alone
      Verify: sed -n '/[Ff]rontmatter/,/^## /p' docs/platform-matrix.md | grep -q 'opencode' && grep -qi 'invoked' docs/platform-matrix.md
      Done when: a minimal command was placed in `~/.config/opencode/commands/`, invoked (headless or interactive per the prior item), accepted fields listed, transcript recorded, mutation logged.

- [ ] Whether an OpenCode npm plugin package can deliver command files is answered definitively — and if delivery requires copying into config dirs, the uninstall-orphan hazard is assessed
      Verify: grep -qiE 'npm.*(command|deliver)' docs/platform-matrix.md && grep -qi 'uninstall' docs/platform-matrix.md
      Done when: the delivery mechanism PR 2's bundle will use is named and demonstrated, and the matrix states what `npm uninstall` leaves behind under that mechanism. If the only mechanism orphans invocable commands pointing at deleted scripts, the matrix must say so — PR 2 will then require an uninstall hook or a different delivery design. [JUDGMENT]

- [ ] OpenCode command namespace behavior is measured: what happens when an installed command filename collides with a user's existing command
      Verify: grep -qiE 'collision|namespace' docs/platform-matrix.md
      Done when: precedence/override behavior recorded; PR 2's filename-prefix decision cites this row.

- [ ] A minimal generated-shape Agy plugin installs and its skill invokes
      Verify: sed -n '/[Aa]gy.*minimal/,/^## /p' docs/platform-matrix.md | grep -q 'agy plugin install' && grep -qi 'plugin list' docs/platform-matrix.md
      Done when: transcript shows install, `agy plugin list`, successful skill invocation; mutation logged.

- [ ] Whether Agy auto-loads a repo-root `GEMINI.md` and/or `AGENTS.md` (and conflict precedence) is measured, not assumed
      Verify: grep -qiE 'GEMINI\.md' docs/platform-matrix.md
      Done when: observed behavior recorded with the method used to observe it. PR 2 creates `GEMINI.md` only if this row supports it.

- [ ] Agy serial-dispatch viability verdict: `agy -p` with `--json-schema`, exit codes, `--sandbox` semantics
      Verify: sed -n '/serial dispatch/,/^## /p' docs/platform-matrix.md | grep -qiE 'viable|not viable'
      Done when: an explicit viable / not-viable verdict with transcripts. This row rewrites PR 2 Phase D.

- [ ] Security-gate equivalents per platform: how OpenCode permission config and Agy's prompts/`--sandbox` map to each Claude gate shipped commands assume (operator confirm before arbitrary shell; sandboxed execution; fail-closed judging)
      Verify: for g in 'operator' 'sandbox' 'fail-closed'; do grep -qi "$g" docs/platform-matrix.md || exit 1; done
      Done when: each gate has a per-platform row: equivalent exists (named) / must refuse. Includes the explicit row: OpenCode dispatch sandbox is Seatbelt/Darwin-only → **on Linux the dispatch tier refuses with a named reason** (operator decision, already made — record it, don't reopen it).

- [ ] Agy MCP registration shape (`mcp_config.json`) confirmed with a working example
      Verify: grep -q 'mcp_config' docs/platform-matrix.md
      Done when: example config recorded (offload-sidecar registration example in PR 2 derives from it).

- [ ] The matrix is complete: every row above present, per-row evidence, no placeholders, invocation ledger within budget
      Verify: test -f docs/platform-matrix.md && test -z "$(grep -E 'TBD|TODO|\?\?\?' docs/platform-matrix.md)" && grep -qi 'ledger' docs/platform-matrix.md && test "$(grep -ci 'Evidence' docs/platform-matrix.md)" -ge 10
      Done when: all four conditions hold and the ledger shows ≤ 12 live invocations.

- [ ] Every machine mutation is cleaned up: spike test commands removed from `~/.config/opencode/commands/`, spike plugins uninstalled via `agy plugin uninstall`, and the Mutations section marks each entry cleaned
      Verify: test -z "$(ls ~/.config/opencode/commands/ 2>/dev/null | grep -i spike)" && test -z "$(agy plugin list 2>/dev/null | grep -i spike)" && ! grep -qi 'UNCLEANED' docs/platform-matrix.md
      Done when: spike-named artifacts are gone from both locations and the matrix confirms it. (Name every spike artifact with a `spike-` prefix so this check is meaningful.)

## Out of scope for PR 1

Everything else: no generator, no `dist/`, no file moves, no edits to any plugin
source, no npm anything. If a spike finding makes part of PR 2 impossible as
planned, record it in the matrix — PR 2 gets revised by the operator, not by this
run.
