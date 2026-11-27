from __future__ import annotations

import copy
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


HARNESSES = ("claude-code", "pi", "omp", "cursor", "codex")
LOCK = ".jstack/lock.json"
VENDOR = ".jstack/vendor"
PI_SETTINGS = ".pi/settings.json"
HOOKS = {".claude/settings.json", ".cursor/hooks.json", ".codex/hooks.json"}
CODEX_HOOKS = ".codex/hooks.json"
CURSOR_HOOKS = ".cursor/hooks.json"
FLOW = ".jstack/vendor/plugins/flow"
LEGACY_CODEX = re.compile(r'^"(?P<root>/[^"]+)/' + re.escape(FLOW) + r'"/hooks/(?P<script>prompt|guard|stop)\.sh$')
LEGACY_CLAUDE = re.compile(r'^"\$\{CLAUDE_PROJECT_DIR\}/' + re.escape(FLOW) + r'"/hooks/(?P<script>prompt|guard|stop)\.sh$')
ABSOLUTE_FLOW = re.compile(r'(?<![\w$}])/[^\n";]*?/\.jstack/vendor/plugins/flow')
PI_SOURCE = re.compile(r"npm:@tintinweb/pi-subagents@\d+\.\d+\.\d+(?:[-+][\w.+-]+)?")
SHA256 = re.compile(r"[0-9a-f]{64}")
HOOK_EVENTS = {
    "prompt": (("UserPromptSubmit", {}, "beforeSubmitPrompt"),),
    "guard": (
        ("PreToolUse", {"matcher": "Bash"}, "beforeShellExecution"),
        ("PreToolUse", {"matcher": "Write|Edit|MultiEdit|NotebookEdit"}, "preToolUse"),
    ),
    "stop": (("Stop", {}, "stop"),),
}
MISSING = object()


class ProjectError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value, *, canonical=False):
    if canonical:
        return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def mode(path):
    try:
        return path.lstat().st_mode
    except FileNotFoundError:
        return None


def checked_path(root, rel):
    parts = Path(rel).parts
    if not parts or Path(rel).is_absolute() or ".." in parts or Path(rel).as_posix() != rel:
        raise ProjectError(f"lock 路径无效：{rel}")
    parent = root
    for part in parts[:-1]:
        parent /= part
        kind = mode(parent)
        if kind is not None and not stat.S_ISDIR(kind):
            raise ProjectError(f"项目入口的父路径必须是普通目录：{parent}")
    return root / rel


def file_state(path):
    kind = mode(path)
    if kind is None:
        return None
    if stat.S_ISLNK(kind):
        return {"kind": "symlink", "target": os.readlink(path)}
    if stat.S_ISREG(kind):
        return {"kind": "file", "sha256": digest(path.read_bytes()), "executable": bool(kind & stat.S_IXUSR)}
    raise ProjectError(f"需要普通文件或入口链接：{path}")


def json_object(path, *, optional=False):
    kind = mode(path)
    if kind is None and optional:
        return {}
    if kind is None or not stat.S_ISREG(kind):
        raise ProjectError(f"需要普通 JSON 文件：{path}")

    def unique_pairs(pairs):
        fields = {}
        for key, value in pairs:
            if key in fields:
                raise ValueError(f"重复的键 {key!r}")
            fields[key] = value
        return fields

    try:
        value = json.loads(path.read_bytes(), object_pairs_hook=unique_pairs)
    except (UnicodeError, ValueError) as exc:
        raise ProjectError(f"JSON 无效：{path}（{exc}）") from exc
    if not isinstance(value, dict):
        raise ProjectError(f"需要 JSON 对象：{path}")
    return value


def record_paths(lock):
    return {path for harness in lock.get("harnesses", {}).values() for path in harness.get("records", [])}


