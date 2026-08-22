"""Routing descriptions are dispatch contracts, not marketing copy."""

from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROUTED_FILES = (
    sorted((ROOT / ".claude" / "commands").glob("*.md"))
    + sorted((ROOT / "plugins").glob("*/commands/*.md"))
    + sorted((ROOT / "plugins").glob("*/skills/*/SKILL.md"))
    + sorted((ROOT / "dist" / "opencode" / "commands").glob("*.md"))
    + sorted((ROOT / "dist" / "agy").glob("*/skills/*.md"))
)
ROUTING_CONDITION = re.compile(r"\buse (?:only )?(?:when|for)\b", re.I)
ROUTING_BOUNDARY = re.compile(
    r"\b(?:do not use|don't use|only when|not (?:for|when|to)|instead of)\b"
    r"|\buse\b.{0,100}\binstead\b|\buse /",
    re.I,
)


def frontmatter_description(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        return ""
    lines = match.group(1).splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("description:"):
            continue
        value = line.split(":", 1)[1].strip()
        block = re.fullmatch(r"([>|])([+-])?", value)
        if value and not block:
            return value
        folded = []
        for continuation in lines[index + 1 :]:
            if continuation.startswith((" ", "\t")):
                folded.append(continuation.strip())
            else:
                break
        return ("\n" if block and block.group(1) == "|" else " ").join(folded)
    return ""


class RoutingDescriptionTest(unittest.TestCase):
    def test_frontmatter_parser_accepts_yaml_multiline_forms(self):
        cases = {
            "folded-strip": "description: >-\n  Use when folded.\n  Do not use otherwise.",
            "literal-strip": "description: |-\n  Use when literal.\n  Do not use otherwise.",
            "plain-indented": "description:\n  Use when plain.\n  Do not use otherwise.",
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, frontmatter in cases.items():
                with self.subTest(name=name):
                    path = Path(tmp) / f"{name}.md"
                    path.write_text(f"---\n{frontmatter}\n---\n", encoding="utf-8")
                    self.assertIn("Use when", frontmatter_description(path))

    def test_generic_that_is_phrase_is_not_a_routing_boundary(self):
        self.assertIsNone(ROUTING_BOUNDARY.search("Use when that is convenient."))

    def test_study_ports_do_not_route_to_claude_model_aliases(self):
        for relative in (
            "dist/opencode/commands/ape-study.md",
            "dist/agy/ape/skills/study.md",
        ):
            with self.subTest(path=relative):
                text = (ROOT / relative).read_text(encoding="utf-8")
                self.assertNotRegex(text, r"\b(?:haiku|sonnet|opus)\b")

    def test_every_command_and_skill_says_when_to_route_to_it(self):
        failures = []
        for path in ROUTED_FILES:
            description = frontmatter_description(path)
            if not ROUTING_CONDITION.search(description):
                failures.append(str(path.relative_to(ROOT)))
        self.assertFalse(
            failures,
            "Descriptions must state a routing condition with 'Use when/for':\n"
            + "\n".join(failures),
        )

    def test_every_command_and_skill_names_a_routing_boundary(self):
        failures = []
        for path in ROUTED_FILES:
            if not ROUTING_BOUNDARY.search(frontmatter_description(path)):
                failures.append(str(path.relative_to(ROOT)))
        self.assertFalse(
            failures,
            "Descriptions must distinguish the nearest non-use case or alternative:\n"
            + "\n".join(failures),
        )


if __name__ == "__main__":
    unittest.main()
