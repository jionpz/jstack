from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


SOURCE = "npm:@tintinweb/pi-subagents@0.23.2"
PACKAGE = "@tintinweb/pi-subagents"
PINNED_VERSION = "0.23.2"
SECTION_RE = re.compile(r"^(User|Project) packages:\s*$")
PACKAGE_LINE_RE = re.compile(r"^\s{2}(\S.*?)\s*$")
NPM_VERSION_RE = re.compile(r"^npm:(?:@[^/\s]+/)?[^@\s]+@([^\s]+)$")


class RecommendedError(Exception):
    pass


def config_path(scope: str, repo: Path | None) -> Path:
    if scope == "project":
        base = repo if repo is not None else Path.cwd()
        return base / ".pi/settings.json"
    agent_dir = os.environ.get("PI_AGENT_DIR")
    base = Path(agent_dir).expanduser() if agent_dir else Path.home() / ".pi/agent"
    return base / "settings.json"


def metadata(scope: str, repo: Path | None) -> dict[str, object]:
    path = config_path(scope, repo)
    config = str(path) if scope == "user" else path.relative_to(repo).as_posix() if repo else ".pi/settings.json"
    return {
        "source": SOURCE,
        "package": PACKAGE,
        "pinned_version": PINNED_VERSION,
        "scope": scope,
        "config": config,
    }


def run_pi(pi: str, args: list[str], cwd: Path | None, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [pi, *args],
            cwd=cwd,
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=300,
        )
    except FileNotFoundError as exc:
        raise RecommendedError(f"找不到 Pi CLI：{pi}") from exc
    except subprocess.SubprocessError as exc:
        raise RecommendedError(f"运行 Pi CLI 失败：{exc}") from exc


def list_packages(pi: str, scope: str, repo: Path | None) -> dict[str, dict[str, str]]:
    cwd = repo if scope == "project" else None
    result = run_pi(pi, ["list", "--approve"], cwd)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"退出码 {result.returncode}"
        raise RecommendedError(f"pi list 失败：{detail}")
    sections: dict[str, dict[str, str]] = {"user": {}, "project": {}}
    current: str | None = None
    for line in result.stdout.splitlines():
        header = SECTION_RE.match(line.strip())
        if header:
            current = header.group(1).lower()
            continue
        if current is None:
            continue
        match = PACKAGE_LINE_RE.match(line)
        if not match:
            continue
        source = match.group(1)
        if "pi-subagents" not in source:
            continue
        version_match = NPM_VERSION_RE.match(source)
        sections[current][PACKAGE] = version_match.group(1) if version_match else "unknown"
    return sections


def install(pi: str, scope: str, repo: Path | None) -> dict[str, object]:
    args = ["install", SOURCE, "--approve"]
    if scope == "project":
        args.insert(2, "-l")
    env = dict(os.environ)
    env["npm_config_ignore_scripts"] = "true"
    cwd = repo if scope == "project" else None
    result = run_pi(pi, args, cwd, env)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"退出码 {result.returncode}"
        raise RecommendedError(f"安装 {SOURCE} 失败：{detail}")
    after = list_packages(pi, scope, repo)
    version = after[scope].get(PACKAGE)
    return {"version": version}


def execute(args: argparse.Namespace) -> dict[str, object]:
    scope = args.scope
    repo = args.repo.resolve(strict=True) if args.repo is not None else None
    if scope == "project" and repo is None:
        repo = Path.cwd().resolve(strict=True)
    if scope == "project" and not repo.is_dir():
        raise RecommendedError(f"--repo 不是目录：{repo}")
    base = metadata(scope, repo)
    if args.metadata:
        return base
    existing = list_packages(args.pi, scope, repo)
    current = existing[scope].get(PACKAGE)
    if current is not None:
        return {
            **base,
            "status": "skipped",
            "version": current,
            "matches_pinned": current == PINNED_VERSION,
        }
    if args.dry_run:
        return {**base, "status": "would-install", "version": None, "matches_pinned": False}
    installed = install(args.pi, scope, repo)
    version = installed["version"]
    return {
        **base,
        "status": "installed",
        "version": version,
        "matches_pinned": version == PINNED_VERSION,
    }


def describe(payload: dict[str, object]) -> str:
    status = payload["status"]
    config = payload["config"]
    if status == "skipped":
        version = payload.get("version") or "unknown"
        note = "" if payload.get("matches_pinned") else f"，期望 {PINNED_VERSION}，未改动已有包"
        return f"- 已存在 {PACKAGE}@{version}（{payload['scope']}，{config}），跳过{note}"
    if status == "would-install":
        return f"- 将安装 {SOURCE}（{payload['scope']}，{config}）；--dry-run 不执行"
    version = payload.get("version") or "unknown"
    return f"✓ 已安装 {SOURCE}（{payload['scope']}，{config}），实测 {PACKAGE}@{version}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="安装或检查 jstack 推荐的 Pi 子代理包")
    parser.add_argument("--scope", choices=("user", "project"), default="user")
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--metadata", action="store_true")
    parser.add_argument("--pi", default="pi", help="Pi CLI 路径，默认 pi")
    args = parser.parse_args(argv)
    try:
        payload = execute(args)
    except (RecommendedError, OSError) as exc:
        print(f"pi-recommended: 错误：{exc}", file=sys.stderr)
        return 1
    if args.json or args.metadata:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    else:
        print(describe(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
