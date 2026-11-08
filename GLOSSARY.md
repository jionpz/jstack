# jstack

jstack 是用户长期维护的 AI 开发工作流，以 `pstack`、`spec`、`flow` 三个插件发布。Claude Code 是主力 harness，同时支持 Pi、OMP、Codex、Cursor。

## Language

**harness**:
An agent client that discovers skills and runs the model loop; this repo targets Claude Code first and also supports Pi, OMP, Codex, and Cursor.
_Avoid_: client, IDE, environment

**stage**:
One fixed step of the jstack workflow (sizing, clarify, plan, execute, verify, review, land, archive), with a defined output and gate.
_Avoid_: phase, step

**provider**:
The skill or script currently bound to a stage; upstream skills are providers and can be swapped.
_Avoid_: backend, implementation

**gate**:
A condition a stage must meet before the workflow moves on, enforced by structure (hook or script) where the harness allows.
_Avoid_: check, checkpoint

**premium model**:
The switchable, token-limited strongest model, used only for short high-leverage judgments.
_Avoid_: expensive model, Opus

**bulk model**:
A model with effectively unlimited tokens (DeepSeek, GLM, Kimi class), used for the main loop, execution, and verification.
_Avoid_: cheap model, fast model

**needs-human**:
A question only the user can settle, queued in the tracker while unblocked work continues.
_Avoid_: blocker, approval

**run report**:
The short end-of-task summary readable on a phone: goal, changes, evidence, defaults applied, and what needs the user.
_Avoid_: recap, log

**task ledger**:
The tracker, the single place where tickets, dependencies, and status live.
_Avoid_: task list, todo

**plugin**:
A distributable bundle of skills and agents named `pstack`, `spec`, or `flow`.
_Avoid_: package, extension

**skill**:
A directory containing `SKILL.md`, portable across harnesses.
_Avoid_: command, prompt

**entry skill**:
A user-invoked skill marked `disable-model-invocation: true`; route and the spec entry points are entry skills.
_Avoid_: command, slash command

**project scope**:
An installation that lives inside the repository (vendor tree, project settings, project skill links) and works without a user-level install.
_Avoid_: local install, per-repo mode

**vendor tree**:
`<repo>/.jstack/vendor/`: the complete plugin trees plus marketplace manifest a project-scope install runs from.
_Avoid_: copy, mirror

**lock file**:
`<repo>/.jstack/lock.json`: the recorded upstream commits, plugin versions, vendor tree hash, and per-harness install records that `./jstack doctor` checks against.
_Avoid_: manifest

**adapter**:
The generic `agents.md` document that maps pstack's Cursor-native names to the running harness.
_Avoid_: shim, translator

**harness variant**:
A build artifact whose content or manifest is tailored to one harness.
_Avoid_: port, fork

**native pstack tree**:
The pstack tree authored for Cursor, used as-is for the Cursor harness.
_Avoid_: original, source

**Claude Code pstack tree**:
The pstack tree generated for Claude Code, read through the adapter.
_Avoid_: claude port
