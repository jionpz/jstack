# Harness 门禁能力

flow 的三个门禁（阶段提示、验证门禁、红线守卫）的判定逻辑都在 `src/flow/hooks/*.sh`，与 harness 无关。各 harness 用自己的事件把输入翻译成 Claude Code 的 hook 协议，再执行同一个脚本；状态文件格式和会话 id 规则也共用 `lib.sh`。

本文件记录每个 harness 能承载哪些门禁、怎么接、哪些地方降级。Codex 的三个门禁也已接：项目级安装把 hooks 写进 `.codex/hooks.json`；它的 hooks 默认要信任后才执行，非交互运行要加 `--dangerously-bypass-hook-trust`。Workloop 的会话 id 已接，但平台没有 Stop hook，门禁只能降级为 agent 自检，见“降级”第 7 条。

## 能力矩阵

| 门禁 | Claude Code | Cursor | Pi | OMP | Codex |
|---|---|---|---|---|---|
| 发布支持 | 一等 | 尽力而为 | 一等 | 尽力而为 | 尽力而为 |
| 阶段提示（UserPromptSubmit） | 支持（原生 hooks） | 需适配（`beforeSubmitPrompt` → `additional_context`） | 需适配（`before_agent_start` → 隐藏消息） | 需适配（`before_agent_start` → 隐藏消息） | 需适配（原生 `UserPromptSubmit` → `hookSpecificOutput.additionalContext`） |
| 验证门禁（Stop） | 支持（原生 hooks，`stop_hook_active` 由 harness 维护） | 需适配（`stop` → `followup_message`，`loop_limit` 3） | 需适配（`agent_before_settle`，扩展自己限 3 次） | 需适配（`session_stop` → `decision: block`，`stop_hook_active` 由 harness 维护） | 需适配（原生 `Stop`，`stop_hook_active` 由 harness 维护） |
| 红线守卫（PreToolUse） | 支持（原生 hooks，`permissionDecision: ask`） | 需适配（`beforeShellExecution` → `permission: ask`；`preToolUse` 降级 `deny`） | 需适配（`tool_call` → 确认框或 `block`） | 需适配（`tool_call` → 确认框或 `block`） | 需适配（`PreToolUse` → `permissionDecision: deny`；不支持 ask，降级为 deny） |

“需适配”不是没实现：三个门禁在 Pi、OMP 和 Codex 上都已实现，只是需要各自的事件/协议翻译，并有下面的降级。

