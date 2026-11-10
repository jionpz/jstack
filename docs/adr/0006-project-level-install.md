# 项目级接入与两级配置：仓库自带安装，配置按作用域分层

Claude Code 有 `--scope project`，其余 harness 只有用户级安装；四个 harness 的安装入口、版本和门禁能力都不对等。需求方（wmstsla）为了在业务仓里接入 jstack，只能自写同步脚本、平铺 69 个 skill、给仓库规则开豁免。同时 ADR-0003 要求"角色到层级只有一份配置"，实现却按 harness 散成三个文件。我们把项目级安装定为一等公民，并把配置分成用户级和仓库级两层。

## 决定

### 1. 项目级是一等公民

一台新机器、一个新仓库，一条命令完成接入，不要求先有用户级安装：

```bash
./jstack install --all --scope project [--repo <path>]
```

`--all` 探测本机已装的 harness，逐个用其原生机制接入；`--scope user` 保留原语义。项目级安装的产物全部落在仓库内，可以提交、可以审计。

### 2. vendor 布局：插件树进仓库，只链入口

```
<repo>/.jstack/
├── config.json          # 仓库级配置
├── lock.json            # 安装锁
└── vendor/
    ├── marketplace.json # Claude Code marketplace 清单
    └── plugins/
        ├── pstack/
        ├── spec/
        └── flow/
```

- `vendor/plugins/` 保持完整的插件布局，不摊平 skill。路径解析、相对链接、adapter 引用都按插件目录原样工作。
- 只把 9 个入口 skill 链到各 harness 的项目 skill 目录：flow 的 `route`、`archive`，pstack 的 `poteto-mode`，spec 的 `grill-with-docs`、`to-spec`、`to-tickets`、`wayfinder`、`handoff`、`setup-matt-pocock-skills`。其余 skill 由 `locate.sh` 按物理路径读取，不进入发现目录。
- 发现目录按实测：Claude Code 用 `.claude/skills`；Pi、OMP、Codex 和 Cursor 共用 `.agents/skills`（Pi 和 OMP 按项目向上查找，Codex 项目根实测可读，Cursor 应用内置读取）。链接用相对路径，仓库搬走也有效。旧安装留在 `.cursor/skills` 的 jstack 软链会在 install 时清理；`.agents` 里已有的同名入口视为用户配置，install 保留并跳过，不覆盖。
- Claude Code 不注册 marketplace：入口 skill 链进 `.claude/skills`，`poteto-agent`、`comment-sicko` 复制到 `.claude/agents`，flow 的三个 hook 写进项目 `.claude/settings.json`，命令用 `${CLAUDE_PROJECT_DIR}` 指向 vendor。
- Cursor 项目级同样只链入口：flow 的三个 hook 写进项目 `.cursor/hooks.json`（Cursor 原生事件与输出协议），命令用 `${CURSOR_PROJECT_DIR}` 指向 vendor。

### 3. lock：安装可核查

`<repo>/.jstack/lock.json` 记录让安装可复现所需的最小事实：

```json
{
  "version": 1,
  "jstack":  { "version": "0.1.0", "commit": "<jstack 仓库 commit>" },
  "vendor":  { "tree": "<vendor 目录内容哈希（路径 + 内容）>" },
  "upstream": { "pstack": "<commit>", "spec": "<commit>" },
  "plugins": { "pstack": { "version": "<版本>" }, "spec": { "version": "<版本>" }, "flow": { "version": "<版本>" } },
  "harnesses": {
    "claude-code": { "scope": "project", "records": [".claude/skills/route", ".claude/agents/poteto-agent.md", "..."] },
    "pi": { "scope": "project", "records": [".agents/skills/route", "..."] }
  }
}
```

`./jstack doctor` 回答"每个 harness × 作用域装的是哪个版本、在哪里、来自哪棵树"，并核对 vendor 树哈希、插件版本和 lock 里记录的入口路径；不一致时报警。`install` 是唯一写 lock 的命令。

### 4. 两级配置，单一来源

| 层 | 文件 | 只放 | 不放 |
|---|---|---|---|
| 用户级 | `~/.jstack/config.json` | 跨仓库不变项：模型分层（premium / bulk / 角色覆盖）、预算与并发上限、通知字段（留给 #13） | 任何仓库相关内容 |
| 仓库级 | `<repo>/.jstack/config.json` | 随仓库变化项：tracker、领域文档位置、must-stop 追加、阶段表文件、验证命令 | 模型名、provider、凭据 |

