from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/tool-policy.py"
ROUTE = Path("src/flow/skills/route")
STAGES = ROUTE / "stages.md"
POLICY = ROUTE / "tool-policy.json"


class ToolPolicyTests(unittest.TestCase):
    def fixture(self, base: Path) -> Path:
        root = base / "repo"
        route = root / ROUTE
        route.mkdir(parents=True)
        (root / "scripts").mkdir()
        (root / "scripts/tool-policy.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        (root / STAGES).write_text((REPO / STAGES).read_text(encoding="utf-8"), encoding="utf-8")
        (root / POLICY).write_text((REPO / POLICY).read_text(encoding="utf-8"), encoding="utf-8")
        return root

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def inventory(self, base: Path, tools: object, name: str = "inventory.json") -> Path:
        path = base / name
        path.write_text(json.dumps(tools), encoding="utf-8")
        return path

    def export(self, root: Path) -> dict[str, object]:
        result = self.run_script("export", "--root", str(root))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def resolve(self, root: Path, inventory: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return self.run_script("resolve", "--root", str(root), "--inventory", str(inventory), *args)

    def test_export_protocol_digest_and_stage_profiles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            payload = self.export(root)
            self.assertEqual(
                set(payload),
                {"protocol_version", "source_commit", "stages", "profiles", "harnesses", "content_digest"},
            )
            self.assertEqual(payload["protocol_version"], "1.0")
            self.assertEqual(payload["source_commit"], "unversioned")
            self.assertEqual(
                payload["stages"],
                {
                    "size": "router",
                    "clarify": "analyst",
                    "plan": "planner",
                    "execute": "developer",
                    "verify": "verifier",
                    "review": "reviewer",
                    "land": "releaser",
                    "archive": "archivist",
                },
            )
            profiles = payload["profiles"]
            self.assertIn("investigator", profiles)
            self.assertIn("tianwen", profiles)
            self.assertEqual(profiles["tianwen"]["capabilities"], ["read", "grep", "find", "ls"])
            body = {key: value for key, value in payload.items() if key != "content_digest"}
            canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            self.assertEqual(payload["content_digest"], hashlib.sha256(canonical).hexdigest())

    def test_repeated_export_is_byte_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            first = self.run_script("export", "--root", str(root))
            second = self.run_script("export", "--root", str(root))
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual(json.loads(first.stdout)["content_digest"], json.loads(second.stdout)["content_digest"])

    def test_stage_profile_change_is_reflected_and_changes_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            before = self.export(root)
            path = root / STAGES
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "| None | `flow:route` | `router` |", "| None | `flow:route` | `analyst` |"
                ),
                encoding="utf-8",
            )
            after = self.export(root)
            self.assertEqual(after["stages"]["size"], "analyst")
            self.assertNotEqual(before["content_digest"], after["content_digest"])

    def test_unknown_stage_profile_is_rejected_without_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            path = root / STAGES
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "| None | `flow:route` | `router` |", "| None | `flow:route` | `ghost` |"
                ),
                encoding="utf-8",
            )
            result = self.run_script("export", "--root", str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("ghost", result.stderr)

    def test_duplicate_json_field_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            path = root / POLICY
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    '"role": "router",', '"role": "router", "role": "router",', 1
                ),
                encoding="utf-8",
            )
            result = self.run_script("export", "--root", str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("重复字段", result.stderr)

    def test_unknown_capability_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            path = root / POLICY
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    '"capabilities": ["read", "grep", "find", "ls"],',
                    '"capabilities": ["read", "grep", "find", "ls", "teleport"],',
                    1,
                ),
                encoding="utf-8",
            )
            result = self.run_script("export", "--root", str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("teleport", result.stderr)

    def test_symlink_escaping_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            outside = base / "outside-policy.json"
            outside.write_text((root / POLICY).read_text(encoding="utf-8"), encoding="utf-8")
            target = root / POLICY
            target.unlink()
            target.symlink_to(outside)
            result = self.run_script("export", "--root", str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("越出仓库根目录", result.stderr)

    def test_claude_native_names_are_selected_from_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(
                base, ["Read", "Write", "Edit", "Bash", "Task", "Grep", "Glob", "LS", "WebSearch", "WebFetch"]
            )
            result = self.resolve(root, inventory, "--stage", "execute", "--harness", "claude-code")
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(
                payload["native_tools"], ["Read", "Grep", "Glob", "LS", "Edit", "Write", "Bash", "Task"]
            )
            self.assertEqual(payload["permissions"]["allowed_tools"], payload["native_tools"])
            self.assertEqual(payload["degradations"], [])
            self.assertEqual(payload["role"], "developer")
            self.assertEqual(payload["stage"], "execute")

    def test_shell_fallback_requires_explicit_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(base, ["Read", "Write", "Edit", "Bash", "Task", "WebSearch", "WebFetch"])
            refused = self.resolve(root, inventory, "--stage", "execute", "--harness", "claude-code")
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(refused.stdout, "")
            self.assertIn("--allow-shell-fallback", refused.stderr)
            self.assertIn("grep", refused.stderr)

            allowed = self.resolve(
                root, inventory, "--stage", "execute", "--harness", "claude-code", "--allow-shell-fallback"
            )
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            payload = json.loads(allowed.stdout)
            self.assertIn("Bash", payload["native_tools"])
            self.assertEqual(payload["native_tools"].count("Bash"), 1)
            self.assertEqual(
                [entry["capability"] for entry in payload["degradations"]], ["grep", "find", "ls"]
            )
            self.assertTrue(all(entry["tool"] == "Bash" for entry in payload["degradations"]))

    def test_read_only_profile_never_gets_bash_silently(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(base, ["Read", "Bash"])
            refused = self.resolve(root, inventory, "--stage", "size", "--harness", "claude-code")
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(refused.stdout, "")
            self.assertNotIn('"Bash"', refused.stdout)
            allowed = self.resolve(
                root, inventory, "--stage", "size", "--harness", "claude-code", "--allow-shell-fallback"
            )
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            payload = json.loads(allowed.stdout)
            self.assertIn("Bash", payload["native_tools"])
            self.assertEqual(len(payload["degradations"]), 3)

    def test_pi_extension_tools_and_object_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(
                base,
                {
                    "tools": [
                        {"name": "read"},
                        {"name": "bash"},
                        {"name": "edit"},
                        {"name": "write"},
                        {"name": "grep"},
                        {"name": "find"},
                        {"name": "ls"},
                        {"name": "Agent"},
                        {"name": "web_search"},
                        {"name": "fetch_content"},
                    ]
                },
            )
            execute = self.resolve(root, inventory, "--stage", "execute", "--harness", "pi")
            self.assertEqual(execute.returncode, 0, execute.stderr)
            payload = json.loads(execute.stdout)
            self.assertIn("Agent", payload["native_tools"])
            self.assertNotIn("web_search", payload["native_tools"])
            self.assertEqual(payload["degradations"], [])
            size = self.resolve(root, inventory, "--stage", "size", "--harness", "pi")
            self.assertEqual(json.loads(size.stdout)["native_tools"], ["read", "grep", "find", "ls"])
            tianwen = self.resolve(root, inventory, "--role", "tianwen", "--harness", "pi")
            self.assertEqual(tianwen.returncode, 0, tianwen.stderr)
            self.assertEqual(
                json.loads(tianwen.stdout)["native_tools"],
                ["read", "grep", "find", "ls", "web_search", "fetch_content"],
            )

    def test_missing_required_tool_is_rejected_even_with_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(base, ["read", "bash", "write", "grep", "find", "ls", "Agent"])
            result = self.resolve(
                root, inventory, "--stage", "execute", "--harness", "pi", "--allow-shell-fallback"
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("edit", result.stderr)

    def test_missing_optional_tools_are_reported_not_faked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(base, ["Read", "Write", "Edit", "Bash", "Task", "Grep", "Glob", "LS"])
            result = self.resolve(root, inventory, "--stage", "clarify", "--harness", "claude-code")
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["missing_optional"], ["web_search", "web_fetch"])
            self.assertNotIn("WebSearch", payload["native_tools"])
            self.assertNotIn("WebFetch", payload["native_tools"])

            inventory = self.inventory(
                base,
                ["Read", "Write", "Edit", "Bash", "Task", "Grep", "Glob", "LS", "WebSearch"],
                "with-web.json",
            )
            result = self.resolve(root, inventory, "--stage", "clarify", "--harness", "claude-code")
            payload = json.loads(result.stdout)
            self.assertEqual(payload["missing_optional"], ["web_fetch"])
            self.assertIn("WebSearch", payload["native_tools"])

    def test_unknown_harness_profile_stage_and_bad_inventory_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            inventory = self.inventory(base, ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "LS", "Task"])
            unknown_harness = self.resolve(root, inventory, "--stage", "execute", "--harness", "cursor")
            self.assertNotEqual(unknown_harness.returncode, 0)
            self.assertIn("cursor", unknown_harness.stderr)
            unknown_role = self.resolve(root, inventory, "--role", "ghost", "--harness", "claude-code")
            self.assertNotEqual(unknown_role.returncode, 0)
            self.assertIn("ghost", unknown_role.stderr)
            unknown_stage = self.resolve(root, inventory, "--stage", "ghost", "--harness", "claude-code")
            self.assertNotEqual(unknown_stage.returncode, 0)
            self.assertIn("ghost", unknown_stage.stderr)
            both = self.resolve(
                root, inventory, "--stage", "execute", "--role", "developer", "--harness", "claude-code"
            )
            self.assertNotEqual(both.returncode, 0)
            neither = self.resolve(root, inventory, "--harness", "claude-code")
            self.assertNotEqual(neither.returncode, 0)
            malformed = base / "malformed.json"
            malformed.write_text('{"tools": "read"}', encoding="utf-8")
            bad = self.resolve(root, malformed, "--stage", "execute", "--harness", "claude-code")
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("tools", bad.stderr)


if __name__ == "__main__":
    unittest.main()
