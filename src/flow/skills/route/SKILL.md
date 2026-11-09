---
name: route
description: Entry point for software engineering work in a code repository. Use at the start of any task that would change code or answer a question about it, such as a feature, bug fix, refactor, migration, or investigation. It sizes the task and walks it through the jstack stages (clarify, plan, execute, verify, review, land, archive), handing each stage to its provider. Skip it for non-engineering requests, and skip it when the user has already invoked a pstack or spec entry skill directly.
argument-hint: "<task description>"
---

# Route

You drive a task through the jstack stages so the user does not have to pick commands. [stages.md](stages.md), next to this file, is the single source of truth: each stage, the output it must produce, the gate it must pass, and the provider that does the work. Read it now. The execute stage's provider is the only executor: `flow:execute` for one task or ticket, `pstack:poteto-mode` when the path has many independent tickets or the work is multi-day. spec output is input to it, never a second plan to run in parallel.

## 1. Locate the providers

Run `locate.sh`, which sits next to this SKILL.md. In Claude Code, run `"${CLAUDE_SKILL_DIR}/locate.sh"`. In another harness, take the absolute path the harness gave for this SKILL.md and replace `SKILL.md` with `locate.sh`.

It prints one line per provider in stages.md, as `provider<TAB>absolute path`. Many providers are marked `disable-model-invocation: true`, so the harness will not launch them as model-invoked skills. Read the file at the printed path and follow it as if the user had invoked that skill, with the task as its argument. Relative links inside it resolve from that file's directory. If it reports a missing provider, name it to the user. Stop only when that provider's stage is on this task's path; otherwise continue and mention the gap in the finish report.

When you tell the user how to invoke a skill directly, use this table.

| Harness | Invocation |
|---|---|
| Claude Code | `/pstack:<name>` or `/spec:<name>` |
| Pi, OMP | `/skill:<name>` |
| Cursor | `/<name>` |

## 2. Size the task and pick the stage path

Decide from the request and a quick look at the repo. Do not ask the user to size it.

| Size | Signals | Stage path |
|---|---|---|
| XS / S | One file or a few lines, a known bug, copy or config change | execute, verify, land, archive |
| M, clear | One module, behavior and boundaries are clear | execute, verify, review, land, archive |
| M, ambiguous | Two or more reasonable readings that change what gets built | clarify, execute, verify, review, land, archive |
| L | A new module, cross-module change, or several features | clarify, plan, then execute, verify, review, land for each ticket, then archive |
| XL | More than one session can hold, or many decisions are still unknown | plan with wayfinder, then L for each cleared area; handoff when the session must end |
| Question | An investigation, a "why" or "how does" question, or a PR-status request, at any size | execute only. The cited answer or the PR state is the output |

When the repo's own CLAUDE.md or `.claude/rules/` defines different sizes, spec locations, or gates, the repo wins.

State the size and the stage path in one sentence. Then record the path with `stage.sh` (next section) and open a todo list with one item per stage on the path, each naming its gate from stages.md. Start without waiting for confirmation.

## 3. Walk the stages

`stage.sh` sits next to this SKILL.md and records where the task is, so the flow hooks and extensions can enforce the gates structurally. In Claude Code, run it as `"${CLAUDE_SKILL_DIR}/stage.sh"`. Claude Code, Cursor, Pi, and OMP all carry the gates; a harness without them (Codex) prints a notice and does nothing, so run it anyway. Workloop records state, but has no Stop hook, so nothing enforces the gates there: before you end the turn, run `stage.sh show` and check the evidence yourself.

Pi and OMP carry the gates through the flow extension; if it is not installed, `stage.sh` prints the same "no session id" notice. Either kind of notice means the gates are off for this session, and the finish report must say so.

| When | Command |
|---|---|
| Right after sizing | `stage.sh start <stage>,<stage>,...` with the path in order |
| Entering each stage | `stage.sh enter <stage>` |
| Each piece of verification evidence | `stage.sh evidence "<command> -> <what it showed>"` |
| A decision you settled with a default instead of asking | `stage.sh default "<decision> -> <why>"` |
| Right before you stop to ask the user anything | `stage.sh ask` |
| After the finish report | `stage.sh end` |

A repo's `.jstack/config.json` can replace the stage table (`stages_file`) and add must-stop entries. The "仓库配置" line the harness injects each turn shows the values in effect; drop any stage on your path that the table no longer has, and leave `stage.sh start` to reject stages outside its table.

Once execute has started on a path that includes verify, the harness will not let you end the turn until evidence is recorded, or until you have run `stage.sh ask` and your reply asks the user a question. Entering execute again, as for the next ticket, clears the earlier evidence. Record real evidence; never record a placeholder or ask a token question to get past the gate.

Take the stages in path order. For each one, read its providers from the locate output and follow them, then check the stage's gate. Mark a stage done only when its gate is met, and write its output into the todo item: a decision list, a spec path, a commit, the verification command and what it showed.

