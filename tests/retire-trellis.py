#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "retire-trellis.py"
ARCHIVE = Path(".jstack-retired-trellis")
PROJECT = ARCHIVE / "project"


class RetireTrellis(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.workspace = Path(workspace.name)
        self.repo = self.workspace / "project with spaces"
        self.home = self.workspace / "home"
        self.home.mkdir()
        self.repo.mkdir()
        self.git("init", "-q")

    def git(self, *args, expected=0):
        result = subprocess.run(
            ["git", "-C", str(self.repo), *args], text=True, capture_output=True,
            env={**os.environ, "HOME": str(self.home), "GIT_CONFIG_NOSYSTEM": "1"},
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return result.stdout

    def write(self, path, value):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes):
            target.write_bytes(value)
        elif isinstance(value, str):
            target.write_text(value, encoding="utf-8")
        else:
            target.write_text(json.dumps(value, indent=4) + "\n", encoding="utf-8")
        return target

    def snapshot(self):
        paths = {}
        for path in self.repo.rglob("*"):
            local = path.relative_to(self.repo)
            if local.parts[0] == ".git":
                continue
            if path.is_symlink():
                paths[local] = ("symlink", os.readlink(path))
            elif path.is_dir():
                paths[local] = ("directory",)
            else:
                paths[local] = (stat.S_IMODE(path.stat().st_mode), path.read_bytes())
        return paths

    def cli(self, *args, expected=0, as_json=True, repo=None):
        command = [sys.executable, "-I", str(SCRIPT), "--repo", str(repo or self.repo), *map(str, args)]
        if as_json:
            command.append("--json")
        result = subprocess.run(
            command, text=True, capture_output=True, cwd=self.workspace, timeout=10,
            env={**os.environ, "HOME": str(self.home)},
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout) if as_json else result.stdout

    def write_hook(self, path=".claude/hooks/session-start.py"):
        return self.write(path, '"""Session Start Hook - Inject structured context"""\nROOT = ".trellis"\n')

    def test_real_shapes_preserve_unrelated_handlers_and_entire_payload(self):
        self.write_hook().chmod(0o755)
        self.write(".codex/hooks/inject-workflow-state.py", '"""Trellis per-turn breadcrumb hook."""\nROOT = ".trellis"\n')
        self.write(".opencode/plugins/session-start.js", 'import { TrellisContext } from "../lib/trellis-context.js"\n')
        self.write(".opencode/lib/trellis-context.js", "// might have been locally edited\n")
        self.write(".opencode/lib/session-utils.js", 'import { debugLog } from "./trellis-context.js"\n')
        self.write(".opencode/plugins/my-plugin.js", "export default async () => ({})\n")
        self.write(".opencode/package.json", {"dependencies": {"@opencode-ai/plugin": "1.17.14"}})
        self.write(".agents/skills/trellis-before-dev/SKILL.md", "---\nname: trellis-before-dev\n---\n")
        self.write(".agents/skills/trellis-before-dev/custom.txt", b"\xffcustom\n")
        self.write(".agents/skills/other/SKILL.md", "---\nname: other\n---\n")
        self.write(".codex/agents/trellis-check.toml", 'name = "trellis-check"\n')
        self.write(".pi/extensions/trellis/index.ts", "export default function activate() {}\n")
        self.write(".pi/extensions/jstack-flow-gates.ts", "export default function activate() {}\n")
        self.write(".pi/settings.json", {
            "extensions": ["./extensions/trellis/index.ts", "./extensions/jstack-flow-gates.ts"],
            "packages": ["npm:@mindfoldhq/trellis@0.6.0", "npm:another-package"],
            "theme": "custom",
        })
        codex_config = self.write(".codex/config.toml", (
            '[agents]\nmax_depth = 2\n\n[agents.trellis-check]\nconfig_file = "agents/trellis-check.toml"\n'
            'description = "Checks the task"\n\n# Keep this note for the next section\n'
            '[agents.jstack-flow]\nconfig_file = "agents/flow.toml"\n'
        ))
        keep_handler = {"type": "command", "command": "./guard.sh", "timeout": 10}
        settings = self.write(".claude/settings.json", {
            "permissions": {"allow": ["Read"]},
            "hooks": {
                "SessionStart": [{"matcher": "startup", "hooks": [
                    {"type": "command", "command": "python3 .claude/hooks/session-start.py", "timeout": 30},
                    keep_handler,
                ]}],
                "Stop": [{"hooks": [keep_handler]}],
            },
        })
        settings.chmod(0o640)
        self.write(".codex/hooks.json", {
            "hooks": {
                "UserPromptSubmit": [{"hooks": [{
                    "type": "command", "command": 'python3 -X utf8 ".codex/hooks/inject-workflow-state.py"',
                }]}],
                "Stop": [{"hooks": [keep_handler]}],
            },
        })
        self.write("package.json", {
            "devDependencies": {"@mindfoldhq/trellis": "^0.6.0", "vitest": "1"},
            "scripts": {"check": "vitest"},
        })
        instructions = b"Project instructions\r\n<!-- TRELLIS:START -->\r\nLocal changes\r\n<!-- TRELLIS:END -->\r\nKeep me\r\n"
        self.write("AGENTS.md", instructions)
        self.write(".trellis/spec/backend/index.md", "Backend conventions\n")
        self.write(".trellis/tasks/archive/2026-11/11-01-old/task.json", {"id": "old", "status": "completed"})
        self.write(".trellis/workspace/alice/journal.md", "Private notes\n")
        self.write(".trellis/unknown.bin", b"\x00\xfe")
        self.write("docs/agents/conventions/existing.md", "Existing conventions\n")
        outside = self.workspace / "outside"
        outside.write_text("outside", encoding="utf-8")
        (self.repo / ".trellis/linked").symlink_to(outside)
        (self.home / ".trellis").mkdir()
        (self.home / ".trellis/untouched").write_text("global", encoding="utf-8")
        before = self.snapshot()
        preview = self.cli()
        self.assertEqual(preview["status"], "dry-run", preview["blockers"])
        self.assertEqual(preview["conventions"]["destination"], "docs/agents/conventions")
        self.assertEqual(preview["conventions"]["source"], ".trellis/spec")
        self.assertIn("git add -f", preview["archive_policy"])
        self.assertEqual(self.snapshot(), before)

        applied = self.cli("--apply")
        self.assertEqual(applied["status"], "applied")
        after = self.snapshot()
        for path, value in before.items():
            if path.parts[0] == ".trellis":
                self.assertEqual(after[PROJECT / path], value)
        self.assertEqual(outside.read_text(), "outside")
        self.assertEqual((self.home / ".trellis/untouched").read_text(), "global")
        self.assertEqual((self.repo / PROJECT / ".claude/hooks/session-start.py").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.repo / PROJECT / ".agents/skills/trellis-before-dev/custom.txt").read_bytes(), b"\xffcustom\n")
        self.assertEqual((self.repo / ARCHIVE / "originals/AGENTS.md").read_bytes(), instructions)
        self.assertEqual((self.repo / "AGENTS.md").read_bytes(), b"Project instructions\r\nKeep me\r\n")
        self.assertEqual((self.repo / "docs/agents/conventions/existing.md").read_text(), "Existing conventions\n")
        self.assertEqual((self.repo / ARCHIVE / "originals/.claude/settings.json").read_bytes(), before[Path(".claude/settings.json")][1])
        self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o640)
        self.assertEqual(json.loads(settings.read_text()), {
            "permissions": {"allow": ["Read"]},
            "hooks": {
                "SessionStart": [{"matcher": "startup", "hooks": [keep_handler]}],
                "Stop": [{"hooks": [keep_handler]}],
            },
        })
        self.assertEqual(json.loads((self.repo / ".codex/hooks.json").read_text()), {
            "hooks": {"Stop": [{"hooks": [keep_handler]}]},
        })
        self.assertEqual(codex_config.read_text(), (
            '[agents]\nmax_depth = 2\n\n\n# Keep this note for the next section\n'
            '[agents.jstack-flow]\nconfig_file = "agents/flow.toml"\n'
        ))
        self.assertEqual(json.loads((self.repo / ".pi/settings.json").read_text()), {
            "extensions": ["./extensions/jstack-flow-gates.ts"],
            "packages": ["npm:another-package"],
            "theme": "custom",
        })
        self.assertEqual(json.loads((self.repo / "package.json").read_text()), {
            "devDependencies": {"vitest": "1"}, "scripts": {"check": "vitest"},
        })
        for untouched in (
            ".agents/skills/other/SKILL.md", ".opencode/plugins/my-plugin.js", ".opencode/package.json",
            ".pi/extensions/jstack-flow-gates.ts",
        ):
            self.assertEqual(after[Path(untouched)], before[Path(untouched)])
        for moved in (
            ".trellis", ".claude/hooks/session-start.py", ".codex/agents/trellis-check.toml",
            ".codex/hooks/inject-workflow-state.py", ".opencode/plugins/session-start.js",
            ".opencode/lib/session-utils.js", ".pi/extensions/trellis",
        ):
            self.assertFalse((self.repo / moved).exists(), moved)
        selected = PROJECT / ".trellis/spec/backend/index.md"
        self.git("check-ignore", "--quiet", str(selected))
        self.git("add", "-f", "--", str(selected))
        self.assertEqual(self.git("diff", "--cached", "--name-only").strip(), str(selected))
        self.assertEqual(self.cli("--apply")["status"], "no-op")
        self.assertEqual(self.snapshot(), after)

    def test_known_open_tasks_require_an_explicit_mapping(self):
        self.write(".trellis/tasks/11-01-open/task.json", {"id": "open", "status": "in_progress"})
        self.write(".trellis/tasks/11-02-done/task.json", {"id": "done", "status": "completed"})
        self.write(".trellis/tasks/archive/2026-10/old/task.json", {"name": "old task format"})
        before = self.snapshot()
        report = self.cli()
        self.assertEqual(report["status"], "blocked")
        self.assertIn("requires --task-map", "\n".join(report["blockers"]))
        self.assertEqual([(task["id"], task["status"], task["historical"]) for task in report["tasks"]], [
            ("open", "in_progress", False), ("done", "completed", False), (None, None, True),
        ])
        self.assertEqual(self.cli("--apply", expected=1)["status"], "blocked")
        self.assertEqual(self.snapshot(), before)
        mapping = self.workspace / "migration.json"
        mapping.write_text('{"open": "acme/work#123"}', encoding="utf-8")
        self.assertEqual(self.cli("--task-map", mapping, "--apply")["status"], "applied")
        self.assertEqual(json.loads((self.repo / ARCHIVE / "task-map.json").read_text()), {"open": "acme/work#123"})
        self.assertEqual(self.cli("--apply")["status"], "no-op")

    def test_unknown_active_task_is_reported_and_mapping_does_not_infer_status(self):
        self.write(".trellis/tasks/11-01-unknown/task.json", {"id": "unknown", "status": "done_or_waiting"})
        self.write(".trellis/tasks/11-02-malformed/task.json", "{broken")
        mapping = self.write("mapping.json", {"unknown": "tracker#2"})
        before = self.snapshot()
        report = self.cli("--apply", "--task-map", mapping, expected=1)
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(len(report["blockers"]), 2)
        self.assertEqual(report["tasks"][0]["status"], "done_or_waiting")
        self.assertNotIn("tracker", report["tasks"][0])
        self.assertEqual(self.snapshot(), before)

    def test_review_references_block_atomically(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write_hook()
        self.write(".claude/settings.json", {"hooks": {"SessionStart": [{"hooks": [{
            "type": "command", "command": "python3 .claude/hooks/session-start.py && ./other-hook.sh",
        }]}]}})
        self.write(".github/workflows/ci.yml", "run: python3 .trellis/scripts/task.py current\n")
        self.write(".codex/config.toml", '[agents.trellis-check]\nconfig_file = "custom.toml"\n')
        self.write(".agents/skills/trellis-custom/SKILL.md", "User-authored skill\n")
        self.write("package.json", {"scripts": {"task": "trellis task list"}})
        before = self.snapshot()
        report = self.cli("--apply", expected=1)
        self.assertEqual(report["status"], "blocked")
        for path in (
            ".claude/settings.json", ".github/workflows/ci.yml", ".codex/config.toml",
            ".agents/skills/trellis-custom", "package.json",
        ):
            self.assertIn(path, "\n".join(report["blockers"]))
        self.assertEqual(self.snapshot(), before)

    def test_codex_removes_generated_tables_and_preserves_neighboring_toml(self):
        prefix = b'model = "example"\r\nitems = [\r\n  "[value]",\r\n]\r\n'
        suffix = b'\r\n# Keep the next table\r\n[[other.entries]]\r\nname = "keep"\r\n'
        config = self.write(".codex/config.toml", prefix + (
            b'[agents.trellis-check]\r\nconfig_file = "./agents/trellis-check.toml"\r\n'
            b'[agents.trellis-research]\r\ndescription = "Research # details"\r\n'
            b'config_file = "agents/trellis-research.toml"\r\n'
        ) + suffix)
        self.assertEqual(self.cli("--apply")["status"], "applied")
        self.assertEqual(config.read_bytes(), prefix + suffix)

    def test_codex_leaves_ambiguous_tables_for_review(self):
        generated = '[agents.trellis-check]\nconfig_file = "agents/trellis-check.toml"\n'
        for content in (
            f'prompt = """\n{generated}"""\n',
            f"prompt = '''\n{generated}'''\n",
            generated + 'extra = true\n',
            generated + 'description = "First"\ndescription = "Second"\n',
            generated + generated,
            f'items = [\n{generated}',
        ):
            with self.subTest(content=content):
                self.write(".codex/config.toml", content)
                before = self.snapshot()
                report = self.cli("--apply", expected=1)
                self.assertIn("review remaining Trellis reference", "\n".join(report["blockers"]))
                self.assertEqual(report["edits"], [])
                self.assertEqual(self.snapshot(), before)

    def test_archive_conflict_prevents_all_edits(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write("AGENTS.md", "<!-- TRELLIS:START -->\nold\n<!-- TRELLIS:END -->\n")
        self.write(ARCHIVE / ".gitignore", "*\n")
        self.write(PROJECT / ".trellis/spec/other.md", "Previous archive\n")
        before = self.snapshot()
        report = self.cli("--apply", expected=1)
        self.assertEqual(report["status"], "blocked")
        self.assertIn("archive destination conflicts", "\n".join(report["blockers"]))
        self.assertEqual(self.snapshot(), before)

    def test_concurrent_applies_converge(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write("AGENTS.md", "Keep\n<!-- TRELLIS:START -->\nold\n<!-- TRELLIS:END -->\n")
        command = [sys.executable, "-I", str(SCRIPT), "--repo", str(self.repo), "--apply", "--json"]
        with subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as first:
            second = subprocess.run(command, text=True, capture_output=True, timeout=10)
            stdout, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, stderr)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual({json.loads(stdout)["status"], json.loads(second.stdout)["status"]}, {"applied", "no-op"})
        self.assertEqual((self.repo / "AGENTS.md").read_text(), "Keep\n")
        self.assertEqual((self.repo / PROJECT / ".trellis/spec/notes.md").read_text(), "Notes\n")

    def test_missing_generic_hook_is_reported_for_review(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write(".claude/settings.json", {"hooks": {"SessionStart": [{"hooks": [{
            "type": "command", "command": "python3 .claude/hooks/session-start.py",
        }]}]}})
        before = self.snapshot()
        report = self.cli("--apply", expected=1)
        self.assertIn(".claude/settings.json", "\n".join(report["blockers"]))
        self.assertEqual(self.snapshot(), before)

    def test_retry_after_archive_backup_and_partial_move(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write("AGENTS.md", "Keep\n<!-- TRELLIS:START -->\nold\n<!-- TRELLIS:END -->\n")
        self.write(ARCHIVE / ".gitignore", "*\n")
        original = self.repo / "AGENTS.md"
        self.write(ARCHIVE / "originals/AGENTS.md", original.read_bytes())
        self.write(PROJECT / ".claude/agents/trellis-check.md", "Already moved\n")
        self.assertEqual(self.cli("--apply")["status"], "applied")
        self.assertEqual(original.read_text(), "Keep\n")
        self.assertEqual((self.repo / PROJECT / ".claude/agents/trellis-check.md").read_text(), "Already moved\n")
        self.assertEqual(self.cli("--apply")["status"], "no-op")

    def test_symlinked_paths_cannot_write_outside_repository(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        outside = self.workspace / "outside"
        outside.mkdir()
        outside_file = outside / "settings.json"
        outside_file.write_text('{"untouched": true}\n')
        (self.repo / ".claude").symlink_to(outside, target_is_directory=True)
        before = self.snapshot()
        self.assertEqual(self.cli("--apply", expected=1)["status"], "blocked")
        self.assertEqual(self.snapshot(), before)
        (self.repo / ".claude").unlink()
        (self.repo / ARCHIVE).symlink_to(outside, target_is_directory=True)
        before = self.snapshot()
        self.assertEqual(self.cli("--apply", expected=1)["status"], "blocked")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(list(outside.iterdir()), [outside_file])
        self.assertEqual(outside_file.read_text(), '{"untouched": true}\n')

    def test_hardlinked_config_is_replaced_without_modifying_outside_inode(self):
        outside = self.workspace / "instructions"
        original = "Keep\n<!-- TRELLIS:START -->\nold\n<!-- TRELLIS:END -->\n"
        outside.write_text(original)
        os.link(outside, self.repo / "AGENTS.md")
        self.assertEqual(self.cli("--apply")["status"], "applied")
        self.assertEqual(outside.read_text(), original)
        self.assertEqual((self.repo / "AGENTS.md").read_text(), "Keep\n")

    def test_duplicate_keys_and_marker_mismatch_block_before_writes(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.write("AGENTS.md", "<!-- TRELLIS:END -->\n")
        self.write("package.json", '{"dependencies": {"@mindfoldhq/trellis": "1", "@mindfoldhq/trellis": "2"}}')
        before = self.snapshot()
        report = self.cli("--apply", expected=1)
        self.assertEqual(report["status"], "blocked")
        self.assertIn("invalid Trellis instruction markers", "\n".join(report["blockers"]))
        self.assertIn("duplicate JSON key", "\n".join(report["blockers"]))
        self.assertEqual(self.snapshot(), before)

    def test_subdirectory_rejected_and_human_report_explains_conventions(self):
        self.write(".trellis/spec/notes.md", "Notes\n")
        self.assertEqual(self.cli("--apply", repo=self.repo / ".trellis", expected=1)["status"], "error")
        preview = self.cli(as_json=False)
        self.assertIn("Review and copy selected regular files from .trellis/spec into docs/agents/conventions", preview)
        self.assertIn(".jstack-retired-trellis/project/.trellis/spec", preview)
        self.assertIn("git add -f", preview)


if __name__ == "__main__":
    unittest.main()
