# Keel managed 工作流包

`managed-export` 支持两种固定包：

- 无 `--ticket-id`：JT-01 只读调查包；
- `--ticket-id`：JT-02C XS/S 单 ticket 工程包。

```bash
./jstack managed-export > /tmp/jstack-investigation.json
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

当前是影子模式：不自动批准、不修改源码、不调用 shell、不部署；不运行完整 L/XL/pstack/land/archive 路线。现有交互式 route、must-stop 与插件安装行为保持原有语义。模型和凭据由 Keel 的运行环境明确配置，不由项目包指定。

验证：`python3 tests/managed-export.py` 的 7 项确定性测试已加入 `./jstack check`。真实模型运行由 Keel 的单独验收承担；缺推理 CLI 的静态检查不等于真实模型验收。

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

验证：`python3 tests/managed-export.py` 覆盖调查包、ticket 四阶段、完整来源清单、
可选 ticket 正文、`branch_ready` / `pr_ready` 两种完成目标、摘要稳定性、缺
provider/缺 profile/非法 size 与内容变化。
