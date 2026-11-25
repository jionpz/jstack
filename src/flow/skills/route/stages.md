# jstack stages

The single source of truth for the jstack workflow (ADR-0002). Route walks these stages in order. `locate.sh` reads the Providers column, and `./jstack check` fails when a provider cannot be found. To swap a provider, change its cell. Nothing else names it.

The Tool profile column names a profile in `tool-policy.json`, next to this file. That file defines only roles, capabilities and harness mappings; it does not repeat the stage list. `./jstack tools export` reads both files and rejects an unknown profile, an unknown capability, a duplicate key or a row without a profile. Auxiliary roles such as tianwen have profiles but no row here: they are not stages.

Managed ticket marks the stages used in a Keel engineering package. `required` includes the stage and its first provider in table order. `-` leaves it out. See ADR-0008 for the launcher boundary.

Tier records the default work and gate model layers as `work / gate`. Work uses `bulk`. A gate can use `bulk` or `premium`, or `-` when it has no separate model decision. These declarations feed model rules and managed exports.

A provider is written `` `<plugin>:<skill>` `` for the skill's `SKILL.md`, or `` `<plugin>:<skill>/<file>` `` for another file inside that skill's folder. `-` means the stage has no provider yet. A cell with several providers lists alternatives or conditional steps; route's SKILL.md says when each one runs.

## Stages

| Stage | Output | Gate | Providers | Tool profile | Managed ticket | Tier |
|---|---|---|---|---|---|---|
| size | One sentence naming the size and the stage path | None | `flow:route` | `router` | - | bulk / - |
| clarify | Settled decisions; GLOSSARY.md or ADR entries for terms and decisions that got resolved | Only a decision the evidence cannot settle reaches the user | `spec:grill-with-docs` | `analyst` | - | bulk / premium |
| plan | A spec and tickets in dependency order, published to the tracker | The spec and breakdown exist; user sign-off is required only for an unresolved high-risk disagreement or a must-stop action (ADR-0004) | `spec:setup-matt-pocock-skills` `spec:to-spec` `spec:to-tickets` `spec:wayfinder` `spec:handoff` | `planner` | - | bulk / premium |
| investigate | A cited answer, explanation, recommendation, or current PR state | The answer is supported by inspected evidence; no code change or PR is required | `pstack:poteto-mode/playbooks/investigation.md` | `investigator` | - | bulk / - |
| execute | The change, committed in small verified units | None | `flow:execute` `pstack:poteto-mode` | `developer` | required | bulk / - |
| verify | Evidence that the candidate works on its real surface: the command or action and what it showed, from the required fresh context(s) | Route requires direct checks for XS, a fresh bulk verifier for S/M, and two independent passing reports for L or a must-stop change. Stop and `stage.sh end` check the configured command receipt or stage-scoped evidence | `flow:verify` | `verifier` | required | bulk / - |
| review | A recorded review conclusion; every finding fixed or dismissed with a concrete reason | The review conclusion and finding resolutions exist, including an explicit zero-findings conclusion when appropriate | `flow:review` `pstack:interrogate` `pstack:swarm` | `reviewer` | required | bulk / premium |
| land | Commits on a branch; when the repo has a remote, a PR whose CI is green (PR-ready) | Nothing on the must-stop list (must-stop.md) without the user, merging the PR included; a PR with red or unfinished CI is not PR-ready | `flow:land` | `releaser` | required | bulk / - |
| archive | Before merge: GLOSSARY.md and ADRs current, gbrain written back, each lesson routed or dropped. After merge: tickets closed with their evidence, merged worktrees cleaned. While the PR is unmerged, the after-merge part is recorded with `stage.sh pending` | A ticket closes only on evidence and only after its PR merged; no worktree with uncommitted work is removed; every lesson is routed or dropped with a reason | `flow:archive` | `archivist` | - | bulk / - |

Verify uses `flow:verify`. XS may run direct checks. S and M use a fresh bulk context, and L or must-stop changes require two independent reports. Author checks recorded during execute do not satisfy the verify gate.

Review uses `flow:review` by default. A contested design, a change touching the must-stop list, or the user's explicit request triggers `pstack:interrogate`; use `pstack:swarm` when a swarm review is requested or needed for that contested design. These are additional review conditions; the recorded review conclusion is required on every path containing review.
