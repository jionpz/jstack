# jstack

jionpz 长期维护的 AI 开发工作流。目标是少占用人的注意力：工作流自己判断什么时候需要人介入，自动走完开发、测试、验证、归档；token 有限的高级模型只做关键判断，token 几乎无限的 DeepSeek / GLM 类模型负责执行和验证。设计决策见 `docs/adr/`，其中 0002 到 0005 定义了方向。

工作流由 jstack 自己定义的阶段组成，每个阶段绑定一个当前的提供者；上游 skill 只是提供者，可以被改写或替换。目前以三个插件的形式发布：

- **pstack**：原版 [pstack](https://github.com/cursor/plugins/tree/main/pstack)（Lauren Tan，MIT），负责执行。只维护上游的 Claude Code 树；Cursor 版由 `./jstack build` 按 `patches/pstack-cursor/rules.tsv` 转换生成，Pi/OMP/Codex/Workloop 通过 `docs/harness/agents.md` 在运行时映射工具名和模型。
- **spec**：[Matt Pocock 的 skills](https://github.com/mattpocock/skills)（MIT）里负责需求澄清和任务拆解的几个，产出的 spec 和 tickets 交给 pstack 执行。
- **flow**：jstack 自己写的衔接层，有 `route` 和 `archive` 两个 skill。`route` 给工程任务分级并驱动全部阶段；`archive` 负责收尾：关票、更新领域文档、写回 gbrain、清理 worktree、分流教训。见下面"分工"一节。

pstack 和 spec 都锁定在上游某个提交，另外叠加了 jstack 自己的少量补丁。flow 没有上游，源码在 `src/flow/`。

## 为什么 pstack 和 spec 是两个插件

这两个插件的上游、许可证、维护节奏都不同，各自锁定自己的提交，互不牵连。命令前缀也分开（`/pstack:*`、`/spec:*`），可以单独装、单独升级。

名字按职责取：`spec` 只做 spec 之前的事。这是范围护栏，不是装饰——实现类 skill 一个都不收。Matt 的 `implement`、`implement-spec`、`ask-matt` 能自己编排实现，进来就会和 `/pstack:poteto-mode` 抢主编排，同一个任务两个编排器，测试、审查、返工都会被跑两遍。所以收的是 `grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`，加上它们运行时真正要调用的 skill：

| skill | 为什么收 |
|---|---|
| `grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff` | 要用的 5 个入口 |
| `grilling`、`domain-modeling` | `grill-with-docs` 和 `wayfinder` 用 Skill 工具调用它们（`grill-with-docs` 的全部内容就是"调用这两个"） |
| `research`、`prototype` | `wayfinder` 把工单分成 research / prototype / grilling / task，前两类要调用它们 |
| `setup-matt-pocock-skills` | `to-spec`、`to-tickets`、`wayfinder` 都要求先运行它，写下这个仓库的 issue tracker 和领域文档配置 |

`check` 会核对这层依赖：skill 里写着 `Call the Skill tool ... "<名字>"` 时，被调用的 skill 必须在插件里，漏了就报错。增删 skill 要同时改 `jstack` 里的 `PICK` 和 `patches/spec/0001` 的 `skills` 清单。

## 安装

### 项目级接入（推荐）

一台新机器、一个新仓库，一条命令完成接入：

```bash
./jstack install --all --scope project --repo /path/to/repo
```

`--all` 探测本机已装的 harness（Claude Code、Pi、OMP、Cursor、Codex），没装的跳过并提示。产物全部落在仓库里：

```
<repo>/.jstack/
├── config.json          # 仓库级配置（可选，ADR-0006）
├── lock.json            # 安装锁：jstack 版本与 commit、vendor 树哈希、上游 commit、插件版本、各 harness 的入口记录
└── vendor/
    ├── .claude-plugin/marketplace.json
    └── plugins/{pstack,spec,flow}/
```

- vendor 保留完整插件树，不摊平 skill。
- 只把 9 个入口 skill 链进发现目录：`route`、`archive`、`poteto-mode`、spec 的 `grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`、`setup-matt-pocock-skills`。其余 skill 留在 vendor，由 `locate.sh` 按物理路径定位。
- 发现目录：Claude Code 用 `.claude/skills`，Pi、OMP、Codex 和 Cursor 共用 `.agents/skills`。Cursor 也读 `.agents/skills`，不再单独写 `.cursor/skills`；旧安装留在 `.cursor/skills` 的 jstack 软链会在下次 install 时移除。`.agents/skills` 里已有的同名入口视为用户配置，install 保留并跳过，不覆盖。链接是相对路径，仓库搬走也有效。
- Pi / OMP 的项目级门禁扩展分别写到 `.pi/extensions/jstack-flow-gates.ts` 和 `.omp/extensions/jstack-flow-gates.ts`；各入口用相对路径转出 `.jstack/vendor/plugins/flow/extensions/` 中对应的扩展。
- Claude Code 另外复制 `poteto-agent`、`comment-sicko` 到 `.claude/agents`，并把 flow 的三个 hook 写进 `.claude/settings.json`，命令用 `${CLAUDE_PROJECT_DIR}` 指向 vendor；不注册 marketplace。
- Pi 的 `poteto-agent`、`comment-sicko` 写到 `.agents/agents/`，已有同名文件时保留用户版本并跳过；OMP 写到 `.omp/agents/`；Cursor 从转换产物 `plugins/pstack-cursor/agents/` 复制两个 agent 到 `.cursor/agents/`。
- Codex 另外把两个 agent 的 Markdown 正文转成 TOML，写到 `.codex/agents/{poteto-agent,comment-sicko}.toml`（`name`、`description`、`developer_instructions`），`spawn_agent` 按名字派出去。
- Codex 的门禁写进 `.codex/hooks.json`，三个事件和 Claude Code 同形，命令用安装时 checkout 的绝对路径（Codex 不给项目 hooks 暴露 PROJECT_DIR 一类的变量）；它只对当前 clone 有效，移动仓库或重新 clone 后必须重跑 install。hooks 默认要落过信任才执行：交互式会话里同意一次，headless（`codex exec`）加 `--dangerously-bypass-hook-trust`。
- 重复运行幂等；`--dry-run` 只打印；不写任何用户级文件。锁与 `doctor --repo` 覆盖项目扩展和 agent 文件。安装完成后提交 `.jstack/`、三个入口目录及各 harness 项目产物；若 ignore 规则屏蔽了产物，安装和 doctor 会通过 `git check-ignore` 检测并给出 白名单建议。

同一个 harness 不要同时做用户级和项目级安装：插件或入口会加载两次，flow 的 hooks 也会跑两遍。换仓库时用项目级；只想全局装一次时用用户级。

`./jstack doctor --repo <repo>` 会核对 vendor 版本、树哈希、lock 记录、入口链接、Pi / OMP 扩展和 agent 文件；也会用 `git check-ignore` 检测被忽略的项目级产物并给出 白名单建议。任何一处对不上都返回非 0。

### Claude Code

本机已经有这个目录时，一条命令即可：

```bash
~/mycode/jstack/jstack install
```

它装 `pstack@jstack`、`spec@jstack`、`flow@jstack` 三个。

在别的机器上不需要 clone，仓库是 public 的 `jionpz/jstack`，直接安装即可。如果要在这个仓库里推送改动，先运行 `gh auth login` 和 `gh auth setup-git`（走 HTTPS 和本机 git 凭据），或者配好 SSH key。然后：

```bash
claude plugin marketplace add jionpz/jstack && claude plugin install pstack@jstack && claude plugin install spec@jstack && claude plugin install flow@jstack
```

装好之后在 Claude Code 里：

1. `/reload-plugins`，或者新开一个会话。
2. `./jstack models init` 按提示配置 `~/.jstack/config.json`，再 `./jstack models apply`：写入模型角色表 `~/.claude/rules/pstack-models.md` 和 `~/.claude/settings.json` 里的模型 env。见下面“模型分层”一节。
3. 在要用 spec 的仓库里运行一次 `/spec:setup-matt-pocock-skills`：选定 issue tracker 和领域文档的位置，写 `docs/agents/*.md` 和 `CLAUDE.md` 里的 `## Agent skills` 段。
4. 直接描述任务即可。`flow:route` 会自动分级并选择流程；也可以显式运行 `/flow:route <任务描述>`。想跳过路由时，直接用 `/pstack:*` 或 `/spec:*` 命令，route 不会介入。

### Pi

仓库根目录本身是 Pi package：`package.json` 的 `pi.skills` 指向 `plugins/pstack/skills`、`plugins/spec/skills` 和 `plugins/flow/skills`。在仓库里运行：

```bash
./jstack install-pi
```

它会执行 `pi install <仓库> --approve`，并把 `plugins/pstack/agents/` 里的 `poteto-agent`、`comment-sicko` 转换后写到 `~/.pi/agent/agents/`（`background: true` 改成 Pi 的 `run_in_background: true`）。重复运行是幂等的；同名的非 jstack agent 文件不会被覆盖。

在 Pi 里用 `/skill:poteto-mode`、`/skill:route` 这类命令调用入口。pstack 的入口 skill 都是 `disable-model-invocation: true`，不会出现在模型自动选择的 skill 列表里，这是正常的，`/skill:<名字>` 仍然能加载。子 agent 由固定的 `@tintinweb/pi-subagents@0.23.2` 提供；`install-pi` 和 `install --all` 检测到目标作用域没有它时，会用原生 `pi install` 安装（项目级加 `-l`，并设置 `npm_config_ignore_scripts=true`），已有包则按作用域跳过并报告版本，`--dry-run` 不联网也不写文件。安装只动包资源，不改 provider、models、auth 或权限设置，也不会另外装一个 hooks 包。Pi 的项目级扩展首次加载可能要求信任项目扩展；核对 `.pi/extensions/jstack-flow-gates.ts` 指向本仓库 vendor 后，在 Pi 中信任它，门禁才会运行。

### OMP

OMP 读 Claude Code 的 `.claude-plugin/marketplace.json`，所以可以直接添加 jstack marketplace 并安装三个插件：

```bash
omp plugin marketplace add jionpz/jstack        # 本机仓库用绝对路径也可以
omp plugin install pstack@jstack spec@jstack flow@jstack
```

在 OMP 里用 `/skill:poteto-mode`、`/skill:route` 调用入口；pstack 的 `poteto-agent`、`comment-sicko` 会作为 `task` 工具的 agent 被发现。OMP 会丢弃 Claude 方言的 `model` frontmatter，模型角色用 `@slow` / `@plan` / `@smol` / `@task`，或在 OMP 配置里调整。更新插件用 `omp plugin upgrade pstack@jstack spec@jstack flow@jstack`。

### Cursor

pstack 只有一棵 skill 树（上游的 Claude Code 树）。`build` 从 `plugins/pstack` 转换出 Cursor 版 `plugins/pstack-cursor`，规则表在 `patches/pstack-cursor/rules.tsv`：

| 规则 | 改什么 | 覆盖的差异 |
|---|---|---|
| `adapter-paragraph` | 删掉「If you are not in Cursor, read the harness adapter…」和后面的空行 | 22 个 SKILL.md 只差这一行；`poteto-help` 也命中这条 |
| `poteto-help-adapter` | 把 `[harness adapter](…/agents.md)` 换回 `[Claude Code adapter](…/claude-code.md)` | `poteto-help` 的第 2 行差异 |
| `agent-background` | `background: true` 换成 `is_background: true` | `poteto-agent` 的 frontmatter |
| `worktree-audit` | 用 `patches/pstack-cursor/worktree-audit.sh` 覆盖 | 会话记录路径换回 `~/.cursor/projects` |
| `cursor-manifest` | 合并 `patches/pstack-cursor/manifest.json` 生成 `.cursor-plugin/plugin.json` | Cursor manifest |
| `cursor-logo` | 复制 `assets/logo.png` | manifest 的 `logo` |

24 个 skill 树差异 = 22 个只差 adapter 提示的 SKILL.md + `poteto-help` + `worktree-audit.sh`；agent frontmatter 不在 skills/ 里，由第 3 条规则覆盖。spec 和 flow 与 Claude Code 共用同一份产物，只是额外带 `.cursor-plugin/plugin.json`：

```bash
./jstack build
./jstack install-cursor        # 复制到 ~/.cursor/plugins/local/{pstack,spec,flow}
```

Cursor 的本地插件加载器只接受 `~/.cursor/plugins/local` 内的符号链接，指向仓库的链接会被拒绝，所以 `install-cursor` 默认复制。改了构建产物后重新运行一次即可。

重开 Cursor 窗口。用 `/poteto-mode`、`/route`、`/grill-with-docs` 调用，不带插件前缀。`check` 会核对每条转换规则都命中差异，并核对生成的 `skills/` 正好有 24 个文件与 `plugins/pstack` 不同；spec/flow 的 Cursor manifest 和 Claude manifest 版本同步。完整检查清单见 `docs/testing/cursor.md`。

不要同时装 `pstack@cursor-plugins` 以及其他 pstack 移植版：它们的命令都以 `/pstack:` 开头，会互相冲突。也不要装 `mattpocock-skills`（Matt 的完整版）：skill 和 `spec` 重复，还带 `implement` 编排。`./jstack install` 检测到这些会拒绝安装并给出卸载命令。

运行时依赖：`bun`（poteto-mode 的 watch-pr 和 statechart 脚本）、`gh`（PR 和 CI 流程）、`rg`、`jq`。缺哪个，`install` 会提示。

## 模型分层

两层模型（ADR-0003）：premium 做判断，通常是能力最强的高级模型；bulk 是 token 几乎不限的模型家族，负责执行和验证。每个角色属于哪一层写在 `jstack` 里，绑定哪个模型只由 `~/.jstack/config.json` 的 `models` 段决定（`JSTACK_USER_CONFIG` 可覆盖路径，测试用）。旧 `~/.config/jstack/models.json` 在第一次运行 `models` 时自动迁移并备份。文件按 harness 分开：

```json
{
  "models": {
    "claude-code": { "premium": "opencode-go/...", "bulk": ["...", "..."] },
    "cursor": { "premium": "...", "bulk": ["...", "..."] },
    "omp": { "premium": "magpie/...", "bulk": ["magpie/...", "magpie/..."] },
    "pi": { "premium": "provider/model", "bulk": ["provider/model", "provider/model"] }
  },
  "budget": { "premium_daily_tokens": null, "premium_concurrency": null }
}
```

每个 harness 还可以选写 `roles`，只覆盖要改的角色，值为 `premium`、`bulk`（等于 `bulk0`）、`bulk0`、`bulk1`，多个用逗号或数组：

```json
"claude-code": {
  "premium": "opencode-go/...",
  "bulk": ["...", "..."],
  "roles": { "hardest tasks": "premium", "arena runners": "bulk0,bulk1" }
}
```

模型 id 只校验形状（`^[A-Za-z0-9][A-Za-z0-9._/-]*(\[[A-Za-z0-9]+\])?(:[a-z]+)?$`），不联网、不调用 magpie；可以带上下文标记和推理深度后缀，如 `deepseek-v4.1-flash[1m]`、`deepseek-v4.1-flash:max`。各家对深度后缀的支持不同：magpie 实测 DeepSeek 只认 `low` / `high` / `max`，`xhigh` 会落到 `max`，所以想用两个不同的 bulk 档位要先验证该模型支持的档位。某个 harness 没配置时，`apply` 跳过它。

| 命令 | 作用 |
|---|---|
| `./jstack models` / `show` | 显示配置路径、各 harness 的 premium/bulk、预算和 `apply` 会写的文件 |
| `./jstack models init` | 逐 harness 引导配置。默认值来自当前安装（Claude Code 的 settings.json、Pi 的 defaultModel、OMP 的 modelRoles）；已有配置作为默认值，`--force` 重新问；输入 `q` 跳过该 harness。非交互写法：`--harness claude-code --premium <id> --bulk <a,b>`。写完不自动 apply |
| `./jstack models set premium <id>` | 改一个值，原子写配置，然后自动 apply。`--harness` 默认 `claude-code` |
| `./jstack models set bulk <a,b>` | 同上；两个 bulk 必须不同 |
| `./jstack models apply [--dry-run] [--yes]` | 按配置写四个 harness 的规则文件；`--dry-run` 只打印路径和内容；首次写 Pi/OMP 的共享文件要确认，`--yes` 跳过确认 |
| `./jstack models status` | 统计 magpie 日志里 premium 今日的 `in + out`，和日预算比较 |

`apply` 写到哪里：

| harness | 文件 | 模型写法 |
|---|---|---|
| Claude Code | `~/.claude/rules/pstack-models.md`（无 frontmatter）和 `~/.claude/settings.json` 的 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`、`ANTHROPIC_SMALL_FAST_MODEL` | 规则里写 `opus` / `sonnet` / `haiku` 别名；settings 的三个 env 指向 premium、bulk[0]、bulk[1]，`SMALL_FAST` 跟 bulk[1]。改 settings 前备份成 `settings.json.bak-models-<时间>`，值没变就不备份 |
| Cursor | `~/.cursor/rules/pstack-models.mdc`（`alwaysApply: true`） | 真实 slug |
| OMP | `~/.omp/agent/rules/pstack-models.md`（`alwaysApply: true`）和 `~/.omp/agent/config.yml` 里的 `modelRoles` 标记块 | 配置里的 magpie slug；`slow` 走 premium，`plan` / `task` / `default` 走 bulk[0]，`smol` 走 bulk[1]；块外内容不碰，首次写入前确认并备份 |
| Pi | `~/.pi/agent/AGENTS.md` 的角色表标记块 | 真实 `provider/model`；AGENTS.md 是符号链接时不跟随写入，只打印角色表（本机就把它交给 harness-config 维护） |

17 个角色行由 `jstack` 生成，四个 harness 共用同一份角色到层级映射：执行、探索、审查工具走 bulk，判断、综合、最终结论走 premium，审查面板同时用两个 bulk 家族。重复运行 `apply` 是幂等的，内容没变就不重写；Pi/OMP 的共享文件只改 `jstack:models` 标记块，块外不碰，写入前备份。

预算：`premium_daily_tokens` 为 null 表示不限。设置上限后，`apply` 先统计今天 premium 的 token；达到或超过上限时把所有 premium 角色降级到对应 harness 的 bulk[0]，在规则文件头写明降级原因，并在 stdout 打出警告。`premium_concurrency` 只记录、打印，不强制，因为 Claude Code 没有按层并发控制。

`/pstack:setup-pstack` 仍然可用，但它直接写规则文件、不读用户级配置。配置模型统一用 `./jstack models`，避免两套来源互相覆盖。

## 安装矩阵（doctor）

`./jstack doctor` 只读地回答"每个 harness 装的是哪个版本、在哪个作用域、来源是什么、是否与 lock 一致"：

```bash
./jstack doctor                  # 表格
./jstack doctor --json           # 机器可读
./jstack doctor --no-fail        # 有漂移也只警告，不返回失败
./jstack doctor --repo <dir>     # 指定仓库，核对它的 .jstack/vendor 与 lock
```

探测来源：Claude Code 的 `claude plugin list --json`（user / project / local 全部保留）、Pi package（`settings.json` 里的本地路径包和 `npm/node_modules/jstack`）、OMP 的 marketplace 缓存、Cursor 的本地插件目录、Codex 的 marketplace 缓存（`$CODEX_HOME/plugins/cache`）、`<repo>/.jstack/vendor/plugins`。每行有 harness、scope、plugin、version、path、source、lock 七列。

`lock` 列的取值：`ok`（与 `<repo>/.jstack/lock.json` 一致）、`drift`（版本不同）、`missing`（lock 里没有这个插件）、`no-lock`（仓库还没有 lock）、`stale`（本地 marketplace 的记录版本落后于源目录）、`-`（用户级安装，不归仓库 lock 管）。`stale`、`drift`、`missing` 会让命令返回非 0；`--no-fail` 降级为警告。

## 分工

Keel 可通过 `./jstack managed-export` 导出 Question 只读调查、XS/S 单 ticket 或
XS/S/M/L/XL route 图。route 包提供规划约束、依赖图说明和固定工作流定义，真实多
ticket 执行仍由 Keel 验收；接口与限制见 [managed 工作流包](docs/managed.md)。

工作流由 [`src/flow/skills/route/stages.md`](src/flow/skills/route/stages.md) 定义成固定阶段：size、clarify、plan、execute、verify、review、land、archive。每个阶段写明产出、门禁和当前提供者（ADR-0002）。`flow:route` 先分级，再按大小选出要走的阶段，逐个交给提供者，不需要你选命令：

| 任务大小 | 阶段路线 |
|---|---|
| XS / S（改文案、修一个 bug、单文件小改） | execute → verify → land → archive |
| M，边界清楚 | execute → verify → review → land → archive |
| M，需求有多种合理解释 | clarify → execute → verify → review → land → archive |
| L（新模块、跨模块改造） | clarify → plan（spec + tickets）→ 每张 ticket 走 execute → land → archive |
| XL（跨会话、跨阶段） | 先用 wayfinder 规划，再对每块按 L 走；需要换会话时 handoff |
| 提问、调查 | 只走 execute，产出就是带出处的回答 |

execute 默认交给 `flow:execute`：jstack 自己的精简执行入口，在主会话里直接改、验证、自审 diff、提交，不派子代理。多张独立 ticket 或多天工程交给 `pstack:poteto-mode`（Orchestrate / Multi-phase playbook），它的 playbook 同时包含验证、审查和开 PR。review 默认交给 `flow:review`：主会话里重读 diff、对照任务、修掉或驳回每个发现；只有设计有争议、改动碰必须停清单、或你要求对抗审查时才跑 `pstack:interrogate`。route 只补执行提供者之后仍未满足的门禁。仓库没有 remote 时，分支上的提交就满足 land。archive 交给 `flow:archive`：关票并附证据、补 GLOSSARY/ADR、写回 gbrain、按 pstack 的 worktree-cleanup 清理已合并的 worktree，并把教训分流到项目约定库或 jionpz/jstack 的 issue。

仓库可以用 `<repo>/.jstack/config.json` 调整这套流程：`stages_file` 整表替换阶段表，`must_stop` 追加必须停项（`guard.sh` 会拦），`tracker` / `domain_docs` / `verify` 声明任务账本、文档位置和验证命令。字段表和读取规则见 [`docs/agents/jstack-config.md`](docs/agents/jstack-config.md)（ADR-0006）；没有这个文件时行为与以前完全一致。

route 只在证据定不了、而且做错代价高的决策上停下来问你（ADR-0004），其余全部自动推进：

1. **必须停清单**：所有大小、任何自主授权下都适用，就是 `src/flow/skills/route/must-stop.md`（全局红线、poteto-mode 的 Always-pause、route 原有的业务/API/数据/架构/合规条目三者的并集，只维护这一份）。能识别的 shell 命令由 guard hook 拦，其余靠 agent 自己识别；这一轮里问完。
2. **证据定不了的决策**：能跑一下观察出结果的，就做实验或原型、记下结果，不问人。只有证据确实定不了、且（不可逆代价高 / 有两种改变做法的读法 / 影响到用户、生产或其他系统）时才问；否则采用推荐的默认值，用 `stage.sh default "<决定> -> <理由>"` 记下来，收尾摘要里逐条列出，你直接说改哪条即可。
3. **拆解**（L、XL）：拆解本身没有高风险分歧时不再要签字，直接发布；只有顺序或范围以后难改、测试接缝证据定不了、或命中必须停清单时，才把测试接缝和 ticket 拆分放在同一条消息里请你确认。
4. **一轮问完**：等待回答的 ticket 在 tracker 上打 `needs-human` 标签后挂起，不依赖它的 ticket 继续推进；攒着的问题合并成一轮，逐个编号、带推荐答案。答完去掉标签。通知渠道是可替换的提供者：在 Paseo 里就推给手机，否则靠标签，下次会话看得到。

收尾摘要固定五段：目标、改了什么、验证证据、采用的默认决定、需要你处理的事（外加门禁未生效时的说明），控制在一手机屏内。业务仓库的 `CLAUDE.md` 或 `.claude/rules/` 里定义了不同的分级、spec 位置或门禁时，以仓库为准。

`disable-model-invocation: true` 的 skill（pstack 57 个、spec 6 个：5 个入口加 setup）不能被模型用 Skill 工具调用，Claude Code 会直接拒绝，提示 "reserved for explicit user invocation"。route 用随附的 `locate.sh` 找到这些提供者文件的路径，然后直接读取并照着做，这也是 pstack 内部 skill 之间互相路由的方式。`locate.sh` 不写死 skill 名，而是读同目录 `stages.md` 的 Providers 列：换掉某个阶段的提供者只改表里那一格。它支持本地 marketplace、Claude Code 的 GitHub 缓存、OMP 缓存、Cursor 本地插件、Pi package、Codex marketplace 缓存和入口软链七种安装布局，入口 skill 以软链暴露时按物理路径解析；任一提供者找不到就点名并以非 0 退出。

### 工具配置

[`src/flow/skills/route/stages.md`](src/flow/skills/route/stages.md) 的末列给每个阶段指定一个 Tool profile；[`tool-policy.json`](src/flow/skills/route/tool-policy.json) 只定义 profile（role、必需能力和可选能力）和 Pi / Claude Code 的原生映射，不复制阶段表。辅助角色 investigator、tianwen 也有 profile，但它们不是阶段。

```bash
./jstack tools export --pretty
./jstack tools resolve --stage execute --harness pi --inventory inventory.json
./jstack tools resolve --role verifier --harness claude-code --inventory inventory.json --allow-shell-fallback
```

`export` 输出 `protocol_version=1.0`、`source_commit`、阶段到 profile 的映射、profiles、harness 映射和 `content_digest`。digest 是对去掉 `content_digest` 的对象按键递归排序后的紧凑 JSON 取 UTF-8 SHA256，Keel 可以独立复算。`resolve` 只读取 inventory 里真实存在的工具：缺必需工具时拒绝，缺可选工具时列在 `missing_optional`，只有显式传 `--allow-shell-fallback` 才会给只读角色加 shell 并输出 `degradations`。它只打印结果，不执行命令，也不在交互式会话里切换工具。原生 `--tools` / `--allowedTools` 的用法、Pi 推荐包和托管委派的边界见 [`docs/harness/tools.md`](docs/harness/tools.md)。

几条硬规则：

- **主编排只有一个**：执行、分配 agent、测试、审查、返工都归 pstack。spec 的产出是输入材料。
- **spec 是"当前任务"的临时 spec**，不等于长期需求。已批准的需求留在项目自己的需求文档里；ADR 和术语表由 `domain-modeling` 写（`GLOSSARY.md`、`docs/adr/`）。
- **setup 是前置**：`to-spec`、`to-tickets`、`wayfinder` 找不到 `docs/agents/` 下的配置时会让你先跑 `/spec:setup-matt-pocock-skills`。
- **tracker 决定文件落在哪**：选 local markdown 时，spec 写到 `.scratch/<feature>/spec.md`，tickets 写到 `.scratch/<feature>/issues/NN-*.md`（`Status:` 行记状态，`Blocked by:` 行记依赖）；wayfinder 的地图在 `.scratch/<effort>/map.md`。这些是任务级材料，一般不提交。
- **用 GitHub tracker 时先建好 `ready-for-agent` 标签**：`to-spec` 会给 issue 打这个标签，仓库里没有标签时 `gh` 会报错。建一次即可：

  ```bash
  gh label create ready-for-agent
  gh label create needs-human --description "Waiting on a human decision; other tickets continue"
  ```

  `needs-human` 是等待人回答的 ticket 的队列标记（ADR-0004）；没收录 `triage` skill，所以不会自动写 `docs/agents/triage-labels.md`。
- **handoff 写到 `$TMPDIR`**，不是仓库。它本来就是为了把当前会话交接给下一个 agent，不是长期文档。

### 结构门禁（hooks）

flow 插件自带三个门禁（Claude Code 的 `src/flow/hooks/hooks.json`，Cursor 的 `hooks/hooks.cursor.json`，Pi / OMP 的 `src/flow/extensions/*.ts`），把阶段门禁从提示词变成结构。Pi / OMP 的扩展只是协议翻译，判定仍由同一组 hook 脚本做。hook 只读状态文件，不调模型；任何内部错误都无输出地放行，不会卡住会话。各 harness 的能力、接入方式和降级见 [`docs/harness/gates.md`](docs/harness/gates.md)。

- **阶段提示（UserPromptSubmit，`prompt.sh`）**：你每发一条消息，就把当前阶段、阶段路径、这一阶段在 `stages.md` 里的产出和门禁、下一阶段以及 `stage.sh` 的用法注入上下文，并清掉"等待用户回答"标记。没有阶段记录时什么也不做。
- **验证门禁（Stop，`stop.sh`）**：路径含 verify、已经进入 execute 或之后的阶段、却一条验证证据都没记录时，拦下这次结束，让 agent 先验证并用 `stage.sh evidence` 记录。agent 运行过 `stage.sh ask` 且这一轮的回复里确实向你提了问题、或者这一轮本身就是被 Stop hook 拦回来的，都放行。每次进入 execute 会清掉之前的证据，L 路径的下一张 ticket 要重新验证。
- **红线守卫（Claude Code 的 PreToolUse / Cursor 的 beforeShellExecution / Pi、OMP 的 bash `tool_call`，只看 shell 命令，`guard.sh`）**：命令在 `;`、`&&`、`||`、`|`、换行处切段，任一段命中 `must-stop.md` 的 patterns 就让 harness 先问你，原因写明命中的是哪条必须停事项。它不看阶段状态，对所有会话生效，包括没走 route 的会话。

route 用同目录的 `stage.sh` 记录阶段（`start`、`enter`、`evidence`、`default`、`ask`、`end`、`show`）。状态按会话存成纯文本 `${JSTACK_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/jstack/sessions}/<会话 id>`，`start` 时顺带删掉 7 天没动过的旧记录。会话 id 依次取 `JSTACK_SESSION_ID`（OMP 扩展写入）、`PI_SESSION_ID`（Pi）、`CLAUDE_CODE_SESSION_ID`、`CURSOR_CONVERSATION_ID`、`CODEX_SESSION_ID`；都没有的 harness 里 `stage.sh` 只打印一行说明，不做任何事。

Cursor 的 hook 是它自己的事件和协议，不复用 Claude 的 `hooks.json`：`beforeShellExecution` 对应 guard（`permission: ask` 会弹出确认），`beforeSubmitPrompt` 对应阶段提示（输出 `additional_context`），`stop` 对应验证门禁（输出 `followup_message`）。Cursor 的 `stop` 输入没有最后一条回复，所以标了 `ask` 时只能直接放行，无法像 Claude 那样核对回复里是否真的提了问题；`stop` 的 `loop_limit` 设为 3，避免反复拦住同一轮。`./jstack install-cursor` 现在会复制完整插件树，Cursor 加载器按 `.cursor-plugin/plugin.json` 的 `hooks` 字段只加载 `hooks.cursor.json`。项目级安装同样会写 `.cursor/hooks.json`，命令指向 `.jstack/vendor`。

Pi 和 OMP 用扩展承载同一套门禁，不复制判定逻辑：根 `package.json` 的 `pi.extensions` 指向 `plugins/flow/extensions/pi.ts`（`./jstack install-pi` 装好即生效）；OMP 的插件清单不收 Claude 格式 hooks，`./jstack install` 在 `~/.omp/agent/extensions/jstack-flow-gates.ts` 写一个入口文件，转出 `plugins/flow/extensions/omp.ts`。扩展把 `before_agent_start` 对应到阶段提示、`agent_before_settle` / `session_stop` 对应到验证门禁、`tool_call` 只对 bash 对应到红线守卫。Pi 没有 harness 维护的 `stop_hook_active`，扩展自己限制每条用户消息最多拦 3 次；OMP 在 `session_start` 把会话 id 写进 `JSTACK_SESSION_ID`，子 shell 继承，`stage.sh` 才能和 Claude / Cursor 用同一套状态文件。非交互运行时没有人能回答确认框，must-stop 命中会直接拒绝执行。

Codex 用自带的 hooks 承载同一套门禁：项目级安装把三个事件写进仓库的 `.codex/hooks.json`，输入是 Claude Code 的形状（shell 工具在 hook 里也叫 `Bash`），`lib.sh` 靠输入里的 `turn_id` 认出 Codex。它的 `PreToolUse` 只认 deny，返回 ask 会被忽略、命令照跑（0.166.0 实测），所以红线守卫在 Codex 里直接拒绝；`Stop` 的 `stop_hook_active` 由 Codex 维护，验证门禁和 Claude Code 走同一条分支。hooks 默认要信任后才执行：交互式会话里同意一次；headless 运行要加 `--dangerously-bypass-hook-trust`，只对已审查的 hooks 来源用。另外 Codex 的 shell 只继承核心环境变量（`shell_environment_policy inherit="core"`），`JSTACK_STATE_DIR` 这类变量要显式写进配置才能传给 shell 工具。接入细节见 [`docs/harness/gates.md`](docs/harness/gates.md)。

实测过两种模式：交互式会话里（包括 `bypassPermissions`）guard 的"先问"会弹出确认框，标题是命令和命中的必须停事项；`claude -p`、`pi -p`、`omp -p` 这类非交互运行没有人能回答，"先问"变成拒绝执行，命令不会运行。Stop 门禁同样在 `-p` 下生效；Pi 和 OMP 的实测已收进 `./jstack smoke pi` / `./jstack smoke omp`。

## 为什么这样做

pstack 上游 `cursor/plugins` 已经官方维护一份 Claude Code 版：[`harness/pstack/claude-code`](https://github.com/cursor/plugins/tree/main/harness/pstack/claude-code)。它由上游脚本从 `pstack/` 生成，上游 CI 会检查 skill 里用到的每个 Cursor 名称在 adapter 映射表里都有对应的一行。凡是用到 Cursor 名称的 SKILL.md，都加了一句"先读 adapter"，由模型在运行时把 `Task`、`readonly`、模型名等映射成 Claude Code 的写法。

jstack 原样 vendor 这棵树，不再自己翻译一遍。下表是几种移植方式的对比：

| 做法 | 代表 | 取舍 |
|---|---|---|
| 运行时 adapter | 上游官方 | 由上游维护，跟进成本最低；代价是每个会话多读一份约 1.5k token 的映射表 |
| 构建期全量翻译 | michael-denyer/pstack-claude | 产物是原生 Claude Code 写法，但要维护上千行生成器和 99 条替换规则 |
| 镜像加手工改写 | backnotprop/pstack | 用 git 分支合并上游；改写全靠手工 |
| 深度 fork | ericlitman/open-pstack | 加了模型注册表和多 provider，离原版最远 |

没有选构建期翻译的原因：Cursor 术语是整句交织在一起的，例如 "a Task subagent with `subagent_type: generalPurpose` and `readonly: true` … default `grok-4.7-xhigh-fast`"。只替换其中一部分，会得到 Cursor 和 Claude Code 混杂的写法，模型仍然得读 adapter；要翻译完整，就会变成 michael-denyer 那样的长期维护负担。

Cursor 版 pstack 也走同一棵 Claude 树：`build` 只删掉面向其他 harness 的 adapter 提示、换回 Cursor 的 frontmatter 和脚本，不翻译 skill 正文里的工具名。两棵树的 skill 正文仍由上游同一份文件生成，不会出现两套措辞；那 24 处差异由 `patches/pstack-cursor/rules.tsv` 逐条覆盖，`check` 会核对。

Matt 的 skills 本来就是 Claude Code 原生写法，不需要 adapter。它的问题在别处：上游是一个 27 个 skill 的完整包，我们只收其中 10 个。所以 spec 不 vendor 上游的 `plugin.json`（它叫 `mattpocock-skills`、列全 27 个 skill），而是由补丁新建一个只列 10 个 skill 的清单，见下面的补丁表。

从第三方移植版借鉴的是维护纪律：

- 锁定上游提交（michael-denyer 的 `upstream.json`）
- 上游原样副本和本地改动分开存放，每次同步留记录（backnotprop 的 `upstream` 分支和 `SYNC-LOG.md`）
- 改动要在真实的 Claude Code 里验证（open-pstack）

补丁只用来修 adapter 管不到的问题，主要是脚本、frontmatter 和 manifest，因为它们不经过模型。

## 目录

```text
.claude-plugin/marketplace.json  marketplace 清单，名字是 jstack，发布 pstack、spec、flow
upstream/pstack/                 pstack 上游原样副本（cursor/plugins 的 harness/pstack/claude-code），不要手改
upstream/spec/                   spec 上游原样副本（mattpocock/skills 的 LICENSE 和 10 个 skill 目录），不要手改
patches/pstack/                  pstack 补丁，按文件名顺序应用
patches/pstack-cursor/           Cursor 转换规则（rules.tsv）和替换文件（manifest.json、worktree-audit.sh、logo）
patches/spec/                    spec 补丁，按文件名顺序应用
plugins/pstack/                  pstack 构建产物（Claude Code 树），等于 upstream 加 patches 再加版本戳，不要手改
plugins/pstack-cursor/           pstack 构建产物（Cursor 版，由 plugins/pstack 转换生成），不进 Claude marketplace，不要手改
plugins/spec/                    spec 构建产物，带 Claude 和 Cursor 两个 manifest，同上
src/flow/                        flow 的源码，jstack 自己维护，可以直接改
plugins/flow/                    flow 构建产物，带 Claude 和 Cursor 两个 manifest，等于 src/flow 再加版本戳，不要手改
docs/harness/agents.md           Pi/OMP/Claude Code 共用的 adapter，把 pstack 里的 Cursor 名称映射到各 harness
docs/harness/gates.md            门禁能力矩阵：各 harness 支持哪些事件、怎么接、怎么降级
docs/adr/                        决策记录；ADR-0006 定义项目级接入与用户级 / 仓库级两层配置
docs/agents/jstack-config.md     两级配置的字段表：归属、默认值、读取方（ADR-0006）
package.json                     Pi package manifest，pi.skills 指向三个插件的 skills，pi.extensions 指向 flow 的门禁扩展
upstream/pstack.lock.json        锁定的 pstack（Claude Code 树）上游：仓库、路径、提交、版本、副本内容哈希
upstream/spec.lock.json          锁定的 spec 上游，字段同上
SYNC-LOG.md                      上游同步记录
evals/run.sh                     评测 runner（./jstack eval）
evals/fixture/                   评测用的种子项目，每个样本复制一份
evals/tasks/<任务>/              评测任务：prompt.md、check.sh、solution.patch 或 answer.md、可选的 seed/
evals/results.jsonl              评测记录，每个样本一行，只追加
evals/reports/<日期>.md          评测报告，每次运行追加一节
tests/flow-hooks.sh              flow 阶段门禁和 hooks 的测试（check 会跑）
jstack                           维护脚本：install / install-pi / install-cursor / sync / build / check / smoke / eval / models
```

## 当前补丁

pstack：

| 补丁 | 修了什么 | 为什么 adapter 管不到 |
|---|---|---|
| `0001-worktree-audit-claude-code-transcripts` | `worktree-audit.sh` 原来只在 `~/.cursor/projects/<slug>/agent-transcripts` 里找会话记录，现在改为在 `~/.claude/projects/<slug>` 里找，并且同时搜主仓库和 worktree 自己的目录 | 这是 shell 脚本，不经过模型。不修的话 `LAST_CHAT` 永远为空，已合并、但最近还有会话在用的 worktree 会被标成 `safe`，worktree-cleanup 剧本可能据此把它删掉。Cursor 产物由转换规则换回 Cursor 版本的脚本。改编自 [backnotprop/pstack](https://github.com/backnotprop/pstack)（MIT） |
| `0002-adapter-transcript-slug` | adapter 原文说 slug 规则是"把 `/` 和 `.` 换成 `-`"，改成"把所有非字母数字字符换成 `-`" | 2026-11-06 在本机 `~/.claude/projects` 实测 32 个目录：新规则 32 个全对；原规则错了 7 个，都是路径里带 `_` 的。规则写错会让 `reflect`、`recall` 这类 skill 找不到会话记录 |
| `0003-poteto-agent-background-frontmatter` | `poteto-agent` 的 frontmatter 把 Cursor 的 `is_background: true` 改成 Claude Code 的 `background: true` | frontmatter 由 Claude Code 解析，不经过模型。原来的键会被静默忽略，只在会话 debug 日志里留一条 WARN，`claude plugin validate` 不报。poteto-mode 要求每次派 delegate 都放后台。2026-11-06 对照实测：主会话明确要求前台运行时，上游原版在前台跑完才返回，打补丁后强制转后台。代价：Claude Code 不允许 agent teams 的进程内 teammate 派 `background: true` 的 agent，pstack 本身不用 agent teams |
| `0004-generic-harness-adapter` | 把 `docs/harness/claude-code.md` 的映射表扩成 `docs/harness/agents.md`，分出 Claude Code、Pi、OMP 三节；`claude-code.md` 只留一个指向它的兼容指针，所有 skill 和 README 里的 adapter 链接改到新文件 | adapter 是模型运行时读的文档，上游只有 Claude Code 一版。Pi 和 OMP 用同一套工具名，但入口、agent 发现和模型角色不同；把差异集中在一个文件里，同步上游后仍只需要维护这一处。Cursor 产物在 build 时删掉这句提示，不读这份 adapter |
| `0005-adapter-cursor-builtins` | 在 adapter 的 Claude Code 一节补上 `cursor-team-kit` 和 `create-skill`、`/loop`、`/deslop`、`control-ui`、`control-cli` 五个 Cursor 内置项的替代做法；Pi 和 OMP 两节原有这一行 | adapter 是运行时文档，模型读到 `cursor-team-kit` 和这几个名字时，Claude Code 一节原来没有任何说明，模型只能自己猜或者干脆跳过。Cursor 产物在 build 时删掉这句提示，不读这份 adapter |
| `0006-adapter-codex` | 在 adapter 加 Codex 一节和检测行：工具名（`shell`、`apply_patch`、`update_plan`）、`spawn_agent` 派自定义 agent、模型与 effort、`$<插件>:<skill>` 调用、会话记录路径和 Cursor-only 降级 | adapter 是运行时文档。Codex 0.166 能直接读 Claude 格式的插件清单和 skill，但工具名、子 agent 机制、skill 调用方式都和 Cursor 不同；映射集中在这一节，`locate.sh`、安装和 smoke 都按它来。Cursor 产物在 build 时删掉这句提示，不读这份 adapter |
| `0007-adapter-workloop` | 在 adapter 加 Workloop 一节和检测行：`agent` 的 `model` / `variant`、`run_workflow` 并行、没有 `Skill` 和 `TodoWrite` 时的做法 | adapter 是运行时文档。Workloop 是第三方云端平台，工具名和子 agent 参数都和 Cursor 不同；映射来自 #33 的沙箱观察，本地 smoke 跑不到，需要在沙箱里手动验收 |
| `0008-subagent-brief-must-stop` | 在 `poteto-mode` 的 Subagents 一节加一段：子代理 brief 不得授权 must-stop 动作；`opening-a-pr` 的 Size and stacks 改为子分支 merge 父分支后普通 push，不再 rebase 加 force push | 上游没有 jstack 的 must-stop 概念，adapter 只映射工具名，管不到 brief 文本授权了什么；guard 只看得到编排者自己的 shell 命令，子代理也可能没有门禁。叠加分支更新改用 merge 是 #34 的推荐做法，force push 仍按 must-stop 先问人 |

spec：

| 补丁 | 修了什么 | 为什么不能用上游的做法 |
|---|---|---|
| `0001-plugin-manifest` | 新建 `.claude-plugin/plugin.json`：插件名 `spec`、只列 10 个 skill；版本号先写占位 `0.0.0`，由 `build` 改成 `<上游版本>+jstack.<内容哈希>` | 上游 manifest 叫 `mattpocock-skills`、列了 27 个 skill，还带 `implement` 实现编排，原样收进来就会和 poteto-mode 抢主编排。如果改成 vendor 上游 manifest 再打补丁，版本号那一行每次上游发版都会变，补丁必然打不上；新建一个文件则与上游版本无关 |
| `0002-skill-tool-fallback` | 在 `grill-with-docs` 和 `wayfinder` 里补一句：harness 没有 Skill 工具时，按名字读取被调用 skill 的 `SKILL.md` | 这两处业务内容要求"用 Skill 工具调用 grilling / domain-modeling"。Pi 和 OMP 的 skill 加载方式不同，有的版本不暴露 Skill 工具；只补调用方式，不改 skill 的业务内容。Claude Code 有 Skill 工具，会走原来的路径 |
| `0003-cursor-manifest` | 新建 `.cursor-plugin/plugin.json`：插件名 `spec`、列同样 10 个 skill；版本号先写占位 `0.0.0`，由 `build` 与 Claude manifest 一起重写 | 上游没有 Cursor 插件清单。Cursor 的加载器要求自己的 manifest，而 spec 只收 10 个 skill，不能直接复制上游的全量清单；由补丁新建，避免上游发版时冲突 |

pstack 这几处问题都值得提给上游 `cursor/plugins`。上游修好之后，`sync` 时补丁会打不上，删掉对应补丁即可。

看过但没打补丁的：`poteto-mode` 的 `icon`、`color` 是 Cursor 界面用的字段，Claude Code 忽略，不影响行为。spec 的 skill 目录里有 `agents/openai.yaml`（Codex 用的元数据），Claude Code 不读，留着是为了让副本和上游一致。

## 维护

更新上游：

```bash
./jstack sync             # pstack、spec 都跟 main（flow 没有上游，跳过）
./jstack sync spec        # 只同步 spec
./jstack sync pstack 2776ddd2355d6d6c8747d3964600f28daf62f049   # 指定 ref：tag、分支或完整提交号
git diff -- upstream/     # 看上游改了什么
./jstack check
```

pstack 只同步 Claude Code 树；Cursor 版由 `build` 转换，不再单独同步。上游同步后，`check` 会核对 `patches/pstack-cursor/rules.tsv` 的每条规则是否仍然命中：差异消失或出现规则没覆盖的新差异都会报出来，按提示改规则表或替换文件。

`ref` 要用 tag、分支名或**完整**提交号。git 的 `fetch` 不接受短提交号，`./jstack sync pstack 2776ddd` 会报 `couldn't find remote ref`。

不传 ref 时跟 `main`，锁文件会更新到上游最新的 main。要停在某个提交，就把完整提交号传给 `sync`。

`check` 检查这些内容：

1. 每个 `plugins/<插件>` 是否等于构建结果（防手改），包括由 `pstack` 转换出的 `pstack-cursor`
2. 每棵 `upstream/<树>` 的内容哈希是否等于锁文件里 `tree` 字段记录的（防手改副本；flow 没有上游，跳过）
3. 各插件脚本里有没有写死的 Cursor 路径
4. skill 和 agent 的 frontmatter：有没有 Claude Code 不认识的键；skill 的 frontmatter 里有没有未加引号又含 `: ` 的值（Cursor 的加载器用严格 YAML，遇到这种值会静默丢掉整个 skill）
5. skill 里通过 Skill 工具调用的 skill 是否都收进了插件
6. spec/flow 的 Cursor manifest 是否和 Claude manifest 同名、同版本、同样的 skill 列表
7. `plugins/pstack-cursor` 是否等于 `plugins/pstack` 的转换结果；`patches/pstack-cursor/rules.tsv` 的每条规则是否都命中差异，转换是否只改动规则覆盖的文件（skills/ 24 个、agents/ 1 个）；manifest、logo、`is_background` 和 worktree-audit 的 Cursor 路径是否齐全
8. 根目录 `package.json` 是否把三个插件的 skills 和 flow 的门禁扩展（`pi.extensions`）都暴露给 Pi
9. `stages.md` 里的每个提供者是否在七种布局下都找得到：用 `plugins/` 产物在临时的假 HOME 里复制出本地 marketplace、Claude GitHub 缓存、OMP 缓存、Cursor 本地插件、Pi npm 包、Codex 缓存（`$CODEX_HOME/plugins/cache/jstack/<插件>/<版本>`，版本去掉 `+` 后面的构建元数据），再加一种入口软链（`<tmp>/.agents/skills/route` 指向仓库里的 flow skill），从各自的 flow 副本运行 `locate.sh`，路径必须落在该布局自己的树里；再把一个提供者换成 `spec:no-such-skill`，`locate.sh` 必须失败并点名它
10. `claude plugin validate` 是否通过（marketplace 和全部插件）
11. 评测任务自检（`./jstack eval --selftest`）：每个任务的 check 在初始状态下失败、在参考解下通过
12. flow 的 `stage.sh` 和三个 hook（`tests/flow-hooks.sh`）：对 `plugins/flow` 产物喂 JSON、断言输出和状态文件，Claude Code 和 Cursor 两种输入/输出协议都测，会话 id 的四级回退（`JSTACK_SESSION_ID`、`PI_SESSION_ID`、`CLAUDE_CODE_SESSION_ID`、`CURSOR_CONVERSATION_ID`）也测，有 jq 和没有 jq 两种路径也都测；macOS 上用 `/bin/bash`（3.2）运行
13. 模型分层命令（`./jstack models`）：在临时 HOME 里跑 init、set、apply、status，核对四个 harness 的规则文件、Pi/OMP 标记块合并与首次确认、旧配置迁移备份、roles 覆盖、settings.json 的模型 env 和原有键、备份幂等、`--dry-run` 不落盘、预算降级，以及今日 token 统计
14. 仓库级配置（`<repo>/.jstack/config.json`，ADR-0006）：当前仓库有配置时校验字段与 `stages_file`；在临时仓库里验证 `stage.sh` 按 `stages_file` 收/拒阶段、`guard.sh` 合并 `must_stop` 并在 reason 里标明“仓库追加”、`prompt.sh` 注入配置，坏 JSON、禁用键、缺 `execute` 都要报出来
15. `./jstack doctor`：临时 HOME 构造 Claude user/project、Pi package、OMP 缓存、Cursor 本地插件、Codex 缓存、vendor 和 lock 七种来源，核对表格与 `--json` 的值；篡改 lock 版本或源目录版本后必须报漂移并返回非 0，`--no-fail` 只警告
16. 项目级安装（`./jstack install --all --scope project`）：在临时仓库和假 HOME 里核对 vendor、9 个入口链接、Claude agents 与 hooks、Cursor hooks、Codex 的 `.codex/agents/*.toml` 与 `.codex/hooks.json`（三条绝对路径、PreToolUse 匹配 Bash）、lock 的版本、树哈希与 `recommended.pi`；三路 `locate.sh` 都要找全阶段表提供者，重复运行不改产物，`--dry-run` 不落盘，改 vendor 文件、删入口、删 `.pi/settings.json`、`.cursor/hooks.json`、`.codex/hooks.json` 或 `.codex/agents` 后 `doctor` 必须失败
17. 工具配置（`tests/tool-policy.py`）：阶段 profile 引用变化反映在导出、重复导出 digest 稳定、digest 可由标准 JSON 复算、重复字段/未知能力/未知 profile 被拒绝、Pi 与 Claude Code 的原生名选择、缺必需工具拒绝、shell fallback 需显式接受、缺可选工具不伪装成可用
18. Pi 推荐包（`tests/pi-recommended.py`）：缺包时安装固定 source、第二次跳过、项目作用域不复用用户作用域、已装的较新版本保留并报告、`--dry-run` 不安装不写文件、安装时禁用 lifecycle scripts、provider/models/auth 配置不变

第 3、4、5 项专门查 adapter 管不到的地方：脚本和 frontmatter 都不经过模型，上游新引入的 Cursor 依赖在同步时就能发现；第 5 项查的是 spec 这种"只收一部分 skill"的插件有没有漏掉依赖。`claude plugin validate` 不查 frontmatter 键，也不查插件内部 skill 之间的调用关系，更不查 YAML 合法性，所以 `: ` 这种写法只能由第 4 项拦。全部通过才提交。

### CI

`.github/workflows/check.yml` 在每个 PR 和 `main` 的每次提交上跑 `./jstack check`，macOS 和 Ubuntu 各一个 job（`fail-fast: false`，两边都会跑完）。macOS job 用系统自带的 bash 3.2，并设成 `en_US.UTF-8`，复现本机最容易踩的 locale 坑。

CI 只跑不耗 token 的部分：

- 跑：上面第 1–18 项全部，包括 `claude plugin validate` 和 `./jstack eval --selftest`（自检不调模型）
- 不跑：`--smoke`（要本机已安装的 Pi / OMP / Cursor / Codex，会启动模型）、`./jstack eval`（调模型，要网络和模型额度）

workflow 里装了 `jq`、Python、Node 24 和当前的 Claude Code CLI（只给 `claude plugin validate` 用），不读任何密钥，也不访问模型接口。macOS job 的 Python 是 3.9，与开发机的系统 `python3` 一致；`ubuntu-latest`（26.04）没有 3.9 的构建，用 3.12。抬高最低支持版本时记得同步这里。

### 跨 harness smoke

`check --smoke` 在静态检查之后，对**本机已安装**的 harness 各跑一遍 headless 链路；没安装的 harness 会打印跳过原因，不算失败。也可以单独运行：

```bash
./jstack smoke pi       # skill 目录、/skill:poteto-mode、route locate.sh、poteto-agent、阶段门禁
./jstack smoke omp      # skill:// URI、隐藏入口按路径读、route、task 派发 poteto-agent、阶段门禁
./jstack smoke cursor   # 调用 Cursor 自带 plugins-loader 检查三个插件、hooks 和 route
./jstack smoke codex    # skill 目录（flow:route、pstack:poteto-mode）、route locate.sh、spawn_agent 派 poteto-agent、阶段门禁
./jstack smoke all      # 四个都跑（= ./jstack check --smoke）
```

Pi、OMP 和 Codex 的 smoke 会实际启动模型、消耗 token，需要网络；它们是验收测试，不是每次提交的默认门禁。Codex 的 smoke 用临时的 `CODEX_HOME`（只软链真实的 `auth.json` / `config.toml`），不读用户级插件，测的是项目级安装本身；hooks 用 `--dangerously-bypass-hook-trust` 跳过信任检查（来源已审查）；模型默认 `opencode-go/deepseek-v4.1-flash`，可用 `JSTACK_SMOKE_CODEX_MODEL` 覆盖；hooks 信任提示和交互式 deny 行为按 `docs/testing/codex.md` 手动做。Cursor 没有可脚本化的 headless agent CLI，smoke 验证加载器解析结果、三个 hook 的 Cursor 协议输出和 `locate.sh`，交互部分按 `docs/testing/cursor.md` 手动做。

每条 headless 命令限时 `JSTACK_SMOKE_TIMEOUT` 秒，默认 600。超时会先 TERM、10 秒后仍在就 KILL，该项按运行失败处理。

补丁打不上，说明上游改了那一段。对照 `upstream/<插件>` 重做补丁；如果上游已经修好，就直接删掉补丁。

新增补丁的步骤：在临时目录建 `a/` 和 `b/` 两份文件，只改 `b/`，然后：

```bash
git diff --no-index --src-prefix= --dst-prefix= a/<路径> b/<路径> > patches/<插件>/NNNN-<说明>.patch
./jstack build && ./jstack check
```

新建文件也可以这样打补丁（`a/` 那边不存在即可），补丁里会写成 `--- /dev/null`。`patches/spec/0001` 就是这么来的。

版本号由 `build` 写成 `<上游版本>+jstack.<内容哈希>`，内容一变版本号就变。pstack 的上游版本从 `plugin.json` 读，spec 的从锁文件读（它不收上游的 manifest）；spec 和 flow 的 Cursor manifest 版本由 `build` 与 Claude manifest 一起重写。

本机的 marketplace 是从本地路径添加的，会话直接从 `plugins/<插件>` 加载。Claude Code 在缓存里也复制了一份，但不读它（2026-11-06 用 `claude --debug-file` 看启动日志确认）。所以 `build` 之后，重开会话或运行 `/reload-plugins` 就生效。再跑一次 `./jstack install`，`claude plugin list` 里的版本号也会跟上。

其他机器从 GitHub 安装，插件复制进缓存，只有版本号变了才会更新。更新命令：`claude plugin marketplace update jstack && claude plugin update pstack@jstack && claude plugin update spec@jstack && claude plugin update flow@jstack`。

## 评测

`./jstack eval` 衡量工作流本身。它把一批固定任务交给 headless 的 harness（默认 Claude Code，也可以选 Pi），每道题跑两组：**工作流组**用项目级安装的产物把 jstack 完整接上（入口 skill、阶段提示、guard 和 Stop 门禁都生效），**对照组**什么都不加载，只有模型和题目。两组并排，看的是走工作流比不走好多少：做成了没有、要人插手几次、花了多少。smoke 只证明调用链跑得通。改了工作流以后是变好还是变差，要靠评测回答。

每个任务在 `evals/tasks/<名字>/` 下，包括 `prompt.md`（原样作为第一条用户消息）、`check.sh`（判定是否完成）、`solution.patch` 或 `answer.md`（参考解），以及可选的 `seed/`。每个样本都有自己的工作目录 `<临时目录>/<随机>/tasknotes`：先复制 `evals/fixture/`，再叠加 `seed/`，工作流组接着跑 `./jstack install --scope project --repo <样本仓库>`，然后 `git init` 并提交一次。安装产物（`.jstack/`、`.claude/`）写进 `.git/info/exclude`，不进初始提交，也不进样本的 `diff.patch`。路径里不出现 eval、test 这类词，被测 agent 不知道自己在被评测。`seed/CLAUDE.md` 让样本仓库按 jstack 的方式从 `route` skill 开始；check 仍只看功能，route / poteto 是否触发、Stop 门禁拦了几次由记录里的对应字段给出。对照组保留题目本身需要的种子文件（坏代码、仓库约定），只去掉指导走工作流的 `CLAUDE.md` / `AGENTS.md`。`m-route-stop-gate` 是专门构造的门禁探针样本：seed 的仓库约定要求每次代码改动都带 verify，prompt 让 agent 实现 `tasknotes clear`、改完直接停，并明说这次就是看 Stop 门禁会不会拦下没有证据的结束；被拦回来后再按提示在临时目录跑 CLI、记录证据收尾。它的 `stop_blocks` 大于 0 就说明门禁真的挡了；`stage.sh end` 在同样条件下也拒绝清掉状态，否则模型只要跑一次 end 就能绕过 Stop 门禁。同一份 seed 在 Pi 下原样传入；seed 里写的是 `route`，Claude Code 用 `/route`、Pi 和 OMP 用 `/skill:route`。

```bash
./jstack eval list                           # 列出任务
./jstack eval --selftest                     # 不调模型：初始状态 check 必须失败，参考解下必须通过（check 也跑这一项）
./jstack eval                                # 全部任务 × 两组，各 1 个样本（Claude Code）
./jstack eval --samples 3 --jobs 3           # 每个任务每组 3 个样本，3 个并发
./jstack eval --group workflow --model <模型> --max-nudges 1 --keep xs-empty-message
./jstack eval --harness pi --provider <provider> --model <模型> --thinking high --samples 3 --jobs 3
```

不传 `--harness` 时是 `claude`，旧命令照常可用；样本仓库改成项目级安装、对照组常设之后，2026-11-13 之前的基线不能直接比，要用新跑的一份。Claude 不传 `--model` 时，runner 从用户级配置 `~/.jstack/config.json`（还没迁移时退回旧 `~/.config/jstack/models.json`）的 `models.claude-code.bulk[0]` 取默认，启动时打印用的是哪个模型；读不到就拒绝运行，不会跟随 Claude Code 的默认模型跑到 premium。Pi 必须显式传 `--model`，`--provider` 和 `--thinking` 也只对 Pi 生效；runner 不读用户配置，也不猜 Pi 的默认模型。`--thinking` 取 `off`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max`。每次运行的 `RUN_ID` 带随机后缀，同一秒启动的两次评测不会共用目录和报告区段。`--group` 默认 `both`，即每个任务跑工作流组和对照组各一遍；`--group workflow` 或 `control` 只跑一组，用于调试，不能当作完整评测的基线。

Pi 评测前先 `./jstack build`，runner 会核对 flow 扩展和三个 skill 目录的构建产物。provider 名以 `pi --list-models` 的结果为准；没有 `--provider` 时由 Pi 自己解析模型。

每轮结束后跑 `check.sh`，cwd 是工作目录，`ANSWER_FILE` 指向 agent 最后一条回复。Claude 的 check 没通过，runner 就用 `--resume` 发一条固定的催促消息："我现在不在电脑前，回答不了问题。需要决定的地方按你推荐的方案处理，把这件事做完。"每个样本最多催 `--max-nudges` 次，默认 2 次。Pi 目前只跑单轮，`nudges` 固定为 0，`--max-nudges` 只能是 0；runner 不会假装 Pi 的续跑和 Claude 的 `--resume` 等价。每轮的时限是 `JSTACK_EVAL_TIMEOUT` 秒，默认 1800；超时会杀掉整个进程组，避免留下 shell 子进程。超时的样本直接判失败，不再催促。只有 check 通过、进程退出码为 0、且本轮有干净的结束事件（Claude 的 `result`、Pi 的 `agent_end`）时才记 `pass: true`；check 通过但进程非零退出、缺结束事件或助手报错时，记录里会写明 `error`。评测是测量，任务失败不影响退出码，只有参数错误或缺少依赖才非 0。

每个样本记一行 JSON，字段如下：

| 字段 | 含义 |
|---|---|
| `harness` / `provider` / `thinking` | 跑评测的 harness；Pi 的 provider 和推理等级。旧记录没有 `harness` 时按 `claude` 处理 |
| `group` | `workflow`（项目级安装，走 jstack）或 `control`（不加载任何 jstack 入口）。旧记录没有这个字段：任务名以 `-vanilla` 结尾的按 `control` 处理，其余按 `workflow` |
| `gates` | 门禁从哪来：`project`（Claude Code 的项目级 hooks）、`extension`（Pi 的 flow 扩展）、`off`（对照组）。旧记录按 `off` 处理，因为它们当时关掉了全部 hooks |
| `stop_blocks` | Stop 门禁拦下"没记证据就想结束"的次数。Claude Code 把拦回的理由作为 `Stop hook feedback:` 消息写回会话；Pi 数扩展发出的 `jstack-gates` 消息。对照组应为 0 |
| `pass` | 最终 check 是否通过，同时要求本轮退出码为 0、有干净的结束事件、助手没有报错 |
| `nudges` | **打断次数**，等于实际发出的催促次数。agent 每停下一次（提问、等确认，或自认为做完但 check 不通过）就会被催一次，对应真实使用中人要回来插手一次。0 表示一次做完。Pi 固定为 0 |
| `rounds` | 跑了几轮 agent，Claude 等于 `nudges + 1`；Pi 为 1 |
| `turns` | Claude 是各轮 `num_turns` 之和；Pi 是 `turn_end` 事件数 |
| `wall_s` | 样本从开始到结束的秒数，包括 check |
| `tokens` | input、output、cache read、cache write 四类 token 之和，覆盖全部模型和子 agent。Pi 的 provider 没有报告 usage 时为 `null`，不填 0 |
| `premium_tokens` | 只算模型名匹配 `JSTACK_PREMIUM_MODELS` 的部分，默认正则 `(^|/)(claude|anthropic)|opus`。Pi 没有 usage 时同样为 `null` |
| `cost_usd` | Claude Code 报告的费用；Pi 从 `usage.cost.total` 汇总，缺失时为 `null` |
| `route` / `poteto` | 主会话有没有调 `route` skill，有没有进入 poteto-mode（调 skill 或读它的 `SKILL.md`） |
| `subagents` | 主会话派出的 `Agent` / `Task` / `subagent` 次数 |
| `timed_out` / `error` | 是否超时；某轮非零退出、没有结束事件、结束事件报错或助手停止原因是 `error` / `aborted` / `length` 时，`error` 写明是哪一轮、什么错。出错的样本不等于工作流退化，先看 `error` |
| `model` / `commit` | Claude 取 init 事件里的模型，Pi 取最后一条助手消息的模型；仓库提交号，工作区有改动时带 `-dirty` |

Claude 的 `--resume` 之后，`result` 事件里的 `modelUsage` 和 `total_cost_usd` 是整个会话的累计值，而 `num_turns` 只算本轮（2026-11-07 实测）。所以 runner 按轮取 token 和费用的增量，不会重复计算。Pi 每轮都是独立进程，没有这个累计问题。

隔离方式：

- `env -i` 只传 `HOME`、`USER`、`PATH`、`LANG`、`LC_ALL`、`TMPDIR`、`SHELL`，再额外传 `JSTACK_STATE_DIR` 把 flow 门禁状态写进样本工作目录同级（不在工作目录里，不污染 diff）。不这样做的话，claude 会继承宿主（桌面 App、外层 Claude 会话）的变量，报 "Not logged in"
- 每个样本另有三个沙箱环境（issue #83）：`PATH` 最前面放一个占位的 `gbrain`，只打印"评测沙箱里不可用"并以非零退出（archive 的写回本来就有写失败则打印页面内容的降级）；`GH_CONFIG_DIR` 指向沙箱里的空目录，`gh` 没有登录态，建不了真实 issue；`CLAUDE_CONFIG_DIR` 指向沙箱目录，里面只放用户 `~/.claude/settings.json` 的 `env` 段（模型网关和登录态），用户级 hooks、用户 `CLAUDE.md` / `rules/`、用户 skills 和插件都不加载。`HOME` 保持真实，换掉会报 "Not logged in"
- Claude 工作流组：样本仓库先做 `./jstack install --scope project --repo <样本仓库>`，产物是当前工作区的构建（`plugins/` 经 `install` 复制进 `.jstack/vendor/`），不是用户已装的版本。入口 skill 从 `.claude/skills` 加载，没有插件前缀；flow 的 `prompt.sh` / `guard.sh` / `stop.sh` 由 `.claude/settings.json` 触发，`JSTACK_STATE_DIR` 指向样本工作目录同级的 `gates/`，所以 Stop 门禁真的会拦住"没记证据就结束"的样本
- Claude 工作流组：`--settings` 里把已安装的 `pstack@jstack`、`spec@jstack`、`flow@jstack` 关掉，避免和样本仓库的项目级安装重复加载；自己的 hooks 保持开启
- Claude 对照组：不做项目级安装，`--settings` 里 `disableAllHooks: true` 并关掉三个已装插件，只有模型和题目。两组都不跑用户级 hooks（`CLAUDE_CONFIG_DIR` 是沙箱），工作流组只多出样本仓库自己的项目级 flow hooks；两组唯一的差别就是这套工作流
- Pi 工作流组：`-e` 显式加载 flow 扩展（门禁来自扩展，记录里 `gates` 是 `extension`），三个 `--skill` 加载构建产物；Pi 的项目级入口要求信任项目，eval 里不打开，所以 Pi 不走项目级安装。对照组既不加扩展也不加 skill
- Claude：`--strict-mcp-config` 不加载任何 MCP；`gbrain` 走 PATH 占位，`gh` 走空配置目录
- Pi：一律带 `pi -p --mode json --no-session --no-mcp --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve`。`--no-*` 挡住用户已装的扩展、skills、prompt templates 和发现的 AGENTS/CLAUDE；`--no-approve` 不信任项目 `.pi` 配置和资源。工作流组的扩展（`-e plugins/flow/extensions/pi.ts`，hooks 仍然从 `plugins/flow/hooks/` 跑）和三个 `--skill` 目录由 runner 显式加上
- Pi：样本仓库里的任务上下文（`AGENTS.override.md`、`AGENTS.md` 或 `CLAUDE.md`）由 runner 用 `--append-system-prompt <文件>` 显式传入，不会把用户级 AGENTS/CLAUDE 带进来。`--no-session` 不写会话文件，`PI_SESSION_FILE` 为空
- 没有隔离的部分：`HOME` 是真实的，样本仍能读本机文件系统、访问网络；`gbrain` 只是 PATH 上的占位，用绝对路径调用真实的二进制仍能跑（这次基线里没观察到）；`git push`、ssh 这类通道没有加约束（样本仓库没有 remote，也没观察到）。Pi 的用户级 `SYSTEM.md` / `APPEND_SYSTEM.md` 不在 `--no-context-files` 的关闭范围。基线要在同一台机器、同一套用户配置下对比

产物：

- `evals/results.jsonl`：每个样本一行，只追加，和代码一起提交，当作基线
- `evals/reports/<日期>.md`：每次运行追加一节，包括 commit、harness、provider、thinking、model、组、样本数、max-nudges，以及按任务和组汇总的表；每道题有工作流组和对照组两行，另外每组一行合计。这一节同时打印到终端
- `.scratch/evals/<run_id>/<任务>-<n>-<组>/`：原始材料，不提交。包括每轮的 `round-<k>.jsonl` 和 `.err`、`answer-<k>.txt`、`check-<k>.txt`、合并后的 `rounds.jsonl` 和 `rounds.err`、最终的 `diff.patch`、`record.json`；门禁状态在样本工作目录同级的 `gates/`，默认一起删。工作目录默认跑完就删，加 `--keep` 会保留并打印路径

`tests/eval-pi.sh` 是 runner 的无模型测试：用假的 `pi` / `claude` 只验证 argv、事件解析、usage 缺失、错误 / 缺 `agent_end` / 超时判定、进程组清理，以及两组各自的加载方式（工作流组装项目级产物并开 hooks，对照组什么都不加载）和 `stop_blocks` 计数。它不代表真实模型验收，目前也不挂在 `./jstack check` 里，需要手动跑 `bash tests/eval-pi.sh`；真实基线仍要跑上面的评测命令。

下面这些改动必须先跑 `./jstack eval`，再和 `evals/results.jsonl` 里最近一次同模型的基线对比：

- 改 `src/flow`
- 增删或修改 `patches/` 下的补丁，包括 adapter `docs/harness/agents.md`
- 同步上游（`./jstack sync`）
- 改模型配置（模型角色表、默认模型、两层模型）
- 改 hooks

退化要么修掉，要么在提交说明里写明理由。单个样本的噪声很大，判断退化至少用 `--samples 3`。差距小于同一提交多次运行之间的波动时，不算退化。改了 `evals/` 本身（runner、任务、fixture）以后，旧基线就不能直接比了，要先重跑一份新基线。`harness`、`provider`、`thinking`、`group` 是记录里的分基线字段：同一次改动前后必须用同一组值；完整评测默认两组都跑，用 `--group` 只跑一组的结果不能和完整基线比。Pi 没有 Claude 的续跑，`nudges` 不要跨 harness 比较。

## 推广到团队项目

仓库当前是 public，队友直接 clone 即可；如果改回 private，先在 Settings → Collaborators 里把队员加为协作者，他们才有权 clone（以及运行 `gh auth setup-git` 或配好 SSH key）。

然后在业务项目的 `.claude/settings.json` 里加上下面的配置并提交。队友信任这个项目之后，Claude Code 会注册 jstack marketplace。如果仍提示未安装，每人运行一次 `claude plugin install pstack@jstack`、`claude plugin install spec@jstack` 和 `claude plugin install flow@jstack`。

```json
{
  "extraKnownMarketplaces": {
    "jstack": { "source": { "source": "github", "repo": "jionpz/jstack" } }
  },
  "enabledPlugins": { "pstack@jstack": true, "spec@jstack": true, "flow@jstack": true }
}
```

## 计划

路线图见 [jionpz/jstack#8](https://github.com/jionpz/jstack/issues/8)，子 issue 按依赖排序：评测套件、阶段表、两层模型、结构门禁、注意力协议、归档阶段、`jstack onboard`、Codex 支持、迁出 Trellis，以及用评测数据决定要不要精简 pstack。

- 可选：如果 `flow:route` 被模型漏掉的情况多，再加一个 SessionStart hook 提示它。2026-11-06 用 DeepSeek Flash 实测：L 级需求会自动进入 route；S 级的一行 bug 修复没有进入 route，模型直接改完并验证了。这一点并入结构门禁 issue 的"逐轮阶段提示"。
- 可选：如果团队统一用 GitHub Issues，考虑收录 `triage` skill，让 `to-spec`/`to-tickets` 的标签流程自动化（现在要手动建 `ready-for-agent` 标签）。

## 致谢

- pstack © Lauren Tan，MIT 许可，原文见 `plugins/pstack/LICENSE`。Claude Code 树由 cursor/plugins 官方生成，Cursor 版由 jstack 在 build 时从这棵树转换。
- spec © Matt Pocock，MIT 许可，原文见 `plugins/spec/LICENSE`。
- pstack 补丁 0001 改编自 backnotprop/pstack（MIT）。
