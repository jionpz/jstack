---
name: verify
description: "jstack's verify-stage provider. Verify a candidate on its real surface with evidence from fresh bulk contexts; XS may run direct checks. Route reads this file by path; do not model-invoke it."
disable-model-invocation: true
---

# Verify

You verify the candidate the execute stage handed back. Author checks are input to execution, not acceptance. Use the task size and the ticket's acceptance criteria, and check the scope against `../route/must-stop.md` plus the repo config's `must_stop`.

- **XS, no must-stop item:** run the project's required verification in this session. Use `verify.command` when the repo config provides it; otherwise run the smallest check that demonstrates the requested behavior.
- **S or M:** use one fresh bulk verifier.
- **L, a ticket on an L path, or any change that touches a must-stop item:** use two independent fresh bulk verifiers. Disagreement, one failure, or a blocked report means verification is incomplete.

## Interactive route

1. Capture the exact candidate: the base and head revisions, plus any working-tree changes. Include everything the ticket changed, not only the last commit.
2. Start a fresh context with the harness's native delegation tool. Do not fork or resume the main context. Use the configured bulk default; if the model configuration provides a `flow verify work` role override, use it. Never inherit a premium parent model just because that is the current model. Start two separate contexts when two reports are required. If the tool or bulk binding cannot be established, report verification as blocked.
3. Brief each verifier with only the original task or ticket, its acceptance criteria, the candidate diff or base/head, the worktree path, the commands needed to run it, and the applicable project constraints. Keep the author's reasoning, author check results, expected verdict, hidden checks, and the other verifier's report out of the brief.
4. Ask the verifier to drive the real CLI, API, or UI and try to falsify the acceptance criteria. It may use temporary data but must leave the candidate unchanged. The report must name the commands or surface actions, the observed results, and a `pass`, `fail`, or `blocked` verdict. Static inspection alone is not a pass.
5. Accept evidence only for the candidate the verifiers received. Once every required report passes, record each with `../route/stage.sh evidence "<verifier/context id>: <command> -> <observation>; verdict: pass"` in the `verify` stage. If the project configures `verify.command`, also run `../route/stage.sh verify` in the coordinating session to obtain the Stop gate's receipt for this snapshot. A check failure, missing report, disagreement, or blocked verdict returns the task to execute; after a change, enter verify again and use new contexts for the new candidate.
6. Never write a pass on the author's behalf and never turn the diff alone into verification evidence. If the real surface cannot be run, report blocked and say what is missing.

## Managed ticket

When the launcher assigns the managed `verify` role with its own ticket and candidate, run the acceptance checks directly and return the evidence in the launcher's result format. The launcher owns context isolation, bulk model binding, and the quorum. If this process is one of several required verifiers, return only its own verdict. Route's `stage.sh` bookkeeping applies to interactive sessions.