def read_lock(repo, inventory):
    path = checked_path(repo, LOCK)
    lock = json_object(path, optional=True)
    if not lock and mode(path) is None:
        return lock
    harnesses = lock.get("harnesses", {})
    if type(lock.get("version")) is not int or lock["version"] not in (1, 2) or not isinstance(harnesses, dict):
        raise ProjectError(f"无法识别 {LOCK} 的版本或 harness 记录")
    for key in ("vendor", "plugins", "recommended"):
        if not isinstance(lock.get(key, {}), dict):
            raise ProjectError(f"{LOCK} 的 {key} 必须是对象")
    if not isinstance(lock.get("recommended", {}).get("pi", {}), dict):
        raise ProjectError(f"{LOCK} 的 recommended.pi 必须是对象")
    for name, harness in harnesses.items():
        if name not in HARNESSES or not isinstance(harness, dict) or not isinstance(harness.get("records"), list):
            raise ProjectError(f"无效的 harness 记录：{name}")
        for path in harness["records"]:
            if not isinstance(path, str):
                raise ProjectError(f"无效的 harness 路径：{path!r}")
            if lock["version"] == 2 and path not in inventory[name]:
                raise ProjectError(f"{name} 不能管理路径：{path}")
    if lock["version"] == 2:
        managed = lock.get("managed")
        if not isinstance(managed, dict) or set(managed) != record_paths(lock):
            raise ProjectError(f"{LOCK} 的入口记录与所有权证明不一致")
        for path, proof in managed.items():
            if path in HOOKS:
                expected = "hooks"
            elif path == PI_SETTINGS:
                expected = "package"
            else:
                expected = "symlink" if "/skills/" in path else "file"
            if not isinstance(proof, dict) or proof.get("kind") != expected:
                raise ProjectError(f"{path} 的所有权证明无效")
            validate_proof(path, proof)
    return lock


def vendor_snapshot(root):
    current = mode(root)
    if current is None:
        return None, {}, None
    if not stat.S_ISDIR(current):
        raise ProjectError(f"vendor 必须是普通目录：{root}")
    files = {}
    directories = []
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in list(dirs):
            path = Path(directory) / name
            if path.is_symlink():
                dirs.remove(name)
                names.append(name)
            else:
                directories.append(path.relative_to(root).as_posix())
        for name in names:
            path = Path(directory) / name
            files[path.relative_to(root).as_posix()] = file_state(path)
    legacy = bytearray()
    for path in sorted(files, key=os.fsencode):
        proof = files[path]
        if proof["kind"] == "file" and Path(path).name != ".DS_Store" and "node_modules" not in Path(path).parts[:-1]:
            filename = os.fsencode(path)
            escaped = b"\\" if b"\\" in filename or b"\n" in filename else b""
            filename = filename.replace(b"\\", b"\\\\").replace(b"\n", b"\\n")
            legacy.extend(escaped + proof["sha256"].encode() + b"  ./" + filename + b"\n")
    return fingerprint([sorted(directories), files]), files, digest(legacy)


def fingerprint(value):
    return digest(encoded(value, canonical=True))


def git_ignored(repo, paths):
    git = ["git", "-C", str(repo)]
    probe = subprocess.run([*git, "rev-parse", "--is-inside-work-tree"], capture_output=True)
    if probe.returncode or probe.stdout.strip() != b"true":
        return
    result = subprocess.run(
        [*git, "check-ignore", "--stdin", "-z"],
        input=b"".join(os.fsencode(path) + b"\0" for path in sorted(paths)), capture_output=True,
    )
    if result.returncode not in (0, 1):
        raise ProjectError("git check-ignore 失败：" + os.fsdecode(result.stderr).strip())
    ignored = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
    if not ignored:
        return
    prefix = subprocess.check_output([*git, "rev-parse", "--show-prefix"], text=True).strip()
    rules = set()
    for path in ignored:
        path = prefix + (".jstack/" if path.startswith(".jstack/") else path)
        parts = path.rstrip("/").split("/")
        rules.update("/".join(parts[:index]) + "/" for index in range(1, len(parts)))
        rules.add(path)
        if path.endswith("/"):
            rules.add(path + "**")
    print(f"! 项目级安装有 {len(ignored)} 个路径被 Git 忽略，同事 clone 后会缺文件：", file=sys.stderr)
    for path in ignored:
        print("  " + path, file=sys.stderr)
    print("  请在 Git 根目录的 .gitignore 末尾加入所需白名单：", file=sys.stderr)
    for rule in sorted(rules):
        pattern = re.sub(r"([\\\[\]?*])", r"\\\1", rule.removesuffix("**") if rule.endswith("/**") else rule)
        print("  !/" + pattern + ("**" if rule.endswith("/**") else ""), file=sys.stderr)
    raise ProjectError("安装文件被 Git 忽略")


