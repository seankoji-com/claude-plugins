# OCR diff review

`/imps:imps` uses `scripts/run-ocr.sh` after the merged diff passes its deterministic gates. This is the only code-review gate: do not invoke Head Imp or another same-lineage subagent on the code or diff.

The engine is **OpenCodeReview** — the `ocr` CLI from `@alibaba-group/open-code-review`. It is **not** the OpenCode agent, despite the names. This gate used to run OpenCode and was named for it; see [Why OCR](#why-ocr).

## Setup

Nothing, if the `litellm` provider is already configured in `~/.config/opencode/opencode.json` — `run-ocr.sh` reads `options.baseURL` and `options.apiKey` straight out of it rather than asking for a second copy of the same endpoint and key. It normalises the base URL to the OpenAI-compatible `/v1` form, because OpenCode stores the proxy root and appends that path itself while OCR expects it present.

The `ocr` CLI installs itself on first use, pinned. The preflight gates on the *installed version*, not on `ocr` merely being present: a presence-only check leaves a stale global install in place forever, and `command -v` alone can find a launcher whose platform binary never finished downloading — that dies at the review call with exit 127, after every setup step has already run.

Override any of it:

| Variable | Default | Purpose |
|---|---|---|
| `IMPS_OCR_MODEL` | `deepseek-v4-flash` | Model id sent to the endpoint |
| `IMPS_OCR_URL` | from `opencode.json` | OpenAI-compatible base URL |
| `IMPS_OCR_TOKEN` | from `opencode.json` | Credential |
| `IMPS_OCR_VERSION` | `1.10.1` | Pinned `ocr` release |
| `IMPS_OCR_CONCURRENCY` | `4` | Files reviewed in parallel |
| `IMPS_OCR_TIMEOUT` | `900` | Wall-clock cap on the whole review |
| `IMPS_OCR_LLM_TIMEOUT` | `180` | Per-request cap inside OCR |
| `IMPS_OCR_RULE` | `references/ocr-review-rule.json` | Review rules |

`--check` runs the preflight alone: `jq`, `git`, `perl`, the rule file, resolvable credentials, the pinned `ocr` version, and JSON output support.

## Isolation

OCR reviews `--from <merge-base> --to <head>` against the real repository. Unlike the OpenCode agent it has no tool surface that can mutate anything, so this does not build the deny-everything snapshot the previous implementation needed. Two protections are kept:

- `HOME` is redirected to a temp directory for the run, so `ocr config set` cannot write to the real one.
- HEAD and `git status --porcelain` are captured before and compared after. A mismatch is `source_mutated` and blocks. It is two git calls, and it is the check that would catch an engine that started writing.

## The contract

The helper emits one final JSON line on stdout — status, verdict, findings, model, provider, session ID, duration, cost when available, and a fixed failure reason. Everything else goes to stderr.

OCR emits `{"comments":[{path, start_line, end_line, body}], …}` and **has no severity field**. The imps contract requires one, so `references/ocr-review-rule.json` instructs the reviewer to prefix every comment with `[blocker]`, `[major]`, `[minor]` or `[nit]`, and `run-ocr.sh` parses that prefix off the body.

**An untagged comment is treated as `major`.** That is deliberate: a model that ignores the instruction blocks the run rather than silently passing it, which is the same fail-closed rule the rest of this gate follows. If untagged comments become common, fix the rule file — do not soften the fallback.

The verdict is derived, since OCR has none of its own: any `blocker` or `major` yields `CHANGES_REQUESTED`, otherwise `APPROVE`. This matches the contract's own rule that `APPROVE` may not carry either severity.

## Failures

`CHANGES_REQUESTED` findings are fixed by Claude, gates rerun, and a fresh OCR run reviews the new diff. After three repair rounds the run blocks with `code_review_red`; an operator may record `override code review: <rationale>` only then.

`provider_config_missing` means neither the environment nor `opencode.json` yielded an endpoint and credential. `ocr_version_mismatch` means the install did not land on the pin. Timeouts and malformed verdicts are blocking failures, not soft warnings — there is no OpenRouter fallback, no Claude diff review, and no Head Imp code-review supplement.

## Why OCR

The previous engine was the OpenCode agent, issuing one completion covering the entire diff. That reliably timed out against a self-hosted OpenAI-compatible endpoint once a diff got large: a 2,752-line diff killed it twice, at 99s and at 120s (exit 143), producing no verdict either time. A review that cannot return is a gate that cannot pass — and the failure got worse exactly as changes got bigger, which is backwards.

OCR is a purpose-built diff reviewer. It chunks per file and fans out with `--concurrency`, so review cost scales with the widest file rather than with the whole changeset, and a slow endpoint degrades throughput instead of hitting a wall.

The names remain an ongoing hazard: the OpenCode agent and the `open-code-review` package are unrelated projects, and "opencode" appears in both. Prefer "OCR" for the review tool and "the OpenCode agent" for the other, and keep filenames unambiguous.
