---
name: review
description: "jstack's default review-stage provider. One pass over the diff against the task: fix or dismiss each finding, record the evidence. Route reads this file by path; do not model-invoke it."
disable-model-invocation: true
---

# Review

You review the change the execute stage made, in the main session. This is the review for every change whose design is not contested; the adversarial providers are conditional and route runs them only when the gate calls for one.

## Read the diff against the task

1. Read the task sentence or the spec again, then the full diff from where execute started (`git diff <base>..HEAD`, or the uncommitted diff when execute has not committed yet). Read every hunk; do not sample.
2. Check the change against the task, not against your taste: behavior the task did not ask for, a boundary the task names (empty, missing, duplicate, invalid), an error that gets swallowed, a test that asserts implementation instead of behavior, and a leftover debug print or commented-out block.
3. When a suspicion can be settled by running something, settle it that way: the repo's test command, the CLI, a one-off command. Never report a finding you did not check, and do not report style.

## Fix or dismiss

- A real finding: fix it, rerun the check that covers it, commit the fix.
- Everything else: dismiss it with the concrete reason, for example "the parser rejects this before the new branch runs".
- Record the stage: `../route/stage.sh evidence "review -> <what you read and ran; N fixed, M dismissed>"`.

## Do not fan out

`pstack:interrogate` and `pstack:swarm` are conditional adversarial providers. Route may call `pstack:interrogate` when the design is contested, the task touches a must-stop item, or the user requests adversarial review. It may call `pstack:swarm` when the design is contested or the user requests multiple adversarial perspectives and a swarm is useful. `flow:review` is the default when a complete review conclusion and finding resolutions are not already recorded; do not repeat a review whose required output already exists. Do not call these providers yourself, and do not spawn reviewers of your own.
