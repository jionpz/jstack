#!/usr/bin/env python3
"""Plan or apply a project-local Trellis cutover."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
from dataclasses import dataclass, field
import fcntl
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import uuid


ARCHIVE = Path(".jstack-retired-trellis")
PAYLOAD = Path(".trellis")
CONVENTIONS = Path("docs/agents/conventions")
ARCHIVE_IGNORE = b"*\n"
HARNESS = {
    ".agent", ".agents", ".claude", ".codebuddy", ".codex", ".cursor",
    ".devin", ".factory", ".gemini", ".github", ".grok", ".kilocode",
    ".kimi-code", ".kiro", ".omp", ".opencode", ".pi", ".qoder",
    ".reasonix", ".snow", ".trae", ".zcode",
}
SKILLS = {
    f"trellis-{name}" for name in (
        "before-dev", "brainstorm", "break-loop", "channel", "check", "continue",
        "finish-work", "meta", "session-insight", "spec-bootstrap", "start", "update-spec",
    )
}
AGENTS = {"trellis-check", "trellis-implement", "trellis-research"}
HOOK_SCRIPTS = {
    "session-start", "inject-subagent-context", "inject-workflow-state", "inject-shell-session-context",
}
PACKAGE_NAMES = {"@mindfoldhq/trellis", "@mindfoldhq/trellis-core"}
DEPENDENCY_KEYS = ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")
EXTENSIONS = {
    Path(f"{harness}/extensions/trellis") for harness in (".pi", ".omp")
}
ROOT_FILES = {
    Path(name) for name in (
        "AGENTS.md", "CLAUDE.md", "GEMINI.md", "Makefile", "opencode.json", "opencode.jsonc",
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock",
    )
}
TEXT_SUFFIXES = {
    ".cjs", ".js", ".json", ".jsonc", ".lock", ".md", ".mdc", ".mjs", ".py",
    ".sh", ".toml", ".ts", ".txt", ".yaml", ".yml",
}
SKIP_DIRS = {".git", ".cache", ".venv", "__pycache__", "node_modules", "worktrees"}
OPEN_STATUSES = {"planning", "in_progress", "review"}
REFERENCE = re.compile(
    r"\.trellis(?![\w-])|\btrellis[-_:]|@mindfoldhq/trellis\b"
    r"|\btrellis\s+(?:init|update|task|mem|channel)\b",
    re.IGNORECASE,
)
MARKER = re.compile(rb"(?m)^[ \t]*<!-- TRELLIS:(START|END) -->[ \t]*\r?$")
GENERATED_HOOK = re.compile(
    rb"Trellis (?:per-turn breadcrumb hook|Session Start (?:Hook|Plugin)|"
    rb"Subagent Context (?:Hook|Plugin)|Workflow State Plugin)"
    rb"|(?:Inject Trellis context into|Context Source: Trellis active task resolver)"
    rb"|Session Start Hook - Inject structured context"
    rb"|(?:import|from)[^\n]*trellis-context\.js",
    re.IGNORECASE,
)
CODEX_AGENT_HEADER = re.compile(r"[ \t]*\[agents\.(trellis-[a-z]+)\][ \t]*(?:#.*)?")
CODEX_AGENT_FIELD = re.compile(
    r'[ \t]*(config_file|description)[ \t]*=[ \t]*"([^"\\]*)"[ \t]*(?:#.*)?'
)
TOML_LINE_TOKEN = re.compile(
    r'''"""|\'\'\'|"(?:\\.|[^"\\])*"|'[^']*'|#.*|["'\[\]{}]'''
)


class RetireError(ValueError):
    pass


def json_value(content: bytes):
    def object_from_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise RetireError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    def invalid_constant(value):
        raise RetireError(f"invalid JSON constant {value}")

    return json.loads(
        content, object_pairs_hook=object_from_pairs, parse_constant=invalid_constant,
    )


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode()


