---
name: archive
description: "Close out a jstack task in two parts: before merge, keep GLOSSARY.md and ADRs current, write back to gbrain, and route each lesson; after merge, close tickets with their evidence and clean merged worktrees. Invoked by flow:route at the archive stage; not for mid-task cleanup."
disable-model-invocation: true
---

# Archive

The archive stage's provider. It has two parts, split by the merge:

- **Before merge** (sections 2, 3, 5): run in the session that did the work, once the task is PR-ready.
- **After merge** (sections 1, 4): run only when the PR is merged. Check with the forge (`gh pr view <n> --json state,mergedAt`), not from memory.

When the PR is still open, do the before-merge part, then record what is owed with `stage.sh pending "<PR URL> <what is left>"` (for example `closes #74, worktree .claude/worktrees/x`) and report the task as PR-ready. Do not merge the PR to get to the second part. When route starts a later task and `stage.sh start` lists pending entries, or the user says a PR was merged, run the after-merge part for each merged PR and then `stage.sh settled <PR URL>`. A repo with no remote runs both parts together.

Skip a section that does not apply, and say which and why in the report.

## 1. Close the tickets (after merge)

Read `docs/agents/issue-tracker.md` for where tickets live. If the repo has `.jstack/config.json`, its `tracker` section wins: `type` (`github` or `local`), `local_dir`, and `label`. If both are missing, use the tracker the task actually used.

- **GitHub issues:** `gh issue close <n> --repo <owner/repo> --comment "<evidence>"`, where the evidence names the commits, the verification command, and what it showed.
- **Local markdown:** set `**Status:** done` in the ticket file and append an `## Evidence` section with the commit SHAs and the verification command and result.
- Close a ticket only when its own verification passed and its PR is merged. A ticket whose tests fail stays open, with one line saying what is missing. A ticket the merge already closed (`Closes #n`) needs only the evidence comment.
- Reference the PR or branch that carries the work.

## 2. Keep the domain docs current (before merge)

- A new or changed domain term: update the glossary at `domain_docs.glossary` (`GLOSSARY.md` by default) with the definition and what to avoid calling it. Follow `spec:domain-modeling` when it is on the locate list.
- A decision with lasting consequences: add the next-numbered ADR under `domain_docs.adr` (`docs/adr/` by default) with context, decision, and consequences.
- Write only what this task actually settled. Do not restate code or restate the ticket.

## 3. Write back to gbrain (before merge)

Follow the global memory rules:

- `project/<id>/state` is the project cognition card: what the project is, where it stands, what is next. Overwrite it, do not append.
- Decisions with their reasons go to `project/<id>/decisions/<topic>`; project-specific lessons go to `project/<id>/lessons/<topic>`; cross-project knowledge goes to `knowledge/<domain>/<topic>`.
- Keep task lists, iteration status, and bug detail out of gbrain; they live in the tracker.
- Use the gbrain MCP tools when the session has them. If the write fails or no gbrain is available, print the exact page content in the report and say the write failed; never drop it silently.

## 4. Clean up worktrees (after merge)

Read pstack's worktree-cleanup playbook at the path `locate.sh` printed for `pstack:poteto-mode/playbooks/worktree-cleanup.md`, and apply its buckets. Limit it to worktrees this task created, and skip its transcript scan unless a bucket is ambiguous.

- Clean, merged, and not in use: remove, then `git worktree prune`.
- Uncommitted work, or a worktree still in use: leave it and report why.
- Never remove the worktree the current session is running in.

## 5. Route each lesson (before merge)

A lesson is a correction, a trap, or a process change this task produced. For each one:

- **Project-specific** (coding conventions, local setup): append it to `<domain_docs.conventions>/<topic>.md` (`docs/agents/conventions/` by default) when the repo has that directory. If it does not, skip and say the repo has no conventions library yet.
- **Workflow-level** (jstack itself should change): search `gh issue list --repo jionpz/jstack --state open --search "<keywords>"` first. Open a new issue only when no open issue already covers it: `gh issue create --repo jionpz/jstack --title "<title>" --body "<what happened, what should change, evidence>"`. At most three per task; drop the rest with one line each.
- If `gh` is unavailable or the repo has no remote, print the issue text instead of creating it.

## 6. Report

One line per section: tickets closed and their ids, docs updated, gbrain pages written, worktrees removed or kept with the reason, lessons routed with issue numbers or paths, sections skipped with the reason. Name the after-merge part as done or as pending with its `stage.sh pending` entry.

## Never

- Never delete a worktree with uncommitted work, one in use, or the current session's.
- Never open a jstack issue before searching for an existing one.
- Never write evidence you did not see, and never close a ticket whose verification failed.
- Never merge a PR to make the after-merge part runnable; merging is the user's call.
