"""Run and cache the repository's configured verification command."""

import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


NO_COMMAND = 10
PENDING = "验证命令仍在运行。请运行 stage.sh verify 等待结果，完成前保留当前阶段记录。"
STOP_WAIT_SECONDS = 4
OUTPUT_TAIL_BYTES = 2048


def settings(repo):
    config = json.loads((repo / ".jstack/config.json").read_text(encoding="utf-8"))
    verify = config.get("verify") or {}
    command = verify.get("command")
    if command is None or command == "":
        return None
    if not isinstance(command, str) or not command.strip():
        raise ValueError("verify.command 必须是非空命令")
    timeout = verify.get("timeout_s")
    if timeout is None:
        timeout = 600
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("verify.timeout_s 必须是正数")
    if any(item.get("regex") for item in config.get("must_stop") or []):
        if os.environ.get("JSTACK_NO_JQ") or shutil.which("jq") is None:
            raise ValueError("验证命令需要 jq 才能检查仓库的 must-stop 模式")
    return command, timeout


def snapshot(repo, command, timeout):
    def git(*args, check=True):
        return subprocess.run(
            ["git", "--no-optional-locks", *args], cwd=repo, check=check,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout

    commit = git("rev-parse", "--verify", "HEAD", check=False).strip().decode("ascii")
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    digest = hashlib.sha256()

    def add(data):
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)

    add(json.dumps([str(repo), command, timeout, commit]).encode("utf-8"))
    add(status)
    add(git("ls-files", "--stage", "-z"))
    add(git("diff", "--binary", "--no-ext-diff", "--no-textconv"))
    for name in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not name:
            continue
        add(name)
        path = repo / os.fsdecode(name)
        mode = path.lstat().st_mode
        add(str(mode).encode("ascii"))
        if stat.S_ISLNK(mode):
            add(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(mode):
            content = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(65536), b""):
                    content.update(block)
            add(content.digest())
        else:
            raise ValueError(f"无法核对未跟踪路径 {os.fsdecode(name)}")
    return digest.hexdigest(), commit or None, bool(status)


def run_command(repo, command, timeout):
    plugin = Path(__file__).resolve().parents[2]
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                        "tool_input": {"command": command}})
    guard_result = subprocess.run(
        ["bash", str(plugin / "hooks/guard.sh")], input=event, text=True, stdout=subprocess.PIPE,
        cwd=repo, env={**os.environ, "JSTACK_REPO": str(repo), "CLAUDE_PLUGIN_ROOT": str(plugin)},
        check=True,
    )
    if guard_result.stdout.strip():
        raise ValueError("验证命令命中 must-stop，未执行")
    start = time.monotonic()
    timed_out = False
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            ["bash", "-c", command], cwd=repo, stdin=subprocess.DEVNULL, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            status = 124
        size = output.seek(0, os.SEEK_END)
        output.seek(max(0, size - OUTPUT_TAIL_BYTES))
        tail = output.read(OUTPUT_TAIL_BYTES).decode("utf-8", errors="replace")
    return status, timed_out, round((time.monotonic() - start) * 1000), tail


def receipt_result(record):
    if record["workspace_changed"]:
        print("验证期间 Git 工作区变化，请在当前版本重新验证。")
        return 1
    if record["exit_code"] == 0:
        return 0
    detail = "超时" if record["timed_out"] else f"退出码 {record['exit_code']}"
    tail = re.sub(r"[\x00-\x1f\x7f]", " ", record["output_tail"]).strip()
    print(f"验证命令失败（{detail}）。{tail}")
    return 1


def verify(repo, state, mode):
    receipt = state.with_name(state.name + ".verify.json")
    lock = state.with_name(state.name + ".verify.lock")
    with lock.open("ab") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | (fcntl.LOCK_NB if mode == "worker" else 0))
        except BlockingIOError:
            print(PENDING)
            return 1

        if not state.is_file():
            raise ValueError("阶段记录已清除")
        request = settings(repo)
        if request is None:
            return NO_COMMAND
        key, commit, dirty = snapshot(repo, *request)
        if mode != "retry" and receipt.is_file():
            record = json.loads(receipt.read_text(encoding="utf-8"))
            if record.get("key") == key and not record.get("workspace_changed"):
                return receipt_result(record)
        status, timed_out, duration_ms, tail = run_command(repo, *request)
        changed = settings(repo) != request or snapshot(repo, *request)[0] != key
        record = {
            "key": key, "commit": commit, "dirty": dirty, "duration_ms": duration_ms,
            "exit_code": status, "timed_out": timed_out, "output_tail": tail if status else "",
            "workspace_changed": changed,
        }
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=receipt.parent,
                                         prefix=receipt.name + ".", delete=False) as output:
            json.dump(record, output, ensure_ascii=False)
            output.write("\n")
        os.replace(output.name, receipt)
        return receipt_result(record)


def main():
    mode, root, state_path = sys.argv[1:]
    repo, state = Path(root).resolve(), Path(state_path).resolve()
    try:
        if settings(repo) is None:
            return NO_COMMAND
        if mode != "stop":
            return verify(repo, state, mode)
        with tempfile.TemporaryFile() as feedback:
            worker = subprocess.Popen(
                [sys.executable, "-I", __file__, "worker", str(repo), str(state)],
                stdin=subprocess.DEVNULL, stdout=feedback, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                status = worker.wait(timeout=STOP_WAIT_SECONDS)
            except subprocess.TimeoutExpired:
                print(PENDING)
                return 1
            feedback.seek(0)
            sys.stdout.write(feedback.read().decode("utf-8", errors="replace"))
            return status
    except (AttributeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"无法完成配置的验证命令：{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
