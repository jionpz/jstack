#!/usr/bin/env python3
"""导出只读 managed 模式所需的最小工作流指令。"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


ROUTE_PATH = Path("src/flow/skills/route/SKILL.md")
STAGES_PATH = Path("src/flow/skills/route/stages.md")
EXECUTE_PATH = Path("src/managed/investigate.md")


class ExportError(Exception):
    """输入仓库缺少安全、完整的导出材料。"""


def read_required(root: Path, relative: Path) -> str:
    """读取根目录内的非空普通文件，拒绝解析到根目录外的路径。"""
    path = root / relative
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise ExportError(f"缺少或无法读取必需文件：{relative}（{exc.strerror or exc}）") from exc

    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ExportError(f"必需文件路径越出仓库根目录：{relative}") from exc

    if not resolved.is_file():
        raise ExportError(f"必需路径不是普通文件：{relative}")

    try:
        content = resolved.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ExportError(f"必需文件无法按 UTF-8 读取：{relative}（{exc}）") from exc
    if not content.strip():
        raise ExportError(f"必需文件为空：{relative}")
    return content


def source_commit(root: Path) -> str:
    """只查询 Git 元数据，不执行仓库内脚本。"""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return "unversioned"
    commit = result.stdout.strip()
    return commit or "unversioned"


def export(root: Path) -> dict[str, object]:
    """读取并校验全部指令后再构造完整 JSON 对象。"""
    root = root.resolve(strict=True)
    route = read_required(root, ROUTE_PATH)
    stages = read_required(root, STAGES_PATH)
    execute = read_required(root, EXECUTE_PATH)

    if not re.search(r"(?im)^\s*\|\s*Question\s*\|.*execute only", route):
        raise ExportError("route 阶段表未声明 Question 只走 execute only 的只读路线")
    if not any(
        "| execute |" in line.lower()
        for line in stages.splitlines()
    ):
        raise ExportError("stages 表缺少 execute 阶段")

    return {
        "protocol_version": "1.0",
        "workflow_id": "jstack",
        "mode": "investigation",
        "source_commit": source_commit(root),
        "stages": ["execute"],
        "instructions": {"route": route, "stages": stages, "execute": execute},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="导出 jstack 只读调查指令 JSON")
    parser.add_argument("--root", type=Path, help="jstack 仓库根目录；默认使用本脚本所属仓库")
    args = parser.parse_args(argv)

    root = args.root if args.root is not None else Path(__file__).resolve().parent.parent
    try:
        payload = export(root)
    except (ExportError, OSError) as exc:
        print(f"managed-export: 错误：{exc}", file=sys.stderr)
        return 1

    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
