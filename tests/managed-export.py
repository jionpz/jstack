"""managed-export 的纯标准库验收测试。"""

from __future__ import annotations

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/managed-export.py"
STAGE_TABLE = REPO / "scripts/stage_table.py"
ROUTE = "src/flow/skills/route/SKILL.md"
STAGES = "src/flow/skills/route/stages.md"
EXECUTE = "src/managed/investigate.md"
PLAN = "src/managed/plan.md"
MUST_STOP = "src/flow/skills/route/must-stop.md"
TOOL_POLICY = "src/flow/skills/route/tool-policy.json"
PROVIDERS = {
    "execute": "src/flow/skills/execute/SKILL.md",
    "verify": "plugins/pstack/skills/principle-prove-it-works/SKILL.md",
    "review": "src/flow/skills/review/SKILL.md",
    "land": "plugins/pstack/skills/poteto-mode/playbooks/opening-a-pr.md",
}


class ManagedExportTests(unittest.TestCase):
    def fixture(self, base: Path) -> Path:
        root = base / "fixture"
        (root / "scripts").mkdir(parents=True)
        (root / "src/flow/skills/route").mkdir(parents=True)
        (root / "src/managed").mkdir(parents=True)
        (root / "scripts/managed-export.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        (root / "scripts/stage_table.py").write_text(STAGE_TABLE.read_text(encoding="utf-8"), encoding="utf-8")
        (root / ROUTE).write_text("# route\n| Question | investigation | execute only |\n", encoding="utf-8")
        (root / STAGES).write_text("| Stage |\n| execute |\n", encoding="utf-8")
        (root / EXECUTE).write_text("只读调查。\n", encoding="utf-8")
        (root / PLAN).write_text("输出 ticket 图。\n", encoding="utf-8")
        return root

    def ticket_fixture(self, base: Path) -> Path:
        root = self.fixture(base)
        (root / STAGES).write_text(
            "## Stages\n\n"
            "| Stage | Output | Gate | Providers | Tool profile |\n"
            "|---|---|---|---|---|\n"
            "| execute | change | none | `flow:execute` | `developer` |\n"
            "| verify | evidence | evidence required | `pstack:principle-prove-it-works` | `verifier` |\n"
            "| review | findings | no open findings | `flow:review` | `reviewer` |\n"
            "| land | commit | no must-stop | `pstack:poteto-mode/playbooks/opening-a-pr.md` | `releaser` |\n"
            "| archive | closed | evidence | `flow:archive` | `archivist` |\n",
            encoding="utf-8",
        )
        (root / ROUTE).write_text(
            "# route\n\n"
            "| Question | investigation | execute only |\n\n"
            "## 2. Size the task and pick the stage path\n\n"
            "| Size | Signals | Stage path |\n"
            "|---|---|---|\n"
            "| XS / S | one file | execute, verify, land, archive |\n"
            "| M, clear | one module | execute, verify, review, land, archive |\n"
            "| M, ambiguous | two readings | clarify, execute, verify, review, land, archive |\n"
            "| L | several features | clarify, plan, execute, verify, review, land, archive |\n"
            "| XL | many sessions | plan with wayfinder, L for each cleared area |\n"
            "| Question | why | execute only |\n",
            encoding="utf-8",
        )
        (root / MUST_STOP).write_text(
            "## Must stop\n\n"
            "| Action | Hook |\n"
            "|---|---|\n"
            "| Recursive forced delete | `rm-rf` |\n"
            "| Force push | `force-push` |\n",
            encoding="utf-8",
        )
        policy = {
            "protocol_version": "1.0",
            "profiles": {
                "developer": {
                    "role": "developer",
                    "capabilities": ["read", "edit", "write", "bash"],
                    "optional_capabilities": [],
                },
                "verifier": {
                    "role": "verifier",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
                "reviewer": {
                    "role": "reviewer",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
                "releaser": {
                    "role": "releaser",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
                "archivist": {
                    "role": "archivist",
                    "capabilities": ["read", "bash"],
                    "optional_capabilities": [],
                },
            },
            "harnesses": {"pi": {"read": {"native": ["read"]}}},
        }
        (root / TOOL_POLICY).write_text(json.dumps(policy), encoding="utf-8")
        for path in PROVIDERS.values():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"provider {path}\n", encoding="utf-8")
        return root

    def add_tier_column(self, root: Path, values: dict[str, str] | None = None) -> None:
        values = values or {
            "execute": "bulk / -",
            "verify": "bulk / premium",
            "review": "bulk / bulk",
            "land": "bulk / premium",
            "archive": "bulk / -",
        }
        path = root / STAGES
        lines = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("|"):
                cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
                if cells[0] == "Stage":
                    if "Tier" not in cells:
                        cells.append("Tier")
                elif cells[0] in values or cells[0] == "execute":
                    if cells[0] == "execute" and "execute" not in values:
                        cells = cells[:5]
                    else:
                        cells = cells[:5] + [values[cells[0]]]
                elif all(set(cell) <= {":", "-"} for cell in cells):
                    cells = cells[:5] + ["---"]
                line = "| " + " | ".join(cells) + " |"
            lines.append(line)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_export(
        self, root: Path, cwd: Path | None = None, *, use_default_root: bool = False
    ) -> subprocess.CompletedProcess[str]:
        script = root / "scripts/managed-export.py"
        command = [sys.executable, str(script)]
        if not use_default_root:
            command.extend(["--root", str(root)])
        return subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_exports_exact_protocol_and_source_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            result = self.run_export(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(
                set(payload),
                {"protocol_version", "workflow_id", "mode", "source_commit", "stages", "instructions"},
            )
            self.assertEqual(payload["protocol_version"], "1.0")
            self.assertEqual(payload["workflow_id"], "jstack")
            self.assertEqual(payload["mode"], "investigation")
            self.assertEqual(payload["stages"], ["execute"])
            self.assertEqual(payload["instructions"]["route"], "# route\n| Question | investigation | execute only |\n")
            self.assertEqual(payload["instructions"]["stages"], "| Stage |\n| execute |\n")
            self.assertEqual(payload["instructions"]["execute"], "只读调查。\n")
            self.assertEqual(payload["source_commit"], "unversioned")

    def test_missing_file_and_missing_execute_are_rejected_without_partial_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            (root / EXECUTE).unlink()
            missing = self.run_export(root)
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout, "")
            self.assertIn(EXECUTE, missing.stderr)

            (root / EXECUTE).write_text("只读调查。\n", encoding="utf-8")
            (root / STAGES).write_text("| Stage |\n| verify |\n", encoding="utf-8")
            no_execute = self.run_export(root)
            self.assertNotEqual(no_execute.returncode, 0)
            self.assertEqual(no_execute.stdout, "")
            self.assertIn("execute", no_execute.stderr)

    def test_output_is_independent_of_working_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            unrelated = base / "elsewhere"
            unrelated.mkdir()
            result = self.run_export(root, cwd=unrelated, use_default_root=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["workflow_id"], "jstack")

    def test_symlink_escaping_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self.fixture(base)
            outside = base / "outside.md"
            outside.write_text("outside\n", encoding="utf-8")
            target = root / EXECUTE
            target.unlink()
            target.symlink_to(outside)
            result = self.run_export(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("越出仓库根目录", result.stderr)

    def test_ticket_exports_fixed_stages_and_complete_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                    "--ticket-title",
                    "single ticket",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["mode"], "ticket")
            self.assertEqual(payload["route"]["stages"], ["execute", "verify", "review", "land"])
            self.assertEqual(payload["completion_target"], "branch_ready")
            self.assertEqual(
                [stage["stage"] for stage in payload["stages"]],
                ["execute", "verify", "review", "land"],
            )
            self.assertEqual(
                [stage["tool_profile"] for stage in payload["stages"]],
                ["developer", "verifier", "reviewer", "releaser"],
            )
            self.assertEqual(payload["ticket"], {"id": "JT-101", "title": "single ticket"})
            self.assertEqual(payload["must_stop"]["actions"][0]["action"], "Recursive forced delete")
            self.assertEqual(payload["tool_policy"]["stages"]["execute"], "developer")
            self.assertEqual(len(payload["sources"]), 8)

            body = {key: value for key, value in payload.items() if key != "content_digest"}
            canonical = json.dumps(
                body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            self.assertEqual(payload["content_digest"], hashlib.sha256(canonical).hexdigest())
            for source in payload["sources"]:
                content = (root / source["path"]).read_text(encoding="utf-8")
                self.assertEqual(
                    source["sha256"], hashlib.sha256(content.encode("utf-8")).hexdigest()
                )
                self.assertEqual(source["bytes"], len(content.encode("utf-8")))

    def test_stage_tiers_are_opt_in_for_route_and_ticket_exports(self) -> None:
        expected = {
            "execute": {"work": "bulk", "gate": None},
            "verify": {"work": "bulk", "gate": "premium"},
            "review": {"work": "bulk", "gate": "bulk"},
            "land": {"work": "bulk", "gate": "premium"},
            "archive": {"work": "bulk", "gate": None},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            self.add_tier_column(root)
            script = root / "scripts/managed-export.py"
            for mode_args in (["--route"], ["--ticket-id", "JT-101"]):
                default = subprocess.run(
                    [sys.executable, str(script), "--root", str(root), *mode_args],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(default.returncode, 0, default.stderr)
                default_payload = json.loads(default.stdout)
                self.assertNotIn("stage_tiers", default_payload)
                self.assertIn("| Tier |", default_payload["instructions"]["stages"])

                opted_in = subprocess.run(
                    [
                        sys.executable, str(script), "--root", str(root),
                        *mode_args, "--with-stage-tiers",
                    ],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(opted_in.returncode, 0, opted_in.stderr)
                payload = json.loads(opted_in.stdout)
                self.assertEqual(payload["stage_tiers"], expected)
                body = {key: value for key, value in payload.items() if key != "content_digest"}
                canonical = json.dumps(
                    body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
                ).encode("utf-8")
                self.assertEqual(
                    payload["content_digest"], hashlib.sha256(canonical).hexdigest()
                )

    def test_stage_tiers_flag_requires_tier_table_and_managed_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            script = root / "scripts/managed-export.py"
            for mode_args in (["--route"], ["--ticket-id", "JT-101"], []):
                result = subprocess.run(
                    [
                        sys.executable, str(script), "--root", str(root),
                        *mode_args, "--with-stage-tiers",
                    ],
                    text=True, capture_output=True, check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_managed_path_and_tiers_come_from_same_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            self.add_tier_column(root)
            stages = root / STAGES
            text = stages.read_text(encoding="utf-8")
            text = text.replace("| Tool profile | Tier |", "| Tool profile | Managed ticket | Tier |")
            text = text.replace("|---|---|---|---|---|---|", "|---|---|---|---|---|---|---|")
            for profile in ("developer", "verifier", "releaser"):
                text = text.replace(f"`{profile}` | bulk", f"`{profile}` | required | bulk")
            for profile in ("reviewer", "archivist"):
                text = text.replace(f"`{profile}` | bulk", f"`{profile}` | - | bulk")
            text = text.replace("`flow:execute` |", "`flow:managed-execute` `flow:execute` |")
            text = text.replace("`pstack:principle-prove-it-works` |", "`flow:verify` |")
            stages.write_text(text, encoding="utf-8")
            provider = root / "src/flow/skills/managed-execute/SKILL.md"
            provider.parent.mkdir()
            provider.write_text("managed execute\n", encoding="utf-8")
            verifier = root / "src/flow/skills/verify/SKILL.md"
            verifier.parent.mkdir()
            verifier.write_text("independent verification\n", encoding="utf-8")
            command = [
                sys.executable, str(root / "scripts/managed-export.py"),
                "--root", str(root), "--with-stage-tiers",
            ]
            ticket = json.loads(subprocess.check_output([*command, "--ticket-id", "JT-101"]))
            route = json.loads(subprocess.check_output([*command, "--route"]))
            expected = ["execute", "verify", "land"]
            self.assertEqual(ticket["route"]["stages"], expected)
            self.assertEqual([rule["stage_path"] for rule in route["route_rules"]], [expected] * 5)
            self.assertEqual(route["stage_templates"], ticket["stages"])
            self.assertEqual(ticket["stages"][0]["provider"], "flow:managed-execute")
            self.assertEqual(ticket["stages"][1]["provider"], "flow:verify")
            self.assertEqual(route["stage_tiers"], ticket["stage_tiers"])
            self.assertEqual(route["stage_tiers"]["review"], {"work": "bulk", "gate": "bulk"})

    def test_invalid_or_missing_tier_cells_are_rejected_in_both_export_modes(self) -> None:
        invalid_values = {
            "execute": "bulk / -",
            "verify": "premium / bulk",
            "review": "bulk / bulk",
            "land": "bulk / premium",
            "archive": "bulk / -",
        }
        missing_values = {
            "review": "bulk / bulk",
            "land": "bulk / premium",
            "archive": "bulk / -",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            script = root / "scripts/managed-export.py"
            for values in (invalid_values, missing_values):
                for mode_args in (["--route"], ["--ticket-id", "JT-101"]):
                    for with_flag in (False, True):
                        with self.subTest(values=values, mode=mode_args, with_flag=with_flag):
                            self.add_tier_column(root, values)
                            command = [
                                sys.executable, str(script), "--root", str(root),
                                *mode_args,
                            ]
                            if with_flag:
                                command.append("--with-stage-tiers")
                            result = subprocess.run(
                                command, text=True, capture_output=True, check=False
                            )
                            self.assertNotEqual(result.returncode, 0)
                            self.assertEqual(result.stdout, "")
                            self.add_tier_column(root)
    def test_ticket_exports_optional_description(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            description = "新增 e2e 文档。\n\n验收：文件存在且内容固定。"
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-102",
                    "--ticket-title",
                    "single ticket",
                    "--ticket-description",
                    description,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(
                payload["ticket"],
                {"id": "JT-102", "title": "single ticket", "description": description},
            )

    def test_ticket_description_requires_ticket_mode_and_nonempty_body(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            no_ticket = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-description",
                    "body",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(no_ticket.returncode, 0)
            self.assertEqual(no_ticket.stdout, "")
            self.assertIn("--ticket-description", no_ticket.stderr)

            empty = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-102",
                    "--ticket-description",
                    "  \n",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(empty.returncode, 0)
            self.assertEqual(empty.stdout, "")
            self.assertIn("ticket description", empty.stderr)

    def test_ticket_exports_pr_ready_completion_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            command = [
                sys.executable,
                str(root / "scripts/managed-export.py"),
                "--root",
                str(root),
                "--ticket-id",
                "JT-101",
            ]
            default = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(default.returncode, 0, default.stderr)
            pr_ready = subprocess.run(
                command + ["--completion-target", "pr_ready"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(pr_ready.returncode, 0, pr_ready.stderr)
            default_payload = json.loads(default.stdout)
            pr_ready_payload = json.loads(pr_ready.stdout)
            self.assertEqual(default_payload["completion_target"], "branch_ready")
            self.assertEqual(pr_ready_payload["completion_target"], "pr_ready")
            self.assertNotEqual(
                default_payload["content_digest"], pr_ready_payload["content_digest"]
            )

    def test_completion_target_requires_ticket_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(Path(directory))
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--completion-target",
                    "pr_ready",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("--completion-target", result.stderr)

    def test_ticket_rejects_missing_provider_missing_profile_and_bad_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            (root / PROVIDERS["verify"]).unlink()
            missing = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout, "")
            self.assertIn(PROVIDERS["verify"], missing.stderr)

            (root / PROVIDERS["verify"]).write_text("provider\n", encoding="utf-8")
            policy = json.loads((root / TOOL_POLICY).read_text(encoding="utf-8"))
            del policy["profiles"]["reviewer"]
            (root / TOOL_POLICY).write_text(json.dumps(policy), encoding="utf-8")
            no_profile = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(no_profile.returncode, 0)
            self.assertIn("reviewer", no_profile.stderr)

            bad_size = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--ticket-id",
                    "JT-101",
                    "--size",
                    "M",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(bad_size.returncode, 0)
            self.assertEqual(bad_size.stdout, "")

    def test_route_exports_five_sizes_templates_and_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["mode"], "route")
            self.assertEqual(payload["completion_target"], "pr_ready")
            self.assertEqual(
                [rule["size"] for rule in payload["route_rules"]],
                ["XS", "S", "M", "L", "XL"],
            )
            self.assertEqual(
                [rule["stage_path"] for rule in payload["route_rules"]],
                [["execute", "verify", "review", "land"]] * 5,
            )
            self.assertEqual(
                [rule["min_tickets"] for rule in payload["route_rules"]],
                [1, 1, 1, 2, 2],
            )
            self.assertEqual(
                [rule["max_tickets"] for rule in payload["route_rules"]],
                [1, 1, 3, 12, 20],
            )
            self.assertEqual(
                [stage["stage"] for stage in payload["stage_templates"]],
                ["execute", "verify", "review", "land"],
            )
            self.assertEqual(payload["instructions"]["plan"], "输出 ticket 图。\n")
            self.assertEqual(payload["archive_gate"], "evidence")
            self.assertEqual(len(payload["sources"]), 9)
            self.assertEqual(
                [source["path"] for source in payload["sources"]],
                [
                    ROUTE,
                    STAGES,
                    PLAN,
                    MUST_STOP,
                    TOOL_POLICY,
                    PROVIDERS["execute"],
                    PROVIDERS["verify"],
                    PROVIDERS["review"],
                    PROVIDERS["land"],
                ],
            )
            for source in payload["sources"]:
                content = (root / source["path"]).read_text(encoding="utf-8")
                self.assertEqual(
                    source["sha256"], hashlib.sha256(content.encode("utf-8")).hexdigest()
                )
                self.assertEqual(source["bytes"], len(content.encode("utf-8")))
            body = {key: value for key, value in payload.items() if key != "content_digest"}
            canonical = json.dumps(
                body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            self.assertEqual(payload["content_digest"], hashlib.sha256(canonical).hexdigest())

    def test_route_source_and_archive_gate_changes_update_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            command = [
                sys.executable,
                str(root / "scripts/managed-export.py"),
                "--root",
                str(root),
                "--route",
            ]
            initial_run = subprocess.run(
                command, text=True, capture_output=True, check=False
            )
            self.assertEqual(initial_run.returncode, 0, initial_run.stderr)
            initial = json.loads(initial_run.stdout)

            changed_plan = "先定依赖，再拆到 XS/S/M。\n"
            (root / PLAN).write_text(changed_plan, encoding="utf-8")
            changed_run = subprocess.run(
                command, text=True, capture_output=True, check=False
            )
            self.assertEqual(changed_run.returncode, 0, changed_run.stderr)
            changed = json.loads(changed_run.stdout)
            self.assertEqual(changed["instructions"]["plan"], changed_plan)
            self.assertNotEqual(initial["content_digest"], changed["content_digest"])
            initial_plan = next(
                source for source in initial["sources"] if source["path"] == PLAN
            )
            changed_plan_source = next(
                source for source in changed["sources"] if source["path"] == PLAN
            )
            self.assertNotEqual(initial_plan["sha256"], changed_plan_source["sha256"])
            self.assertEqual(
                changed_plan_source["sha256"],
                hashlib.sha256(changed_plan.encode("utf-8")).hexdigest(),
            )

            stages = (root / STAGES).read_text(encoding="utf-8")
            (root / STAGES).write_text(
                stages.replace(
                    "| archive | closed | evidence |",
                    "| archive | closed | archive evidence |",
                ),
                encoding="utf-8",
            )
            gate_run = subprocess.run(
                command, text=True, capture_output=True, check=False
            )
            self.assertEqual(gate_run.returncode, 0, gate_run.stderr)
            gate_changed = json.loads(gate_run.stdout)
            self.assertEqual(gate_changed["archive_gate"], "archive evidence")
            self.assertNotEqual(changed["content_digest"], gate_changed["content_digest"])

    def test_route_requires_plan_archive_and_all_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            (root / PLAN).unlink()
            missing_plan = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing_plan.returncode, 0)
            self.assertEqual(missing_plan.stdout, "")
            self.assertIn(PLAN, missing_plan.stderr)

            outside = root.parent / "outside-plan.md"
            outside.write_text("伪造来源\n", encoding="utf-8")
            (root / PLAN).symlink_to(outside)
            forged_plan = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(forged_plan.returncode, 0)
            self.assertEqual(forged_plan.stdout, "")
            self.assertIn("越出仓库根目录", forged_plan.stderr)

            (root / PLAN).unlink()
            (root / PLAN).write_text("输出 ticket 图。\n", encoding="utf-8")
            route = (root / ROUTE).read_text(encoding="utf-8")
            (root / ROUTE).write_text(
                route.replace("| XL | many sessions | plan with wayfinder, L for each cleared area |\n", ""),
                encoding="utf-8",
            )
            missing_size = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing_size.returncode, 0)
            self.assertIn("XL", missing_size.stderr)

            (root / ROUTE).write_text(route, encoding="utf-8")
            stages = (root / STAGES).read_text(encoding="utf-8")
            (root / STAGES).write_text(
                stages.replace(
                    "| archive | closed | evidence | `flow:archive` | `archivist` |",
                    "| archive | closed |  | `flow:archive` | `archivist` |",
                ),
                encoding="utf-8",
            )
            missing_gate = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing_gate.returncode, 0)
            self.assertEqual(missing_gate.stdout, "")
            self.assertIn("archive 阶段缺少 gate", missing_gate.stderr)

            (root / STAGES).write_text(stages, encoding="utf-8")
            (root / STAGES).write_text(
                stages.replace(
                    "| archive | closed | evidence | `flow:archive` | `archivist` |\n", ""
                ),
                encoding="utf-8",
            )
            missing_archive = subprocess.run(
                [
                    sys.executable,
                    str(root / "scripts/managed-export.py"),
                    "--root",
                    str(root),
                    "--route",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(missing_archive.returncode, 0)
            self.assertIn("archive", missing_archive.stderr)

    def test_route_rejects_ticket_only_options(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            for option in (["--ticket-id", "JT-101"], ["--size", "S"]):
                with self.subTest(option=option[0]):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(root / "scripts/managed-export.py"),
                            "--root",
                            str(root),
                            "--route",
                            *option,
                        ],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("--route", result.stderr)

    def test_ticket_digest_changes_when_stage_content_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.ticket_fixture(Path(directory))
            command = [
                sys.executable,
                str(root / "scripts/managed-export.py"),
                "--root",
                str(root),
                "--ticket-id",
                "JT-101",
            ]
            first = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            initial = json.loads(first.stdout)
            (root / PROVIDERS["execute"]).write_text("changed provider\n", encoding="utf-8")
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(second.returncode, 0, second.stderr)
            changed = json.loads(second.stdout)
            self.assertNotEqual(initial["content_digest"], changed["content_digest"])
            self.assertNotEqual(
                initial["stages"][0]["content_digest"], changed["stages"][0]["content_digest"]
            )


if __name__ == "__main__":
    unittest.main()
