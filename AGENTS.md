# jstack 维护规则

jstack 是一个 Claude Code marketplace，发布三个插件：

- `pstack`：原版 pstack（Lauren Tan）的 Claude Code 版，源码 vendor 自 cursor/plugins 的 `harness/pstack/claude-code`。
- `spec`：Matt Pocock skills 里负责需求澄清和任务拆解的几个，vendor 自 mattpocock/skills。产出交给 `/pstack:poteto-mode` 执行。
- `flow`：jstack 自己写的衔接层，只有一个 `route` skill，按任务大小把 spec 和 pstack 接起来。没有上游，源码在 `src/flow/`，直接改源码再 `./jstack build`。

- `upstream/<插件>/` 是上游原样副本，只能由 `./jstack sync <插件>` 写入。pstack 是整棵树；spec 只取 `jstack` 脚本里 `PICK` 列出的文件和目录。
- `plugins/<插件>/` 是构建产物，只能由 `./jstack build` 写入。
- 要修改某个插件，就在 `patches/<插件>/` 下加补丁，格式见 README 的"维护"一节。不要直接改上面两个目录。
- 补丁只修上游管不到、或不能原样收的部分：
  - pstack：脚本、frontmatter（两者都不经过模型），以及 adapter 本身写错的地方。能靠 `docs/harness/claude-code.md` 在运行时映射的 Cursor 名称，不要打补丁。
  - spec：manifest。上游的 `plugin.json` 叫 `mattpocock-skills` 并列全 27 个 skill，不能原样收；由 `patches/spec/0001` 新建一个只列 10 个 skill 的清单。
- spec 只收需求澄清和任务拆解。不要收 `implement`、`implement-spec`、`ask-matt` 这类实现编排，它们会和 `poteto-mode` 抢主编排。增删 skill 时，`jstack` 的 `PICK` 和 `patches/spec/0001` 的 `skills` 清单要一起改；漏掉被调用的 skill 时 `./jstack check` 会报。
- 提交前必须让 `./jstack check` 全部通过。
- 同步上游后，用 `git diff -- upstream/` 看上游改了什么。如果上游已经修好某个补丁对应的问题，就删掉那个补丁。
- route 依赖 spec 和 pstack 的入口路径（见 `src/flow/skills/route/locate.sh`）。上游改了 skill 名或目录时，同步改 locate.sh。
- 插件名必须保持 `pstack`、`spec`、`flow`：skill 以插件名为命令前缀（`/pstack:<name>`、`/spec:<name>`），adapter 还把 agent 映射成 `pstack:poteto-agent`。改名会让这些引用全部失效。
