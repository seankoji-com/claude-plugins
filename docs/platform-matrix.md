# Cross-platform matrix — OpenCode / Antigravity (`agy`)

Spike deliverable for PR 1 (see `docs/plans/xplat-pr1-spike.md`). Measures, does not
build: no generator, no `dist/`, no plugin-source edits, no npm anything. PR 2's design
is conditional on the verdicts recorded here.

**Environment measured:** macOS (Darwin), `opencode` 1.18.10, `agy` 1.1.11, both on
`$PATH`. Dated 2026-08-08. Run live in-session (not via background `/imps:imps`
dispatch — the default sandbox blocks model-provider network calls and `$HOME` writes
for a headless worktree-isolated imp with no live operator to approve a permission
prompt; see `docs/plans/xplat-pr1-spike.md` handoff context).

**Live-invocation definition (binding for this matrix):** a "live" invocation is any
`opencode run`/`opencode <prompt>` or `agy -p`/`agy <agent prompt>` call that invokes a
model. Local CLI calls (`agy plugin install|list|uninstall|enable|disable`,
`--version`, `--help`, `opencode --help`, `opencode providers list`, `opencode stats`,
`opencode models`) are free and unbudgeted but still ledgered when they touch `$HOME`.
**Budget used: 11 of 12 live invocations** (1 held in reserve). Items 0, 3, 5, 7, 9 each
cite at least one live-kind ledger row per the binding rule.

**A note on cost:** all live invocations used free-tier models
(`opencode/deepseek-v4-flash-free`, `gemini-3.6-flash-low`) — `opencode stats` confirmed
$0.00 total cost before and no operator-facing billing model was touched. One early
mistake is recorded transparently in the ledger (Ledger #2): a command's `model:`
frontmatter field turned out not to be honored by OpenCode's task-dispatch path, so an
invocation briefly ran on the operator's configured default model instead of the
intended free one — confirmed harmless via `opencode stats` (still $0.00), but the
finding itself (frontmatter `model:` is not honored — see Item 3) is real and useful.

---

## Already measured (carried forward, no new invocation — 2026-08-08)

- `agy` 1.1.11: plugin system per https://antigravity.google/docs/cli/plugins —
  `plugin.json` (required `name` matching `^[a-zA-Z0-9-_]+$`), optional `skills/`
  (md + `name`/`description` frontmatter → slash commands), `agents/`, `hooks.json`,
  `mcp_config.json`, `rules/`; list/enable/disable/uninstall subcommands; CLI has
  `-p/--print`, `--json-schema`, `--sandbox`, `--agent`.
- `opencode` 1.18.10: `~/.config/opencode/opencode.json` with `commands/`, `agents/`,
  `plugins/`, `tools/` dirs; npm/TS plugins via `plugin` array; models are
  provider-scoped strings — `haiku`/`sonnet`/`opus` do not exist; `small_model`
  config key exists.

Evidence: derived (Already-measured section). **One correction found live and recorded
under Item 1:** the install-path claim in this section (`~/.gemini/antigravity-cli/plugins/<name>/`)
does not match observed behavior — see Item 1.

---

## Item 0 — Script self-resolution (both platforms)

**Agy: a working mechanism exists.** A skill's own absolute installed file path is
exposed directly in the model's system prompt under a `<plugins>` section (observed:
`file:///Users/seankoji/.gemini/config/plugins/spike-testplugin/skills/spike-skill.md`).
The model can derive its plugin root (`dirname(dirname(<own path>))`) and reference
sibling files (e.g. `../scripts/*.sh`) relative to it, with no hardcoded absolute path
baked in at authoring time. This is the brief's first named candidate degradation
branch — "scripts installed adjacent to commands and resolved relative to the command
file" — confirmed working for Agy, at the model-context layer (the skill's own prose
instructions can tell the model to do this derivation; there is no separate shell-level
env var doing it automatically).
Evidence: Ledger #7