`./jstack check --smoke` 与 `./jstack smoke all` 要求 Claude Code 和 Pi 的烟测通过；OMP、Cursor、Codex 缺失或失败会在输出里报告。单独运行 `./jstack smoke <harness>` 时，被指定的 harness 必须可用并通过。发布还需通过 Claude Code 和 Pi 的评测，见 [ADR-0002](../adr/0002-flow-is-the-product.md#发布支持分级)。

## 接入方式

- **Claude Code**：`src/flow/hooks/hooks.json`，插件清单的 `hooks` 字段。
- **Cursor**：`src/flow/hooks/hooks.cursor.json`，由 `.cursor-plugin/plugin.json` 的 `hooks` 字段指向；`./jstack install-cursor` 复制插件树。项目级安装使用 `.cursor/hooks.json`，从 `.claude/settings.json` 导入的 jstack 项目 hooks 在 Cursor 中退出。
- **Pi**：根 `package.json` 的 `pi.extensions` → `plugins/flow/extensions/pi.ts`，`./jstack install-pi`（或 `install --all`）安装 package 后自动加载。项目级安装在 `.pi/extensions/jstack-flow-gates.ts` 写相对路径入口，转出 `.jstack/vendor/plugins/flow/extensions/pi.ts`。扩展用 `import.meta.url` 找到 flow 根，脚本从对应安装树的 `hooks/` 执行。Pi 的项目扩展需要信任；项目 smoke 对临时安装使用 `--approve`。
- **OMP**：OMP 的插件清单只收 skills / agents，不收 flow 的 Claude 格式 hooks。用户级 `./jstack install` 把 `plugins/flow/extensions/omp.ts` 写成 `~/.omp/agent/extensions/jstack-flow-gates.ts`；项目级安装写 `.omp/extensions/jstack-flow-gates.ts`，相对路径转出 `.jstack/vendor/plugins/flow/extensions/omp.ts`。OMP 的对应 extension 目录加载入口文件。
- **Codex**：项目级安装写 `.codex/hooks.json`。命令从会话目录解析 Git 根并执行该 checkout 的 vendor 脚本。交互式会话在审查并信任 hooks 后执行。已审查来源的自动化测试可使用 `--dangerously-bypass-hook-trust`。

三个门禁都只读状态文件、不调模型；状态文件的路径和格式见 `lib.sh`。任务正常收尾时 `stage.sh` 在同一级的 `runs.jsonl` 追加一行运行记录；没有收尾的任务留在 `runs/active/`，`./jstack runs` 会把它标成未完成。记录只含仓库、规模、阶段路径、证据、默认决定、打断次数和耗时等元数据，不含提示词或代码 diff。

提示 hook 每轮输出 `jstack 提示门禁注入：session=<id>`，尚未执行 `stage.sh start` 时也输出，供 agent 核对本会话确实收到过 harness 注入。看到源码中的字符串、配置存在或手动运行 hook 都不算收到注入；这个标记只证明提示 hook 运行，不能代替 Stop/guard 的实际拦截证据。

## 会话 id

`stage.sh` 和 hooks 必须拿到同一个会话 id，才读写同一份状态。相同的 id 不是主代理身份的证明。`lib.sh` 的 `jstack_hook_sid` 按以下顺序取：

1. hook / session 输入里的 `session_id`（Claude Code）或 `conversation_id`（Cursor）
2. `JSTACK_SESSION_ID`
3. `PI_SESSION_ID`
4. `CLAUDE_CODE_SESSION_ID`
5. `CURSOR_CONVERSATION_ID`
6. `CODEX_SESSION_ID`
7. `WORKLOOP_SESSION_ID`

- Claude Code 在 shell 里导出 `CLAUDE_CODE_SESSION_ID`，hook 输入里也带 `session_id`。
- Cursor 导出 `CURSOR_CONVERSATION_ID`，hook 输入里是 `conversation_id`；两者都是 UUID，URI 编码后不变。
- Pi 给 bash 工具注入 `PI_SESSION_ID`；扩展用 `ctx.sessionManager.getSessionId()` 调 hook。
- OMP 不向 shell 注入会话 id。`extensions/omp.ts` 在 `session_start` / `session_switch` 把根会话 id 写进进程环境 `JSTACK_SESSION_ID`，子 shell 继承。子 agent 会话（`sessionManager.getHeader().parentSession` 非空）不写，继承根会话的 id，和根会话共用同一份阶段记录。
- Codex 给 `shell` 工具的环境导出 `CODEX_SESSION_ID`（与 `CODEX_THREAD_ID` 同值），`codex exec` 里同样可用；hook 输入里也带 `session_id`，两者同值，`stage.sh` 和三个 hook 读写同一份状态。
- Workloop 沙箱的 shell 环境里有 `WORKLOOP_SESSION_ID`；`stage.sh` 能记阶段和证据。

## 阶段证据与完成条件（#58）

阶段状态仍是每个 session 一份纯文本，但结果必须由明确的阶段命令写入。进入 `verify` 后用 `stage.sh evidence "<命令> -> <实际结果>"` 产生 `evidence verify ...`；进入 `review` 后记录 `review finding <ID> ...`、每条 `review resolution <ID> fixed|dismissed <原因>`，最后 `review complete <总结>`；进入 `land` 后记录 `land commit <SHA>`，远端仓库还需 `land pr <URL>`。Stop hook 和 `stage.sh end` 共用 `lib.sh` 的验证条件，旧格式自由文本不会自动视为阶段完成。

待决问题必须通过 `stage.sh ask "<具体问题？>"` 排队。Claude Code、Pi/OMP、Codex 的 Stop 输入包含最后回复时，必须出现同一条完整问题才暂停；Cursor 无法取得最后回复内容，只能检查是否有排队问题。输入里的 `agent_id` 是 Claude Code PreToolUse 的身份线索，不是任意 shell 命令的不可伪造凭证。缺少 hook 的环境仍可能无强制门禁。

## 降级

1. **没有 UI 时“先问”变“拦下”**（Cursor 的 `preToolUse`、Pi / OMP 的 print / JSON 运行）：没有人能回答确认框，`guard.sh` 命中的命令直接拒绝执行，不会先运行。交互式会话（包括 Claude Code 的 `bypassPermissions`）仍弹确认框。
2. **Pi 的 Stop 门禁每条用户消息最多拦 3 次**：Pi 没有 Claude Code / Cursor / OMP 那种由 harness 维护的 `stop_hook_active`，`agent_before_settle` 的 `continue` 只对本次结算有效。扩展自己计数，模型硬顶着不记证据时第 4 次放行；用户发新消息或门禁满足时清零。代价是模型坚持不记证据时会溜过去，收益是不会无限续跑。
3. **Cursor 的 Stop 门禁拿不到最后一条回复**：标了 `ask` 时直接放行，无法核对回复里是否真的提了问题；`loop_limit` 3 兜底。
4. **OMP 扩展缺失时门禁不生效**：用户级检查 `~/.omp/agent/extensions/jstack-flow-gates.ts`；项目级检查 `.omp/extensions/jstack-flow-gates.ts`。用户级入口仍引用安装时 checkout 的绝对路径，移动 checkout 后需重跑用户级 install。若当前作用域的入口文件缺失或未加载，`stage.sh` 打印“这个 harness 没有会话 id”。
5. **子 agent 状态隔离是有限保护，不是沙箱**：Pi / OMP 的扩展跳过 `parentSession` 非空会话的提示和 Stop 门禁；在识别到子代理的 `tool_call(bash)` 中，扩展拒绝直接调用会修改主状态的 `stage.sh` 命令。Claude Code 的 `PreToolUse` 提供 `agent_id` 时，`guard.sh` 同样拒绝直接修改状态的命令。`stage.sh` 收到 `JSTACK_SUBAGENT_ID` 也直接拒绝写入。**但是**子代理 shell 可能继承根会话 id，经过 wrapper/间接脚本、无 hook 或未受信任的 hook 仍可能绕过普通命令匹配；不能将此机制称为 OS 级权限隔离。主会话必须亲自读取子代理结果、重新验证并记录阶段凭据；真正防篡改需要独立可验证的子代理身份或文件访问隔离。
6. **Codex 的 ask 降级为 deny，hooks 要先信任**：Codex 的 `PreToolUse` 只认 deny，返回 `permissionDecision: ask` 会被忽略、命令照跑（0.166.0 实测），所以 `guard.sh` 在 Codex 输入下直接 deny，和 Cursor 的 `preToolUse` 同规则，交互式会话里也没有“先问”这一步。另外 Codex 的 hooks 默认要落过信任才执行：交互式会话首次会要求同意；`codex exec` 不加 `--dangerously-bypass-hook-trust` 就静默跳过未信任的 hooks。
7. **Workloop 三个门禁都不强制**：Workloop 是第三方云端编码平台，没有 Stop hook，也没有已知的扩展点。`stage.sh start` 会打印未强制提示；agent 结束前自己运行 `stage.sh show` 核对证据，收尾摘要的门禁一行写明未强制。这是自检，不是门禁。本地 `./jstack smoke` 跑不到 Workloop，只能在它的沙箱里手动验收。

## 收尾报告

route 的收尾摘要（`src/flow/skills/route/SKILL.md` 第 5 节）始终包含“门禁”一行，分别记录提示注入和实际拦截证据：

- `stage.sh` 打印“这个 harness 没有会话 id” → 摘要里写“本会话阶段门禁未生效（<harness>）”。
- Pi 用户级通过 package manifest 加载扩展，没有 `jstack-flow-gates.ts` 入口；项目级入口在 `.pi/extensions/`。OMP 用户级入口在 `~/.omp/agent/extensions/`，项目级在 `.omp/extensions/`。入口缺失或未信任可能导致没有注入，最终以本会话实际收到的标记为准；配置文件存在或 shell 有会话 id 都不能证明门禁已加载。
- Codex 会话里仓库没有 `.codex/hooks.json`（或 hooks 没被信任）→ 同样视为未生效。
- Workloop 会话（`stage.sh start` 打印未强制提示）→ 写“本会话阶段门禁未强制（Workloop）”。
- 收到本会话的注入标记 → 写“提示注入已观测”。Stop/guard 只有真正由 harness 执行过相应门禁时才写“已观测”，否则写“未验证”；提示标记不能证明另外两项已启用。

## 验证

- `bash tests/flow-hooks.sh`：三个 hook 的协议、会话 id 回退、仓库配置；不依赖 harness。
- `./jstack smoke pi` / `./jstack smoke omp` / `./jstack smoke codex`：在真机上跑非交互会话，断言 `rm -rf` 被拦（`GUARD-SEEN`）、`stage.sh start execute,verify` 后停止被 Stop 门禁拦回（`GATE-SEEN`）。没装对应 harness 自动跳过。
- 手工：交互式会话里跑一次命中 must-stop 的命令，确认弹确认框；Codex 的 hooks 信任与 deny 行为按 `docs/testing/codex.md` 核对。`stage.sh show` 看状态落在 `~/.local/state/jstack/sessions/<id>`。

## 短路径的改动范围复核

在 Git 工作树中，route 给含 `execute,verify,land` 的 XS/S 路径加上 `--recheck-size`，前提是有效阶段表提供 `review` 且可使用 Python 3.9 及以上。它在编辑前记录 Git 基线和已有编辑的内容摘要。进入 verify 时比较实际改动，直接进入 land 时也会复核。已有编辑如果内容未变，不计入本次工作范围。

跨目录模块、超过三个变动路径，或触及 `api`、`schemas`、`hooks` 等边界路径时，路径扩展为 `execute → verify → review → land`。同一个模块的少量改动沿用原路径。目录规则用 `src/<模块>`、`packages/<包>` 等目录作为模块近似值，测试和文档仍计入文件数。路径一旦扩展，本任务保留 review，审查结论和发现处置齐全后才进入 land。实际 API 兼容性和 must-stop 授权仍按项目约定取证。