class Repo:
    def __init__(self, root: Path, descriptor: int):
        self.root = root
        self.descriptor = descriptor

    @contextmanager
    def directory(self, path: Path, create=False):
        descriptor = os.dup(self.descriptor)
        try:
            for part in path.parts:
                if create:
                    try:
                        os.mkdir(part, 0o700, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                child = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor,
                )
                os.close(descriptor)
                descriptor = child
            yield descriptor
        finally:
            os.close(descriptor)

    def info(self, path: Path):
        try:
            with self.directory(path.parent) as parent:
                return os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return None

    def children(self, path: Path):
        with self.directory(path) as directory:
            return [path / name for name in sorted(os.listdir(directory))]

    def read(self, path: Path) -> bytes:
        with self.directory(path.parent) as parent:
            descriptor = os.open(
                path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent,
            )
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise RetireError(f"{path} must be a regular file")
                return stream.read()

    def link_target(self, path: Path) -> str:
        with self.directory(path.parent) as parent:
            return os.readlink(path.name, dir_fd=parent)

    def write(self, path: Path, data: bytes, mode: int, replace=False):
        with self.directory(ARCHIVE) as staging, self.directory(path.parent, create=True) as parent:
            temporary = f".write-{uuid.uuid4().hex}"
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=staging,
            )
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fchmod(stream.fileno(), mode)
                    os.fsync(stream.fileno())
                if replace:
                    os.replace(temporary, path.name, src_dir_fd=staging, dst_dir_fd=parent)
                else:
                    os.link(temporary, path.name, src_dir_fd=staging, dst_dir_fd=parent)
            finally:
                try:
                    os.unlink(temporary, dir_fd=staging)
                except FileNotFoundError:
                    pass

    def move(self, path: Path, destination: Path):
        with self.directory(path.parent) as source, self.directory(destination.parent, create=True) as target:
            rename, flag = exclusive_rename()
            if rename(source, os.fsencode(path.name), target, os.fsencode(destination.name), flag):
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), str(destination))


def exclusive_rename():
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin" and hasattr(library, "renameatx_np"):
        return library.renameatx_np, 0x4
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        return library.renameat2, 0x1
    raise RetireError("safe archive moves require exclusive rename support")


@dataclass(frozen=True)
class Edit:
    path: Path
    before: bytes
    after: bytes
    mode: int

    @property
    def backup(self):
        return ARCHIVE / "originals" / self.path


@dataclass
class Plan:
    moves: dict[Path, Path] = field(default_factory=dict)
    edits: list[Edit] = field(default_factory=list)
    tasks: list[dict] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    task_map: bytes | None = None
    conventions_source: Path | None = None


def mode_of(info) -> int:
    return info.st_mode if info else 0


def discover(repo: Repo, base: Path, files: dict, directories: set):
    for path in repo.children(base):
        info = repo.info(path)
        if stat.S_ISDIR(mode_of(info)):
            if path.name not in SKIP_DIRS:
                directories.add(path)
                discover(repo, path, files, directories)
        else:
            files[path] = info


def template_hashes(repo: Repo, plan: Plan) -> dict:
    path = PAYLOAD / ".template-hashes.json"
    if repo.info(path) is None:
        return {}
    try:
        data = json_value(repo.read(path))
        hashes = data.get("hashes") if isinstance(data, dict) else None
        if not isinstance(hashes, dict):
            raise RetireError("expected a hashes object")
        return hashes
    except (OSError, ValueError) as exc:
        plan.blockers.append(f"{path}: {exc}")
        return {}


def named_entry(path: Path) -> bool:
    if path in EXTENSIONS or path == Path(".opencode/lib/trellis-context.js"):
        return True
    if len(path.parts) != 3:
        return False
    section = path.parts[1]
    if section == "skills":
        return path.name in SKILLS
    if section in {"agents", "droids"}:
        return path.stem in AGENTS and path.suffix in {".md", ".toml"}
    if section in {"commands", "prompts", "workflows"}:
        return path.name == "trellis" or (
            path.stem in SKILLS and path.suffix in {".md", ".toml", ".json"}
        )
    return False


