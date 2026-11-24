#!/usr/bin/env python3
"""Find and take over an unfinished flow run without trusting stale gate evidence."""

import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


def git(directory, *args):
    result = subprocess.run(
        ["git", "-C", str(directory), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def worktree(directory):
    root = git(directory, "rev-parse", "--show-toplevel")
    return Path(root).resolve() if root else None


def remote_id(directory):
    value = git(directory, "config", "--get", "remote.origin.url")
    if "://" in value:
        try:
            parsed = urlsplit(value)
            host, path = parsed.hostname, parsed.path.lstrip("/")
        except ValueError:
            return None
    else:
        match = re.fullmatch(r"(?:[^@/]+@)?([A-Za-z\d.-]+):([^?#]+)", value)
        host, path = match.groups() if match else (None, "")
    if not host or not re.fullmatch(r"[A-Za-z\d_.-]+(?:/[A-Za-z\d_.-]+)+", path):
        return None
    return f"{host.lower()}/{path.removesuffix('.git')}"


def same_repository(value, directory):
    if not isinstance(value, str) or not value or value == "-":
        return False
    candidate = Path(value).expanduser()
    root = worktree(directory)
    if candidate.is_absolute() and root and candidate.resolve() == root:
        return True
    current = remote_id(directory)
    return bool(current and current.casefold() == value.casefold())


def active_path(state_dir, session):
    return state_dir.parent / "runs/active" / f"{session}.json"


def active_rows(state_dir):
    directory = state_dir.parent / "runs/active"
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else ():
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(row, dict) and row.get("status") == "unfinished":
            yield row


def find(state_dir, repo, ticket):
    rows = []
    for row in active_rows(state_dir):
        tickets = row.get("tickets") if isinstance(row.get("tickets"), list) else []
        if not tickets:
            tickets = [row.get("ticket")]
        if (
            row.get("run_id")
            and row.get("worktree")
            and ticket in tickets
            and same_repository(row.get("repo"), repo)
        ):
            rows.append(row)
    for row in sorted(rows, key=lambda item: str(item.get("started_at") or "")):
        print(json.dumps(row, ensure_ascii=False, separators=(",", ":")))


def fields(lines):
    result = {}
    for line in lines:
        key, _, value = line.removeprefix("prior ").partition(" ")
        result.setdefault(key, []).append(value)
    return result


def current_ticket(lines):
    tickets = [line[7:] for line in lines if line.startswith("ticket ")]
    return tickets[-1] if tickets else None


def recheck_stage(path, stage):
    recheck = ("verify", "review", "land", "archive")
    if stage not in recheck:
        return stage
    earlier = recheck[: recheck.index(stage) + 1]
    return next((item for item in path if item in earlier), stage)


def replace(path, text):
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=".run-",
        delete=False,
    ) as output:
        temporary = Path(output.name)
        try:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def take_over(state_dir, run_id, old_session, ticket, new_session, repo):
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with locked(state_dir / ".locks" / "resume"):
        source = state_dir / old_session
        destination = state_dir / new_session
        if source == destination:
            raise ValueError("续跑需要新的会话")
        if not source.is_file() or destination.exists():
            raise ValueError("原会话已无阶段记录，或新会话已有任务")

        active = active_path(state_dir, old_session)
        try:
            row = json.loads(active.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise ValueError("原会话没有未完成运行快照") from None
        except ValueError:
            raise ValueError("原会话的运行快照已损坏") from None

        lines = source.read_text(encoding="utf-8").rstrip("\n").split("\n")
        if "verify_required yes" not in lines and source.with_name(source.name + ".verify.json").is_file():
            lines.append("verify_required yes")
        values = fields(lines)
        path = values.get("path", [None])[0]
        stage = values.get("stage", [None])[0]
        if not path or not stage:
            raise ValueError("阶段记录缺少 path/stage")
        if row.get("run_id") != run_id:
            raise ValueError("运行 ID 与原会话不符")
        if not same_repository(row.get("repo"), repo):
            raise ValueError("请在原运行的仓库续跑")
        current_worktree = worktree(repo)
        recorded_worktree = Path(row.get("worktree") or "").expanduser()
        if not current_worktree or not recorded_worktree.is_absolute() or recorded_worktree.resolve() != current_worktree:
            raise ValueError("请在原运行的 Git 工作树续跑")
        if current_ticket(lines) != ticket:
            raise ValueError("当前 ticket 与原运行不符")

        new_stage = recheck_stage(path.split(","), stage)
        updated = []
        current_ticket_seen = False
        for line in lines:
            if line.startswith("ticket "):
                current_ticket_seen = True
            if line.startswith("stage "):
                line = f"stage {new_stage}"
            elif current_ticket_seen and line.startswith(
                (
                    "evidence verify ",
                    "evidence review ",
                    "evidence land ",
                    "evidence archive ",
                    "review ",
                    "land ",
                )
            ):
                line = "prior " + line
            updated.append(line)
        lines = updated + [f"visited {new_stage}"]
        stage = new_stage

        replace(source, "\n".join(lines) + "\n")
        os.replace(source, destination)
        active.unlink(missing_ok=True)
        print(f"jstack: 已在 {ticket} 的 {stage} 阶段续跑 {run_id}")


def main(argv):
    if len(argv) < 4:
        raise ValueError("用法：resume.py find <状态目录> <仓库> <ticket>")
    action, state_dir, *args = argv
    state = Path(state_dir)
    if action == "find" and len(args) == 2:
        find(state, args[0], args[1])
    elif action == "take-over" and len(args) == 5:
        take_over(state, *args)
    else:
        raise ValueError("resume.py 参数不完整")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"jstack: 续跑失败：{error}")