- **clarify, plan.** Follow the spec providers, but not every plan provider runs every time. L runs to-spec then to-tickets. XL runs wayfinder first. setup-matt-pocock-skills runs only when `docs/agents/issue-tracker.md` is missing: follow it first and put its questions into the first clarification round, each with its recommended answer (local markdown when the repo has no GitHub or GitLab remote, otherwise that host). handoff runs only when the session must end before the work does.
- **review.** `flow:review` is the default: reread the diff against the task, fix or dismiss each finding. Run `pstack:interrogate` only when the gate calls for an adversarial review — a design decision on this task was contested (the user pushed back, or clarify settled it by default over a real alternative), the change touches the must-stop list, or the user asked for one. `pstack:swarm` runs only when the gate calls for an adversarial review by a swarm of reviewers of a contested design.
- **execute.** Follow the execute provider the table names. `flow:execute` covers verify and a self-review; `pstack:poteto-mode` also runs verification, review, and Opening a PR through its playbook, so do not run those a second time when it did. When the executor finishes, check the gate of each later stage on the path against what now exists. Run a stage's provider only for a gate that is still unmet, then check again.
- **land.** In a repo with no remote, commits on a branch meet the gate. Never push or open a PR for a repo the user did not point you at.
- **archive.** Follow the archive providers. The archive skill closes tickets with evidence, updates GLOSSARY.md and ADRs, writes back to gbrain, and routes lessons; the worktree playbook cleans merged worktrees. The gate is in stages.md.
- **A stage whose provider is `-`**: write one line, `Skipped: <stage> has no provider yet.`, and go on.

For L, work the ticket frontier: a ticket starts only when every ticket that blocks it is done. Run execute through land once per ticket, and mark the ticket done in the tracker when its verify gate passes. Many independent tickets, or a multi-day effort, use the `pstack:poteto-mode` provider's Orchestrate or Multi-phase plan playbook instead of one ticket at a time.

Hand the execute provider what the earlier stages produced: the task in the user's words, the spec path or issue URL, the tickets in dependency order, the decisions settled in clarify, and any ADR or GLOSSARY.md entries written.

## 4. Human checkpoints

Human attention is the most expensive resource here. Interrupt the user only for a decision that is theirs to make; everything else takes the default you would recommend, recorded so they can correct it later (ADR-0004).

1. **Must-stop actions**, at any size and under any autonomy grant: everything in [must-stop.md](must-stop.md), next to this file, plus every entry in the repo config's `must_stop`. The plugin list is the only built-in list. The flow guard hook makes the harness ask before the shell commands it can detect; the rest you must recognize yourself. Collect these and ask them in one round, each with options and a recommendation. Delegating counts as doing it: a subagent brief must not authorize a must-stop action, because the guard sees your own shell commands, not the brief's text, and the subagent may run without the gates. Do that step yourself once the user approves, or leave it out of the brief and ask first. To update a stacked branch from its parent, merge the parent in and push normally; a rebase plus force push is not a routine update.

2. **Decisions the evidence cannot settle.** Look facts up yourself. When a fork is a fact you can observe by running something (behavior, timing, layout, output, a prototype), settle it that way and record the result instead of asking. Ask only when the evidence cannot settle a product or preference call and at least one of these holds: undoing the choice would be expensive, the request has two readings that change what gets built, or the choice reaches users, production, or another system. Otherwise take the default you would recommend, record it with `stage.sh default "<decision> -> <why>"`, and report it under 采用的默认决定 in the finish summary. The user reads it and tells you what to change; no reply word needed.

3. **Breakdowns.** Publish an L or XL breakdown without a sign-off unless the breakdown itself carries a high-risk disagreement: an order or scope that would be costly to change later, a testing seam the evidence cannot settle, or a must-stop action. Only then present the spec's testing seams and the ticket breakdown together in one message, before you publish either.

4. **One round.** Collect every open question, but never hold back work that does not depend on the answer. When a ticket is waiting on the user, mark it `needs-human` in the tracker (GitHub: `gh issue edit <n> --add-label needs-human`, creating the label once with `gh label create needs-human` if the repo lacks it; local markdown: set `**Status:** needs-human`), keep working the tickets that do not depend on it, and ask the queued questions together in one round, numbered, each with your recommended answer, worded so "yes" accepts it. Remove the label once answered. The notification channel is a replaceable provider: Paseo when the session runs under it, the tracker label alone otherwise.

Clarification rounds follow the same rule: only decisions reach the user, and a question you can answer by observing something never does. The execute provider's own autonomy rules still apply, including the Always-pause list in [must-stop.md](must-stop.md).


## 5. Finish

End with one summary the user can read on a phone, in this order, then run `stage.sh end`:

```
目标：<one line>
改了什么：<tickets closed, commits, files; a stage whose gate was never met is named here as not done, with what is missing>
验证：<the commands you ran and what they showed>
采用的默认决定：<every stage.sh default, with its reason; 无 when none>
需要你处理：<every queued question and needs-human ticket; 无 when none>
门禁：<only when stage.sh reported no session id or Workloop: the stage gates were not active / not enforced in this session>
```

Every adopted default and every queued question must appear; they are how the user corrects you later. Do not restate the code or the ticket.

## Never

- Never use Matt Pocock's implement, implement-spec, or ask-matt skills, even if they are installed. Execution belongs to the execute stage's provider.
- Never run clarify or plan for XS, S, or clear M work just to have a spec.
- Never ask the user which command or workflow to run.
- Never guess a provider's path. Every provider comes from stages.md through locate.sh.
