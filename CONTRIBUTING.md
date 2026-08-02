# Contributing

Contributions welcome — new plugins, improvements to existing ones, docs fixes.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `jq` (for local validation and CI parity)
- `shellcheck` (shell script linter)
- `node` (for `node --check` validation of Workflow scripts)
- `pipx` (for `check-jsonschema` and other Python tools)
- Python 3 with `PyYAML` (for frontmatter schema validation)
- Plugin-specific prerequisites vary — see the relevant `plugins/<name>/README.md`

## Repo layout

```
.claude-plugin/marketplace.json     # marketplace index (one entry per plugin)
plugins/<name>/
  .claude-plugin/plugin.json        # plugin manifest
  commands/<name>.md                # slash-command definition (source of truth for mechanics)
  scripts/*.sh                      # bundled helpers — must be chmod +x
  README.md                         # user-facing docs
schemas/                            # JSON Schema contracts for manifests
tests/                              # behavioral tests for plugins/*/scripts/*.sh
.github/workflows/validate.yml      # CI gate
```

See `AGENTS.md` for the full invariants and the add-a-plugin checklist.

---

## Testing locally

Plugins install into a local cache. To test changes without publishing:

**1. Find your cache path**

```bash
ls ~/.claude/plugins/cache/seankoji/
# ape/  claude-tuneup/  elephant-goldfish/  imps/  offload-sidecar/  prompt-builder/  recon/
```

Each plugin lives at `~/.claude/plugins/cache/seankoji/<plugin>/<version>/`.

**2. Copy your changed file into the cache**

```bash
cp plugins/elephant-goldfish/commands/elephant.md \
   ~/.claude/plugins/cache/seankoji/elephant-goldfish/0.1.10/commands/elephant.md
```

Do this for any file you changed — commands, scripts, or READMEs.

**3. Hot-reload in Claude Code**

In any Claude Code session, run:

```
/reload-plugins
```

This re-reads all plugin command files from disk. No session restart needed.

**4. Invoke your command**

```
/elephant-goldfish:elephant check
```

The change is live. Edit → copy → `/reload-plugins` → test, repeat.

**Testing a new plugin end-to-end**

If you're adding a brand-new plugin and want to test the full install flow:

```bash
# Install from your local branch (Claude Code supports file:// paths)
claude plugin install file://$(pwd)/plugins/my-new-plugin --scope user
```

Then invoke it normally. To uninstall when done:

```bash
claude plugin uninstall my-new-plugin@seankoji
```

---

## Adding a plugin

Five things must change **together** — missing one breaks the marketplace:

1. `plugins/<name>/.claude-plugin/plugin.json` — fill every required field (name, version, description, author, homepage, repository, license, keywords)
2. `.claude-plugin/marketplace.json` — add an entry under `"plugins"` (name, source, description)
3. Root `README.md` — add one row to the "Available plugins" table
4. `plugins/<name>/README.md` — user-facing prerequisites, modes, env vars, license
5. `chmod +x plugins/<name>/scripts/*.sh` — every shipped shell helper must be executable

**Invariants to follow:**
- Use `${CLAUDE_PLUGIN_ROOT}` for bundled asset paths — never hardcode `~/.claude/`
- Runtime state (logs, run state) goes under `~/.claude/` — never bundle it
- Commands are auto-discovered from `commands/*.md` — no `commands` field in `plugin.json`
- Fail-closed: scripts should exit non-zero on ambiguous/empty output, not treat silence as success
- Invoke a plugin's own command with its fully namespaced form, `/<plugin-name>:<command-name>`
  (e.g. `/imps:imps`, `/elephant-goldfish:elephant`) — Claude Code always namespaces plugin
  commands this way, even when the command file name matches the plugin name; there is no bare
  unqualified alias

**Versioning:** bumps are a pure per-touching-PR patch counter (CI's "version bumped" check just
requires the number to change), not semver — don't expect automatic minor/major bumps for larger
changes.

---

## Validate before opening a PR

Run CI checks locally first:

```bash
# Validate JSON manifests
jq . .claude-plugin/marketplace.json
for f in plugins/*/.claude-plugin/plugin.json; do jq -e '.name' "$f"; done

# Validate manifests against the JSON Schema contracts (same tool CI uses)
pipx run check-jsonschema --schemafile schemas/marketplace.schema.json .claude-plugin/marketplace.json
for f in plugins/*/.claude-plugin/plugin.json; do pipx run check-jsonschema --schemafile schemas/plugin.schema.json "$f"; done

# Validate command/agent frontmatter against JSON Schema contracts
for f in plugins/*/commands/*.md; do [ -f "$f" ] && pipx run check-jsonschema --schemafile schemas/command-frontmatter.schema.json "$f"; done
for f in plugins/*/agents/*.md; do [ -f "$f" ] && pipx run check-jsonschema --schemafile schemas/agent-frontmatter.schema.json "$f"; done

# Validate marketplace versions match plugin.json
jq -r '.plugins[] | "\(.name) \(.source) \(.version // "")"' .claude-plugin/marketplace.json | \
  while IFS=" " read -r name source market_version; do
    [ -n "$market_version" ] || { echo "ERROR: marketplace entry for '$name' is missing version"; exit 1; }
    manifest="${source}/.claude-plugin/plugin.json"
    plugin_version=$(jq -r '.version' "$manifest")
    [ "$market_version" = "$plugin_version" ] || { echo "ERROR: version mismatch for $name: marketplace=$market_version plugin.json=$plugin_version"; exit 1; }
  done

# Confirm every plugin has a README and a row in the root README
for d in plugins/*/; do [ -f "${d}README.md" ] || echo "missing ${d}README.md"; done

# Confirm bundled assets are referenced via CLAUDE_PLUGIN_ROOT, not hardcoded paths
# (References to ~/.claude/ in command docs for *runtime state* are fine — the CI gate
# "Check for bundled-asset path leaks" in .github/workflows/validate.yml is the
# authoritative rule: it flags only bundled assets like scripts/ or personas/ referenced
# under literal ~/.claude/ paths. See that step for the structural rule.)

# Check all .sh and .py files are executable
git ls-files plugins/**/*.sh plugins/**/*.py | xargs ls -la | grep -v '^-rwx'

# Lint shell scripts
find plugins -name "*.sh" -exec shellcheck --severity=warning {} +

# Check node scripts (Workflow scripts)
for f in plugins/*/scripts/*.js; do [ -f "$f" ] && node --check "$f"; done

# Run behavioral tests for plugins/*/scripts/*.sh, Python, and JavaScript
bash tests/run.sh
bash tests/run-python.sh
bash tests/run-js.sh
```

CI runs all of these automatically on push. See `.github/workflows/validate.yml` for the full suite.

---

## Opening a PR

- Branch from `master`
- Keep PRs scoped to one plugin or one concern — easier to review and revert
- The PR description should explain *why*, not just what changed
- CI must pass before merge
