# OpenCode diff review

`/imps:imps` uses `scripts/opencode-review.sh` after the merged diff passes its deterministic gates. This is the only code-review gate: do not invoke Head Imp or another same-lineage subagent on the code or diff. The helper only gives OpenCode a temporary snapshot. It denies edit, Bash, task delegation, web access, and external-directory access, then checks that the real checkout and HEAD did not change.

## Setup

Install OpenCode and configure the `litellm` provider in `~/.config/opencode/opencode.json`:

```sh
opencode models litellm --pure --verbose
```

The review model is pinned to `litellm/deepseek-v4-flash`. The helper copies only the LiteLLM provider block into its temporary OpenCode configuration. The early `--check` preflight requires OpenCode, `jq`, the LiteLLM provider configuration, the pinned model in `opencode models`, and JSON-format headless support.

Other providers and models are rejected. There is no automatic provider switch, OpenRouter fallback, Claude diff review, or Head Imp code-review supplement.

No reasoning variant is passed by default. If the configured LiteLLM model advertises a supported variant, set it with `--variant <effort>` or `IMPS_OPENCODE_REVIEW_VARIANT` (one of `none low medium high xhigh max`, or empty to omit the flag).

## Contract and failures

The helper emits one final JSON line with status, verdict, findings, model, provider, session ID, duration, cost when available, and a fixed failure reason. `CHANGES_REQUESTED` findings are fixed by Claude, gates rerun, and a fresh OpenCode session reviews the new diff. After three repair rounds, the run blocks with `code_review_red`; an operator may record `override code review: <rationale>` only then.

If preflight reports `provider_config_missing`, configure the LiteLLM provider. `model_unavailable` means the pinned model is not exposed by that provider. Timeout and malformed verdicts are blocking failures, not soft warnings.
