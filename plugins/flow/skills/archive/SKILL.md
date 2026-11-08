---
name: archive
description: "Close out a finished jstack task: close tickets with their evidence, keep GLOSSARY.md and ADRs current, write back to gbrain, clean merged worktrees, and route each lesson. Invoked by flow:route at the archive stage; not for mid-task cleanup."
disable-model-invocation: true
---

# Archive

The archive stage's provider. Work through the sections in order. Skip a section that does not apply, and say which and why in the report.

## 1. Close the tickets

Read `docs/agents/issue-tracker.md` for where tickets live. If it is missing, use the tracker the task actually used.

- **GitHub issues:** `gh issue close <n> --repo <owner/repo> --comment "<evidence>"`, where the evidence names the commits, the verification command, and what it showed.
- **Local markdown:** set `**Status:** done` in the ticket file and append an `## Evidence` section with the commit SHAs and the verification command and result.
- Close a ticket only when its own verification passed. A ticket whose tests fail stays open, with one line saying what is missing.
- Reference the PR or branch that carries the work.

## 2. Keep the domain docs current

- A new or changed domain term: update `GLOSSARY.md` with the definition and what to avoid calling it. Follow `spec:domain-modeling` when it is on the locate list.
- A decision with lasting consequences: add the next-numbered ADR under `docs/adr/` with context, decision, and consequences.
- Write only what this task actually settled. Do not restate code or restate the ticket.

## 3. Write back to gbrain

Follow the global memory rules:

- `project/<id>/state` is the project cognition card: what the project is, where it stands, what is next. Overwrite it, do not append.
- Decisions with their reasons go to `project/<id>/decisions/<topic>`; project-specific lessons go to `project/<id>/lessons/<topic>`; cross-project knowledge goes to `knowledge/<domain>/<topic>`.
- Keep task lists, iteration status, and bug detail out of gbrain; they live in the tracker.
- Use the gbrain MCP tools when the session has them. If the write fails or no gbrain is available, print the exact page content in the report and say the write failed; never drop it silently.

## 4. Clean up worktrees

Read pstack's worktree-cleanup playbook at the path `locate.sh` printed for `pstack:poteto-mode/playbooks/worktree-cleanup.md`, and apply its buckets. Limit it to worktrees this task created, and skip its transcript scan unless a bucket is ambiguous.

- Clean, merged, and not in use: remove, then `git worktree prune`.
- Uncommitted work, or a worktree still in use: leave it and report why.
- Never remove the worktree the current session is running in.

## 5. Route each lesson

A lesson is a correction, a trap, or a process change this task produced. For each one:

- **Project-specific** (coding conventions, local setup): append it to `docs/agents/conventions/<topic>.md` when the repo has that directory. If it does not, skip and say the repo has no conventions library yet.
- **Workflow-level** (jstack itself should change): search `gh issue list --repo jionpz/jstack --state open --search "<keywords>"` first. Open a new issue only when no open issue already covers it: `gh issue create --repo jionpz/jstack --title "<title>" --body "<what happened, what should change, evidence>"`. At most three per task; drop the rest with one line each.
- If `gh` is unavailable or the repo has no remote, print the issue text instead of creating it.

## 6. Report

One line per section: tickets closed and their ids, docs updated, gbrain pages written, worktrees removed or kept with the reason, lessons routed with issue numbers or paths, sections skipped with the reason.

## Never

- Never delete a worktree with uncommitted work, one in use, or the current session's.
- Never open a jstack issue before searching for an existing one.
- Never write evidence you did not see, and never close a ticket whose verification failed.
