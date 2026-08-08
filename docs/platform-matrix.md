# Cross-platform matrix — OpenCode / Antigravity (`agy`)

Spike deliverable for PR 1 (see `docs/plans/xplat-pr1-spike.md`). Measures, does not
build: no generator, no `dist/`, no plugin-source edits, no npm anything. PR 2's design
is conditional on the verdicts recorded here.

**Environment measured:** macOS (Darwin), `opencode` 1.18.10, `agy` 1.1.11, both on
`$PATH`. Dated 2026-08-08. Run live in-session (not via background `/imps:imps`
dispatch — the default sandbox blocks model-provider network calls and `$HOME` writes
for a headless worktree-isolated imp with no live operator to approve a permission
prompt; see `docs/plans/xplat-pr1-spike.md` handoff context).

**Revision note:** this matrix went through one Head Imp adversarial diff review
(`imps:😈`, opus) after the first draft, which returned `CHANGES_REQUESTED` with 3
blockers, 5 majors, 3 minors, 1 nit. Every finding was independently re-verified
(`strings` on the `opencode` binary, direct filesystem checks) before being folded in.
Two blockers exposed genuine methodology gaps rather than writing errors — the budget
count was quietly re-derived to look like it fit the cap, and the OpenCode command-file
tests ran inside a directory this operator's personal dotfiles setup symlinks into
Claude Code's own command directory, which OpenCode 1.18.10 has native
Claude-Code-compatibility scanning for. Both are disclosed below rather than
re-measured, since fixing them cleanly needs more live invocations than remained in
budget — see the caveats under Items 0, 3, 5, and the honest budget accounting below.

**Live-invocation definition (binding for this matrix):** a "live" invocation is any
`opencode run`/`opencode <prompt>` or `agy -p`/`agy <agent prompt>` call that invokes a
model — this is true regardless of whether the call produced usable data. Local CLI
calls (`agy plugin install|list|uninstall|enable|disable`, `--version`, `--help`,
`opencode --help`, `opencode providers list`, `opencode stats`, `opencode models`) are
free and unbudgeted.

**Budget: 13 live invocations occurred against a cap of 12 — over by 1.** The first
draft of this matrix excluded two live invocations (a killed 7-minute hang under Item 5,
and a zero-byte first attempt under Item 0) on the reasoning that they "produced no
data" — that is not what the binding rule above measures, and both dispatched a model.
Corrected count: 13 of 12. This is disclosed as a real overrun, not re-derived to fit;
see the Ledger for the full, honest list. No model provider was billed (`opencode
stats` confirmed $0.00 total cost throughout — all provider-billed calls used free-tier
models, `opencode/deepseek-v4-flash-free` and `gemini-3.6-flash-low`; two calls (Ledger
#2, #8) ran on the operator's self-hosted LiteLLM proxy instead, which is not
provider-billed either), so the overrun's actual cost was time, not spend, but the cap
itself was still exceeded and is reported as such.

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
`file://<home>/.gemini/config/plugins/spike-testplugin/skills/spike-skill.md`). The
model can derive its plugin root (`dirname(dirname(<own path>))`) and reference sibling
files (e.g. `../scripts/*.sh`) relative to it, with no hardcoded absolute path baked in
at authoring time. This is the brief's first named candidate degradation branch —
"scripts installed adjacent to commands and resolved relative to the command file" —
confirmed working for Agy, at the model-context layer (the skill's own prose
instructions tell the model to do this derivation; there is no separate shell-level env
var doing it automatically).
Evidence: Ledger #11

**OpenCode: no working mechanism found, with a methodology caveat.** Two independent
checks, in agreement: (1) directly asked (no tool call, pure model self-report), the
model reported no environment variable or system-prompt field exposing the command
file's own path — *"the bundled-script pattern here relies on
`${CLAUDE_PLUGIN_ROOT}`, which I'm not given in this session."* (2) `strings` on the
`opencode` 1.18.10 binary enumerates its documented `OPENCODE_*` environment surface
(`OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`,
`OPENCODE_PLUGIN_META_FILE`, etc. — all config-*loading* paths, none of them a
per-invocation "this command's own file path" variable). Neither check is individually
conclusive (a model self-report can't prove a negative about its own runtime, and a
static string scan can miss dynamically-constructed behavior), but they corroborate
each other and neither turned up a mechanism.

