# JStack

> **让 AI 不止于写代码，而是把工程任务推进到有证据、可审查的交付状态。**

[![CI](https://github.com/jionpz/jstack/actions/workflows/check.yml/badge.svg)](https://github.com/jionpz/jstack/actions/workflows/check.yml)

JStack 是一套面向 AI 编程工具的软件工程工作流。你只需要说明要解决的问题，它就会根据任务规模和风险，组织必要的澄清、规划、实现、验证、审查与收尾步骤。

JStack 要减少的不只是重复操作，还有开发过程中反复确认「做完了吗？验证过了吗？」所消耗的注意力。**日常决定尽量由工作流处理，关键决定仍由你掌握；每项完成结论都应有可以检查的依据。**

JStack 支持 Claude Code、Pi、OMP、Cursor 和 Codex。不同运行环境的接入方式、门禁能力和信任机制有所区别，详见[兼容性说明](#支持的运行环境)。

## JStack 解决什么问题？

- **不知道该走哪套流程？** 用 `route` 作为统一入口。小修复直接进入执行与验证，复杂任务先澄清、拆解，再按依赖逐步推进。
- **AI 说完成了，却看不到验证依据？** 工作流要求记录真实的验证命令和结果；在门禁已正确加载并生效的环境中，还能阻止缺少验证证据的任务直接结束。
- **想减少打断，又不想失去控制？** 有证据支持、风险可控的决定优先采用合理默认值；涉及高风险、难以撤销或需要你授权的操作，仍交由你决定。

JStack 不把「自动合并所有代码」当作目标。对于有远程仓库的项目，它通常推进到 **PR-ready**：PR 已创建，相关验证与审查通过，且 CI 在经过验证的提交上通过。**是否合并，由你明确决定。**

## 快速开始

### 方式一：安装到 Claude Code

如果你已经安装 Claude Code，可以直接添加 JStack 的插件市场并安装三个插件：

```bash
claude plugin marketplace add jionpz/jstack
claude plugin install pstack@jstack
claude plugin install spec@jstack
claude plugin install flow@jstack
```

通过 Claude Code 插件市场安装的插件从本地缓存加载，桌面端也使用这份缓存。用以下命令刷新来自 GitHub 插件市场的副本。

```bash
claude plugin marketplace update jstack
claude plugin update pstack@jstack
claude plugin update spec@jstack
claude plugin update flow@jstack
```

如果市场指向本地 JStack checkout，修改构建输入后，运行 `./jstack build` 和 `./jstack install` 刷新缓存。

重新打开 Claude Code 会话，或执行 `/reload-plugins`。然后进入你想修改的代码仓库，试着提交一个任务：

```text
/flow:route 修复登录失败时提示信息不清晰的问题，并运行相关测试
```

也可以只要求调查，不修改任何代码：

```text
/flow:route 调查最近的 CI 为什么失败，给出证据和建议，不要修改代码
```

`route` 会先判断这是调查还是工程修改，再选择后续步骤。**第一次使用建议显式调用 `/flow:route`**，不必依赖模型自动选中对应的 skill。

如果需要用 `spec` 生成正式需求说明或任务单（ticket），请先在目标仓库运行一次 `/spec:setup-matt-pocock-skills`，配置任务跟踪方式和领域文档位置。

### 方式二：安装到项目（推荐团队使用）

项目级安装会把所需插件与入口文件放进目标仓库，便于团队共享和检查具体版本。先获取 JStack，再指定你的项目目录：

```bash
git clone https://github.com/jionpz/jstack.git
cd jstack
./jstack install --all --scope project --repo /absolute/path/to/your-project
./jstack doctor --repo /absolute/path/to/your-project
```

项目级 `--all` 会生成 Claude Code、Pi、OMP、Cursor 和 Codex 的原生入口，无需在维护者的机器上装齐五种工具。用 `--harnesses pi,cursor` 可只接入指定工具，也可在现有项目上追加接入。

把 `.jstack/vendor/`、`.jstack/lock.json` 和生成的项目入口一起提交。协作者 `git clone` 后，用已有的 AI 编程工具打开项目，按提示审查并信任项目入口即可。默认接线无需另外安装 JStack、npm 包或 JavaScript 运行时。各阶段所用的外部工具仍有各自的依赖。

在 Claude Code 的项目级安装中，可以从目标仓库使用 `/route` 入口。其他工具的调用方式见下方[兼容性说明](#支持的运行环境)。

安装前可加 `--dry-run` 查看计划。**同一种工具不要同时启用用户级和项目级的 JStack**，以免插件或门禁重复加载。安装后用 `doctor` 核对版本、入口归属及 Git 忽略规则。

Pi 的项目接线默认不声明子 agent 扩展包。需要该功能时，用 `--with-pi-recommended` 添加声明，Pi 按原生机制加载。用 `--no-pi-recommended` 可移除归属已记录在 lock 的声明。

清退项目接线前，先预览：

```bash
./jstack uninstall --scope project --repo /absolute/path/to/your-project --dry-run
```

核对预览后去掉 `--dry-run`。加 `--harnesses cursor,pi` 可只清退指定工具。卸载按 lock 移除已有归属证明的接线，并保留仍在使用的共享入口。第一版 lock 需要先重跑项目级安装。详见[项目级安装设计](docs/adr/0006-project-level-install.md)。

> 环境要求：Git、Bash，以及相应的 AI 编程工具。部分安装或运行功能还需要 `jq`、`rg`、`gh`、`bun` 等依赖。当前仓库的静态 CI 覆盖 macOS 和 Linux；其他平台应先自行验证。

## 一项任务如何推进？

JStack 把「应该做什么」和「由哪个 skill 完成」分开管理。`route` 先识别任务规模，再按照阶段定义安排执行者。

```text
                           ┌─ 调查类任务 ─→ 阅读证据 ─→ 给出回答（不改代码）
你的任务 ─→ route 选择路线 ┤
                           └─ 工程任务 ─→ [澄清 / 规划] ─→ 实现 ─→ 验证 ─→ [审查]
                                                                        │
                                                                        ▼
                                                           提交分支 / 准备 PR
                                                                        │
                                                                        ▼
                                                            合并前归档与交付报告
```

方括号里的步骤并非每次都需要；具体选择由任务复杂度、歧义和风险决定。对有远程仓库的项目，工作流在验证、审查及对应提交的 CI 都通过后报告 **PR-ready**，等待你决定是否合并；合并后的关票和 worktree 清理由后续归档完成。没有远程仓库时，则以分支提交及相应归档为目标。

| 任务类型 | 处理方式 |
|---|---|
| **调查与提问** | 阅读仓库和相关证据，给出有出处的结论；不进入修改流程 |
| **XS / S：小修复** | 直接执行、验证、落地与归档 |
| **M：单模块改动** | 执行、验证、审查；存在关键歧义时先澄清 |
| **L：跨模块任务** | 先澄清和拆分任务单，再按依赖推进每项工作 |
| **XL：跨会话工程** | 先规划工作范围与依赖，再分阶段执行，必要时交接会话 |

完整的阶段、产出要求和执行者定义，以 [`stages.md`](src/flow/skills/route/stages.md) 为准。

### 为什么分成三个插件？

JStack 的核心是 **flow**，不是把第三方 skills 简单放在一起。流程由 JStack 定义，各阶段再使用合适的执行者：

| 插件 | 承担的工作 |
|---|---|
| **flow** | JStack 自己维护的流程控制、任务分级、默认执行、默认审查与归档 |
| **spec** | 需求澄清、领域建模、需求说明、任务拆分和会话交接；来源于 [Matt Pocock 的 skills](https://github.com/mattpocock/skills) |
| **pstack** | 适合多个独立任务单或跨天工程的深度执行与编排；来源于 [Lauren Tan 的 pstack](https://github.com/cursor/plugins/tree/main/pstack) |

普通任务默认使用 `flow:execute`，较复杂的多任务工作可切换到 `pstack:poteto-mode`。同一任务只保留一个主要执行者，避免不同编排器重复安排实现、测试与审查。第三方实现被视为可维护、可替换的阶段提供者，而不是 JStack 的流程定义本身。[设计决策：ADR-0002](docs/adr/0002-flow-is-the-product.md)

## 人工决策与安全边界

**减少人工介入，不等于放弃人工控制。** JStack 按以下边界推进任务：

- **完成必须有证据。** 验证应记录真实命令及观察到的结果。检查未执行或未通过时，不能用「已验证」代替事实。
- **PR-ready 不等于已合并。** 有远程仓库时，CI 未完成或未通过的 PR 不能报告为 PR-ready。合并必须由用户明确指定；合并后的清理和关票另行完成。[ADR-0007](docs/adr/0007-flow-ends-at-pr-ready.md)
- **高风险操作需要授权。** 必须暂停的事项遵循项目的规则和可见操作的门禁；不同工具可能弹出确认、拒绝执行，或仅依靠工作流规则约束。
- **门禁不能靠安装文件来证明生效。** 只有在对应 hooks 或扩展已加载、受到信任且实际运行时，才能声称相关检查已被强制执行；无法确认时，应明确说明未验证的部分。[门禁能力与限制](docs/harness/gates.md)

## 支持的运行环境

| 工具 | 安装方式 | 任务入口 |
|---|---|---|
| **Claude Code** | 插件市场或项目级安装 | 插件：`/flow:route`；项目级：`/route` |
| **Pi** | `./jstack install-pi` 或项目级安装 | `/skill:route` |
| **OMP** | OMP 插件市场或项目级安装 | `/skill:route` |
| **Cursor** | `./jstack build` 后执行 `./jstack install-cursor`，或项目级安装 | `/route` |
| **Codex** | 项目级安装 | 在 `/skills` 中选择 `route`，或使用对应 skill 调用方式 |

这些工具可以共享 JStack 的阶段定义，但并非拥有完全相同的工具权限、事件回调和阻断能力。使用前请查看[门禁能力矩阵](docs/harness/gates.md)，并在实际环境中核对安装与信任状态。

## 可选：按角色分配模型

JStack 支持把模型按职责分成两层：`premium` 负责架构判断、关键决策等高杠杆任务，`bulk` 负责执行、探索和验证。两层对应的实际模型由用户配置，不预设任何提供商一定拥有无限额度，也不保证配置后必然更省钱。

```bash
./jstack models init             # 配置模型
./jstack models apply --dry-run  # 先检查将要修改的文件
./jstack models apply            # 确认后应用
./jstack models status           # 查看当前预算状态
```

模型配置写在 `~/.jstack/config.json`。**更换模型提供商可能改变代码和上下文的数据流向**，运行 `apply` 前应检查配置。项目自身的任务跟踪、验证命令和必须暂停事项则放在 `<repo>/.jstack/config.json`；不要在项目配置里存放模型凭据。具体规则见[配置字段](docs/agents/jstack-config.md)及 [ADR-0003](docs/adr/0003-two-tier-models.md)。

## 开发、检查与文档

```bash
./jstack check                 # 静态检查与不依赖模型的测试
./jstack doctor --repo <dir>  # 检查项目安装、版本和锁文件
./jstack check --smoke         # 发布检查，要求 Claude Code 和 Pi 的真实 smoke 通过
./jstack smoke claude-code      # 单独验收项目安装后的 Claude Code 门禁
./jstack eval list             # 列出固定评测任务
```

真实 smoke 需要模型和网络。全量 smoke 会报告 OMP、Cursor 和 Codex 的结果，这三者缺失或未通过时仍可通过发布检查。发布前还需通过 Claude Code 和 Pi 的评测。

Claude Code 的注意力题（`*-attention-*`）分别记录打断、漏停、误停和被推翻的默认决定。每次答复只算一次打断，漏停按待决事项计数。有需要时，runner 用同一会话发送一次预置的用户答复，`nudges` 仍只记录催促。计分按题目约定识别答复里的问题和默认决定，并检查回复前的仓库状态。只有完成首轮并拿到答复的样本才进入注意力统计。Pi 运行整套评测时跳过这些题。

项目源码与构建产物分开管理：`src/flow/` 是 JStack 自有工作流的源码；`upstream/` 保留第三方上游副本，`patches/` 保存本地补丁，`plugins/` 是生成后的插件目录。修改功能时请改源码或补丁，不要直接编辑构建产物。

- **架构与配置**：[阶段定义](src/flow/skills/route/stages.md) · [工具能力映射](docs/harness/tools.md) · [配置字段](docs/agents/jstack-config.md) · [设计决策](docs/adr/)
- **运行与集成**：[门禁能力](docs/harness/gates.md) · [Keel 托管工作流接口](docs/managed.md)
- **维护与评测**：[CI](.github/workflows/check.yml) · [测试](tests/) · [评测](evals/) · [上游同步记录](SYNC-LOG.md) · [旧版详细维护说明（存档）](docs/archive/README-2026-11-18.md)

## 从 Trellis 迁移

运行 `./jstack retire trellis --repo <项目>` 预览旧入口和待迁任务。按 [Trellis 项目清退指南](docs/trellis-retirement.md) 迁移在途任务与项目约定，再应用清退。原资料和共享配置原件会保存到项目归档目录。

## 来源与致谢

JStack 自有工作流位于 [`src/flow/`](src/flow/)。`pstack` 由 Lauren Tan 创建，`spec` 采用 Matt Pocock skills 的选定子集；两个上游均以固定提交及本地补丁维护，相关版权与许可证保留在 [`plugins/pstack/LICENSE`](plugins/pstack/LICENSE) 和 [`plugins/spec/LICENSE`](plugins/spec/LICENSE) 中。部分 pstack 补丁还借鉴了 [backnotprop/pstack](https://github.com/backnotprop/pstack) 的实现。
