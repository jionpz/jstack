# Codex 手动 smoke

Codex 有可脚本化的 headless CLI，`./jstack smoke codex` 已经覆盖非交互路径（route、子 agent、三个门禁）。这一份是交互式会话与 hooks 信任的检查清单：hooks 默认要落过信任才执行，自动化用 `--dangerously-bypass-hook-trust` 跳过，信任提示和拒绝后的行为只能手动确认。

## 准备

```bash
./jstack build
./jstack install --all --scope project --repo <仓库>
```

项目级安装写 `<仓库>/.codex/hooks.json`，三条命令指向 `<仓库>/.jstack/vendor/plugins/flow/hooks/`。Codex 不给项目 hooks 暴露 `PROJECT_DIR` 一类的变量，所以命令是绝对路径；仓库搬家后要重跑一次 install。

在该仓库里启动交互式 `codex`。首次启动会提示 hooks 需要信任（列出 `.codex/hooks.json` 的三条），同意后 hooks 才执行。

## 结构检查

```bash
./jstack smoke codex                      # 隔离 CODEX_HOME 的非交互验收
jq '.hooks | keys' <仓库>/.codex/hooks.json   # ["PreToolUse","Stop","UserPromptSubmit"]
```

smoke 断言：入口 skill 可见、`locate.sh` 找到阶段表的全部提供者、`poteto-agent` 作为自定义 agent 派出、`rm -rf` 被 deny（`GUARD-SEEN`）、`stage.sh start execute,verify` 后停止被 Stop 门禁拦回（`GATE-SEEN`）。

## 交互检查

1. **hooks 信任**：首次启动提示信任 `.codex/hooks.json`；拒绝后三个门禁全部静默不执行（Codex 的默认行为，不是 jstack 的问题）。
2. **阶段提示**：route 进入某个阶段后再发一条消息，回复的上下文里应出现「jstack 阶段门禁：当前阶段 …」。没有阶段记录时不应出现。
3. **must-stop**：让 agent 运行 `rm -rf build`。Codex 的 `PreToolUse` 只认 `deny`，命令应被直接拦下，理由带 `jstack must-stop:`；交互式会话里也没有确认框，这是和 Claude Code 的区别（降级写在 `docs/harness/gates.md` 第 6 条）。
4. **Stop 门禁**：当前阶段在 execute 或 verify、没有记录任何 `stage.sh evidence`，让 agent 直接宣布完成；应返回 `decision: block` 并把它拉回验证。记录一条证据后再让它结束，不应再被拦。`stop_hook_active` 由 Codex 维护，每次停止最多拦一次。
5. **会话 id**：`stage.sh show` 和 hooks 读写同一个 `~/.local/state/jstack/sessions/<id>`；`<id>` 等于会话里 `echo $CODEX_SESSION_ID` 的值。

## 失败时记录

- `codex --version`。
- `<仓库>/.codex/hooks.json` 的内容，以及它是否已被信任（`~/.codex/config.toml` 的 `[hooks.state."…"]` 条目；不要贴 auth 段）。
- 是否仓库搬家后没有重跑 install（绝对路径失效）。