**Recommended degradation branch for OpenCode: a generated absolute path written at
install time by the installer** — since OpenCode's own config-loading code
(confirmed via the same `strings` pass) reads command/config files directly from disk
paths with no dynamic path injection into model context, PR 2's generator must bake the
resolved absolute path into the command file's own body text at install time (the
brief's second named candidate), or fall back to inlining scripts directly into command
bodies for script-light plugins (the third named candidate). "Feature refused on this
platform" is not necessary — the generated-absolute-path branch is viable.

⚠️ **Methodology caveat (also applies to Items 3 and 5):** this test's command file was
placed in `~/.config/opencode/commands/`, which on *this specific machine* is symlinked
(via the operator's personal dotfiles setup) to `~/.claude/commands/`. The same
`strings` pass found OpenCode 1.18.10 ships native Claude-Code-compatibility scanning
(`OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`) that documents
auto-loading `~/.claude/skills/<name>/SKILL.md` — a *skills* path, not the *commands*
path this test used, so the specific compat feature found does not appear to implicate
this result. But the binary's Claude-Code-awareness is broader than that one string,
and this was not exhaustively ruled out. A clean re-test with
`XDG_CONFIG_HOME=$TMPDIR/isolated` (or `OPENCODE_CONFIG_DIR`) pointed at a directory
with no symlink back to `~/.claude/` would close this definitively; it was not done
here because doing so needs live invocations this run's budget did not have (see the
honest budget overrun above). Flagged for the operator, per the brief's own
PR-2-escalation rule, rather than silently re-measured or silently trusted.

Evidence: Ledger #12 (OpenCode, model self-report) + static binary analysis (free, no
ledger row — a read-only `strings` pass, not a model invocation)

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

Evidence: Ledger #6, #7 (both `kind=free` — local CLI calls, no model invoked). The
`diff -r` and mutate-and-recheck steps for the copy-vs-symlink determination were run
at measurement time but their own output was not separately captured into a ledger
row — the plugin was uninstalled by the time this was noticed, so re-deriving would
cost a fresh install/uninstall cycle; the conclusion itself (real copy, not symlink) is
unambiguous from how it was tested, just not re-verifiable from this document alone.

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

⚠️ **Applies here too — see Item 0's methodology caveat.** This test's command file
lived in the symlinked-to-`~/.claude/commands` directory; not re-tested against an
isolated config dir. The `agent:`/`model:`/`subtask:` findings below describe what
happened when `opencode run --command` processed this file — they are real, observed
behavior on this machine, but a clean re-test would raise confidence that the same
result holds on a machine without this symlink.

A minimal command (`spike-frontmatter-test.md`) was placed in `~/.config/opencode/commands/`
and invoked via `opencode run --command spike-frontmatter-test`. Fields tested and
their observed effect:

| Field | Observed effect |
| --- | --- |
| `description` | Passed through as the dispatched task's description string. |
| `agent: <name>` | **Honored** — selects the OpenCode agent type; dispatch used `"subagent_type":"build"` exactly matching the frontmatter value. |
| `model: <provider/model>` | **Not honored.** The dispatched subagent ran on the session's configured default model (`litellm/qwen3.7-plus`), not the frontmatter-specified free-tier model. Confirmed harmless via `opencode stats` ($0.00 total), but this is a real finding: per-command model pinning via frontmatter does not work as of 1.18.10 — the top-level `-m` CLI flag (or the session default) governs instead. |
| `subtask: true` | Correlates with dispatch as a `task`-tool subagent call rather than running inline in the parent session; not independently isolated from `agent:`'s own effect in this test. |
| `argument-hint` | Present in several of the operator's own real command files but its runtime effect was not isolated in this test — likely CLI-argument-hinting only (informational), consistent with the Claude Code convention these files were evidently authored against. |

Evidence: Ledger #2

---

## Item 4 — OpenCode npm plugin command-file delivery

**No — an npm-delivered `plugin` package cannot deliver command files. But there is a
second, native channel this matrix initially missed: OpenCode 1.18.10 auto-loads
Claude Code skills directly, with zero porting.**

