# jstack stages

The single source of truth for the jstack workflow (ADR-0002). Route walks these stages in order. `locate.sh` reads the Providers column, and `./jstack check` fails when a provider cannot be found. To swap a provider, change its cell. Nothing else names it.

The Tool profile column names a profile in `tool-policy.json`, next to this file. That file defines only roles, capabilities and harness mappings; it does not repeat the stage list. `./jstack tools export` reads both files and rejects an unknown profile, an unknown capability, a duplicate key or a row without a profile. Auxiliary roles such as investigator and tianwen have profiles but no row here: they are not stages.

A provider is written `` `<plugin>:<skill>` `` for the skill's `SKILL.md`, or `` `<plugin>:<skill>/<file>` `` for another file inside that skill's folder. `-` means the stage has no provider yet. A cell with several providers lists alternatives or conditional steps; route's SKILL.md says when each one runs.

## Stages

| Stage | Output | Gate | Providers | Tool profile |
|---|---|---|---|---|
| size | One sentence naming the size and the stage path | None | `flow:route` | `router` |
| clarify | Settled decisions; GLOSSARY.md or ADR entries for terms and decisions that got resolved | Only a decision the evidence cannot settle reaches the user | `spec:grill-with-docs` | `analyst` |
| plan | A spec and tickets in dependency order, published to the tracker | The user signs off the testing seams and the breakdown in one message | `spec:setup-matt-pocock-skills` `spec:to-spec` `spec:to-tickets` `spec:wayfinder` `spec:handoff` | `planner` |
| execute | The change, committed in small verified units | None | `flow:execute` `pstack:poteto-mode` | `developer` |
| verify | Evidence that the change works on the real surface: the command run and what it showed | No evidence means not done; the flow Stop gate enforces it (Claude Code, Cursor, Pi, OMP) | `pstack:principle-prove-it-works` | `verifier` |
| review | Every finding fixed or dismissed with a concrete reason | A contested design gets an adversarial review before landing | `flow:review` `pstack:interrogate` `pstack:swarm` | `reviewer` |
| land | Commits on a branch; a PR when the repo has a remote | Nothing on the must-stop list (must-stop.md) without the user | `pstack:poteto-mode/playbooks/opening-a-pr.md` | `releaser` |
| archive | Tickets closed with their evidence; GLOSSARY.md and ADRs current; gbrain written back; merged worktrees cleaned; each lesson routed or dropped | A ticket closes only on evidence; no worktree with uncommitted work is removed; every lesson is routed or dropped with a reason | `flow:archive` `pstack:poteto-mode/playbooks/worktree-cleanup.md` | `archivist` |
