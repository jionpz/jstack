#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
exec python3 -I - "$repo_root" <<'PY'
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


repo_root = Path(sys.argv[1]).resolve()
failures: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"ok - {label}")
    else:
        failures.append(label)
        print(f"not ok - {label}" + (f": {detail}" if detail else ""))


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )


with tempfile.TemporaryDirectory(prefix="jstack project clone ") as temporary:
    temp = Path(temporary)
    home = temp / "empty home"
    source = temp / "source checkout"
    aside = temp / "original checkout moved aside"
    clone = temp / "clean clone with spaces"
    fake_bin = temp / "fake harness commands"
    home.mkdir()
    source.mkdir()
    fake_bin.mkdir()

    fake_harness = fake_bin / "harness"
    fake_harness.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$0" >>"$HARNESS_CALLS"\nexit 97\n',
        encoding="utf-8",
    )
    fake_harness.chmod(0o755)
    for name in ("claude", "pi", "omp", "cursor", "codex"):
        (fake_bin / name).symlink_to(fake_harness)

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
            "HARNESS_CALLS": str(temp / "harness-calls.txt"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "jstack regression",
            "GIT_AUTHOR_EMAIL": "jstack-regression@example.invalid",
            "GIT_COMMITTER_NAME": "jstack regression",
            "GIT_COMMITTER_EMAIL": "jstack-regression@example.invalid",
        }
    )

    init = run(["git", "init", "-q", str(source)], env=env)
    check("initialize isolated source repository", init.returncode == 0, init.stderr)
    install = run(
        [
            str(repo_root / "jstack"),
            "install",
            "--all",
            "--scope",
            "project",
            "--repo",
            str(source),
        ],
        cwd=repo_root,
        env=env,
    )
    check("generate all project harness projections", install.returncode == 0, install.stderr)
    check("installer never invokes a harness", not (temp / "harness-calls.txt").exists())

    if install.returncode == 0:
        staged = run(["git", "add", "-A"], cwd=source, env=env)
        committed = run(["git", "commit", "-qm", "install jstack project projection"], cwd=source, env=env)
        check("stage and commit throwaway fixture", staged.returncode == 0 and committed.returncode == 0,
              staged.stderr + committed.stderr)

        cloned = run(["git", "clone", "-q", str(source), str(clone)], env=env)
        check("clone committed fixture into path with spaces", cloned.returncode == 0, cloned.stderr)

        if cloned.returncode == 0:
            clone = clone.resolve()
            shutil.move(source, aside)
            expected_skills = {
                "route",
                "archive",
                "poteto-mode",
                "grill-with-docs",
                "to-spec",
                "to-tickets",
                "wayfinder",
                "handoff",
                "setup-matt-pocock-skills",
            }
            skills_dir = clone / ".agents/skills"
            actual_skills = {path.name for path in skills_dir.iterdir()} if skills_dir.is_dir() else set()
            check("clone retains exactly nine entry skills", actual_skills == expected_skills,
                  f"found {sorted(actual_skills)}")
            check(
                "entry skill links resolve inside clone",
                all((skills_dir / skill / "SKILL.md").is_file()
                    and (skills_dir / skill).resolve().is_relative_to(clone)
                    for skill in expected_skills),
            )

            locate = run(["bash", str(skills_dir / "route/locate.sh")], cwd=clone, env=env)
            located_paths = [
                Path(line.split("\t", 1)[1]).resolve()
                for line in locate.stdout.splitlines()
                if "\t" in line
            ]
            check("route locate succeeds from moved clone", locate.returncode == 0, locate.stderr)
            check(
                "all located providers resolve inside clone",
                bool(located_paths) and all(path.is_relative_to(clone) for path in located_paths),
                f"found paths outside clone: {[str(path) for path in located_paths if not path.is_relative_to(clone)]}",
            )

            for harness in ("pi", "omp"):
                extension = clone / f".{harness}/extensions/jstack-flow-gates.ts"
                import_line = next(
                    (line for line in extension.read_text(encoding="utf-8").splitlines()
                     if line.startswith("export { default } from ")),
                    "",
                ) if extension.is_file() else ""
                target = import_line.split('"', 2)[1] if '"' in import_line else ""
                resolved = (extension.parent / target).resolve() if target else None
                check(
                    f"{harness} extension resolves to clone vendor",
                    resolved is not None
                    and resolved.is_relative_to(clone / ".jstack/vendor")
                    and resolved.is_file(),
                    str(resolved),
                )

            for agent_dir in (".agents/agents", ".omp/agents", ".cursor/agents"):
                for name in ("poteto-agent", "comment-sicko"):
                    agent = clone / agent_dir / f"{name}.md"
                    contents = agent.read_text(encoding="utf-8") if agent.is_file() else ""
                    check(
                        f"{agent_dir} {name} agent is installed from project vendor",
                        f"generated by jstack install --scope project; source: pstack/agents/{name}.md"
                        in contents
                        and str(aside) not in contents,
                        str(agent),
                    )

            for name in ("poteto-agent", "comment-sicko"):
                agent = clone / ".codex/agents" / f"{name}.toml"
                contents = agent.read_text(encoding="utf-8") if agent.is_file() else ""
                check(
                    f"Codex {name} agent names clone vendor as its source",
                    f"source: .jstack/vendor/plugins/pstack/agents/{name}.md" in contents,
                    str(agent),
                )

            hooks_file = clone / ".codex/hooks.json"
            hooks = json.loads(hooks_file.read_text(encoding="utf-8")) if hooks_file.is_file() else {}
            command_for = {
                "prompt": hooks.get("hooks", {}).get("UserPromptSubmit", [{}])[0]
                .get("hooks", [{}])[0].get("command", ""),
                "guard": hooks.get("hooks", {}).get("PreToolUse", [{}])[0]
                .get("hooks", [{}])[0].get("command", ""),
                "stop": hooks.get("hooks", {}).get("Stop", [{}])[0]
                .get("hooks", [{}])[0].get("command", ""),
            }
            state_dir = temp / "hook state"
            state_dir.mkdir()
            (state_dir / "clone-session").write_text(
                "path execute,verify\nstage execute\n",
                encoding="utf-8",
            )
            hook_env = env.copy()
            hook_env["JSTACK_STATE_DIR"] = str(state_dir)
            requests = {
                "prompt": (
                    '{"session_id":"clone-session","turn_id":"prompt-turn",'
                    '"hook_event_name":"UserPromptSubmit"}\n',
                    lambda payload: "hookSpecificOutput" in payload,
                ),
                "guard": (
                    '{"session_id":"clone-session","turn_id":"guard-turn",'
                    '"hook_event_name":"PreToolUse","tool_name":"Bash",'
                    '"tool_input":{"command":"rm -rf synthetic-safe-target"}}\n',
                    lambda payload: payload.get("hookSpecificOutput", {}).get("permissionDecision") == "deny",
                ),
                "stop": (
                    '{"session_id":"clone-session","turn_id":"stop-turn",'
                    '"hook_event_name":"Stop","stop_hook_active":false}\n',
                    lambda payload: payload.get("decision") == "block",
                ),
            }
            for location in (clone, clone / "nested" / "directory"):
                location.mkdir(parents=True, exist_ok=True)
                for hook, (request, accepts) in requests.items():
                    command = command_for[hook]
                    result = run(
                        ["/bin/bash", "-c", command],
                        cwd=location,
                        env=hook_env,
                        input_text=request,
                    )
                    try:
                        payload = json.loads(result.stdout) if result.stdout else {}
                    except json.JSONDecodeError:
                        payload = {}
                    check(
                        f"Codex {hook} command runs from {location.relative_to(clone) or '.'}",
                        result.returncode == 0 and accepts(payload),
                        f"exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}",
                    )

if failures:
    print(f"\n{len(failures)} project clone regression assertion(s) failed.", file=sys.stderr)
    raise SystemExit(1)
print("\nProject clone regression checks passed.")
PY