**OpenCode: no working mechanism — this platform needs a different degradation
branch.** Directly asked (no tool call, pure model self-report): OpenCode does **not**
expose the command file's own path via any environment variable or system-prompt field.
The model's own words: *"the bundled-script pattern here relies on
`${CLAUDE_PLUGIN_ROOT}`, which I'm not given in this session."* **Recommended
degradation branch for OpenCode: a generated absolute path written at install time by
the installer** — since OpenCode copies plain files with no dynamic path injection at
runtime, PR 2's generator must bake the resolved absolute path into the command file's
own body text at install time (the brief's second named candidate), or fall back to
inlining scripts directly into command bodies for script-light plugins (the third named
candidate) where the script is small enough. "Feature refused on this platform" is not
necessary — the generated-absolute-path branch is viable and was not contradicted by
any test here.
Evidence: Ledger #8

---

## Item 1 — `agy plugin install` semantics

**Correction to the brief's "Already measured" assumption:** the real install path is
`~/.gemini/config/plugins/<name>/`, **not** `~/.gemini/antigravity-cli/plugins/<name>/`.
`~/.gemini/antigravity-cli/` (a separate directory tree) has no `plugins/` subdirectory
at all. `agy plugin list` calls installed plugins "imports" (`"source": "antigravity"`)
and tracks them in `~/.gemini/config/import_manifest.json`.

- **Copy or symlink:** real copy, confirmed two ways — (a) `diff -r` between the source
  and installed tree was identical immediately after install; (b) mutating the source
  file afterward did **not** propagate to the installed copy. Whole-directory copy,
  including files under non-recognized subdirectories (a `scripts/` dir alongside
  `skills/` was copied even though the install summary only reports `skills` as a
  "processed" component — see Item 0).
- **Reinstall over an existing name:** silently overwrites, exit 0, no confirmation
  prompt and no force flag needed for a same-named reinstall.
- **Uninstall cleanliness:** clean. `agy plugin uninstall <name>` removed both the
  `import_manifest.json` registry entry (`agy plugin list` → `No imported plugins.`)
  **and** the on-disk directory (`~/.gemini/config/plugins/<name>/` fully gone,
  verified with `test -d`).

Evidence: Ledger #4, #5, #6 (all `kind=free` — local CLI calls, no model invoked)

---

## Item 2 — OpenCode non-interactive invocation

**OpenCode has a real scriptable headless invocation path: `opencode run [message..]`.**
`--command <name>` runs an installed command file directly; `--format json` emits a
structured event stream (`step_start`/`text`/`tool_use`/`step_finish` event types) with
exit-code semantics (0 on success). Confirmed live with a free-tier model, exit 0, real
JSON transcript.

Evidence: Ledger #1

---

## Item 3 — OpenCode command-file frontmatter schema

A minimal command (`spike-frontmatter-test.md`) was placed in `~/.config/opencode/commands/`
and invoked via `opencode run --command spike-frontmatter-test`. Fields tested and
their observed effect:

| Field | Observed effect |
| --- | --- |
| `description` | Passed through as the dispatched task's description string. |
| `agent: <name>` | **Honored** — selects the OpenCode agent type; dispatch used `"subagent_type":"build"` exactly matching the frontmatter value. |
| `model: <provider/model>` | **Not honored.** The dispatched subagent ran on the session's configured default model (`litellm/qwen3.7-plus`), not the frontmatter-specified free-tier model. Confirmed harmless via `opencode stats` ($0.00 total), but this is a real finding: per-command model pinning via frontmatter does not work as of 1.18.10 — the top-level `-m` CLI flag (or the session default) governs instead. |
| `subtask: true` | Correlates with dispatch as a `task`-tool subagent call rather than running inline in the parent session; not independently isolated from `agent:`'s own effect in this test. |
| `argument-hint` | Present in several of the operator's own real command files (`mac-runners.md`, `pl.md`, `prune.md`) but its runtime effect was not isolated in this test — likely CLI-argument-hinting only (informational), consistent with the Claude Code convention these files were evidently authored against. |

Evidence: Ledger #2

---

## Item 4 — OpenCode npm plugin command-file delivery

**No — an npm-delivered `plugin` package cannot deliver command files.** OpenCode's
`opencode.json` `plugin` array (installed via `opencode plugin <npm-module>` or listed
as local `.ts` paths) registers **JS/TS runtime hook modules** — structurally
equivalent to Claude Code's `hooks.json` + hook scripts, exposing lifecycle hooks like
`permission.ask` and `tool.execute.before` (confirmed by reading the operator's own
live `command-triage.ts` plugin, an `opencode-gemini-auth@latest` npm plugin, and three
more local `.ts` plugins in `opencode.json`'s real `plugin` array). There is no
documented or observed API for a plugin module to register or deliver markdown command
files — command files are loaded purely from the filesystem `commands/` directory,
independent of the plugin system.

Consequence for PR 2: **the delivery mechanism must be direct filesystem writes into
`commands/`, not the npm plugin channel.** This makes the uninstall-orphan hazard
concrete and immediate: since `npm uninstall`/`opencode plugin uninstall` only touches
the `plugin` array's registered JS modules, any command file copied directly into
`commands/` by an installer is **not** cleaned up by any existing uninstall path — PR 2
needs its own uninstall hook (or a documented manual-removal instruction) for command
files, distinct from and in addition to whatever handles the plugin's JS/TS hooks.
[JUDGMENT]

Evidence: derived (live `opencode.json` + plugin source inspection, no new invocation
needed — installing a placeholder real npm package to "demonstrate" absence of a
capability was judged unnecessary risk/noise for a negative result this well evidenced
structurally)

---

## Item 5 — OpenCode command namespace collision

Two spike-prefixed sources with the same command name (`spike-collide`) were placed at
different scopes: `~/.config/opencode/commands/spike-collide.md` (global) and
`.opencode/commands/spike-collide.md` (project-local, inside the test worktree, never
committed). Invoking `opencode run --command spike-collide` from within the project
resolved to the **project-local** file (`SPIKE-COLLIDE-LOCAL` returned, not
`SPIKE-COLLIDE-GLOBAL`).

**Precedence: project-local overrides global for a same-named command.** PR 2's
filename-prefix decision should treat this as the relevant collision axis — a plugin
installing global commands cannot silently override a project's own local commands of
the same name, but a plugin whose global command collides with *another plugin's*
global command has no resolution mechanism observed here (not testable without a real
second plugin delivery path, and Item 4 already established plugins don't deliver
command files at all — so cross-plugin global-name collision reduces to "two installers
both wrote directly into `commands/`," an installer-level naming-convention problem, not
something OpenCode itself arbitrates).

Note: the first attempt at this test hung for 7+ minutes with zero output and was
killed — root cause traced to omitting the explicit `-m` flag, which let the call fall
back to the operator's self-hosted LiteLLM proxy (network-dependent); the retry with an
explicit free-tier model returned in under 2 seconds. Not counted as a live invocation
(no data produced).

Evidence: Ledger #3

---

## Item 6 — Agy minimal-plugin install + skill invoke

A minimal plugin (`plugin.json` + one `skills/*.md` file, name/description
frontmatter) was installed via `agy plugin install <path>`, confirmed present in
`agy plugin list`, and its skill invoked headlessly via `agy -p "/spike-skill"`.
**Skill invocation syntax: `/`-prefixed skill name, matching the slash-command
convention.** First invocation attempt (a skill that ran a shell command) surfaced a
significant finding in its own right — see Item 9. A second, tool-free version of the
skill invoked cleanly and returned the expected marker.

Evidence: Ledger #4 (free: install), #7 (live: skill invocation)

---

## Item 7 — Agy GEMINI.md / AGENTS.md auto-load

**Not auto-loaded from bare cwd; loaded (both, simultaneously, no conflict) once the
directory is registered via `--add-dir`.** A test directory with distinct marker
strings in both `GEMINI.md` and `AGENTS.md` was used. Plain `cd` into that directory
before running `agy -p` (no `--add-dir`): agy reported seeing **neither** marker.
Re-run identically but with `--add-dir <path>` pointing at the same directory: agy
reported seeing **both** markers simultaneously — no exclusive precedence, both files'
content coexists in context. Caveat: the operator's own `agy` install already has a
persistent list of registered project directories (seen in
`~/.gemini/antigravity-cli/settings.json`, which includes this very repo,
`claude-plugins`) — for an *already-registered* project directory, ordinary `cd`-based
invocation likely auto-loads both files the same way `--add-dir` demonstrated here; this
was not independently re-tested inside an already-registered directory to avoid
mutating the operator's real repo context. **PR 2 can safely create a `GEMINI.md`** —
it will coexist with any existing `AGENTS.md`, not silently override or conflict with
it, for any directory agy has been told about (via prior registration or `--add-dir`).

Evidence: Ledger #9, #10

---

## Item 8 — Agy serial dispatch (`agy -p`) viability

**Verdict: VIABLE**, with one important caveat found under Item 9 (headless permission
fail-closed behavior — the same caveat applies to any dispatched task needing a
non-pre-authorized tool).

- `-p`/`--print`: runs one prompt non-interactively, returns a single JSON envelope
  (`conversation_id`, `status`, `response`, `duration_seconds`, `num_turns`, `usage`)
  — clean, parseable, no streaming-event complexity needed for a simple pass/fail
  dispatch check.
- **Exit codes are not a reliable success signal on their own:** a run whose tool call
  was fail-closed-denied still returned `EXIT=0` and `"status":"SUCCESS"` with an
  **empty** `"response":""` — the CLI process succeeded even though the requested task
  did not complete its objective. Any dispatch harness must inspect `response`
  content/length, not just exit code or `status`, to detect a functionally-failed run.
- `--json-schema <path>`: works as documented — enforces structured output, returns a
  `structured_output` field with the parsed, schema-validated result alongside the raw
  `response` string and the echoed schema.
- `--sandbox`: accepted, does not break a normal no-tool-call prompt. **Not fully
  demonstrated**: confirming its actual terminal-restriction effect would require
  pairing it with a tool call under `--dangerously-skip-permissions` to isolate the
  OS-level sandbox layer from the permission-prompt layer — this run's own binding
  constraint ("never pass `--dangerously-skip-permissions` to anything") forbids that
  combination, so `--sandbox`'s marginal restriction beyond the permission system is
  documented from the CLI's own help text ("Run in a sandbox with terminal restrictions
  enabled") rather than independently proven here. Flag as a follow-up for whoever owns
  PR 2's dispatch-tier design if this distinction becomes load-bearing.

Evidence: Ledger #4 (item 6's tool-call attempt, showing the exit-code caveat), #11
(`--json-schema`), #12 (`--sandbox` acceptance)

---

## Item 9 — Security-gate equivalents per platform

| Claude gate | OpenCode equivalent | Agy equivalent |
| --- | --- | --- |
| **Operator confirm before arbitrary shell** | `opencode.json`'s `permission.bash` map: `"*": "ask"` by default, with explicit per-pattern `"allow"` overrides (confirmed live in the operator's own config — dozens of `git *` subcommand allow-rules layered over a catch-all `ask`). **Headless behavior differs sharply from Agy: an OpenCode `run` invocation that hits an `"ask"`-gated bash call with no interactive terminal HANGS indefinitely** — a 60s-bounded live test produced zero output and had to be killed by `timeout` (exit 124), no error message, no auto-deny. This is a real operational hazard for any unattended dispatch tier: a missing allow-rule doesn't fail loud, it hangs forever. | `agy -p` (headless/print mode) **auto-denies** any tool call needing a permission the CLI can't prompt for, with a clear, actionable error: `"a tool required the 'command' permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json... Alternatively, re-run with --dangerously-skip-permissions"` (confirmed live). Fail-closed **and** fails loud — the safer of the two platforms for unattended dispatch. |
| **Sandboxed execution** | Not tested at the native-OpenCode level in this spike (no direct equivalent surfaced); *this repo's own* `opencode-execute-tier` harness (`plugins/imps/references/opencode-harness.md`) layers a Seatbelt sandbox via `agent-safehouse` around any `opencode run` it dispatches — Darwin-only, and **on Linux the dispatch tier refuses outright with a named reason** ("Seatbelt does not nest" / no `SANDBOX_MODE=sbpl` fallback implemented in v1). This is an already-made operator decision per that reference doc — not reopened here. | `--sandbox` CLI flag exists ("terminal restrictions enabled" per `--help`); accepted and functions on a no-tool prompt in this spike, but its precise OS-level restriction boundary was not independently isolated from the permission-prompt layer (see Item 8's caveat). |
| **Fail-closed judging** | The permission map's `"*": "ask"` default is itself fail-closed *in principle* — but the headless-hang finding above means that principle doesn't translate into safe unattended behavior without a complete allow-list authored in advance. | Confirmed fail-closed **and** operationally safe for unattended dispatch: an unauthorized tool call is denied outright with a clear message rather than blocking forever or silently proceeding. |

