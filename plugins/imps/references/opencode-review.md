# OpenCode diff review

`/imps:imps` uses `scripts/opencode-review.sh` after the merged diff passes its deterministic gates. The helper only gives OpenCode a temporary snapshot. It denies edit, Bash, task delegation, web access, and external-directory access, then checks that the real checkout and HEAD did not change.

## Setup

Install OpenCode and authenticate the preferred provider:

```sh
opencode auth login
```

Use the ChatGPT subscription OAuth entry and the default `openai/gpt-5.4` model. The early `--check` preflight requires OpenCode, `jq`, a selected-provider credential, the model in `opencode models`, and JSON-format headless support.

OpenRouter is an explicit paid fallback only:

```sh
export IMPS_OPENCODE_REVIEW_MODEL=openrouter/openai/gpt-5.4
```

Only `openai/*` and `openrouter/openai/*` models are accepted. There is no automatic provider switch and no Claude diff-review fallback.

## Contract and failures

The helper emits one final JSON line with status, verdict, findings, model, provider, session ID, duration, cost when available, and a fixed failure reason. `CHANGES_REQUESTED` findings are fixed by Claude, gates rerun, and a fresh OpenCode session reviews the new diff. After two repair rounds, the run blocks with `code_review_red`; an operator may record `override code review: <rationale>` only then.

If preflight reports `auth_missing`, run `opencode auth login`. `model_unavailable` means choose a model shown by `opencode models` for the selected provider. `timeout` and malformed verdicts are blocking failures, not soft warnings.