def hook_entries(doc, *, cursor):
    hooks = doc.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ProjectError("hooks 必须是 JSON 对象")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ProjectError(f"hooks.{event} 必须是数组")
        for group in groups:
            if not isinstance(group, dict):
                raise ProjectError(f"hooks.{event} 每项必须是对象")
            if cursor:
                yield event, {}, group, groups, group, None
                continue
            handlers = group.get("hooks", [])
            if not isinstance(handlers, list):
                raise ProjectError(f"hooks.{event} 的匹配组 hooks 必须是数组")
            context = {key: value for key, value in group.items() if key != "hooks"}
            for handler in handlers:
                yield event, context, handler, groups, group, handlers


def generated_handlers(doc, path):
    cursor = path == ".cursor/hooks.json"
    fragments = [[event, context, handler] for event, context, handler, *_ in hook_entries(doc, cursor=cursor)]
    if not fragments:
        raise ProjectError(f"没有生成任何门禁：{path}")
    return fragments


def check_hook_targets(repo):
    for script in HOOK_EVENTS:
        rel = f"{FLOW}/hooks/{script}.sh"
        kind = mode(checked_path(repo, rel))
        if kind is None or not stat.S_ISREG(kind) or not kind & stat.S_IXUSR:
            raise ProjectError(f"项目门禁需要可执行的 vendor 脚本：{rel}")


def hook_targets(path, script):
    targets = HOOK_EVENTS[script]
    if path == CODEX_HOOKS and script == "guard":
        return (
            ("PreToolUse", {"matcher": "Bash"}, "beforeShellExecution"),
            ("PreToolUse", {"matcher": "apply_patch"}, "preToolUse"),
        )
    return targets


def owned_hook_forms(path):
    for script, targets in HOOK_EVENTS.items():
        cursor_command = f'"${{CURSOR_PROJECT_DIR}}/{FLOW}"/hooks/{script}.sh'
        for event, context, cursor_event in hook_targets(path, script):
            if path == CURSOR_HOOKS:
                handler = {"command": cursor_command, "timeout": 10}
                if script == "stop":
                    handler["loop_limit"] = 3
                yield [[cursor_event, {}, handler]]
                continue
            if path == CODEX_HOOKS:
                commands = [f'repo=$(git rev-parse --show-toplevel) && exec "$repo/{FLOW}/hooks/{script}.sh"']
            else:
                suffix = f'exec "${{CLAUDE_PROJECT_DIR}}/{FLOW}/hooks/{script}.sh"'
                timeout = "10 and .loop_limit == 3" if script == "stop" else "10"
                escaped_cursor = cursor_command.replace('"', r'\"')
                cursor_check = (
                    f"'(.hooks.{cursor_event} // []) | any(.command == $command and .timeout == {timeout})' "
                    '"${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}/.cursor/hooks.json" >/dev/null 2>&1; '
                    "then exit 0; fi; " + suffix
                )
                cursor_prefix = 'if [ -n "${CURSOR_VERSION:-}" ] && command -v jq >/dev/null 2>&1 && jq -e --arg command '
                commands = [
                    f'"${{CLAUDE_PROJECT_DIR}}/{FLOW}"/hooks/{script}.sh',
                    f"JSTACK_CURSOR_HOOK_SOURCE=claude-project {suffix}",
                    'if [ -n "${CURSOR_VERSION:-}" ]; then exit 0; fi; ' + suffix,
                    f'{cursor_prefix}"{escaped_cursor}" {cursor_check}',
                    f"{cursor_prefix}'{cursor_command}' {cursor_check}",
                ]
            yield [[event, context, {"type": "command", "command": command, "timeout": 10}] for command in commands]


def validate_proof(path, proof):
    kind = proof["kind"]
    if kind == "symlink":
        target = proof.get("target")
        expected = r"\.\./\.\./\.jstack/vendor/plugins/(pstack|spec|flow)/skills/(?:engineering/|productivity/)?"
        if not isinstance(target, str) or not re.fullmatch(expected + re.escape(Path(path).name), target):
            raise ProjectError(f"{path} 的入口链接目标不属于项目 vendor")
        return
    if not isinstance(proof.get("sha256"), str) or not SHA256.fullmatch(proof["sha256"]):
        raise ProjectError(f"{path} 的指纹无效")
    if kind == "file":
        if not isinstance(proof.get("executable"), bool):
            raise ProjectError(f"{path} 的文件权限证明无效")
        return
    fragments = proof.get("fragments")
    if not isinstance(fragments, list) or fingerprint(fragments) != proof["sha256"]:
        raise ProjectError(f"{path} 的配置片段指纹无效")
    for key in ("created_file", "created_hooks", "created_version", "created_packages"):
        if key in proof and not isinstance(proof[key], bool):
            raise ProjectError(f"{path} 的配置所有权字段无效：{key}")
    if kind == "package":
        if len(fragments) != 1 or not isinstance(fragments[0], str) or not PI_SOURCE.fullmatch(fragments[0]):
            raise ProjectError(f"{path} 的 Pi 推荐包证明无效")
        return
    forms = list(owned_hook_forms(path))
    if len(fragments) != len(forms) or any(sum(fragment in options for fragment in fragments) != 1 for options in forms):
        raise ProjectError(f"{path} 的门禁证明必须指向项目内 jstack 脚本")
    events = proof.get("created_events")
    allowed_events = {options[0][0] for options in forms}
    if not isinstance(events, list) or any(not isinstance(event, str) or event not in allowed_events for event in events):
        raise ProjectError(f"{path} 的门禁事件证明无效")
    if path == CURSOR_HOOKS and proof.get("version") != 1:
        raise ProjectError(f"{path} 的配置版本证明无效")


