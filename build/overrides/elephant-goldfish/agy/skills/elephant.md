<!-- REPLACE-SECTION: ## Fact-check mode (`check`) -->
## Fact-check mode (`check`)

`$ARGUMENTS == check`: run a read-only pass that (a) verifies every `path`/`path:line`
citation in `elephant.md` against what that file actually contains, and (b) spot-checks
`git ls-files` for major additions the doc never mentions.

On Claude Code this spawns a cheap `model: haiku` subagent. No per-skill model field is
recorded for this platform in `docs/platform-matrix.md`, so none is emitted — pick the model
at invocation with `--model <name>` (matrix Item 8) or run the pass inline.

Report drift as `doc says X / code does Y (path:line)` or `code has X / doc never mentions it
(path)`. **Read-only — never writes `elephant.md`.** This is the complement to the judge
above: it catches wrong-but-plausible claims the cold judge structurally cannot (see
Limitations).
<!-- END-SECTION -->