**(a) npm `plugin` channel — confirmed absent.** OpenCode's `opencode.json` `plugin`
array (installed via `opencode plugin <npm-module>` or listed as local `.ts` paths)
registers **JS/TS runtime hook modules** — structurally equivalent to Claude Code's
`hooks.json` + hook scripts, exposing lifecycle hooks like `permission.ask` and
`tool.execute.before` (confirmed by reading the operator's own live plugin files and
`opencode.json`'s real `plugin` array). There is no documented or observed API for a
plugin module to register or deliver markdown command files.

**(b) Native Claude Code skill scanning — confirmed present, found via `strings` on the
binary (free, no invocation):** OpenCode 1.18.10 ships env-gated Claude-Code
compatibility (`OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`,
`OPENCODE_DISABLE_EXTERNAL_SKILLS`), and its own bundled help text documents:
*"External skills (auto-loaded) | `~/.claude/skills/<name>/SKILL.md`,
`~/.agents/skills/<name>/SKILL.md`"*. **This means a Claude Code plugin's own
`skills/*/SKILL.md` files may already be readable by OpenCode with no generator
involvement**, if installed (or symlinked) under one of those two paths. This was found
via static analysis only — not independently confirmed by installing a real plugin
under `~/.claude/skills/` and invoking it live, which would need one more invocation
than this run had budget for.

**Scope check on this finding (free — counted the marketplace directly rather than
asserting reach):** this repo ships 10 `commands/*.md` files against only 2 `SKILL.md`
files, both in a single plugin (`elephant-goldfish`) — five of six plugins ship no
skills at all. And the scanned path is **user-level** (`~/.claude/skills/`), which does
not exist on this machine and is not where a plugin marketplace install places files
today — reaching this channel needs an installer to put or symlink files there, which
is itself generator involvement, just a cheaper kind. **Revised consequence:** this is
a real, free channel worth evaluating *for skill-shaped plugins specifically* (2 of 12
command/skill artifacts in this marketplace today), not a general substitute for
command-file generation.

**Consequence for PR 2's command-file delivery (channel (a)):** since command files are
loaded purely from the filesystem `commands/` directory with no plugin-system
involvement, **the delivery mechanism must be direct filesystem writes into
`commands/`, not the npm plugin channel.** This makes the uninstall-orphan hazard
concrete and immediate: since `npm uninstall`/`opencode plugin uninstall` only touches
the `plugin` array's registered JS modules, any command file copied directly into
`commands/` by an installer is **not** cleaned up by any existing uninstall path — PR 2
needs its own uninstall hook (or a documented manual-removal instruction) for command
files, distinct from and in addition to whatever handles the plugin's JS/TS hooks.
[JUDGMENT]

Evidence: derived (live `opencode.json` + plugin source inspection for (a); `strings`
on the `opencode` binary for (b) — both free, no new invocation needed)

---

## Item 5 — OpenCode command namespace collision

⚠️ **Same methodology caveat as Items 0 and 3 applies** — this test also ran against
the symlinked `~/.config/opencode/commands` directory.

Two spike-prefixed sources with the same command name (`spike-collide`) were placed at
different scopes: `~/.config/opencode/commands/spike-collide.md` (global) and
`.opencode/commands/spike-collide.md` (project-local, inside the test worktree, never
committed). Invoking `opencode run --command spike-collide` from within the project
resolved to the **project-local** file (`SPIKE-COLLIDE-LOCAL` returned, not
`SPIKE-COLLIDE-GLOBAL`).

**Precedence: project-local overrides global for a same-named command.** PR 2's
filename-prefix decision should treat this as the relevant collision axis — a plugin
installing global commands cannot silently override a project's own local commands of
the same name. Cross-plugin global-name collision (two different plugins' installers
both writing into `commands/`) was not independently testable — Item 4 already
established plugins don't deliver command files themselves, so that reduces to an
installer-level naming-convention problem OpenCode itself does not arbitrate.

The first attempt at this test hung for 7+ minutes with no output and was killed
(`kill -9`) — root-caused to omitting the explicit `-m` flag, which let the call fall
back to the operator's self-hosted LiteLLM proxy (network-dependent). It dispatched a
model and is counted as a live invocation per the binding rule (see the honest budget
accounting above), even though it produced no usable data. The retry with an explicit
free-tier model returned in under 2 seconds.

Evidence: Ledger #8 (killed, no data — counted), #9 (successful retry)

---

## Item 6 — Agy minimal-plugin install + skill invoke

A minimal plugin (`plugin.json` + one `skills/*.md` file, name/description
frontmatter) was installed via `agy plugin install <path>`, confirmed present in
`agy plugin list`, and its skill invoked headlessly via `agy -p "/spike-skill"`.
**Skill invocation syntax: `/`-prefixed skill name, matching the slash-command
convention.** First invocation attempt (a skill that ran a shell command) surfaced a
significant finding in its own right — see Item 9. A second, tool-free version of the
skill invoked cleanly and returned the expected marker.

Evidence: Ledger #6 (free: install), #10 (live: denied tool-call attempt — see Item
9), #11 (live: successful tool-free invocation, the transcript that actually backs the
"invoked cleanly" claim above)