def remove_hooks(doc, path, fragments, *, missing=False):
    cursor = path == ".cursor/hooks.json"
    for fragment in fragments:
        matches = [entry for entry in hook_entries(doc, cursor=cursor) if list(entry[:3]) == fragment]
        if not matches and missing:
            continue
        if len(matches) != 1:
            raise ProjectError(f"{path} 的项目门禁已改动或重复：{fragment[0]}")
        _, _, handler, groups, group, handlers = matches[0]
        if cursor:
            groups.remove(group)
        else:
            handlers.remove(handler)
            if not handlers:
                groups.remove(group)


def shared_config_proof(kind, fragments, **history):
    return {"kind": kind, "sha256": fingerprint(fragments), "fragments": fragments, **history}


def command_for(handler):
    return handler.get("command", "") if isinstance(handler, dict) and isinstance(handler.get("command"), str) else ""


def legacy_hooks(doc, path, expected):
    matches = []
    for event, context, handler, *_ in hook_entries(doc, cursor=path == ".cursor/hooks.json"):
        fragment = [event, context, handler]
        if fragment in expected:
            matches.append(fragment)
            continue
        command = command_for(handler)
        matcher = {CODEX_HOOKS: LEGACY_CODEX, ".claude/settings.json": LEGACY_CLAUDE}.get(path)
        match = matcher.fullmatch(command) if matcher else None
        if match:
            script = match["script"]
            legacy_targets = [
                (target_event, target_context)
                for target_event, target_context, _ in hook_targets(path, script)
            ]
            if (event, context) in legacy_targets and handler == {
                "type": "command", "command": command, "timeout": 10,
            }:
                matches.append(fragment)
    return matches


def check_codex_commands(repo, doc):
    for _, _, handler, *_ in hook_entries(doc, cursor=False):
        command = command_for(handler)
        match = LEGACY_CODEX.fullmatch(command)
        if match:
            root = Path(match["root"])
            if root != repo or not (repo / FLOW / "hooks" / (match["script"] + ".sh")).is_file():
                raise ProjectError(f"{CODEX_HOOKS} 的旧门禁指向其他 clone 或已损坏：{command}")


def install_hooks(repo, stage, path, prior, legacy):
    source = checked_path(repo, path)
    current = json_object(source, optional=True)
    original = copy.deepcopy(current)
    generated = json_object(stage / path)
    expected = generated_handlers(generated, path)
    if path == CODEX_HOOKS and any(
        LEGACY_CODEX.fullmatch(command_for(handler)) or ABSOLUTE_FLOW.search(command_for(handler))
        for _, _, handler in expected
    ):
        raise ProjectError(f"生成的 {path} 包含暂存机上的绝对路径")
    cursor = path == ".cursor/hooks.json"
    if prior:
        if mode(source) is not None:
            verify_shared(current, path, prior)
            remove_hooks(current, path, prior["fragments"])
    elif legacy:
        remove_hooks(current, path, legacy_hooks(current, path, expected))
    hooks = current.setdefault("hooks", {})
    hook_entries_list = [list(entry[:3]) for entry in hook_entries(current, cursor=cursor)]
    for fragment in expected:
        if fragment in hook_entries_list:
            raise ProjectError(f"{path} 已有相同门禁，无法证明由 jstack 生成：{fragment[0]}")
    created_events = {event for event in generated["hooks"] if event not in hooks}
    for event, groups in generated["hooks"].items():
        hooks.setdefault(event, []).extend(groups)
    created_version = False
    if cursor:
        version = generated["version"]
        if "version" in current and current["version"] != version:
            raise ProjectError(f"{path} 已有不兼容的 version：{current['version']}")
        created_version = "version" not in current or bool(prior and prior.get("created_version"))
        current["version"] = version
    proof = shared_config_proof(
        "hooks", expected, created_file=mode(source) is None or bool(prior and prior.get("created_file")),
        created_hooks="hooks" not in original or bool(prior and prior.get("created_hooks")),
        created_events=sorted(created_events | set((prior or {}).get("created_events", []))),
    )
    if cursor:
        proof.update(version=version, created_version=created_version)
    validate_proof(path, proof)
    if path == CODEX_HOOKS:
        check_codex_commands(repo, current)
    return proof, None if current == original else encoded(current)


