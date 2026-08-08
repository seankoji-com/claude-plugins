#!/usr/bin/env python3
"""gh_publish.py — mirror a topic's artifacts to one GitHub Issue or Discussion.

One container per topic; each artifact posted as a comment as it completes, so the thread
reads as the progression of the thinking rather than a single dump at the end.

Publishing is outward-facing and effectively irreversible (edits and deletes leave
traces, and public threads may be indexed). Two guards follow from that:

  * Nothing is created or posted unless a mode was explicitly chosen — `none` is the
    default everywhere upstream, and this script refuses to guess a mode.
  * `--dry-run` on every mutating subcommand prints exactly what would happen and
    touches nothing, so the caller can show the user the target before committing.

Idempotence is by content digest, not by "did we post before": the sha256 recorded in
meta.json is compared against the artifact's current digest, so an unchanged file is
skipped and an edited one is correctly re-posted as a new comment.

That check is read-then-write with no lock, so two `post` calls racing on the same artifact
could both see it as unpublished and comment twice. Left as-is deliberately: a topic is
driven by one interactive session, the duplicate is visible and harmless, and the lockfile
needed to close it would be a new failure mode (stale locks after a crash) traded against a
cosmetic one.

Usage:
  gh_publish.py detect-repo
  gh_publish.py ensure <slug> --mode issue|discussion [--repo OWNER/NAME]
                [--category NAME] [--root DIR] [--dry-run]
  gh_publish.py post <slug> <artifact.md> [--root DIR] [--dry-run]

Exit codes: 0 ok · 1 usage/state error · 2 environment error (no `gh`, not a repo).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_ROOT = "thinking"
ISSUE_URL_RE = re.compile(r"https://\S+?/issues/(\d+)")

# GitHub caps issue and comment bodies at 65536. Its error phrases this as "characters",
# but that wording is not a reliable guide to what the backend counts, and the two diverge
# by 3x for CJK text. Measure UTF-8 bytes: it is the stricter reading, so we never hand
# GitHub a body it will reject. The cost is conservatively refusing a non-ASCII document
# somewhere between 65536 characters and 65536 bytes — at which point it is a 20+ page
# brief, and the error already points at local-only storage.
#
# This check is advisory rather than load-bearing: run() raises PublishError carrying
# GitHub's own message if the API rejects a body anyway, so an over-long post fails loudly
# either way. What it buys is a better message and no wasted round-trip.
#
# Refuse rather than truncate — a silently clipped brief is worse than no published brief,
# because the thread then looks complete while missing the part that got cut.
MAX_BODY = 65536

ARTIFACT_HEADINGS = {
    "discovery.md": "Step 1 — Problem definition",
    "spec.md": "Step 2 — Evaluation criteria",
    "handoff.md": "The plan",
}


class EnvError(Exception):
    """Something about the environment is missing. Exit 2."""


class PublishError(Exception):
    """Caller error or bad state. Exit 1."""


def run(cmd: list[str], stdin: str | None = None) -> str:
    try:
        proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise EnvError(f"{cmd[0]} not found on PATH") from exc
    if proc.returncode != 0:
        raise PublishError(f"{' '.join(cmd[:3])} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout.strip()


def require_gh() -> None:
    if not shutil.which("gh"):
        raise EnvError("the `gh` CLI is required for publishing — install it or choose local-only storage")


def detect_repo() -> str:
    require_gh()
    try:
        return run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    except PublishError as exc:
        raise EnvError(f"could not detect a GitHub repo from the current directory: {exc}") from exc


def topic_paths(root: str, slug: str) -> tuple[Path, Path]:
    tdir = Path(root) / slug
    meta = tdir / "meta.json"
    if not meta.exists():
        raise PublishError(f"no topic {slug!r} under {root}")
    return tdir, meta


def load_meta(meta_file: Path) -> dict:
    return json.loads(meta_file.read_text(encoding="utf-8"))


def save_meta(meta_file: Path, meta: dict) -> None:
    meta_file.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def graphql(query: str, **variables) -> dict:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        cmd += ["-F", f"{key}={value}"]
    data = json.loads(run(cmd))
    # GitHub answers many real failures — Discussions disabled, missing scope, rate limit,
    # unknown node id — with HTTP 200 and an `errors` array, so a zero exit status is not
    # evidence of success. Surface GitHub's own message here; without this the caller's
    # subscript chain hits a null payload and raises a bare TypeError with nothing in it
    # that would tell anyone what actually went wrong.
    if data.get("errors"):
        raise PublishError(
            "GitHub GraphQL error: "
            + "; ".join(e.get("message", str(e)) for e in data["errors"])
        )
    if not isinstance(data.get("data"), dict):
        raise PublishError(f"unexpected GraphQL response: {json.dumps(data)[:300]}")
    return data


def dig(data: dict, *path: str):
    """Walk a GraphQL response, naming the first missing hop instead of raising TypeError."""
    cursor = data
    for i, key in enumerate(path):
        if not isinstance(cursor, dict) or cursor.get(key) is None:
            raise PublishError(f"GraphQL response missing '{'.'.join(path[: i + 1])}'")
        cursor = cursor[key]
    return cursor


def repo_ids(repo: str, category: str | None) -> tuple[str, str, str]:
    owner, name = repo.split("/", 1)
    data = graphql(
        "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){"
        "id discussionCategories(first:25){nodes{id name}}}}",
        owner=owner,
        name=name,
    )
    try:
        repository = dig(data, "data", "repository")
    except PublishError:
        raise PublishError(f"repository {repo} not found or not accessible") from None
    categories = dig(repository, "discussionCategories", "nodes")
    if not categories:
        raise PublishError(f"{repo} has no Discussion categories — enable Discussions on the repo first")
    chosen = None
    if category:
        chosen = next((c for c in categories if c["name"].lower() == category.lower()), None)
        if not chosen:
            available = ", ".join(c["name"] for c in categories)
            raise PublishError(f"no Discussion category named {category!r} in {repo}; available: {available}")
    else:
        # Prefer a category that reads like open-ended thinking over an announcement or
        # Q&A board, but never fail for want of a preference.
        for want in ("Ideas", "General", "Show and tell"):
            chosen = next((c for c in categories if c["name"] == want), None)
            if chosen:
                break
        chosen = chosen or categories[0]
    return repository["id"], chosen["id"], chosen["name"]


def body_for(path: Path, slug: str) -> str:
    heading = ARTIFACT_HEADINGS.get(path.name, path.name)
    body = f"## {heading}\n\n_`{slug}/{path.name}` — posted by `/thinking`_\n\n{path.read_text(encoding='utf-8').strip()}\n"
    size = len(body.encode("utf-8"))
    if size > MAX_BODY:
        raise PublishError(
            f"{path.name} renders to {size} UTF-8 bytes ({len(body)} characters), over "
            f"GitHub's {MAX_BODY} limit — shorten the document or switch this topic to "
            "local-only storage"
        )
    return body


def cmd_ensure(args) -> int:
    tdir, meta_file = topic_paths(args.root, args.slug)
    meta = load_meta(meta_file)
    gh_meta = meta.setdefault("github", {})

    mode = args.mode
    if mode == "none":
        raise PublishError("`ensure` needs an explicit --mode of issue or discussion")

    if gh_meta.get("number"):
        print(json.dumps({"status": "exists", **gh_meta}, indent=2))
        return 0

    repo = args.repo or detect_repo()
    title = f"[thinking] {meta.get('title', args.slug)}"
    intro = (
        f"Thinking record for **{meta.get('title', args.slug)}** (`{args.slug}`), "
        f"output type: **{meta.get('output_type', 'unknown')}**.\n\n"
        "Produced with [`/thinking`](https://github.com/seankoji/claude-plugins/tree/master/plugins/elephant-goldfish) "
        "— steps 1 and 2 of Rensin's three-step process. Each artifact is posted as a comment below as it completes.\n"
    )

    if args.dry_run:
        print(json.dumps({"status": "dry-run", "mode": mode, "repo": repo, "title": title}, indent=2))
        return 0

    require_gh()
    if mode == "issue":
        # `gh issue create` writes the URL to stdout, but not necessarily alone — version
        # notices and other advisories land there too. Search for the issue URL rather than
        # assuming the whole of stdout is one, so an extra line is noise instead of a
        # ValueError from int() on something that was never a number.
        out = run(["gh", "issue", "create", "--repo", repo, "--title", title, "--body", intro])
        match = ISSUE_URL_RE.search(out)
        if not match:
            raise PublishError(f"no issue URL in `gh issue create` output: {out[:200]!r}")
        url, number = match.group(0), int(match.group(1))
        gh_meta.update({"mode": "issue", "repo": repo, "number": number, "url": url, "node_id": None, "category": None})
    else:
        repo_id, cat_id, cat_name = repo_ids(repo, args.category)
        data = graphql(
            "mutation($r:ID!,$c:ID!,$t:String!,$b:String!){createDiscussion(input:{"
            "repositoryId:$r,categoryId:$c,title:$t,body:$b}){discussion{id number url}}}",
            r=repo_id,
            c=cat_id,
            t=title,
            b=intro,
        )
        disc = dig(data, "data", "createDiscussion", "discussion")
        gh_meta.update(
            {
                "mode": "discussion",
                "repo": repo,
                "number": disc["number"],
                "url": disc["url"],
                "node_id": disc["id"],
                "category": cat_name,
            }
        )

    save_meta(meta_file, meta)
    print(json.dumps({"status": "created", **gh_meta}, indent=2))
    return 0


def cmd_post(args) -> int:
    tdir, meta_file = topic_paths(args.root, args.slug)
    meta = load_meta(meta_file)
    gh_meta = meta.get("github", {})

    if gh_meta.get("mode", "none") == "none":
        raise PublishError(f"topic {args.slug!r} is local-only — nothing to publish to")
    if not gh_meta.get("number"):
        raise PublishError(f"no Issue/Discussion for {args.slug!r} yet — run `ensure` first")

    artifact = tdir / args.artifact
    if not artifact.exists():
        raise PublishError(f"no such artifact: {artifact}")

    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    published = meta.setdefault("published", {})
    if published.get(args.artifact) == digest:
        print(json.dumps({"status": "unchanged", "artifact": args.artifact, "url": gh_meta.get("url")}, indent=2))
        return 0

    body = body_for(artifact, args.slug)
    if args.dry_run:
        print(json.dumps({"status": "dry-run", "artifact": args.artifact, "target": gh_meta.get("url"), "bytes": len(body)}, indent=2))
        return 0

    require_gh()
    if gh_meta["mode"] == "issue":
        url = run(["gh", "issue", "comment", str(gh_meta["number"]), "--repo", gh_meta["repo"], "--body-file", "-"], stdin=body)
    else:
        data = graphql(
            "mutation($d:ID!,$b:String!){addDiscussionComment(input:{discussionId:$d,body:$b}){comment{url}}}",
            d=gh_meta["node_id"],
            b=body,
        )
        url = dig(data, "data", "addDiscussionComment", "comment", "url")

    published[args.artifact] = digest
    save_meta(meta_file, meta)
    print(json.dumps({"status": "posted", "artifact": args.artifact, "url": url}, indent=2))
    return 0


def cmd_detect(args) -> int:
    print(json.dumps({"repo": detect_repo()}, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gh_publish.py", description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=DEFAULT_ROOT)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("detect-repo", help="print the GitHub repo for the current directory")

    p_ensure = sub.add_parser("ensure", help="find or create the topic's Issue/Discussion")
    p_ensure.add_argument("slug")
    p_ensure.add_argument("--mode", required=True, choices=("issue", "discussion", "none"))
    p_ensure.add_argument("--repo", default=None, help="OWNER/NAME; detected from cwd when omitted")
    p_ensure.add_argument("--category", default=None, help="Discussion category name")
    p_ensure.add_argument("--dry-run", action="store_true")

    p_post = sub.add_parser("post", help="post one artifact as a comment")
    p_post.add_argument("slug")
    p_post.add_argument("artifact")
    p_post.add_argument("--dry-run", action="store_true")

    return parser


HANDLERS = {"detect-repo": cmd_detect, "ensure": cmd_ensure, "post": cmd_post}


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return HANDLERS[args.cmd](args)
    except EnvError as exc:
        print(f"gh_publish: {exc}", file=sys.stderr)
        return 2
    except (PublishError, json.JSONDecodeError, KeyError) as exc:
        print(f"gh_publish: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
