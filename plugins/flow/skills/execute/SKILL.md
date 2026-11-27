---
name: execute
description: "jstack's lean execute-stage provider. One task or one ticket done in the main session: inspect, change, run author checks, review the diff, commit. Route reads this file by path; do not model-invoke it."
disable-model-invocation: true
---

# Execute

You own one task or one ticket from the first edit to the committed change. Work in the main session. Run author checks and a self-review before handing the candidate back to route; independent verification happens in the verify stage.

## Do the work

1. Read what the task touches before editing: the repo's CLAUDE.md or AGENTS.md, the files the task or spec names, and the test layout. Do not re-read skill files.
2. Say, in one or two sentences, the behavior or data shape you are changing and the smallest change that gets there. If the existing design conflicts with the request, say that before building around it.
3. Change in small units. After each unit, run the real check for what changed: the repo's test command, or the command the task names. Read the failure before editing again. Fix the root cause, then rerun.
4. Review your own diff before committing: debug leftovers, unrelated edits, error handling at boundaries, and tests that assert observable behavior.
5. Create or reuse the task branch before the first commit, including in a repo with no remote. If HEAD is detached or on the default branch, switch to a task branch before committing. Commit each verified unit with a message that says why. Never push to a repo the user did not point you at, and never rewrite a pushed branch.
6. Return the base revision, candidate revision, and run instructions to route. Report what your author checks showed. The verify stage records the acceptance evidence.

## Delegation

Do the core change yourself. Delegate only an independent piece that pays for its own context: a separate subsystem, a mechanical sweep across many files, or a read-only investigation. One subagent at a time, with file pointers and the success check. Review its diff before you land it. When the repo enables must-stop, never put a listed action in a brief: the guard cannot see the brief, and the subagent may run without the gates.

For a worker command that needs throwaway files, run `python3 -I <flow>/skills/route/with-scratch.py -- <command> [args...]`. The command inherits the current working directory and receives a fresh directory as `TMPDIR` and `JSTACK_SCRATCH_DIR`. The helper removes that directory when the command exits, including on a nonzero exit. Write any results the parent needs outside the scratch directory.

## Decisions

- When the repo sets `must_stop_enabled: true` in `.jstack/config.json`, a must-stop action waits for the user, whoever would run it. The list is `../route/must-stop.md` plus the repo config's `must_stop`.
- A decision the evidence cannot settle that is irreversible, product-facing, or a public API or schema change: ask once, with a recommendation.
- Everything else: take the default you would recommend, record `../route/stage.sh default "<decision> -> <why>"`, and continue.

## Finish

End with the material route's finish summary needs:

- What changed, in the user's terms.
- Each check you ran and what it showed.
- Decisions taken by default, with their reasons.
- Anything skipped, not done, or not verified.