- 格式统一为 JSON：`jq` 已是运行时依赖，不引入 YAML 解析器。
- 读取顺序：仓库级覆盖用户级；缺省值写在字段表里。仓库根由 `.jstack/config.json` 向上发现，`JSTACK_REPO` 可覆盖（测试用）。
- 字段表是 `docs/agents/jstack-config.md`，每个字段写明归属、默认值和读取方。
- **模型名只出现在用户级**。仓库级配置里出现 `models` 视为错误，`./jstack check` 拒绝，避免把数据流向写进业务仓库。
- **阶段表只有一个覆盖机制**：`stages_file` 指向一份同格式的表，整表替换。按阶段合并 provider 的写法被否——同一种需求两套机制，还要处理"覆盖后阶段的产出与门禁从哪来"的歧义；整表文件共用同一份解析器和校验，换提供者、加阶段、删阶段都只改一个文件。route 生成路线时丢掉表里不存在的阶段。
- 现有 `~/.config/jstack/models.json` 是过渡形态：`./jstack models` 在新文件不存在时自动迁移并备份旧文件，写入一律落到 `~/.jstack/config.json` 的 `models` 段（#24 已落地，旧路径保留只读兼容一个版本周期）。

### 5. 不新建第五套安装器

全部扩展 `./jstack` 子命令（install / doctor），底层仍用各 harness 的原生机制：Claude Code 用户级用 plugin marketplace、项目级用 skill 目录与 settings hooks，Pi 用 package 或 `.agents/skills`，OMP 用 plugin 或 `.agents/skills`，Cursor 用本地插件目录复制或 `.agents/skills`。jstack 只负责编排、放置 vendor、写 lock 和核对。

### 6. 门禁可降级，不可静默

flow 的三个 hook（阶段注入、Stop 证据、must-stop guard）目前有 Claude Code 和 Cursor 两套实现。Cursor 用自己的 hooks 配置（`.cursor-plugin/plugin.json` 声明 `hooks/hooks.cursor.json`，项目级写 `.cursor/hooks.json`）承载同样三件事：`beforeShellExecution` 对应 guard 并支持 `ask`，`beforeSubmitPrompt` 对应阶段提示，`stop` 对应验证门禁；Cursor 的 `stop` 输入没有最后一条回复，标了 `ask` 时只能直接放行。其余 harness 按 #28 的调研结果落地能承载的部分；承载不了的写进 adapter 的降级说明，并由 route 在收尾报告里点名"本次跳过了哪些门禁"。仓库级 `must_stop` 追加项在所有 harness 上都是**必须停**清单的一部分，即使该 harness 没有 guard 脚本，route 也必须自己识别。

### 7. 模型变更仍是数据流向变更

`install` 和 `doctor` 永不修改模型映射；只有 `./jstack models apply` 写各 harness 的模型配置，且按全局红线在落地前取得用户确认（ADR-0003 的 Consequences 不变）。

## 字段表（摘要，完整版见 docs/agents/jstack-config.md）

| 定制点 | 归宿 |
|---|---|
| tracker 类型 / 本地目录 / 标签 | 仓库级 `tracker` |
| 领域文档：GLOSSARY、ADR、约定库位置 | 仓库级 `domain_docs` |
| must-stop 追加项与新增命令模式 | 仓库级 `must_stop[]` |
| 阶段表（整表替换：换提供者、加阶段、删阶段） | 仓库级 `stages_file` |
| 项目验证命令 | 仓库级 `verify` |
| 模型分层与角色映射 | 用户级 `models` |
| 预算 / 并发上限 | 用户级 `budget` |
| 通知渠道（预留） | 用户级 `notifications` |
| 各 harness 的模型规则文件（`~/.claude/rules/pstack-models.md`、`~/.cursor/rules/pstack-models.mdc`、Pi/OMP rules） | 由用户级 `models` 生成，不单独维护 |
| `docs/agents/*.md`、`CLAUDE.md` 的 `## Agent skills` | 保留为 spec 上游可读的 prose；jstack 脚本以仓库级配置为准，`doctor` 报告两者不一致 |

