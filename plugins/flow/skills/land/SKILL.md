---
name: land
description: "jstack's default land-stage provider. Turn a verified, reviewed change into ordered branch commits and, when the repository has a remote, a ready PR with verification and adopted-default receipts. Route reads this file by path; do not model-invoke it."
disable-model-invocation: true
---

# Land

You own publication, not implementation. Execute, verify, and review have already happened. Turn their result into commits on a branch and, when there is a remote, a ready PR. Never invent verification, skip a failed check, or merge the PR.

## 1. Inspect the diff before committing

Read the task or spec, `../route/stage.sh show`, and the full diff from the recorded base. Include both committed work (`git diff <base>..HEAD`) and anything still uncommitted (`git diff` and `git diff --cached`).

Run `git status --short`, `git diff --check`, and inspect every changed path. A change that does not belong to this task, debug output, generated files, unrelated lockfile churn, or any secret blocks land. Secrets include `.env*`, credentials, auth stores, tokens, private keys, and harness configuration that carries them. If you find a real defect, return to execute instead of hiding it in the PR description.

## 2. Branch and commit

Check the current branch with `git branch --show-current`. Reuse the task branch when it already exists. If HEAD is detached or on the default branch, create a task branch at the current HEAD, such as `codex/<slug>` in Codex. Preserve any existing commits on the default branch.

Commit only the intended files, in small verified units. Use a Conventional Commits subject that says what changed and a body that says why. Keep unrelated user changes out of the commit. Never rewrite a pushed branch: force push is a must-stop action.

Leave the working tree clean. Before recording the head SHA or pushing, confirm that HEAD is on the task branch. In a repository with no remote, the branch commit is the land output: run `../route/stage.sh land commit <SHA>` and stop without pushing or opening a PR.

## 3. Open or update the PR

With a remote, push the branch normally. Prefer the harness's built-in PR tool when the run provides one; otherwise use the repository's forge, such as `gh` for GitHub. Do not create a second PR for a branch that already has one. Check for an existing open PR by head branch and reuse it, updating its body and head if needed.

Open the PR ready, not as a draft. Write a one-minute briefing from the task, diff, verification evidence, and recorded defaults:

```markdown
## What changed
- <one to three concrete changes>

## Verification
- `<command>` -> `<observed result>`

## Decisions
- `<adopted default>` -> `<reason>`

## Risk
- <what is not covered, or "None identified">
```

Use the actual verify evidence. If there is no verification evidence, land is blocked. Do not paste secrets, raw logs, or a file-by-file essay. After the PR exists and its head is the commit you inspected, run `../route/stage.sh land commit <SHA>` and `../route/stage.sh land pr <URL>`.

## 4. Check CI once

Wait once for the required checks on the pushed head. On GitHub, run `gh pr checks <number> --watch`; use the equivalent forge command elsewhere. Do not poll in a loop.

- Green on the inspected head: land is PR-ready. Report the PR URL, head SHA, the verification and decisions sections, and the check result.
- Red, still unfinished after that one wait, or unable to run: land is not met. Name the exact failing, pending, or unavailable check and send the task back to execute for a fix and a fresh verify. Do not report the task as done.

Never merge the PR, enable auto-merge, or push directly to the default branch unless the user's current message explicitly names that PR or action. Route owns that decision, and the must-stop guard enforces it.
