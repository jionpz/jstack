import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

DIFF = ("diff", "--no-renames", "--no-ext-diff", "--no-textconv", "-z")


def git(directory, *args, check=True):
    return subprocess.run(
        ["git", "--no-optional-locks", "-C", directory, *args],
        stdout=subprocess.PIPE,
        check=check,
    ).stdout


def paths(raw):
    return {os.fsdecode(name) for name in raw.split(b"\0") if name}


def worktree_paths(root, head):
    revision = (head,) if head else ()
    tracked = git(root, *DIFF, "--name-only", *revision, "--")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z", "--")
    return paths(tracked + untracked)


def staged_files(root):
    entries = git(root, *DIFF, "--cached", "--raw", "--no-abbrev", "--").split(b"\0")
    staged = {}
    for metadata, name in zip(entries[::2], entries[1::2]):
        _, mode, _, object_id, _ = metadata.decode().split()
        staged[os.fsdecode(name)] = [mode, object_id]
    return staged


def head_commit(root):
    return git(root, "rev-parse", "--verify", "--quiet", "HEAD", check=False).decode().strip()


def committed_paths(root, base, head):
    if base == head:
        return set()
    if not base or not head:
        return paths(git(root, "ls-tree", "-r", "--name-only", "-z", base or head))
    return paths(git(root, *DIFF, "--name-only", base, head, "--"))


def fingerprint(root, name):
    target = Path(root, name)
    if not target.parent.resolve().is_relative_to(Path(root)):
        return None
    try:
        mode = target.lstat().st_mode
    except (FileNotFoundError, NotADirectoryError):
        return None
    if stat.S_ISLNK(mode):
        return ["symlink", os.readlink(target)]
    if stat.S_ISDIR(mode) and (target / ".git").exists():
        return ["submodule", git(target, "rev-parse", "HEAD").decode().strip()]
    if not stat.S_ISREG(mode):
        return ["mode", stat.S_IFMT(mode)]
    digest = hashlib.sha256()
    with target.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return ["file", bool(mode & stat.S_IXUSR), digest.hexdigest()]


def capture(root):
    head = head_commit(root)
    staged = staged_files(root)
    files = {name: fingerprint(root, name) for name in worktree_paths(root, head) | staged.keys()}
    print(json.dumps({"root": root, "head": head, "files": files, "staged": staged}, sort_keys=True))


def module(name):
    parts = name.split("/")
    if len(parts) == 1 or parts[0] in {"docs", "test", "tests", "fixtures", "examples"}:
        return None
    if len(parts) > 2 and parts[0] in {"src", "lib", "packages", "apps", "services"}:
        return "/".join(parts[:2])
    return parts[0]


def boundary(name):
    parts = name.lower().split("/")
    return (
        parts[0] in {".jstack", ".github"}
        or parts[-1] in {"must-stop.md", "openapi.json", "openapi.yaml", "openapi.yml"}
        or bool(set(parts[:-1]) & {"api", "public", "schema", "schemas", "hooks", "permissions"})
    )


def recheck(root, state):
    with open(state, encoding="utf-8") as source:
        baseline = next(
            json.loads(line.removeprefix("scope-baseline "))
            for line in source
            if line.startswith("scope-baseline ")
        )
    if baseline["root"] != root:
        raise ValueError("当前 checkout 与执行前的范围基线不同")
    head = head_commit(root)
    staged = staged_files(root)
    old_staged = baseline["staged"]
    old_files = baseline["files"]
    candidates = worktree_paths(root, head) | staged.keys() | old_files.keys()
    files = {
        name for name in candidates
        if name not in old_files or old_files[name] != fingerprint(root, name)
    }
    files.update(name for name in staged.keys() | old_staged.keys() if staged.get(name) != old_staged.get(name))
    files.update(committed_paths(root, baseline["head"], head))
    modules = {group for group in map(module, files) if group is not None}
    if any(map(boundary, files)):
        print("改动触及接口、门禁或项目治理路径")
    elif len(modules) > 1:
        print(f"改动横跨 {len(modules)} 个目录模块")
    elif len(files) > 3:
        print(f"改动涉及 {len(files)} 个文件")


def main():
    action, directory, *args = sys.argv[1:]
    root = os.path.realpath(os.fsdecode(git(directory, "rev-parse", "--show-toplevel").removesuffix(b"\n")))
    if action == "capture":
        capture(root)
    else:
        recheck(root, args[0])


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, ValueError, StopIteration) as exc:
        sys.exit(f"jstack: 无法复核实际改动范围：{exc}")
