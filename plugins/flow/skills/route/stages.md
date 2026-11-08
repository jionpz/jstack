# jstack stages

The single source of truth for the jstack workflow (ADR-0002). Route walks these stages in order. `locate.sh` reads the Providers column, and `./jstack check` fails when a provider cannot be found. To swap a provider, change its cell. Nothing else names it.

A provider is written `` `<plugin>:<skill>` `` for the skill's `SKILL.md`, or `` `<plugin>:<skill>/<file>` `` for another file inside that skill's folder. `-` means the stage has no provider yet. A cell with several providers lists alternatives or conditional steps; route's SKILL.md says when each one runs.

## Stages

| Stage | Output | Gate | Providers |
|---|---|---|---|
| size | One sentence naming the size and the stage path | None | `flow:route` |
| clarify | Settled decisions; GLOSSARY.md or ADR entries for terms and decisions that got resolved | Only a decision the evidence cannot settle reaches the user | `spec:grill-with-docs` |
| plan | A spec and tickets in dependency order, published to the tracker | The user signs off the testing seams and the breakdown in one message | `spec:setup-matt-pocock-skills` `spec:to-spec` `spec:to-tickets` `spec:wayfinder` `spec:handoff` |
| execute | The change, committed in small verified units | None | `pstack:poteto-mode` |
| verify | Evidence that the change works on the real surface: the command run and what it showed | No evidence means not done; the flow Stop hook enforces it | `pstack:principle-prove-it-works` |
| review | Every finding fixed or dismissed with a concrete reason | A contested design gets an adversarial review before landing | `pstack:interrogate` `pstack:swarm` |
| land | Commits on a branch; a PR when the repo has a remote | Nothing on the must-stop list (must-stop.md) without the user | `pstack:poteto-mode/playbooks/opening-a-pr.md` |
| archive | Tickets closed with their evidence; GLOSSARY.md and ADRs current; merged worktrees cleaned | None | - |
