# Maintaining claude-plugins

Extended maintainer prose that doesn't fit the budget-capped `CLAUDE.md` (≤200 lines) or
`AGENTS.md` (≤300 lines). Those two files carry the load-bearing core — the add-a-plugin
checklist, invariants, and audit-log schema, verbatim-identical between them inside
`<!-- BEGIN SHARED-MAINTAINER-BLOCK -->` / `<!-- END SHARED-MAINTAINER-BLOCK -->` markers
— and point here for depth. This file has no line budget and is not auto-loaded by any
agent runtime; read it deliberately.

Every platform-behavior claim below cites `docs/platform-matrix.md`, including its
`## PR 2 re-verification` section. If you need a platform fact this file doesn't cite,
check the matrix yourself before trusting prose — don't extrapolate.

---

## Cross-platform generator

`plugins/*/commands/`, `plugins/*/agents/`, `plugins/*/scripts/` drive Claude Code
behavior directly and are also the generator's input. `build/generate.py` (Python 3,
stdlib only) derives OpenCode and Agy artifacts from those sources plus
`build/platform-table.json` (the single Claude-term → platform-term mapping) and
`build/overrides/<plugin>/` (irreducible prose differences as section-replacement
blocks). Output lands in committed `dist/` — `dist/opencode/` and `dist/agy/<plugin>/` —
and is never hand-edited; a maintainer edits the sources or the override blocks and
reruns the generator, committing the regenerated `dist/` alongside the source change in
the same, dedicated regeneration commit.

Editing Claude sources is normal, ongoing plugin development, not something this build
freezes forever — only within a single generator run does the generator itself leave
them untouched. What CI enforces on every push/PR is `build/dist-lint.sh`'s `regen-diff`
check: that committed `dist/` is exactly what `generate.py` produces from the current
sources. A separate, narrower invariant — that a *specific* change left
`plugins/*/{commands,agents,scripts}` byte-identical to a prior state — is available via
`build/dist-lint.sh --check-frozen-sources`, but it is opt-in and point-in-time (it diffs
against `origin/master`, which moves with every merge) rather than a standing CI gate;
see `docs/plans/cross-platform-compat.md` for how and when to run it, and
`build/dist-lint.sh`'s own `--help` and comments for the three narrow, explicitly-named
exceptions it allows (two comment-only platform-assumption headers, plus the
`SERVER_VERSION`-only line `version-bump.yml` rewrites — see AGENTS.md's "Cross-plugin
audit log" section).

`build/dist-lint.sh` is the mechanical gate on generated output (the reviewer diff
excludes `dist/` itself), including a self-test that the shared maintainer block stays
identical between `CLAUDE.md` and `AGENTS.md`. `.github/workflows/validate.yml`
regenerates on `ubuntu-latest` and fails on drift — that doubles as the cross-machine
determinism check, since the generator must produce byte-identical output regardless of
host.

## Install paths per platform

| Platform | Mechanism |
| --- | --- |
| Claude Code | `.claude-plugin/marketplace.json` — unchanged by this work |
| OpenCode | npm package; `postinstall` runs the installer, plus a `bin` CLI (`install`/`uninstall`/`doctor`) so a `--ignore-scripts` install is still completable and detectable. Published manually via `workflow_dispatch` — this repo carries no git tags |
| Agy | `git clone` + `install-agy.sh` → `agy plugin install dist/agy/<plugin>` per plugin; `--uninstall` reverses it |

Both installers default to installing from `master`, accept `--ref <branch|tag|sha>`, and
record the installed commit SHA plus every written path in a manifest, so re-running
updates in place. `agy plugin install` performs a real directory copy, not a symlink —
confirmed twice (a source mutation after install did not propagate to the installed
copy, and a same-named reinstall silently overwrote at exit 0); see
`docs/platform-matrix.md` Item 1 and `## PR 2 re-verification`, token
`AGY_INSTALL_MODE: copy`. That is what makes "reinstall to update" a valid story for the
Agy install path.

Agy's real install root is `~/.gemini/config/plugins/<name>/` (not
`~/.gemini/antigravity-cli/plugins/`, which the original brief assumed), registered in
`~/.gemini/config/import_manifest.json`.

## Placeholders and machine paths

Generated artifacts under `dist/` carry a literal `__PLUGIN_ROOT__` placeholder, never a
resolved absolute path — OpenCode has no plugin-root injection mechanism of its own
(`docs/platform-matrix.md` Item 0: confirmed absent via a binary `strings` scan). Each
installer substitutes the placeholder with the resolved absolute path into the installed
copy only, on the user's machine, and the substitution is idempotent — re-running the
installer reproduces the same result and the manifest records what was written.
Relocating an install requires re-running the installer; there is no in-place move.

## Frontmatter and model tiers on OpenCode

