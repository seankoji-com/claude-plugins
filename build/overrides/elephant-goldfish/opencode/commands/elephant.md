<!-- REPLACE-SECTION: # /elephant -->
# /elephant-goldfish-elephant

**Before executing any steps**, output:

> 🐘 **elephant-goldfish** — keeping your design doc honest
>
> Writes or updates `elephant.md`, then cold-reads it with a different-lineage model that
> has no repo access. A PASS means the doc is *plausible enough to bootstrap from* — not
> that every claim in it is true. See **Limitations** below before trusting one.
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Fact-check mode (`check`) -->
## Fact-check mode (`check`)

`$ARGUMENTS == check`: run a read-only pass that (a) verifies every `path`/`path:line`
citation in `elephant.md` against what that file actually contains, and (b) spot-checks
`git ls-files` for major additions the doc never mentions.

On Claude Code this spawns a cheap `model: haiku` subagent. Here there is no per-command model
field — the Claude Code convention for one is not honored (docs/platform-matrix.md, Item 3) —
so either run the pass inline or dispatch it with an explicit cheap model at invocation time
(`-m <provider/model>`).

Report drift as `doc says X / code does Y (path:line)` or `code has X / doc never mentions it
(path)`. **Read-only — never writes `elephant.md`.** This is the complement to the judge
above: it catches wrong-but-plausible claims the cold judge structurally cannot (see
Limitations).
<!-- END-SECTION -->