def hook_file(path: Path) -> bool:
    if len(path.parts) == 3 and path.parts[1] == "hooks":
        return path.stem in HOOK_SCRIPTS and path.suffix == ".py"
    return path.parts[0] == ".opencode" and (
        path.parent == Path(".opencode/plugins") and path.stem in HOOK_SCRIPTS and path.suffix == ".js"
        or path in {Path(".opencode/lib/trellis-context.js"), Path(".opencode/lib/session-utils.js")}
    )


def owned_entries(repo: Repo, files: dict, directories: set, hashes: dict) -> set:
    owned = {path for path in directories if named_entry(path)}
    for path, info in files.items():
        if path.parent.name not in {"skills", "extensions"} or stat.S_ISLNK(mode_of(info)):
            if named_entry(path):
                owned.add(path)
        if hook_file(path) and stat.S_ISREG(mode_of(info)):
            content = repo.read(path)
            if (
                hashlib.sha256(content).hexdigest() == hashes.get(str(path))
                or GENERATED_HOOK.search(content[:4096]) and b".trellis" in content
                or path.parts[0] == ".opencode" and GENERATED_HOOK.search(content[:4096])
            ):
                owned.add(path)
    return owned


def hook_target(command, repo: Repo, harness: str, owned: set):
    if not isinstance(command, str):
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if not tokens:
        return None
    if tokens[0] in {"python", "python3"}:
        tokens = tokens[1:]
        if tokens[:2] == ["-X", "utf8"]:
            tokens = tokens[2:]
    if len(tokens) != 1:
        return None
    target = tokens[0]
    for prefix in (f"{repo.root}/",) + tuple(
        f"{variable}/" for name in (
            "CLAUDE_PROJECT_DIR", "CODEX_PROJECT_DIR", "CURSOR_PROJECT_DIR",
        ) for variable in (f"${name}", f"${{{name}}}")
    ):
        if target.startswith(prefix):
            target = target[len(prefix):]
            break
    if target.startswith("./"):
        target = target[2:]
    path = Path(target)
    if target != str(path):
        return None
    if path in owned and path.parts[0] == harness and hook_file(path):
        return path
    if path.parent == PAYLOAD / "scripts" / "hooks" and path.stem in HOOK_SCRIPTS and path.suffix == ".py":
        return path
    return None


def remove_hooks(hooks, matches):
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue
        retained = []
        for entry in entries:
            if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
                remaining = [item for item in entry["hooks"] if not matches(item)]
                if remaining != entry["hooks"]:
                    if remaining or entry.keys() - {"matcher", "hooks"}:
                        retained.append({**entry, "hooks": remaining})
                    continue
            if not matches(entry):
                retained.append(entry)
        if retained != entries:
            if retained:
                hooks[event] = retained
            else:
                del hooks[event]


def edit_json(repo: Repo, path: Path, content: bytes, owned: set) -> tuple[bytes, str]:
    data = json_value(content)
    if not isinstance(data, dict):
        raise RetireError("expected a JSON object")
    before = json_bytes(data)
    if path.name == "package.json":
        for key in DEPENDENCY_KEYS:
            dependencies = data.get(key)
            if isinstance(dependencies, dict):
                for name in PACKAGE_NAMES:
                    dependencies.pop(name, None)
    if isinstance(data.get("hooks"), dict):
        harness = path.parts[0]

        def matches(item):
            return (
                isinstance(item, dict)
                and item.keys() <= {"type", "command", "timeout", "async", "statusMessage"}
                and item.get("type", "command") == "command"
                and hook_target(item.get("command"), repo, harness, owned) is not None
            )

        remove_hooks(data["hooks"], matches)
    if path in {Path(".pi/settings.json"), Path(".omp/settings.json")}:
        extension = "extensions/trellis/index.ts"
        if isinstance(data.get("extensions"), list):
            data["extensions"] = [
                item for item in data["extensions"]
                if item not in (extension, f"./{extension}")
            ]
        if isinstance(data.get("packages"), list):
            data["packages"] = [
                item for item in data["packages"]
                if not isinstance(item, str)
                or not re.fullmatch(r"npm:@mindfoldhq/trellis(?:-core)?(?:@[^/\s]+)?", item)
            ]
    after = json_bytes(data)
    return (content if before == after else after), json.dumps(data, ensure_ascii=False)


