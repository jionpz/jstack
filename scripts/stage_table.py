from __future__ import annotations

import re
import sys
from pathlib import Path


STAGE_COLUMNS = ("Stage", "Output", "Gate", "Providers", "Tool profile")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
BACKTICK_RE = re.compile(r"`([^`]+)`")
TIER_RE = re.compile(r"bulk\s*/\s*(bulk|premium|-)")


class StageTableError(ValueError):
    pass


def parse_stage_table(text: str, *, require_tiers: bool = False) -> dict[str, dict[str, object]]:
    in_section = False
    header = None
    rows = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if line.startswith("## "):
            if header is not None:
                break
            in_section = line == "## Stages"
        if not in_section or not line.startswith("|"):
            if header is not None and line:
                break
            continue
        cells = tuple(cell.strip() for cell in line.removeprefix("|").removesuffix("|").split("|"))
        if header is None:
            optional = cells[len(STAGE_COLUMNS):]
            if cells[:len(STAGE_COLUMNS)] != STAGE_COLUMNS or optional not in (
                (), ("Tier",), ("Managed ticket",), ("Managed ticket", "Tier"),
            ):
                raise StageTableError("Stages 表头必须以这些列开头：" + " | ".join(STAGE_COLUMNS))
            if require_tiers and "Tier" not in optional:
                raise StageTableError("Stages 表缺少 Tier 列")
            header = cells
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) != len(header):
            raise StageTableError(f"Stages 表第 {number} 行列数与表头不匹配")
        row = dict(zip(header, cells))
        stage = row["Stage"]
        if not NAME_RE.fullmatch(stage):
            raise StageTableError(f"Stages 表第 {number} 行的阶段名不合法：{stage}")
        if stage in rows:
            raise StageTableError(f"Stages 表重复定义阶段：{stage}")
        profiles = BACKTICK_RE.findall(row["Tool profile"])
        if len(profiles) != 1 or not NAME_RE.fullmatch(profiles[0]):
            raise StageTableError(f"阶段 {stage} 的 Tool profile 必须声明一个合法 profile")
        rows[stage] = {
            "output": row["Output"],
            "gate": row["Gate"],
            "providers": BACKTICK_RE.findall(row["Providers"]),
            "tool_profile": profiles[0],
        }
        if "Managed ticket" in row:
            if row["Managed ticket"] not in ("required", "-"):
                raise StageTableError(f"阶段 {stage} 的 Managed ticket 必须是 required 或 -")
            rows[stage]["managed"] = row["Managed ticket"] == "required"
        if "Tier" in row:
            match = TIER_RE.fullmatch(row["Tier"])
            if not match:
                raise StageTableError(f"阶段 {stage} 的 Tier 必须是 bulk / bulk、bulk / premium 或 bulk / -")
            rows[stage]["tier"] = {
                "work": "bulk",
                "gate": None if match[1] == "-" else match[1],
            }
    if not rows:
        raise StageTableError("找不到非空 Stages 表")
    return rows


def stage_tiers(rows):
    return {name: row["tier"] for name, row in rows.items() if "tier" in row}


def model_roles(path: Path) -> None:
    rows = parse_stage_table(path.read_text(encoding="utf-8"), require_tiers=True)
    for stage, tiers in stage_tiers(rows).items():
        role = "flow route" if stage == "size" else f"flow {stage}"
        print(f"{role}|{tiers['work']}0")
        if tiers["gate"]:
            tier = "bulk0" if tiers["gate"] == "bulk" else tiers["gate"]
            print(f"{role} gate|{tier}")


if __name__ == "__main__":
    try:
        model_roles(Path(sys.argv[1]))
    except (StageTableError, OSError) as error:
        sys.exit(f"jstack: {error}")
