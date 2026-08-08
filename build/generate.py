#!/usr/bin/env python3
"""Generate OpenCode and Antigravity (agy) artifacts from the frozen Claude sources.

Contract: docs/plans/cross-platform-compat.md. Every platform behaviour this relies on is
cited in build/platform-table.json's per-platform `evidence` block, which points at
docs/platform-matrix.md. Nothing here measures a platform; facts come from the matrix or
they do not get used.

Determinism contract (verbatim from the plan):
  * every filesystem enumeration is wrapped in sorted()
  * JSON is dumped with sort_keys=True, indent=2, ensure_ascii=False plus a trailing "\\n"
  * every file is opened with newline="\\n"
  * no timestamps, hostnames, absolute paths, os.environ reads, or dict ordering derived
    from **kwargs

Usage:
    python3 build/generate.py                 # whole tree
    python3 build/generate.py --only <plugin> # one plugin's outputs only
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import stat
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "build"
PLUGINS_DIR = REPO_ROOT / "plugins"
OVERRIDES_DIR = BUILD_DIR / "overrides"
NPM_DIR = BUILD_DIR / "npm"
DIST_DIR = REPO_ROOT / "dist"

PLATFORM_TABLE_PATH = BUILD_DIR / "platform-table.json"
GENERATION_MANIFEST_PATH = BUILD_DIR / "generation-manifest.json"

# Sorted, so iteration order never depends on the table's key order.
PLATFORMS = ("agy", "opencode")

HEADING_RE = re.compile(r"^#{1,6} ")
FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z0-9_.-]+):")

# The invariants dist/ must hold. Checked here so a porting mistake fails at generation
# time with a file and line, rather than only in build/dist-lint.sh much later.
FORBIDDEN_PATTERNS = (
    (
        re.compile(r"\$HOME|\$\{HOME\b"),
        "references the home environment variable; dist/ must carry no machine paths",
    ),
    (
        re.compile(r"(^|[^_A-Za-z0-9])/(Users|home|opt|usr/local)/"),
        "contains an absolute machine path; the installer resolves paths at install time",
    ),
    (
        re.compile(r"CLAUDE_PLUGIN_ROOT"),
        "leaks the Claude plugin-root variable; use the __PLUGIN_ROOT__ placeholder",
    ),
)
CLAUDE_DIR_RE = re.compile(r"\.claude/")
AUDIT_LOG_BASENAME = "audit.jsonl"

SENTINEL_AUDIT = "\x00audit-%d\x00"
SENTINEL_OVERRIDE = "\x00override-%d\x00"


class GenerateError(Exception):
    """A porting or configuration fault. Always fails the run — never a warning."""


# --------------------------------------------------------------------------- io helpers


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:  # pragma: no cover - defensive
        raise GenerateError(f"{rel(path)}: not UTF-8 text ({exc})") from exc


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def load_json(path: Path) -> dict:
    if not path.is_file():
        raise GenerateError(f"missing required input: {rel(path)}")
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise GenerateError(f"{rel(path)}: invalid JSON ({exc})") from exc


def dump_json(data: dict) -> str:
    return json.dumps(data, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def file_mode(path: Path) -> int:
    return 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644


# ------------------------------------------------------------------- frontmatter blocks


def split_frontmatter(text: str, where: str) -> tuple[list[tuple[str, list[str]]], str]:
    """Split leading YAML frontmatter on the `---` delimiter lines. No YAML parser.

    Returns (blocks, body). A block is (top-level key, its raw lines) so folded scalars
    and comments survive re-rendering byte-for-byte.
    """
    if not text.startswith("---\n"):
        return [], text
    end = text.find("\n---\n", 3)
    if end == -1:
        raise GenerateError(f"{where}: frontmatter opened but never closed")
    raw = text[4 : end + 1]
    body = text[end + 5 :]

    blocks: list[list] = []
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line in lines:
        match = FRONTMATTER_KEY_RE.match(line)
        if match and not line[:1].isspace():
            blocks.append([match.group(1), [line]])
        elif blocks:
            blocks[-1][1].append(line)
        elif line.strip():
            raise GenerateError(f"{where}: frontmatter line before any key: {line!r}")
    return [(key, tuple(body_lines)) for key, body_lines in blocks], body


def render_frontmatter(blocks) -> str:
    if not blocks:
        return ""
    lines = ["---"]
    for _key, block_lines in blocks:
        lines.extend(block_lines)
    lines.append("---")
    return "\n".join(lines) + "\n"


def filter_frontmatter(blocks, emit, drop, where: str):
    """Keep only allow-listed keys, in source order. Deny-listed keys are dropped loudly."""
    emit_set = set(emit)
    drop_set = set(drop)
    kept = []
    for key, block_lines in blocks:
        if key in emit_set:
            kept.append((key, block_lines))
        elif key in drop_set:
            continue
        else:
            raise GenerateError(
                f"{where}: frontmatter key {key!r} is neither emitted nor dropped for this "
                f"platform. Add it to build/platform-table.json's emit or drop list — "
                f"silently passing an unmeasured field through is not allowed."
            )
    return kept


# ------------------------------------------------------------------------- override files


class Override:
    """Section replacements and frontmatter additions for one generated file."""

    def __init__(self, path: Path | None = None):
        self.path = path
        self.replacements: list[tuple[str, str | None]] = []
        self.frontmatter: list[tuple[str, str]] = []
        self.used: set[str] = set()

    @property
    def label(self) -> str:
        return rel(self.path) if self.path else "<none>"


def parse_override(path: Path) -> Override:
    """Parse a per-file override.

    Directives, each on its own line:
        <!-- REPLACE-SECTION: <exact heading line> -->  ... <!-- END-SECTION -->
        <!-- DROP-SECTION: <exact heading line> -->
        <!-- SET-FRONTMATTER: <key>: <value> -->

    A "section" runs from its heading line up to the next heading line of any level, or
    end of file. Replacement text is inserted verbatim: the platform mapping does not run
    over it, so write `__PLUGIN_ROOT__` and platform paths directly.
    """
    override = Override(path)
    lines = read_text(path).split("\n")
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        replace = re.fullmatch(r"<!--\s*REPLACE-SECTION:\s*(.+?)\s*-->", line)
        drop = re.fullmatch(r"<!--\s*DROP-SECTION:\s*(.+?)\s*-->", line)
        setfm = re.fullmatch(r"<!--\s*SET-FRONTMATTER:\s*([A-Za-z0-9_-]+):\s*(.*?)\s*-->", line)
        if replace:
            body: list[str] = []
            index += 1
            while index < len(lines) and not re.fullmatch(
                r"<!--\s*END-SECTION\s*-->", lines[index].strip()
            ):
                body.append(lines[index])
                index += 1
            if index >= len(lines):
                raise GenerateError(
                    f"{rel(path)}: REPLACE-SECTION for {replace.group(1)!r} has no END-SECTION"
                )
            override.replacements.append((replace.group(1), "\n".join(body).strip("\n")))
        elif drop:
            override.replacements.append((drop.group(1), None))
        elif setfm:
            override.frontmatter.append((setfm.group(1), setfm.group(2)))
        elif line and not line.startswith("<!--"):
            raise GenerateError(
                f"{rel(path)}:{index + 1}: text outside a directive block: {line!r}"
            )
        index += 1
    if not override.replacements and not override.frontmatter:
        raise GenerateError(f"{rel(path)}: override file contains no directives")
    return override


def load_overrides(plugin: str, platform: str, kind: str) -> dict[str, Override]:
    """kind is 'commands' or 'skills'; returns {stem: Override}."""
    directory = OVERRIDES_DIR / plugin / platform / kind
    if not directory.is_dir():
        return {}
    return {path.stem: parse_override(path) for path in sorted(directory.glob("*.md"))}


def find_section(body_lines: list[str], heading: str) -> tuple[int, int] | None:
    for start, line in enumerate(body_lines):
        if line.strip() != heading:
            continue
        end = start + 1
        while end < len(body_lines) and not HEADING_RE.match(body_lines[end]):
            end += 1
        return start, end
    return None


def apply_override(body: str, override: Override, where: str) -> tuple[str, list[str]]:
    """Swap overridden sections for sentinels so the mapping cannot rewrite them."""
    held: list[str] = []
    for heading, replacement in override.replacements:
        lines = body.split("\n")
        span = find_section(lines, heading)
        if span is None:
            raise GenerateError(
                f"{override.label}: heading {heading!r} not found in {where}. Override "
                f"headings must match the Claude source exactly."
            )
        start, end = span
        if replacement is None:
            lines[start:end] = []
        else:
            token = SENTINEL_OVERRIDE % len(held)
            held.append(replacement)
            lines[start:end] = [token, ""]
        body = "\n".join(lines)
    return body, held


def restore_overrides(text: str, held: list[str]) -> str:
    for index, replacement in enumerate(held):
        text = text.replace(SENTINEL_OVERRIDE % index, replacement)
    return text


# ------------------------------------------------------------------------ the mapping


def build_invocation_map(plugin: str, commands: list[str], platform_table: dict, platform: str):
    """Map this plugin's own /<plugin>:<command> invocations to the platform's form.

    Only the plugin being generated is remapped. A reference to another plugin's Claude
    command is left alone: it is either a genuine "on Claude Code this is X" comparison or
    a cross-plugin note whose porting belongs to that plugin's own overrides.
    """
    naming = platform_table[platform]["command_naming"]
    pairs = []
    for command in commands:
        pairs.append((f"/{plugin}:{command}", "/" + output_command_name(plugin, command, naming)))
    pairs.sort(key=lambda pair: (-len(pair[0]), pair[0]))
    return pairs


def output_command_name(plugin: str, command: str, naming: dict) -> str:
    if not naming.get("namespace"):
        return command
    if command == plugin:
        return plugin
    return f"{plugin}{naming.get('separator', '-')}{command}"


def apply_mapping(text: str, platform_conf: dict, invocation_pairs, source_rel: str) -> str:
    for pre in platform_conf.get("pre_replacements", []):
        required = any(source_rel.endswith(suffix) for suffix in pre.get("required_in", []))
        if pre["find"] in text:
            text = text.replace(pre["find"], pre["replace"])
        elif required:
            raise GenerateError(
                f"{source_rel}: required rewrite not applicable — the source no longer "
                f"contains {pre['find']!r}. Update build/platform-table.json's "
                f"pre_replacements to match the current source."
            )

    audit = platform_conf["audit_log"]
    for index, needle in enumerate(audit["protect"]):
        text = text.replace(needle, SENTINEL_AUDIT % index)

    for find, replace in platform_conf["replacements"]:
        text = text.replace(find, replace)
    for find, replace in invocation_pairs:
        text = text.replace(find, replace)

    for index in range(len(audit["protect"])):
        text = text.replace(SENTINEL_AUDIT % index, audit["canonical"])
    return text


def guard(out_rel: str, text: str) -> None:
    for lineno, line in enumerate(text.split("\n"), start=1):
        for pattern, why in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                raise GenerateError(f"dist/{out_rel}:{lineno}: {why}\n    {line.strip()}")
        if CLAUDE_DIR_RE.search(line) and AUDIT_LOG_BASENAME not in line:
            raise GenerateError(
                f"dist/{out_rel}:{lineno}: unmapped Claude directory reference. Add a "
                f"mapping to build/platform-table.json or an override section for it.\n"
                f"    {line.strip()}"
            )


# ------------------------------------------------------------------------- generation


def plugin_sources(plugin: str) -> tuple[list[Path], list[Path]]:
    commands = sorted((PLUGINS_DIR / plugin / "commands").glob("*.md"))
    skills = sorted((PLUGINS_DIR / plugin / "skills").glob("*/SKILL.md"))
    return commands, skills


def port_config(plugin: str, platform_conf: dict) -> dict:
    path = OVERRIDES_DIR / plugin / "port.json"
    config = {
        "asset_dirs": list(platform_conf["layout"]["asset_dirs_default"]),
        "asset_exclude": {},
        "asset_replacements": {},
        "manifest_overrides": {},
    }
    if path.is_file():
        config.update(load_json(path))
    return config


def apply_asset_replacements(text: str, plugin: str, source_rel: str, table: dict) -> str:
    """Per-file text fixes for copied assets, from build/overrides/<plugin>/port.json.

    Assets are copied, not rendered, so they have no REPLACE-SECTION mechanism. This is
    the narrow equivalent: {"<plugin-relative path>": [[find, replace], ...]}. A pair
    whose `find` is absent is an error rather than a silent no-op, so an edit to the
    Claude source cannot quietly strip a rewrite the generated artifact depends on.
    """
    pairs = table.get(source_rel)
    if not pairs:
        return text
    for find, replace in pairs:
        if find not in text:
            raise GenerateError(
                f"build/overrides/{plugin}/port.json: asset_replacements for "
                f"{source_rel!r} expects {find!r}, which the current source no longer "
                f"contains. Update the pair or drop it."
            )
        text = text.replace(find, replace)
    return text


def asset_files(plugin: str, asset_dirs, asset_exclude=None) -> list[Path]:
    """Every file under asset_dirs, minus the plugin-relative paths in asset_exclude.

    asset_exclude maps a plugin-relative POSIX path to the reason it does not ship — a
    Claude-only harness script, or one whose content cannot satisfy the dist/ invariants.
    A listed path that no longer exists is an error, so the list cannot silently rot into
    shipping a file it was written to hold back.
    """
    excluded = dict(asset_exclude or {})
    for relative, reason in sorted(excluded.items()):
        if not (PLUGINS_DIR / plugin / relative).is_file():
            raise GenerateError(
                f"build/overrides/{plugin}/port.json: asset_exclude lists "
                f"{relative!r} ({reason}), but plugins/{plugin}/{relative} does not "
                f"exist. Remove the entry or fix the path."
            )
    found: list[Path] = []
    for name in sorted(asset_dirs):
        directory = PLUGINS_DIR / plugin / name
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if not path.is_file():
                continue
            if path.relative_to(PLUGINS_DIR / plugin).as_posix() in excluded:
                continue
            found.append(path)
    return found


def render_markdown(
    source: Path,
    override: Override,
    frontmatter_conf: dict,
    platform_conf: dict,
    invocation_pairs,
    extra_frontmatter: list[tuple[str, str]],
) -> str:
    source_rel = rel(source)
    blocks, body = split_frontmatter(read_text(source), source_rel)
    blocks = filter_frontmatter(
        blocks, frontmatter_conf["emit"], frontmatter_conf["drop"], source_rel
    )
    for key, value in extra_frontmatter + override.frontmatter:
        blocks = [(k, v) for k, v in blocks if k != key]
        blocks.insert(0, (key, (f"{key}: {value}",)))

    body, held = apply_override(body, override, source_rel)
    text = render_frontmatter(blocks) + "\n" + body.lstrip("\n")
    text = apply_mapping(text, platform_conf, invocation_pairs, source_rel)
    text = restore_overrides(text, held)
    if not text.endswith("\n"):
        text += "\n"
    return text


def generate_plugin(plugin: str, platform: str, platform_table: dict, outputs: dict) -> None:
    platform_conf = platform_table[platform]
    commands, skills = plugin_sources(plugin)
    command_names = [path.stem for path in commands]
    invocation_pairs = build_invocation_map(plugin, command_names, platform_table, platform)
    config = port_config(plugin, platform_conf)

    if platform == "opencode":
        naming = platform_conf["command_naming"]
        overrides = load_overrides(plugin, platform, "commands")
        for source in commands:
            name = output_command_name(plugin, source.stem, naming)
            text = render_markdown(
                source,
                overrides.pop(source.stem, Override()),
                platform_conf["command_frontmatter"],
                platform_conf,
                invocation_pairs,
                [],
            )
            outputs[f"opencode/{platform_conf['layout']['commands_dir']}/{name}.md"] = (text, 0o644)
        if overrides:
            raise GenerateError(
                f"build/overrides/{plugin}/{platform}/commands: no such command(s): "
                + ", ".join(sorted(overrides))
            )
        asset_root = platform_conf["layout"]["asset_root"].replace("<plugin>", plugin)
        asset_prefix = f"opencode/{asset_root}"
    else:
        overrides = load_overrides(plugin, platform, "skills")
        for source in commands + skills:
            name = source.parent.name if source.name == "SKILL.md" else source.stem
            text = render_markdown(
                source,
                overrides.pop(name, Override()),
                platform_conf["skill_frontmatter"],
                platform_conf,
                invocation_pairs,
                [("name", name)],
            )
            outputs[f"agy/{plugin}/{platform_conf['layout']['skills_dir']}/{name}.md"] = (
                text,
                0o644,
            )
        if overrides:
            raise GenerateError(
                f"build/overrides/{plugin}/{platform}/skills: no such skill(s): "
                + ", ".join(sorted(overrides))
            )
        source_manifest = load_json(PLUGINS_DIR / plugin / ".claude-plugin" / "plugin.json")
        manifest = {}
        for field in sorted(platform_conf["manifest"]["fields"]):
            # A per-plugin override exists because the Claude manifest's own prose can
            # name Claude-only machinery; there is no section mechanism for a JSON field.
            value = config["manifest_overrides"].get(field, source_manifest.get(field))
            if not value:
                raise GenerateError(
                    f"plugins/{plugin}/.claude-plugin/plugin.json: missing required "
                    f"field {field!r} for the Agy manifest"
                )
            manifest[field] = apply_mapping(value, platform_conf, invocation_pairs, plugin)
        outputs[f"agy/{plugin}/{platform_conf['manifest']['filename']}"] = (
            dump_json(manifest),
            0o644,
        )
        asset_prefix = f"agy/{plugin}"

    for source in asset_files(plugin, config["asset_dirs"], config["asset_exclude"]):
        source_rel = rel(source)
        text = apply_mapping(read_text(source), platform_conf, invocation_pairs, source_rel)
        relative = source.relative_to(PLUGINS_DIR / plugin).as_posix()
        text = apply_asset_replacements(text, plugin, relative, config["asset_replacements"])
        outputs[f"{asset_prefix}/{relative}"] = (text, file_mode(source))


def mirror_npm_source(outputs: dict) -> None:
    """The npm channel's package source is authored in build/npm/ and generated into
    dist/opencode/ verbatim — never hand-placed there (contract: 'Versioning')."""
    if not NPM_DIR.is_dir():
        return
    for source in sorted(path for path in NPM_DIR.rglob("*") if path.is_file()):
        relative = source.relative_to(NPM_DIR).as_posix()
        outputs[f"opencode/{relative}"] = (read_text(source), file_mode(source))


# ------------------------------------------------------------------------------ output


def clear_paths(paths) -> None:
    for path in paths:
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()


def plugin_output_targets(plugin: str, platform_table: dict) -> list[Path]:
    targets = [DIST_DIR / "agy" / plugin]
    asset_root = platform_table["opencode"]["layout"]["asset_root"].replace("<plugin>", plugin)
    targets.append(DIST_DIR / "opencode" / asset_root)
    commands_dir = DIST_DIR / "opencode" / platform_table["opencode"]["layout"]["commands_dir"]
    if commands_dir.is_dir():
        for path in sorted(commands_dir.glob("*.md")):
            if path.name == f"{plugin}.md" or path.name.startswith(f"{plugin}-"):
                targets.append(path)
    return targets


def write_outputs(outputs: dict) -> None:
    for out_rel in sorted(outputs):
        text, mode = outputs[out_rel]
        guard(out_rel, text)
    for out_rel in sorted(outputs):
        text, mode = outputs[out_rel]
        path = DIST_DIR / out_rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        path.chmod(mode)


# -------------------------------------------------------------------------------- main


def generatable(manifest: dict) -> tuple[list[str], list[tuple[str, str]]]:
    ready: list[str] = []
    skipped: list[tuple[str, str]] = []
    for plugin in sorted(manifest):
        statuses = {platform: manifest[plugin].get(platform) for platform in PLATFORMS}
        if not any(status == "full" for status in statuses.values()):
            skipped.append((plugin, f"{statuses['opencode']}/{statuses['agy']} in the manifest"))
        elif not (OVERRIDES_DIR / plugin).is_dir():
            skipped.append((plugin, f"not ported yet — build/overrides/{plugin}/ does not exist"))
        else:
            ready.append(plugin)
    return ready, skipped


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--only",
        metavar="PLUGIN",
        help="regenerate just this plugin's outputs, leaving the rest of dist/ alone",
    )
    args = parser.parse_args(argv)

    platform_table = load_json(PLATFORM_TABLE_PATH)
    manifest = load_json(GENERATION_MANIFEST_PATH)
    for platform in PLATFORMS:
        if platform not in platform_table:
            raise GenerateError(f"{rel(PLATFORM_TABLE_PATH)}: missing platform {platform!r}")

    ready, skipped = generatable(manifest)

    if args.only:
        plugin = args.only
        if plugin not in manifest:
            raise GenerateError(
                f"--only {plugin}: not in {rel(GENERATION_MANIFEST_PATH)} "
                f"(known: {', '.join(sorted(manifest))})"
            )
        if plugin not in ready:
            reason = dict(skipped)[plugin]
            raise GenerateError(f"--only {plugin}: not generatable — {reason}")
        plugins = [plugin]
        clear_paths(plugin_output_targets(plugin, platform_table))
    else:
        plugins = ready
        clear_paths([DIST_DIR])

    outputs: dict[str, tuple[str, int]] = {}
    for plugin in plugins:
        for platform in PLATFORMS:
            if manifest[plugin].get(platform) == "full":
                generate_plugin(plugin, platform, platform_table, outputs)
    mirror_npm_source(outputs)
    write_outputs(outputs)

    for plugin in plugins:
        print(f"generated  {plugin}")
    if not args.only:
        for plugin, reason in skipped:
            print(f"skipped    {plugin}  ({reason})")
    print(f"{len(outputs)} file(s) under dist/")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenerateError as error:
        print(f"generate.py: {error}", file=sys.stderr)
        sys.exit(1)
