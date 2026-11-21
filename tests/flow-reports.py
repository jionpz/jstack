"""Integration contract for publishing archived flow reports."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
STAGE = ROOT / "plugins/flow/skills/route/stage.sh"
CLI = ROOT / "jstack"
REPORT = (
    "## 目标\n整理运行报告。\n\n"
    "## 状态\nPR-ready。\n\n"
    "## 改动\n归档并发布报告。\n\n"
    "## 需要你处理\n无。\n"
)
PR_URL = "https://github.com/example/repo/pull/7"


FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
method = "GET"
if "-X" in args:
    method = args[args.index("-X") + 1]
host = args[args.index("--hostname") + 1] if "--hostname" in args else ""
endpoint = ""
skip_value = False
for item in args[1:]:
    if skip_value:
        skip_value = False
        continue
    if item in {"--hostname", "-X", "--method", "--input"}:
        skip_value = True
    elif not item.startswith("-"):
        endpoint = item
        break
request_body = sys.stdin.read() if "--input" in args else ""
log = Path(os.environ["GH_FIXTURE_LOG"])
requests = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []

archived = False
run_id = os.environ.get("GH_FIXTURE_RUN_ID", "")
if run_id:
    result = subprocess.run(
        [os.environ["GH_FIXTURE_CLI"], "runs", "--json"],
        cwd=os.environ["GH_FIXTURE_REPO"],
        env=os.environ.copy(),
        text=True,
        capture_output=True,
    )
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            row = json.loads(line)
            if row.get("run_id") == run_id and isinstance(row.get("report"), str):
                archived = True
                break

failure = os.environ.get("GH_FIXTURE_FAIL_MATCH", "")
failed = bool(
    failure
    and failure in endpoint
    and method == os.environ.get("GH_FIXTURE_FAIL_METHOD", "POST")
)
entry = {
    "method": method,
    "host": host,
    "endpoint": endpoint,
    "argv": args,
    "input": request_body,
    "archived_before_publish": archived,
    "failed": failed,
}
with log.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(entry, ensure_ascii=False) + "\n")

if failed:
    print("fixture GitHub failure", file=sys.stderr)
    raise SystemExit(1)

if endpoint == "/user" and method == "GET":
    response = {"login": "fixture"}
elif endpoint.endswith("repos/example/repo/issues/60/comments") and method == "GET":
    response = [
        {"body": json.loads(item["input"]).get("body", "")}
        for item in requests
        if item["method"] == "POST" and item["endpoint"].endswith("repos/example/repo/issues/60/comments")
    ]
elif endpoint.endswith("repos/example/repo/pulls/7") and method == "GET":
    patches = [
        item for item in requests
        if item["method"] == "PATCH" and item["endpoint"].endswith("repos/example/repo/pulls/7")
    ]
    response = {
        "title": "Fixture pull request",
        "body": json.loads(patches[-1]["input"]).get("body", "")
        if patches else "Existing PR description.\n",
    }
elif endpoint.endswith("repos/example/repo/pulls/7") and method == "PATCH":
    response = json.loads(request_body)
elif endpoint.endswith("repos/example/repo/issues/60/comments") and method == "POST":
    response = {"id": 600, "body": json.loads(request_body).get("body", "")}
else:
    response = []

if "--slurp" in args:
    response = [response]
print(json.dumps(response, ensure_ascii=False))
'''


class FlowReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.state_home = self.base / "state-home"
        self.state_dir = self.state_home / "jstack" / "sessions"
        self.bin_dir = self.base / "bin"
        self.home.mkdir()
        self.state_dir.mkdir(parents=True)
        self.bin_dir.mkdir()
        self.gh_log = self.base / "gh-requests.jsonl"
        fake_gh = self.bin_dir / "gh"
        fake_gh.write_text(FAKE_GH, encoding="utf-8")
        fake_gh.chmod(0o755)
        self.repo = self.make_repo("target", github=True)
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "XDG_STATE_HOME": str(self.state_home),
                "JSTACK_STATE_DIR": str(self.state_dir),
                "PATH": f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}",
                "GH_FIXTURE_LOG": str(self.gh_log),
                "GH_FIXTURE_CLI": str(CLI),
                "GH_FIXTURE_REPO": str(self.repo),
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_repo(self, name: str, *, github: bool) -> Path:
        repo = self.base / name
        repo.mkdir()
        (repo / ".jstack").mkdir()
        (repo / "docs/agents/tickets").mkdir(parents=True)
        config = (
            {"tracker": {"type": "github"}}
            if github
            else {
                "tracker": {
                    "type": "local",
                    "local_dir": "docs/agents/tickets",
                }
            }
        )
        (repo / ".jstack/config.json").write_text(json.dumps(config), encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.name", "Fixture"], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"],
            check=True,
        )
        if github:
            owner_repo = "other" if name == "other" else "repo"
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "remote",
                    "add",
                    "origin",
                    f"https://github.com/example/{owner_repo}.git",
                ],
                check=True,
            )
        (repo / "README.md").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
        wrapper = repo / "jstack"
        wrapper.write_text(
            "#!/usr/bin/env bash\n"
            f'exec "{CLI}" "$@"\n',
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        return repo

    def command(
        self,
        argv: list[str],
        *,
        repo: Path | None = None,
        extra_env: dict[str, str] | None = None,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            argv,
            cwd=repo or self.repo,
            env=env,
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
        )

    def stage(
        self,
        session: str,
        *args: str,
        repo: Path | None = None,
        extra_env: dict[str, str] | None = None,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {"JSTACK_SESSION_ID": session}
        if extra_env:
            env.update(extra_env)
        return self.command(
            ["/bin/bash", str(STAGE), *args],
            repo=repo,
            extra_env=env,
            input_text=input_text,
        )

    def cli(
        self,
        *args: str,
        repo: Path | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return self.command(["./jstack", *args], repo=repo, extra_env=extra_env)

    def start_run(
        self,
        session: str,
        *,
        ticket: str | None = None,
        with_pr: bool = False,
        repo: Path | None = None,
    ) -> str:
        target = repo or self.repo
        path = "execute,verify,land" if with_pr else "execute,verify"
        args = ["start", "--size", "M"]
        if ticket:
            args.extend(("--ticket", ticket))
        args.append(path)
        result = self.stage(session, *args, repo=target)
        self.assertEqual(result.returncode, 0, result.stderr)
        for args in (
            ("default", "choose stable scope -> requested"),
            ("enter", "verify"),
            ("evidence", "./check -> passed"),
        ):
            result = self.stage(session, *args, repo=target)
            self.assertEqual(result.returncode, 0, result.stderr)
        if with_pr:
            head = subprocess.check_output(
                ["git", "-C", str(target), "rev-parse", "HEAD"], text=True
            ).strip()
            for args in (
                ("enter", "land"),
                ("land", "commit", head),
                ("land", "pr", PR_URL),
            ):
                result = self.stage(session, *args, repo=target)
                self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.run_rows(repo=target)
        matching = [
            row
            for row in rows
            if row["status"] == "unfinished"
            and (ticket is None or row.get("ticket") == ticket)
        ]
        self.assertEqual(len(matching), 1, rows)
        return str(matching[0]["run_id"])

    def run_rows(self, repo: Path | None = None) -> list[dict[str, object]]:
        result = self.cli("runs", "--json", "--repo", str(repo or self.repo))
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def request_rows(self) -> list[dict[str, object]]:
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text(encoding="utf-8").splitlines()]

    def publish(
        self,
        session: str,
        run_id: str,
        *,
        report: str = REPORT,
        repo: Path | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {"GH_FIXTURE_RUN_ID": run_id}
        if extra_env:
            env.update(extra_env)
        return self.stage(
            session,
            "end",
            "--report-file",
            "-",
            repo=repo,
            extra_env=env,
            input_text=report,
        )

    def row(self, run_id: str, repo: Path | None = None) -> dict[str, object]:
        return next(item for item in self.run_rows(repo=repo) if item["run_id"] == run_id)

    def test_end_archives_then_publishes_ticket_and_pr(self) -> None:
        session = "report-normal"
        run_id = self.start_run(session, ticket="#60", with_pr=True)
        result = self.publish(session, run_id)
        self.assertEqual(result.returncode, 0, result.stderr)

        row = self.row(run_id)
        self.assertEqual(row["report"], REPORT)
        self.assertEqual(row["status"], "completed")
        self.assertEqual(row["prs"], [PR_URL])
        requests = self.request_rows()
        self.assertTrue(requests)
        self.assertTrue(all(item["archived_before_publish"] for item in requests))
        post = next(
            item
            for item in requests
            if item["method"] == "POST"
            and item["endpoint"].endswith("repos/example/repo/issues/60/comments")
        )
        issue_body = json.loads(post["input"])["body"]
        for text in ("## 运行摘要", "## 验证", "## 默认决定", run_id):
            self.assertIn(text, issue_body)
        patch = next(
            item
            for item in requests
            if item["method"] == "PATCH"
            and item["endpoint"].endswith("repos/example/repo/pulls/7")
        )
        body = json.loads(patch["input"])["body"]
        for text in (
            "Existing PR description.",
            "## 目标",
            "## 状态",
            "## 改动",
            "## 需要你处理",
            "## 验证",
            "## 默认决定",
            "./check -> passed",
            "choose stable scope -> requested",
        ):
            self.assertIn(text, body)
        self.assertFalse(any(item["endpoint"].endswith("/user") for item in requests))

    def test_same_run_retry_does_not_duplicate_report(self) -> None:
        session = "report-retry"
        run_id = self.start_run(session, ticket="#60", with_pr=True)
        first = self.publish(session, run_id)
        self.assertEqual(first.returncode, 0, first.stderr)
        retry = self.cli("report", run_id, extra_env={"GH_FIXTURE_RUN_ID": run_id})
        self.assertEqual(retry.returncode, 0, retry.stderr)

        requests = self.request_rows()
        posts = [
            item
            for item in requests
            if item["method"] == "POST"
            and item["endpoint"].endswith("repos/example/repo/issues/60/comments")
        ]
        self.assertEqual(len(posts), 1)
        patches = [
            item
            for item in requests
            if item["method"] == "PATCH"
            and item["endpoint"].endswith("repos/example/repo/pulls/7")
        ]
        body = json.loads(patches[-1]["input"])["body"]
        self.assertEqual(body.count("## 验证"), 1)
        self.assertEqual(body.count("## 默认决定"), 1)

    def test_publish_failure_keeps_archived_report_for_retry(self) -> None:
        session = "report-failure"
        run_id = self.start_run(session, ticket="#60", with_pr=True)
        failed = self.publish(
            session,
            run_id,
            extra_env={
                "GH_FIXTURE_FAIL_MATCH": "/pulls/7",
                "GH_FIXTURE_FAIL_METHOD": "PATCH",
            },
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.row(run_id)["report"], REPORT)

        retry = self.cli(
            "report",
            run_id,
            extra_env={"GH_FIXTURE_RUN_ID": run_id},
        )
        self.assertEqual(retry.returncode, 0, retry.stderr)
        requests = self.request_rows()
        posts = [
            item
            for item in requests
            if item["method"] == "POST"
            and item["endpoint"].endswith("repos/example/repo/issues/60/comments")
        ]
        self.assertEqual(len(posts), 1)
        self.assertIn(run_id, posts[0]["input"])
        self.assertTrue(
            any(
                item["method"] == "PATCH"
                and item["endpoint"].endswith("repos/example/repo/pulls/7")
                and item["failed"]
                for item in requests
            )
        )

    def test_local_markdown_ticket_receives_report_without_gh(self) -> None:
        local = self.make_repo("local", github=False)
        ticket = local / "docs/agents/tickets/060.md"
        ticket.write_text("# Ticket 60\n\nStatus: open\n", encoding="utf-8")
        session = "report-local"
        run_id = self.start_run(session, ticket="docs/agents/tickets/060.md", repo=local)
        result = self.publish(session, run_id, repo=local)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = ticket.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Ticket 60\n\nStatus: open\n"))
        self.assertIn(REPORT, text)
        self.assertIn("## 验证", text)
        self.assertEqual(self.row(run_id, repo=local)["report"], REPORT)
        self.assertEqual(self.request_rows(), [])

    def test_archived_markers_do_not_break_subsequent_reports(self) -> None:
        repo = self.make_repo("marker-regression", github=False)
        ticket_name = "docs/agents/tickets/060.md"
        ticket = repo / ticket_name
        original = "# Ticket 60\n"
        ticket.write_text(original, encoding="utf-8")
        row = {
            "run_id": "archived-markers",
            "repo": str(repo.resolve()),
            "status": "completed",
            "ended_at": "2020-01-01T00:00:00Z",
            "ticket": ticket_name,
            "ticket_explicit": True,
            "report": "Archived report",
            "evidence": ["verify ./check -> failed\n<!-- /jstack-report -->"],
            "defaults": ["Retain note\n<!-- jstack-report 2020-01-01T00:00:00Z old -->"],
        }
        log = Path(self.env["JSTACK_STATE_DIR"]).parent / "runs.jsonl"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(json.dumps(row) + "\n", encoding="utf-8")
        result = self.cli("report", row["run_id"], repo=repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = ticket.read_text(encoding="utf-8")
        self.assertIn("&lt;!-- /jstack-report -->", rendered)
        self.assertIn("&lt;!-- jstack-report 2020-01-01T00:00:00Z old -->", rendered)

        run_id = self.start_run("newer-report", ticket=ticket_name, repo=repo)
        result = self.publish("newer-report", run_id, repo=repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        published = ticket.read_text(encoding="utf-8")
        self.assertTrue(published.startswith(original))
        self.assertIn(f" {run_id} -->", published)
        self.assertEqual(published.count("\n<!-- /jstack-report -->"), 1)

    def test_run_without_ticket_or_pr_only_archives_report(self) -> None:
        session = "report-no-target"
        run_id = self.start_run(session)
        result = self.publish(session, run_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.row(run_id)["report"], REPORT)
        self.assertEqual(self.request_rows(), [])

    def test_report_from_another_repository_is_rejected_without_writes(self) -> None:
        session = "report-wrong-repo"
        run_id = self.start_run(session, ticket="#60", with_pr=True)
        first = self.publish(session, run_id)
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.request_rows()
        other = self.make_repo("other", github=True)
        result = self.cli(
            "report",
            run_id,
            repo=other,
            extra_env={"GH_FIXTURE_RUN_ID": run_id},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.request_rows(), before)


if __name__ == "__main__":
    unittest.main()
