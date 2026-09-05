# Codex-first diff review

`/imps:imps` calls `scripts/run-code-review.sh` after the merged diff passes its
deterministic gates — this is the single entrypoint for the code-review gate; see
`references/ocr-review.md` for the fallback engine it wraps. `run-code-review.sh` tries a
Codex adversarial review first, via `scripts/run-codex-review.sh`, and falls back to OCR
whenever Codex is unavailable, times out, or produces no usable verdict.

## Why not the slash command

`/codex:adversarial-review` cannot be invoked here. Its command frontmatter sets
`disable-model-invocation: true`, a documented Claude Code setting that blocks the
SlashCommand tool from calling it programmatically — only a human typing it in chat can.
`run-codex-review.sh` instead calls the same underlying runtime the slash command wraps
(`codex-companion.mjs adversarial-review`) directly, exactly the way `run-ocr.sh` calls
the `ocr` CLI directly instead of going through `/open-code-review:review`.

## Locating Codex

Codex is a separate, independently installed plugin, so its script root isn't knowable
at authoring time or stable across machines. `run-codex-review.sh` resolves it at
runtime from Claude Code's own `~/.claude/plugins/installed_plugins.json` — the install
manifest every plugin is actually recorded in — by finding a `codex@*` entry and
preferring its user-scope `installPath`. Override the lookup entirely with
`IMPS_CODEX_PLUGIN_ROOT` (used by the test suite, and useful for pointing at a
non-default install).

A missing Codex plugin is a normal, expected outcome, not a failure: the gate falls back
to OCR silently (a line to stderr, nothing more).

## The fallback rule

**Only availability and integrity failures fall back to OCR. A completed Codex verdict is
authoritative and is never second-guessed by also running OCR.** Concretely:

| Codex outcome | Result |
| --- | --- |
| Completed, verdict `approve` | Gate passes. OCR does not run. |
| Completed, verdict `needs-attention` | Gate blocks with Codex's findings. OCR does not run. |
| Codex CLI/plugin not installed, `node` missing | Falls back to OCR. |
| Timed out (`IMPS_CODEX_TIMEOUT`, default 300s) | Falls back to OCR. |
| Crashed, or exited non-zero for any other reason | Falls back to OCR. |
| Produced no usable structured verdict (parse error, unexpected `verdict` value, malformed payload) | Falls back to OCR. |
| The source checkout changed during the review (`source_mutated`) | **Blocks. Does not fall back.** This is the one integrity failure the gate treats as fatal — see below. |

Running OCR *in addition to* a completed `needs-attention` verdict would mean fixing real
findings is optional as long as some other reviewer's random pass comes back clean — the
same fail-closed reasoning `ocr-review.md` applies to its own untagged-comment fallback.
Codex is a genuinely different reviewer, not a pre-filter for OCR.

## Contract mapping

Codex reports structured output matching `codex/schemas/review-output.schema.json`:
`verdict` (`approve`/`needs-attention`), and per-finding `severity`
(`critical`/`high`/`medium`/`low`), `file`, `line_start`/`line_end`, `confidence`, and
`recommendation`. The imps contract requires `blocker`/`major`/`minor`/`nit` and a single
`message` string, so `run-codex-review.sh` maps:

- `verdict`: `approve` → `APPROVE`, `needs-attention` → `CHANGES_REQUESTED`. Any other
  value is treated as `codex_unexpected_verdict` and falls back to OCR — the schema only
  permits those two, so anything else means the model deviated from it.
- `severity`: `critical` → `blocker`, `high` → `major`, `medium` → `minor`, everything
  else → `nit`.
- `message`: `"<title>: <body> Fix: <recommendation>"` (the `Fix:` clause is omitted when
  `recommendation` is empty).
- `line`: `line_start`, falling back to `line_end`, then `1`.

GOAL.md (the Definition of Done plus Global Constraints) is passed as Codex's free-text
review focus — the same acceptance-criteria background OCR gets via `--background-file`,
capped at the same 7500-character truncation point for consistency, since Codex has no
equivalent flag of its own.

## Isolation

Codex's adversarial-review turn runs with `sandbox: "read-only"`, so it has no tool
surface that can mutate the reviewed repository — the same property that let `run-ocr.sh`
skip building a deny-everything snapshot. The mutation check is kept anyway, for the same
reason: HEAD and `git status --porcelain` are captured before and compared after, and a
mismatch is `source_mutated` and blocks outright rather than falling back to OCR. A
review that mutated the tree it just reviewed is not a review OCR can safely re-run
against — the diff OCR would see is no longer the diff that was gated.

Unlike `run-ocr.sh`, `HOME` is **not** redirected: Codex needs its real auth and config
under `~/.codex` to function at all, and its own sandbox already prevents it from writing
into the reviewed repository.

## Overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `IMPS_CODEX_PLUGIN_ROOT` | resolved from `installed_plugins.json` | Codex plugin install root |
| `IMPS_CODEX_NODE_BIN` | `node` | Node binary to run `codex-companion.mjs` |
| `IMPS_CODEX_BIN` | `codex` | Codex CLI binary checked for on `PATH` |
| `IMPS_CODEX_MODEL` | Codex's own default | Model id passed to `--model` |
| `IMPS_CODEX_TIMEOUT` | `300` | Wall-clock cap on the Codex attempt |
| `IMPS_CLAUDE_PLUGINS_MANIFEST` | `~/.claude/plugins/installed_plugins.json` | Install manifest to query |

`run-code-review.sh --check` runs `run-codex-review.sh --check` for information only —
its result is logged but never fails the overall preflight — then requires
`run-ocr.sh --check` to pass, unchanged. OCR remains the mandatory backstop.