Generated OpenCode command files never carry `model:` frontmatter — `docs/platform-matrix.md`
Item 3 measured that Claude Code's `model:` convention is silently ignored (the dispatched
subagent ran on the session's configured default model instead). That measurement is
narrower than "OpenCode has no per-command model pinning at all" — no differently-named
field was tested — so treat "no `model:`" as the safe, measured default, not a claim that
no equivalent exists. Model tiers are instead passed at invocation time by the dispatch
backend (`opencode run -m <model>`).

## Agy dispatch: check response content, not exit status

The Agy backend inspects `response` content, never exit code or `status` alone —
`docs/platform-matrix.md` Item 8 measured that a permission-denied `agy -p` run still
returns `EXIT=0` and `"status":"SUCCESS"` with an empty `response`. Treating that as a
successful run would silently swallow every permission refusal.

## Env passthrough for MCP servers

Agy's MCP server config uses the key `environment`, not `env` — confirmed via a
`strings` pass over the `agy` binary matching the exact struct field names
(`mcpServers`, `command`, `args`, `environment`, `headers`, `timeout`). See
`docs/platform-matrix.md`, `## PR 2 re-verification`, token
`ENV_PASSTHROUGH: supported:environment`. This is static-binary evidence, not a live
round-trip confirmation — `plugins/offload-sidecar/README.md`'s Agy example should use
`environment` and say so.

## The OpenCode-reads-Claude-skills channel (documented, not built)

OpenCode 1.18.10 ships native, env-gated Claude Code compatibility scanning — found via
a `strings` pass over the binary, not a live invocation — controlled by
`OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`, and
`OPENCODE_DISABLE_EXTERNAL_SKILLS`. Its own bundled help text documents auto-loading
external skills from `~/.claude/skills/<name>/SKILL.md` and
`~/.agents/skills/<name>/SKILL.md`. See `docs/platform-matrix.md` Item 4(b).

This is a **skills** path, distinct from the **commands** delivery problem this PR's
generator solves — an npm-delivered OpenCode `plugin` package cannot deliver markdown
command files at all (Item 4(a), confirmed absent), which is why command-file delivery
still needs the generator + installer path documented above.

This repo ships exactly two `SKILL.md` files, both in `elephant-goldfish` (five of six
plugins ship no skills at all). If either of those files ends up placed or symlinked
under a user's `~/.claude/skills/<name>/` or `~/.agents/skills/<name>/`, OpenCode should
pick them up with zero porting and no generator involvement, per the binary's own
documented behavior. **This channel is recorded here as a known free capability only.
No second delivery channel is being built for it in this PR** — reaching it still
requires an installer (or a manual symlink) to place files under one of those two paths,
which nothing in `build/` or `install-agy.sh` does today, and the finding itself was
never independently confirmed by installing a real plugin under `~/.claude/skills/` and
invoking it live (budget-constrained — see the matrix's own caveat on Item 4). Treat it
as a future-work candidate, not a shipped feature.

## GEMINI.md and Agy's auto-load caveat

Agy does not auto-load `AGENTS.md` or `GEMINI.md` from the working directory under
ordinary invocation, even inside a registered `trustedWorkspaces` entry — only
`--add-dir <path>` loads either file. Measured twice in
`docs/platform-matrix.md`, `## PR 2 re-verification`, token
`AGY_REGISTERED_AUTOLOAD: neither`: once inside a subdirectory of the trusted workspace,
once at the exact registered workspace path. Consequence: this repo intentionally does
not ship a `GEMINI.md`. Repo-root instruction files reach Agy only when a maintainer or
tooling explicitly passes `--add-dir` — don't assume ordinary `agy -p` picks them up.

## Versioning

`dist/` embeds no per-plugin version — Agy's generated `plugin.json` carries `name` and
`description` only, never `version` — so `version-bump.yml` (the sole writer of
`plugin.json`/`marketplace.json` for Claude Code releases) can never desync generated
output. The npm package version is hand-maintained in `build/npm/package.json` and
generated as-is into `dist/opencode/package.json`; never hand-edit the generated copy.
Publishing is manual-only, via `workflow_dispatch` on `release.yml` — this repo carries
no git tags, so there is no tag-triggered publish path to accidentally wire up.

## OpenCode's headless bash gate — a known unknown

`docs/platform-matrix.md`'s original Item 9 recorded a silent 60-second hang under an
unauthorized bash call and inferred "must refuse." The `## PR 2 re-verification` section
reran it with a positive control and found a run needing **no** permission at all hangs
identically (token `OPENCODE_BASH_GATE: unmeasured`) — the hang is environmental, not
necessarily the permission gate. The only thing this repo's generated dispatch code
treats as measured is the Darwin-only sandbox constraint (Seatbelt does not nest, so
OpenCode dispatch refuses on any non-Darwin host by design). The bash-gate hang itself
is documented in generated output as prose describing a known unknown, not as a
generated refusal branch — don't promote it to a coded gate until it's re-measured
inside a real git repository, the cheap follow-up the matrix names.
