# Cursor 手动 smoke

Cursor 没有可脚本化的 headless agent CLI，这一份是 Cursor 本地插件的可重复检查清单。结构性检查由 `./jstack check` 和下面的 shell 命令负责；交互部分在 Cursor 应用里完成。

## 准备

```bash
./jstack build
./jstack install-cursor          # 默认复制；改了构建产物后重跑
```

`install-cursor` 把三个产物复制到 Cursor 的本地插件目录（Cursor 的加载器拒绝指向该目录之外的符号链接）：

```text
~/.cursor/plugins/local/pstack/   # 上游 Cursor 原生树，来自 plugins/pstack-cursor
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

`./jstack smoke cursor` 直接调用 Cursor.app 内的 `plugins-loader.cjs`，断言三个插件都被加载、`flow` 有 `route`、`pstack` 有 `poteto-mode` 和 `poteto-agent`、`spec` 有 `grill-with-docs`，并在 Cursor 布局下运行 `locate.sh`。它不启动模型，也不覆盖下面的交互检查。

第二条命令应打印 7 行，覆盖 `poteto-mode`、`setup-matt-pocock-skills`、`grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`，且每行路径都存在。

## 交互检查

1. **插件被发现**：Plugins 列表里能看到本地插件 `pstack`、`spec`、`flow`；三个版本都带 `+jstack.<hash>`。
2. **skill 被发现**：Agent 会话里输入 `/`，能看到 `/poteto-mode`、`/route`、`/grill-with-docs`、`/to-spec`、`/setup-matt-pocock-skills`。
3. **route → pstack**：运行 `/route 用一句话说明这个仓库是做什么的，不要改文件`。route 应把它判成调查类，读 `poteto-mode` 的 SKILL.md 后直接执行。
4. **route → spec**：运行 `/route 这个仓库的安装流程有两种合理解释，先澄清再拆解，暂时不要实现`。route 应判成 M/ambiguous 或 L，先读 `grill-with-docs` 的 SKILL.md；确认它能进入澄清轮，再停止。
5. **agent 能派发**：让 poteto-mode 派一个只读子 agent（例如读 README 的 `Task`），确认 Cursor 的 subagent 面板出现，结果回到主会话。也可以直接确认 `agents/poteto-agent.md` 的 `is_background: true` 和 `agents/comment-sicko.md` 都在。
6. **装的是原生树**：`~/.cursor/plugins/local/pstack/agents/poteto-agent.md` 保留 `is_background: true`；`pstack/skills/` 里没有 “In Claude Code” 的 adapter 引导。这说明 Cursor 用的是上游原生树，不是 Claude Code 树。
7. **spec/flow 的 Cursor manifest**：`~/.cursor/plugins/local/spec/.cursor-plugin/plugin.json` 的 `skills` 是一个 10 项的数组；`flow` 的 `skills` 是 `"./skills/"`。

## 失败时记录

- Cursor 版本。
- `ls -la ~/.cursor/plugins/local/{pstack,spec,flow}` 的结果；它们应该是普通目录，不是指向仓库的符号链接。
- 对应插件 `.cursor-plugin/plugin.json` 的 `name` 和 `version`。
- Cursor 开发者工具 Console 里与插件加载相关的错误。
