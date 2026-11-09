# Harness 门禁能力

flow 的三个门禁（阶段提示、验证门禁、红线守卫）的判定逻辑都在 `src/flow/hooks/*.sh`，与 harness 无关。各 harness 用自己的事件把输入翻译成 Claude Code 的 hook 协议，再执行同一个脚本；状态文件格式和会话 id 规则也共用 `lib.sh`。

本文件记录每个 harness 能承载哪些门禁、怎么接、哪些地方降级。Codex 的三个门禁也已接：项目级安装把 hooks 写进 `.codex/hooks.json`；它的 hooks 默认要信任后才执行，非交互运行要加 `--dangerously-bypass-hook-trust`。

## 能力矩阵

| 门禁 | Claude Code | Cursor | Pi | OMP | Codex |
|---|---|---|---|---|---|
| 阶段提示（UserPromptSubmit） | 支持（原生 hooks） | 需适配（`beforeSubmitPrompt` → `additional_context`） | 需适配（`before_agent_start` → 隐藏消息） | 需适配（`before_agent_start` → 隐藏消息） | 需适配（原生 `UserPromptSubmit` → `hookSpecificOutput.additionalContext`） |
| 验证门禁（Stop） | 支持（原生 hooks，`stop_hook_active` 由 harness 维护） | 需适配（`stop` → `followup_message`，`loop_limit` 3） | 需适配（`agent_before_settle`，扩展自己限 3 次） | 需适配（`session_stop` → `decision: block`，`stop_hook_active` 由 harness 维护） | 需适配（原生 `Stop`，`stop_hook_active` 由 harness 维护） |
| 红线守卫（PreToolUse） | 支持（原生 hooks，`permissionDecision: ask`） | 需适配（`beforeShellExecution` → `permission: ask`；`preToolUse` 降级 `deny`） | 需适配（`tool_call` → 确认框或 `block`） | 需适配（`tool_call` → 确认框或 `block`） | 需适配（`PreToolUse` → `permissionDecision: deny`；不支持 ask，降级为 deny） |

“需适配”不是没实现：三个门禁在 Pi、OMP 和 Codex 上都已实现，只是需要各自的事件/协议翻译，并有下面的降级。

## 接入方式

- **Claude Code**：`src/flow/hooks/hooks.json`，插件清单的 `hooks` 字段。
- **Cursor**：`src/flow/hooks/hooks.cursor.json`，由 `.cursor-plugin/plugin.json` 的 `hooks` 字段指向；`./jstack install-cursor` 复制插件树。
- **Pi**：根 `package.json` 的 `pi.extensions` → `plugins/flow/extensions/pi.ts`，`./jstack install-pi`（或 `install --all`）安装 package 后自动加载。扩展用 `import.meta.url` 找到 flow 根，脚本仍从 `plugins/flow/hooks/` 执行。
- **OMP**：OMP 的插件清单只收 skills / agents，不收 flow 的 Claude 格式 hooks。`./jstack install`（用户级）把 `plugins/flow/extensions/omp.ts` 写成一个入口文件 `~/.omp/agent/extensions/jstack-flow-gates.ts`，OMP 的 ambient extension 目录加载它，入口再转出插件里的扩展本身。
- **Codex**：`./jstack install --scope project` 写仓库的 `.codex/hooks.json`，事件名和输入都是 Claude Code 的形状；命令用仓库内 vendor 的绝对路径（Codex 不给项目 hooks 暴露 PROJECT_DIR 一类的变量，仓库搬家后重跑一次 install）。hooks 默认要落过信任才执行：交互式会话里同意一次；headless（`codex exec`）加 `--dangerously-bypass-hook-trust`，只对已审查的 hooks 来源用。

三个门禁都只读状态文件、不调模型；状态文件的路径和格式见 `lib.sh`。

## 会话 id

`stage.sh` 和 hooks 必须拿到同一个会话 id，才读写同一份状态。`lib.sh` 的 `jstack_hook_sid` 按以下顺序取：

1. hook / session 输入里的 `session_id`（Claude Code）或 `conversation_id`（Cursor）
2. `JSTACK_SESSION_ID`
3. `PI_SESSION_ID`
4. `CLAUDE_CODE_SESSION_ID`
5. `CURSOR_CONVERSATION_ID`
6. `CODEX_SESSION_ID`

