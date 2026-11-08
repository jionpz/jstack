# jstack 维护规则

jstack 是用户长期维护的整条 AI 开发工作流。flow 定义工作流的阶段和门禁，上游 skill 只是当前绑定在某个阶段上的提供者，可以被改写或替换（ADR-0002）。模型分两层（ADR-0003），人工介入按风险自判（ADR-0004），任务只记在 tracker（ADR-0005），安装以项目级为一等公民、配置分用户级和仓库级（ADR-0006）。改动工作流前先读这几份 ADR。Claude Code 是主力 harness，同时支持 Pi、OMP、Codex、Cursor。

当前以插件 marketplace 的形式发布三个插件：

- `pstack`：原版 pstack（Lauren Tan）的 Claude Code 版，源码 vendor 自 cursor/plugins 的 `harness/pstack/claude-code`。Cursor 用上游原生的 `pstack/` 树，单独构建为 Cursor-native 产物。
- `spec`：Matt Pocock skills 里负责需求澄清和任务拆解的几个，vendor 自 mattpocock/skills。产出交给 pstack 的 `poteto-mode` 执行。
- `flow`：jstack 自己写的衔接层，有 `route` 和 `archive` 两个 skill：`route` 按 `src/flow/skills/route/stages.md` 的阶段表驱动任务走完全部阶段，把每个阶段交给表里的提供者。没有上游，源码在 `src/flow/`，直接改源码再 `./jstack build`。

- `upstream/<插件>/` 是上游原样副本，只能由 `./jstack sync <插件>` 写入。`pstack`（Claude Code 版）和 `pstack-cursor`（Cursor 原生版）都是整棵树；spec 只取 `jstack` 脚本里 `PICK` 列出的文件和目录。
- `plugins/<插件>/` 是构建产物，只能由 `./jstack build` 写入。`plugins/pstack-cursor/` 是 Cursor 原生产物，不进 Claude marketplace；`./jstack install-cursor` 把 pstack、spec、flow 三个产物复制到 Cursor 的本地插件目录（flow 的 `hooks/` 只为 Claude Code 写过，复制时排除）。Cursor 的本地插件加载器拒绝指向 `~/.cursor/plugins/local` 之外的符号链接，所以这里只复制。
- spec 和 flow 同时带 `.claude-plugin/plugin.json`（Claude Code）和 `.cursor-plugin/plugin.json`（Cursor）。两个 manifest 的 `name` 必须等于插件名，`version` 由 `build` 同步重写；`jstack check` 会核对。spec 的 Cursor manifest 由 `patches/spec/0003-cursor-manifest.patch` 新建，flow 的直接放在 `src/flow/.cursor-plugin/`。
- 要修改某个插件，就在 `patches/<插件>/` 下加补丁，格式见 README 的"维护"一节。不要直接改上面两个目录。`pstack-cursor` 是上游原生树，默认不打补丁。
- 补丁只修上游管不到、或不能原样收的部分：
  - pstack：脚本、frontmatter（两者都不经过模型），以及 adapter 本身写错的地方。能靠 `docs/harness/agents.md` 在运行时映射的 Cursor 名称，不要打补丁。`docs/harness/agents.md` 是唯一 adapter，`docs/harness/claude-code.md` 只保留指向它的兼容指针。
  - spec：manifest，以及 harness 没有 `Skill` 工具时按名字加载 skill 的 fallback 说明。上游的 `plugin.json` 叫 `mattpocock-skills` 并列全 27 个 skill，不能原样收；由 `patches/spec/0001` 新建一个只列 10 个 skill 的清单。fallback 只补调用方式，不改 skill 的业务内容。
- spec 只收需求澄清和任务拆解。不要收 `implement`、`implement-spec`、`ask-matt` 这类实现编排，它们会和 `poteto-mode` 抢主编排。增删 skill 时，`jstack` 的 `PICK` 和 `patches/spec/0001` 的 `skills` 清单要一起改；漏掉被调用的 skill 时 `./jstack check` 会报。
- 提交前必须让 `./jstack check` 全部通过。改了 adapter、安装方式、manifest 或 Pi package 时，再跑 `./jstack check --smoke`（或 `./jstack smoke all`）：它会启动本机已装的 Pi、OMP、Cursor 做 headless 验收，没装的 harness 自动跳过。smoke 会消耗 token，不是每次提交的硬性门禁，但发布前必须跑过。
- 改 `src/flow`、`patches/`（包括 adapter）、同步上游、改模型配置或 hooks 之前，先跑 `./jstack eval`，把结果和 `evals/results.jsonl` 里最近一次同模型的基线对比；退化要修掉，或者在提交说明里写明理由。判断退化至少用 `--samples 3`。改了 `evals/` 本身就重跑一份基线。`evals/tasks` 的题目由 `./jstack check` 自检（初始状态失败、参考解通过）。细节见 README 的“评测”一节。
- 模型分层只由 `~/.config/jstack/models.json` 决定。改模型选择用 `./jstack models set`，不要在 skill 或规则文件里写死模型；改 `apply` 生成的规则格式后跑 `./jstack check`（models 项会在临时 HOME 里核对角色表、settings 备份、幂等、dry-run 和预算降级）。
- 根目录 `package.json` 是 Pi package manifest，`pi.skills` 必须覆盖 `plugins/pstack/skills`、`plugins/spec/skills`、`plugins/flow/skills`；`./jstack check` 会核对。
- 同步上游后，用 `git diff -- upstream/` 看上游改了什么。如果上游已经修好某个补丁对应的问题，就删掉那个补丁。
- route 的阶段和每个阶段的提供者只写在 `src/flow/skills/route/stages.md`，`locate.sh` 从那张表读提供者，不写死 skill 名。上游改了 skill 名，或要换掉某个阶段的提供者，只改表里那一格；只有安装目录布局变了才改 locate.sh。`./jstack check` 会在五种安装布局下核对表里每个提供者都找得到。
- 插件名必须保持 `pstack`、`spec`、`flow`：Claude Code 的 skill 以插件名为命令前缀（`/pstack:<name>`、`/spec:<name>`），adapter 还把 agent 映射成 `pstack:poteto-agent`；Pi/OMP 用 `/skill:<name>`，Cursor 用 `/<name>`。改名会让这些引用全部失效。`pstack-cursor` 只是构建目录 / 上游目录的 key，两个 pstack 产物的 manifest 名字都必须是 `pstack`。