def edit_markers(content: bytes) -> bytes:
    matches = list(MARKER.finditer(content))
    if not matches:
        return content
    if [match[1] for match in matches] != [b"START", b"END"]:
        raise RetireError("invalid Trellis instruction markers")
    start, end = matches
    after = end.end() + (content[end.end():end.end() + 1] == b"\n")
    return content[:start.start()] + content[after:]


def edit_codex(content: bytes) -> bytes:
    """Remove only generated agent tables with unambiguous line boundaries."""
    text = content.decode()
    if not re.search(r"(?m)^[ \t]*\[agents\.trellis-", text):
        return content
    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]|\r(?!\n)", text):
        return content

    lines = list(StringIO(text))
    sections = []
    closing = []
    for index, line in enumerate(lines):
        line = line.rstrip("\r\n")
        if not closing and line.lstrip(" \t").startswith("["):
            sections.append(index)
        for match in TOML_LINE_TOKEN.finditer(line):
            token = match[0]
            if token in {'"""', "'''", '"', "'"}:
                return content
            if token in {"[", "{"}:
                closing.append("]" if token == "[" else "}")
            elif token in {"]", "}"} and (not closing or closing.pop() != token):
                return content
    if closing:
        return content

    seen = set()
    remove = set()
    for start, end in zip(sections, sections[1:] + [len(lines)]):
        header = CODEX_AGENT_HEADER.fullmatch(lines[start].rstrip("\r\n"))
        if not header or header[1] not in AGENTS:
            continue
        name = header[1]
        if name in seen:
            return content
        seen.add(name)
        fields = {}
        for index in range(start + 1, end):
            line = lines[index].rstrip("\r\n")
            if not line.strip(" \t") or line.lstrip(" \t").startswith("#"):
                continue
            field = CODEX_AGENT_FIELD.fullmatch(line)
            if not field or field[1] in fields:
                break
            fields[field[1]] = (index, field[2])
        else:
            if fields.get("config_file", (None, None))[1] in {
                f"agents/{name}.toml", f"./agents/{name}.toml",
            }:
                remove.add(start)
                remove.update(index for index, _ in fields.values())
    return "".join(line for index, line in enumerate(lines) if index not in remove).encode()


def editable_json(path: Path) -> bool:
    if path.name == "package.json":
        return path in {Path("package.json"), Path(".opencode/package.json")}
    return path.parts[0] in HARNESS and path.name in {
        "hooks.json", "settings.json", "settings.local.json", "config.json",
    } and (len(path.parts) == 2 or path.parent == Path(".github/copilot"))