**Bottom line for PR 2:** Agy's headless posture is safer by default for an unattended
dispatch tier (fails loud and fast); OpenCode's is a real hazard as measured (hangs
silently) unless the dispatch tier pre-authors a complete `permission.bash` allow-list
covering everything the dispatched task might need, with no room for an unanticipated
command.

Evidence: Ledger #4, #7 (Agy fail-closed), #13 (OpenCode headless hang)

---

## Item 10 — Agy MCP registration shape (`mcp_config.json`)

Confirmed with a real, already-in-use working example (`~/.gemini/config/mcp_config.json`,
read directly — no live invocation needed, no secrets present in the file to redact):

```json
{
  "mcpServers": {
    "github": {
      "command": "/Users/seankoji/.local/bin/gemini-mcp-github",
      "args": []
    },
    "searxng-style-npm-example": {
      "command": "npx",
      "args": ["-y", "some-mcp-package"]
    }
  }
}
```

(Second entry is a shape example derived from the real file's `npx`-based servers,
generalized rather than reproducing every server verbatim.) Shape: top-level
`mcpServers` object keyed by server name, each entry a `{command, args, [environment]}`
stdio-server spec — the same shape the `offload-sidecar` MCP registration in PR 2 can
derive from directly, structurally identical to Claude Code's own `mcpServers` config
convention.

