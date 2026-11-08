# jstack config: 用户级与仓库级字段表

字段表来自 [ADR-0006](../adr/0006-project-level-install.md)。本页是实现依据：每个字段写明归属、类型、默认值和读取方。字段之外的键一律忽略；`./jstack check` 对未知键报警，对禁用键报错。

两级文件：

| 层 | 路径 | 内容 |
|---|---|---|
| 用户级 | `~/.jstack/config.json` | 跨仓库不变项（模型、预算、通知预留） |
| 仓库级 | `<repo>/.jstack/config.json` | 随仓库变化项（tracker、文档位置、must-stop、阶段表、验证命令） |

> 实现状态：本表为目标形态，按 ticket 逐项落地（#23 仓库级读取层、#24 用户级与迁移、#26 安装）。落地前 `./jstack models` 仍读写 `~/.config/jstack/models.json`，但字段名与下表一致，迁移只换文件位置。

## 解析规则

- 仓库根：从当前目录向上找第一个含 `.jstack/config.json` 的目录；找不到再找 `.git`，以它为仓库根。`JSTACK_REPO` 环境变量优先（测试与 CI 用）。
- 用户级路径：`$JSTACK_USER_CONFIG`，默认 `~/.jstack/config.json`。旧路径 `~/.config/jstack/models.json` 只读兼容，`models` 段等价于用户级 `models`。
- 合并：仓库级覆盖用户级；数组字段整体覆盖，不做拼接。缺省值见各表。
- 读取失败（JSON 非法、类型错误）：`./jstack check` 和 `./jstack doctor` 报错；flow hooks 在每轮提示里打一行醒目警告，guard 继续只按内置清单拦截。降级是显式的——用户每轮都能看到"仓库级 must-stop 追加项未生效"，修好后自动恢复。

## 用户级 `~/.jstack/config.json`

| 字段 | 类型 | 默认 | 读取方 | 说明 |
|---|---|---|---|---|
| `models.<harness>.premium` | string | 无（必填才有分层） | `jstack models apply/status` | 高级模型 id，可带 `[1m]` 与 `:effort` 后缀；`<harness>` 取 `claude-code`、`cursor`、`omp`、`pi` |
| `models.<harness>.bulk` | string[2] | 无 | 同上 | 两个无限模型；`bulk[0]` 给 `sonnet`/判断降级，`bulk[1]` 给 `haiku`/`SMALL_FAST` |
| `models.<harness>.roles` | object | pstack 的 17 行角色表 | 同上 | 角色 → `premium` \| `bulk` \| `bulk0` \| `bulk1` 的覆盖，只写要改的行 |
| `budget.premium_daily_tokens` | number \| null | `null` | `jstack models status/apply` | premium 当日 token 上限；超限时判断类角色降级到 `bulk0` |
| `budget.premium_concurrency` | number \| null | `null` | 同上 | premium 并发上限（AnyRouter 这类不能并发的 provider 用） |
| `notifications.channel` | string \| null | `null` | 预留（#13） | 只占位，不实现；实现前写入即报"未支持" |
| `notifications.target` | string \| null | `null` | 预留（#13） | 同上 |

`models` 里出现未知 harness 名不算错误（向前兼容），`apply` 遇到未实现的 harness 只打印角色表。

## 仓库级 `<repo>/.jstack/config.json`

