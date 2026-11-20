#!/usr/bin/env python3
"""Publish an archived flow run summary to its ticket and pull request."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


START = re.compile(r"^<!-- jstack-report (\S+) ([A-Za-z0-9._-]+) -->\r?$", re.M)
END = re.compile(r"^<!-- /jstack-report -->\r?$", re.M)


def git(directory, *args):
    result = subprocess.run(
        ["git", "-C", str(directory), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def repo_root(directory):
    root = git(directory, "rev-parse", "--show-toplevel")
    return Path(root or directory).resolve()


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


def state_directory():
    value = os.environ.get("JSTACK_STATE_DIR")
    if not value:
        base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        value = base / "jstack/sessions"
    return Path(value).expanduser()


def load_run(path, run_id):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except (TypeError, ValueError):
            continue
        if isinstance(row, dict) and row.get("run_id") == run_id:
            return row
    return None


def same_repository(row, directory):
    value = row.get("repo")
    if not isinstance(value, str) or not value or value == "-":
        return False
    candidate = Path(value).expanduser()
    if candidate.is_absolute() and candidate.resolve() == repo_root(directory):
        return True
    current = remote_id(directory)
    return bool(current and current.casefold() == value.casefold())


def tracker_config(root):
    path = root / ".jstack/config.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError(".jstack/config.json 必须是 JSON 对象")
    tracker = value.get("tracker") or {}
    if not isinstance(tracker, dict):
        raise ValueError("tracker 配置必须是 JSON 对象")
    return tracker


def local_ticket(root, config, value):
    directory = (root / config.get("local_dir", "docs/agents/tickets")).resolve()
    ticket = (root / value).resolve()
    if not directory.is_relative_to(root):
        raise ValueError("tracker.local_dir 必须位于仓库内")
    if not ticket.is_relative_to(directory) or ticket.suffix != ".md":
        raise ValueError("本地 ticket 须为 tracker.local_dir 下的 Markdown 路径")
    if not ticket.is_file():
        raise ValueError(f"本地 ticket 不存在：{value}")
    return ticket


def neutralise_markers(text):
    return text.replace("<!-- jstack-", "&lt;!-- jstack-").replace(
        "<!-- /jstack-", "&lt;!-- /jstack-"
    )


def render(row):
    verification = [
        item.removeprefix("verify ")
        for item in row.get("evidence") or []
        if isinstance(item, str) and item.startswith("verify ")
    ]
    checks = "\n".join(f"- {item}" for item in verification) or "- 本次无验证记录"
    defaults = "\n".join(f"- {item}" for item in row.get("defaults") or []) or "- 无"
    excerpt = str(row.get("report") or "").strip("\n")
    if not excerpt:
        raise ValueError("运行记录里没有摘要")
    text = (
        f"## 运行摘要\n\n{neutralise_markers(excerpt)}\n\n"
        f"## 验证\n\n{checks}\n\n"
        f"## 默认决定\n\n{defaults}"
    )
    return text


def section_for(original, row, summary):
    starts, ends = list(START.finditer(original)), list(END.finditer(original))
    version = (
        str(row.get("ended_at") or row.get("started_at") or ""),
        str(row["run_id"]),
    )
    section = (
        f"<!-- jstack-report {version[0]} {version[1]} -->\n"
        f"{summary}\n<!-- /jstack-report -->"
    )
    if not starts and not ends:
        return original + ("\n\n" if original else "") + section + "\n"
    if len(starts) != 1 or len(ends) != 1 or starts[0].end() >= ends[0].start():
        raise ValueError("已有运行摘要的边界不完整")
    start, end = starts[0], ends[0]
    if (start.group(1), start.group(2)) >= version:
        return original
    suffix_offset = end.end() - int(end.group(0).endswith("\r"))
    return original[: start.start()] + section + original[suffix_offset:]


def replace_text(path, text, mode):
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=".jstack-report-",
        delete=False,
    ) as output:
        temporary = Path(output.name)
        try:
            os.fchmod(output.fileno(), mode)
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


def gh(host, method, endpoint, body=None, paginate=False):
    command = ["gh", "api", "--hostname", host, "-X", method, endpoint]
    if paginate:
        command.extend(("--paginate", "--slurp"))
    if body is not None:
        command.extend(("--input", "-"))
    result = subprocess.run(
        command,
        input=json.dumps({"body": body}) if body is not None else "",
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise ValueError(
            f"GitHub {method} {endpoint} 失败（gh 退出码 {result.returncode}）"
            + (f"：{detail}" if detail else "")
        )
    return json.loads(result.stdout) if result.stdout.strip() else None


def issue_report(host, slug, number, row, summary):
    endpoint = f"repos/{slug}/issues/{number}/comments"
    marker = f"<!-- jstack-run {row['run_id']} -->"
    pages = gh(host, "GET", endpoint, paginate=True) or []
    if isinstance(pages, dict):
        pages = [pages]
    for page in pages:
        if not isinstance(page, list):
            continue
        for comment in page:
            body = comment.get("body") if isinstance(comment, dict) else None
            if isinstance(body, str) and body.startswith(marker + "\n"):
                return
    gh(host, "POST", endpoint, f"{marker}\n{summary}")


def pr_report(host, slug, number, row, summary):
    endpoint = f"repos/{slug}/pulls/{number}"
    current = gh(host, "GET", endpoint)
    body = current.get("body") if isinstance(current, dict) else ""
    updated = section_for(body or "", row, summary)
    if updated != (body or ""):
        gh(host, "PATCH", endpoint, updated)


def publish(state_dir, directory, run_id):
    path = state_dir.parent / "runs.jsonl"
    row = load_run(path, run_id)
    if not row or row.get("status") != "completed" or not row.get("report"):
        raise ValueError("没有可发布的已完成运行摘要")
    if not same_repository(row, directory):
        raise ValueError("运行摘要属于另一个仓库")

    ticket = row.get("ticket")
    tickets = [ticket] if row.get("ticket_explicit") and ticket not in (None, "", "-") else []
    prs = [item for item in row.get("prs") or [] if isinstance(item, str)]
    if not tickets and not prs:
        print("jstack: 运行摘要已留在本地")
        return

    root = repo_root(directory)
    config = tracker_config(root)
    remote = remote_id(root)
    github = remote if remote and remote.startswith("github.com/") else None
    tracker_type = config.get("type") or ("github" if github else "local")
    local_files, issue_numbers, pull_requests = [], [], []

    if tracker_type == "local":
        local_files = [local_ticket(root, config, value) for value in tickets]
    elif tracker_type == "github":
        if not github:
            raise ValueError("tracker.type=github 需要 GitHub remote")
        for value in tickets:
            if not re.fullmatch(r"#[1-9][0-9]*", value):
                raise ValueError("GitHub issue 须使用本仓库的 #编号")
            issue_numbers.append(value[1:])
    else:
        raise ValueError(f"不支持的 tracker 类型：{tracker_type}")

    if prs and not github:
        raise ValueError("报告只发往当前仓库的 GitHub PR")
    if github:
        host, slug = github.split("/", 1)
        for url in prs:
            parsed = urlsplit(url)
            parts = parsed.path.strip("/").split("/")
            if (
                parsed.scheme != "https"
                or not parsed.hostname
                or parsed.hostname.casefold() != host.casefold()
                or len(parts) != 4
                or parts[2] != "pull"
                or not parts[3].isdigit()
                or f"{parts[0]}/{parts[1]}".casefold() != slug.casefold()
            ):
                raise ValueError("报告只发往当前仓库的 GitHub PR")
            pull_requests.append(parts[3])

    summary = render(row)
    with locked(path.with_name("report.lock")):
        for ticket_path in dict.fromkeys(local_files):
            current = ticket_path.read_text(encoding="utf-8")
            updated = section_for(current, row, summary)
            if updated != current:
                replace_text(ticket_path, updated, stat.S_IMODE(ticket_path.stat().st_mode))
        if github:
            host, slug = github.split("/", 1)
            for number in dict.fromkeys(issue_numbers):
                issue_report(host, slug, number, row, summary)
            for number in dict.fromkeys(pull_requests):
                pr_report(host, slug, number, row, summary)
    print("jstack: 运行摘要已写入 tracker")


def main():
    if os.environ.get("JSTACK_SUBAGENT_ID"):
        sys.exit("jstack: 子代理不能发布运行摘要")
    parser = argparse.ArgumentParser(prog="./jstack report")
    parser.add_argument("run_id")
    args = parser.parse_args()
    directory = os.environ.get("JSTACK_REPO") or os.getcwd()
    try:
        publish(state_directory(), directory, args.run_id)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"jstack: 发布运行摘要失败：{error}")


if __name__ == "__main__":
    main()
