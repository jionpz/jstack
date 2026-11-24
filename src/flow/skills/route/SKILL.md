---
name: route
description: Entry point for software engineering work in a code repository. Use at the start of any task that would change code or answer a question about it, such as a feature, bug fix, refactor, migration, or investigation. It sizes the task and walks it through the jstack stages (clarify, plan, investigate, execute, verify, review, land, archive), handing each stage to its provider. Skip it for non-engineering requests, and skip it when the user has already invoked a pstack or spec entry skill directly.
argument-hint: "<task description>"
---

# Route

You drive a task through the jstack stages so the user does not have to pick commands. [stages.md](stages.md), next to this file, is the single source of truth: each stage, the output it must produce, the gate it must pass, and the provider that does the work. Read it now. The execute stage's provider is the only executor: `flow:execute` for one task or ticket, `pstack:poteto-mode` when the path has many independent tickets or the work is multi-day. spec output is input to it, never a second plan to run in parallel.

## 1. Locate the providers

Run `locate.sh`, which sits next to this SKILL.md. In Claude Code, run `"${CLAUDE_SKILL_DIR}/locate.sh"`. In another harness, take the absolute path the harness gave for this SKILL.md and replace `SKILL.md` with `locate.sh`.

It prints one line per provider in stages.md, as `provider<TAB>absolute path`. Many providers are marked `disable-model-invocation: true`, so the harness will not launch them as model-invoked skills. Read the file at the printed path and follow it as if the user had invoked that skill, with the task as its argument. Relative links inside it resolve from that file's directory. If it reports a missing provider, name it to the user. Stop only when that provider's stage is on this task's path; otherwise continue and mention the gap in the finish report.

The Tool profile column in stages.md names a profile in `tool-policy.json`, next to it. Together they declare what each role needs and how a harness maps it to native tools; they do not change the tools of the current interactive session. A managed launcher exports the policy with `./jstack tools export` and resolves a stage with `./jstack tools resolve` from the jstack checkout. Shell fallback and optional tools follow `docs/harness/tools.md`. Never claim a profile is enforced when the harness was not launched with that tool set.

When you tell the user how to invoke a skill directly, use this table.

| Harness | Invocation |
|---|---|
| Claude Code | `/flow:<name>`, `/pstack:<name>`, or `/spec:<name>` |
| Pi, OMP | `/skill:<name>` |
| Cursor | `/<name>` |
| Codex | `$flow:<name>`, `$pstack:<name>`, or `$spec:<name>`; the `/skills` picker also works |

## 2. Size the task and pick the stage path

Decide from the request and a quick look at the repo. Do not ask the user to size it.

| Size | Signals | Stage path |
|---|---|---|
| XS / S | One file or a few lines, a known bug, copy or config change | execute, verify, land, archive |
| M, clear | One module, behavior and boundaries are clear | execute, verify, review, land, archive |
| M, ambiguous | Two or more reasonable readings that change what gets built | clarify, execute, verify, review, land, archive |
| L | A new module, cross-module change, or several features | clarify, plan, then execute, verify, review, land for each ticket, then archive |
| XL | More than one session can hold, or many decisions are still unknown | plan with wayfinder, then L for each cleared area; handoff when the session must end |
| Question | An investigation, a "why" or "how does" question, or a PR-status request, at any size | investigate only. The cited answer or the PR state is the output |

When the repo's own CLAUDE.md or `.claude/rules/` defines different sizes, spec locations, or gates, the repo wins.

State the size and the stage path in one sentence. Then record the path with `stage.sh` (next section) and open a todo list with one item per stage on the path, each naming its gate from stages.md. Start without waiting for confirmation.

## 3. Walk the stages

