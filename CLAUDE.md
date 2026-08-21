# CLAUDE.md — maintainer guide for claude-plugins

This file is loaded automatically by Claude Code for sessions **inside this repo**. It
is for **marketplace maintainers**. Plugin *users* never see it.

Sessions in other agent runtimes read `AGENTS.md` instead — but see that file's note on
Agy's auto-load caveat before assuming any instruction file reaches every agent by
default.

Default branch: `master`.

---

## Layout

```
.claude-plugin/marketplace.json   # lists every plugin in plugins/
plugins/<name>/
  .claude-plugin/plugin.json      # this plugin's manifest
  commands/<name>.md              # the slash-command (its frontmatter is the source of truth)
  agents/<name>.md                # optional: subagent types this plugin registers on install
  scripts/*.sh                    # helpers; must be chmod +x
  README.md                       # user-facing docs for this plugin
build/                            # cross-platform generator: platform-table, per-plugin overrides, npm channel source
dist/                             # generated OpenCode/Agy output — committed, never hand-edited
docs/MAINTAINING.md               # extended maintainer prose (generator, install paths, versioning)
README.md                         # marketplace overview + install table (one row per plugin)
```

---

<!-- BEGIN SHARED-MAINTAINER-BLOCK -->
## Add-a-plugin checklist

These five things must change **together** — missing one breaks the marketplace:

1. `plugins/<name>/.claude-plugin/plugin.json` — fill every required field
2. `.claude-plugin/marketplace.json` — add an entry under `"plugins"`
3. Root `README.md` "Available plugins" table — add one row
4. `plugins/<name>/README.md` — user-facing prerequisites, modes, env vars, license
5. `chmod +x plugins/<name>/scripts/*.sh` — every shipped helper must be executable

## Invariants

- **No machine paths.** Bundled scripts resolve themselves via `${CLAUDE_PLUGIN_ROOT}`
  on Claude Code. The pattern is already established in `goldfish-judge.sh` and
  `elephant.md` — match it. Cross-platform generated artifacts (`dist/`) carry a literal
  `__PLUGIN_ROOT__` placeholder instead, resolved by the installer at install time on
  the user's machine only — never write an absolute path into the repo or into `dist/`.
  See `docs/MAINTAINING.md` for the generator/installer split.
- **Executable files are the source of truth.** `commands/*.md` owns mechanics;
  `scripts/*.sh` owns runtime behavior. READMEs *describe* them — don't restate or drift.
- **Fail-closed beats fail-open** everywhere safety-relevant. See `goldfish-judge.sh` for
  the pattern. Deliberate exception: `audit-log.sh` is telemetry, not a gate — it fails
  *soft* (warns on stderr, exits 0) on a missing `jq` or an unwritable log dir, so a
  logging hiccup never breaks the caller's primary command. Malformed *arguments* to it
  still exit 1 — those are bugs in the calling command, not the environment.

## Cross-plugin audit log

Self-improving commands (imps, prompt-builder, claude-tuneup) each append one line to a
shared, append-only `~/.claude/audit.jsonl` after a run, in addition to their own
free-text learnings log. One fixed shape across plugins is what makes a future
cross-plugin meta-command (e.g. "which command types are failing most this month")
possible at all — schema adapted from maestro's `audit.jsonl`
(github.com/sharpdeveye/maestro):

```json
{"id":"a-974bcc15","ts":"2026-07-09T02:15:37Z","plugin":"imps","command":"/imps:imps","scope":"project","project":"claude-plugins","exit_status":"completed","duration_ms":812345,"cost_estimate_usd":null,"tier":null,"attempts":null,"notes":"Shipped audit-log JSONL schema across imps, prompt-builder, claude-tuneup"}
```

`exit_status` is one of `completed | partial | blocked | failed | cancelled`. `notes` is
free text, truncated to 200 chars by the script. `cost_estimate_usd` is reserved for
future token-cost instrumentation — always `null` today. `tier` and `attempts` are
optional, `null` unless the caller passes `--tier`/`--attempts` — used by the opencode
execute-tier harness (`opencode-dispatch.sh`) to record which offload tier ran a task and
how many oracle-loop attempts it took.

The appender is `scripts/audit-log.sh`, bundled **identically into every plugin that
uses it** (`plugins/imps/scripts/`, `plugins/prompt-builder/scripts/`,
`plugins/claude-tuneup/scripts/`) rather than pulled from one shared location — plugins
in this marketplace install independently, so there is no cross-plugin runtime path to
require a shared lib from. `tests/run.sh` diffs the copies against each other; if you
change the script, change all three and let the diff check catch drift.

The free-text logs (`learnings.md`, `claude-tuneup.notes.md`) are not being replaced —
they hold qualitative "Active rules" narratives a single JSON line can't express well.
`audit.jsonl` is additive: a queryable event stream layered on top.
<!-- END SHARED-MAINTAINER-BLOCK -->

---

## Validate before committing

CI runs these checks automatically on every push and PR. For a quick local pre-commit check:
```bash
jq . .claude-plugin/marketplace.json && for f in plugins/*/.claude-plugin/plugin.json; do jq -e '.name' "$f"; done
grep -rn --include="*.md" 'CLAUDE_PLUGIN_ROOT' plugins/*/commands/ | head  # confirm rewrites landed
```
See `.github/workflows/validate.yml` for the full check suite; `build/dist-lint.sh`
gates generated `dist/` output separately, including a self-test that this shared block
stays identical between this file and `AGENTS.md`.

## Further reading

`docs/MAINTAINING.md` covers the cross-platform generator, install paths per platform,
and versioning in more depth than this budget-capped file has room for.