def pi_recommended(repo, *, declare=False):
    action = "--stage-project-declaration" if declare else "--project-declaration"
    script = Path(__file__).with_name("pi-recommended.py")
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(script), "--scope", "project", "--repo", str(repo), action, "--json"],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise ProjectError(result.stderr.strip() or "无法读取 Pi 推荐包声明")
    return json.loads(result.stdout)


def install_pi(repo, stage, recommendation, prior):
    source = checked_path(repo, PI_SETTINGS)
    current = json_object(source, optional=True)
    owned = prior
    if prior and mode(source) is not None:
        verify_shared(current, PI_SETTINGS, prior)
    if recommendation == "no-pi-recommended" and prior:
        if mode(source) is None:
            return {}, None, MISSING
        data = remove_shared(repo, PI_SETTINGS, prior)
        if data is None:
            return {}, None, None
        copied = stage / PI_SETTINGS
        copied.parent.mkdir(exist_ok=True)
        copied.write_bytes(data)
        return pi_recommended(stage), None, data
    if recommendation == "with-pi-recommended" or (prior and mode(source) is None):
        copied = stage / PI_SETTINGS
        copied.parent.mkdir(exist_ok=True)
        if mode(source) is not None:
            shutil.copy2(source, copied)
        observed = pi_recommended(stage, declare=True)
        if observed["declaration_created"]:
            owned = shared_config_proof(
                "package", [observed["source"]],
                created_file=mode(source) is None, created_packages="packages" not in current,
            )
            return observed, owned, copied.read_bytes()
    if mode(source) is None:
        owned = None
    return pi_recommended(repo) if mode(source) is not None else {}, owned, MISSING


def verify_shared(doc, path, proof):
    if proof["kind"] == "hooks":
        remove_hooks(copy.deepcopy(doc), path, proof["fragments"])
        if "version" in proof and doc.get("version") != proof["version"]:
            raise ProjectError(f"{path} 的 version 已改动")
    else:
        packages = doc.get("packages", [])
        if not isinstance(packages, list) or packages.count(proof["fragments"][0]) != 1:
            raise ProjectError(f"{path} 的 Pi 推荐包声明已改动或重复")


def verify_record(repo, path, proof):
    target = checked_path(repo, path)
    if proof["kind"] in {"hooks", "package"}:
        verify_shared(json_object(target), path, proof)
    elif file_state(target) != proof:
        raise ProjectError(f"安装入口已改动或不存在：{path}")
    elif proof["kind"] == "symlink" and not (target / "SKILL.md").is_file():
        raise ProjectError(f"安装入口链接已损坏：{path}")


def remove_shared(repo, path, proof):
    doc = json_object(checked_path(repo, path))
    verify_shared(doc, path, proof)
    if proof["kind"] == "hooks":
        remove_hooks(doc, path, proof["fragments"])
        hooks = doc["hooks"]
        for event in proof.get("created_events", []):
            if hooks.get(event) == []:
                del hooks[event]
        if not hooks and proof.get("created_hooks"):
            del doc["hooks"]
        if not hooks and proof.get("created_version"):
            del doc["version"]
    else:
        doc["packages"].remove(proof["fragments"][0])
        if not doc["packages"] and proof.get("created_packages"):
            del doc["packages"]
    if not doc and proof.get("created_file"):
        return None
    return encoded(doc)


def copy_payload(source, destination):
    if isinstance(source, bytes):
        destination.write_bytes(source)
    elif source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)


