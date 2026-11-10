"""pi-skill-filter 的纯标准库验收测试。"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/pi-skill-filter.py"


class PiSkillFilterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.root = self.base / "jstack"
        self.settings = self.base / "pi" / "agent" / "settings.json"
        self.agents = self.base / "agents" / "skills"
        self.write_skill(self.root / "plugins/flow/skills/review", "review")
        self.write_skill(self.root / "plugins/pstack/skills/poteto-mode", "poteto-mode")
        self.write_skill(self.root / "plugins/spec/skills/engineering/wayfinder", "wayfinder")
        self.write_skill(self.agents / "review", "review")
        self.write_skill(self.agents / "wayfinder", "wayfinder")
        self.write_skill(self.agents / "other", "other")
        self.settings.parent.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_skill(self, directory: Path, name: str) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: fixture\n---\n", encoding="utf-8"
        )

    def source(self) -> str:
        return os.path.relpath(self.root, self.settings.parent)

    def write_settings(self, packages: list[object]) -> None:
        self.settings.write_text(
            json.dumps({"packages": packages}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def run_filter(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCRIPT),
                "--settings",
                str(self.settings),
                "--agents",
                str(self.agents),
                "--root",
                str(self.root),
            ],
            capture_output=True,
            text=True,
        )

    def load(self) -> dict:
        return json.loads(self.settings.read_text(encoding="utf-8"))

    def test_string_entry_becomes_filtered_object(self) -> None:
        self.write_settings([self.source()])
        result = self.run_filter()
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.load()["packages"][0]
        self.assertIsInstance(entry, dict)
        self.assertEqual(entry["source"], self.source())
        self.assertEqual(
            set(entry["skills"]),
            {
                "-plugins/flow/skills/review",
                "-plugins/spec/skills/engineering/wayfinder",
            },
        )
        self.assertIn("review", result.stdout)
        self.assertIn("wayfinder", result.stdout)

    def test_stale_filter_is_removed_and_user_filter_kept(self) -> None:
        self.write_settings(
            [
                {
                    "source": self.source(),
                    "skills": [
                        "-plugins/flow/skills/review",
                        "+plugins/flow/skills/execute",
                    ],
                }
            ]
        )
        (self.agents / "review" / "SKILL.md").unlink()
        result = self.run_filter()
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.load()["packages"][0]
        self.assertEqual(
            entry["skills"],
            [
                "+plugins/flow/skills/execute",
                "-plugins/spec/skills/engineering/wayfinder",
            ],
        )

    def test_no_collision_leaves_string_entry_unchanged(self) -> None:
        self.write_settings([self.source()])
        for name in ("review", "wayfinder", "other"):
            (self.agents / name / "SKILL.md").unlink()
        before = self.settings.read_text(encoding="utf-8")
        result = self.run_filter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.settings.read_text(encoding="utf-8"), before)
        self.assertIsInstance(self.load()["packages"][0], str)
        self.assertIn("no duplicate", result.stdout)

    def test_other_package_entries_are_untouched(self) -> None:
        other = {"source": "npm:something@1.0.0", "skills": ["-skills/x"]}
        self.write_settings([other, self.source()])
        result = self.run_filter()
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = self.load()["packages"]
        self.assertEqual(packages[0], other)
        self.assertIsInstance(packages[1], dict)


if __name__ == "__main__":
    unittest.main()
