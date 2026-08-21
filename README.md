# claude-plugins

<p align="center">
  <img src="docs/assets/claude-plugins-hero.png" alt="claude-plugins banner" width="720">
</p>

A [Claude Code](https://code.claude.com/) plugin marketplace by [@seankoji](https://github.com/seankoji).

## Available plugins

| Plugin | Description |
|---|---|
| [elephant-goldfish](./plugins/elephant-goldfish/) | Self-validating `/elephant-goldfish:elephant` design-doc command + Gemini goldfish judge, and `/elephant-goldfish:thinking` — interrogate a problem, build a grading rubric, emit a ready-to-paste brief for a fresh session |
| [claude-tuneup](./plugins/claude-tuneup/) | Permission audit and settings tuneup for Claude Code |
| [prompt-builder](./plugins/prompt-builder/) | Iterative prompt engineering assistant |
| [imps](./plugins/imps/) | Swarm orchestration, whole-repo audits, PR monitoring, and proof-led blast-radius analysis |
| [ape](./plugins/ape/) | Forages broadly or studies one named OSS source for transferable techniques |
| [offload-sidecar](./plugins/offload-sidecar/) | MCP tool that offloads file transforms, log triage, and vision tasks — paths in, paths out, no file content through Claude's context. Local Ollama tiers (private) plus budget-gated Gemini tiers via the agy CLI. Formerly ollama-sidecar |

---

## Install

```bash
# Add the marketplace (one-time)
claude plugin marketplace add seankoji-com/claude-plugins

# Install a plugin
claude plugin install elephant-goldfish@seankoji

# Install project-scoped (shared with teammates via .claude/)
claude plugin install elephant-goldfish@seankoji --scope project

# Keep marketplace up to date
claude plugin marketplace update
```

---

## Other platforms: OpenCode and Agy

Most plugins here also generate for [OpenCode](https://opencode.ai) and
[Agy](https://antigravity.google) (the Antigravity CLI) from these same Claude
sources — see each plugin's README for its own `<!-- PLATFORM-SUPPORT: -->` marker,
and [`docs/plans/cross-platform-compat.md`](./docs/plans/cross-platform-compat.md) for
the generator design. Every platform-specific claim in that plan and in this repo's
generated output cites [`docs/platform-matrix.md`](./docs/platform-matrix.md) — the
measured facts about what each CLI actually does, live-tested rather than assumed.

**OpenCode** — via the npm package (source at `build/npm/`, generated into
`dist/opencode/`). It is published to **GitHub Packages**, which requires a token to
read *even for public packages*, so installing needs one `~/.npmrc` setup step:

```
@seankoji:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_TOKEN_HERE
```

The token is a [personal access token](https://github.com/settings/tokens) with only
the `read:packages` scope. It must be a **classic** token — GitHub's npm-registry docs
state *"GitHub Packages only supports authentication using a personal access token
(classic)"*, and fine-grained tokens are not supported for this registry even though
they expose a `Packages` permission that works elsewhere. Then:

```bash
npm install -g @seankoji/claude-plugins-opencode
```

`postinstall` copies commands and scripts into `~/.config/opencode/{commands,share}`.
If `postinstall` didn't run, nothing was copied — run the bundled CLI's own subcommand
instead: `claude-plugins-opencode install` (also `uninstall`/`doctor`) — the binary
keeps its unscoped name. `--ignore-scripts` is only one route there: npm also gates
install scripts on its own, and CI images often disable them, so
`claude-plugins-opencode doctor` is the reliable check rather than whether you passed a
flag. Published manually via `workflow_dispatch`; this repo carries no git tags.

**Working inside this repo?** The committed [`.npmrc`](./.npmrc) already maps the
`@seankoji` scope to GitHub Packages, so you only need the credential:
`export NODE_AUTH_TOKEN=<your classic PAT>`. It carries no token itself — npm expands
`${NODE_AUTH_TOKEN}` at read time. The `~/.npmrc` setup above is for installing from
anywhere else.

**Don't want a token?** Clone this repo and run `node dist/opencode/bin/cli.js install`
from the checkout — same code path as `postinstall`, no registry involved. See
[`build/npm/README.md`](./build/npm/README.md) for the full CLI.

**Heads up:** running `opencode run` inside any directory with project-local OpenCode
config auto-provisions a **~62 MB** `.opencode/node_modules/` there — confirmed live
(`docs/platform-matrix.md` Item 12, reconfirmed under `## PR 2 re-verification`) — and
that footprint is hidden from `git status` by a `.gitignore` OpenCode bundles into
`.opencode/` itself, so it's easy to not notice it's there. Nothing in this repo's own
install path creates it; it's a side effect of invoking `opencode run` project-locally,
worth knowing about before you do.

**Agy** — via this repo's own installer, `install-agy.sh`, against the generated
`dist/agy/<plugin>/` trees:

```bash
git clone https://github.com/seankoji-com/claude-plugins
cd claude-plugins
./install-agy.sh              # installs at master; --ref <branch|tag|sha> to pin
./install-agy.sh --uninstall  # reverses exactly what was installed
```

Manifest-tracked at `~/.gemini/config/.seankoji-agy-manifest` (the OpenCode installer
above has its own manifest at `~/.config/opencode/.seankoji-plugins-manifest.json`);
reinstalling either updates in place rather than duplicating. Note that Agy does
**not** auto-load this repo's `AGENTS.md` from a checkout's working directory, even in
an already-registered `trustedWorkspaces` entry — only `--add-dir` does — so don't
expect repo-root instructions to reach it for free (`docs/platform-matrix.md`,
`## PR 2 re-verification`).

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to add a plugin, test changes locally, and open a PR.
