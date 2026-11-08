# jstack

jionpz 长期维护的 AI 开发工作流。目标是少占用人的注意力：工作流自己判断什么时候需要人介入，自动走完开发、测试、验证、归档；token 有限的高级模型只做关键判断，token 几乎无限的 DeepSeek / GLM 类模型负责执行和验证。设计决策见 `docs/adr/`，其中 0002 到 0005 定义了方向。

工作流由 jstack 自己定义的阶段组成，每个阶段绑定一个当前的提供者；上游 skill 只是提供者，可以被改写或替换。目前以三个插件的形式发布：

- **pstack**：原版 [pstack](https://github.com/cursor/plugins/tree/main/pstack)（Lauren Tan，MIT），负责执行。Claude Code 用上游的 Claude Code 树，Cursor 用上游原生树，Pi/OMP 通过 `docs/harness/agents.md` 在运行时映射工具名和模型。
- **spec**：[Matt Pocock 的 skills](https://github.com/mattpocock/skills)（MIT）里负责需求澄清和任务拆解的几个，产出的 spec 和 tickets 交给 pstack 执行。
- **flow**：jstack 自己写的衔接层，只有一个 `route` skill。工程任务进来时它自动分级，按大小把 spec 和 pstack 接起来，见下面"分工"一节。

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
2. `/pstack:setup-pstack`：写入模型角色表 `~/.claude/rules/pstack-models.md`，只需要做一次。
3. 在要用 spec 的仓库里运行一次 `/spec:setup-matt-pocock-skills`：选定 issue tracker 和领域文档的位置，写 `docs/agents/*.md` 和 `CLAUDE.md` 里的 `## Agent skills` 段。
4. 直接描述任务即可。`flow:route` 会自动分级并选择流程；也可以显式运行 `/flow:route <任务描述>`。想跳过路由时，直接用 `/pstack:*` 或 `/spec:*` 命令，route 不会介入。

### Pi

仓库根目录本身是 Pi package：`package.json` 的 `pi.skills` 指向 `plugins/pstack/skills`、`plugins/spec/skills` 和 `plugins/flow/skills`。在仓库里运行：

```bash
./jstack install-pi
```

它会执行 `pi install <仓库> --approve`，并把 `plugins/pstack/agents/` 里的 `poteto-agent`、`comment-sicko` 转换后写到 `~/.pi/agent/agents/`（`background: true` 改成 Pi 的 `run_in_background: true`）。重复运行是幂等的；同名的非 jstack agent 文件不会被覆盖。

在 Pi 里用 `/skill:poteto-mode`、`/skill:route` 这类命令调用入口。pstack 的入口 skill 都是 `disable-model-invocation: true`，不会出现在模型自动选择的 skill 列表里，这是正常的，`/skill:<名字>` 仍然能加载。子 agent 需要 `@tintinweb/pi-subagents`；`install-pi` 检测不到会提示安装命令。

### OMP

OMP 读 Claude Code 的 `.claude-plugin/marketplace.json`，所以可以直接添加 jstack marketplace 并安装三个插件：

```bash
omp plugin marketplace add jionpz/jstack        # 本机仓库用绝对路径也可以
omp plugin install pstack@jstack spec@jstack flow@jstack
```

在 OMP 里用 `/skill:poteto-mode`、`/skill:route` 调用入口；pstack 的 `poteto-agent`、`comment-sicko` 会作为 `task` 工具的 agent 被发现。OMP 会丢弃 Claude 方言的 `model` frontmatter，模型角色用 `@slow` / `@plan` / `@smol` / `@task`，或在 OMP 配置里调整。更新插件用 `omp plugin upgrade pstack@jstack spec@jstack flow@jstack`。

### Cursor

Cursor 用上游原生的 pstack 树；spec 和 flow 与 Claude Code 共用同一份产物，只是额外带 `.cursor-plugin/plugin.json`：

```bash
./jstack build
./jstack install-cursor        # 复制到 ~/.cursor/plugins/local/{pstack,spec,flow}
```

Cursor 的本地插件加载器只接受 `~/.cursor/plugins/local` 内的符号链接，指向仓库的链接会被拒绝，所以 `install-cursor` 默认复制。改了构建产物后重新运行一次即可。

重开 Cursor 窗口。用 `/poteto-mode`、`/route`、`/grill-with-docs` 调用，不带插件前缀。`pstack` 保留 Cursor 原生的 `is_background: true` 等字段；spec/flow 的 Cursor manifest 和 Claude manifest 版本同步。完整检查清单见 `docs/testing/cursor.md`。

不要同时装 `pstack@cursor-plugins` 以及其他 pstack 移植版：它们的命令都以 `/pstack:` 开头，会互相冲突。也不要装 `mattpocock-skills`（Matt 的完整版）：skill 和 `spec` 重复，还带 `implement` 编排。`./jstack install` 检测到这些会拒绝安装并给出卸载命令。

运行时依赖：`bun`（poteto-mode 的 watch-pr 和 statechart 脚本）、`gh`（PR 和 CI 流程）、`rg`、`jq`。缺哪个，`install` 会提示。

## 分工

工作流由 [`src/flow/skills/route/stages.md`](src/flow/skills/route/stages.md) 定义成固定阶段：size、clarify、plan、execute、verify、review、land、archive。每个阶段写明产出、门禁和当前提供者（ADR-0002）。`flow:route` 先分级，再按大小选出要走的阶段，逐个交给提供者，不需要你选命令：

| 任务大小 | 阶段路线 |
|---|---|
| XS / S（改文案、修一个 bug、单文件小改） | execute → verify → land → archive |
| M，边界清楚 | execute → verify → review → land → archive |
| M，需求有多种合理解释 | clarify → execute → verify → review → land → archive |
| L（新模块、跨模块改造） | clarify → plan（spec + tickets）→ 每张 ticket 走 execute → land → archive |
| XL（跨会话、跨阶段） | 先用 wayfinder 规划，再对每块按 L 走；需要换会话时 handoff |
| 提问、调查 | 只走 execute，产出就是带出处的回答 |

execute 交给 poteto-mode。它的 playbook 已经包含验证、审查和开 PR，route 只补其后仍未满足的门禁。仓库没有 remote 时，分支上的提交就满足 land。archive 还没有提供者，暂时跳过并在报告里写明。

route 只在三处停下来问你，其余全部自动推进：

1. **澄清轮**：grill 把所有当前能问的问题一次列出，每个都带推荐答案，回答"是"就采纳。仓库还没跑过 setup 时，setup 的问题也并进这一轮。
2. **拆解签字**（只有 L、XL）：spec 的测试接缝和 ticket 拆分放在同一条消息里让你确认，确认之后才发布。
3. **必须由人决定的事项**：证据定不了的业务规则、破坏性的 API 或 schema 变更、不可逆的数据操作、生产环境/权限/安全、没有 ADR 的重大架构变化、成本/法务/隐私。这些攒在一轮里问。

签字之后由 poteto-mode 按 ticket 依赖顺序执行，不再停下来确认，poteto-mode 自己的 Always-pause 清单仍然有效。业务仓库的 `CLAUDE.md` 或 `.claude/rules/` 里定义了不同的分级、spec 位置或门禁时，以仓库为准。

`disable-model-invocation: true` 的 skill（pstack 57 个、spec 6 个：5 个入口加 setup）不能被模型用 Skill 工具调用，Claude Code 会直接拒绝，提示 "reserved for explicit user invocation"。route 用随附的 `locate.sh` 找到这些提供者文件的路径，然后直接读取并照着做，这也是 pstack 内部 skill 之间互相路由的方式。`locate.sh` 不写死 skill 名，而是读同目录 `stages.md` 的 Providers 列：换掉某个阶段的提供者只改表里那一格。它支持本地 marketplace、Claude Code 的 GitHub 缓存、OMP 缓存、Cursor 本地插件和 Pi package 五种安装布局，任一提供者找不到就点名并以非 0 退出。

几条硬规则：

- **主编排只有一个**：执行、分配 agent、测试、审查、返工都归 pstack。spec 的产出是输入材料。
- **spec 是"当前任务"的临时 spec**，不等于长期需求。已批准的需求留在项目自己的需求文档里；ADR 和术语表由 `domain-modeling` 写（`GLOSSARY.md`、`docs/adr/`）。
- **setup 是前置**：`to-spec`、`to-tickets`、`wayfinder` 找不到 `docs/agents/` 下的配置时会让你先跑 `/spec:setup-matt-pocock-skills`。
- **tracker 决定文件落在哪**：选 local markdown 时，spec 写到 `.scratch/<feature>/spec.md`，tickets 写到 `.scratch/<feature>/issues/NN-*.md`（`Status:` 行记状态，`Blocked by:` 行记依赖）；wayfinder 的地图在 `.scratch/<effort>/map.md`。这些是任务级材料，一般不提交。
- **用 GitHub tracker 时先建好 `ready-for-agent` 标签**：`to-spec` 会给 issue 打这个标签，仓库里没有标签时 `gh` 会报错。建一次即可：

  ```bash
  gh label create ready-for-agent
  ```

  （没收录 `triage` skill，所以不会自动写 `docs/agents/triage-labels.md`。）
- **handoff 写到 `$TMPDIR`**，不是仓库。它本来就是为了把当前会话交接给下一个 agent，不是长期文档。

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
upstream/pstack-cursor/          pstack 上游原样副本（cursor/plugins 的原生 pstack/ 树），不要手改
upstream/spec/                   spec 上游原样副本（mattpocock/skills 的 LICENSE 和 10 个 skill 目录），不要手改
patches/pstack/                  pstack 补丁，按文件名顺序应用
patches/spec/                    spec 补丁，按文件名顺序应用
plugins/pstack/                  pstack 构建产物（Claude Code 树），等于 upstream 加 patches 再加版本戳，不要手改
plugins/pstack-cursor/           pstack 构建产物（Cursor 原生树），不进 Claude marketplace，不要手改
plugins/spec/                    spec 构建产物，带 Claude 和 Cursor 两个 manifest，同上
src/flow/                        flow 的源码，jstack 自己维护，可以直接改
plugins/flow/                    flow 构建产物，带 Claude 和 Cursor 两个 manifest，等于 src/flow 再加版本戳，不要手改
docs/harness/agents.md           Pi/OMP/Claude Code 共用的 adapter，把 pstack 里的 Cursor 名称映射到各 harness
package.json                     Pi package manifest，pi.skills 指向三个插件的 skills
upstream/pstack.lock.json        锁定的 pstack（Claude Code 树）上游：仓库、路径、提交、版本、副本内容哈希
upstream/pstack-cursor.lock.json 锁定的 pstack（Cursor 原生树）上游，字段同上
upstream/spec.lock.json          锁定的 spec 上游，字段同上
SYNC-LOG.md                      上游同步记录
evals/run.sh                     评测 runner（./jstack eval）
evals/fixture/                   评测用的种子项目，每个样本复制一份
evals/tasks/<任务>/              评测任务：prompt.md、check.sh、solution.patch 或 answer.md、可选的 seed/
evals/results.jsonl              评测记录，每个样本一行，只追加
evals/reports/<日期>.md          评测报告，每次运行追加一节
jstack                           维护脚本：install / install-pi / install-cursor / sync / build / check / smoke / eval
```

## 当前补丁

pstack：

| 补丁 | 修了什么 | 为什么 adapter 管不到 |
|---|---|---|
| `0001-worktree-audit-claude-code-transcripts` | `worktree-audit.sh` 原来只在 `~/.cursor/projects/<slug>/agent-transcripts` 里找会话记录，现在改为在 `~/.claude/projects/<slug>` 里找，并且同时搜主仓库和 worktree 自己的目录 | 这是 shell 脚本，不经过模型。不修的话 `LAST_CHAT` 永远为空，已合并、但最近还有会话在用的 worktree 会被标成 `safe`，worktree-cleanup 剧本可能据此把它删掉。改编自 [backnotprop/pstack](https://github.com/backnotprop/pstack)（MIT） |
| `0002-adapter-transcript-slug` | adapter 原文说 slug 规则是"把 `/` 和 `.` 换成 `-`"，改成"把所有非字母数字字符换成 `-`" | 2026-11-06 在本机 `~/.claude/projects` 实测 32 个目录：新规则 32 个全对；原规则错了 7 个，都是路径里带 `_` 的。规则写错会让 `reflect`、`recall` 这类 skill 找不到会话记录 |
| `0003-poteto-agent-background-frontmatter` | `poteto-agent` 的 frontmatter 把 Cursor 的 `is_background: true` 改成 Claude Code 的 `background: true` | frontmatter 由 Claude Code 解析，不经过模型。原来的键会被静默忽略，只在会话 debug 日志里留一条 WARN，`claude plugin validate` 不报。poteto-mode 要求每次派 delegate 都放后台。2026-11-06 对照实测：主会话明确要求前台运行时，上游原版在前台跑完才返回，打补丁后强制转后台。代价：Claude Code 不允许 agent teams 的进程内 teammate 派 `background: true` 的 agent，pstack 本身不用 agent teams |
| `0004-generic-harness-adapter` | 把 `docs/harness/claude-code.md` 的映射表扩成 `docs/harness/agents.md`，分出 Claude Code、Pi、OMP 三节；`claude-code.md` 只留一个指向它的兼容指针，所有 skill 和 README 里的 adapter 链接改到新文件 | adapter 是模型运行时读的文档，上游只有 Claude Code 一版。Pi 和 OMP 用同一套工具名，但入口、agent 发现和模型角色不同；把差异集中在一个文件里，同步上游后仍只需要维护这一处。Cursor 用原生树，不读这份 adapter |

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
./jstack sync             # pstack（两棵树）、spec 都跟 main（flow 没有上游，跳过）
./jstack sync spec        # 只同步 spec
./jstack sync pstack 2776ddd2355d6d6c8747d3964600f28daf62f049   # 指定 ref：tag、分支或完整提交号
git diff -- upstream/     # 看上游改了什么
./jstack check
```

`pstack` 和 `pstack-cursor` 是同一个上游仓库的两棵子树，可以分别同步；要停在同一个提交，就对两个 key 各传一次同样的完整提交号。只想同步 Cursor 原生树时用 `./jstack sync pstack-cursor`。

`ref` 要用 tag、分支名或**完整**提交号。git 的 `fetch` 不接受短提交号，`./jstack sync pstack 2776ddd` 会报 `couldn't find remote ref`。

不传 ref 时跟 `main`，锁文件会更新到上游最新的 main。要停在某个提交，就把完整提交号传给 `sync`。

`check` 检查这些内容：

1. 每个 `plugins/<插件>` 是否等于构建结果（防手改），包括 `pstack-cursor`
2. 每棵 `upstream/<树>` 的内容哈希是否等于锁文件里 `tree` 字段记录的（防手改副本；flow 没有上游，跳过）
3. 各插件脚本里有没有写死的 Cursor 路径
4. skill 和 agent 的 frontmatter 里有没有 Claude Code 不认识的键
5. skill 里通过 Skill 工具调用的 skill 是否都收进了插件
6. spec/flow 的 Cursor manifest 是否和 Claude manifest 同名、同版本、同样的 skill 列表
7. `plugins/pstack-cursor` 是否是 Cursor 插件 `pstack`，skills 和 agents 是否齐全
8. 根目录 `package.json` 是否把三个插件的 skills 都暴露给 Pi
9. `stages.md` 里的每个提供者是否在五种安装布局下都找得到：用 `plugins/` 产物在临时的假 HOME 里复制出本地 marketplace、Claude GitHub 缓存、OMP 缓存、Cursor 本地插件、Pi npm 包，从各自的 flow 副本运行 `locate.sh`，路径必须落在该布局自己的树里；再把一个提供者换成 `spec:no-such-skill`，`locate.sh` 必须失败并点名它
10. `claude plugin validate` 是否通过（marketplace 和全部插件）
11. 评测任务自检（`./jstack eval --selftest`）：每个任务的 check 在初始状态下失败、在参考解下通过

第 3、4、5 项专门查 adapter 管不到的地方：脚本和 frontmatter 都不经过模型，上游新引入的 Cursor 依赖在同步时就能发现；第 5 项查的是 spec 这种"只收一部分 skill"的插件有没有漏掉依赖。`claude plugin validate` 不查 frontmatter 键，也不查插件内部 skill 之间的调用关系。全部通过才提交。

### 跨 harness smoke

`check --smoke` 在静态检查之后，对**本机已安装**的 harness 各跑一遍 headless 链路；没安装的 harness 会打印跳过原因，不算失败。也可以单独运行：

```bash
./jstack smoke pi       # skill 目录、/skill:poteto-mode、route locate.sh、poteto-agent
./jstack smoke omp      # skill:// URI、隐藏入口按路径读、route、task 派发 poteto-agent
./jstack smoke cursor   # 调用 Cursor 自带 plugins-loader 检查三个插件和 route
./jstack smoke all      # 三个都跑（= ./jstack check --smoke）
```

Pi 和 OMP 的 smoke 会实际启动模型、消耗 token，需要网络；它们是验收测试，不是每次提交的默认门禁。Cursor 没有可脚本化的 headless agent CLI，smoke 只验证加载器解析结果和 `locate.sh`，交互部分按 `docs/testing/cursor.md` 手动做。

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

`./jstack eval` 衡量工作流本身。它把一批固定任务交给 headless 的 Claude Code，后者加载仓库里的 pstack、spec、flow，再看三件事：做成了没有、要人插手几次、花了多少。smoke 只证明调用链跑得通。改了工作流以后是变好还是变差，要靠评测回答。

每个任务在 `evals/tasks/<名字>/` 下，包括 `prompt.md`（原样作为第一条用户消息）、`check.sh`（判定是否完成）、`solution.patch` 或 `answer.md`（参考解），以及可选的 `seed/`。每个样本都有自己的工作目录 `<临时目录>/<随机>/tasknotes`：先复制 `evals/fixture/`，再叠加 `seed/`，然后 `git init` 并提交一次。路径里不出现 eval、test 这类词，被测 agent 不知道自己在被评测。

```bash
./jstack eval list                           # 列出任务
./jstack eval --selftest                     # 不调模型：初始状态 check 必须失败，参考解下必须通过（check 也跑这一项）
./jstack eval                                # 全部任务，各 1 个样本
./jstack eval --samples 3 --jobs 3           # 每个任务 3 个样本，3 个并发
./jstack eval --model <模型> --max-nudges 1 --keep xs-empty-message
```

每轮结束后跑 `check.sh`，cwd 是工作目录，`ANSWER_FILE` 指向 agent 最后一条回复。check 没通过，runner 就用 `--resume` 发一条固定的催促消息："我现在不在电脑前，回答不了问题。需要决定的地方按你推荐的方案处理，把这件事做完。"每个样本最多催 `--max-nudges` 次，默认 2 次。每轮的时限是 `JSTACK_EVAL_TIMEOUT` 秒，默认 1800。超时的样本直接判失败，不再催促。评测是测量，任务失败不影响退出码，只有参数错误或缺少依赖才非 0。

每个样本记一行 JSON，字段如下：

| 字段 | 含义 |
|---|---|
| `pass` | 最终 check 是否通过 |
| `nudges` | **打断次数**，等于实际发出的催促次数。agent 每停下一次（提问、等确认，或自认为做完但 check 不通过）就会被催一次，对应真实使用中人要回来插手一次。0 表示一次做完 |
| `rounds` | 跑了几轮 claude，等于 `nudges + 1` |
| `turns` | 各轮 `num_turns` 之和 |
| `wall_s` | 样本从开始到结束的秒数，包括 check |
| `tokens` | input、output、cache read、cache creation 四类 token 之和，覆盖全部模型和子 agent |
| `premium_tokens` | 只算模型名匹配 `JSTACK_PREMIUM_MODELS` 的部分，默认正则 `(^|/)(claude|anthropic)|opus`。两层模型（#11）以后会换成配置 |
| `cost_usd` | Claude Code 报告的费用 |
| `route` / `poteto` | 主会话有没有调 `route` skill，有没有进入 poteto-mode（调 skill 或读它的 `SKILL.md`） |
| `subagents` | 主会话派出的 `Agent` / `Task` 次数 |
| `timed_out` / `error` | 是否超时；某轮没有 `result` 事件或 `result` 报错时，`error` 写明是哪一轮、什么错。出错的样本不等于工作流退化，先看 `error` |
| `model` / `commit` | init 事件里的模型；仓库提交号，工作区有改动时带 `-dirty` |

`--resume` 之后，`result` 事件里的 `modelUsage` 和 `total_cost_usd` 是整个会话的累计值，而 `num_turns` 只算本轮（2026-11-07 实测）。所以 runner 按轮取 token 和费用的增量，不会重复计算。

隔离方式：

- `env -i` 只传 `HOME`、`USER`、`PATH`、`LANG`、`LC_ALL`、`TMPDIR`、`SHELL`。不这样做的话，claude 会继承宿主（桌面 App、外层 Claude 会话）的变量，报 "Not logged in"
- `--plugin-dir` 从仓库的 `plugins/` 加载三个插件，同时在 `--settings` 里关掉已安装的 `pstack@jstack`、`spec@jstack`、`flow@jstack`。测的是当前工作区，不是已安装版本
- `disableAllHooks: true` 关掉全部 hooks。issue #12 给 flow 加自带的 hook 时，要改成只关用户 hooks，否则评测量不到那个 hook
- `--strict-mcp-config` 不加载任何 MCP，被测 agent 写不进 gbrain 这类用户记忆
- 没有隔离的部分：用户级 `~/.claude/CLAUDE.md` 和 `~/.claude/rules/`（包括 `/pstack:setup-pstack` 写的模型角色表）、其他已安装的插件、用户 skills 仍然会加载；会话记录写进 `~/.claude/projects/`。基线要在同一台机器、同一套用户配置下对比

产物：

- `evals/results.jsonl`：每个样本一行，只追加，和代码一起提交，当作基线
- `evals/reports/<日期>.md`：每次运行追加一节，包括 commit、model、样本数、max-nudges，以及按任务汇总的表。这一节同时打印到终端
- `.scratch/evals/<run_id>/<任务>-<n>/`：原始材料，不提交。包括每轮的 `round-<k>.jsonl` 和 `.err`、`answer-<k>.txt`、`check-<k>.txt`、最终的 `diff.patch`、`record.json`。工作目录默认跑完就删，加 `--keep` 会保留并打印路径

下面这些改动必须先跑 `./jstack eval`，再和 `evals/results.jsonl` 里最近一次同模型的基线对比：

- 改 `src/flow`
- 增删或修改 `patches/` 下的补丁，包括 adapter `docs/harness/agents.md`
- 同步上游（`./jstack sync`）
- 改模型配置（模型角色表、默认模型、两层模型）
- 改 hooks

退化要么修掉，要么在提交说明里写明理由。单个样本的噪声很大，判断退化至少用 `--samples 3`。差距小于同一提交多次运行之间的波动时，不算退化。改了 `evals/` 本身（runner、任务、fixture）以后，旧基线就不能直接比了，要先重跑一份新基线。

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

- pstack © Lauren Tan，MIT 许可，原文见 `plugins/pstack/LICENSE`。Claude Code 树由 cursor/plugins 官方生成。
- spec © Matt Pocock，MIT 许可，原文见 `plugins/spec/LICENSE`。
- pstack 补丁 0001 改编自 backnotprop/pstack（MIT）。