def apply_changes(repo, changes, dry):
    if dry:
        for rel, source in changes.items():
            print(f"  {'移除' if source is None else '写入'} {rel}")
        print("（--dry-run，项目目录未改动）")
        return
    prepared = []
    created = []
    applied = []
    recovery = set()
    try:
        for rel, source in changes.items():
            target = checked_path(repo, rel)
            missing = [parent for parent in target.parents if parent != repo and mode(parent) is None]
            for parent in reversed(missing):
                parent.mkdir()
                created.append(parent)
            temp = Path(tempfile.mkdtemp(prefix=".jstack-install-", dir=target.parent))
            prepared.append((rel, temp))
            if source is not None:
                copy_payload(source, temp / "new")
                if isinstance(source, bytes) and mode(target) is not None:
                    (temp / "new").chmod(stat.S_IMODE(mode(target)))
        for rel, temp in prepared:
            target = checked_path(repo, rel)
            existed = mode(target) is not None
            applied.append((target, temp, existed))
            if existed:
                os.replace(target, temp / "old")
            if mode(temp / "new") is not None:
                os.replace(temp / "new", target)
    except (OSError, ProjectError, KeyboardInterrupt):
        for target, temp, existed in reversed(applied):
            try:
                if existed and mode(temp / "old") is None:
                    continue
                if mode(target) is not None:
                    os.replace(target, temp / "new")
                if existed:
                    os.replace(temp / "old", target)
            except OSError:
                recovery.add(temp)
                print(f"! 无法恢复 {target}，备份留在 {temp}", file=sys.stderr)
        raise
    finally:
        for _, temp in prepared:
            if temp not in recovery:
                shutil.rmtree(temp)
        for parent in reversed(created):
            if not any(parent.iterdir()):
                parent.rmdir()


def selection(csv):
    names = set(csv.split(","))
    unknown = names - set(HARNESSES)
    if unknown:
        raise ProjectError(f"未知 harness：{', '.join(sorted(unknown)) or '（空）'}")
    return names


def install(repo, stage, dry, recommendation, locked, inventory):
    old = read_lock(repo, inventory)
    desired = json_object(stage / LOCK)
    previous = set(old.get("harnesses", {}))
    requested = set(desired["harnesses"])
    if not previous <= requested or (locked and previous != requested):
        raise ProjectError("预检期间 harness 记录有变化，请重试")
    old_records = record_paths(old) if old.get("version") == 1 else set()
    old_proofs = old.get("managed", {})
    proposed = record_paths(desired)
    if HOOKS & proposed:
        check_hook_targets(stage)
    managed = {}
    changes = {}
    old_vendor, _, old_tree = vendor_snapshot(checked_path(repo, VENDOR))
    new_vendor, new_files, new_tree = vendor_snapshot(stage / VENDOR)
    if new_tree != desired["vendor"]["tree"]:
        raise ProjectError("暂存 vendor 树哈希与生成的 lock 不一致")
    if old_vendor is not None:
        field, actual = ("integrity", old_vendor) if old.get("version") == 2 else ("tree", old_tree)
        if old.get("vendor", {}).get(field) != actual:
            raise ProjectError("vendor 内容已改动或来源不明，保留现有 vendor")
    if old_vendor != new_vendor:
        changes[VENDOR] = stage / VENDOR
    for path in sorted(proposed):
        target = checked_path(repo, path)
        prior = old_proofs.get(path)
        if path in HOOKS:
            proof, data = install_hooks(repo, stage, path, prior, path in old_records)
            if data is not None:
                changes[path] = data
        else:
            staged = stage / path
            proof = file_state(staged)
            if proof is None:
                raise ProjectError(f"暂存投影缺少入口：{path}")
            if proof["kind"] == "symlink" and not (staged / "SKILL.md").is_file():
                raise ProjectError(f"暂存 skill 链接已损坏：{path}")
            if mode(target) is not None:
                try:
                    current = file_state(target)
                except ProjectError:
                    current = MISSING
                if current != prior and (path not in old_records or current != proof):
                    if path.startswith(".agents/") and path != ".agents/skills/route" and not prior:
                        print(f"! 保留项目已有入口：{path}", file=sys.stderr)
                        continue
                    raise ProjectError(f"项目入口冲突或已改动，保留原文件：{path}")
                if current != proof:
                    changes[path] = staged
            else:
                changes[path] = staged
        managed[path] = proof
    if "cursor" in desired["harnesses"] and "cursor" in old.get("harnesses", {}):
        cursor_dir = checked_path(repo, ".cursor/skills/sentinel").parent
        if cursor_dir.is_dir():
            for target in cursor_dir.iterdir():
                shared = managed.get(f".agents/skills/{target.name}", {})
                if shared.get("kind") == "symlink" and target.is_symlink() and os.readlink(target) == shared["target"]:
                    changes[f".cursor/skills/{target.name}"] = None
            if any(f".cursor/skills/{target.name}" not in changes for target in cursor_dir.iterdir()):
                print("! .cursor/skills 里还有非 jstack 的入口", file=sys.stderr)
    desired["recommended"] = {}
    if recommendation == "with-pi-recommended" and "pi" not in desired["harnesses"]:
        raise ProjectError("--with-pi-recommended 需要安装 Pi 项目投影")
    if "pi" in desired["harnesses"]:
        observed, proof, data = install_pi(repo, stage, recommendation, old_proofs.get(PI_SETTINGS))
        if observed.get("source"):
            desired["recommended"]["pi"] = {
                "source": observed["source"], "version": observed["version"], "scope": "project", "config": PI_SETTINGS,
            }
        if proof:
            desired["harnesses"]["pi"]["records"].append(PI_SETTINGS)
            managed[PI_SETTINGS] = proof
        if data is not MISSING:
            changes[PI_SETTINGS] = data
    removed = set(old_proofs) - set(managed)
    if recommendation == "no-pi-recommended":
        removed.discard(PI_SETTINGS)
    if removed:
        raise ProjectError("更新会丢失已记录的入口，先退役对应 harness")
    for harness in desired["harnesses"].values():
        harness["records"] = [path for path in harness["records"] if path in managed]
    desired["vendor"]["integrity"] = new_vendor
    desired["managed"] = managed
    check_paths = {LOCK, *managed, *(f"{VENDOR}/{path}" for path in new_files)}
    if desired["recommended"]:
        check_paths.add(PI_SETTINGS)
    git_ignored(repo, check_paths)
    lock_data = encoded(desired)
    if not old or (repo / LOCK).read_bytes() != lock_data:
        changes[LOCK] = lock_data
    apply_changes(repo, changes, dry)


