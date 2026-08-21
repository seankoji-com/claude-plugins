"""Routing descriptions are dispatch contracts, not marketing copy."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROUTED_FILES = (
    sorted((ROOT / "plugins").glob("*/commands/*.md"))
    + sorted((ROOT / "plugins").glob("*/skills/*/SKILL.md"))
    + sorted((ROOT / "dist" / "opencode" / "commands").glob("*.md"))
    + sorted((ROOT / "dist" / "agy").glob("*/skills/*.md"))
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
        if value not in {">", "|"}:
            return value
        folded = []
        for continuation in lines[index + 1 :]:
            if continuation.startswith((" ", "\t")):
                folded.append(continuation.strip())
            else:
                break
        return " ".join(folded)
    return ""


class RoutingDescriptionTest(unittest.TestCase):
    def test_every_command_and_skill_says_when_to_route_to_it(self):
        failures = []
        for path in ROUTED_FILES:
            description = frontmatter_description(path)
            if not re.search(r"\buse (?:only )?(?:when|for)\b", description, re.I):
                failures.append(str(path.relative_to(ROOT)))
        self.assertFalse(
            failures,
            "Descriptions must state a routing condition with 'Use when/for':\n"
            + "\n".join(failures),
        )

    def test_every_command_and_skill_names_a_routing_boundary(self):
        failures = []
        boundary = re.compile(
            r"\b(?:do not|instead|only when)\b|\buse /|\bthat is\b", re.I
        )
        for path in ROUTED_FILES:
            if not boundary.search(frontmatter_description(path)):
                failures.append(str(path.relative_to(ROOT)))
        self.assertFalse(
            failures,
            "Descriptions must distinguish the nearest non-use case or alternative:\n"
            + "\n".join(failures),
        )


if __name__ == "__main__":
    unittest.main()