- Claude Code 在 shell 里导出 `CLAUDE_CODE_SESSION_ID`，hook 输入里也带 `session_id`。
- Cursor 导出 `CURSOR_CONVERSATION_ID`，hook 输入里是 `conversation_id`；两者都是 UUID，URI 编码后不变。
- Pi 给 bash 工具注入 `PI_SESSION_ID`；扩展用 `ctx.sessionManager.getSessionId()` 调 hook。
- OMP 不向 shell 注入会话 id。`extensions/omp.ts` 在 `session_start` / `session_switch` 把根会话 id 写进进程环境 `JSTACK_SESSION_ID`，子 shell 继承。子 agent 会话（`sessionManager.getHeader().parentSession` 非空）不写，继承根会话的 id，和根会话共用同一份阶段记录。
- Codex 给 `shell` 工具的环境导出 `CODEX_SESSION_ID`（与 `CODEX_THREAD_ID` 同值），`codex exec` 里同样可用；hook 输入里也带 `session_id`，两者同值，`stage.sh` 和三个 hook 读写同一份状态。

## 降级

1. **没有 UI 时“先问”变“拦下”**（Cursor 的 `preToolUse`、Pi / OMP 的 print / JSON 运行）：没有人能回答确认框，`guard.sh` 命中的命令直接拒绝执行，不会先运行。交互式会话（包括 Claude Code 的 `bypassPermissions`）仍弹确认框。
2. **Pi 的 Stop 门禁每条用户消息最多拦 3 次**：Pi 没有 Claude Code / Cursor / OMP 那种由 harness 维护的 `stop_hook_active`，`agent_before_settle` 的 `continue` 只对本次结算有效。扩展自己计数，模型硬顶着不记证据时第 4 次放行；用户发新消息或门禁满足时清零。代价是模型坚持不记证据时会溜过去，收益是不会无限续跑。
3. **Cursor 的 Stop 门禁拿不到最后一条回复**：标了 `ask` 时直接放行，无法核对回复里是否真的提了问题；`loop_limit` 3 兜底。
4. **OMP 的扩展目前只装在用户级**：`./jstack install --scope project` 不写 `~/.omp/agent/extensions/`（项目级扩展要写 `.omp/config.yml`，尚未接入）。扩展入口写的是最后一次用户级 `./jstack install` 的 checkout 绝对路径，与项目 vendor 的版本可能漂移；更新或移动 checkout 后重跑一次用户级 install。扩展缺失时 OMP 里没有门禁，`stage.sh` 打印“这个 harness 没有会话 id”。
5. **子 agent 会话不跑门禁**：Pi / OMP 的扩展跳过 `parentSession` 非空的会话。子 agent 不该也不能替主会话记证据；它的 shell 继承根会话 id，只读同一份状态。
6. **Codex 的 ask 降级为 deny，hooks 要先信任**：Codex 的 `PreToolUse` 只认 deny，返回 `permissionDecision: ask` 会被忽略、命令照跑（0.166.0 实测），所以 `guard.sh` 在 Codex 输入下直接 deny，和 Cursor 的 `preToolUse` 同规则，交互式会话里也没有“先问”这一步。另外 Codex 的 hooks 默认要落过信任才执行：交互式会话首次会要求同意；`codex exec` 不加 `--dangerously-bypass-hook-trust` 就静默跳过未信任的 hooks。

## 收尾报告

route 的收尾报告（`src/flow/skills/route/SKILL.md` 第 5 节）要写明门禁是否生效：

- `stage.sh` 打印“这个 harness 没有会话 id” → 报告里写“本会话阶段门禁未生效（<harness>）”。
- OMP 会话里没有 `~/.omp/agent/extensions/jstack-flow-gates.ts` → 同样视为未生效。
- Codex 会话里仓库没有 `.codex/hooks.json`（或 hooks 没被信任）→ 同样视为未生效。
- 其余情况不写。

## 验证

- `bash tests/flow-hooks.sh`：三个 hook 的协议、会话 id 回退、仓库配置；不依赖 harness。
- `./jstack smoke pi` / `./jstack smoke omp` / `./jstack smoke codex`：在真机上跑非交互会话，断言 `rm -rf` 被拦（`GUARD-SEEN`）、`stage.sh start execute,verify` 后停止被 Stop 门禁拦回（`GATE-SEEN`）。没装对应 harness 自动跳过。
- 手工：交互式会话里跑一次命中 must-stop 的命令，确认弹确认框；`stage.sh show` 看状态落在 `~/.local/state/jstack/sessions/<id>`。
