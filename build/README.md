# `build/` — the cross-platform generator

`dist/` is generated, never hand-edited. Everything under it comes from
`python3 build/generate.py`, whose inputs are the frozen Claude sources under `plugins/`
plus the three files described below. Contract: `docs/plans/cross-platform-compat.md`.
Every platform behaviour relied on here is cited back to `docs/platform-matrix.md` from
`platform-table.json`'s per-platform `evidence` block. Nothing in this directory measures
a platform — a fact that is not in the matrix does not get used.

```
build/
  generate.py               the generator (Python 3, stdlib only)
  platform-table.json       the single Claude→platform mapping source
  generation-manifest.json  which plugin generates for which platform, and why
  overrides/<plugin>/       per-plugin porting spec + section-replacement blocks
  npm/                      npm channel package source, mirrored into dist/opencode/
```

## Running it

```bash
python3 build/generate.py                    # whole tree; rebuilds dist/ from scratch
python3 build/generate.py --only <plugin>    # just that plugin, leaving the rest of dist/
```

`--only` clears exactly that plugin's outputs (`dist/agy/<plugin>/`,
`dist/opencode/share/<plugin>/`, and `dist/opencode/commands/<plugin>*.md`) and rewrites
them. Whole-tree is authoritative: CI regenerates without `--only` and diffs.

## What generates, and when

A plugin is generated for a platform when `generation-manifest.json` marks it `full` for
that platform **and** `build/overrides/<plugin>/` exists. The manifest records policy; the
overrides directory records that the porting work has actually been done. A plugin marked
`full` with no overrides directory is reported as skipped, by name, on every run — and
`--only` on it fails outright rather than emitting an unported command. Statuses are
`full`, `excluded` (nothing to port to) and `note-only` (documented in the plugin README,
nothing generated).

## `dist/` invariants

These are enforced twice: `generate.py` fails the run with a file and line, and
`build/dist-lint.sh` re-checks the committed tree independently.

- **No machine paths.** No absolute path and no reference to the home environment
  variable. Bundled-script paths carry the literal `__PLUGIN_ROOT__`; the installer
  substitutes the resolved absolute path into the *installed* copy on the user's machine.
  OpenCode exposes no plugin-root mechanism at all (matrix Item 0), which is why the
  resolution is deferred to install time rather than read from the environment.
- **No unmapped Claude references.** No `CLAUDE_PLUGIN_ROOT`, and no `.claude/` path
  except the one canonical `~/.claude/audit.jsonl` — the audit log is deliberately the
  same file on every platform.
- **No `model:` frontmatter in `dist/opencode/`.** Matrix Item 3 measured only that Claude
  Code's `model:` convention is *not honored*; it explicitly did not rule out a
  differently-named OpenCode field. Emitting none is therefore a **safe default, not a
  settled platform fact**. Model choice is passed at invocation by the dispatch backend.
- **No per-plugin version anywhere in `dist/agy/`.** The Agy manifest carries `name` and
  `description` only, so `version-bump.yml` — the sole writer of `plugin.json` and
  `marketplace.json` — can never desync `dist/`. The npm version is authored in
  `build/npm/package.json` and generated into `dist/opencode/package.json`; never
  hand-edit the generated copy.

## `platform-table.json`

Top level is exactly the two platform keys. Each carries:

| Key | What it does |
| --- | --- |
| `evidence` | Matrix citation for every platform behaviour this platform's rules assume |
| `layout` | Output paths, and the default asset directories copied alongside |
| `command_naming` | Whether generated command names are prefixed with the plugin name |
| `command_frontmatter` / `skill_frontmatter` | Allow-list (`emit`) and deny-list (`drop`) |
| `pre_replacements` | Exact, documented rewrites applied before anything else |
| `replacements` | Ordered literal string mappings, longest/most-specific first |
| `audit_log` | The forms protected from the mapping, and the canonical path restored after |

Frontmatter is allow-listed, not filtered: a key that is in neither `emit` nor `drop`
fails the run. Passing an unmeasured field through silently is how a platform assumption
gets made by accident.

Substitution order, per file: `pre_replacements` → protect the audit-log path →
`replacements` → this plugin's own `/<plugin>:<command>` invocations → restore the
audit-log path. Only the plugin being generated has its invocations remapped; a reference
to another plugin's Claude command is left alone, because it is either a genuine "on
Claude Code this is X" comparison or a cross-plugin note that belongs to that plugin's own
overrides.

## `overrides/<plugin>/`

```
overrides/<plugin>/
  port.json                       optional: {"asset_dirs": ["scripts", "templates"]}
  opencode/commands/<name>.md     override for the command generated from commands/<name>.md
  agy/skills/<name>.md            override for the skill generated from that command or SKILL.md
```

An override file is a list of directives and nothing else:

```
<!-- REPLACE-SECTION: ## Exact heading line from the Claude source -->
replacement markdown, inserted verbatim
<!-- END-SECTION -->

<!-- DROP-SECTION: ## Another exact heading -->

<!-- SET-FRONTMATTER: agent: build -->
```

A *section* runs from its heading line to the next heading line of any level, or end of
file. Headings are matched against the **Claude source**, before any mapping runs. The
replacement text is inserted **verbatim** — the mapping does not touch it — so write
`__PLUGIN_ROOT__` and platform paths directly, and keep any deliberate "on Claude Code
this is X" wording you want preserved. A heading that does not match, or an override for a
command or skill that does not exist, fails the run.
