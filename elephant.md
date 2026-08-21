# claude-plugins — Elephant (design of record)
<!-- Authoritative design doc. "Design is the new code." A zero-context session re-bootstraps
     from this file alone. Last reconciled: 2026-08-08 against ce248dd (issue #131). -->

## The Problem

This repo is a **personal Claude Code plugin marketplace** by [@seankoji](https://github.com/seankoji)
(`.claude-plugin/marketplace.json:2` — marketplace `name` is `seankoji`). It packages and distributes
reusable [Claude Code](https://code.claude.com/) slash-command plugins so they can be installed across
machines with one command and kept in sync, instead of being copy-pasted into each machine's
`~/.claude/` by hand.

**Who it's for:** two distinct audiences.
- **Plugin users** — anyone who runs `claude plugin marketplace add seankoji/claude-plugins` and installs
  one or more plugins. They only ever see each plugin's slash commands and its `README.md`.
- **Marketplace maintainers** — whoever adds/edits plugins. They are governed by `AGENTS.md` (loaded by
  Claude Code for sessions *inside* this repo) and the CI in `.github/workflows/validate.yml`. Users never
  see `AGENTS.md` (`AGENTS.md:3-4`).

**What it solves:** Claude Code reads plugins from a *marketplace* — a git repo with a top-level
`marketplace.json` index pointing at self-contained plugin packages. This repo IS that marketplace. It
currently ships **6 plugins**: `elephant-goldfish`, `claude-tuneup`, `prompt-builder`, `imps`, `ape`,
`offload-sidecar` (`.claude-plugin/marketplace.json:7-45`).

## The Technical Plan

### Marketplace → plugin → command hierarchy

```
.claude-plugin/marketplace.json      # the index: name "seankoji", owner, list of 6 plugins
schemas/marketplace.schema.json      # contract for the index
schemas/plugin.schema.json           # contract for each plugin manifest
plugins/<name>/
  .claude-plugin/plugin.json         # this plugin's manifest (NO "commands" field — see below)
  commands/<cmd>.md                  # slash commands, AUTO-DISCOVERED from this dir
  scripts/*                          # bundled helpers (chmod +x for *.sh)
  personas/*.md                      # bundled briefs (imps only)
  README.md                          # user-facing docs for this plugin
README.md                            # marketplace overview + install table (one row per plugin)
AGENTS.md                            # maintainer guide (in-repo agents only)
.github/workflows/validate.yml       # CI gate
```

### Three load-bearing conventions (get these right or the marketplace breaks)

1. **Commands are auto-discovered from `commands/*.md`.** A `plugin.json` has **no** `commands` field —
   CI rejects any manifest that has one (`.github/workflows/validate.yml:23-24`). Every plugin manifest
   here omits it (e.g. `plugins/imps/.claude-plugin/plugin.json`).
2. **Invocation is always `/<plugin>:<command>`** — the plugin name namespaces every command. A file
   `plugins/imps/commands/issue-mode.md` is invoked `/imps:issue-mode`; `plugins/elephant-goldfish/commands/elephant.md`
   is `/elephant-goldfish:elephant`. The command *file stem* is the command name; a nested file (e.g.
   `plugins/imps/commands/issue-mode.md`) becomes `/imps:issue-mode`.
3. **Marketplace `name` vs git `source` are different identifiers.** You **ADD** the marketplace by its
   **git source** (`claude plugin marketplace add seankoji/claude-plugins`), but you **INSTALL** a plugin
   by `<plugin>@<marketplace-name>` (`claude plugin install imps@seankoji`). The `@seankoji` suffix is the
   `name` field in `marketplace.json:2`, *not* the GitHub path (`README.md:18-30`).

### The `${CLAUDE_PLUGIN_ROOT}` vs `~/.claude/` runtime boundary

This is the single most important architectural rule for the bundled-asset plugins:

- **Bundled assets** (scripts, persona briefs) ship inside the plugin and self-locate via the
  `${CLAUDE_PLUGIN_ROOT}` env var that Claude Code sets to the installed plugin's directory. Commands
  reference assets as `${CLAUDE_PLUGIN_ROOT}/scripts/...` — never a hardcoded `~/.claude/` path. This is an
  enforced invariant (`AGENTS.md:38-39`) and CI fails the build if a `commands/*.md` file hardcodes a
  bundled-asset `~/.claude/` path (`.github/workflows/validate.yml:48-58`).
- **Runtime state** (logs, run state, learnings) is written *outside* the plugin, under the user's
  `~/.claude/`. It is created on first run, is **not** bundled, and is per-user/per-project. Example: imps
  writes `~/.claude/imps/runs/<slug>.json` (`plugins/imps/README.md:106-114`); claude-tuneup writes
  `~/.claude/claude-tuneup.notes.md`; prompt-builder reads `~/.claude/prompt-builder/learnings.md`.

Mnemonic: **read from `${CLAUDE_PLUGIN_ROOT}`, write to `~/.claude/`.**

### Component list (one line each, with owning path)

| Component | Role | Owned by |
|---|---|---|
| Marketplace index | Lists the 6 plugins; defines the `seankoji` name | `.claude-plugin/marketplace.json` |
| Marketplace schema | Draft-07 contract for the index (requires name/owner/plugins) | `schemas/marketplace.schema.json` |
| Plugin schema | Draft-07 contract for each manifest (8 required fields) | `schemas/plugin.schema.json` |
| Maintainer guide | Layout, add-a-plugin checklist, invariants | `AGENTS.md` |
| Marketplace README | User-facing overview + install instructions | `README.md` |
| CI validator | 5-check gate on every push/PR | `.github/workflows/validate.yml` |
| elephant-goldfish | Self-validating design-doc generator + Gemini judge | `plugins/elephant-goldfish/` |
| claude-tuneup | Permission audit + settings tuneup | `plugins/claude-tuneup/` |
| prompt-builder | Iterative prompt-engineering assistant | `plugins/prompt-builder/` |
| imps | Swarm orchestrator (parallel model-routed agents) | `plugins/imps/` |
| ape | OSS-repo foraging for transferable techniques, run as a Workflow script | `plugins/ape/` |
| offload-sidecar | MCP file-transform/vision offload to local Ollama tiers or budget-gated Gemini via agy | `plugins/offload-sidecar/` |

## Alternatives

- **One plugin per tool vs one bundled mega-plugin.** Chosen: one plugin per tool (6 separate packages
  under `plugins/`). This lets users install only what they want (`claude plugin install prompt-builder@seankoji`
  without dragging in `imps`), and keeps each plugin's manifest, README, and CI surface independent. A single
  bundled plugin would force all-or-nothing installs and couple unrelated release cadences. *(Inferred
  rationale — the per-plugin layout and per-plugin install rows in `README.md:7-12` are the evidence; the
  trade-off reasoning is inferred.)*
- **`/<plugin>:<command>` namespacing vs bare commands.** Accepted the namespaced form because it is what
  Claude Code's marketplace plugin system imposes — commands are auto-discovered and prefixed by plugin
  name. There is no bare-command option for marketplace plugins; the cost (longer invocation) is paid to get
  collision-free naming across plugins. *(Inferred — namespacing is observable in every README's usage block;
  that it is mandatory rather than chosen is inferred from the auto-discovery model.)*
- **Marketplace name `seankoji` (not `claude-plugins`).** The marketplace `name` is `seankoji`
  (`marketplace.json:2`) even though the repo is `claude-plugins`. The Claude Code CLI rejects marketplace
  names containing the substring "claude", so the repo name could not be reused as the marketplace name;
  the owner handle was used instead. This is why `install <plugin>@seankoji` works but `@claude-plugins`
  would not. *(The "claude"-substring rejection is the stated reason in the task brief and is consistent with
  the divergent name; treat the exact CLI rule as inferred — it is not asserted in a repo file.)*
- **`plugin.json` carries no `commands` field vs an explicit command list.** Chosen: rely on
  auto-discovery from `commands/*.md` and actively forbid a `commands` field (CI rejects it,
  `validate.yml:23-24`). An explicit list would drift from the files on disk; auto-discovery makes the
  filesystem the single source of truth. *(Rationale inferred; the CI rejection is fact.)*
- **Fail-closed judge vs fail-open.** elephant-goldfish's judge exits non-zero (code 2) on empty/unreachable
  output rather than treating "no gaps found" as a pass — an empty judge response must never certify a doc
  (`plugins/elephant-goldfish/scripts/goldfish-judge.sh:64-72,164-167`). Stated invariant: "Fail-closed beats
  fail-open everywhere" (`AGENTS.md:42`).

## Detailed Implementation

### The 6 plugins and their commands

**elephant-goldfish** — `plugins/elephant-goldfish/`
- Command: `/elephant-goldfish:elephant` (`commands/elephant.md`). A self-validating design-doc generator:
  writes/updates `elephant.md` grounded in the repo, then a **Goldfish Gate** runs a closed
  judge→patch→re-judge loop (up to 5 rounds) using a different-lineage `gemini` CLI reader
  (`commands/elephant.md:11-33`).
- Modes via argument (`commands/elephant.md:2-6,35-36,51-58`): bare = write (or just gate an existing doc)
  then run the judge loop; `check` = read-only factual-drift pass — a `model: haiku` agent verifies every
  `path`/`path:line` citation and flags undocumented additions, no writes, no judge; any other text = a
  goldfish failure report pasted back from a prior run, folded in directly.
- Bundled asset: `scripts/goldfish-judge.sh` — ONE cold comprehension pass whose primary judge is the
  `gemini` CLI, with an optional second-opinion judge via `ollama` (set `OLLAMA_MODEL`). Exit codes:
  `0`=READY (every judge that ran agrees), `10`=NOT READY (any judge disagrees), `2`=judge error/empty/no
  VERDICT line (fail-closed), `1`=usage (`scripts/goldfish-judge.sh:19-27,64-72,164-167`). Both judges get
  the doc inlined into the prompt — never file access — so no sandbox flags are needed
  (`scripts/goldfish-judge.sh:5-17`).
- Config env vars: `GEMINI_MODEL` (default `gemini-2.5-pro`), `OLLAMA_MODEL` (unset — optional second
  judge), `OLLAMA_NO_THINK` (`true`), `OLLAMA_HOST`, `JUDGE_TIMEOUT` (`180`s)
  (`scripts/goldfish-judge.sh:36-45`, `README.md:76-84`).
- Prerequisite: `gemini` CLI on PATH, pointed at a Gemini model — **not** a Claude model, or the judge
  shares the author's priors (`README.md:37-53`).

**claude-tuneup** — `plugins/claude-tuneup/`
- Command: `/claude-tuneup:claude-tuneup` (`commands/claude-tuneup.md`). Three phases: **Scan** (read last
  50 transcripts, surface allowlist candidates with count ≥ 3, classify global vs project), **Audit**
  (compare `~/.claude/settings.json` vs project `.claude/settings.json`, strip dupes / move misplaced
  entries), **Self-reflect** (append findings to `~/.claude/claude-tuneup.notes.md`) (`README.md:11-29`).
- Flags: `--scan-only`, `--audit-only`, `--dry-run`, `--no-reflect` (`README.md:58-64`).
- Bundled asset: `scripts/scan_perms.py`, invoked as `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scan_perms.py`;
  if absent, Phase 1 is skipped and the run falls back to `--audit-only` (`README.md:72`).
- Prerequisite: Claude Code only — no external tools (`README.md:33-35`).

**prompt-builder** — `plugins/prompt-builder/`
- Command: `/prompt-builder:prompt-builder [initial brief]` (`commands/prompt-builder.md`). Iterative
  prompt-engineering assistant: diagnose → structure → draft → critique → deliver → refine
  (`README.md:8-15`). PR #56 dropped the 8 acronym frameworks in favor of Anthropic's own evidence-based
  prompting techniques — none of the acronyms are evidence-based and picking between near-identical ones
  wasted time without changing output (`README.md:11`, `commands/prompt-builder.md:98-103`): XML-tag
  structuring, context/motivation, long-context layout, Chain-of-Thought, prompt chaining, few-shot
  examples, and do-vs-don't phrasing (`README.md:19-30`). Prefilling is deliberately not used — deprecated
  on current models (`README.md:31`).
- Bundled asset: `scripts/audit-log.sh` (byte-identical copy also in `imps` and `claude-tuneup`) — appends
  one structured line to `~/.claude/audit.jsonl` at session end; needs `jq` on PATH and skips itself with a
  warning (not a failure) if missing (`README.md:35`).
- Optional runtime state: `~/.claude/prompt-builder/learnings.md` read at session start, grown over time
  with a ~150-line soft cap (`README.md:37,62-68`).

**imps** — `plugins/imps/`
- Four commands, all auto-discovered from `commands/`:
  - `/imps:imps` (`commands/imps.md`) — swarm orchestrator. Three entry modes auto-detected from the
    argument: free-text task, issue-driven (`/imps 42 43 51`), checklist-file (`README.md:23-49`).
  - `/imps:issue-mode` (`commands/issue-mode.md`) — issue-driven mode (scout issues → rolling dispatch in
    isolated worktrees → holding branch → gates → persona panel → operator handoff).
  - `/imps:imp-agency` (`commands/imp-agency.md`) — whole-repo audit (purpose-first, then technical health) producing an `/imps:imps`-ready remediation plan; one wrangler subagent fans out per-dimension finders, adversarially refutes every P0/P1, runs a completeness critic, and synthesizes a checklist (`README.md:111-125`).
  - `/imps:prs` (`commands/prs.md`) — proactive PR monitor; addresses review comments, CI failures, merge
    conflicts; stops when the PR is merged/closed/48h old (`README.md:51-56`).
- Bundled assets (`README.md:96-104`): 5 persona briefs at `${CLAUDE_PLUGIN_ROOT}/personas/<slug>.md`
  (`solution-architect`, `grumpy-engineer`, `sre`, `business-analyst`, `ux-designer` — see the panel table
  at `README.md:79-85`) and a cosmetic banner `${CLAUDE_PLUGIN_ROOT}/scripts/imps-intro.py`.
- Runtime state under `~/.claude/imps/` (`README.md:106-118`): `runs/<slug>.json` (dispatch state +
  heartbeat source), `runs/<slug>.prs.json` (PR-monitor state), `learnings.md` (self-tuning `## Active
  rules`, ≤10 bullets, read at startup every run).
- Prerequisites (`README.md:58-72`): Workflow tool (degrades to sequential `Agent` calls), `gh` CLI for
  issue-driven mode, GitHub MCP (`mcp__github__*`) for PR/issue reads, the `imp` agent type (falls back to
  `general-purpose`). Optional: `CLAUDE_CDP_URL` and Claude-in-Chrome MCP for the browser review half.

**ape** — `plugins/ape/`
- Two commands: `/ape:forage [focus]` (`commands/forage.md`) — Phase 0 (fingerprint) runs as a plain
  command, then syncs the bundled `scripts/ape-forage.workflow.js` into `~/.claude/workflows/ape-forage.js`
  (a plugin can't ship a runnable Workflow directly — `.js` workflows only load from a user's own
  `~/.claude/workflows/`) and invokes it; `/ape:clean [--all]` (`commands/clean.md`) — sanctioned deletion
  of clones, keeping reports unless `--all` (`README.md:48-59`).
- The synced Workflow script runs: parallel 3-axis discovery (same domain, adjacent stack, curated
  sources) → dedupe (plain code) + one judgment-call ranking agent → clone with one automatic retry →
  parallel per-repo analysis → one synthesis agent producing `RECOMMENDATIONS.md` plus the top 2-3 picks
  returned to the caller (`README.md:5-46`).
- Bundled scripts: `scripts/init-workspace.sh`, `scripts/clone-candidates.sh`, `scripts/search-repos.sh`,
  `scripts/triage-repos.sh`, `scripts/readme-peek.sh` — each batches what would otherwise be a
  multi-command/for-loop bash block into one matchable command, since Claude Code's permission analyzer
  can't statically verify a compound block against an `allowed-tools` prefix (`README.md:54-59,97-99`).
- All artifacts land in `~/tmp/repo-research/<project-dir-name>/`: `fingerprint.md` (cached ≤30 days),
  `repos/`, `reports/*.md`, `RECOMMENDATIONS.md` (`README.md:78-79`).
- Prerequisite: `gh` CLI (discovery + cloning), the Workflow tool; `/ape:forage` dispatches a background
  run, so the command's turn ends before the expedition finishes (`README.md:81-85`).

**offload-sidecar** — `plugins/offload-sidecar/` (formerly ollama-sidecar)
- No `commands/` — this plugin ships only an MCP server (`scripts/offload_sidecar.py`, run via
  `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/offload_sidecar.py` through the plugin's `.mcp.json`) exposing one
  tool, `process_local_file`, for file transforms/digests too irregular for a fixed `jq`/Python rule.
- Reads `input_path` from disk and writes `output_path` back to disk directly — Claude exchanges only a
  path and an operation name, never file contents.
- Two operation kinds: **deterministic** (pure local Python, no model call — line/format ops plus
  `json_digest`, `xlsx_extract`) and **LLM**, routed across four tiers on two engines: `deep`/`fast`
  are local/LAN Ollama endpoints (private); `flash`/`pro` are Gemini via the Google Antigravity CLI
  (`agy`) on the operator's subscription — the only tiers with vision (`describe_image`,
  `verify_screenshot`, `pdf_to_structured`) and ~1M-token context.
- Cloud calls are budget-gated up front: sliding-window per-model call budgets plus lockout deadlines
  parsed from agy's own output live in `~/.local/state/offload-sidecar/quota.json`; an exhausted budget
  REJECTS the call before agy is spawned, with a structured error naming the local fallback.
- Every output is validated before it's written (format checks, size-ratio bounds, record-count heuristics,
  required-JSON-key checks for the digest family, known-secret-shape scans depending on operation); a
  failed validation writes to `<output_path>.rejected` and leaves the requested file untouched — never a
  false `"success"`.
- `userConfig` (prompted at install, reconfigurable later): Ollama host/model/num_ctx per local tier,
  TLS CA bundle, agy binary + flash/pro model names, and the four cloud call-budget caps
  (`plugin.json` `userConfig`).
- Prerequisite: `python3` on PATH (stdlib only). A reachable Ollama instance is needed only for
  local-tier LLM operations; the `agy` CLI (authenticated) only for the flash/pro tiers — each engine
  degrades independently with a structured error.

### Add-a-plugin checklist (cite `AGENTS.md:24-32`)

Five things must change **together** — missing one breaks the marketplace:
1. `plugins/<name>/.claude-plugin/plugin.json` — fill every required field (the 8 in `plugin.schema.json:7`).
2. `.claude-plugin/marketplace.json` — add an entry under `"plugins"` (name/source/description required).
3. Root `README.md` "Available plugins" table — add one row.
4. `plugins/<name>/README.md` — user-facing prerequisites, modes, env vars, license.
5. `chmod +x plugins/<name>/scripts/*.sh` — every shipped shell helper must be executable.

### CI checks (cite `.github/workflows/validate.yml`)

Runs on every push and PR (`validate.yml:3`). Two jobs — `validate` (15 checks across the marketplace + all 6
plugins) and `behavioral-tests` (3 test-runner steps):
1. **Marketplace manifest** — `marketplace.json` is valid JSON (`:16-19`).
2. **All plugin manifests** — each `plugins/*/.claude-plugin/plugin.json` is valid JSON, has a non-empty
   `name`, has **no** `commands` field, and has a `version` (`:21-33`).
3. **JSON Schema contracts** — marketplace and every plugin manifest validated against their draft-07
   schemas (`:35-41`).
4. **Command/agent frontmatter** — every `commands/*.md` and `agents/*.md` frontmatter block is extracted
   and validated against `schemas/command-frontmatter.schema.json` or `schemas/agent-frontmatter.schema.json`
   (`:43-76`).
5. **README presence** — every plugin has a `README.md` and is listed in the root `README.md` (`:78-87`).
6. **Name↔source consistency** — for each marketplace entry, the `source` dir exists and its manifest
   `name` matches the marketplace `name` (`:89-97`).
7. **Registration completeness** — the set of manifest names matches the set of marketplace entry names
   exactly; no extras, no omissions (`:99-103`).
8. **Version consistency** — `marketplace.json` version matches each `plugin.json` version; on PRs,
   changed plugin files require a version bump (`:105-142`).
9. **Scripts executable** — every git-tracked `plugins/**/*.sh` and `plugins/**/*.py` has mode `100755`
   (`:144-152`).
10. **Shellcheck** — all `.sh` scripts pass shellcheck at severity ≥ warning (`:154-156`).
11. **Node/Python syntax** — all `.js` Workflow scripts pass `node --check`, all `.py` scripts pass
    `python3 -m py_compile` (`:158-173`).
12. **Contract-name agreement** (imps only) — ruling vocabulary and section names are consistent across
    `imps-run.workflow.js`, `imps.md`, and `imp-agency.md` (`:175-219`).
13. **Bundled-asset path hygiene** — no hardcoded `~/.claude/` paths referencing bundled assets in any
    `plugins/*/commands/*.md` — use `CLAUDE_PLUGIN_ROOT` instead (`:221-256`).
14. **Behavioral tests** — `tests/run.sh`, `tests/run-python.sh`, `tests/run-js.sh` (`:258-270`).

Local pre-commit check (`AGENTS.md:48-52`):
```bash
jq . .claude-plugin/marketplace.json && for f in plugins/*/.claude-plugin/plugin.json; do jq -e '.name' "$f"; done
grep -rn --include="*.md" 'CLAUDE_PLUGIN_ROOT' plugins/*/commands/ | head
```

### Schemas

- `schemas/marketplace.schema.json` — draft-07; requires `name`, `owner` (`{name, url}`), and `plugins[]`
  (each requires `name`, `source`, `description`).
- `schemas/plugin.schema.json` — draft-07; requires `name`, `version`, `description`, `author` (`{name,
  url}`), `homepage`, `repository`, `license`, `keywords` (≥1) (`plugin.schema.json:7`). All six manifests
  satisfy this.

### Install / usage (cite `README.md:16-30`)

```bash
claude plugin marketplace add seankoji/claude-plugins          # add the marketplace (one-time, by git source)
claude plugin install elephant-goldfish@seankoji               # install a plugin (by marketplace name)
claude plugin install elephant-goldfish@seankoji --scope project   # project-scoped (shared via .claude/)
claude plugin marketplace update                               # keep up to date
```
Then invoke any command as `/<plugin>:<command>`, e.g. `/imps:prs` or `/prompt-builder:prompt-builder`.

## Open questions / unverified

- The exact Claude Code CLI rule that a marketplace `name` may not contain the substring "claude" is taken
  from the design brief, not asserted in any repo file. The divergence between repo name `claude-plugins`
  and marketplace name `seankoji` (`marketplace.json:2`) is consistent with it, but the rule itself is
  unverified from the tree.
- Default branch is documented as `master` in `AGENTS.md:6`. This worktree's HEAD is detached at `a805f23`;
  branch naming was not independently re-verified.

---
*Refresh: `/elephant-goldfish:elephant` (gate an existing doc) · `reconcile` (drift) · `regenerate` (rebuild)*