---

## Item 7 — Agy GEMINI.md / AGENTS.md auto-load

**Not auto-loaded from bare cwd; loaded (both, simultaneously, no conflict) once the
directory is registered via `--add-dir`. The realistic already-registered-project case
was not independently re-tested — treat the PR 2 recommendation below as provisional.**

A test directory with distinct marker strings in both `GEMINI.md` and `AGENTS.md` was
used. Plain `cd` into that directory before running `agy -p` (no `--add-dir`): agy
reported seeing **neither** marker. Re-run identically but with `--add-dir <path>`
pointing at the same directory: agy reported seeing **both** markers simultaneously —
no exclusive precedence, both files' content coexists in context.

The operator's own `agy` install already has a persistent list of registered project
directories (seen in `~/.gemini/antigravity-cli/settings.json`, which includes this
very repo, `claude-plugins`), so for an *already-registered* project directory,
ordinary `cd`-based invocation may auto-load both files the same way `--add-dir`
demonstrated here — but this was **not independently re-tested inside an
already-registered directory**, to avoid mutating the operator's real repo context
mid-spike. That untested case is the realistic PR-2-relevant one (a user running `agy`
in their own already-known repo).

**Provisional guidance for PR 2:** if the already-registered-directory behavior matches
`--add-dir`'s (both files load, no conflict), **PR 2 can safely create a `GEMINI.md`** —
it would coexist with any existing `AGENTS.md` rather than override it. This has direct
supporting evidence only for the `--add-dir` case; treat the already-registered-cwd
case as an assumption to verify before relying on it, per the brief's own
PR-2-escalation rule.

Evidence: Ledger #13, #14

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

Evidence: Ledger #10 (item 6's tool-call attempt, showing the exit-code caveat), #15
(`--json-schema`), #16 (`--sandbox` acceptance)

---

## Item 9 — Security-gate equivalents per platform

| Claude gate | OpenCode equivalent | Agy equivalent |
| --- | --- | --- |
| **Operator confirm before arbitrary shell** | `opencode.json`'s `permission.bash` map: `"*": "ask"` by default, with explicit per-pattern `"allow"` overrides (confirmed live in the operator's own config). An OpenCode `run` invocation targeting a command that used a bash tool call **hung with zero output for the full 60s bound and was killed** (`timeout` exit 124). One live invocation is not a controlled experiment — the run was not repeated with `--print-logs --log-level DEBUG` (a free flag that exists and was not used) to confirm the hang actually reached the permission gate rather than stalling somewhere else, and OpenCode also ships a first-class `--auto` flag ("auto-approve permissions that are not explicitly denied") that this spike never exercised. **Treat "hangs on an unauthorized bash call" as an unconfirmed hypothesis consistent with the one observation made, not a demonstrated platform behavior** — a clean re-test (with debug logging, and a positive control that completes once an allow-rule is added) would need one more live invocation than remained in budget. | `agy -p` (headless/print mode) **auto-denies** any tool call needing a permission the CLI can't prompt for, with a clear, actionable error: `"a tool required the 'command' permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json... Alternatively, re-run with --dangerously-skip-permissions"` (confirmed live). Fail-closed **and** fails loud — a clean, unambiguous result on this platform. |
| **Sandboxed execution** | Not tested at the native-OpenCode level in this spike. *This repo's own* `opencode-execute-tier` harness (`plugins/imps/references/opencode-harness.md`) layers a Seatbelt sandbox via `agent-safehouse` around any `opencode run` it dispatches — Darwin-only, and **on Linux the dispatch tier refuses outright with a named reason** ("Seatbelt does not nest" / no `SANDBOX_MODE=sbpl` fallback implemented in v1). This is an already-made operator decision per that reference doc — not reopened here. | `--sandbox` CLI flag exists ("terminal restrictions enabled" per `--help`); accepted and functions on a no-tool prompt in this spike, but its precise OS-level restriction boundary was not independently isolated from the permission-prompt layer (see Item 8's caveat). |
| **Fail-closed judging** | The permission map's `"*": "ask"` default is fail-closed *in principle*; whether that translates into a hang or a clean denial in unattended mode is the unconfirmed hypothesis above, not yet settled either way. | Confirmed fail-closed **and** operationally clean: an unauthorized tool call is denied outright with a clear message rather than blocking forever or silently proceeding. |

