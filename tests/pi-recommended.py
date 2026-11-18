from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/pi-recommended.py"
SOURCE = "npm:@tintinweb/pi-subagents@0.23.2"

FAKE_PI = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FAKE_PI_STATE"])
state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {"user": None, "project": None, "installs": []}
state.setdefault("installs", [])


def settings_path(scope):
    if scope == "project":
        return Path.cwd() / ".pi/settings.json"
    return Path(os.environ["HOME"]) / ".pi/agent/settings.json"


def add_package(scope, source):
    path = settings_path(scope)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    packages = data.get("packages", [])
    if source not in packages:
        packages.append(source)
    data["packages"] = packages
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if sys.argv[1] == "list":
    for scope, label in (("user", "User packages:"), ("project", "Project packages:")):
        source = state.get(f"{scope}_source")
        version = state.get(scope)
        if not source and not version:
            continue
        print(label)
        print(f"  {source or f'npm:@tintinweb/pi-subagents@{version}'}")
        print("    /fake/pi/node_modules/package")
    sys.exit(0)

if sys.argv[1] == "install":
    source = next((arg for arg in sys.argv[2:] if arg.startswith("npm:")), None)
    local = any(arg in ("-l", "--local") for arg in sys.argv[2:])
    scope = "project" if local else "user"
    if os.environ.get("FAKE_PI_FAIL_INSTALL") == "1":
        print("fake install failure", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("npm_config_ignore_scripts") != "true":
        print("lifecycle scripts not disabled", file=sys.stderr)
        sys.exit(2)
    state[scope] = "0.23.2"
    state["installs"].append(
        {
            "source": source,
            "scope": scope,
            "cwd": os.getcwd(),
            "args": sys.argv[2:],
            "ignore_scripts": os.environ.get("npm_config_ignore_scripts"),
        }
    )
    state_path.write_text(json.dumps(state), encoding="utf-8")
    add_package(scope, source)
    sys.exit(0)

print("unsupported fake pi command", file=sys.stderr)
sys.exit(3)
'''


class PiRecommendedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.repo = self.base / "repo"
        self.bin = self.base / "bin"
        self.home.mkdir()
        self.repo.mkdir()
        self.bin.mkdir()
        fake = self.bin / "pi"
        fake.write_text(FAKE_PI, encoding="utf-8")
        fake.chmod(0o755)
        self.state = self.base / "state.json"
        self.env = dict(os.environ)
        self.env.pop("PI_AGENT_DIR", None)
        self.env["HOME"] = str(self.home)
        self.env["PATH"] = f"{self.bin}:{self.env.get('PATH', '')}"
        self.env["FAKE_PI_STATE"] = str(self.state)
        self.env.pop("FAKE_PI_FAIL_INSTALL", None)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def seed(self, user: str | None = None, project: str | None = None) -> None:
        self.state.write_text(json.dumps({"user": user, "project": project, "installs": []}), encoding="utf-8")

    def read_state(self) -> dict[str, object]:
        return json.loads(self.state.read_text(encoding="utf-8"))

    def run_script(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged = dict(self.env)
        if env:
            merged.update(env)
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
            env=merged,
        )

    def json_run(self, *args: str, env: dict[str, str] | None = None) -> dict[str, object]:
        result = self.run_script(*args, "--json", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_installs_pinned_source_with_lifecycle_scripts_disabled(self) -> None:
        self.seed()
        settings = self.home / ".pi/agent/settings.json"
        settings.parent.mkdir(parents=True)
        original = {"models": {"premium": "p/x"}, "providers": {"p": {"base": "local"}}, "packages": []}
        settings.write_text(json.dumps(original), encoding="utf-8")

        payload = self.json_run("--scope", "user")
        self.assertEqual(payload["status"], "installed")
        self.assertEqual(payload["source"], SOURCE)
        self.assertEqual(payload["version"], "0.23.2")
        self.assertTrue(str(payload["config"]).endswith(".pi/agent/settings.json"))

        state = self.read_state()
        self.assertEqual(len(state["installs"]), 1)
        install = state["installs"][0]
        self.assertEqual(install["source"], SOURCE)
        self.assertEqual(install["scope"], "user")
        self.assertEqual(install["ignore_scripts"], "true")
        self.assertNotIn("-l", install["args"])

        updated = json.loads(settings.read_text(encoding="utf-8"))
        self.assertEqual(updated["models"], original["models"])
        self.assertEqual(updated["providers"], original["providers"])
        self.assertEqual(updated["packages"], [SOURCE])

    def test_second_run_is_idempotent_and_reports_scope(self) -> None:
        self.seed()
        self.json_run("--scope", "user")
        second = self.run_script("--scope", "user")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("跳过", second.stdout)
        self.assertIn("user", second.stdout)
        self.assertEqual(len(self.read_state()["installs"]), 1)

    def test_project_scope_does_not_reuse_user_install(self) -> None:
        self.seed(user="0.23.2")
        user_settings = self.home / ".pi/agent/settings.json"
        user_settings.parent.mkdir(parents=True)
        user_settings.write_text(json.dumps({"packages": [SOURCE], "models": {"keep": True}}), encoding="utf-8")
        before = user_settings.read_bytes()

        payload = self.json_run("--scope", "project", "--repo", str(self.repo))
        self.assertEqual(payload["status"], "installed")
        self.assertEqual(payload["config"], ".pi/settings.json")
        state = self.read_state()
        self.assertEqual(len(state["installs"]), 1)
        self.assertEqual(state["installs"][0]["scope"], "project")
        self.assertEqual(Path(state["installs"][0]["cwd"]).resolve(), self.repo.resolve())
        self.assertIn("-l", state["installs"][0]["args"])
        self.assertEqual(user_settings.read_bytes(), before)
        project_settings = json.loads((self.repo / ".pi/settings.json").read_text(encoding="utf-8"))
        self.assertEqual(project_settings["packages"], [SOURCE])

    def test_existing_project_package_is_kept_and_version_reported(self) -> None:
        self.seed(project="0.24.0")
        payload = self.json_run("--scope", "project", "--repo", str(self.repo))
        self.assertEqual(payload["status"], "skipped")
        self.assertEqual(payload["version"], "0.24.0")
        self.assertEqual(payload["scope"], "project")
        self.assertFalse(payload["matches_pinned"])
        self.assertEqual(self.read_state()["installs"], [])
        human = self.run_script("--scope", "project", "--repo", str(self.repo))
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("0.24.0", human.stdout)
        self.assertIn("0.23.2", human.stdout)
        self.assertIn("未改动已有包", human.stdout)

    def test_pi_list_ignores_unrelated_packages_containing_name(self) -> None:
        self.state.write_text(
            json.dumps(
                {
                    "user": None,
                    "project": None,
                    "project_source": "npm:@someone/pi-subagents-helper@4.0.0",
                    "installs": [],
                }
            ),
            encoding="utf-8",
        )
        payload = self.json_run("--scope", "project", "--repo", str(self.repo))
        self.assertEqual(payload["status"], "installed")
        self.assertEqual(len(self.read_state()["installs"]), 1)

    def test_project_declaration_stages_without_pi_or_home_writes(self) -> None:
        settings = self.repo / ".pi/settings.json"
        settings.parent.mkdir(parents=True)
        original = {
            "models": {"keep": "p/m"},
            "packages": ["npm:other@1.0.0", {"source": "git+https://example.test/tool.git"}],
            "providers": {"keep": {"base": "local"}},
        }
        settings.write_text(json.dumps(original), encoding="utf-8")
        home_before = set(self.home.rglob("*"))

        payload = self.json_run(
            "--stage-project-declaration",
            "--scope",
            "project",
            "--repo",
            str(self.repo),
            "--pi",
            str(self.base / "missing-pi"),
        )

        self.assertEqual(
            payload,
            {"source": SOURCE, "version": "0.23.2", "declaration_created": True},
        )
        updated = json.loads(settings.read_text(encoding="utf-8"))
        self.assertEqual(updated["models"], original["models"])
        self.assertEqual(updated["providers"], original["providers"])
        self.assertEqual(updated["packages"], [*original["packages"], SOURCE])
        self.assertEqual(set(self.home.rglob("*")), home_before)
        self.assertFalse(self.state.exists())

        second = self.json_run(
            "--stage-project-declaration", "--scope", "project", "--repo", str(self.repo)
        )
        self.assertEqual(
            second,
            {"source": SOURCE, "version": "0.23.2", "declaration_created": False},
        )

    def test_project_declaration_preserves_structured_existing_source_and_version(self) -> None:
        settings = self.repo / ".pi/settings.json"
        settings.parent.mkdir(parents=True)
        original = {
            "packages": [
                "npm:pi-subagents-helper@1.0.0",
                {"source": "npm:@tintinweb/pi-subagents@0.24.1", "skills": ["keep"]},
            ],
        }
        settings.write_text(json.dumps(original), encoding="utf-8")
        before = settings.read_bytes()

        payload = self.json_run(
            "--stage-project-declaration", "--scope", "project", "--repo", str(self.repo)
        )

        self.assertEqual(
            payload,
            {
                "source": "npm:@tintinweb/pi-subagents@0.24.1",
                "version": "0.24.1",
                "declaration_created": False,
            },
        )
        self.assertEqual(settings.read_bytes(), before)

    def test_project_declaration_rejects_user_scope(self) -> None:
        result = self.run_script("--stage-project-declaration", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("仅支持", result.stderr)
        self.assertFalse((self.home / ".pi").exists())

    def test_project_declaration_dry_run_leaves_settings_absent(self) -> None:
        payload = self.json_run(
            "--stage-project-declaration", "--dry-run", "--scope", "project", "--repo", str(self.repo)
        )
        self.assertEqual(payload["source"], SOURCE)
        self.assertFalse(payload["declaration_created"])
        self.assertFalse((self.repo / ".pi").exists())

    def test_inspect_project_declaration_without_adding_it(self) -> None:
        settings = self.repo / ".pi/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text('{"packages":["npm:pi-subagents@0.88.1"]}\n', encoding="utf-8")
        before = settings.read_bytes()
        arguments = ("--project-declaration", "--scope", "project", "--repo", str(self.repo))
        self.assertIsNone(self.json_run(*arguments)["source"])
        self.assertEqual(settings.read_bytes(), before)

        settings.write_text('{"packages":[{"source":"npm:@tintinweb/pi-subagents@0.20.0"}]}\n', encoding="utf-8")
        observed = self.json_run(*arguments)
        self.assertEqual(observed["version"], "0.20.0")
        self.assertFalse(observed["declaration_created"])

    def test_project_declaration_rejects_symlinked_settings_directory(self) -> None:
        (self.repo / ".pi").symlink_to(self.home, target_is_directory=True)
        result = self.run_script(
            "--stage-project-declaration", "--scope", "project", "--repo", str(self.repo)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "settings.json").exists())

    def test_dry_run_does_not_install_or_write(self) -> None:
        self.seed()
        payload = self.json_run("--scope", "project", "--repo", str(self.repo), "--dry-run")
        self.assertEqual(payload["status"], "would-install")
        self.assertEqual(self.read_state()["installs"], [])
        self.assertFalse((self.repo / ".pi").exists())
        self.assertFalse((self.home / ".pi").exists())
        human = self.run_script("--scope", "project", "--repo", str(self.repo), "--dry-run")
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("--dry-run", human.stdout)

    def test_install_failure_is_reported(self) -> None:
        self.seed()
        result = self.run_script("--scope", "user", env={"FAKE_PI_FAIL_INSTALL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("安装", result.stderr)
        self.assertEqual(self.read_state()["installs"], [])

    def test_missing_pi_is_reported(self) -> None:
        self.seed()
        result = self.run_script("--scope", "user", "--pi", str(self.base / "no-such-pi"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("找不到 Pi CLI", result.stderr)

    def test_metadata_does_not_touch_pi_or_files(self) -> None:
        self.seed()
        result = self.run_script(
            "--metadata", "--scope", "project", "--repo", str(self.repo), "--pi", str(self.base / "no-such-pi")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["source"], SOURCE)
        self.assertEqual(payload["config"], ".pi/settings.json")
        self.assertEqual(payload["pinned_version"], "0.23.2")
        self.assertEqual(self.read_state()["installs"], [])
        self.assertFalse((self.repo / ".pi").exists())


if __name__ == "__main__":
    unittest.main()