def inspect_references(repo: Repo, files: dict, owned: set, plan: Plan):
    ambiguous_hooks = {
        Path(f"{harness}/hooks/{name}.py")
        for harness in {path.parts[0] for path in files if path.parts[0] in HARNESS}
        for name in HOOK_SCRIPTS
    } - files.keys() if PAYLOAD in plan.moves else set()
    paths = tuple(str(path) for path in sorted(owned | ambiguous_hooks))
    reference = re.compile(
        REFERENCE.pattern + (r"|" + "|".join(map(re.escape, paths)) if paths else ""),
        re.IGNORECASE,
    )
    for path, info in sorted(files.items()):
        if path in owned or any(parent in owned for parent in path.parents):
            continue
        if stat.S_ISLNK(mode_of(info)):
            target = repo.link_target(path)
            if reference.search(str(path)) or reference.search(target) or (
                (plan.moves or owned) and (editable_json(path) or path in ROOT_FILES)
            ):
                plan.blockers.append(f"{path}: review symbolic link")
            continue
        if path not in ROOT_FILES and path.suffix not in TEXT_SUFFIXES:
            continue
        if not stat.S_ISREG(mode_of(info)):
            plan.blockers.append(f"{path}: review non-regular file")
            continue
        try:
            before = after = repo.read(path)
            decoded = ""
            if path in {Path("AGENTS.md"), Path("CLAUDE.md")}:
                after = edit_markers(before)
            elif editable_json(path) and (
                reference.search(before.decode("utf-8", errors="replace"))
                or b"\\u" in before
                or path in {Path(".pi/settings.json"), Path(".omp/settings.json")}
            ):
                after, decoded = edit_json(repo, path, before, owned)
            elif path == Path(".codex/config.toml"):
                after = edit_codex(before)
            if before != after:
                plan.edits.append(Edit(path, before, after, stat.S_IMODE(info.st_mode)))
            lines = [
                str(number) for number, line in enumerate(
                    after.decode("utf-8", errors="replace").splitlines(), start=1,
                ) if reference.search(line)
            ]
            if lines or reference.search(decoded) or reference.search(str(path)):
                location = f" (lines {', '.join(lines[:8])})" if lines else ""
                plan.blockers.append(f"{path}{location}: review remaining Trellis reference")
        except (ImportError, OSError, ValueError) as exc:
            plan.blockers.append(f"{path}: {exc}")


def task_record(repo: Repo, path: Path, historical: bool) -> dict:
    task = {"path": str(path), "id": None, "status": None, "historical": historical}
    try:
        data = json_value(repo.read(path))
        if isinstance(data, dict):
            task["id"] = data.get("id") if isinstance(data.get("id"), str) else None
            task["status"] = data.get("status") if isinstance(data.get("status"), str) else None
    except (OSError, ValueError):
        pass
    return task


def inspect_tasks(repo: Repo, mapping: dict, plan: Plan):
    tasks_dir = PAYLOAD / "tasks"
    if repo.info(tasks_dir) is None:
        return
    for directory in repo.children(tasks_dir):
        if directory.name == "archive":
            if not stat.S_ISDIR(mode_of(repo.info(directory))):
                plan.blockers.append(f"{directory}: review unknown task archive format")
                continue
            historical = {}
            discover(repo, directory, historical, set())
            for path in historical:
                if path.name == "task.json":
                    plan.tasks.append(task_record(repo, path, historical=True))
        elif directory.name != ".DS_Store":
            path = directory / "task.json" if stat.S_ISDIR(mode_of(repo.info(directory))) else directory
            task = task_record(repo, path, historical=False) if path != directory else {
                "path": str(path), "id": None, "status": None, "historical": False,
            }
            plan.tasks.append(task)

    migrated = {}
    seen = set()
    for task in plan.tasks:
        task_id, status = task["id"], task["status"]
        if status in OPEN_STATUSES and task_id and task_id.strip() == task_id:
            if task_id in seen:
                plan.blockers.append(f"{task['path']}: duplicate open task ID {task_id}")
            seen.add(task_id)
            if task_id not in mapping:
                plan.blockers.append(f"{task['path']}: open task {task_id} requires --task-map")
            else:
                task["tracker"] = migrated[task_id] = mapping[task_id]
        elif status != "completed" and not task["historical"]:
            plan.blockers.append(f"{task['path']}: review unknown task ID or status")
    if migrated:
        plan.task_map = json_bytes(dict(sorted(migrated.items())))