`stage.sh` sits next to this SKILL.md and records where the task is, so the flow hooks and extensions can enforce the gates structurally. In Claude Code, run it as `"${CLAUDE_SKILL_DIR}/stage.sh"`. Claude Code, Cursor, Pi, OMP, and Codex support these gates when their hooks or extensions are loaded and trusted. Codex uses project `.codex/hooks.json` and requires hook trust. Workloop records state, but has no Stop hook, so nothing enforces the gates there: before you end the turn, run `stage.sh show` and check the evidence yourself.

Pi and OMP carry the gates through the flow extension. A session id or a hook configuration file alone does not prove that the gates ran: Pi and Codex can still have a session id when an extension is missing or untrusted. Look for `jstack 提示门禁注入：session=<id>` in the context actually injected by the harness for this session. The prompt hook emits this receipt even before a task has stage state. Reading the hook source or manually calling it is not receipt of an injection. If no receipt was received, report prompt injection as unobserved; do not infer success from `stage.sh start` working. A receipt proves only the prompt hook ran, not that Stop or guard are active. Report those separately as observed only if the harness actually enforced them, otherwise unverified. A "no session id" notice means stage tracking is off. Workloop must always be reported as unenforced. None of these cases requires stopping useful work.

| When | Command |
|---|---|
| Right after sizing | `stage.sh start --size <XS\|S\|M\|L\|XL\|Question> [--ticket <ref>] <stage>,<stage>,...` with the path in order. For a Git checkout with Python 3.9+ and an XS/S route containing `execute,verify,land` with a `review` provider available, append `--recheck-size` before the first edit. |
| Entering each stage | `stage.sh enter <stage> [--ticket <ref>]`; pass `--ticket` when picking up a ticket not known at start |
| Starting a known ticket in a new session | `stage.sh resume --ticket <ref>` before `start`, then `stage.sh resume <run-id> --from-session <old-session> --ticket <current-ticket>` after the worktree and ownership check |
| The size changes after start | `stage.sh size <XS\|S\|M\|L\|XL\|Question>` |
| In `verify`, when the required checks pass | `stage.sh evidence "<verifier/context id>: <command> -> <observation>; verdict: pass"` for each report (stage-scoped) |
| In `verify`, when the repo configures `verify.command` | `stage.sh verify` |
| During `review`, for each finding | `stage.sh review finding F1 "<finding>"`, then `stage.sh review resolution F1 fixed|dismissed "<reason>"` |
| When review is complete | `stage.sh review complete "<conclusion>"` (explicit zero findings if none) |
| During `land` | `stage.sh land commit <SHA>`; if the repo has a remote, also `stage.sh land pr <PR URL>` |
| A decision you settled with a default instead of asking | `stage.sh default "<decision> -> <why>"` |
| Right before a real interruption | `stage.sh ask "<exact question?>"`; ask the same question in the reply |
| When the task is ready for its finish report | `stage.sh end --report-file <markdown or ->`; plain `stage.sh end` is only for a user-requested local-only finish |
| The task stops at PR-ready with the after-merge archive still owed | `stage.sh pending "<PR URL> <what is left>"` |
| The after-merge archive for a merged PR is done | `stage.sh settled <PR URL>` |

Delegated workers should return results to the main session; they must not use `stage.sh start`, `stage.sh end`, or `stage.sh evidence` to modify the parent session. A repeated `start` with the same path preserves existing state; a new path cannot silently replace active work. Bash hooks can identify `agent_id` on supported Claude Code tool events and Pi/OMP extensions identify subagents, but shell wrappers or untrusted hooks are **not** a sandbox: treat isolation as best-effort and keep the main session responsible for recording each result.

A repo's `.jstack/config.json` can replace the stage table (`stages_file`) and add must-stop entries. The "仓库配置" line the harness injects each turn shows the values in effect; drop any stage on your path that the table no longer has, and leave `stage.sh start` to reject stages outside its table. If filtering leaves an empty path, report the missing configured stage and do not call start with an empty path. A Question remains read-only when a custom table omits investigate; answer from inspected evidence rather than switching to execute.