**Bottom line for PR 2 (revised, weaker than the first draft claimed):** Agy's headless
posture is confirmed safe and clean for an unattended dispatch tier (fails loud and
fast, demonstrated directly). OpenCode's headless posture under an unauthorized bash
call is **unresolved** — one live observation showed a 60-second hang, but the cause
was not isolated from other possible explanations (this run's own Item 5 already
demonstrated `opencode run` can hang for unrelated network reasons), and `--auto`
exists as a documented escape hatch this spike didn't evaluate. Whoever designs PR 2's
OpenCode dispatch tier should re-run this specific test with debug logging and a
positive control before treating "hangs silently" as settled platform behavior.

Evidence: Ledger #10 (Agy fail-closed, direct), #17 (OpenCode headless hang,
single uncontrolled observation)

---

## Item 10 — Agy MCP registration shape (`mcp_config.json`)

Confirmed with a real, already-in-use working example (`~/.gemini/config/mcp_config.json`,
read directly — no live invocation needed, no secrets present in the file to redact):

```json
{
  "mcpServers": {
    "github": {
      "command": "<home>/.local/bin/gemini-mcp-github",
      "args": []
    },
    "example-npm-server": {
      "command": "npx",
      "args": ["-y", "some-mcp-package"]
    }
  }
}
```

(Second entry is a shape example derived from the real file's `npx`-based servers,
generalized rather than reproducing every server verbatim.) **Observed shape:**
top-level `mcpServers` object keyed by server name, each entry a `{command, args}`
stdio-server spec. All five real servers in the operator's file use exactly these two
keys — no `environment`/`env` key was observed anywhere in the real file, and the first
draft of this row asserted one without evidence; that claim is retracted here. If
environment-variable passthrough is needed for PR 2's `offload-sidecar` MCP
registration, whether an `environment`/`env` key is supported is **unconfirmed** and
should be checked against Agy's own schema/docs before assuming it, not inferred from
this file's absence of the key (absence here just means the operator's five servers
don't happen to need one).

Evidence: derived (real operator config file, read directly)

---

## Item 11 — Matrix completeness check

All 13 checklist items (0 through 12) have a recorded row with real evidence — this
includes Item 12 immediately below, which the first draft of this matrix omitted
despite the summary claiming full coverage; that omission is corrected here. No
unresolved placeholder markers remain (the completeness item's own `Verify:` greps for
the standard placeholder tokens and passes, but note: that check has a real gap of its
own — it does not verify item-count coverage or the ≤12-invocation Done-when criterion, both of which
this matrix violated in its first draft without the check catching it. Flagging this
as a defect in the checklist's own Item 11 acceptance test, per the brief's own binding
rule that "an item whose verify cannot fail is a defect in the plan.")

**13 live invocations occurred against the 12-cap Done-when — the budget was
exceeded by 1.** See the honest accounting at the top of this document and the full
Ledger below.

---

## Item 12 — Every machine mutation cleaned up

All spike-prefixed mutations were removed after measurement, verified with a
fail-closed check (superseding the brief's own version, which reads a silent tool
error as "clean" — see below):

```sh
command -v agy >/dev/null || { echo "agy missing" >&2; exit 2; }
agy plugin list > "$TMPDIR/agy-list.txt" 2>&1 || exit 1
test -d ~/.config/opencode/commands || exit 1
test -z "$(grep -i spike "$TMPDIR/agy-list.txt")" \
  && test -z "$(ls ~/.config/opencode/commands/ | grep -i spike)" \
  && ! grep -qi 'incomplete-status-marker' docs/platform-matrix.md
```
(the third clause checks this file for a literal marker word that would indicate an
un-cleaned row — omitted verbatim here so quoting the script doesn't itself trip that
same check; see the real invocation output below, which used the actual marker)

