# jstack stages

The single source of truth for the jstack workflow (ADR-0002). Route walks these stages in order. `locate.sh` reads the Providers column, and `./jstack check` fails when a provider cannot be found. To swap a provider, change its cell. Nothing else names it.

A provider is written `` `<plugin>:<skill>` `` for the skill's `SKILL.md`, or `` `<plugin>:<skill>/<file>` `` for another file inside that skill's folder. `-` means the stage has no provider yet. A cell with several providers lists alternatives or conditional steps; route's SKILL.md says when each one runs.

## Stages

| Stage | Output | Gate | Providers |
|---|---|---|---|
| size | One sentence naming the size and the stage path | None | `flow:route` |
| clarify | Settled decisions; GLOSSARY.md or ADR entries for terms and decisions that got resolved | Only a decision the evidence cannot settle reaches the user | `spec:grill-with-docs` |
| plan | A spec and tickets in dependency order, published to the tracker | The spec and breakdown exist; user sign-off is required only for an unresolved high-risk disagreement or a must-stop action (ADR-0004) | `spec:setup-matt-pocock-skills` `spec:to-spec` `spec:to-tickets` `spec:wayfinder` `spec:handoff` |
| investigate | A cited answer, explanation, recommendation, or current PR state | The answer is supported by inspected evidence; no code change or PR is required | `pstack:poteto-mode/playbooks/investigation.md` |
| execute | The change, committed in small verified units | None | `flow:execute` `pstack:poteto-mode` |
| verify | Evidence that the change works on the real surface: the command run and what it showed | No evidence means not done; the flow Stop gate enforces it where loaded and trusted (Claude Code, Cursor, Pi, OMP, Codex) | `pstack:principle-prove-it-works` |
| review | A recorded review conclusion; every finding fixed or dismissed with a concrete reason | The review conclusion and finding resolutions exist, including an explicit zero-findings conclusion when appropriate | `flow:review` `pstack:interrogate` `pstack:swarm` |
| land | Commits on a branch; a PR when the repo has a remote | The commits exist and, when a remote exists, the PR URL is recorded (unless the user explicitly directs a merge or push instead); must-stop actions require user approval | `pstack:poteto-mode/playbooks/opening-a-pr.md` |
| archive | Tickets closed with their evidence; GLOSSARY.md and ADRs current; gbrain written back; merged worktrees cleaned; each lesson routed or dropped | A ticket closes only on evidence; no worktree with uncommitted work is removed; every lesson is routed or dropped with a reason | `flow:archive` `pstack:poteto-mode/playbooks/worktree-cleanup.md` |

Review uses `flow:review` by default. A contested design, a change touching the must-stop list, or the user's explicit request triggers `pstack:interrogate`; use `pstack:swarm` when a swarm review is requested or needed for that contested design. These are additional review conditions; the recorded review conclusion is required on every path containing review.
