# OpenCode diff review

`/imps` uses `scripts/opencode-review.sh` after the merged diff passes its deterministic gates. The helper only gives OpenCode a temporary snapshot. It denies edit, Bash, task delegation, web access, and external-directory access, then checks that the real checkout and HEAD did not change.

## Setup

Install OpenCode and authenticate the preferred provider:

```sh
opencode auth login
```

Use the ChatGPT subscription OAuth entry and the default `openai/gpt-5.6-terra` model, run at `high` reasoning effort via `--variant` (both configurable, see below). The early `--check` preflight requires OpenCode, `jq`, a selected-provider credential, the model in `opencode models`, and JSON-format headless support.

OpenRouter is an explicit paid fallback only:

```sh
export IMPS_OPENCODE_REVIEW_MODEL=openrouter/deepseek/deepseek-v4-flash   # or openrouter/openai/gpt-5.6-terra
```

Only `openai/*`, `openrouter/openai/*`, and `openrouter/deepseek/*` models are accepted — deliberately scoped rather than the whole `openrouter/*` namespace, since that would also admit routing a Claude model through here. There is no automatic provider switch and no Claude diff-review fallback.

Reasoning effort defaults to `high` and is passed to `opencode run` as `--variant`, not baked into the model string; override with `--variant <effort>` or `IMPS_OPENCODE_REVIEW_VARIANT` (one of `none low medium high xhigh max`, or empty to omit the flag). Not every model supports every variant — check `opencode models <provider> --pure --verbose` for the model's own `variants` list before setting one that isn't there.

## Contract and failures

The helper emits one final JSON line with status, verdict, findings, model, provider, session ID, duration, cost when available, and a fixed failure reason. `CHANGES_REQUESTED` findings are fixed by Claude, gates rerun, and a fresh OpenCode session reviews the new diff. After three repair rounds, the run blocks with `code_review_red`; an operator may record `override code review: <rationale>` only then.

If preflight reports `auth_missing`, run `opencode auth login`. `model_unavailable` means choose a model shown by `opencode models` for the selected provider. `timeout` and malformed verdicts are blocking failures, not soft warnings.