def uninstall(repo, dry, csv, inventory):
    old = read_lock(repo, inventory)
    if not old:
        print("没有项目级安装记录。")
        return
    if old["version"] != 2:
        raise ProjectError("旧 lock 未记录入口所有权；请先重新运行项目级 install")
    installed = set(old["harnesses"])
    retiring = selection(csv) if csv else installed
    if retiring - installed:
        raise ProjectError("未安装的 harness：" + ", ".join(sorted(retiring - installed)))
    changes = {}
    remaining = copy.deepcopy(old)
    for name in retiring:
        del remaining["harnesses"][name]
    keep = record_paths(remaining)
    for path, proof in sorted(old["managed"].items()):
        verify_record(repo, path, proof)
        if path in keep:
            continue
        changes[path] = remove_shared(repo, path, proof) if proof["kind"] in {"hooks", "package"} else None
        del remaining["managed"][path]
    if "pi" in retiring:
        remaining.get("recommended", {}).pop("pi", None)
    if remaining["harnesses"]:
        changes[LOCK] = encoded(remaining)
    else:
        integrity, _, _ = vendor_snapshot(checked_path(repo, VENDOR))
        if integrity is not None and integrity == old["vendor"].get("integrity"):
            changes[VENDOR] = None
        elif integrity is not None:
            print("! vendor 内容已改动，保留现有 vendor。", file=sys.stderr)
        changes[LOCK] = None
    apply_changes(repo, changes, dry)
    if not dry:
        print("✓ 已退役项目投影：" + ", ".join(name for name in HARNESSES if name in retiring))


def check_source_commit(lock, source):
    jstack = lock.get("jstack", {})
    if not isinstance(jstack, dict):
        raise ProjectError("lock 的 jstack 来源记录无效")
    if "commit" not in jstack:
        return
    commit = jstack["commit"]
    if not isinstance(commit, str) or not re.fullmatch(r"[a-fA-F0-9]{7,64}", commit):
        raise ProjectError("lock 的 jstack.commit 必须是 Git 提交 SHA")
    git = ["git", "-C", str(source)]
    env = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
    root = subprocess.run([*git, "rev-parse", "--show-toplevel"], capture_output=True, env=env)
    if root.returncode != 0 or Path(os.fsdecode(root.stdout.rstrip(b"\n"))) != source:
        raise ProjectError(f"无法验证 jstack.commit {commit}：当前 JStack 安装源没有 Git 历史")
    resolved = subprocess.run([*git, "rev-parse", f"--disambiguate={commit}"], capture_output=True, env=env)
    objects = resolved.stdout.decode("ascii").splitlines()
    if resolved.returncode or len(objects) != 1:
        raise ProjectError(f"无法验证 jstack.commit {commit}：当前 JStack 安装源的 Git 历史里找不到该提交")
    result = subprocess.run([*git, "cat-file", "-t", objects[0]], capture_output=True, env=env)
    if result.returncode or result.stdout.strip() != b"commit":
        raise ProjectError(f"无法验证 jstack.commit {commit}：Git 对象不是提交")


