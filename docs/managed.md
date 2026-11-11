# Keel managed 工作流包

`managed-export` 支持三种固定包：

- 无 `--ticket-id`：JT-01 只读调查包；
- `--route`：JT-04 XS/S/M/L/XL 路线与多 ticket 规划包；
- `--ticket-id`：JT-02C XS/S 单 ticket 工程包。

```bash
./jstack managed-export > /tmp/jstack-investigation.json
./jstack managed-export --route > /tmp/jstack-route.json
./jstack managed-export --route --completion-target branch_ready \
  > /tmp/jstack-route-branch-ready.json
./jstack managed-export --ticket-id JT-101 --ticket-title "修复登录回跳" \
  > /tmp/jstack-ticket.json
./jstack managed-export --ticket-id JT-101 --ticket-title "修复登录回跳" \
  --ticket-description "复现步骤、验收标准与边界条件" > /tmp/jstack-ticket.json
./jstack managed-export --ticket-id JT-101 --ticket-title "修复登录回跳" \
  --completion-target pr_ready > /tmp/jstack-ticket-pr-ready.json
```

## 调查包

导出器读取 `src/flow/skills/route/SKILL.md` 的 Question 路线、阶段表和 `src/managed/investigate.md`，确认只走 execute 后输出 `protocol_version=1.0` 的包。`--root` 只用于显式选择导出来源和测试；不运行该目录的脚本。缺文件、空文件、越界软链或不兼容路线均拒绝。

Keel 接收并保存完整内容和摘要；旧任务不受本地文件或后续升级影响。`source_commit` 记录导出时 HEAD 作为补充来源信息，工作区新增/修改内容的确切身份以 Keel 内容摘要为准。

调查模型没有原生工具，通过 `read_files` 向 Keel 请求相对路径。所有需要人工的问题以 `waiting_decision` 提案提交；Keel 先运行天问并保存建议，再接受真实用户答复。完成报告须引用已观察的路径和内容摘要。

调查包仍是影子模式：不自动批准、不修改源码、不调用 shell、不部署，也不运行完整
L/XL/pstack/land/archive 路线。现有交互式 route、must-stop 与插件安装行为保持原有
语义。模型和凭据由 Keel 的运行环境明确配置，不由项目包指定。

验证：`python3 tests/managed-export.py` 的确定性测试已加入 `./jstack check`。真实模型
运行由 Keel 的单独验收承担；缺推理 CLI 的静态检查不等于真实模型验收。

## route 工程包

`--route` 导出规划器而不是一张既定 ticket。包内 `route_rules` 固定给出五档规模：

| route_size | 图规模 | ticket 数 |
|---|---|---|
| XS | 一个单文件小改或已知 bug | 1 |
| S | 一个小 ticket，可涉及少量文件 | 1 |
| M | 一个模块或一个清晰行为 | 1..3 |
| L | 跨模块或多项功能 | 2..12 |
| XL | 超过一个会话能承载，或决策仍未明 | 2..20 |

`route_size` 只描述请求本身。图里的每张 ticket 必须继续拆到 `XS`、`S` 或 `M`，
不能把 `L` / `XL` 原样放进 ticket 图。`src/managed/plan.md` 定义规划约束：planner
输出一个 `JstackRoutePlan` JSON，每张 ticket 都有稳定的 `key` / `ticket_id`、单一
目标、验收项和仅限仓库相对路径的 `scope_paths`。`depends_on` 只列真正阻塞本 ticket
的节点；引用必须存在，图必须无环，独立 ticket 不能互相依赖。等待人工的 ticket 不
阻塞其他独立节点。Keel 校验通过后才提交这张图，并按依赖前沿推进。

managed route 不照搬交互式 route 的每档阶段差：五档都固定为
`execute → verify → review → land`，`route_rules[].stage_path` 和
`stage_templates` 都绑定这条安全路径。即使交互式 XS/S 默认省略 review，managed
写路径仍强制 review。四个阶段的 provider、门禁、tool profile、完整指令与
`content_digest` 都在包内，Keel 不从工作区临时读取最新 provider。

`archive_gate` 原样携带阶段表的 archive 门禁：ticket 只有证据齐全才能关闭；有未提交
工作的 worktree 不得删除；每条教训必须有去向。route 包只携带这道门禁文本，不包含
archive provider，实际关闭与清理仍由 Keel 的 archive 执行器负责。

route 包的 `content_digest` 覆盖除自身以外的完整包，包括五档规则、固定阶段模板、
规划说明、tool policy、must-stop、`archive_gate` 和 `sources`。`sources` 固定记录 9 个
来源（route、阶段表、planner、must-stop、tool policy 与四个阶段 provider）的路径、
SHA256 和字节数；任一内容变化都会同时改变对应来源摘要和包摘要。`source_commit`
记录导出基线，作为补充来源信息；任务运行时的准确内容身份以包摘要为准。缺文件、
空文件、越界软链、缺 archive gate、缺规模、缺 provider/profile 或内容被替换都会
拒绝导出。

route 的 `completion_target` 缺省为 `pr_ready`，可用 `--completion-target
branch_ready` 改为分支完成。与 ticket 模式一样，它只声明完成边界，不执行 push、PR
或 CI。

与单 ticket 模式的区别：

| | 单 ticket 包 | route 包 |
|---|---|---|
| 输入 | 一个显式 ticket，可带正文 | 一段工程请求，不接收 ticket 参数 |
| size | `XS` / `S` | `route_size` 为五档；图内 ticket 为 `XS/S/M` |
| 包形状 | `ticket` + 四个执行阶段 | `route_rules` + planner + 固定阶段模板 |
| 默认完成目标 | `branch_ready` | `pr_ready` |

## 单 ticket 工程包

`--ticket-id` 模式固定导出 `execute → verify → review → land`：

| 阶段 | provider | tool profile |
|---|---|---|
| execute | `flow:execute` | `developer` |
| verify | `pstack:principle-prove-it-works` | `verifier` |
| review | `flow:review` | `reviewer` |
| land | `pstack:poteto-mode/playbooks/opening-a-pr.md` | `releaser` |

交互式 XS/S route 默认不含 review；managed 写路径强制加入 review 安全门，这是
launcher 的安全覆盖，不声称与交互式 route 完全相同。

包会嵌入 route、阶段表、must-stop、四个 provider 的完整内容，读取
`tool-policy.json` 并生成 stage/profile/harness 映射及 `content_digest`。`sources`
记录每个固定来源的路径、SHA256 与字节数；包的 `content_digest` 覆盖完整包内容，
排除该字段本身。provider 文件缺失、为空、越界软链、stage 行缺 provider/profile、
tool profile 不存在或来源内容变化都会拒绝导出或改变摘要。

`completion_target` 缺省为 `branch_ready`，可用 `--completion-target pr_ready`
显式导出 managed 自动交付包。两者都只声明包期望的完成边界：导出器本身不执行
push、PR 或 CI；`pr_ready` 表示后续 Keel 网关必须创建真实 PR 并等待准确 head
SHA 的必需 check 通过。

`--ticket-description` 可选携带 1..20000 字符的 ticket 正文，缺省不写入
`ticket.description`，兼容既有包。

验证：`python3 tests/managed-export.py` 覆盖调查包、ticket 四阶段、route 五档与
展开上限、固定阶段模板、route 的 9 个来源摘要、archive gate、planner 说明嵌入、
可选 ticket 正文、`branch_ready` / `pr_ready` 两种完成目标、摘要稳定性、越界软链、
缺来源/缺 provider/缺 profile/非法 size 与内容变化。
