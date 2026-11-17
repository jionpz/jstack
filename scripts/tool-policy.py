from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


REQUIRED_CAPABILITIES = ("read", "grep", "find", "ls", "edit", "write", "bash", "delegate")
OPTIONAL_CAPABILITIES = ("web_search", "web_fetch")
CAPABILITIES = REQUIRED_CAPABILITIES + OPTIONAL_CAPABILITIES
HARNESSES = ("pi", "claude-code")
STAGE_COLUMNS = ("Stage", "Output", "Gate", "Providers", "Tool profile")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
TOOL_RE = re.compile(r"^[A-Za-z0-9_.:/-]+$")
BACKTICK_RE = re.compile(r"`([^`]+)`")


class ToolPolicyError(Exception):
    pass


def fail(message: str) -> None:
    raise ToolPolicyError(message)


def no_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 里有重复字段：{key}")
        result[key] = value
    return result


def read_text(root: Path, path: Path, label: str) -> str:
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        fail(f"缺少或无法读取{label}：{path}（{exc.strerror or exc}）")
    try:
        resolved.relative_to(root)
    except ValueError:
        fail(f"{label}越出仓库根目录：{path}")
    if not resolved.is_file():
        fail(f"{label}不是普通文件：{path}")
    try:
        content = resolved.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"{label}无法按 UTF-8 读取：{path}（{exc}）")
    if not content.strip():
        fail(f"{label}为空：{path}")
    return content


def find_route_dir(root: Path) -> Path:
    try:
        root = root.resolve(strict=True)
    except OSError as exc:
        fail(f"仓库根目录不存在：{root}（{exc.strerror or exc}）")
    if not root.is_dir():
        fail(f"仓库根目录不是目录：{root}")
    for candidate in (
        root / "src/flow/skills/route",
        root / "skills/route",
        root / "plugins/flow/skills/route",
        root,
    ):
        if (candidate / "stages.md").is_file() or (candidate / "tool-policy.json").is_file():
            return candidate
    fail(f"找不到 stages.md 和 tool-policy.json：{root}")


def source_commit(root: Path) -> str:
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
    return result.stdout.strip() or "unversioned"


def parse_stages(text: str) -> dict[str, str]:
    in_section = False
    header: tuple[str, ...] | None = None
    rows: dict[str, str] = {}
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
            if not cells or cells[0] != "Stage":
                fail(f"Stages 表头必须以 Stage 开头：第 {number} 行")
            if cells != STAGE_COLUMNS:
                fail("Stages 表头必须是：" + " | ".join(STAGE_COLUMNS))
            header = cells
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) != len(header):
            fail(f"Stages 表第 {number} 行有 {len(cells)} 列，表头有 {len(header)} 列")
        row = dict(zip(header, cells))
        stage = row["Stage"]
        if not NAME_RE.fullmatch(stage):
            fail(f"Stages 表第 {number} 行的阶段名不合法：{stage}")
        if stage in rows:
            fail(f"Stages 表重复定义阶段：{stage}")
        match = BACKTICK_RE.findall(row["Tool profile"])
        if len(match) != 1:
            fail(f"阶段 {stage} 的 Tool profile 必须是一个反引号括起来的 profile 名")
        profile = match[0]
        if not NAME_RE.fullmatch(profile):
            fail(f"阶段 {stage} 的 profile 名不合法：{profile}")
        rows[stage] = profile
    if header is None:
        fail("找不到 ## Stages 表")
    if not rows:
        fail("Stages 表里没有阶段")
    return rows


def check_string_list(value: object, label: str, allowed: tuple[str, ...], *, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or (not value and not allow_empty):
        fail(f"{label} 必须是{'数组' if allow_empty else '非空数组'}")
    seen: set[str] = set()
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"{label} 的每一项都必须是非空字符串")
        if item not in allowed:
            fail(f"{label} 里有未知能力：{item}")
        if item in seen:
            fail(f"{label} 里有重复能力：{item}")
        seen.add(item)
        result.append(item)
    return result