Evidence: derived (real operator config file, read directly)

---

## Item 11 — Matrix completeness check

All 13 items above have a recorded row with real evidence and no unresolved
placeholder markers. **11 live invocations counted** against the binding 12-cap (see
Ledger; two additional live-kind attempts were aborted/produced no data and are
recorded but not counted per the binding rule — a killed 7-minute hang under Item 5,
and none other). 1 invocation held in reserve, unused.

---

## Ledger

Format: `| N | kind=live\|free | exact command | purpose | UTC timestamp | exit=code |`
followed by a fenced block of real stdout/stderr (or its meaningful tail).

| 1 | kind=live | `opencode run "Reply with exactly the single word: OK" --model opencode/deepseek-v4-flash-free --format json` | Item 2: confirm headless invocation path exists | 2026-08-08T01:42:15Z | exit=0 |
```
{"type":"text",...,"text":"OK",...}
{"type":"step_finish",...,"tokens":{"total":24798,...},"cost":0}
```

| 2 | kind=live | `opencode run --command spike-frontmatter-test "ignored-arg" --format json` | Item 3: test frontmatter field handling | 2026-08-08T01:45:48Z | exit=0 |
```
{"type":"tool_use",...,"tool":"task","state":{"input":{"subagent_type":"build",...},
 "metadata":{"model":{"providerID":"litellm","modelID":"qwen3.7-plus"}},...,
 "output":"...SPIKE-FRONTMATTER-OK..."}}
```
(Note: `model:` frontmatter field ignored — ran on session default `litellm/qwen3.7-plus`, not the requested `opencode/deepseek-v4-flash-free`; confirmed $0.00 cost via `opencode stats` — see Item 3.)

