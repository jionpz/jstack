# Cursor 手动 smoke

Cursor 没有可脚本化的 headless agent CLI，这一份是 Cursor 本地插件的可重复检查清单。结构性检查由 `./jstack check` 和下面的 shell 命令负责；交互部分在 Cursor 应用里完成。

## 准备

```bash
./jstack build
./jstack install-cursor          # 默认复制；改了构建产物后重跑
```

`install-cursor` 把三个产物复制到 Cursor 的本地插件目录（Cursor 的加载器拒绝指向该目录之外的符号链接）：

```text
~/.cursor/plugins/local/pstack/   # 由 plugins/pstack 转换生成，来自 plugins/pstack-cursor
~/.cursor/plugins/local/spec/     # 双 manifest，来自 plugins/spec
~/.cursor/plugins/local/flow/     # 双 manifest，来自 plugins/flow
```

重开 Cursor 窗口，或在命令面板运行 reload。

## 结构检查

```bash
./jstack smoke cursor          # Cursor 自带 plugins-loader + route locate.sh

# 也可以手动核对
for name in pstack spec flow; do
  manifest="$HOME/.cursor/plugins/local/$name/.cursor-plugin/plugin.json"
  test -f "$manifest" && grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" "$manifest" && echo "$name OK"
done

bash "$HOME/.cursor/plugins/local/flow/skills/route/locate.sh"
```

`./jstack smoke cursor` 直接调用 Cursor.app 内的 `plugins-loader.cjs`，断言三个插件都被加载、`flow` 有 `route`、`pstack` 有 `poteto-mode` 和 `poteto-agent`、`spec` 有 `grill-with-docs`、`flow` 的 hooks 配置里有 `beforeShellExecution` / `beforeSubmitPrompt` / `stop`，并在 Cursor 布局下运行 `locate.sh`。随后按 Cursor 的 hook 协议喂三份输入，确认安装副本里的 guard 返回 `permission: ask`、stop 返回 `followup_message`、prompt 返回 `additional_context`。它不启动模型，也不覆盖下面的交互检查。

第二条命令应打印 7 行，覆盖 `poteto-mode`、`setup-matt-pocock-skills`、`grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`，且每行路径都存在。

## 交互检查

1. **插件被发现**：Plugins 列表里能看到本地插件 `pstack`、`spec`、`flow`；三个版本都带 `+jstack.<hash>`。
2. **skill 被发现**：Agent 会话里输入 `/`，能看到 `/poteto-mode`、`/route`、`/grill-with-docs`、`/to-spec`、`/setup-matt-pocock-skills`。
3. **route → pstack**：运行 `/route 用一句话说明这个仓库是做什么的，不要改文件`。route 应把它判成调查类，读 `poteto-mode` 的 SKILL.md 后直接执行。
4. **route → spec**：运行 `/route 这个仓库的安装流程有两种合理解释，先澄清再拆解，暂时不要实现`。route 应判成 M/ambiguous 或 L，先读 `grill-with-docs` 的 SKILL.md；确认它能进入澄清轮，再停止。
5. **agent 能派发**：让 poteto-mode 派一个只读子 agent（例如读 README 的 `Task`），确认 Cursor 的 subagent 面板出现，结果回到主会话。也可以直接确认 `agents/poteto-agent.md` 的 `is_background: true` 和 `agents/comment-sicko.md` 都在。
6. **装的是转换产物**：`~/.cursor/plugins/local/pstack/agents/poteto-agent.md` 保留 `is_background: true`；`pstack/skills/` 里没有「If you are not in Cursor, read the harness adapter」的引导。这说明 Cursor 用的是从 Claude 树转换出的产物，不是 Claude Code 树。
7. **spec/flow 的 Cursor manifest**：`~/.cursor/plugins/local/spec/.cursor-plugin/plugin.json` 的 `skills` 是一个 10 项的数组；`flow` 的 `skills` 是 `"./skills/"`，`hooks` 指向 `"./hooks/hooks.cursor.json"`。
8. **阶段提示**：让 route 进入某个阶段后，再发一条消息，回复的上下文里应出现「jstack 阶段门禁：当前阶段 …」。没有阶段记录时不应出现。
9. **must-stop 确认**：让 agent 运行 `rm -rf build`（或 `git push --force`），Cursor 应弹出命令确认，提示里带 `jstack must-stop:`；取消后命令不执行。
10. **Stop 门禁**：当前阶段在 execute 或 verify、没有记录任何 `stage.sh evidence`，让 agent 直接宣布完成；Cursor 应自动追加一条 `followup_message`，内容包含「jstack verify 门禁」并把 agent 拉回验证。记录一条证据后再让它结束，不应再被拦。
11. **项目级安装的 hooks**：如果用 `./jstack install --all --scope project` 接入，检查仓库的 `.cursor/hooks.json` 里有三条 jstack 的 hook，命令指向 `.jstack/vendor/plugins/flow/hooks/`；重开 Cursor 后重复第 8–10 项。

## 失败时记录

- Cursor 版本。
- `ls -la ~/.cursor/plugins/local/{pstack,spec,flow}` 的结果；它们应该是普通目录，不是指向仓库的符号链接。
- 对应插件 `.cursor-plugin/plugin.json` 的 `name` 和 `version`。
- 项目级安装时 `.cursor/hooks.json` 的内容；用户级安装时 `~/.cursor/plugins/local/flow/hooks/hooks.cursor.json` 是否存在。
- Cursor 开发者工具 Console 里与插件加载、hook 执行相关的错误。
