#!/usr/bin/env python3
"""thinking_state.py — deterministic state resolver for /elephant-goldfish-thinking.

The command needs the same handful of facts at every turn: which topics exist, which
phase this one is in, which artifacts are on disk, what was already published. Answering
that by `ls`-ing, `cat`-ing and `stat`-ing pulls directory listings and whole documents
into the model's context to recover a few dozen bytes of state. This script answers it in
one compact JSON blob instead — `resolve` is designed to be the single call the command
makes when it starts.

No network, no model, no side effects except under `init`/`set`. Pure enough to test.

Usage:
  thinking_state.py list [--root DIR]
  thinking_state.py resolve <slug> [--root DIR]
  thinking_state.py init <slug> --output-type research|implementation
                    [--title TEXT] [--github issue|discussion|none] [--root DIR]
  thinking_state.py set <slug> KEY=VALUE [KEY=VALUE ...] [--root DIR]
  thinking_state.py gate <slug> --require discovery,spec [--root DIR]

`gate` is fail-closed: a missing artifact exits 1 and names it. Every other subcommand
prints JSON to stdout and exits 0, or prints a JSON error object and exits 1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ROOT = "thinking"

# Artifact filenames in phase order. The order is load-bearing: NEXT_PHASE walks it to
# decide what the command should do next, so inserting a stage means inserting it here.
ARTIFACTS = ("discovery.md", "spec.md", "handoff.md")
PHASE_FOR_MISSING = {"discovery.md": "discovery", "spec.md": "spec", "handoff.md": "handoff"}

OUTPUT_TYPES = ("research", "implementation")
GITHUB_MODES = ("issue", "discussion", "none")

# Deliberately strict: this string becomes a directory name and is interpolated into
# `gh` arguments downstream. Anything with a dot, slash or space is rejected outright
# rather than sanitized, so a traversal attempt fails loudly instead of silently
# resolving somewhere unexpected.
SLUG_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

# The script's own CLI is unambiguous — a slug is always a positional after a subcommand, so
# `resolve list` reads fine. The ambiguity is one level up: /elephant-goldfish-thinking takes
# a bare `$ARGUMENTS` that is either the word `list` or a topic slug, and a topic actually
# named `list` makes that undecidable. Reserve the subcommand names so the collision cannot
# be created in the first place.
RESERVED_SLUGS = frozenset({"list", "resolve", "init", "set", "gate"})


class StateError(Exception):
    """Anything the caller did wrong. Rendered as a JSON error object, exit 1."""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate_slug(slug: str) -> str:
    if not SLUG_RE.match(slug or ""):
        raise StateError(
            f"invalid slug {slug!r}: use lowercase kebab-case, 1-63 chars, "
            "starting and ending alphanumeric (e.g. 'buy-family-car')"
        )
    if slug in RESERVED_SLUGS:
        raise StateError(
            f"slug {slug!r} is reserved — it collides with a subcommand name and would make "
            "the command's own argument ambiguous; pick another (e.g. 'list-topics')"
        )
    return slug


def topic_dir(root: Path, slug: str) -> Path:
    return root / validate_slug(slug)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def meta_path(tdir: Path) -> Path:
    return tdir / "meta.json"


def read_meta(tdir: Path) -> dict:
    mp = meta_path(tdir)
    if not mp.exists():
        return {}
    try:
        return json.loads(mp.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise StateError(f"{mp} is not valid JSON: {exc}") from exc


def write_meta(tdir: Path, meta: dict) -> None:
    meta["updated_at"] = utcnow()
    tdir.mkdir(parents=True, exist_ok=True)
    meta_path(tdir).write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def artifact_state(tdir: Path, meta: dict) -> dict:
    """Per-artifact existence, digest and publish status.

    `published` compares the artifact's current digest against the digest recorded when
    it was last posted to GitHub. That makes republish decisions idempotent *and*
    correctly re-flags a doc that was edited after publishing, which an exists-only flag
    would miss.
    """
    published = meta.get("published", {})
    out = {}
    for name in ARTIFACTS:
        path = tdir / name
        if not path.exists():
            out[name] = {"exists": False}
            continue
        digest = sha256_of(path)
        out[name] = {
            "exists": True,
            "sha256": digest,
            "bytes": path.stat().st_size,
            "published": published.get(name) == digest,
        }
    return out


def next_phase(artifacts: dict) -> str:
    for name in ARTIFACTS:
        if not artifacts.get(name, {}).get("exists"):
            return PHASE_FOR_MISSING[name]
    return "complete"


def resolve(root: Path, slug: str) -> dict:
    tdir = topic_dir(root, slug)
    meta = read_meta(tdir)
    artifacts = artifact_state(tdir, meta)
    return {
        "slug": slug,
        "root": str(root),
        "dir": str(tdir),
        "exists": tdir.is_dir(),
        "meta": meta,
        "artifacts": artifacts,
        "next_phase": next_phase(artifacts),
    }


def cmd_list(args) -> dict:
    root = Path(args.root)
    topics = []
    if root.is_dir():
        for tdir in sorted(p for p in root.iterdir() if p.is_dir()):
            meta = read_meta(tdir)
            artifacts = artifact_state(tdir, meta)
            topics.append(
                {
                    "slug": tdir.name,
                    "title": meta.get("title", tdir.name),
                    "output_type": meta.get("output_type"),
                    "next_phase": next_phase(artifacts),
                    "updated_at": meta.get("updated_at"),
                }
            )
    return {"root": str(root), "topics": topics}


def cmd_resolve(args) -> dict:
    return resolve(Path(args.root), args.slug)


def cmd_init(args) -> dict:
    root = Path(args.root)
    tdir = topic_dir(root, args.slug)
    if args.output_type not in OUTPUT_TYPES:
        raise StateError(f"--output-type must be one of {'|'.join(OUTPUT_TYPES)}, got {args.output_type!r}")
    if args.github not in GITHUB_MODES:
        raise StateError(f"--github must be one of {'|'.join(GITHUB_MODES)}, got {args.github!r}")

    meta = read_meta(tdir)
    if meta:
        # Re-running init on a live topic must not silently reset output_type or drop the
        # published map — the command uses this path to resume, not to restart.
        raise StateError(
            f"topic {args.slug!r} already initialised (phase: {next_phase(artifact_state(tdir, meta))}); "
            "use `set` to change fields, or pick a different slug"
        )

    meta = {
        "slug": args.slug,
        "title": args.title or args.slug.replace("-", " "),
        "output_type": args.output_type,
        "created_at": utcnow(),
        "github": {"mode": args.github, "repo": None, "number": None, "url": None, "category": None},
        "published": {},
    }
    write_meta(tdir, meta)
    return resolve(root, args.slug)


def set_dotted(meta: dict, key: str, value):
    # `published` is the one map in the schema whose keys are filenames, so they contain
    # dots and cannot survive this splitter: `published.discovery.md` would nest into
    # {"published": {"discovery": {"md": ...}}}, which no lookup would ever match and no
    # error would ever report — every publish check silently false, forever. Refuse the
    # whole prefix rather than special-casing it; gh_publish.py owns that map anyway.
    if key == "published" or key.startswith("published."):
        raise StateError(
            "refusing to set 'published' through `set`: its keys are filenames containing "
            "dots, which this dotted-key syntax cannot address. gh_publish.py maintains it."
        )
    parts = key.split(".")
    cursor = meta
    for part in parts[:-1]:
        cursor = cursor.setdefault(part, {})
        if not isinstance(cursor, dict):
            raise StateError(f"cannot set {key!r}: {part!r} is not an object")
    cursor[parts[-1]] = value


def coerce(raw: str):
    """JSON-first so `--` callers can pass numbers, null and booleans; bare words stay strings."""
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def cmd_set(args) -> dict:
    root = Path(args.root)
    tdir = topic_dir(root, args.slug)
    meta = read_meta(tdir)
    if not meta:
        raise StateError(f"no topic {args.slug!r} under {root} — run `init` first")
    for pair in args.pairs:
        if "=" not in pair:
            raise StateError(f"expected KEY=VALUE, got {pair!r}")
        key, raw = pair.split("=", 1)
        set_dotted(meta, key.strip(), coerce(raw))
    write_meta(tdir, meta)
    return resolve(root, args.slug)


def cmd_gate(args) -> dict:
    """Fail-closed artifact gate. Missing or empty input is an error, never a warning.

    Existence alone is too weak a check: a 0-byte discovery.md is an interrupted phase, not
    a completed one, and letting it through means the failure surfaces later in
    render_handoff.py — the wrong component, with a worse message, after the gate has
    already reported "pass".
    """
    root = Path(args.root)
    tdir = topic_dir(root, args.slug)
    required = [r.strip() for r in args.require.split(",") if r.strip()]
    missing, empty = [], []
    for req in required:
        name = req if req.endswith(".md") else f"{req}.md"
        path = tdir / name
        if not path.exists():
            missing.append(name)
        elif not path.read_text(encoding="utf-8").strip():
            empty.append(name)
    if missing or empty:
        problems = []
        if missing:
            problems.append(f"missing: {', '.join(missing)}")
        if empty:
            problems.append(f"empty: {', '.join(empty)}")
        raise StateError(
            f"topic {args.slug!r} is not ready ({'; '.join(problems)}) — "
            "run the earlier phase before this one"
        )
    return {"slug": args.slug, "gate": "pass", "required": required}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="thinking_state.py", description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=DEFAULT_ROOT, help=f"topics directory (default: {DEFAULT_ROOT})")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="list all topics")

    p_resolve = sub.add_parser("resolve", help="full state for one topic")
    p_resolve.add_argument("slug")

    p_init = sub.add_parser("init", help="create a topic")
    p_init.add_argument("slug")
    p_init.add_argument("--output-type", required=True, choices=OUTPUT_TYPES)
    p_init.add_argument("--title", default=None)
    p_init.add_argument("--github", default="none", choices=GITHUB_MODES)

    p_set = sub.add_parser("set", help="update meta fields (dotted keys allowed)")
    p_set.add_argument("slug")
    p_set.add_argument("pairs", nargs="+", metavar="KEY=VALUE")

    p_gate = sub.add_parser("gate", help="fail-closed check that artifacts exist")
    p_gate.add_argument("slug")
    p_gate.add_argument("--require", required=True, help="comma-separated artifact names")

    return parser


HANDLERS = {
    "list": cmd_list,
    "resolve": cmd_resolve,
    "init": cmd_init,
    "set": cmd_set,
    "gate": cmd_gate,
}


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = HANDLERS[args.cmd](args)
    except StateError as exc:
        json.dump({"error": str(exc)}, sys.stdout)
        sys.stdout.write("\n")
        return 1
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
