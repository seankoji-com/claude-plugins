# GOAL — PR 2 of 2: cross-platform build (v4 — reconciled against the merged matrix)

Handoff: `/imps:imps docs/plans/cross-platform-compat.md`. Branch off `master`; one PR
to `master`. **Prerequisite:** `docs/platform-matrix.md` exists on `master` (merged in
#160). Every platform fact below cites it. A fact not in the matrix and not produced by
Phase A′ below must not be invented — stop and report instead.

## Verify convention (binding)

`Verify:` exits 0 **iff** the Done-when holds. Expect-empty is `test -z "$(...)"`;
expect-present is `grep -q`; counts are `test -ge/-eq`. `[JUDGMENT]` items run at the
**session tier** — no model pin.

---

## 0. What the matrix changed (read before touching anything)

The spike refuted five assumptions the earlier draft of this plan was built on. Each is
now a design constraint:

| Matrix finding | Consequence for this PR |
| --- | --- |
| Item 4a: an npm `plugin` package registers JS/TS hook modules **only** — it cannot deliver markdown command files | Command files are delivered by **direct filesystem writes** into the command dir. The npm package is a carrier plus an installer, not a native plugin (see npm channel below) |
| Item 0: OpenCode exposes **no** plugin-root mechanism (binary scan of `OPENCODE_*`) | Bundled-script paths are resolved **at install time** via placeholder substitution (see below) |
| Item 3: `model:` frontmatter is **not honored** on OpenCode | Generated commands must **never** carry `model:`. Model choice is invocation-time (`opencode run -m …`) and lives in the dispatch backend |
| Item 9: OpenCode headless + unauthorized bash → **silent 60s hang**, verdict *must refuse* | Refusal is **not** Linux-only. Scope is set by Phase A′ item 2 |
| Item 7 + A′: Agy loads **neither** file from cwd — re-measured in a registered `trustedWorkspaces` directory and at the exact registered path; only `--add-dir` loads them | Repo-root instruction files do nothing for Agy users. **`GEMINI.md` must NOT be created**; `AGENTS.md` cannot be relied on to reach Agy |

Also corrected: Agy installs to **`~/.gemini/config/plugins/<name>/`** (not
`~/.gemini/antigravity-cli/plugins/`), registry `~/.gemini/config/import_manifest.json`;
reinstall silently overwrites (exit 0, no force flag) and uninstall is clean —
that is the update story. `agy` skills are invoked `/`-prefixed.

Confirmed free during reconciliation (no invocation): OpenCode's bundled help documents
**both** `~/.config/opencode/command(s)/<name>.md` and `.opencode/command(s)/<name>.md`,
so the spike's plural-dir usage is officially supported and Items 3/5 are not artifacts
of this machine's `~/.claude/commands` symlink. **The repo has zero git tags** — no
release practice exists.

## Architecture (decided; do not revisit)

**Build-time generation.** Claude sources are frozen — files under
`plugins/*/commands/`, `plugins/*/agents/`, `plugins/*/scripts/` keep byte-identical
behavior. Exactly two named exceptions: (1) comment-only platform-assumption headers on
the two workflow scripts; (2) `plugins/imps/references/opencode-harness.md` — narrowing
its maintainer-checkout scoping note, because the harness is already shipped surface and
this PR makes it the default OpenCode dispatch backend. That edit changes what Claude
users read and is reviewed as such.

Generator: **`build/generate.py`, Python 3, stdlib only** (no PyYAML — frontmatter is
split on `---` delimiter lines and re-rendered from templates). Mappings in
`build/platform-table.json`; irreducible prose differences as section-replacement blocks
in `build/overrides/<plugin>/`. Output is committed `dist/`.

**Machine paths — the invariant, reconciled.** The repo's "no machine paths" rule binds
the **repo and `dist/`**: generated artifacts carry a literal `__PLUGIN_ROOT__`
placeholder, never an absolute path. The **installer** substitutes the resolved path
into the installed copy on the user's machine only. Installers are idempotent so
updates re-substitute; both document that relocating an install requires re-running it.
Lint asserts `dist/` contains no absolute paths and no unsubstituted placeholder escapes
into the repo.

**Frontmatter (OpenCode)** per Item 3: emit `description` and, where a subagent is
wanted, `agent:` (honored). **Never emit `model:`.** `argument-hint` is informational
only.

**Distribution:**

| Platform | Mechanism |
| --- | --- |
| Claude Code | marketplace.json — unchanged |
| OpenCode | npm package: `postinstall` runs the installer, **plus a `bin` CLI** (`<pkg> install|uninstall|doctor`) so a `--ignore-scripts` install is still completable and detectable. Writes are manifest-tracked; `uninstall` removes exactly what it wrote. Published **manually via `workflow_dispatch`** — there are no tags — from a hand-maintained `dist/opencode/package.json` version |
| Agy | `git clone` + `install-agy.sh` → `agy plugin install dist/agy/<plugin>` per plugin; `--uninstall` reverses it |

**Install from master, no tags.** Both installers default to `master`, accept
`--ref <branch|tag|sha>`, and record the installed commit SHA plus every written path in
a manifest (`~/.config/opencode/.seankoji-plugins-manifest.json` and the Agy equivalent).
Re-running updates.

**Dispatch tiers:** Claude = full swarm, workflow scripts untouched. OpenCode = the
oracle-loop harness as default backend; **model tiers are passed as `opencode run -m`
by the backend**, never as frontmatter; cheap tier → the configured small model, else
session model, with a documented override. Agy = serial `agy -p` (matrix Item 8:
**VIABLE**) — the backend must inspect `response` content, **not** exit code or
`status`, because a permission-denied run still returns `EXIT=0` / `"status":"SUCCESS"`
with an empty response.

**Security — fail-closed parity gates.** Agy headless is confirmed fail-closed and
fails loud (Item 9): equivalent exists on all three gates. OpenCode headless under an
unauthorized bash call **still refuses, but as a documented known unknown** — A′ ran the
positive control Item 9 lacked and refuted its basis (a run needing no permission at all
hung identically, so the hang is environmental, not the gate); the cheap follow-up is to
repeat the test inside a real git repository; the Darwin-only
sandbox means **OpenCode dispatch on Linux refuses** regardless. Installers ship or
document the OpenCode `permission.bash` allow-rules the dispatch backend needs; they
never add them silently and never pass `--dangerously-skip-permissions`.

**Generation matrix:** elephant-goldfish (proof), prompt-builder, imps, ape = full;
claude-tuneup = **excluded** (its subject is Claude's own settings);
offload-sidecar = note-only.

**Audit log:** one canonical `~/.claude/audit.jsonl` everywhere (`audit-log.sh` is
already `$HOME`-relative). **Budgets:** `CLAUDE.md` ≤ 200, `AGENTS.md` ≤ 300,
`GEMINI.md` ≤ 50; `dist/`, `build/` exempt. **Maintainer invariants stay auto-loaded:**
the core block (add-a-plugin checklist, invariants, audit-log schema) appears verbatim
in both `CLAUDE.md` and `AGENTS.md` between
`<!-- BEGIN SHARED-MAINTAINER-BLOCK -->` / `<!-- END … -->` markers, CI-diffed like the
triple-bundled `audit-log.sh`; extended prose in `docs/MAINTAINING.md`. No `@`
references between instruction files.

**Static vs behavioral:** `build/dist-lint.sh` (static) runs from
`.github/workflows/validate.yml` — `tests/run.sh`'s charter puts static checks there.
`tests/run.sh` gains only opt-in e2e gating using its existing `skip()` convention.

**Versioning:** `dist/` embeds no per-plugin versions (Agy `plugin.json` = name +
description only), so `version-bump.yml` — the sole writer of plugin.json/marketplace.json
— can never desync `dist/`. The npm package version is hand-maintained and documented.

---

## Phase A′ — close the four provisional findings (blocking)

Budget: **5 live invocations, hard cap.** Log each (command, purpose, timestamp) and
every out-of-repo mutation in `docs/platform-matrix.md` under a new
"PR 2 re-verification" section; clean up mutations and verify it. Do the free checks
first — they may remove the need for live ones. If a call fails in a way consistent
with rate limiting, STOP and report (the matrix records a prior mid-run quota death).
Never pass `--dangerously-skip-permissions`.

**Verdict tokens (binding).** A first audit of this plan found four Phase A′ gates
already green against the *merged* matrix: they grepped for words the matrix uses in the
very sentences admitting a thing was **not** measured (`positive control`, `--auto`,
`already-registered`). A gate that passes because the evidence documents its own absence
is worse than no gate. So every Phase A′ result is recorded as a machine-readable line
inside a new `## PR 2 re-verification` section appended to `docs/platform-matrix.md`,
and every verify is scoped to that section with `sed -n '/## PR 2 re-verification/,$p'`.
Prose alone never satisfies a gate. The tokens, one per line, exact spelling:

```
AGY_INSTALL_MODE: copy | symlink
ENV_PASSTHROUGH: supported:<key-name> | unsupported
AGY_REGISTERED_AUTOLOAD: both | agents-only | gemini-only | neither
OPENCODE_BASH_GATE: clean-deny | hang | auto-viable | unmeasured
LIVE_INVOCATIONS: <integer>
```

Each token still needs its transcript and reasoning written beneath it — the token is
the gate's handle, not a substitute for evidence.

- [ ] `agy plugin install` copy-vs-symlink is re-confirmed (free, ~5s) — the matrix flags this load-bearing finding as not re-verifiable from the document
      Verify: sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^AGY_INSTALL_MODE: (copy|symlink)$'
      Done when: install a throwaway plugin, mutate the source, confirm the installed copy is unaffected, uninstall; token recorded with its transcript. If `symlink`, the "reinstall to update" story is wrong and Phase C's installer design changes.

- [ ] Agy `mcp_config.json` env passthrough is answered (free first: schema/docs; live only if unavoidable) — offload-sidecar reads `os.environ.get` (`plugins/offload-sidecar/scripts/offload_sidecar.py:165`)
      Verify: sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^ENV_PASSTHROUGH: (supported:[A-Za-z_][A-Za-z0-9_]*|unsupported)$'
      Done when: recorded as supported (token carries the key name) or unsupported. If unsupported, Phase C's offload-sidecar note must say so plainly rather than ship an example that cannot carry credentials.

- [ ] Agy auto-load in an **already-registered** directory is measured — the matrix only tested bare cwd (loaded neither) and `--add-dir` (loaded both)
      Verify: sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^AGY_REGISTERED_AUTOLOAD: (both|agents-only|gemini-only|neither)$'
      Done when: an explicit verdict for the realistic case. This gates whether `GEMINI.md` (and repo-root instruction files generally) do anything for Agy users.

- [ ] OpenCode's headless bash gate is re-tested with a positive control and debug logging, and `--auto` is evaluated as an unattended posture
      Verify: sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^OPENCODE_BASH_GATE: (clean-deny|hang|auto-viable|unmeasured)$'
      Done when: the matrix records (a) whether the hang is the permission gate or an unrelated stall, (b) whether an allow-rule produces a clean run, (c) what `--auto` does — then the token. The verdict sets the refusal scope in Phase D. [JUDGMENT]

- [ ] Phase A′ mutations are cleaned up and the budget is honestly reported
      Verify: test -z "$(agy plugin list 2>/dev/null | grep -i spike)" && test -z "$(ls ~/.config/opencode/command ~/.config/opencode/commands 2>/dev/null | grep -i spike)" && sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^LIVE_INVOCATIONS: [0-9]+$'
      Done when: no spike-prefixed artifacts remain in either location and the count is recorded even if it exceeded 5.

## Phase B — generator, lint, proof plugin (Depends-on: A′)

- [ ] `build/platform-table.json` is the single mapping source and contains no machine-specific values
      Verify: python3 -c "import json;d=json.load(open('build/platform-table.json'));assert 'opencode' in d and 'agy' in d" && test -z "$(grep -iE 'deepseek|litellm|/Users/|seankoji' build/platform-table.json)"
      Done when: parses with both platforms; no concrete model names or this machine's paths.

- [ ] The generator is deterministic
      Verify: T="$(mktemp -d)" && trap 'rm -rf "$T"' EXIT && python3 build/generate.py && cp -R dist "$T/dist1" && python3 build/generate.py && diff -r "$T/dist1" dist
      Done when: two runs are byte-identical.

- [ ] `dist/` is free of absolute paths and never emits `model:` frontmatter
      Verify: test -d dist && test -z "$(grep -rE '(^|[^_[:alnum:]])/(Users|home|opt|usr/local)/|[$]HOME' dist)" && test -z "$(grep -rE '^model:' dist)"
      Done when: both expect-empty checks hold — the invariant lives here, with resolution deferred to install time.

- [ ] `build/dist-lint.sh` exists with a self-test proving each invariant catches a broken fixture — and it is the **only** mechanical gate on generated output, since the reviewer diff excludes `dist/`
      Verify: test -x build/dist-lint.sh && bash build/dist-lint.sh --self-test
      Done when: fixtures for regen-diff, unsubstituted-ref, absolute-path, manifest, budget, mirrored-block, gate-stripped, **out-of-prefix uninstall path**, **frozen Claude sources**, and **README marker vs. generation-manifest agreement** each fail when broken and pass when correct. The last three are the only enforcement their constraints get anywhere in this run. The marker check validates only READMEs that **have** a marker — a missing marker is item 32's failure, not dist-lint's, so the lint is not red in the worktrees that precede it. `dist-lint.sh` also accepts `--scope <plugin>` to lint one plugin's output.

- [ ] Claude sources are untouched except the two named exceptions
      Verify: test -d dist && test -z "$(git diff origin/master --name-only -- plugins/*/commands plugins/*/agents plugins/*/scripts | grep -vE 'imps-run\.workflow\.js|ape-forage\.workflow\.js')"
      Done when: only the two workflow scripts appear; the harness-reference edit is reviewed under its own Phase D item. [JUDGMENT]

- [ ] elephant-goldfish generates for OpenCode with placeholder-based script paths and matrix-conformant frontmatter
      Verify: test -d dist/opencode && grep -rq '__PLUGIN_ROOT__' dist/opencode && test -z "$(grep -rE '\.claude/|CLAUDE_PLUGIN_ROOT' dist/opencode | grep -v 'audit\.jsonl')"
      Done when: placeholders present, no unsubstituted Claude references beyond the canonical audit-log path.

- [ ] elephant-goldfish generates for Agy: manifest with name + description and no version field, skills with `name`/`description` frontmatter
      Verify: python3 -c "import json;d=json.load(open('dist/agy/elephant-goldfish/plugin.json'));assert d['name'] and d.get('description') and 'version' not in d" && ls dist/agy/elephant-goldfish/skills/*.md >/dev/null
      Done when: both hold.

- [ ] **[OPERATOR-RUN — not dispatchable]** The proof plugin installs and invokes on both platforms; transcripts captured for the PR body; installs cleaned up afterward
      Verify: test -s "$TMPDIR/proof-transcripts.md" && test -z "$(agy plugin list 2>/dev/null | grep -i elephant)"
      Done when: `agy plugin install` + `/`-prefixed skill invocation and `opencode run --command` both succeeded, transcripts saved, nothing left installed. [JUDGMENT]

- [ ] `build/generation-manifest.json` encodes the generation matrix with reasons for exclusions
      Verify: python3 -c "import json;d=json.load(open('build/generation-manifest.json'));assert d['claude-tuneup']['opencode']=='excluded' and d['claude-tuneup']['reason']"
      Done when: every plugin has per-platform status with a reason.

## Phase C — rollout and installers (Depends-on: B)

- [ ] prompt-builder, imps, ape generate for both platforms and pass the lint
      Verify: python3 build/generate.py ${XPLAT_ONLY:+--only "$XPLAT_ONLY"} && bash build/dist-lint.sh ${XPLAT_ONLY:+--scope "$XPLAT_ONLY"}
      Done when: exit 0. `generate.py` must accept `--only <plugin>` and `dist-lint.sh` a `--scope <plugin>` flag, so a per-plugin override task can evaluate its own work; with `XPLAT_ONLY` unset both run whole-tree, which is how the post-merge re-assertion runs it.

- [ ] Dispatch prose in generated artifacts comes from `build/overrides/` — no Claude Workflow mechanics presented as if they run there
      Verify: test -d dist/opencode && test -d dist/agy && test -z "$(grep -rlE "agent\(\)|isolation: 'worktree'" dist/opencode dist/agy)"
      Done when: expect-empty holds; remaining Workflow mentions are explicit "on Claude Code this uses…" comparisons. [JUDGMENT]

- [ ] `install-agy.sh` is executable, installs to the corrected path, is manifest-tracked, idempotent, and fails closed
      Verify: test -x install-agy.sh && bash -n install-agy.sh && grep -q 'command -v agy' install-agy.sh && grep -q -- '--uninstall' install-agy.sh && grep -q -- '--ref' install-agy.sh && ! grep -q 'dangerously-skip-permissions' install-agy.sh && bash install-agy.sh --self-test
      Done when: iterates `dist/agy/*/`, exits clearly when `agy` is missing, records installed SHA + written paths, `--uninstall` reverses via `agy plugin uninstall`, `--ref` defaults to `master`. **`--self-test` must at minimum feed the uninstaller a manifest path outside the install prefix and a path containing a space, assert it refuses the former and correctly removes the latter, and exit non-zero if either behaves wrongly** — a `--self-test) echo ok` stub does not satisfy this item.

- [ ] The npm channel source declares a `bin` CLI (`install`/`uninstall`/`doctor`) and a `postinstall`, so a `--ignore-scripts` install stays completable and detectable
      Verify: python3 -c "import json;d=json.load(open('build/npm/package.json'));assert d.get('bin') and d.get('scripts',{}).get('postinstall')" && for f in build/npm/bin/*; do test -x "$f" || exit 1; case "$f" in *.js) node --check "$f" || exit 1;; *) bash -n "$f" || exit 1;; esac; done && test -f tests/npm-install-smoke.sh
      Done when: `build/npm/` carries the package source (`package.json` with `bin` + `postinstall`, executable `bin/` scripts that parse); `tests/npm-install-smoke.sh` exists and packs `dist/opencode`, installs the tarball into a throwaway prefix both normally and with `--ignore-scripts`, asserts commands land in the first case and `doctor` reports the gap in the second, exercises `uninstall`, and cleans up. **Executing that smoke test is OPERATOR-RUN** — it needs npm registry access an imp cannot reach; this item only requires that it exists and is well-formed.

- [ ] The installer substitutes `__PLUGIN_ROOT__` and the substitution is idempotent
      Verify: grep -rq '__PLUGIN_ROOT__' dist/opencode && grep -rqE '__PLUGIN_ROOT__' build/npm/bin/* && grep -rqE 'sed|replace' build/npm/bin/*
      Done when: the installer replaces every placeholder with the resolved absolute path in installed copies only, re-running produces the same result, and the manifest records what was written. Documented: relocating an install requires re-running it.

- [ ] offload-sidecar gains per-platform MCP registration examples matching Phase A′'s env verdict; Python untouched
      Verify: grep -q 'mcpServers' plugins/offload-sidecar/README.md && grep -qi 'opencode' plugins/offload-sidecar/README.md && test -z "$(git diff origin/master --name-only -- plugins/offload-sidecar/scripts/)"
      Done when: the Agy example uses the confirmed `{command, args}` shape; if env passthrough is unsupported, the README says so plainly instead of shipping an example that cannot carry credentials.

- [ ] The OpenCode-reads-Claude-skills channel is documented, not built
      Verify: grep -qi 'skills' docs/MAINTAINING.md && grep -q 'OPENCODE_DISABLE_CLAUDE_CODE' docs/MAINTAINING.md
      Done when: matrix Item 4b is recorded as a known free channel for the two `SKILL.md` files this repo ships (both in elephant-goldfish), with an explicit note that no second delivery channel is being built for it in this PR.

## Phase D — dispatch tiers (Depends-on: A′, C)

- [ ] The harness-reference edit is exactly the named exception, and generated OpenCode imps points at the harness — one OpenCode dispatch path total
      Verify: git diff --numstat origin/master -- plugins/imps/references/opencode-harness.md | awk '$2+0>0{ok=1} END{exit !ok}' && grep -rq 'opencode-dispatch' dist/opencode
      Done when: the diff touches only the scoping prose; the doc stays accurate for Claude readers; no second dispatch mechanism exists. [JUDGMENT]

- [ ] Model tiers are passed at invocation by the backend, never as frontmatter, and no Claude model name survives as a runtime choice
      Verify: test -z "$(grep -rE '^model:' dist/opencode)" && grep -rq -- '-m ' dist/opencode && test -z "$(grep -rE '\b(haiku|sonnet|opus)\b' dist/opencode | grep -viE 'claude code|on claude')"
      Done when: all three hold — matrix Item 3 means a `model:` field would be silently ignored. [JUDGMENT]

- [ ] The Agy backend inspects response content, not exit code or status
      Verify: grep -rqi 'response' dist/agy && grep -rqiE 'empty|length|content' dist/agy
      Done when: the dispatch path explicitly treats `EXIT=0` + `"status":"SUCCESS"` + empty `response` as a failed run, per matrix Item 8. [JUDGMENT]

- [ ] Refusals match the measured verdicts: OpenCode dispatch refuses when `uname -s != Darwin` (Seatbelt does not nest) with a named reason. The headless bash gate is `OPENCODE_BASH_GATE: unmeasured` — documented in prose as a known unknown, with **no** generated refusal branch
      Verify: grep -rqE 'uname -s|Darwin' dist/opencode && grep -rqiE 'refus|unsupported' dist/opencode && grep -rqi 'known unknown' dist/opencode
      Done when: the only generated refusal branch is the Darwin check; the bash gate appears as prose describing a known unknown and nothing else. Required allow-rules are documented, never added silently. [JUDGMENT]

- [ ] Both workflow scripts carry platform-assumption headers and are otherwise byte-identical to master
      Verify: head -40 plugins/imps/scripts/imps-run.workflow.js | grep -qi 'platform' && head -40 plugins/ape/scripts/ape-forage.workflow.js | grep -qi 'platform' && test -z "$(git diff origin/master -- plugins/imps/scripts/imps-run.workflow.js plugins/ape/scripts/ape-forage.workflow.js | grep -E '^[+-][^+-]' | grep -vE '^[+-][[:space:]]*(//|/\*|\*)')"
      Done when: the non-comment filtered diff is empty.

## Phase E — CI (Depends-on: B; publish item Depends-on: C)

- [ ] validate.yml regenerates on ubuntu-latest and fails on dist drift — this is also the cross-machine determinism check
      Verify: grep -q 'generate.py' .github/workflows/validate.yml && grep -q 'dist-lint' .github/workflows/validate.yml && grep -qE 'diff --exit-code.*dist' .github/workflows/validate.yml
      Done when: all three present.

- [ ] Publishing is manual-only and nothing else can publish
      Verify: test -f .github/workflows/release.yml && grep -q 'workflow_dispatch' .github/workflows/release.yml && grep -q 'NPM_TOKEN' .github/workflows/release.yml && test -f install-agy.sh && test -z "$(grep -rln 'npm publish' build/ tests/ install-agy.sh .github/workflows/validate.yml)"
      Done when: `workflow_dispatch`-triggered (the repo has no tags), publishes committed `dist/opencode` as-is, and no other file in the repo invokes publish. `--access` / `--provenance` are set for a scoped first publish.

- [ ] The Claude suite passes unweakened and new e2e gating uses the existing skip() convention
      Verify: bash tests/run.sh && grep -q 'skip "' tests/run.sh && grep -qE 'XPLAT|OPENCODE|AGY' tests/run.sh
      Done when: full pass; no existing test weakened; cross-platform e2e is env-gated and off by default; skips print skip-lines, never "ok". [JUDGMENT]

## Phase F — instruction files, docs (Depends-on: C)

- [ ] CLAUDE.md is self-contained and both it and AGENTS.md carry the identical shared maintainer block
      Verify: test -z "$(grep '^@' CLAUDE.md)" && test "$(wc -l < CLAUDE.md)" -le 200 && test "$(wc -l < AGENTS.md)" -le 300 && test -f docs/MAINTAINING.md && diff <(sed -n '/BEGIN SHARED-MAINTAINER-BLOCK/,/END SHARED-MAINTAINER-BLOCK/p' CLAUDE.md) <(sed -n '/BEGIN SHARED-MAINTAINER-BLOCK/,/END SHARED-MAINTAINER-BLOCK/p' AGENTS.md)
      Done when: all hold; the block carries the add-a-plugin checklist, invariants, and audit-log schema; the block-diff also runs in dist-lint.

- [ ] `GEMINI.md` is NOT created, and AGENTS.md documents that Agy loads neither file from cwd — only via `--add-dir`
      Verify: test ! -f GEMINI.md && grep -qi 'add-dir' AGENTS.md && sed -n '/## PR 2 re-verification/,$p' docs/platform-matrix.md | grep -qE '^AGY_REGISTERED_AUTOLOAD: neither$'
      Done when: no GEMINI.md exists (A′ measured `neither` at both a subdirectory of a trusted workspace and the exact registered path), and AGENTS.md states the caveat so a future maintainer does not re-add it. [JUDGMENT]

- [ ] Every plugin README states platform support per the generation manifest, including claude-tuneup's exclusion and each refusal
      Verify: for f in plugins/*/README.md; do grep -q '^<!-- PLATFORM-SUPPORT:' "$f" || exit 1; done
      Done when: no README claims support the manifest doesn't back. [JUDGMENT]

- [ ] Root README documents both install paths, links the matrix, and warns about the `.opencode/` footprint
      Verify: grep -qi 'install-agy' README.md && grep -q 'platform-matrix' README.md && grep -qiE 'node_modules|footprint' README.md
      Done when: all three present — matrix Item 12 found `opencode run` auto-provisions a ~62MB `.opencode/node_modules/` in any directory with project-local OpenCode config, hidden from `git status` by its own bundled `.gitignore`.

- [ ] Versioning is bot-compatible and documented: no dist file embeds a per-plugin version, the npm version is hand-maintained, and AGENTS.md tells maintainers to edit sources and regenerate
      Verify: test -z "$(grep -rl '"version"' dist/agy/ 2>/dev/null)" && python3 -c "import json,re;v=json.load(open('build/npm/package.json'))['version'];assert re.match(r'^\d+\.\d+\.\d+$',v) and v!='0.0.0'" && python3 -c "import json;a=json.load(open('build/npm/package.json'))['version'];b=json.load(open('dist/opencode/package.json'))['version'];assert a==b" && grep -qi 'regenerate' AGENTS.md && grep -qi 'npm version' docs/MAINTAINING.md
      Done when: `version-bump.yml`'s bumps (they will fire — READMEs change) cannot desync `dist/`, and the npm version-bump procedure is written down.

---

## Out of scope

- Any behavior change to Claude-loaded files beyond the two named exceptions.
- Rewriting workflow-script internals; porting claude-tuneup; reworking offload-sidecar Python.
- Building a second OpenCode delivery channel for the Claude-skills auto-load (document only).
- Introducing git tags or a release-tagging practice.
- Running `npm publish` from this run; a Linux sandbox backend.
- Measuring anything Phase A′ doesn't cover — cite the matrix or stop.
- `--dangerously-skip-permissions`, anywhere.

## Standing rules

- Every platform fact cites `docs/platform-matrix.md` or Phase A′. Missing → stop and report.
- Unsure whether a Claude reference is semantic or incidental → semantic.
- Generated artifacts never run laxer than the Claude original; installers never add
  permission rules silently.
- Commit per phase. Adversarial review over the full diff before the PR, with attention
  to: the frozen-sources guarantee, the harness-reference edit, placeholder substitution
  correctness, and every verify actually being able to fail.
- Handoff report flags operator follow-ups: create `NPM_TOKEN`, choose the package
  name/scope, run the first manual publish, and confirm any Phase A′ verdict that came
  back weaker than expected.
