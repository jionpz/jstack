# jstack

jstack 是一个 AI 工程工作流 marketplace，发布 `pstack`、`spec`、`flow` 三个插件，并适配 Claude Code、Pi、OMP、Cursor 四个 harness。

## Language

**harness**:
An agent client that discovers skills and runs the model loop; this repo supports Claude Code, Pi, OMP, and Cursor.
_Avoid_: client, IDE, environment

**plugin**:
A distributable bundle of skills and agents named `pstack`, `spec`, or `flow`.
_Avoid_: package, extension

**skill**:
A directory containing `SKILL.md`, portable across harnesses.
_Avoid_: command, prompt

**entry skill**:
A user-invoked skill marked `disable-model-invocation: true`; route and the spec entry points are entry skills.
_Avoid_: command, slash command

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