def validate_policy(policy: object) -> dict[str, object]:
    if not isinstance(policy, dict):
        fail("tool-policy.json 顶层必须是对象")
    if set(policy) != {"protocol_version", "profiles", "harnesses"}:
        fail("tool-policy.json 顶层只能有 protocol_version、profiles、harnesses")
    if policy["protocol_version"] != "1.0":
        fail("tool-policy.json 的 protocol_version 必须是 1.0")
    profiles = policy["profiles"]
    if not isinstance(profiles, dict) or not profiles:
        fail("tool-policy.json 的 profiles 必须是非空对象")
    for name, profile in profiles.items():
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            fail(f"profile 名不合法：{name}")
        if not isinstance(profile, dict):
            fail(f"profile {name} 必须是对象")
        if set(profile) != {"role", "capabilities", "optional_capabilities"}:
            fail(f"profile {name} 只能有 role、capabilities、optional_capabilities")
        role = profile["role"]
        if not isinstance(role, str) or not role:
            fail(f"profile {name} 的 role 必须是非空字符串")
        required = check_string_list(profile["capabilities"], f"profile {name} 的 capabilities", REQUIRED_CAPABILITIES)
        optional = check_string_list(
            profile["optional_capabilities"],
            f"profile {name} 的 optional_capabilities",
            OPTIONAL_CAPABILITIES,
            allow_empty=True,
        )
        overlap = set(required) & set(optional)
        if overlap:
            fail(f"profile {name} 的能力既是必需又是可选：{', '.join(sorted(overlap))}")
    harnesses = policy["harnesses"]
    if not isinstance(harnesses, dict):
        fail("tool-policy.json 的 harnesses 必须是对象")
    if set(harnesses) != set(HARNESSES):
        fail("tool-policy.json 的 harnesses 必须正好有 pi 和 claude-code")
    for harness, mapping in harnesses.items():
        if not isinstance(mapping, dict):
            fail(f"harness {harness} 的映射必须是对象")
        if set(mapping) != set(CAPABILITIES):
            unknown = sorted(set(mapping) - set(CAPABILITIES))
            missing = sorted(set(CAPABILITIES) - set(mapping))
            detail = []
            if unknown:
                detail.append("未知能力 " + ", ".join(unknown))
            if missing:
                detail.append("缺少能力 " + ", ".join(missing))
            fail(f"harness {harness} 的映射不完整：{'；'.join(detail)}")
        bash_tools = mapping["bash"]
        shell_names = set(bash_tools.get("native", [])) if isinstance(bash_tools, dict) else set()
        for capability, spec in mapping.items():
            if not isinstance(spec, dict):
                fail(f"harness {harness} 的 {capability} 映射必须是对象")
            extra = sorted(set(spec) - {"native", "fallback", "extension"})
            if extra:
                fail(f"harness {harness} 的 {capability} 映射有未知字段：{', '.join(extra)}")
            native = spec.get("native")
            if not isinstance(native, list) or not native:
                fail(f"harness {harness} 的 {capability} 必须有非空 native 数组")
            seen: set[str] = set()
            for tool in native:
                if not isinstance(tool, str) or not TOOL_RE.fullmatch(tool):
                    fail(f"harness {harness} 的 {capability} 有不合法的工具名：{tool}")
                if tool in seen:
                    fail(f"harness {harness} 的 {capability} 有重复工具名：{tool}")
                seen.add(tool)
            fallback = spec.get("fallback")
            if fallback is not None:
                if capability == "bash":
                    fail(f"harness {harness} 的 bash 不能有 shell fallback")
                if not isinstance(fallback, str) or fallback not in shell_names:
                    fail(f"harness {harness} 的 {capability} fallback 必须是该 harness 的 shell 工具")
                if fallback in seen:
                    fail(f"harness {harness} 的 {capability} fallback 不能同时是原生工具")
            extension = spec.get("extension")
            if extension is not None and not isinstance(extension, bool):
                fail(f"harness {harness} 的 {capability} extension 必须是布尔值")
    return policy


def load(root: Path) -> tuple[dict[str, str], dict[str, object], Path]:
    try:
        root = root.resolve(strict=True)
    except OSError as exc:
        fail(f"仓库根目录不存在：{root}（{exc.strerror or exc}）")
    route_dir = find_route_dir(root)
    try:
        policy_text = read_text(root, route_dir / "tool-policy.json", "tool-policy.json")
    except ToolPolicyError as exc:
        fail(str(exc))
    try:
        policy = json.loads(policy_text, object_pairs_hook=no_duplicate_keys)
    except json.JSONDecodeError as exc:
        fail(f"tool-policy.json 不是合法 JSON：{exc}")
    policy = validate_policy(policy)
    stages_text = read_text(root, route_dir / "stages.md", "stages.md")
    stages = parse_stages(stages_text)
    profiles = policy["profiles"]
    assert isinstance(profiles, dict)
    for stage, profile in stages.items():
        if profile not in profiles:
            fail(f"阶段 {stage} 引用了 tool-policy.json 里没有的 profile：{profile}")
    return stages, policy, route_dir


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(payload: dict[str, object]) -> str:
    body = {key: value for key, value in payload.items() if key != "content_digest"}
    return hashlib.sha256(canonical(body)).hexdigest()


def export_payload(root: Path) -> dict[str, object]:
    stages, policy, _ = load(root)
    payload: dict[str, object] = {
        "protocol_version": "1.0",
        "source_commit": source_commit(root),
        "stages": stages,
        "profiles": policy["profiles"],
        "harnesses": policy["harnesses"],
    }
    payload["content_digest"] = digest(payload)
    return payload


def read_inventory(path: Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"无法读取 inventory：{path}（{exc}）")
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(f"inventory 不是合法 JSON：{exc}")
    names: list[str] = []
    if isinstance(value, list):
        names = value
    elif isinstance(value, dict):
        tools = value.get("tools")
        if not isinstance(tools, list):
            fail("inventory 对象必须有 tools 数组")
        for tool in tools:
            if not isinstance(tool, dict):
                fail("inventory 的 tools 每一项都必须是对象")
            names.append(tool.get("name"))
    else:
        fail("inventory 必须是工具名数组或 {tools: [...]} 对象")
    result: set[str] = set()
    for name in names:
        if not isinstance(name, str) or not name:
            fail("inventory 的工具名必须是非空字符串")
        result.add(name)
    return result