On a short route with size recheck enabled, `stage.sh enter verify` compares the candidate against the checkout before execution. Crossing directory modules, changing more than three paths, or touching standard interface, hook, or policy paths adds `review` between `verify` and `land`. Treat the expanded path as at least M, update the todo list, and run the review provider before land. Re-entering execute or shrinking the diff keeps the added review. Repository-specific API boundaries and must-stop actions still follow the repository's rules. When Git, Python, or a configured review stage is unavailable, report that automatic recheck is unavailable.

Once execute has started, the Stop gate checks **each stage on the selected path**: `verify` needs a passing command receipt when configured, or evidence recorded *after entering verify* otherwise. `review` needs a completed conclusion and a fixed/dismissed disposition for every recorded finding. `land` needs a commit SHA plus a PR URL if the repository has a remote. The CLI `stage.sh end` applies the same checks before deleting state. Route also requires the verifier reports prescribed by `flow:verify`; the Stop hook does not check their context or quorum. A free-form evidence entry from `execute` cannot satisfy later stages. Entering execute for the next ticket invalidates older evidence/review/land receipts. Record actual results, not placeholders. To interrupt for a human decision, queue a concrete question with `stage.sh ask "<exact question?>"` and include that question verbatim in the final reply; a random question mark does not suffice. Cursor cannot inspect the reply and therefore relies only on a queued question; report that degradation. Never drop verify just because the user asks to skip tests.

With a configured `verify.command`, the gate requires the verifier's result for the current Git snapshot. Run `stage.sh verify` before landing. Stop starts the same verifier automatically. If Stop reports that it is still running, `stage.sh verify` waits for the result. `stage.sh show` displays the receipt. Use `stage.sh verify --retry` to repeat a check after a transient failure.

For a known ticket in a new session, run the `resume --ticket` query before `start`. It lists unfinished runs with their session, worktree, current ticket, stage, and saved evidence; an unfinished record alone does not prove its owner is gone. Take over only after an explicit handoff or after confirming the old session exited. In the recorded worktree, inspect Git HEAD and status, the tracker, and any PR URLs or branches already used; do not reopen or re-close completed work. Then run `resume <run-id> --from-session <old-session> --ticket <current-ticket>`. The takeover keeps the run ID and prior receipts, marks old gate evidence as historical, and returns to `verify` when the old stage was verify or later. Run the real check again before continuing.

Take the stages in path order. For each one, read its providers from the locate output and follow them, then check the stage's gate. Mark a stage done only when its gate is met, and write its output into the todo item: a decision list, a spec path, a commit, the verification command and what it showed.

