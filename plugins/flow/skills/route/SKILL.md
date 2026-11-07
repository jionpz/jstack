---
name: route
description: Entry point for software engineering work in a code repository. Use at the start of any task that would change code or answer a question about it, such as a feature, bug fix, refactor, migration, or investigation. It sizes the task and hands it to the right jstack workflow (spec for clarifying and breaking down, pstack poteto-mode for execution). Skip it for non-engineering requests, and skip it when the user has already invoked a pstack or spec entry skill directly.
argument-hint: "<task description>"
---

# Route

You connect two plugins so the user does not have to pick commands. `spec` clarifies and breaks work down. `pstack` executes. pstack's poteto-mode is the only orchestrator: spec output is input to it, never a second plan to execute in parallel.

## 1. Locate the entry skills

Run `locate.sh`, which sits next to this SKILL.md. In Claude Code, run `"${CLAUDE_SKILL_DIR}/locate.sh"`. In another harness, take the absolute path the harness gave for this SKILL.md and replace `SKILL.md` with `locate.sh`.

It prints one line per entry skill, as `name<TAB>absolute path`. These skills are marked `disable-model-invocation: true`, so the harness will not let you launch them as model-invoked skills. Instead, read the SKILL.md at the printed path and follow it as if the user had invoked that skill, with the task as its argument. Relative links inside it resolve from that file's directory. If the script fails, tell the user which plugin is missing and stop.

Every harness loads the same skill names but invokes them differently. Refer to skills by name in this workflow. Use this table when you tell the user how to invoke one directly.

| Harness | Invocation |
|---|---|
| Claude Code | `/pstack:<name>` or `/spec:<name>` |
| Pi | `/skill:<name>` |
| OMP | `/skill:<name>` |
| Cursor | `/<name>` |

## 2. Size the task

Decide from the request and a quick look at the repo. Do not ask the user to size it.

| Size | Signals | Route |
|---|---|---|
| XS / S | One file or a few lines, a known bug, copy or config change | poteto-mode |
| M, clear | One module, behavior and boundaries are clear | poteto-mode |
| M, ambiguous | The request has two or more reasonable readings that change what gets built | grill-with-docs, then poteto-mode |
| L | A new module, cross-module change, or several features | grill-with-docs, to-spec, to-tickets, then poteto-mode per ticket |
| XL | More than one session can hold, or many decisions are still unknown | wayfinder, then L for each cleared area; handoff when the session must end |

An investigation, a "why" or "how does" question, or a PR-status request is always poteto-mode, whatever its size. When the repo's own CLAUDE.md or `.claude/rules/` defines different sizes, spec locations, or gates, the repo wins.

State the size and route in one sentence, then start. Do not wait for confirmation.

## 3. Prerequisite for spec

to-spec, to-tickets, and wayfinder need `docs/agents/issue-tracker.md`. If it is missing, follow setup-matt-pocock-skills first. Put its questions into the first question round below, each with its recommended answer: local markdown when the repo has no GitHub or GitLab remote, otherwise that host. Never let setup add its own separate round.

## 4. Human checkpoints

Ask the user only at these points. Everything else proceeds.

1. **Clarification round.** grill-with-docs asks in rounds. Each round lists every open question at once, numbered, with your recommended answer, worded so "yes" accepts it. Look facts up yourself; only decisions reach the user.
2. **Breakdown sign-off (L and XL only).** Present the spec's testing seams and the ticket breakdown together in one message, before you publish either. This single approval covers both to-spec's seam check and to-tickets' quiz.
3. **Always-pause decisions**, at any size. A business rule or product behavior the evidence cannot settle, a breaking public API or schema change, irreversible data operations, production, permissions, or security changes, a major architecture change with no ADR, and cost, legal, or privacy exposure. Collect these and ask them in one round, each with options and a recommendation.

Once the user approves the breakdown, execute without further check-ins. poteto-mode's own Autonomy section still applies, including its Always-pause list.

## 5. Hand off to poteto-mode

Read poteto-mode's SKILL.md and follow it. Its first message restates the goal. Pass along what the earlier steps produced:

- The task, in the user's words.
- The spec path or issue URL, and the ticket paths or issue numbers in dependency order.
- Decisions settled in the clarification round, and any ADRs or GLOSSARY.md entries written.

For L, work the frontier: a ticket starts only when every ticket that blocks it is done. Run one poteto-mode playbook per ticket, and mark each ticket done in the tracker when its verification passes. Many independent tickets, or a multi-day effort, route to poteto-mode's Orchestrate or Multi-phase plan playbook instead of one ticket at a time.

## Never

- Never use Matt Pocock's implement, implement-spec, or ask-matt skills, even if they are installed. Execution belongs to poteto-mode.
- Never run spec steps for XS, S, or clear M work just to have a spec.
- Never ask the user which command or workflow to run.
