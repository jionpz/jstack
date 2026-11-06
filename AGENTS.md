# jstack 维护规则

jstack 是一个 Claude Code marketplace，现在只发布一个插件：原版 pstack 的 Claude Code 版。

- `upstream/pstack/` 是 cursor/plugins 的 `harness/pstack/claude-code` 原样副本，只能由 `./jstack sync` 写入。
- `plugins/pstack/` 是构建产物，只能由 `./jstack build` 写入。
- 要修改 pstack，就在 `patches/pstack/` 下加补丁，格式见 README 的"维护"一节。不要直接改上面两个目录。
- 补丁只修 adapter 管不到的问题：脚本、frontmatter（两者都不经过模型），以及 adapter 本身写错的地方。能靠 `docs/harness/claude-code.md` 在运行时映射的 Cursor 名称，不要打补丁。
- 提交前必须让 `./jstack check` 全部通过。
- 同步上游后，用 `git diff -- upstream/` 看上游改了什么。如果上游已经修好某个补丁对应的问题，就删掉那个补丁。
- 插件名必须保持 `pstack`：adapter 把 agent 映射成 `pstack:poteto-agent`，命令写成 `/pstack:<name>`，都依赖这个名字。