- **clarify, plan.** Follow the spec providers, but not every plan provider runs every time. L runs to-spec then to-tickets. XL runs wayfinder first. setup-matt-pocock-skills runs only when `docs/agents/issue-tracker.md` is missing: follow it first and put its questions into the first clarification round, each with its recommended answer (local markdown when the repo has no GitHub or GitLab remote, otherwise that host). handoff runs only when the session must end before the work does.
- **investigate.** Follow the table's investigation provider and produce a cited answer from inspected evidence. This path has no execute, verify, review, land, or archive requirement and does not create a code change or PR. If the user later requests an implementation, size that new task and start its change path.
- **review.** `flow:review` is the default: reread the diff against the task, fix or dismiss each finding. Run `pstack:interrogate` only when the gate calls for an adversarial review — a design decision on this task was contested (the user pushed back, or clarify settled it by default over a real alternative), the change touches the must-stop list, or the user asked for one. `pstack:swarm` runs only when the gate calls for an adversarial review by a swarm of reviewers of a contested design.
- **execute.** Follow the execute provider the table names. Run author checks before handing the candidate to route. If an execute playbook also describes opening a PR, run that part at land, after the verify and review gates. A self-review counts for review only if, after entering `review`, each finding and its fix/dismissal are recorded with `stage.sh review` and a `review complete` conclusion is present (explicitly zero findings if none). If that record is absent, run `flow:review`. Do not repeat a provider when its required output already exists. The absence of a contested design is not review evidence, and the absence of a must-stop action is not a PR.
- **verify.** Follow `flow:verify` with the task size, acceptance criteria, and candidate. Give verifiers only the task, diff or base/head, run instructions, and applicable project constraints. XS runs direct checks. S and M use one fresh bulk verifier; L or a must-stop change uses two independent fresh verifiers. Accept only `pass`, `fail`, or `blocked` reports with commands and observations; disagreement, failure, missing reports, or blocked returns to execute. After a change, enter verify again and use new contexts. Once all required reports pass, record each with `stage.sh evidence` and obtain the configured command receipt when applicable. Author checks from execute cannot satisfy this gate.
- **land.** In a repo with no remote, commits on a branch meet the gate. Never push or open a PR for a repo the user did not point you at. With a remote, land ends at **PR-ready**: the PR is open, verify and review passed, and its CI is green on the head commit you verified. A local commit alone leaves land unmet. When entering `land`, record `stage.sh land commit <SHA>` and, when there is a remote, `stage.sh land pr <PR URL>` after actually creating the PR. These are required output receipts, not proof of green CI; check CI separately. Wait for CI once (for GitHub, `gh pr checks <n> --watch`); do not poll in a loop. Red CI sends the task back to execute (`stage.sh enter execute`), fix, verify again, push; that is routine work, not a reason to interrupt the user. CI that cannot finish (no runner, an outage) leaves the task not PR-ready, and the report says so. An explicit user instruction to merge or push directly replaces the PR requirement for that task; record the resulting commit and destination. The flow stops at PR-ready: merging is the user's click. Merge a PR only when the user's current message names that PR, and merge only that one; a fix needed after a merge gets its own PR, which also stops at PR-ready. Never turn on auto-merge unasked.
- **archive.** Follow the archive providers. Archive has two parts. Before merge, in this session: GLOSSARY.md and ADRs, gbrain, lessons. After merge: close the tickets with evidence and clean the merged worktrees. When the PR is still open at the end of the task, record the second part with `stage.sh pending "<PR URL> <what is left>"` instead of doing it. `stage.sh start` prints the repo's pending entries at the start of the next task: check each PR, finish the after-merge part for the merged ones and run `stage.sh settled <PR URL>`, and leave the unmerged ones alone. A repo with no remote has no PR to wait for, so both parts run together. The gate is in stages.md.
- **A stage whose provider is `-`**: write one line, `Skipped: <stage> has no provider yet.`, and go on.

For L, work the ticket frontier: a ticket starts only when every ticket that blocks it is done. Run execute through land once per ticket, and mark the ticket done in the tracker when its verify gate passes. Many independent tickets, or a multi-day effort, use the `pstack:poteto-mode` provider's Orchestrate or Multi-phase plan playbook instead of one ticket at a time.

Hand the execute provider what the earlier stages produced: the task in the user's words, the spec path or issue URL, the tickets in dependency order, the decisions settled in clarify, and any ADR or GLOSSARY.md entries written.

## 4. Human checkpoints

Human attention is the most expensive resource here. Interrupt the user only for a decision that is theirs to make; everything else takes the default you would recommend, recorded so they can correct it later (ADR-0004).

1. **Must-stop actions**, at any size and under any autonomy grant: everything in [must-stop.md](must-stop.md), next to this file, plus every entry in the repo config's `must_stop`. The plugin list is the only built-in list. The flow guard hook asks when the harness supports confirmation; Codex and Cursor's `preToolUse` deny, and Pi/OMP without UI block. User approval does not change that denial: give the approved command to the user to execute themselves; do not rerun it through another tool or evade the guard. Commands without a detectable pattern still need your judgment. Collect decisions and ask them in one round, each with options and a recommendation. Delegating counts as doing it: a subagent brief must not authorize a must-stop action, because the guard sees your own shell commands, not the brief's text, and the subagent may run without the gates. To update a stacked branch from its parent, merge the parent in and push normally; a rebase plus force push is not a routine update.