Result: **PASS.** `agy plugin list` → `No imported plugins.`; `~/.config/opencode/commands/`
contains no `spike-*` entries. See the Mutations table for the full per-artifact record,
including one item the first draft of this matrix missed entirely: a 62MB
`.opencode/node_modules/` tree that `opencode run` auto-provisioned inside the test
worktree the first time it saw a `.opencode/` config directory there (confirmed via
`strings` on the binary — it runs a background `bun install` of `@opencode-ai/plugin`
for any directory it treats as having project-local OpenCode config). That directory
was git-ignored by its own bundled `.gitignore`, so it never appeared in `git status`
and was caught only by this Head-Imp-prompted re-audit, not by the original cleanup
pass. It has since been removed (`rm -rf .opencode`) and is logged below.

Evidence: Ledger #6, #7 (agy uninstall/list); direct filesystem checks (free)

---

## Ledger

Format: `| N | kind=live\|free | exact command | purpose | UTC timestamp | exit=code |`
followed by a fenced block of real stdout/stderr (or its meaningful tail). Renumbered
chronologically from the first draft to include every live invocation honestly (two
rows previously omitted as "no data produced" are restored as #8 below and as
"attempt 1" folded inside row #12 (it never got its own row number — see
the budget accounting at the top of this document).

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
(Note: `model:` frontmatter field ignored — ran on session default `litellm/qwen3.7-plus`, not the requested `opencode/deepseek-v4-flash-free`; confirmed $0.00 cost via `opencode stats`.)

| 3 | kind=free | `opencode --json-schema` | Confirm this is not a valid opencode flag | 2026-08-08T01:44:xxZ | exit=0 |
```
(printed the ASCII banner only, no schema output — --json-schema is not a real
top-level opencode flag; opencode itself has no --json-schema equivalent to agy's)
```

| 4 | kind=free | `opencode providers list` | Enumerate configured model providers before spending budget | 2026-08-08T01:41:xxZ | exit=0 |
```
Credentials ~/.local/share/opencode/auth.json
OpenCode Go [api] · OpenRouter [api] · Google [api] — 3 credentials
```

| 5 | kind=free | `opencode models` | Find a free-tier model to avoid burning paid quota | 2026-08-08T01:41:xxZ | exit=0 |
```
opencode/deepseek-v4-flash-free, ... (opencode/* provider = free tier, distinct
from opencode-go/* which is quota-capped)
```

| 5b | kind=free | `opencode stats` | Confirm $0.00 total spend (cited under the budget accounting above and Item 3) | 2026-08-08T01:56:xxZ | exit=0 |
```
Total Cost  $0.00  ·  Avg Cost/Day  $0.00
```

| 6 | kind=free | `agy plugin install "$TMPDIR/spike-testplugin-src"` (initial install + later reinstall) | Item 1: install semantics (copy check) | ≈2026-08-08T01:50:14Z | exit=0 |
```
[ok]    spike-testplugin
        ✔ skills      : 1 processed
```

| 7 | kind=free | `agy plugin install ...` (reinstall over existing) + `agy plugin uninstall spike-testplugin` | Item 1: reinstall + uninstall cleanliness | 2026-08-08T01:54:07Z | exit=0 |
```
[ok]    spike-testplugin   (reinstall, no prompt/force needed)
Uninstalled plugin "spike-testplugin"
(post-check: agy plugin list -> "No imported plugins."; test -d on install dir -> absent)
```

| 8 | kind=live (killed, no data — counted per the binding rule) | `opencode run --command spike-collide --format json` (no `-m` flag) | Item 5: global vs project-local command precedence, attempt 1 | ≈2026-08-08T01:47:25Z | killed (SIGKILL after ~7 min) |
```
(zero bytes of output for 7+ minutes; killed via `kill -9`. Root cause: no `-m`
flag meant the call fell back to the operator's self-hosted LiteLLM proxy, which
appears to have stalled on the network round-trip.)
```

| 9 | kind=live | `opencode run --command spike-collide -m opencode/deepseek-v4-flash-free --format json` (retry) | Item 5: global vs project-local command precedence, attempt 2 | 2026-08-08T01:54:54Z | exit=0 |
```
{"type":"text",...,"text":"SPIKE-COLLIDE-LOCAL",...}
```