## 待验证事实

实现前必须实测，结果回填本 ADR 或对应 ticket：

| # | 事实 | 谁验证 |
|---|---|---|
| F1 | Claude Code `extraKnownMarketplaces` 是否接受相对 `directory` source，且项目 `.claude/settings.json` 单独声明即可生效（不依赖用户级 marketplace） | #26 实测后不采用：Claude 项目级走 `.claude/skills` 软链 + `.claude/settings.json` hooks，不注册 marketplace |
| F2 | `claude plugin marketplace add --scope project` 是否只在首次注册时生效；已有用户级 marketplace 时如何改写为项目级 | #26 实测后不采用：项目 settings 的 path 会被写成绝对路径，仓库不可移植 |
| F3 | Pi 的项目 skill 目录（`.agents/skills`、`.pi/skills` 或其它）与软链跟随行为 | #26 已实测：Pi 从 cwd 及祖先目录发现 `.agents/skills`，用户级 `~/.agents/skills` 单独算；软链按物理路径跟随，`locate.sh` 已验证 |
| F4 | OMP 的项目 skill 目录与软链行为 | #26 已实测：OMP 按 cwd 向上找 `.agents/skills`，也认 `.omp/skills`；项目级与 Pi 共用 `.agents/skills` |
| F5 | Cursor 项目 `.cursor/skills` 是否接受指向仓库内的符号链接（已知本地插件目录拒绝 `~/.cursor/plugins/local` 之外的链接） | #26 部分实测：Cursor 应用内置 `.cursor/skills` 扫描；软链的真机加载仍需手动验证（`smoke cursor` 只覆盖本地插件加载器） |
| F6 | Pi extension / OMP hook 能否承载阶段注入、Stop 证据检查、命令 guard 中的哪些 | #28 |
| F7 | Cursor 的 hooks（若存在）事件模型能否承载 guard / Stop；不能时如何降级 | #27 已实测：Cursor 3.27 有完整 hooks 运行时。插件清单可指向 Cursor 原生配置；`beforeShellExecution` 的 `ask` 会弹确认（`preToolUse` 的 `ask` 不执行，降级为 `deny`），`stop` 输出 `followup_message`，`beforeSubmitPrompt` 输出 `additional_context`。`stop` 输入没有最后一条回复，`ask` 只能无条件放行。项目级写 `.cursor/hooks.json` |
| F8 | 四个 harness 同时存在用户级与项目级安装时的优先级与去重规则 | #25 |
| F9 | Cursor 是否读取项目 `.agents/skills` | 2026-11-10 从 Cursor 应用 bundle 实测：扫描列表包含 `.agents/skills`、`.cursor/skills`、`.claude/skills`、`.codex/skills`；项目级入口统一放 `.agents/skills`，旧 `.cursor/skills` 软链由 install 清理 |

## 被否方案

- **每个 harness 一份配置**（现状）：ADR-0003 的单一来源落不了地，改一次模型要改三处。
- **YAML 配置**：多一个解析器和一类缩进错误，收益只是可读性；JSON 已够。
- **把插件树复制进每个 harness 的 skill 目录**：69 个 skill 淹没仓库自有 skill（wmstsla 的实际问题），且版本漂移不可见。
- **只把 skill 目录软链进用户级目录**：项目级就依赖用户级，违背第 1 条。
- **在 jstack 里再写一套插件加载逻辑**：与各 harness 原生更新机制冲突，等于第五套安装器。

## Consequences

- #22（locate 物理路径）、#23（仓库级配置读取层）、#24（用户级配置与四 harness 生成器）、#25（doctor）、#26（统一安装与 vendor）、#27（Cursor 门禁）、#28（Pi/OMP 门禁）按此 ADR 实现；#29（合并 pstack 双树）在它们全部关闭后进行。
- `./jstack install --scope project` 成为新机器接入的推荐路径；README 与安装文档改写。
- `./jstack check` 增加配置 schema、lock 一致性和软链布局的校验项。
- 业务仓库不再需要自写同步脚本或给通用规则开豁免（wmstsla PR #1117 的做法可以撤掉）。
- 仓库级配置缺省时行为与今天完全一致；升级不强制任何仓库新增文件。