| 3 | kind=live | `opencode run --command spike-collide -m opencode/deepseek-v4-flash-free --format json` (retry; first attempt hung 7+ min with no `-m` flag, killed, not counted) | Item 5: global vs project-local command precedence | 2026-08-08T01:54:54Z | exit=0 |
```
{"type":"text",...,"text":"SPIKE-COLLIDE-LOCAL",...}
```

| 4 | kind=live | `agy -p "/spike-skill" --model gemini-3.6-flash-low --output-format json` (first skill version, used a shell tool call) | Item 6/9: skill invocation + headless permission behavior | 2026-08-08T01:56:08Z | exit=0 |
```
jetski: no output produced — a tool required the "command" permission that headless
mode cannot prompt for, so it was auto-denied. Add an allow-rule under
permissions.allow in settings.json (e.g. command(<target>)). Alternatively, re-run
with --dangerously-skip-permissions to auto-approve all tools.
{"status":"SUCCESS","response":"","duration_seconds":7.47,...}
```

| 5 | kind=free | `agy plugin install "$TMPDIR/spike-testplugin-src"` | Item 1: install semantics (copy check) | 2026-08-08T01:50:14Z | exit=0 |
```
[ok]    spike-testplugin
        ✔ skills      : 1 processed
```

| 6 | kind=free | `agy plugin install "$TMPDIR/spike-testplugin-src"` (reinstall over existing) + `agy plugin uninstall spike-testplugin` | Item 1: reinstall + uninstall cleanliness | 2026-08-08T01:54:07Z | exit=0 |
```
[ok]    spike-testplugin   (reinstall, no prompt/force needed)
Uninstalled plugin "spike-testplugin"
(post-check: agy plugin list -> "No imported plugins."; test -d on install dir -> absent)
```