2. **Decisions the evidence cannot settle.** Look facts up yourself. When a fork is a fact you can observe by running something (behavior, timing, layout, output, a prototype), settle it that way and record the result instead of asking. Ask only when the evidence cannot settle a product or preference call and at least one of these holds: undoing the choice would be expensive, the request has two readings that change what gets built, or the choice reaches users, production, or another system. Otherwise take the default you would recommend, record it with `stage.sh default "<decision> -> <why>"`, and report it under 采用的默认决定 in the finish summary. The user reads it and tells you what to change; no reply word needed.

3. **Breakdowns.** Publish an L or XL breakdown without a sign-off unless the breakdown itself carries a high-risk disagreement: an order or scope that would be costly to change later, a testing seam the evidence cannot settle, or a must-stop action. Only then present the spec's testing seams and the ticket breakdown together in one message, before you publish either.

4. **One round.** Collect every open question, but never hold back work that does not depend on the answer. When a ticket is waiting on the user, mark it `needs-human` in the tracker (GitHub: `gh issue edit <n> --add-label needs-human`, creating the label once with `gh label create needs-human` if the repo lacks it; local markdown: set `**Status:** needs-human`), keep working the tickets that do not depend on it, and ask the queued questions together in one round, numbered, each with your recommended answer, worded so "yes" accepts it. Remove the label once answered. The notification channel is a replaceable provider: Paseo when the session runs under it, the tracker label alone otherwise.

Clarification rounds follow the same rule: only decisions reach the user, and a question you can answer by observing something never does. The execute provider's own autonomy rules still apply, including the Always-pause list in [must-stop.md](must-stop.md).


## 5. Finish

End with one summary the user can read on a phone, in this order:

```
目标：<one line>
状态：<exactly one of: PR-ready（<PR URL>，CI 通过，等你合并） / done（已合并、已归档） / 未完成（<what is missing: red or unfinished CI, an unmet gate, a waiting question>）. A question-only task writes 已回答. A repo with no remote is done when the commits are on the branch and archive ran>
改了什么：<tickets closed, commits, files; a stage whose gate was never met is named here as not done, with what is missing>
验证：<the commands you ran and what they showed>
采用的默认决定：<every stage.sh default, with its reason; 无 when none>
需要你处理：<every queued question and needs-human ticket; 无 when none>
门禁：<always report prompt injection as observed or unobserved; Stop/guard as actually observed or unverified; no session id means tracking inactive; Workloop means unenforced>
```

Every adopted default and every queued question must appear; they are how the user corrects you later. Do not restate the code or the ticket. Never write PR-ready for a PR whose CI is red, still running, or not checked, and never write done while the PR is open or the after-merge archive is still pending.

Before replying, write a short Markdown excerpt with `## 目标`, `## 状态`, `## 改动`, and `## 需要你处理`, then pass it to `stage.sh end --report-file -` with a quoted heredoc. The command adds `## 验证` and `## 默认决定`, archives the run locally, then posts an issue comment, updates the bounded summary section in its PR body, or appends that section to the local Markdown ticket. Use the run ID in the command output to retry a failed publish with `./jstack report <run-id>` from the same repository; the local record stays available when the network or tracker write fails. When returning to a ticket, read its latest run-report comment: a plain reply there can override a default.

## Never

- Never use Matt Pocock's implement, implement-spec, or ask-matt skills, even if they are installed. Execution belongs to the execute stage's provider.
- Never run clarify or plan for XS, S, or clear M work just to have a spec.
- Never ask the user which command or workflow to run.
- Never guess a provider's path. Every provider comes from stages.md through locate.sh.
- Never merge a PR, or turn on auto-merge, unless the user's current message names that PR. An earlier "merge" does not cover a later PR.
