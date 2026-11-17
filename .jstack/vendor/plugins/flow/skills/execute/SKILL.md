---
name: execute
description: "jstack's lean execute-stage provider. One task or one ticket done in the main session: inspect, change, verify, review the diff, commit. Route reads this file by path; do not model-invoke it."
disable-model-invocation: true
---

# Execute

You own one task or one ticket from the first edit to the committed change. Work in the main session. This stage also covers verify and a self-review; the land gate is checked after you finish.

## Do the work

1. Read what the task touches before editing: the repo's CLAUDE.md or AGENTS.md, the files the task or spec names, and the test layout. Do not re-read skill files.
2. Say, in one or two sentences, the behavior or data shape you are changing and the smallest change that gets there. If the existing design conflicts with the request, say that before building around it.
3. Change in small units. After each unit, run the real check for what changed: the repo's test command, or the command the task names. Read the failure before editing again. Fix the root cause, then rerun.
4. Review your own diff before committing: debug leftovers, unrelated edits, error handling at boundaries, and tests that assert observable behavior.
5. Commit each verified unit with a message that says why. Branch first when the repo works on branches. Never push to a repo the user did not point you at, and never rewrite a pushed branch.
6. After each check, record it with `../route/stage.sh evidence "<command> -> <what it showed>"`. If it reports that the gates are off, say so once in the finish report and continue.

## Delegation

Do the core change yourself. Delegate only an independent piece that pays for its own context: a separate subsystem, a mechanical sweep across many files, or a read-only investigation. One subagent at a time, with file pointers and the success check. Review its diff before you land it. Never put a must-stop action in a brief: the guard cannot see the brief, and the subagent may run without the gates.

## Decisions

- A must-stop action waits for the user, whoever would run it. The list is `../route/must-stop.md` plus the repo config's `must_stop`.
- A decision the evidence cannot settle that is irreversible, product-facing, or a public API or schema change: ask once, with a recommendation.
- Everything else: take the default you would recommend, record `../route/stage.sh default "<decision> -> <why>"`, and continue.

## Finish

End with the material route's finish summary needs:

- What changed, in the user's terms.
- Each check you ran and what it showed.
- Decisions taken by default, with their reasons.
- Anything skipped, not done, or not verified.
