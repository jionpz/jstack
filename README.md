# jstack

jionpz 的 AI 工程工作流 marketplace。目前只有一个插件：原版 [pstack](https://github.com/cursor/plugins/tree/main/pstack)（Lauren Tan，MIT）的 Claude Code 版。内容锁定在上游某个提交，另外叠加了 jstack 自己的少量补丁。

## 安装

本机已经有这个目录时，一条命令即可：

```bash
~/mycode/jstack/jstack install
```

推到 GitHub 之后，在新机器上不需要 clone，用 Claude Code 自带的命令即可：

```bash
claude plugin marketplace add jionpz/jstack && claude plugin install pstack@jstack
```

装好之后在 Claude Code 里依次运行：

1. `/reload-plugins`，或者新开一个会话。
2. `/pstack:setup-pstack`：写入模型角色表 `~/.claude/rules/pstack-models.md`，只需要做一次。
3. `/pstack:poteto-mode <任务描述>`：主入口，它会按任务类型选对应的剧本。

`pstack@cursor-plugins` 以及其他 pstack 移植版都不要同时装。它们的命令都以 `/pstack:` 开头，会互相冲突，`./jstack install` 检测到时会拒绝安装。

运行时依赖：`bun`（poteto-mode 的 watch-pr 和 statechart 脚本）、`gh`（PR 和 CI 流程）、`rg`、`jq`。缺哪个，`install` 会提示。

## 为什么这样做

上游 `cursor/plugins` 已经官方维护一份 Claude Code 版：[`harness/pstack/claude-code`](https://github.com/cursor/plugins/tree/main/harness/pstack/claude-code)。它由上游脚本从 `pstack/` 生成，上游 CI 会检查 skill 里用到的每个 Cursor 名称在 adapter 映射表里都有对应的一行。凡是用到 Cursor 名称的 SKILL.md，都加了一句"先读 adapter"，由模型在运行时把 `Task`、`readonly`、模型名等映射成 Claude Code 的写法。

jstack 原样 vendor 这棵树，不再自己翻译一遍。下表是几种移植方式的对比：

| 做法 | 代表 | 取舍 |
|---|---|---|
| 运行时 adapter | 上游官方 | 由上游维护，跟进成本最低；代价是每个会话多读一份约 1.5k token 的映射表 |
| 构建期全量翻译 | michael-denyer/pstack-claude | 产物是原生 Claude Code 写法，但要维护上千行生成器和 99 条替换规则 |
| 镜像加手工改写 | backnotprop/pstack | 用 git 分支合并上游；改写全靠手工 |
| 深度 fork | ericlitman/open-pstack | 加了模型注册表和多 provider，离原版最远 |

没有选构建期翻译的原因：Cursor 术语是整句交织在一起的，例如 "a Task subagent with `subagent_type: generalPurpose` and `readonly: true` … default `grok-4.7-xhigh-fast`"。只替换其中一部分，会得到 Cursor 和 Claude Code 混杂的写法，模型仍然得读 adapter；要翻译完整，就会变成 michael-denyer 那样的长期维护负担。

从第三方移植版借鉴的是维护纪律：

- 锁定上游提交（michael-denyer 的 `upstream.json`）
- 上游原样副本和本地改动分开存放，每次同步留记录（backnotprop 的 `upstream` 分支和 `SYNC-LOG.md`）
- 改动要在真实的 Claude Code 里验证（open-pstack）

补丁只用来修 adapter 管不到的问题，主要是脚本和 frontmatter，因为它们不经过模型。

## 目录

```text
.claude-plugin/marketplace.json  marketplace 清单，名字是 jstack
upstream/pstack/                 上游原样副本（cursor/plugins 的 harness/pstack/claude-code），不要手改
patches/pstack/                  jstack 补丁，按文件名顺序应用
plugins/pstack/                  构建产物，等于 upstream 加 patches 再加版本戳，不要手改
upstream.lock.json               锁定的上游仓库、路径、提交和版本
SYNC-LOG.md                      上游同步记录
jstack                           维护脚本：install / sync / build / check
```

## 当前补丁

| 补丁 | 修了什么 | 为什么 adapter 管不到 |
|---|---|---|
| `0001-worktree-audit-claude-code-transcripts` | `worktree-audit.sh` 原来只在 `~/.cursor/projects/<slug>/agent-transcripts` 里找会话记录，现在改为在 `~/.claude/projects/<slug>` 里找，并且同时搜主仓库和 worktree 自己的目录 | 这是 shell 脚本，不经过模型。不修的话 `LAST_CHAT` 永远为空，已合并、但最近还有会话在用的 worktree 会被标成 `safe`，worktree-cleanup 剧本可能据此把它删掉。改编自 [backnotprop/pstack](https://github.com/backnotprop/pstack)（MIT） |
| `0002-adapter-transcript-slug` | adapter 原文说 slug 规则是"把 `/` 和 `.` 换成 `-`"，改成"把所有非字母数字字符换成 `-`" | 2026-11-06 在本机 `~/.claude/projects` 实测 32 个目录：新规则 32 个全对；原规则错了 7 个，都是路径里带 `_` 的。规则写错会让 `reflect`、`recall` 这类 skill 找不到会话记录 |
| `0003-poteto-agent-background-frontmatter` | `poteto-agent` 的 frontmatter 把 Cursor 的 `is_background: true` 改成 Claude Code 的 `background: true` | frontmatter 由 Claude Code 解析，不经过模型。原来的键会被静默忽略，只在会话 debug 日志里留一条 WARN，`claude plugin validate` 不报。poteto-mode 要求每次派 delegate 都放后台。2026-11-06 对照实测：主会话明确要求前台运行时，上游原版在前台跑完才返回，打补丁后强制转后台。代价：Claude Code 不允许 agent teams 的进程内 teammate 派 `background: true` 的 agent，pstack 本身不用 agent teams |

这几处问题都值得提给上游 `cursor/plugins`。上游修好之后，`sync` 时补丁会打不上，删掉对应补丁即可。

看过但没打补丁的：`poteto-mode` 的 `icon`、`color` 是 Cursor 界面用的字段，Claude Code 忽略，不影响行为。

## 维护

更新上游：

```bash
./jstack sync          # 默认跟 main；也可以传 tag 或提交号，例如 ./jstack sync 2776ddd
git diff -- upstream/  # 看上游改了什么
./jstack check
```

`check` 依次检查五件事：

1. `plugins/` 是否等于构建结果（防手改）
2. 锁文件和副本是否一致
3. 脚本里有没有写死的 Cursor 路径
4. skill 和 agent 的 frontmatter 里有没有 Claude Code 不认识的键
5. `claude plugin validate` 是否通过

第 3、4 项专门查 adapter 管不到的地方：脚本和 frontmatter 都不经过模型，上游新引入的 Cursor 依赖在同步时就能发现。`claude plugin validate` 不查 frontmatter 键。全部通过才提交。

补丁打不上，说明上游改了那一段。对照 `upstream/pstack` 重做补丁；如果上游已经修好，就直接删掉补丁。

新增补丁的步骤：在临时目录建 `a/` 和 `b/` 两份文件，只改 `b/`，然后：

```bash
git diff --no-index --src-prefix= --dst-prefix= a/<路径> b/<路径> > patches/pstack/NNNN-<说明>.patch
./jstack build && ./jstack check
```

版本号由 `build` 写成 `<上游版本>+jstack.<内容哈希>`，内容一变版本号就变。

本机的 marketplace 是从本地路径添加的，会话直接从 `plugins/pstack` 加载。Claude Code 在缓存里也复制了一份，但不读它（2026-11-06 用 `claude --debug-file` 看启动日志确认）。所以 `build` 之后，重开会话或运行 `/reload-plugins` 就生效。再跑一次 `./jstack install`，`claude plugin list` 里的版本号也会跟上。

其他机器从 GitHub 安装，插件复制进缓存，只有版本号变了才会更新。更新命令：`claude plugin marketplace update jstack && claude plugin update pstack@jstack`。

## 推广到团队项目

在业务项目的 `.claude/settings.json` 里加上下面的配置并提交。队友信任这个项目之后，Claude Code 会注册 jstack marketplace。如果仍提示未安装，每人运行一次 `claude plugin install pstack@jstack`。

```json
{
  "extraKnownMarketplaces": {
    "jstack": { "source": { "source": "github", "repo": "jionpz/jstack" } }
  },
  "enabledPlugins": { "pstack@jstack": true }
}
```

## 计划

- 把 Matt Pocock 的 skills（`grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`）作为第二个插件加进来，同样锁定上游提交。分工上，Matt 的 skills 只负责需求澄清和任务拆解，产出交给 pstack 执行；它的 `implement` 这类编排 skill 不收录，避免和 pstack 抢主编排。
- 可选：加一个 SessionStart 路由 hook，让工程类任务默认进入 poteto-mode。

## 致谢

- pstack © Lauren Tan，MIT 许可，原文见 `plugins/pstack/LICENSE`。Claude Code 树由 cursor/plugins 官方生成。
- 补丁 0001 改编自 backnotprop/pstack（MIT）。
