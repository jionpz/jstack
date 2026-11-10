"""managed-export 的纯标准库验收测试。"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/managed-export.py"
ROUTE = "src/flow/skills/route/SKILL.md"
STAGES = "src/flow/skills/route/stages.md"
EXECUTE = "src/managed/investigate.md"


class ManagedExportTests(unittest.TestCase):
    def fixture(self, base: Path) -> Path:
        root = base / "fixture"
        (root / "scripts").mkdir(parents=True)
        (root / "src/flow/skills/route").mkdir(parents=True)
        (root / "src/managed").mkdir(parents=True)
        (root / "scripts/managed-export.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        (root / ROUTE).write_text("# route\n| Question | investigation | execute only |\n", encoding="utf-8")
        (root / STAGES).write_text("| Stage |\n| execute |\n", encoding="utf-8")
        (root / EXECUTE).write_text("只读调查。\n", encoding="utf-8")
        return root

    def run_export(
        self, root: Path, cwd: Path | None = None, *, use_default_root: bool = False
    ) -> subprocess.CompletedProcess[str]:
        script = root / "scripts/managed-export.py"
        command = [sys.executable, str(script)]
        if not use_default_root:
            command.extend(["--root", str(root)])
        return subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_exports_exact_protocol_and_source_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            result = self.run_export(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(
                set(payload),
                {"protocol_version", "workflow_id", "mode", "source_commit", "stages", "instructions"},
            )
            self.assertEqual(payload["protocol_version"], "1.0")
            self.assertEqual(payload["workflow_id"], "jstack")
            self.assertEqual(payload["mode"], "investigation")
            self.assertEqual(payload["stages"], ["execute"])
            self.assertEqual(payload["instructions"]["route"], "# route\n| Question | investigation | execute only |\n")
            self.assertEqual(payload["instructions"]["stages"], "| Stage |\n| execute |\n")
            self.assertEqual(payload["instructions"]["execute"], "只读调查。\n")
            self.assertEqual(payload["source_commit"], "unversioned")

    def test_missing_file_and_missing_execute_are_rejected_without_partial_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            (root / EXECUTE).unlink()
            missing = self.run_export(root)
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout, "")
            self.assertIn(EXECUTE, missing.stderr)

            (root / EXECUTE).write_text("只读调查。\n", encoding="utf-8")
            (root / STAGES).write_text("| Stage |\n| verify |\n", encoding="utf-8")
            no_execute = self.run_export(root)
            self.assertNotEqual(no_execute.returncode, 0)
            self.assertEqual(no_execute.stdout, "")
            self.assertIn("execute", no_execute.stderr)

    def test_output_is_independent_of_working_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            unrelated = base / "elsewhere"
            unrelated.mkdir()
            result = self.run_export(root, cwd=unrelated, use_default_root=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["workflow_id"], "jstack")

    def test_symlink_escaping_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            outside = base / "outside.md"
            outside.write_text("outside\n", encoding="utf-8")
            target = root / EXECUTE
            target.unlink()
            target.symlink_to(outside)
            result = self.run_export(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("越出仓库根目录", result.stderr)


if __name__ == "__main__":
    unittest.main()