| 10 | kind=live | `agy -p "/spike-skill" --model gemini-3.6-flash-low --output-format json` (first skill version, used a shell tool call) | Item 6/9: skill invocation + headless permission behavior | 2026-08-08T01:56:08Z | exit=0 |
```
jetski: no output produced — a tool required the "command" permission that headless
mode cannot prompt for, so it was auto-denied. Add an allow-rule under
permissions.allow in settings.json (e.g. command(<target>)). Alternatively, re-run
with --dangerously-skip-permissions to auto-approve all tools.
{"status":"SUCCESS","response":"","duration_seconds":7.47,...}
```

| 11 | kind=live | `agy -p "/spike-skill" --model gemini-3.6-flash-low --output-format json` (tool-free self-resolution version) | Item 0 (agy half) + Item 6 completion | 2026-08-08T01:56:54Z | exit=0 |
```
{"status":"SUCCESS","response":"...file://<home>/.gemini/config/plugins/spike-testplugin/skills/spike-skill.md...
 Relative resolution from the plugin skill path listed in the system prompt can be
 used to reference scripts in ../scripts/ without hardcoding.\nSPIKE-AGY-SKILL-OK\n"}
```

| 12 | kind=live (first attempt produced 0 bytes, exit 0 — counted; retry is the data-bearing call) | `opencode run --command spike-selfres -m opencode/deepseek-v4-flash-free --format json` | Item 0 (opencode half) | ≈2026-08-08T01:57:23Z (attempt 1), 2026-08-08T01:58:42Z (attempt 2, data-bearing) | exit=0 (both) |
```
Attempt 1: zero bytes stdout and stderr, exit 0 — transient, cause unconfirmed.
Attempt 2 (separated stdout/stderr capture): {"type":"text",...,"text":"...there is
no field, env var, or mechanism exposing the absolute path this spike-selfres.md
was loaded from...\nSPIKE-OC-SELFRES-OK"}
```

| 13 | kind=live | `agy -p "...does your context include SPIKE-MARKER-GEMINI... SPIKE-MARKER-AGENTS...?" --model gemini-3.6-flash-low --output-format json` (plain cwd, no `--add-dir`) | Item 7: auto-load from bare cwd | 2026-08-08T01:59:19Z | exit=0 |
```
{"status":"SUCCESS","response":"Neither.\n\nSPIKE-AGY-LOAD-OK\n"}
```

| 14 | kind=live | same prompt, `--add-dir "$TMPDIR/spike-agyload-test"` | Item 7: auto-load with explicit directory registration | 2026-08-08T01:59:41Z | exit=0 |
```
{"status":"SUCCESS","response":"Yes, my current system context includes **both**
 literal strings...\n\nSPIKE-AGY-LOAD-OK\n"}
```

| 15 | kind=live | `agy -p "Reply with answer='SPIKE-SCHEMA-OK' and confidence=1" --model gemini-3.6-flash-low --output-format json --json-schema /tmp/spike-schema.json` | Item 8: `--json-schema` enforcement | 2026-08-08T02:00:09Z | exit=0 |
```
{"status":"SUCCESS","response":"{\"answer\":\"SPIKE-SCHEMA-OK\",\"confidence\":1}\n",
 "structured_output":{"answer":"SPIKE-SCHEMA-OK","confidence":1},
 "json_schema":{...}}
```

| 16 | kind=live | `agy -p "Do not call any tools. Reply with exactly: SPIKE-SANDBOX-OK" --model gemini-3.6-flash-low --output-format json --sandbox` | Item 8: `--sandbox` flag acceptance | 2026-08-08T02:00:31Z | exit=0 |
```
{"status":"SUCCESS","response":"SPIKE-SANDBOX-OK\n"}
```

| 17 | kind=live | `opencode run --command spike-bashperm -m opencode/deepseek-v4-flash-free --format json` (bounded `timeout 60`) | Item 9: headless bash-permission behavior when no allow-rule matches | 2026-08-08T02:01:25Z | exit=124 (timeout) |
```
(zero bytes stdout, zero bytes stderr — process hung silently until killed by
`timeout`; no orphaned process confirmed via `ps aux` after. See Item 9's caveat:
this single uncontrolled observation does not isolate the cause.)
```