def validate_archive(repo: Repo, plan: Plan):
    if plan.moves:
        exclusive_rename()
    archive_info = repo.info(ARCHIVE)
    if archive_info is not None:
        if not stat.S_ISDIR(archive_info.st_mode):
            raise RetireError(f"archive must be a directory: {ARCHIVE}")
        ignore = ARCHIVE / ".gitignore"
        if repo.info(ignore) is not None:
            if repo.read(ignore) != ARCHIVE_IGNORE:
                raise RetireError(f"archive marker conflicts: {ignore}")
        elif any(
            not re.fullmatch(r"\.write-[a-f0-9]{32}", path.name) for path in repo.children(ARCHIVE)
        ):
            raise RetireError(f"archive marker missing: {ignore}")

    root_device = os.fstat(repo.descriptor).st_dev
    targets = {path: None for path in plan.moves.values()}
    targets.update({edit.backup: edit.before for edit in plan.edits})
    if plan.task_map:
        targets[ARCHIVE / "task-map.json"] = plan.task_map
    for destination, expected in targets.items():
        for parent in reversed(destination.parents):
            if parent == Path("."):
                continue
            info = repo.info(parent)
            if info and (not stat.S_ISDIR(info.st_mode) or info.st_dev != root_device):
                raise RetireError(f"unsafe archive parent: {parent}")
        if repo.info(destination) is not None and (
            expected is None or repo.read(destination) != expected
        ):
            raise RetireError(f"archive destination conflicts: {destination}")
    for path in (*plan.moves, *(edit.path for edit in plan.edits)):
        with repo.directory(path.parent) as parent:
            if os.fstat(parent).st_dev == root_device and repo.info(path).st_dev == root_device:
                continue
        raise RetireError(f"path sits on a different filesystem: {path}")


def build_plan(repo: Repo, mapping: dict) -> Plan:
    plan = Plan()
    files = {path: repo.info(path) for path in ROOT_FILES if repo.info(path) is not None}
    directories = set()
    try:
        payload = repo.info(PAYLOAD)
        if payload:
            if not stat.S_ISDIR(payload.st_mode):
                raise RetireError(f"{PAYLOAD} must be a directory")
            plan.moves[PAYLOAD] = ARCHIVE / "project" / PAYLOAD
            if repo.info(PAYLOAD / "spec") is not None:
                plan.conventions_source = PAYLOAD / "spec"
            inspect_tasks(repo, mapping, plan)
        hashes = template_hashes(repo, plan) if payload else {}
        for harness in map(Path, sorted(HARNESS)):
            info = repo.info(harness)
            if info:
                if not stat.S_ISDIR(info.st_mode):
                    plan.blockers.append(f"{harness}: review non-directory harness path")
                    continue
                discover(repo, harness, files, directories)
        owned = owned_entries(repo, files, directories, hashes)
        for path in sorted(owned):
            plan.moves[path] = ARCHIVE / "project" / path
        for path in sorted(directories):
            if (
                REFERENCE.search(path.name)
                and path not in owned
                and not any(parent in owned for parent in path.parents)
            ):
                plan.blockers.append(f"{path}: review directory with a Trellis name")
        inspect_references(repo, files, owned, plan)
        validate_archive(repo, plan)
        if not payload and repo.info(ARCHIVE / "project" / PAYLOAD / "spec") is not None:
            plan.conventions_source = PAYLOAD / "spec"
    except (OSError, ValueError) as exc:
        plan.blockers.append(str(exc))
    return plan


def apply_plan(repo: Repo, plan: Plan):
    with repo.directory(ARCHIVE, create=True):
        pass
    ignore = ARCHIVE / ".gitignore"
    if repo.info(ignore) is None:
        repo.write(ignore, ARCHIVE_IGNORE, 0o600)
    mapping = ARCHIVE / "task-map.json"
    if plan.task_map and repo.info(mapping) is None:
        repo.write(mapping, plan.task_map, 0o600)
    for edit in plan.edits:
        if repo.read(edit.path) != edit.before:
            raise RetireError(f"file changed during cutover: {edit.path}")
        if repo.info(edit.backup) is None:
            repo.write(edit.backup, edit.before, 0o600)
        repo.write(edit.path, edit.after, edit.mode, replace=True)
    for path, destination in sorted(plan.moves.items(), key=lambda item: item[0] == PAYLOAD):
        repo.move(path, destination)


