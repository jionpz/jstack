"""managed-export 的纯标准库验收测试。"""

from __future__ import annotations

import json
import hashlib
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
MUST_STOP = "src/flow/skills/route/must-stop.md"
TOOL_POLICY = "src/flow/skills/route/tool-policy.json"
PROVIDERS = {
    "execute": "src/flow/skills/execute/SKILL.md",
    "verify": "plugins/pstack/skills/principle-prove-it-works/SKILL.md",
    "review": "src/flow/skills/review/SKILL.md",
    "land": "plugins/pstack/skills/poteto-mode/playbooks/opening-a-pr.md",
}


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

    def ticket_fixture(self, base: Path) -> Path:
        root = self.fixture(base)
        (root / STAGES).write_text(
            "## Stages\n\n"
            "| Stage | Output | Gate | Providers | Tool profile |\n"
            "|---|---|---|---|---|\n"
            "| execute | change | none | `flow:execute` | `developer` |\n"
            "| verify | evidence | evidence required | `pstack:principle-prove-it-works` | `verifier` |\n"
            "| review | findings | no open findings | `flow:review` | `reviewer` |\n"
            "| land | commit | no must-stop | `pstack:poteto-mode/playbooks/opening-a-pr.md` | `releaser` |\n",
            encoding="utf-8",
        )
        (root / MUST_STOP).write_text(
            "## Must stop\n\n"
            "| Action | Hook |\n"
            "|---|---|\n"
            "| Recursive forced delete | `rm-rf` |\n"
            "| Force push | `force-push` |\n",
            encoding="utf-8",
        )
        policy = {
            "protocol_version": "1.0",
            "profiles": {
                "developer": {
                    "role": "developer",
                    "capabilities": ["read", "edit", "write", "bash"],
                    "optional_capabilities": [],
                },
                "verifier": {
                    "role": "verifier",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
                "reviewer": {
                    "role": "reviewer",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
                "releaser": {
                    "role": "releaser",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
            },
            "harnesses": {"pi": {"read": {"native": ["read"]}}},
        }
        (root / TOOL_POLICY).write_text(json.dumps(policy), encoding="utf-8")
        for path in PROVIDERS.values():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"provider {path}\n", encoding="utf-8")
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

    def test_ticket_exports_fixed_stages_and_complete_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                    "--ticket-title",
                    "single ticket",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["mode"], "ticket")
            self.assertEqual(payload["route"]["stages"], ["execute", "verify", "review", "land"])
            self.assertEqual(payload["completion_target"], "branch_ready")
            self.assertEqual(
                [stage["stage"] for stage in payload["stages"]],
                ["execute", "verify", "review", "land"],
            )
            self.assertEqual(
                [stage["tool_profile"] for stage in payload["stages"]],
                ["developer", "verifier", "reviewer", "releaser"],
            )
            self.assertEqual(payload["ticket"], {"id": "JT-101", "title": "single ticket"})
            self.assertEqual(payload["must_stop"]["actions"][0]["action"], "Recursive forced delete")
            self.assertEqual(payload["tool_policy"]["stages"]["execute"], "developer")
            self.assertEqual(len(payload["sources"]), 8)

            body = {key: value for key, value in payload.items() if key != "content_digest"}
            canonical = json.dumps(
                body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            self.assertEqual(payload["content_digest"], hashlib.sha256(canonical).hexdigest())
            for source in payload["sources"]:
                content = (root / source["path"]).read_text(encoding="utf-8")
                self.assertEqual(
                    source["sha256"], hashlib.sha256(content.encode("utf-8")).hexdigest()
                )
                self.assertEqual(source["bytes"], len(content.encode("utf-8")))

    def test_ticket_exports_pr_ready_completion_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            command = [
                sys.executable,
                str(root / "scripts/managed-export.py"),
                "--root",
                str(root),
                "--ticket-id",
                "JT-101",
            ]
            default = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(default.returncode, 0, default.stderr)
            pr_ready = subprocess.run(
                command + ["--completion-target", "pr_ready"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(pr_ready.returncode, 0, pr_ready.stderr)
            default_payload = json.loads(default.stdout)
            pr_ready_payload = json.loads(pr_ready.stdout)
            self.assertEqual(default_payload["completion_target"], "branch_ready")
            self.assertEqual(pr_ready_payload["completion_target"], "pr_ready")
            self.assertNotEqual(
                default_payload["content_digest"], pr_ready_payload["content_digest"]
            )

    def test_completion_target_requires_ticket_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--completion-target",
                    "pr_ready",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("--completion-target", result.stderr)

    def test_ticket_rejects_missing_provider_missing_profile_and_bad_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            (root / PROVIDERS["verify"]).unlink()
            missing = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout, "")
            self.assertIn(PROVIDERS["verify"], missing.stderr)

            (root / PROVIDERS["verify"]).write_text("provider\n", encoding="utf-8")
            policy = json.loads((root / TOOL_POLICY).read_text(encoding="utf-8"))
            del policy["profiles"]["reviewer"]
            (root / TOOL_POLICY).write_text(json.dumps(policy), encoding="utf-8")
            no_profile = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(no_profile.returncode, 0)
            self.assertIn("reviewer", no_profile.stderr)

            bad_size = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                    "--size",
                    "M",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(bad_size.returncode, 0)
            self.assertEqual(bad_size.stdout, "")

    def test_ticket_digest_changes_when_stage_content_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            command = [
                sys.executable,
                str(root / "scripts/managed-export.py"),
                "--root",
                str(root),
                "--ticket-id",
                "JT-101",
            ]
            first = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            initial = json.loads(first.stdout)
            (root / PROVIDERS["execute"]).write_text("changed provider\n", encoding="utf-8")
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(second.returncode, 0, second.stderr)
            changed = json.loads(second.stdout)
            self.assertNotEqual(initial["content_digest"], changed["content_digest"])
            self.assertNotEqual(
                initial["stages"][0]["content_digest"], changed["stages"][0]["content_digest"]
            )


if __name__ == "__main__":
    unittest.main()