| 字段 | 类型 | 默认 | 读取方 | 说明 |
|---|---|---|---|---|
| `tracker.type` | `"github"` \| `"local"` | 有 remote 时 `github`，否则 `local` | `route`、`flow:archive`、`stage.sh` | 任务账本类型；与 `docs/agents/issue-tracker.md` 的描述应一致 |
| `tracker.local_dir` | string | `docs/agents/tickets` | `flow:archive` | `local` 时的 ticket 目录 |
| `tracker.label` | string | `ready-for-agent` | `flow:archive`、`route` | 可派给 agent 的标签 |
| `docs.glossary` | string | `GLOSSARY.md` | `flow:archive`、`spec:domain-modeling` | 领域词表位置 |
| `docs.adr` | string | `docs/adr` | 同上 | ADR 目录 |
| `docs.conventions` | string | `docs/agents/conventions` | `flow:archive`、poteto-mode 的委派 | 项目约定库；缺目录时归档阶段跳过并说明 |
| `must_stop.add` | `{action, hook?}[]` | `[]` | `route`、`prompt.sh` | 追加到必须停清单的人类可读条目；`hook` 与 `must_stop.patterns` 的 hook 名对应 |
| `must_stop.patterns` | `{hook, regex}[]` | `[]` | `guard.sh` | 追加命令模式，ERE，与插件 `must-stop.md` 的 patterns 同格式；hook 名不得覆盖内置条目，只能新增 |
| `stages.override.<stage>.providers` | string[] | 插件 `stages.md` | `locate.sh`、`route` | 替换某阶段的提供者，token 形如 `pstack:interrogate`；替换后必须能被 locate 找到 |
| `stages.skip` | string[] | `[]` | `route`、`stage.sh` | 从所有路线里移除这些阶段；`execute` 不可跳过 |
| `verify.command` | string \| null | `null` | `prompt.sh`（注入提示）、`route`、`flow:archive` | 项目的验证命令；提供后 verify 阶段的证据默认来自它 |
| `verify.timeout_s` | number | `600` | `route` | 验证命令超时 |

禁用键（出现即 `./jstack check` 报错）：

- `models`、`provider`、`api_key` 一类：模型与凭据只在用户级。
- `install`、`scope`：安装参数属于命令行，不写进配置。

## 与现有文件的关系

| 文件 | 关系 |
|---|---|
| `docs/agents/issue-tracker.md` | 面向 spec 上游的 prose，保留。jstack 脚本读仓库级 `tracker`；`doctor` 发现两者矛盾时报警（例如文档写 local、配置写 github） |
| `docs/agents/domain.md` | 保留；`docs.*` 路径与它描述的位置应一致 |
| `CLAUDE.md` 的 `## Agent skills` 段 | 保留为入口说明；内容应与 `tracker` / `docs` 一致，`doctor` 检查 |
| `~/.claude/rules/pstack-models.md`、`~/.cursor/rules/pstack-models.mdc`、`~/.pi/agent/AGENTS.md`、OMP 的 rules | 全部由用户级 `models` 生成，禁止手改；`./jstack models apply` 是唯一写入方 |
| `src/flow/skills/route/stages.md`、`must-stop.md` | 插件内置的默认值；仓库级 `stages` / `must_stop` 在读取时叠加，不改插件文件 |
| 业务仓库自己的 `AGENTS.md` | jstack 不读不写。项目级接入只动 `.jstack/`、生成的 harness 配置和入口链接，不往 `AGENTS.md` 里塞内容 |

## 示例

用户级：

```json
{
  "models": {
    "claude-code": {
      "premium": "anyrouter/claude-opus-5-5[1m]",
      "bulk": ["opencode-go/deepseek-v4.1-flash:max", "opencode-go/deepseek-v4.1-flash:xhigh"]
    }
  },
  "budget": { "premium_daily_tokens": null, "premium_concurrency": null }
}
```

仓库级：

```json
{
  "tracker": { "type": "local", "local_dir": "docs/agents/tickets" },
  "must_stop": {
    "add": [{ "action": "运行 ./deploy.sh 或 kubectl apply", "hook": "deploy" }],
    "patterns": [{ "hook": "deploy", "regex": "(^|[[:space:]/])(\\./deploy\\.sh|kubectl[[:space:]]+apply|docker[[:space:]]+push)([[:space:]]|$)" }]
  },
  "stages": { "override": { "review": { "providers": ["pstack:interrogate"] } } },
  "verify": { "command": "./scripts/verify.sh", "timeout_s": 900 }
}
```

## 校验（`./jstack check`）

1. 两级配置 JSON 合法、字段类型正确。
2. 仓库级不含禁用键。
3. `stages.override` 里的每个 provider 都能被 `locate.sh` 找到；`stages.skip` 不含 `execute`、`size`。
4. `must_stop.patterns` 每条是合法 ERE（`grep -E` 能编译）。
5. 安装了项目级 vendor 时，`lock.json` 与 vendor 树、插件版本一致。