def report(root: Path, plan: Plan, status: str, as_json: bool):
    archived_spec = ARCHIVE / "project" / plan.conventions_source if plan.conventions_source else None
    archive_policy = (
        f"{ARCHIVE} is ignored by default. After review, stage selected archive files explicitly "
        f"with `git add -f -- {ARCHIVE}/<reviewed-file>`."
    )
    if as_json:
        print(json_bytes({
            "repo": str(root),
            "status": status,
            "archive": str(ARCHIVE),
            "archive_policy": archive_policy,
            "conventions": {
                "source": str(plan.conventions_source),
                "archived_source": str(archived_spec),
                "destination": str(CONVENTIONS),
                "action": (
                    "Review and copy selected regular files into the destination, merging any "
                    "existing files. Inspect symbolic links separately."
                ),
            } if archived_spec else None,
            "moves": [
                {"path": str(source), "destination": str(destination)}
                for source, destination in plan.moves.items()
            ],
            "edits": [{"path": str(edit.path), "backup": str(edit.backup)} for edit in plan.edits],
            "tasks": plan.tasks,
            "blockers": plan.blockers,
        }).decode(), end="")
        return
    print(f"Trellis cutover [{status}] {root}")
    if plan.moves or plan.edits or archived_spec:
        print(f"  {archive_policy}")
    if archived_spec:
        source = archived_spec if status == "no-op" or status == "applied" else plan.conventions_source
        print(
            f"  Review and copy selected regular files from {source} into {CONVENTIONS}. "
            "Merge with existing conventions and inspect symbolic links separately."
        )
        if source != archived_spec:
            print(f"  After apply, the archived source is {archived_spec}.")
    for source, destination in plan.moves.items():
        print(f"  Archive {source} -> {destination}")
    for edit in plan.edits:
        print(f"  Edit {edit.path} (backup {edit.backup})")
    for task in plan.tasks:
        tracker = f" -> {task['tracker']}" if "tracker" in task else ""
        print(f"  Task {task['id'] or task['path']} [{task['status'] or 'unknown'}]{tracker}")
    for blocker in plan.blockers:
        print(f"  Review {blocker}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path, metavar="PATH")
    parser.add_argument("--repo", type=Path, help="project Git root (default: current directory)")
    parser.add_argument("--apply", action="store_true", help="apply a cutover with no review blockers")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    parser.add_argument("--task-map", type=Path, metavar="FILE", help="JSON object mapping open task IDs to tracker references")
    args = parser.parse_args()
    if args.path is not None and args.repo is not None:
        parser.error("pass either PATH or --repo")
    root = args.repo or args.path or Path.cwd()
    status = "error"
    plan = Plan()
    try:
        root = root.absolute()
        if root.is_symlink():
            raise RetireError("repository root must not be a symbolic link")
        root = root.resolve(strict=True)
        root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fcntl.flock(root_descriptor, fcntl.LOCK_EX if args.apply else fcntl.LOCK_SH)
            repo = Repo(root, root_descriptor)
            git = mode_of(repo.info(Path(".git")))
            if not (stat.S_ISDIR(git) or stat.S_ISREG(git)):
                raise RetireError("pass the project Git root")
            mapping = json_value(args.task_map.read_bytes()) if args.task_map else {}
            if not isinstance(mapping, dict) or any(
                not key or not isinstance(value, str) or not value.strip() for key, value in mapping.items()
            ):
                raise RetireError("--task-map must be a JSON object with nonempty tracker references")
            plan = build_plan(repo, mapping)
            if plan.blockers:
                status = "blocked"
            elif not (plan.moves or plan.edits):
                status = "no-op"
            elif args.apply:
                apply_plan(repo, plan)
                status = "applied"
            else:
                status = "dry-run"
        finally:
            os.close(root_descriptor)
    except (OSError, ValueError) as exc:
        plan.blockers.append(str(exc))
    report(root, plan, status, args.json)
    return int(status == "error" or status == "blocked" and args.apply)


if __name__ == "__main__":
    sys.exit(main())
