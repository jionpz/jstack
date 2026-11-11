#!/usr/bin/env python3
"""导出 Keel managed 模式所需的固定工作流包。"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


ROUTE_PATH = Path("src/flow/skills/route/SKILL.md")
STAGES_PATH = Path("src/flow/skills/route/stages.md")
EXECUTE_PATH = Path("src/managed/investigate.md")
MUST_STOP_PATH = Path("src/flow/skills/route/must-stop.md")
TOOL_POLICY_PATH = Path("src/flow/skills/route/tool-policy.json")
TICKET_STAGES = ("execute", "verify", "review", "land")
TICKET_STAGE_PROVIDERS = {
    "execute": "flow:execute",
    "verify": "pstack:principle-prove-it-works",
    "review": "flow:review",
    "land": "pstack:poteto-mode/playbooks/opening-a-pr.md",
}
TICKET_PROVIDER_PATHS = {
    "flow:execute": Path("src/flow/skills/execute/SKILL.md"),
    "pstack:principle-prove-it-works": Path(
        "plugins/pstack/skills/principle-prove-it-works/SKILL.md"
    ),
    "flow:review": Path("src/flow/skills/review/SKILL.md"),
    "pstack:poteto-mode/playbooks/opening-a-pr.md": Path(
        "plugins/pstack/skills/poteto-mode/playbooks/opening-a-pr.md"
    ),
}
STAGE_COLUMNS = ("Stage", "Output", "Gate", "Providers", "Tool profile")
BACKTICK_RE = re.compile(r"`([^`]+)`")


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


def digest_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def digest_payload(payload: dict[str, object]) -> str:
    body = {key: value for key, value in payload.items() if key != "content_digest"}
    return hashlib.sha256(canonical(body)).hexdigest()


def read_source(root: Path, relative: Path) -> tuple[str, dict[str, object]]:
    content = read_required(root, relative)
    return content, {
        "path": relative.as_posix(),
        "sha256": digest_text(content),
        "bytes": len(content.encode("utf-8")),
    }


def parse_stage_table(text: str) -> dict[str, dict[str, object]]:
    in_section = False
    header: tuple[str, ...] | None = None
    rows: dict[str, dict[str, object]] = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if line.startswith("## "):
            if in_section and header is not None:
                break
            in_section = line == "## Stages"
            continue
        if not in_section or not line.startswith("|"):
            if in_section and header is not None and line:
                break
            continue
        cells = tuple(cell.strip() for cell in line.strip("|").split("|"))
        if header is None:
            if cells != STAGE_COLUMNS:
                raise ExportError("Stages 表头必须是：" + " | ".join(STAGE_COLUMNS))
            header = cells
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) != len(header):
            raise ExportError(f"Stages 表第 {number} 行列数不匹配")
        row = dict(zip(header, cells))
        stage = row["Stage"]
        if stage in rows:
            raise ExportError(f"Stages 表重复定义阶段：{stage}")
        providers = BACKTICK_RE.findall(row["Providers"])
        profiles = BACKTICK_RE.findall(row["Tool profile"])
        if len(profiles) != 1:
            raise ExportError(f"阶段 {stage} 必须声明一个 tool profile")
        rows[stage] = {
            "output": row["Output"],
            "gate": row["Gate"],
            "providers": providers,
            "tool_profile": profiles[0],
        }
    if header is None or not rows:
        raise ExportError("找不到非空 Stages 表")
    return rows


def parse_must_stop(text: str) -> list[dict[str, str]]:
    actions: list[dict[str, str]] = []
    header: tuple[str, ...] | None = None
    in_section = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("## "):
            if in_section and header is not None:
                break
            in_section = line == "## Must stop"
            continue
        if not in_section or not line.startswith("|"):
            if in_section and header is not None and line:
                break
            continue
        cells = tuple(cell.strip() for cell in line.strip("|").split("|"))
        if header is None:
            if cells != ("Action", "Hook"):
                raise ExportError("Must stop 表头必须是：Action | Hook")
            header = cells
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) != 2 or not cells[0]:
            raise ExportError("Must stop 表行不完整")
        actions.append({"action": cells[0], "hook": cells[1]})
    if not actions:
        raise ExportError("must-stop 表为空")
    return actions


def build_tool_policy(
    root: Path, stages: dict[str, dict[str, object]]
) -> tuple[dict[str, object], dict[str, object]]:
    raw_text, manifest = read_source(root, TOOL_POLICY_PATH)
    try:
        raw = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ExportError(f"tool-policy.json 不是合法 JSON：{exc}") from exc
    if not isinstance(raw, dict) or raw.get("protocol_version") != "1.0":
        raise ExportError("tool-policy.json protocol_version 必须是 1.0")
    profiles = raw.get("profiles")
    harnesses = raw.get("harnesses")
    if not isinstance(profiles, dict) or not profiles:
        raise ExportError("tool-policy.json profiles 必须是非空对象")
    if not isinstance(harnesses, dict) or not harnesses:
        raise ExportError("tool-policy.json harnesses 必须是非空对象")
    stage_profiles = {stage: row["tool_profile"] for stage, row in stages.items()}
    for stage, profile in stage_profiles.items():
        if profile not in profiles:
            raise ExportError(f"阶段 {stage} 引用了不存在的 tool profile：{profile}")
    policy: dict[str, object] = {
        "protocol_version": "1.0",
        "source_commit": source_commit(root),
        "stages": stage_profiles,
        "profiles": profiles,
        "harnesses": harnesses,
    }
    policy["content_digest"] = digest_payload(policy)
    return policy, manifest


def export_investigation(root: Path) -> dict[str, object]:
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


def export_ticket(
    root: Path,
    ticket_id: str,
    ticket_title: str,
    ticket_description: str | None,
    size: str,
    completion_target: str = "branch_ready",
) -> dict[str, object]:
    root = root.resolve(strict=True)
    if not ticket_id.strip() or len(ticket_id) > 200:
        raise ExportError("ticket id 必须为 1..200 字符")
    if not ticket_title.strip() or len(ticket_title) > 1000:
        raise ExportError("ticket title 必须为 1..1000 字符")
    if ticket_description is not None and (
        not ticket_description.strip() or len(ticket_description) > 20000
    ):
        raise ExportError("ticket description 必须为 1..20000 字符")
    if size not in ("XS", "S"):
        raise ExportError("ticket size 只接受 XS 或 S")
    if completion_target not in ("branch_ready", "pr_ready"):
        raise ExportError("completion target 只接受 branch_ready 或 pr_ready")

    route, route_manifest = read_source(root, ROUTE_PATH)
    stages_text, stages_manifest = read_source(root, STAGES_PATH)
    must_stop_text, must_stop_manifest = read_source(root, MUST_STOP_PATH)
    stage_table = parse_stage_table(stages_text)
    must_stop_actions = parse_must_stop(must_stop_text)
    tool_policy, policy_manifest = build_tool_policy(root, stage_table)

    stages: list[dict[str, object]] = []
    sources = [
        route_manifest,
        stages_manifest,
        must_stop_manifest,
        policy_manifest,
    ]
    for stage in TICKET_STAGES:
        row = stage_table.get(stage)
        if row is None:
            raise ExportError(f"Stages 表缺少 ticket 阶段：{stage}")
        provider = TICKET_STAGE_PROVIDERS[stage]
        if provider not in row["providers"]:
            raise ExportError(f"阶段 {stage} 没有声明 provider {provider}")
        provider_path = TICKET_PROVIDER_PATHS[provider]
        content, manifest = read_source(root, provider_path)
        sources.append(manifest)
        stages.append(
            {
                "stage": stage,
                "provider": provider,
                "provider_path": provider_path.as_posix(),
                "gate": row["gate"],
                "tool_profile": row["tool_profile"],
                "instructions": content,
                "content_digest": digest_text(content),
            }
        )

    ticket: dict[str, object] = {"id": ticket_id.strip(), "title": ticket_title.strip()}
    if ticket_description is not None:
        ticket["description"] = ticket_description.strip()

    package: dict[str, object] = {
        "protocol_version": "1.0",
        "workflow_id": "jstack",
        "mode": "ticket",
        "source_commit": source_commit(root),
        "ticket": ticket,
        "route": {"size": size, "stages": list(TICKET_STAGES)},
        "stages": stages,
        "instructions": {
            "route": route,
            "stages": stages_text,
            "must_stop": must_stop_text,
        },
        "tool_policy": tool_policy,
        "must_stop": {
            "content": must_stop_text,
            "actions": must_stop_actions,
            "content_digest": digest_text(must_stop_text),
        },
        "completion_target": completion_target,
        "sources": sources,
    }
    package["content_digest"] = digest_payload(package)
    return package


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="导出 jstack managed 工作流包 JSON")
    parser.add_argument("--root", type=Path, help="jstack 仓库根目录；默认使用本脚本所属仓库")
    parser.add_argument("--ticket-id", help="导出 XS/S 单 ticket 工程包")
    parser.add_argument("--ticket-title", help="ticket 标题；缺省使用 ticket id")
    parser.add_argument("--ticket-description", help="ticket 正文；可选，最多 20000 字符")
    parser.add_argument("--size", choices=("XS", "S"), default="S", help="ticket 规模")
    parser.add_argument(
        "--completion-target",
        choices=("branch_ready", "pr_ready"),
        help="单 ticket 完成目标；缺省 branch_ready，managed 自动交付用 pr_ready",
    )
    args = parser.parse_args(argv)

    root = args.root if args.root is not None else Path(__file__).resolve().parent.parent
    try:
        if args.ticket_id is None:
            if args.ticket_title is not None:
                raise ExportError("--ticket-title 只能与 --ticket-id 一起使用")
            if args.ticket_description is not None:
                raise ExportError("--ticket-description 只能与 --ticket-id 一起使用")
            if args.completion_target is not None:
                raise ExportError("--completion-target 只能与 --ticket-id 一起使用")
            payload = export_investigation(root)
        else:
            payload = export_ticket(
                root,
                args.ticket_id,
                args.ticket_title or args.ticket_id,
                args.ticket_description,
                args.size,
                args.completion_target or "branch_ready",
            )
    except (ExportError, OSError) as exc:
        print(f"managed-export: 错误：{exc}", file=sys.stderr)
        return 1

    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
