# pstack harness adapter

pstack skills use Cursor tool and field names. Read this file once per session, detect the harness with the table below, then apply only that harness's section. `<pstack>` means the folder that holds `skills/` and `docs/`. If a section has no row for a Cursor field, drop the field and say so. Never pass a field or value the tool schema rejects.

Cursor's native pstack tree does not read this file. The copy that ships to Cursor runs the Cursor names directly. This file exists for ports that map those names onto another harness.

## Detect the harness

| Signal in the session | Harness | Section |
| --- | --- | --- |
| An `Agent` tool with an `effort` parameter, a `Skill` tool, or agents named `pstack:*`; transcripts under `~/.claude/projects/` | Claude Code | [Claude Code](#claude-code) |
| An `Agent` tool with `thinking` and `get_subagent_result`; `/skill:<name>` commands; sessions under `~/.pi/agent/sessions/` | Pi | [Pi](#pi) |
| A `task` tool with `agent`, `task`, `context`, and `name`; `skill://<name>` or `manage_skill`; sessions under `~/.omp/agent/sessions/` | OMP | [OMP](#omp) |

Use the first row whose tools the session actually exposes. If none match, say which harness you could not identify, then use the Cursor names as written and drop any field the tool rejects.

## Claude Code

pstack skills use Cursor names. In Claude Code, read this file once per session, then map each Cursor name in a skill with the tables below. `<pstack>` means the folder that holds `skills/` and `docs/`. If a Cursor field has no row, drop it and say so. Never pass a field or value the tool schema rejects.

### Tools

| Cursor | Claude Code |
| --- | --- |
| `Task` | `Agent` |
| `AskQuestion` | `AskUserQuestion`. In `-p` mode it is absent, so ask in plain text. |
| Open a todolist | Use `TodoWrite` if the session offers it. Otherwise keep the list in your reply and update it at each phase. |
| Run another pstack skill (`/name` or "the **name** skill") | `Read` `<pstack>/skills/<name>/SKILL.md` and follow it. The `Skill` tool refuses most pstack skills. When you tell the user to type it, write `/pstack:<name>`. |
| `Grep`, `Glob` | `Bash` with `rg` when the session has no `Grep` or `Glob`. |

### Subagent fields

| Cursor | Claude Code |
| --- | --- |
| `subagent_type: generalPurpose` | `subagent_type: "general-purpose"` |
| `poteto-agent`, `comment-sicko` | `pstack:poteto-agent`, `pstack:comment-sicko` |
| `readonly: true` | `subagent_type: "Explore"`. It keeps `Bash`, so the brief also says "do not edit files", and you check `git status` afterward. |
| `readonly: false` | `general-purpose`. It keeps the session's MCP servers. |
| `environment: "cloud"` | `isolation: "worktree"`. Name the branch or commit the worker checks out. |
| `environment: "local"` | Omit. |
| `cloud_base_branch: <b>` | Tell the worker to check out `<b>` first. |
| `run_in_background: true` | Omit. Subagents run in the background by default and notify you when they finish. |
| `resume` | Spawn a new agent and paste the earlier result into its brief. |
| `file_attachments` | List the paths in the brief. |

### Models

| Cursor | Claude Code |
| --- | --- |
| `claude-<family>-<version>-<effort>[-fast]`, such as `claude-opus-5-5-xhigh` | `model: "opus"` and `effort: "xhigh"`. `model` takes only `opus`, `sonnet`, `haiku`, `fable`. Drop `-fast`. |
| A `grok-*`, `gpt-*`, or other non-Claude slug | Omit `model` so the agent runs on the session model, and say so. |
| `auto` or `inherit-parent` | Omit `model`. |
| The `pstack-models.mdc` rule, `~/.cursor/rules/pstack-models.mdc` | `~/.claude/rules/pstack-models.md`. Claude Code loads it into every new session, so its role lines are already in context. If they are not, read the file. If the file or the role's line is missing, use the skill's default slug. |
| A role value `<model> <effort>`, such as `opus high` | `model: "opus"` and `effort: "high"`. |

### setup-pstack

Claude Code loads every `.md` file in `~/.claude/rules/` into each new session, so `setup-pstack` writes its rule there. Follow its steps with these changes:

- Detect. The detected models are the `model` values that the `Agent` tool schema lists, each with an effort from its `effort` values. Write a real model as `<model> <effort>`, such as `opus xhigh`. The effort is the last token, so the budget step works as written.
- Defaults. Map each default slug with the rows above: `claude-opus-5-5-xhigh` is `opus xhigh`, and `grok-4.7-xhigh-fast` is `inherit-parent`.
- Write. Write `~/.claude/rules/pstack-models.md` with no frontmatter, then the comment lines, the `# budget` line, and one line per role from step 5. Overwrite the whole file. Never put the role lines in `CLAUDE.md` or `AGENTS.md`.

### Paths

| Cursor | Claude Code |
| --- | --- |
| `.cursor/skills/`, `~/.cursor/skills/` | `.claude/skills/`, `~/.claude/skills/` |
| `~/.cursor/plugins/`, `.cursor-plugin/plugin.json` | `~/.claude/plugins/`, `.claude-plugin/plugin.json` |
| `.cursor/rules/*.mdc`, always-applied rules | `CLAUDE.md`, or `AGENTS.md` when no `CLAUDE.md` exists. Claude Code never reads `.mdc` files. The model rule is the exception. See Models. |
| `https://github.com/cursor/plugins/blob/main/pstack/<path>` | `<pstack>/<path>` when that file exists. The plugin ships the skills, `docs/guide/`, and `README.md`. Read the local copy and never fetch it. Give the user the URL when they need a link. |
| Transcripts in `~/.cursor/projects/<slug>/agent-transcripts/` | `~/.claude/projects/<slug>/<session>.jsonl`. The slug is the workspace path with every character other than a letter or digit changed to `-`, so `/Users/you/my_proj` is `-Users-you-my-proj`. The newest `.jsonl` directly in that folder is the current session. Its `<session>/subagents/` folder holds subagent transcripts. Read only this workspace's folder. |

### Cursor-only features

Claude Code has no Cursor Automations, Bugbot, Cursor cloud agents, or built-in PR tool. When a step needs one, put one line in your reply, `Skipped in Claude Code: <step>. <reason>.`, then go on to the next step. Do not stop, ask, or retry. When a later step needs what the skipped step made, such as a URL or a key, leave a placeholder and name it in the line.

| Cursor | Claude Code |
| --- | --- |
| Cursor Automations: routines, `update_state` routine calls, `api2.cursor.sh/automations` webhooks, routine wakes, and `SendToUser` secret requests | Skip with the line. |
| Bugbot | Bugbot comments on a GitHub PR are ordinary review threads, so triage them with the forge command that the step gives. Skip a step that starts, waits for, or configures Bugbot when the PR has no Bugbot check or comment. |
| Cursor cloud agents | `environment: "cloud"` maps to a worktree, as in Subagent fields. Skip a step that needs the cloud agent itself, such as its dashboard status or its own machine. |
| A built-in PR tool | Use the forge command that the step gives, such as `gh pr create`. That is not a skip, so write no line. |

## Pi

Pi is `pi-coding-agent`; the `Agent` tool below comes from the `@tintinweb/pi-subagents` extension. Only the rows below differ from the Cursor names; map everything else as written.

### Tools

| Cursor | Pi |
| --- | --- |
| `Read`, `Write`, `Edit`, `Bash` | `read`, `write`, `edit`, `bash`. Pi tool names are lowercase. |
| `Grep`, `Glob` | `grep`, `glob`. |
| `AskQuestion` | No question tool. Ask in plain text, one question per message, with options. |
| Open a todolist | No todo tool. Keep the list in your reply and update it at each phase. |
| `Task` | `Agent` from `@tintinweb/pi-subagents` (see below). |

### Subagent tool and parameters

| Cursor | Pi |
| --- | --- |
| `Task` | `Agent` from `@tintinweb/pi-subagents`. Parameters: `subagent_type`, `prompt`, `description`, `model`, `thinking`, `max_turns`, `run_in_background`, `resume`, `isolated`, `isolation`, `inherit_context`. |
| `subagent_type: generalPurpose` | `subagent_type: "general-purpose"` |
| `poteto-agent`, `comment-sicko` | Custom agents. Put `poteto-agent.md` and `comment-sicko.md` in `~/.pi/agent/agents/`, `.pi/agents/`, or `.agents/agents/`. Frontmatter: `description`, `tools`, `disallowed_tools`, `model`, `thinking`, `max_turns`, `run_in_background`. If a file is missing, spawn `general-purpose` and put poteto-mode's skill-read line in the prompt. |
| `environment: "cloud"` | `isolation: "worktree"`. Name the branch or commit the worker checks out. |
| `environment: "local"` | Omit. |
| `cloud_base_branch: <b>` | Tell the worker to check out `<b>` first. |
| `resume` | `resume: "<agent-id>"` resumes that agent's session. poteto-mode still prefers a fresh agent with consolidated scope. |
| `file_attachments` | List the paths in the brief. |
| `inherit_context: true` | Pi-specific. Leave it false; poteto-mode passes file pointers instead of forking the parent conversation. |

`max_turns` is optional. Omit it for unlimited.

### Readonly and background

| Cursor | Pi |
| --- | --- |
| `readonly: true` | `subagent_type: "Explore"`. It keeps `bash`, so the brief also says "do not edit files", and you check `git status` afterward. A custom agent whose `tools` are read-only is the strict form. |
| `readonly: false` | `general-purpose`. It is a parent twin and inherits `AGENTS.md` / `CLAUDE.md`. |
| `run_in_background: true` | `run_in_background: true`. Pi defaults to foreground; a background call returns an agent id and notifies you when it finishes. Read it with `get_subagent_result` and steer it with `steer_subagent`. |

### Models and thinking

| Cursor | Pi |
| --- | --- |
| `claude-<family>-<version>-<effort>[-fast]`, such as `claude-opus-5-5-xhigh` | Split the slug. `model` is the slug without the trailing effort token, in the `provider/modelId` form Pi's registry lists (`claude-opus-5-5` or its provider form); `thinking` is that token (`xhigh`). Drop `-fast`; Pi has no fast mode. |
| A `grok-*`, `gpt-*`, or other non-Claude slug | Same split. If the slug does not resolve, omit `model` so the agent runs on the parent model, and say so. |
| `auto` or `inherit-parent` | Omit `model`. |
| A role value `<model> <effort>`, such as `opus high` | `model: "opus"` and `thinking: "high"`. |
| The `pstack-models.mdc` rule, `~/.cursor/rules/pstack-models.mdc` | `~/.pi/agent/AGENTS.md`, the agent-dir instruction file Pi loads into every session. If the role's line is missing, use the skill's default slug. |

`thinking` takes `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. Pi clamps an unsupported level down. A custom agent's frontmatter `model` and `thinking` are authoritative and win over the caller and the role line; leave them unset when the role line should control the agent.

### Skill invocation

| Cursor | Pi |
| --- | --- |
| `/name` or "the **name** skill" | `Read` `<pstack>/skills/<name>/SKILL.md` and follow it. Pi has no `Skill` tool; the model reads the file. |
| Telling the user to run a pstack skill | `/skill:<name>`. There is no `/pstack:<name>` prefix. |
| `disable-model-invocation: true` | Supported. It hides the skill from automatic model selection, and `/skill:<name>` still loads it. |

### Session and transcript roots

| Cursor | Pi |
| --- | --- |
| Transcripts in `~/.cursor/projects/<slug>/agent-transcripts/` | Sessions under `~/.pi/agent/sessions/`, grouped by working directory. Read only this workspace's session folder. |
| A subagent transcript beside the chat | pi-subagents writes per-agent `.output` transcripts under `<os-tmpdir>/pi-subagents-<uid>/<cwd>/<session>/tasks/<agent-id>.output`. They are temporary and cleared on reboot. |
| `.cursor/skills/`, `~/.cursor/skills/` | `.pi/skills/`, `.agents/skills/`, `~/.pi/agent/skills/`, `~/.agents/skills/`. |
| `~/.cursor/plugins/`, `.cursor-plugin/plugin.json` | jstack is a Pi package. Run `./jstack install-pi` from the checkout, or `pi install <checkout-or-git-url>`; the package root is `<package>`, and `<pstack>` is `<package>/plugins/pstack`. Its `pi.skills` covers `plugins/pstack`, `plugins/spec`, and `plugins/flow`. pstack's entry skills use `disable-model-invocation: true`, so they stay out of the model catalog; invoke them with `/skill:<name>` or read `<pstack>/skills/<name>/SKILL.md`. |
| `.cursor/rules/*.mdc`, always-applied rules | `~/.pi/agent/AGENTS.md` for user-wide instructions, or `AGENTS.md` / `CLAUDE.md` in the project. Pi does not read `.mdc` files. |
| `https://github.com/cursor/plugins/blob/main/pstack/<path>` | `<pstack>/<path>` when that file exists. Read the local copy, never fetch it. |

### setup-pstack

`setup-pstack` does not write Pi config. Print the role lines and the choices, then let the user apply them.

- Detect. The detected models are the ones Pi's model registry accepts for the `Agent` tool, each with a `thinking` level. Write a real model as `<model> <thinking>`, such as `claude-opus-5-5 xhigh`.
- Defaults. Map each default slug by the Models and thinking table: `claude-opus-5-5-xhigh` is `claude-opus-5-5 xhigh`; `grok-4.7-xhigh-fast` is `grok-4.7 xhigh` when that model resolves, otherwise `inherit-parent`.
- Print, don't write. Print the comment lines, the `# budget` line, and one line per role from step 5. Tell the user they can paste them into `~/.pi/agent/AGENTS.md` (the user instructions Pi loads in every session) or set `model` and `thinking` in an agent file. Do not edit either file; the user owns them. Never put the role lines in a project `AGENTS.md` or `CLAUDE.md`.
- Custom agents. A role line cannot override a custom agent's frontmatter `model` or `thinking`. Leave those fields out of the agent file when the role line should control it.

### Cursor-only skips

| Cursor | Pi |
| --- | --- |
| Cursor Automations: routines, `update_state` routine calls, `api2.cursor.sh/automations` webhooks, routine wakes, and `SendToUser` secret requests | Skip with the line. |
| Bugbot | Bugbot comments on a GitHub PR are ordinary review threads, so triage them with the forge command that the step gives. Skip a step that starts, waits for, or configures Bugbot when the PR has no Bugbot check or comment. |
| Cursor cloud agents | Pi has no cloud agents. `isolation: "worktree"` is the local substitute. Skip a step that needs the cloud agent itself, such as its dashboard status or its own machine. |
| A built-in PR tool | Use the forge command that the step gives, such as `gh pr create`. That is not a skip, so write no line. |
| Cursor built-ins and `cursor-team-kit`: `create-skill`, `/loop`, `/deslop`, `control-ui`, `control-cli` | Not built into Pi. Author `SKILL.md` directly, run the loop in the session or the job runner, and use the repo's own UI or CLI driver. Skip a step that needs the Cursor built-in itself with the line. |

When a step needs a Cursor-only feature, put one line in your reply, `Skipped in Pi: <step>. <reason>.`, then go on to the next step. Do not stop, ask, or retry. When a later step needs what the skipped step made, such as a URL or a key, leave a placeholder and name it in the line.

## OMP

OMP is `@oh-my-pi/pi-coding-agent`. It discovers Claude Code marketplace plugins, including jstack's, and their `agents/`, so an installed pstack is discoverable; otherwise point `<pstack>` at the checkout. Only the rows below differ from the Cursor names; map everything else as written.

### Tools

| Cursor | OMP |
| --- | --- |
| `Read`, `Write`, `Edit`, `Bash` | `read`, `write`, `edit`, `bash`. OMP tool names are lowercase. |
| `Grep`, `Glob` | `grep`, `glob`, or `find` for path search. |
| `AskQuestion` | `ask` with a `questions` array. |
| Open a todolist | `todo`. |
| `Task` | `task` (see below). |

### Subagent tool and parameters

| Cursor | OMP |
| --- | --- |
| `Task` | `task`. Parameters: `agent`, `task`, `context`, `name`. `agent` names the subagent type (`task`, `scout`, `reviewer`, `security-reviewer`, `sonic`, or a custom agent); omit it for the default `task`. `task` is the brief; `context` is shared context for batch calls; `name` is a short CamelCase name. One agent per call; parallel work is parallel `task` calls. |
| `subagent_type: generalPurpose` | Omit `agent`; the default is `task`. |
| `poteto-agent`, `comment-sicko` | pstack's plugin agents are discovered from the installed plugin, whether OMP installed it from the jstack marketplace or it comes from Claude Code's plugin cache. Call `agent: "poteto-agent"` or `"comment-sicko"` when pstack is installed there. OMP drops Claude-dialect `model` frontmatter; use the model roles below. If the plugin is not installed, add `poteto-agent.md` or `comment-sicko.md` under `~/.omp/agent/agents/` or `.omp/agents/` with `name`, `description`, `tools`, and poteto-mode's skill-read line; otherwise use the default `task` and put the skill text in the brief. `comment-sicko` can also run as `reviewer`. |
| `environment: "cloud"` | OMP has no cloud agents. Use `isolated: true` when the session's `task` schema lists it (runs in a worktree); otherwise run locally or create the worktree yourself and pass its path. Skip a step that needs the cloud dashboard or machine. |
| `environment: "local"` | Omit. |
| `cloud_base_branch: <b>` | Tell the worker to check out `<b>` first. |
| `resume` | Spawn a new `task` and paste the earlier result into the brief. OMP session resume is per chat, not per subagent. |
| `file_attachments` | List the paths in `task`. |

Some OMP builds add `isolated`, `tools`, `effort` (`lo` / `med` / `hi`), `solutionSpace`, and `outputSchema` to the `task` schema, and a batch form with `context` plus `tasks[]`. Use them only when the session's schema lists them; otherwise drop them.

### Readonly and background

| Cursor | OMP |
| --- | --- |
| `readonly: true` | `agent: "scout"` for exploration; it has only read-only tools. For review, use `agent: "reviewer"` or `"security-reviewer"`; they keep `bash` or `lsp`, so the brief says "do not edit files", and you check `git status` afterward. |
| `readonly: false` | Omit `agent` (default `task`). |
| `run_in_background: true` | No per-call field. Async is a harness setting (`async.enabled`): when on, `task` returns an agent id immediately; when off, the call blocks. Spawn independent work as parallel `task` calls. |

### Models and thinking

| Cursor | OMP |
| --- | --- |
| `claude-<family>-<version>-<effort>[-fast]`, such as `claude-opus-5-5-xhigh` | Map the role, not the literal slug. An agent's `.md` frontmatter `model` takes a model role (`@slow`, `@plan`, `@smol`, `@task`) or a `provider/modelId`. Use `@slow` for judgment and prose, `@plan` for design and architecture, `@smol` for mechanical work, and `@task` for default code work. Drop `-fast`; use `effort` (`lo` / `med` / `hi`) when the schema offers it: `low` → `lo`, `medium` or `high` → `med`, `xhigh` or `max` → `hi`. |
| A `grok-*`, `gpt-*`, or other non-Claude slug | Same role mapping. If the model is not in OMP's registry, use the role's configured model and say so. |
| `auto` or `inherit-parent` | Leave the role at its configured default (`@task` or the `default` model role). |
| A role value `<model> <effort>`, such as `opus high` | `model: "<model>"` and `thinking: "<effort>"` (also read as `thinkingLevel`) in the agent file, or the matching model role. |
| The `pstack-models.mdc` rule, `~/.cursor/rules/pstack-models.mdc` | `~/.omp/agent/rules/pstack-models.md` with `alwaysApply: true`, or the sticky `~/.omp/agent/RULES.md`. |

An agent file's `model` and `thinking` are authoritative. The `task` call has no model parameter; choose the agent or role instead. OMP drops `model` from Claude-dialect plugin agents, including pstack's, so an installed `poteto-agent` runs on the configured role or session model. Use `modelRoles` or an OMP-native copy when a role must be explicit.

### Skill invocation

| Cursor | OMP |
| --- | --- |
| `/name` or "the **name** skill" | `Read` `<pstack>/skills/<name>/SKILL.md` and follow it. OMP has no `Skill` tool. |
| Telling the user to run a pstack skill | `/skill:<name>`, or `skill://<name>` for a direct read. There is no `/pstack:<name>` prefix. |
| Managing a skill | `manage_skill` creates, edits, or deletes skills; it does not invoke them. Use it only for authoring. |
| Installed pstack | OMP marketplace installs live under `~/.omp/plugins/cache/plugins/jstack___pstack___<version>`; `<pstack>` is that directory. OMP also reads Claude Code marketplace plugins under `~/.claude/plugins/cache`. If neither has pstack, point `<pstack>` at the checkout. |
| `disable-model-invocation: true` | Supported. It hides the skill from the model-invocable list, and the read tool's `skill://<name>` may miss it. Read `<pstack>/skills/<name>/SKILL.md` by absolute path; in the interactive CLI, `/skill:<name>` loads it. |

### Session and transcript roots

| Cursor | OMP |
| --- | --- |
| Transcripts in `~/.cursor/projects/<slug>/agent-transcripts/` | `~/.omp/agent/sessions/--path--/session.jsonl`, where `--path--` encodes the workspace path. Read only this workspace's folder. |
| A subagent transcript beside the chat | The session folder's `subagents/` directory holds per-agent `.jsonl` transcripts. |
| `.cursor/skills/`, `~/.cursor/skills/` | `.omp/skills/` (project, walking up) and `~/.omp/agent/skills/` (user). |
| `.cursor/rules/*.mdc`, always-applied rules | `~/.omp/agent/rules/*.md` (or `.mdc`) with `alwaysApply: true`, the sticky `~/.omp/agent/RULES.md`, or a project `.omp/RULES.md`. |
| `~/.cursor/plugins/`, `.cursor-plugin/plugin.json` | OMP plugins and Claude Code marketplace plugins under `~/.claude/plugins/cache`. |
| `https://github.com/cursor/plugins/blob/main/pstack/<path>` | `<pstack>/<path>` when that file exists. Read the local copy, never fetch it. |

### setup-pstack

`setup-pstack` does not write OMP config. Print the role lines and the YAML snippet, then let the user apply them.

- Detect. The detected models are the `provider/modelId` values OMP's model registry and `modelRoles` accept. A real model may carry a `:level` suffix, such as `magpie/auto/deepseek-v4.1-flash:high`.
- Defaults. Map each default slug to a model role: `claude-opus-5-5-xhigh` is the model configured for `@slow` at `xhigh`; `grok-4.7-xhigh-fast` is the model configured for `@task` at `xhigh`. If a role is unset, use the `default` role.
- Print, don't write. Print the comment lines, the `# budget` line, and one line per role from step 5. Print the `modelRoles` YAML for `slow`, `plan`, `smol`, `task`, and `default`. Tell the user they can paste the roles into `~/.omp/agent/config.yml` and the rule lines into `~/.omp/agent/rules/pstack-models.md` with `alwaysApply: true`. Do not edit those files; the user owns them.
- Custom agents. An agent file's `model` and `thinking` are authoritative. Leave them unset when the role line should control the agent.

### Cursor-only skips

| Cursor | OMP |
| --- | --- |
| Cursor Automations: routines, `update_state` routine calls, `api2.cursor.sh/automations` webhooks, routine wakes, and `SendToUser` secret requests | Skip with the line. |
| Bugbot | Bugbot comments on a GitHub PR are ordinary review threads, so triage them with the forge command that the step gives. Skip a step that starts, waits for, or configures Bugbot when the PR has no Bugbot check or comment. |
| Cursor cloud agents | OMP has no cloud agents. Use `isolated: true` when the session's `task` schema lists it, or run locally. Skip a step that needs the cloud agent itself, such as its dashboard status or its own machine. |
| A built-in PR tool | Use the forge command that the step gives, such as `gh pr create`. That is not a skip, so write no line. |
| Cursor built-ins and `cursor-team-kit`: `create-skill`, `/loop`, `/deslop`, `control-ui`, `control-cli` | Not built into OMP. Author `SKILL.md` with `manage_skill` or directly, run the loop in the session or the job runner, and use the repo's own UI or CLI driver. Skip a step that needs the Cursor built-in itself with the line. |

When a step needs a Cursor-only feature, put one line in your reply, `Skipped in OMP: <step>. <reason>.`, then go on to the next step. Do not stop, ask, or retry. When a later step needs what the skipped step made, such as a URL or a key, leave a placeholder and name it in the line.
