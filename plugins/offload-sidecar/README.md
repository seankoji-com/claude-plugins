<!-- PLATFORM-SUPPORT: opencode=note-only agy=note-only -->

# offload-sidecar

*Formerly `ollama-sidecar` — one sidecar for all offloadable work, local or cloud.*

**Use this when `jq`/Python can't do the transform in one deterministic pass** — the
input is too irregular for a fixed rule (messy logs, "does this look like a secret",
"what does this screenshot show") but too big or too tedious to be worth Claude's own
context budget. For anything a `jq` filter or a short Python script *can* express
exactly, that's strictly better — deterministic, instant, free, verifiable — and this
plugin's own `deterministic` operations cover the common cases (dedup, sort, filter,
slice, decode, hash, and a dozen-plus structured-format conversions) with no model
call at all. Reach for the LLM-backed operations only for the remainder: input that
genuinely needs judgment about its meaning.

Either way, Claude exchanges only a file path and an operation name (a few dozen
tokens) with this plugin's MCP tool, never the file contents. Only a small status
payload comes back.

---

## Four LLM tiers, two engines

| Tier | Engine | Meant for | Privacy |
|---|---|---|---|
| `deep` | Ollama | Judgment-heavy, low-volume work; the biggest model your local machine can hold | content stays on your machine/LAN |
| `fast` | Ollama | Bulk transforms with large outputs; a smaller model fully resident in a LAN GPU's VRAM | content stays on your machine/LAN |
| `flash` | agy (Gemini Flash) | Vision (images, PDFs), inputs beyond local context (~1M tokens), bulk work above local quality | **content is sent to Google** |
| `pro` | agy (Gemini Pro) | Occasional escalation when flash isn't enough | **content is sent to Google**; scarce weekly quota |

- Local tiers behave exactly as in ollama-sidecar: every `fast` setting falls back to
  its `deep` value when unset, unreachable-endpoint failover between the two local
  tiers (never across the local/cloud boundary), same timeouts (`deep` 300s, `fast`
  120s; `OLLAMA_TIMEOUT`/`OLLAMA_FAST_TIMEOUT` override).
