#!/usr/bin/env python3
"""让 ~/.agents/skills 里的同名 skill 优先于 jstack Pi package。

Pi 同时从 ~/.agents/skills 和已安装 package 的 skills 加载 skill；同名时两边都会出现。
这个脚本在 `jstack install-pi` 之后运行，把与 ~/.agents/skills 重名的 jstack skill
写成 package 的负向过滤（`-plugins/.../skills/<name>`），让 .agents 里的那份生效。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def skill_name(skill_md: Path) -> str:
    """读 SKILL.md frontmatter 的 name；没有就用目录名。"""
    try:
        lines = skill_md.read_text(encoding="utf-8").splitlines()
    except OSError:
        return skill_md.parent.name
    if lines and lines[0].strip() == "---":
        for line in lines[1:]:
            if line.strip() == "---":
                break
            if line.startswith("name:"):
                value = line.split(":", 1)[1].strip()
                if value:
                    return value.strip("\"'")
    return skill_md.parent.name


def jstack_skills(root: Path) -> list[tuple[str, str]]:
    """返回 jstack package 里的 (skill 名, 相对 package 根的目录)。"""
    result: list[tuple[str, str]] = []
    for plugin in ("pstack", "spec", "flow"):
        base = root / "plugins" / plugin / "skills"
        if not base.is_dir():
            continue
        for skill_md in sorted(base.rglob("SKILL.md")):
            result.append((skill_name(skill_md), skill_md.parent.relative_to(root).as_posix()))
    return result


def agents_skills(agents: Path) -> set[str]:
    """返回 ~/.agents/skills 下所有 skill 名。"""
    if not agents.is_dir():
        return set()
    return {skill_name(skill_md) for skill_md in agents.glob("*/SKILL.md")}


def resolve_source(source: str, settings_dir: Path) -> Path:
    """Pi 把本地 package 存成相对 settings.json 的路径。"""
    path = Path(source).expanduser()
    if not path.is_absolute():
        path = settings_dir / path
    return path.resolve()


def package_source(entry: object) -> str | None:
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        source = entry.get("source")
        return source if isinstance(source, str) else None
    return None


def write_atomic(path: Path, doc: object) -> None:
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True, type=Path, help="Pi 的 settings.json")
    parser.add_argument("--agents", required=True, type=Path, help="共享的 ~/.agents/skills")
    parser.add_argument("--root", required=True, type=Path, help="jstack package 根目录")
    args = parser.parse_args(argv)

    settings: Path = args.settings
    root = args.root.resolve()
    try:
        doc = json.loads(settings.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print("no settings.json; nothing to filter")
        return 0
    except (OSError, ValueError) as exc:
        print(f"cannot read {settings}: {exc}", file=sys.stderr)
        return 1

    packages = doc.get("packages") if isinstance(doc, dict) else None
    if not isinstance(packages, list):
        print("settings.json has no packages list; nothing to filter")
        return 0

    settings_dir = settings.resolve().parent
    index = None
    for i, entry in enumerate(packages):
        source = package_source(entry)
        if source is not None and resolve_source(source, settings_dir) == root:
            index = i
            break
    if index is None:
        print("jstack package not found in settings.json; nothing to filter")
        return 0

    skills = jstack_skills(root)
    names = agents_skills(args.agents)
    collisions = sorted({(name, rel) for name, rel in skills if name in names})
    all_rels = {rel for _, rel in skills}

    entry = packages[index]
    if isinstance(entry, str):
        entry = {"source": entry}
        packages[index] = entry
    filters = entry.get("skills")
    if filters is None:
        filters = []
    elif not isinstance(filters, list):
        print("jstack package skills is not a list; refusing to edit", file=sys.stderr)
        return 1

    def ours(item: object) -> bool:
        if not isinstance(item, str) or not item.startswith("-"):
            return False
        rel = item[1:].rstrip("/")
        if rel.endswith("/SKILL.md"):
            rel = rel[: -len("/SKILL.md")]
        return rel in all_rels

    kept = [item for item in filters if not ours(item)]
    existing = set(kept)
    added = 0
    for _, rel in collisions:
        item = "-" + rel
        if item not in existing:
            kept.append(item)
            existing.add(item)
            added += 1

    if added or kept != filters:
        entry["skills"] = kept
        try:
            write_atomic(settings, doc)
        except OSError as exc:
            print(f"cannot write {settings}: {exc}", file=sys.stderr)
            return 1

    if collisions:
        print("filtered %d duplicate skill(s) from ~/.agents/skills: %s" %
              (len(collisions), ", ".join(name for name, _ in collisions)))
    else:
        print("no duplicate skills in ~/.agents/skills")
    return 0


if __name__ == "__main__":
    sys.exit(main())