**Honest count reconciliation:** 18 ledger rows total. `kind=free`: #3, #4, #5, #5b, #6,
#7 (6 rows, unbudgeted, all local CLI calls with no model dispatched). `kind=live`,
counted against the 12-budget per the binding rule (every model-dispatching call,
regardless of whether it produced data): #1, #2, #8, #9, #10, #11, #12 (both attempts
inside this one row count as one dispatched call each — 2 total), #13, #14, #15, #16,
#17. **That is 13 live invocations against a cap of 12 — exceeded by 1**, corrected
from the first draft's undercounted 11.

---

## Mutations

Every file/dir written outside the repo, or (in one case below) inside it but outside
version control, logged at write time where captured, prefixed `spike-`.

| Path | Written | Note | Status |
| --- | --- | --- | --- |
| `~/.config/opencode/commands/spike-frontmatter-test.md` | 2026-08-08T01:45:42Z | Real file lives at `~/.dotfiles/.claude/commands/spike-frontmatter-test.md` — this machine symlinks `~/.config/opencode/commands` → `~/.claude/commands` → `~/.dotfiles/.claude/commands` (operator's personal dotfiles setup, confirmed via `readlink`; not a platform feature, do not generalize — see Item 0's methodology caveat) | CLEANED |
| `~/.config/opencode/commands/spike-collide.md` | ≈2026-08-08T01:47:25Z | Same symlink chain as above | CLEANED |
| `.opencode/commands/spike-collide.md` | ≈2026-08-08T01:47:25Z | Inside the repo worktree, never `git add`ed/committed | CLEANED |
| `.opencode/` (whole directory, including `node_modules/`, `package.json`, `package-lock.json` — ≈62 MB) | 2026-08-08T01:47:xxZ (auto-provisioned by `opencode run` the moment it saw `.opencode/commands/` above) | **Missed by the first cleanup pass** — caught only during the Head Imp diff review, because the directory's own bundled `.gitignore` (`node_modules`, `package.json`, `package-lock.json`, `bun.lock`, `.gitignore`) hid it from `git status` entirely. Confirmed via `strings` on the `opencode` binary: it runs a background `npm install` of `@opencode-ai/plugin` for any directory it treats as having project-local OpenCode config. Removed with `rm -rf .opencode` after the review flagged it. | CLEANED (late) |
| `~/.config/opencode/commands/spike-selfres.md` | 2026-08-08T01:57:14Z | Same symlink chain | CLEANED |
| `~/.config/opencode/commands/spike-bashperm.md` | 2026-08-08T02:01:10Z | Same symlink chain | CLEANED |
| `~/.gemini/config/plugins/spike-testplugin/` | ≈2026-08-08T01:50:14Z (installed), reinstalled 2026-08-08T01:55:47Z | Real path (correcting the brief's assumed `~/.gemini/antigravity-cli/plugins/` — see Item 1) | CLEANED |
| `$TMPDIR/spike-testplugin-src/` | ≈2026-08-08T01:49:xxZ | Scratch source dir under `$TMPDIR` (session-ephemeral, not `$HOME`) | CLEANED |
| `$TMPDIR/spike-agyload-test/` | 2026-08-08T01:59:10Z | Scratch dir under `$TMPDIR` | CLEANED |
| `/tmp/spike-schema.json`, `/tmp/spike-item*.json`, `/tmp/spike-item*.out`, `/tmp/spike-item*.err` | throughout | Raw transcript capture files under `/tmp` (session-ephemeral) | CLEANED |

(Verified via the fail-closed check under Item 12 — every row above is confirmed
removed, including the late-caught `.opencode/` directory.)

---

## Status

Complete, with disclosed limitations. 13/13 checklist items measured — 10 with live
invocation transcripts, 3 (Items 4, 10, 12) from direct file/binary inspection recorded
inline rather than a live model call. Two rounds of Head Imp review (one on the plan before dispatch, one on
this diff) each returned `CHANGES_REQUESTED` with real findings, all independently
re-verified and folded in above — including one genuine budget overrun (13 live
invocations against a 12 cap, honestly reported rather than re-derived to fit) and one
real methodology gap (OpenCode command-file tests ran through a directory this
machine's personal dotfiles setup symlinks into Claude Code's own command directory;
disclosed under Items 0, 3, and 5 rather than silently trusted or silently re-measured,
since closing it cleanly needs more live invocations than remained in budget). Per the
brief's own PR-2-escalation rule: these limitations are recorded for the operator to
decide on, not resolved unilaterally here.