def doctor(repo, source, inventory):
    lock = read_lock(repo, inventory)
    if not lock:
        return
    version = lock["version"]
    integrity, files, tree = vendor_snapshot(checked_path(repo, VENDOR))
    if tree is None or tree != lock.get("vendor", {}).get("tree"):
        raise ProjectError("vendor 树哈希与 lock 不一致")
    if version == 2 and integrity != lock["vendor"].get("integrity"):
        raise ProjectError("vendor 完整性指纹与 lock 不一致")
    if version == 2 and HOOKS & set(lock["managed"]):
        check_hook_targets(repo)
    problems = []
    for path in sorted(record_paths(lock)):
        try:
            if version == 2:
                verify_record(repo, path, lock["managed"][path])
            elif path != PI_SETTINGS and not checked_path(repo, path).exists():
                raise ProjectError(f"lock 记录的安装入口不存在：{path}")
        except ProjectError as exc:
            problems.append(str(exc))
    if "codex" in lock.get("harnesses", {}):
        try:
            check_codex_commands(repo, json_object(checked_path(repo, CODEX_HOOKS), optional=True))
        except ProjectError as exc:
            problems.append(str(exc))
    recommended = lock.get("recommended", {}).get("pi", {})
    if recommended.get("source"):
        try:
            json_object(checked_path(repo, PI_SETTINGS))
            observed = pi_recommended(repo)
            if not observed.get("source") or (version == 2 and observed["source"] != recommended["source"]):
                raise ProjectError(f"{PI_SETTINGS} 的 Pi 推荐包来源与 lock 不一致")
        except ProjectError as exc:
            problems.append(str(exc))
    check_paths = {LOCK, *(record_paths(lock) - {PI_SETTINGS}), *(f"{VENDOR}/{path}" for path in files)}
    if recommended.get("source") or PI_SETTINGS in lock.get("managed", {}):
        check_paths.add(PI_SETTINGS)
    git_ignored(repo, check_paths)
    try:
        check_source_commit(lock, source)
    except ProjectError as exc:
        problems.append(str(exc))
    if problems:
        raise ProjectError("\n! ".join(problems))


def main():
    raw_inventory, action, raw_repo, *args = sys.argv[1:]
    inventory = {name: set() for name in HARNESSES}
    for record in raw_inventory.splitlines():
        name, path = record.split("\t", 1)
        inventory[name].add(path)
    candidate = Path(raw_repo)
    if candidate.is_symlink():
        raise ProjectError(f"项目目录不能是符号链接：{candidate}")
    repo = candidate.resolve(strict=True)
    if not repo.is_dir():
        raise ProjectError(f"--repo 不是目录：{repo}")
    if action == "doctor":
        doctor(repo, Path(args[0]), inventory)
        return
    git_root = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if git_root.returncode == 0 and Path(git_root.stdout.rstrip("\n")).resolve() != repo:
        raise ProjectError(f"--repo 必须指向 Git 工作树根目录：{git_root.stdout.rstrip()}")
    if action == "select":
        names = set(read_lock(repo, inventory).get("harnesses", {}))
        if args[1] == "1":
            if not names:
                raise ProjectError("没有可刷新的项目安装，请先运行 jstack install --scope project")
        else:
            names |= selection(args[0])
        print(" ".join(name for name in HARNESSES if name in names))
        return
    fd = os.open(repo, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if action == "install":
            stage, dry, recommendation, locked = args
            install(repo, Path(stage), dry == "1", recommendation, locked == "1", inventory)
        elif action == "uninstall":
            dry, csv = args
            uninstall(repo, dry == "1", csv, inventory)
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except (ProjectError, OSError, KeyError, TypeError, ValueError) as exc:
        print(f"jstack: {exc}", file=sys.stderr)
        sys.exit(1)