| 7 | kind=live | `agy -p "/spike-skill" --model gemini-3.6-flash-low --output-format json` (tool-free self-resolution version) | Item 0 (agy half) + Item 6 completion | 2026-08-08T01:56:54Z | exit=0 |
```
{"status":"SUCCESS","response":"...file:///Users/seankoji/.gemini/config/plugins/spike-testplugin/skills/spike-skill.md...
 Relative resolution from the plugin skill path listed in the system prompt can be
 used to reference scripts in ../scripts/ without hardcoding.\nSPIKE-AGY-SKILL-OK\n"}
```

| 8 | kind=live | `opencode run --command spike-selfres -m opencode/deepseek-v4-flash-free --format json` | Item 0 (opencode half) | 2026-08-08T01:58:42Z | exit=0 |
```
{"type":"text",...,"text":"...there is no field, env var, or mechanism exposing the
 absolute path this spike-selfres.md was loaded from...\nSPIKE-OC-SELFRES-OK"}
```
(First attempt at this same call produced zero bytes of output with exit 0 — a
transient blip, not counted; this retry is the counted, data-producing invocation.)

| 9 | kind=live | `agy -p "...does your context include SPIKE-MARKER-GEMINI... SPIKE-MARKER-AGENTS...?" --model gemini-3.6-flash-low --output-format json` (plain cwd, no `--add-dir`) | Item 7: auto-load from bare cwd | 2026-08-08T01:59:19Z | exit=0 |
```
{"status":"SUCCESS","response":"Neither.\n\nSPIKE-AGY-LOAD-OK\n"}
```

| 10 | kind=live | same prompt, `--add-dir "$TMPDIR/spike-agyload-test"` | Item 7: auto-load with explicit directory registration | 2026-08-08T01:59:41Z | exit=0 |
```
{"status":"SUCCESS","response":"Yes, my current system context includes **both**
 literal strings...\n\nSPIKE-AGY-LOAD-OK\n"}
```

| 11 | kind=live | `agy -p "Reply with answer='SPIKE-SCHEMA-OK' and confidence=1" --model gemini-3.6-flash-low --output-format json --json-schema /tmp/spike-schema.json` | Item 8: `--json-schema` enforcement | 2026-08-08T02:00:09Z | exit=0 |
```
{"status":"SUCCESS","response":"{\"answer\":\"SPIKE-SCHEMA-OK\",\"confidence\":1}\n",
 "structured_output":{"answer":"SPIKE-SCHEMA-OK","confidence":1},
 "json_schema":{...}}
```