- Cloud tiers shell out to the official [`agy`](https://antigravity.google) binary
  (Google Antigravity CLI) authenticated against your Gemini subscription — the
  plugin never touches its OAuth token. Calls are serial, never parallel. When the
  input goes by path (all vision ops, text over ~200KB), it is **staged alone into a
  temp directory** first — agy can see that one file, never its real parent
  directory, so a prompt-injected input can't talk the agent into reading siblings.
- **Trust boundary:** anything routed to `flash`/`pro` leaves your machine. That is
  why `redact_secrets` defaults (and should stay) local, and why every operation's
  default tier is local except the vision ops, which have nowhere local to go.
- A per-call `tier` argument overrides any operation's default.
- Success payloads name the `tier`, `engine`, and `model` that served the call
  (cloud payloads add quota usage; local payloads add the `host`).

## The quota gate (cloud tiers)

Google meters Antigravity subscriptions in opaque units: a ~5-hourly sprint bucket
plus a weekly cap whose exhaustion locks the model for up to **7 days** (Flash is the
cheapest bucket by far; Pro and the non-Gemini models burn it fastest). The plugin
therefore **rejects cloud calls up front instead of routing them to Gemini to fail**:

- Sliding-window call budgets per tier (defaults: flash 60/5h + 600/week, pro 5/5h +
  25/week; all four configurable, `0` disables a window) tracked in
  `~/.local/state/offload-sidecar/quota.json` across all sessions
  (`AGY_QUOTA_STATE` overrides the path).
- When agy itself reports a lockout ("you can resume using this model at …"), the
  deadline is recorded and every later call to that model is rejected immediately
  until it passes.
- A rejection is a structured `status:"error"` naming the exhausted window, the
  usage, and the local-tier fallback — the caller retries on `deep`/`fast` or waits.
- Budgets count *calls*, not Google's hidden units — they're a conservative margin,
  not an exact meter. `status` (below) shows current usage.

---

## Why

Passing 10,000 log lines through Claude costs real input *and* output tokens for no
benefit, and screenshots cost ~1–1.5k tokens each at Claude vision rates. But if the
pass is truly rule-based, `jq`/Python solves it strictly better than any model — the
`deterministic` operations exist for exactly that. The LLM operations exist for the
narrower remainder: input too irregular for a fixed rule, but too large, repetitive,
or low-stakes to spend Claude's own judgment on. For that slice, `process_local_file`:

1. Reads the input file directly from disk (or, on cloud tiers with big/media
   inputs, tells agy the path and lets it read the file with its own tools).
2. Runs the operation — pure local Python, `yq`, the configured Ollama model, or
   Gemini via agy, per the tier table.
3. **Validates the output before writing it** — malformed JSON, ragged CSV, gross
   truncation, missing required keys surface as `status:"error"`, not a false
   "success".
4. Writes the result to disk and returns only a tiny status payload.

**Important trust boundary:** the validators check *format*, not *content*. They
catch a model that returns broken JSON or drops most of the records; they do **not**
verify field values are semantically correct. Where subtle content fidelity matters,
spot-check the output file rather than trusting a bare `"success"`. Deterministic
operations have a stronger guarantee — no model in the loop — but are only as correct
as the fixed rules they implement.

---

## Platforms

| Claude Code | OpenCode | Agy |
| --- | --- | --- |
| native (this README), via `.mcp.json` | note-only | note-only |

Not generated for OpenCode or Agy — this plugin ships no command, agent, or skill
files to port; it's an MCP server plus a Python entrypoint, so there is nothing for
`build/generate.py` to produce (`build/generation-manifest.json`). Per-platform MCP
registration is documented by hand instead, below. `scripts/offload_sidecar.py` is
untouched by cross-platform work — it's the same entrypoint on every platform. See
[`docs/plans/cross-platform-compat.md`](../../docs/plans/cross-platform-compat.md) and
[`docs/platform-matrix.md`](../../docs/platform-matrix.md) for how and why.

## Prerequisites

- `python3` on PATH (standard library only — nothing to `pip install`; `toml_to_json`
  needs Python 3.11+). Everything deterministic runs with this alone.
- **Local tiers:** a reachable Ollama instance with the configured model(s) pulled.
- **Cloud tiers:** the [`agy` CLI](https://antigravity.google) installed and signed
  in (run `agy` once interactively), with a Google Gemini subscription. Without it,
  `flash`/`pro` return a structured error and everything else keeps working.
- Optional: [`yq`](https://github.com/mikefarah/yq) (`brew install yq`) — makes
  `yaml_to_json` deterministic and enables `json_to_yaml`.

No build step, Node runtime, or pip dependencies. The server is one file:
`scripts/offload_sidecar.py`, invoked via this plugin's `.mcp.json`.

---

## Install

```bash
claude plugin marketplace add seankoji/claude-plugins
claude plugin install offload-sidecar@seankoji
```

**Migrating from ollama-sidecar:** uninstall `ollama-sidecar` and install this — same
tool name, same operations (plus many new), same local-tier config keys; the old
plugin name no longer receives updates.

Config (prompted at install; reconfigure later via `claude plugin` config commands):

| Setting | Default | Purpose |
|---|---|---|
| `ollama_host` | `http://localhost:11434` | **Deep tier** — primary Ollama server. |
| `ollama_model` | `qwen3:14b` | Deep tier model tag (must be pulled). |
| `num_ctx` | `16384` | Deep tier context window. |
| `fast_ollama_host` | *(unset → deep)* | **Fast tier** — optional second Ollama server, e.g. `http://your-pc.local:11434`. |
| `fast_ollama_model` | *(unset → deep)* | Fast tier model tag. |
| `fast_num_ctx` | *(unset → deep)* | Fast tier context window. |
| `tls_ca_file` | *(unset)* | PEM CA bundle path (`~` or absolute) for verifying **https** Ollama endpoints (mkcert/self-signed LAN proxies). |
| `agy_bin` | `agy` | **Cloud tiers** — Antigravity CLI binary name, or a `~`/absolute path. |
| `agy_flash_model` | `Gemini 3.5 Flash (Low)` | Flash tier model, exactly as `agy models` prints it. |
| `agy_pro_model` | `Gemini 3.1 Pro (High)` | Pro tier model. |
| `agy_flash_per_5h` | `60` | Flash call budget per 5h window (`0` disables). |
| `agy_flash_per_week` | `600` | Flash call budget per week. |
| `agy_pro_per_5h` | `5` | Pro call budget per 5h window. |
| `agy_pro_per_week` | `25` | Pro call budget per week. |

---

## Registering on OpenCode or Agy

This plugin has no OpenCode or Agy generated output (see Platforms above) —
`scripts/offload_sidecar.py` is a standalone MCP server, so register it by hand in
whichever platform's MCP config.

### Agy — `mcp_config.json`

The shape below is confirmed live against a real, already-in-use
`~/.gemini/config/mcp_config.json` (`docs/platform-matrix.md` Item 10): a top-level
`mcpServers` object keyed by server name, each entry a `{command, args}` stdio-server
spec.

```json
{
  "mcpServers": {
    "offload-sidecar": {
      "command": "python3",
      "args": ["/absolute/path/to/offload-sidecar/scripts/offload_sidecar.py"],
      "environment": {
        "OLLAMA_HOST": "http://localhost:11434",
        "OLLAMA_MODEL": "qwen3:14b",
        "AGY_BIN": "agy"
      }
    }
  }
}
```

**Env-var passthrough uses the key `environment`, not `env`.** Confirmed by a
`strings` pass over the `agy` binary matching its MCP-config struct's exact field
names — `mcpServers`, `command`, `args`, `environment`, `headers`, `timeout` — see
`docs/platform-matrix.md`, `## PR 2 re-verification`, token
`ENV_PASSTHROUGH: supported:environment`. That's static-binary evidence, not a live
round-trip confirmation, but it does mean credentials and config *can* reach the
sidecar through Agy — set every key from the config table above that you need
(`OLLAMA_*`, `AGY_*`, plus `SIDECAR_ROOT` if you want output paths scoped to a
project directory other than `mcp_config.json`'s own cwd). Unlike `.mcp.json`,
`${user_config.*}`/`${CLAUDE_PLUGIN_ROOT}` substitution is a Claude Code convention
only — Agy needs literal, already-resolved values.

### OpenCode

OpenCode's own MCP server registration shape was not measured by this repo's
platform spike — only Agy's `mcp_config.json` shape (Item 10, above) and the `agy`
binary's env-key struct were confirmed. Check OpenCode's current docs or `opencode
--help` for its MCP config location and schema before registering; don't assume the
Agy `{command, args, environment}` shape above applies unmodified.

Whichever platform you register on, the entrypoint itself
(`scripts/offload_sidecar.py`) is unchanged — same file, same invocation, same
`OLLAMA_*`/`AGY_*` env vars either config sets directly.

---

## Sizing `num_ctx` (local LLM operations only)

`num_ctx` is the total token window Ollama allocates for one request — system prompt,
input file, *and* generated output all have to fit. The context-budget guard reserves
roughly half of `num_ctx` for output, so as a rule of thumb: **set `num_ctx` to
roughly 2× the token size of the largest file you expect to process** (~4 chars per
token for logs/prose). The trade-off is memory: `num_ctx` sizes the KV cache on top of
the model weights, per tier. If a call fails with `"input too large for the current
context budget"`, raise that tier's `num_ctx`, `split_file` the input — or route the
call to `flash`, whose budget is ~1M tokens (remembering that sends the content to
Google).

---

## Usage

### The tool: `process_local_file`

```json
{
  "input_path": "logs/raw.txt",
  "output_path": "logs/triage.json",
  "operation": "triage_ci_log",
  "tier": "flash",
  "instruction": "optional extra guidance for LLM operations",
  "params": {"...": "operation-specific parameters for deterministic operations"},
  "overwrite": false
}
```

- `input_path` / `output_path` — absolute or relative to the project root; must resolve
  **inside** the project directory (the server refuses anything that escapes it, and
  refuses to write through a symlinked `output_path`). `merge_files` uses
  `input_paths` (a list); `split_file` treats `output_path` as an existing directory.
- `tier` — LLM operations only: `deep`, `fast`, `flash`, or `pro` (see the tier
  table). Omit for the operation's default.
- `instruction` — free-text guidance, LLM operations only. **Required** for
  `html_extract` (the question) and `verify_screenshot` (the assertion).
- `params` — deterministic operations only.
- `overwrite` — if the target exists and this isn't `true`, the result is written to
  `<output_path>.new` instead.
- On validation failure the rejected output is written to `<output_path>.rejected`
  and the requested file is left untouched.

### LLM-backed operations

| Operation | Default tier | What it does | Validator checks |
|---|---|---|---|
| `extract_json` | deep | Pulls messy/unstructured input into JSON. | Parses as JSON; record-count heuristic flags gross record-dropping (line-oriented inputs only). |
| `convert_format` | fast | Converts to the format implied by `output_path`'s extension (.json/.csv). | Parses; consistent CSV columns. |
| `clean_text` | fast | Cleanup/reformatting per `instruction`. | Non-empty; size ratio in [0.15, 4.0]. Weak guarantee. |
| `redact_secrets` | deep | Replaces credential-looking values with `[REDACTED]`. **Keep this local.** | Non-empty; size ratio; known secret shapes must not survive. A safety net, not a guarantee. |
| `summarize` | deep | Concise factual summary. | Non-empty; smaller than large inputs. |
| `yaml_to_json` | fast *(llm fallback only)* | Deterministic via `yq` when installed. | Parses as JSON. |
| `triage_ci_log` | fast | CI/build log → failure triage. | JSON with `verdict`, `error_class`, `failing_step`, `error_excerpt`, `summary`. |
| `summarize_test_run` | fast | Test output → counts + failures clustered by root cause. | JSON with `passed`/`failed`/`skipped`/`failure_clusters`/`summary`. |
| `triage_service_log` | fast | Service log → health verdict, deduplicated error families, anomaly window. | JSON with `healthy`/`error_families`/`anomaly_window`/`summary`. |
| `digest_task_output` | fast | Agent/background-task output or journal → state, last action, blockers. | JSON with `state`/`last_action`/`blockers`/`summary`. |
| `digest_review_comments` | fast | Review comments → actionable vs nits vs questions. | JSON with `actionable`/`nits`/`questions`/`summary`. |
| `security_scan_digest` | fast | Scanner report → critical/high/fixable findings. | JSON with `critical`/`high`/`lower_count`/`fixable`/`summary`. |
| `draft_commit_message` | fast | Git diff → conventional commit message. | Non-empty, no code fences, sane summary-line length. |
| `draft_pr_body` | fast | Diff/log → markdown PR description. | Contains `## Summary` and `## Changes`. |
| `changelog_from_commits` | fast | Commit log → grouped release notes. | Contains markdown bullets. |
| `html_extract` | fast | Question-guided extraction from markup; `instruction` required. | Non-empty. |
| `describe_image` | **flash** (vision) | Image → precise description with exact text transcription. | Non-empty. |
| `verify_screenshot` | **flash** (vision) | Screenshot + assertion (`instruction`) → verdict. | JSON with boolean `pass` + `observed`. |
| `pdf_to_structured` | **flash** (vision) | PDF (incl. scanned) → structured JSON. | Parses as JSON. |

The three vision operations error on local tiers — Ollama text models can't take
them. Every text LLM operation has a context-budget guard; on cloud tiers, inputs
over ~200KB are handed to agy by path (it reads the file itself) instead of inlined.

### Deterministic operations (no model in the loop)

Unchanged from ollama-sidecar — `dedupe_lines`, `sort_lines`, `filter_lines`,
`slice_lines`, `regex_replace`, `base64_encode`/`decode`, `hash_file`, `text_stats`,
`strip_ansi_codes`, `normalize_log_timestamps`, `extract_fields`, `json_format`,
`jsonl_to_json`/`json_to_jsonl`, `csv_to_json`/`json_to_csv`, `toml_to_json`,
`xml_to_json`, `html_to_text`, `plist_to_json`, `sqlite_to_json`, `yaml_to_json`
(via `yq`), `json_to_yaml` (requires `yq`), `split_file`, `merge_files` — see the
tool's operation enum for per-op `params`. Two new ones:

| Operation | What it does | `params` | Validator / limitation |
|---|---|---|---|
| `json_digest` | Big JSON → shape summary: schema, key/record counts, truncated samples — without reproducing the data. | — | Output JSON has `schema`. |
| `xlsx_extract` | Excel `.xlsx` → JSON `{sheet: [[rows]]}` via stdlib zip+XML (no openpyxl). | `sheet` (optional name or 1-based index) | **Dates stay Excel serial numbers** (styles.xml is deliberately not interpreted). |

### Adding an operation

**LLM-backed:** add an entry to `OPERATIONS` in `scripts/offload_sidecar.py` with
`"kind": "llm"`, a `"default_tier"`, a prompt-builder, and a
`validate(input_text, output_text, output_path, instruction) -> (bool, reason)`.
Digest-style ops can reuse `_make_digest_prompt`/`_make_digest_validator`. Set
`"media": True` for vision ops (cloud-only, file passed by path) and
`"requires_instruction": True` when the instruction is the task itself.

**Deterministic:** `"kind": "deterministic"`, a
`transform(input_bytes, params, instruction, output_path) -> output_bytes` (raise
`SidecarError` on malformed input), and a matching `validate` over bytes. Set
`"reads_own_input": True` to receive the file path instead of bytes.

No build step — edit the file and it's live on the next server restart.

### Diagnosing connectivity and quota: `status`

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/offload_sidecar.py status
```

Probes each local tier (reachability, latency, pulled vs loaded models, cold-start
hints — `OLLAMA_STATUS_TIMEOUT` controls the wait, default 5s) and reports each cloud
tier's binary presence, configured model, budget usage per window, and any active
lockout — **without spending a single agy call**. Exit code reflects local tiers
only.

---

## Failure modes (all structured `status:"error"`, never a hang or silent bad write)

- Paths missing, empty, or escaping the project root; output parent directory missing.
- Malformed `params`, or a deterministic operation's input isn't what it expects.
- Missing `instruction` on `html_extract`/`verify_screenshot`.
- A vision operation routed to a local tier.
- Local LLM: tier unreachable with no different-host local tier to fail over to;
  input too large for `num_ctx`; truncated generation; Ollama HTTP errors.
- Cloud LLM: **budget exhausted or model quota-locked (rejected before agy is
  spawned)**; agy binary missing; agy needs interactive re-login; agy timeout; empty
  output twice (a known agy non-TTY bug, retried once automatically).
- Output fails its operation's validator (written to `<output_path>.rejected`).

**Keep-warm pattern (local):** if cold-start timeouts recur, a cron job that pings
`ollama_host` with `keep_alive` keeps the model in VRAM; `status` tells you whether
that's actually your problem.

**A note on scripted agy use:** this plugin drives the *official* agy binary with its
own sign-in, serially, at human-plausible volumes — it never extracts or replays
Google's OAuth tokens (the pattern behind Google's early-2026 enforcement wave
against third-party Antigravity clients). Residual ToS risk isn't zero; the
conservative default budgets exist partly for that reason.

---

## License

MIT
