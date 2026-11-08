# jstack config: 用户级与仓库级字段表

字段表来自 [ADR-0006](../adr/0006-project-level-install.md)。本页是实现依据：每个字段写明归属、类型、默认值和读取方。字段之外的键一律忽略（向前兼容）；`./jstack check` 对禁用键和类型错误报错。

两级文件：

| 层 | 路径 | 内容 |
|---|---|---|
| 用户级 | `~/.jstack/config.json` | 跨仓库不变项（模型、预算、通知预留） |
| 仓库级 | `<repo>/.jstack/config.json` | 随仓库变化项（tracker、文档位置、must-stop、阶段表、验证命令） |

> 实现状态：**仓库级**字段（`tracker`、`domain_docs`、`must_stop`、`stages_file`、`verify`）自 #23 起由 flow 的 `lib.sh` / `stage.sh` / `locate.sh` / `guard.sh` / `prompt.sh` 读取；**用户级**字段自 #24 起由 `./jstack models` 读写 `~/.jstack/config.json`，并生成四个 harness 的模型规则文件。旧 `~/.config/jstack/models.json` 在第一次运行 `models` 时自动迁移并备份。

## 解析规则

- 仓库根：从当前目录向上找第一个含 `.jstack/config.json` 的目录；找不到再找 `.git`，以它为仓库根。`JSTACK_REPO` 环境变量优先（测试与 CI 用）。
- 用户级路径：`$JSTACK_USER_CONFIG`，默认 `~/.jstack/config.json`。旧路径 `~/.config/jstack/models.json` 在新文件不存在时自动迁移（`harnesses` 段改名为 `models`，`budget` 原样保留），旧文件备份为 `models.json.bak-migrate-<时间>` 后保留；新文件存在后不再读旧文件。
- 合并：仓库级覆盖用户级；数组字段整体覆盖，不做拼接。缺省值见各表。
- 读取失败（JSON 非法、类型错误）：`./jstack check` 报错；flow hooks 在每轮提示里打一行醒目警告，guard 继续只按内置清单拦截。降级是显式的——用户每轮都能看到"仓库级 must-stop 追加项未生效"，修好后自动恢复。`./jstack doctor` 只核对安装矩阵与 lock，不读仓库级配置。

## 用户级 `~/.jstack/config.json`

| 字段 | 类型 | 默认 | 读取方 | 说明 |
|---|---|---|---|---|
| `models.<harness>.premium` | string | 无（必填才有分层） | `jstack models apply/status` | 高级模型 id，可带 `[1m]` 与 `:effort` 后缀；`<harness>` 取 `claude-code`、`cursor`、`omp`、`pi` |
| `models.<harness>.bulk` | string[2] | 无 | 同上 | 两个无限模型；`bulk[0]` 给 `sonnet`/判断降级，`bulk[1]` 给 `haiku`/`SMALL_FAST` |
| `models.<harness>.roles` | object | pstack 的 17 行角色表 | 同上 | 角色 → `premium` \| `bulk` \| `bulk0` \| `bulk1` 的覆盖，只写要改的行；值可以是逗号分隔的字符串或数组，`bulk` 等同 `bulk0` |
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
| `domain_docs.glossary` | string | `GLOSSARY.md` | `flow:archive`、`spec:domain-modeling` | 领域词表位置 |
| `domain_docs.adr` | string | `docs/adr` | 同上 | ADR 目录 |
| `domain_docs.conventions` | string | `docs/agents/conventions` | `flow:archive`、poteto-mode 的委派 | 项目约定库；缺目录时归档阶段跳过并说明 |
| `must_stop` | `{action, hook?, regex?}[]` | `[]` | `route`、`prompt.sh`、`guard.sh` | 追加项。`action` 是给人看的一句话；带 `regex`（ERE）的条目由 guard 拦截，`hook` 是稳定标识，便于 reason 和日志引用。没有 `regex` 的条目只能靠 route 自己识别 |
| `stages_file` | string \| null | `null` | `stage.sh`、`locate.sh`、`prompt.sh`、`route` | 整表替换的路径，相对仓库根；表格格式与插件的 `stages.md` 完全相同。必须含 `execute`，至少要有一个阶段。route 生成路线时丢掉表里没有的阶段 |
| `verify.command` | string \| null | `null` | `prompt.sh`（注入提示）、`route`、`flow:archive` | 项目的验证命令；提供后 verify 阶段的证据默认来自它 |
| `verify.timeout_s` | number | `600` | `route` | 验证命令超时 |

禁用键（出现即 `./jstack check` 报错）：

- `models`、`provider`、`api_key` 一类：模型与凭据只在用户级。
- `install`、`scope`：安装参数属于命令行，不写进配置。

## 与现有文件的关系

| 文件 | 关系 |
|---|---|
| `docs/agents/issue-tracker.md` | 面向 spec 上游的 prose，保留。jstack 脚本读仓库级 `tracker`；两者矛盾时以配置为准（doctor 不检查这层） |
| `docs/agents/domain.md` | 保留；`domain_docs.*` 路径与它描述的位置应一致 |
| `CLAUDE.md` 的 `## Agent skills` 段 | 保留为入口说明；内容应与 `tracker` / `docs` 一致（doctor 只核对安装矩阵，不读这段） |
| `~/.claude/rules/pstack-models.md`、`~/.cursor/rules/pstack-models.mdc`、`~/.omp/agent/rules/pstack-models.md`、`~/.omp/agent/config.yml` 的 `modelRoles` 块、`~/.pi/agent/AGENTS.md` 的角色表块 | 全部由用户级 `models` 生成，禁止手改；`./jstack models apply` 是唯一写入方。Pi/OMP 的共享文件只改 `jstack:models` 标记块，块外不碰；首次写入前确认（`--yes` 跳过），写前备份 |
| `src/flow/skills/route/stages.md`、`must-stop.md` | 插件内置的默认值；仓库级 `stages_file` 整表替换阶段表，`must_stop` 在读取时追加，都不改插件文件 |
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
  "domain_docs": { "glossary": "docs/GLOSSARY.md", "adr": "docs/adr" },
  "must_stop": [
    {
      "action": "运行 ./deploy.sh、kubectl apply 或 docker push",
      "hook": "deploy",
      "regex": "(^|[[:space:]/])(\\./deploy\\.sh|kubectl[[:space:]]+apply|docker[[:space:]]+push)([[:space:]]|$)"
    }
  ],
  "stages_file": ".jstack/stages.md",
  "verify": { "command": "./scripts/verify.sh", "timeout_s": 900 }
}
```

## 校验（`./jstack check`）

1. 两级配置 JSON 合法、字段类型正确。
2. 仓库级不含禁用键。
3. `stages_file` 存在、能解析出至少一个阶段、含 `execute`；表里每个 provider 都能被 `locate.sh` 找到。
4. `must_stop[]` 每条有非空 `action`；带 `regex` 的条目是合法 ERE（`grep -E` 能编译）。
5. 安装了项目级 vendor 时，`./jstack doctor` 核对 `lock.json` 与 vendor 树、插件版本一致（`check` 不读 vendor）。