def resolve_payload(
    root: Path,
    *,
    stage: str | None,
    role: str | None,
    harness: str,
    inventory_path: Path,
    allow_shell_fallback: bool,
) -> dict[str, object]:
    stages, policy, _ = load(root)
    if (stage is None) == (role is None):
        fail("必须且只能给 --stage 或 --role 之一")
    if stage is not None:
        if stage not in stages:
            fail(f"阶段表里没有阶段：{stage}")
        profile_name = stages[stage]
    else:
        profile_name = role
        assert profile_name is not None
        if profile_name not in policy["profiles"]:
            fail(f"tool-policy.json 里没有 profile：{profile_name}")
    if harness not in HARNESSES:
        fail(f"未知 harness：{harness}（可用 pi、claude-code）")
    profiles = policy["profiles"]
    harnesses = policy["harnesses"]
    assert isinstance(profiles, dict) and isinstance(harnesses, dict)
    profile = profiles[profile_name]
    mapping = harnesses[harness]
    assert isinstance(profile, dict) and isinstance(mapping, dict)
    inventory = read_inventory(inventory_path)

    tools: list[str] = []
    degradations: list[dict[str, object]] = []
    missing_required: list[dict[str, object]] = []
    missing_optional: list[str] = []

    def add(tool: str) -> None:
        if tool not in tools:
            tools.append(tool)

    for capability in profile["capabilities"]:
        spec = mapping[capability]
        assert isinstance(spec, dict)
        native = spec["native"]
        assert isinstance(native, list)
        chosen = next((tool for tool in native if tool in inventory), None)
        if chosen is not None:
            add(chosen)
            continue
        fallback = spec.get("fallback")
        if isinstance(fallback, str) and fallback in inventory:
            if allow_shell_fallback:
                add(fallback)
                degradations.append(
                    {
                        "capability": capability,
                        "native_candidates": native,
                        "tool": fallback,
                        "reason": "native tool missing; shell fallback explicitly allowed",
                    }
                )
                continue
            missing_required.append(
                {
                    "capability": capability,
                    "native_candidates": native,
                    "fallback": fallback,
                    "reason": "--allow-shell-fallback required",
                }
            )
            continue
        entry: dict[str, object] = {"capability": capability, "native_candidates": native}
        if isinstance(fallback, str):
            entry["fallback"] = fallback
            entry["reason"] = "native tool and shell fallback missing"
        missing_required.append(entry)

    for capability in profile["optional_capabilities"]:
        spec = mapping[capability]
        assert isinstance(spec, dict)
        native = spec["native"]
        assert isinstance(native, list)
        chosen = next((tool for tool in native if tool in inventory), None)
        if chosen is None:
            missing_optional.append(capability)
        else:
            add(chosen)

    if missing_required:
        lines = []
        for entry in missing_required:
            candidates = ", ".join(entry["native_candidates"])
            reason = entry.get("reason", "")
            lines.append(f"{entry['capability']}（候选 {candidates}；{reason}）")
        fail("缺少必需工具：" + "；".join(lines))

    return {
        "protocol_version": "1.0",
        "harness": harness,
        "stage": stage,
        "profile": profile_name,
        "role": profile["role"],
        "native_tools": tools,
        "permissions": {"allowed_tools": list(tools)},
        "degradations": degradations,
        "missing_optional": missing_optional,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="导出 jstack 工具配置并解析为 harness 原生工具")
    sub = parser.add_subparsers(dest="command", required=True)
    default_root = Path(__file__).resolve().parent.parent

    export_parser = sub.add_parser("export", help="导出 protocol 1.0 工具配置 JSON")
    export_parser.add_argument("--root", type=Path, default=default_root, help="jstack 仓库或插件目录")
    export_parser.add_argument("--pretty", action="store_true", help="缩进输出；默认紧凑 JSON")

    resolve_parser = sub.add_parser("resolve", help="把阶段或 profile 解析为原生工具")
    resolve_parser.add_argument("--root", type=Path, default=default_root, help="jstack 仓库或插件目录")
    resolve_parser.add_argument("--stage")
    resolve_parser.add_argument("--role")
    resolve_parser.add_argument("--harness", required=True)
    resolve_parser.add_argument("--inventory", type=Path, required=True)
    resolve_parser.add_argument("--allow-shell-fallback", action="store_true")
    resolve_parser.add_argument("--pretty", action="store_true", help="缩进输出；默认紧凑 JSON")

    args = parser.parse_args(argv)
    try:
        if args.command == "export":
            payload = export_payload(args.root)
        else:
            payload = resolve_payload(
                args.root,
                stage=args.stage,
                role=args.role,
                harness=args.harness,
                inventory_path=args.inventory,
                allow_shell_fallback=args.allow_shell_fallback,
            )
    except ToolPolicyError as exc:
        print(f"tool-policy: 错误：{exc}", file=sys.stderr)
        return 1
    if args.pretty:
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    else:
        json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