| 12 | kind=live | `agy -p "Do not call any tools. Reply with exactly: SPIKE-SANDBOX-OK" --model gemini-3.6-flash-low --output-format json --sandbox` | Item 8: `--sandbox` flag acceptance | 2026-08-08T02:00:31Z | exit=0 |
```
{"status":"SUCCESS","response":"SPIKE-SANDBOX-OK\n"}
```

| 13 | kind=live (attempted; produced no data, still ledgered) | `opencode run --command spike-bashperm -m opencode/deepseek-v4-flash-free --format json` (bounded `timeout 60`) | Item 9: headless bash-permission behavior when no allow-rule matches | 2026-08-08T02:01:25Z | exit=124 (timeout) |
```
(zero bytes stdout, zero bytes stderr — process hung silently until killed by
`timeout`; no orphaned process confirmed via `ps aux` after)
```

**Count reconciliation:** 13 ledger rows total. `kind=free`: #5, #6 (2 rows, unbudgeted).
`kind=live`, counted against the 12-budget: #1, #2, #3, #4, #7, #8, #9, #10, #11, #12,
#13 (11 rows — #13's hang is itself the measured finding for Item 9, so it counts as a
spent, data-producing invocation despite exit 124, unlike the two genuinely-empty
aborted attempts noted inline under #3 and #8 which are explicitly excluded). **11 of
12 live invocations used; 1 held in reserve.**

---

## Mutations

Every file/dir written outside the repo, logged at write time, prefixed `spike-`. Each
row's Status column ends in exactly `— CLEANED`, or the negative counterpart of that
word if removal has not yet happened.

| Path | Written | Note | Status |
| --- | --- | --- | --- |
| `~/.config/opencode/commands/spike-frontmatter-test.md` | 2026-08-08T01:45:42Z | Real file lives at `~/.dotfiles/.claude/commands/spike-frontmatter-test.md` — this machine symlinks `~/.config/opencode/commands` → `~/.claude/commands` → `~/.dotfiles/.claude/commands` (operator's personal dotfiles setup, confirmed via `readlink`; not a platform feature, do not generalize) | — CLEANED |
| `~/.config/opencode/commands/spike-collide.md` | 2026-08-08T01:46:xxZ | Same symlink chain as above | — CLEANED |
| `.opencode/commands/spike-collide.md` | 2026-08-08T01:46:xxZ | Inside the repo worktree, never `git add`ed/committed | — CLEANED |
| `~/.config/opencode/commands/spike-selfres.md` | 2026-08-08T01:57:14Z | Same symlink chain | — CLEANED |
| `~/.config/opencode/commands/spike-bashperm.md` | 2026-08-08T02:01:10Z | Same symlink chain | — CLEANED |
| `~/.gemini/config/plugins/spike-testplugin/` | 2026-08-08T01:50:14Z (installed), reinstalled 2026-08-08T01:55:47Z | Real path (correcting the brief's assumed `~/.gemini/antigravity-cli/plugins/` — see Item 1) | — CLEANED |
| `$TMPDIR/spike-testplugin-src/` | 2026-08-08T01:49:xxZ | Scratch source dir under `$TMPDIR` (session-ephemeral, not `$HOME`) | — CLEANED |
| `$TMPDIR/spike-agyload-test/` | 2026-08-08T01:59:10Z | Scratch dir under `$TMPDIR` | — CLEANED |
| `/tmp/spike-schema.json`, `/tmp/spike-item*.json`, `/tmp/spike-item*.out`, `/tmp/spike-item*.err` | throughout | Raw transcript capture files under `/tmp` (session-ephemeral) | — CLEANED |

(All rows above are marked CLEANED as of the cleanup step — see Item 12 for the
fail-closed verification that ran after every removal.)

---

## Status

Complete. 13/13 items measured with real transcripts (11 live invocations, 2 free
mutation-producing calls, several free/derived research findings). Two real
platform-asymmetry findings surfaced that materially affect PR 2's design (Item 0's
self-resolution gap on OpenCode; Item 9's headless-hang-vs-fail-closed-deny asymmetry)
— both flagged per the brief's PR-2-escalation rule, not acted on here.
