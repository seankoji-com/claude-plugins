#!/usr/bin/env python3
"""render_handoff.py — assemble handoff.md, the input to step 3.

`handoff.md` is the deliverable of /elephant-goldfish:thinking: a single self-contained
document you paste as the first message of a fresh session (or hand to /imps:imps). It is
pure concatenation of documents that already exist on disk, so the model must never
generate it — having Claude re-emit discovery.md and spec.md into a third file costs
output tokens at output-token prices to produce bytes that are already sitting there,
and introduces a chance of paraphrasing the brief it is supposed to reproduce verbatim.

Templates live in ../templates/handoff.<output_type>.md and are chosen from meta.json's
output_type, so the research and implementation paths differ in framing without the
caller deciding anything at render time.

Usage:
  render_handoff.py <slug> [--root DIR] [--template-dir DIR] [--stdout]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ROOT = "thinking"
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z_]+)\}\}")


class RenderError(Exception):
    pass


def default_template_dir() -> Path:
    """Resolve bundled templates relative to this file — never an absolute machine path.

    CLAUDE_PLUGIN_ROOT is honoured when set (that is how the command invokes it), but the
    __file__-relative fallback means the script also works when run directly from a
    checkout or a test harness.
    """
    import os

    root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if root:
        candidate = Path(root) / "templates"
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent / "templates"


def read_required(path: Path, what: str) -> str:
    if not path.exists():
        raise RenderError(f"missing {what}: {path} — run the earlier phase first")
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        raise RenderError(f"{what} at {path} is empty")
    return text


def render(template: str, values: dict) -> str:
    """Substitute {{PLACEHOLDER}} tokens found in the TEMPLATE. User content stays inert.

    The unknown-placeholder check runs against the template *before* substitution, never
    against the result. Scanning the output conflates two different things: a typo in a
    template we ship, and a brace pair inside the user's own documents. Only the first is a
    bug. The second is ordinary content — Mustache and Handlebars snippets, `{{API_KEY}}`
    style placeholders in API notes, or a discovery.md that discusses this plugin's own
    templates — and aborting on it would break the render of a document whose entire job is
    to reproduce discovery.md and spec.md verbatim.

    Substituted values are never rescanned: re.sub does not re-examine what a replacement
    function returns, so a `{{SPEC}}` inside discovery.md passes through as literal text
    rather than being treated as a placeholder or as an error.
    """
    unknown = sorted({key for key in PLACEHOLDER_RE.findall(template) if key not in values})
    if unknown:
        raise RenderError(
            "template references unknown placeholder(s): "
            + ", ".join("{{%s}}" % key for key in unknown)
        )
    return PLACEHOLDER_RE.sub(lambda match: values[match.group(1)], template)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="render_handoff.py", description=__doc__.split("\n")[0])
    parser.add_argument("slug")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--template-dir", default=None)
    parser.add_argument("--stdout", action="store_true", help="print instead of writing handoff.md")
    args = parser.parse_args(argv)

    try:
        tdir = Path(args.root) / args.slug
        meta_file = tdir / "meta.json"
        if not meta_file.exists():
            raise RenderError(f"no topic {args.slug!r} under {args.root} — nothing to render")
        meta = json.loads(meta_file.read_text(encoding="utf-8"))

        output_type = meta.get("output_type")
        if output_type not in ("research", "implementation"):
            raise RenderError(f"meta.json has invalid output_type {output_type!r}")

        tpl_dir = Path(args.template_dir) if args.template_dir else default_template_dir()
        tpl_file = tpl_dir / f"handoff.{output_type}.md"
        if not tpl_file.exists():
            raise RenderError(f"missing template {tpl_file}")

        values = {
            "TOPIC_SLUG": args.slug,
            "TITLE": meta.get("title", args.slug),
            "OUTPUT_TYPE": output_type,
            "GENERATED_AT": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "DISCOVERY": read_required(tdir / "discovery.md", "discovery.md"),
            "SPEC": read_required(tdir / "spec.md", "spec.md"),
        }
        out = render(tpl_file.read_text(encoding="utf-8"), values)
    except (RenderError, json.JSONDecodeError) as exc:
        print(f"render_handoff: {exc}", file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(out)
    else:
        target = tdir / "handoff.md"
        target.write_text(out, encoding="utf-8")
        print(str(target))
    return 0


if __name__ == "__main__":
    sys.exit(main())
