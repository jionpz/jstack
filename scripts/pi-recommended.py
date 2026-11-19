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
PACKAGE_SOURCE_RE = re.compile(r"^npm:@tintinweb/pi-subagents(?:@([^\s]+))?$")


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


def package_version(source: str) -> str | None:
    match = PACKAGE_SOURCE_RE.fullmatch(source)
    return match.group(1) if match else None


def package_entry_source(entry: object) -> str | None:
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict) and isinstance(entry.get("source"), str):
        return entry["source"]
    return None


def project_declaration(repo: Path, *, declare: bool, dry_run: bool) -> dict[str, object]:
    path = config_path("project", repo)
    if path.parent.is_symlink() or path.is_symlink():
        raise RecommendedError(f"Pi 项目设置路径不能是符号链接：{path}")
    if path.exists():
        try:
            settings = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise RecommendedError(f"无法读取 Pi 项目设置：{path}") from exc
        if not isinstance(settings, dict):
            raise RecommendedError(f"Pi 项目设置必须是 JSON 对象：{path}")
    else:
        settings = {}

    packages = settings.get("packages", [])
    if not isinstance(packages, list):
        raise RecommendedError(f"Pi 项目设置 packages 必须是数组：{path}")

    for entry in packages:
        source = package_entry_source(entry)
        version = package_version(source) if source is not None else None
        if version is not None or source == f"npm:{PACKAGE}":
            return {
                "source": source,
                "version": version or "unknown",
                "declaration_created": False,
            }

    if not declare:
        return {"source": None, "version": None, "declaration_created": False}
    if not dry_run:
        packages.append(SOURCE)
        settings["packages"] = packages
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {
        "source": SOURCE,
        "version": PINNED_VERSION,
        "declaration_created": not dry_run,
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


def list_packages(pi: str, scope: str, repo: Path | None) -> dict[str, dict[str, dict[str, str]]]:
    cwd = repo if scope == "project" else None
    result = run_pi(pi, ["list", "--approve"], cwd)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"退出码 {result.returncode}"
        raise RecommendedError(f"pi list 失败：{detail}")
    sections: dict[str, dict[str, dict[str, str]]] = {"user": {}, "project": {}}
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
        version = package_version(source)
        if version is None:
            if source != f"npm:{PACKAGE}":
                continue
            version = "unknown"
        sections[current][PACKAGE] = {"source": source, "version": version}
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
    package = after[scope].get(PACKAGE)
    version = package["version"] if package else None
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
    if args.stage_project_declaration or args.project_declaration:
        if scope != "project":
            raise RecommendedError("项目包声明仅支持 --scope project")
        assert repo is not None
        return project_declaration(repo, declare=args.stage_project_declaration, dry_run=args.dry_run)
    existing = list_packages(args.pi, scope, repo)
    current = existing[scope].get(PACKAGE)
    if current is not None:
        return {
            **base,
            "status": "skipped",
            "version": current["version"],
            "matches_pinned": current["version"] == PINNED_VERSION,
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
    declaration = parser.add_mutually_exclusive_group()
    declaration.add_argument(
        "--project-declaration",
        action="store_true",
        help="只读检查 Pi 项目设置中的推荐包声明",
    )
    declaration.add_argument(
        "--stage-project-declaration",
        action="store_true",
        help="直接在项目 Pi 设置中添加推荐包声明，不运行 Pi 或 npm",
    )
    parser.add_argument("--pi", default="pi", help="Pi CLI 路径，默认 pi")
    args = parser.parse_args(argv)
    try:
        payload = execute(args)
    except (RecommendedError, OSError) as exc:
        print(f"pi-recommended: 错误：{exc}", file=sys.stderr)
        return 1
    if args.json or args.metadata or args.project_declaration:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    elif args.stage_project_declaration:
        action = "预览" if args.dry_run else "已添加" if payload["declaration_created"] else "已存在"
        print(f"✓ {action} {payload['source']}（声明版本 {payload['version']}）")
    else:
        print(describe(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
