# 执行入口对比：#18

2026-11-09。用 `./jstack eval` 比较两个 execute 阶段提供者：旧的 `pstack:poteto-mode` 和 jstack 自己的精简执行入口 `flow:execute`。结论是**改**，并把 poteto-mode 保留为多 ticket / 多天工作的替代提供者。

## 方法

- 七道硬题：`m-route-store-guard`、`m-route-sort-policy`、`m-route-batch-clean`、`l-route-archive`、`m-route-stats`、`m-route-concurrent-add`、`l-route-recurring`，每题 3 个样本。
- 模型 `opencode-go/deepseek-v4.1-flash:xhigh`，`--max-nudges 2`，样本仓库按 `seed/CLAUDE.md` 从 `flow:route` 开始。
- 基线：`20261109-111555-29318`、`20261109-114354-4098`、`20261109-121342-21455`、`20261109-134003-12909`（execute 走 poteto-mode）。
- 对比组：`20261109-143615-26919`、`20261109-152552-18378`（execute 走 flow:execute）。
- 判定只看 check.sh 的功能检查；route / poteto / 子 agent / token 由 runner 记录。

## 瓶颈在哪

从一次 route + poteto 的 L 样本（`l-route-recurring-1`，单样本 3.97M token、1401 秒）看：

- 主会话 73 条 assistant 消息、约 158 KB 工具结果；四个子代理各 25–64 条消息、40–103 KB 工具结果。同样的题裸跑只有 33 条消息、18 KB。
- 每个子代理都会完整读取 `poteto-mode/SKILL.md`（22.3 KB ≈ 5.6k token）；主会话读 SKILL.md 13 次。playbooks 合计 77 KB。
- 成本主要来自三处：主会话长上下文 × 多轮重发；实现 + 审查 + 复核的子代理扇出；skill / playbook 的重复读取。不是某个具体 playbook 写错了。

## 改动

- 新增 `src/flow/skills/execute/SKILL.md`：主会话内完成 inspect → change → verify → 自审 diff → commit；默认不派子代理；保留 must-stop、证据记录和五段收尾需要的内容。
- `stages.md` 的 execute 一行改为 `` `flow:execute` `pstack:poteto-mode` ``：单任务或单 ticket 走 flow:execute；多张独立 ticket 或多天工程仍走 poteto-mode 的 Orchestrate / Multi-phase playbook。
- route 的 §5 handoff、execute 段、finish 说明和 Never 一节的提供者引用改为“execute 阶段的提供者”。

## 结果

单个样本均值；`tokens` 为单样本，非三样本合计。

| 任务 | poteto 通过/耗时/tokens/$ | flow:execute 通过/耗时/tokens/$ |
|---|---|---|
| m-route-store-guard | 3/3 · 288s · 1.56M · $1.23 | 3/3 · 145s · 0.89M · $0.69 |
| m-route-sort-policy | 3/3 · 349s · 2.11M · $1.66 | 3/3 · 166s · 0.94M · $0.77 |
| m-route-batch-clean | 3/3 · 427s · 3.38M · $2.61 | 3/3 · 268s · 1.82M · $1.11 |
| l-route-archive | 3/3 · 953s · 5.58M · $5.14 | 3/3 · 802s · 5.32M · $5.00 |
| m-route-stats | 3/3 · 365s · 2.54M · $1.82 | 3/3 · 172s · 0.90M · $0.66 |
| m-route-concurrent-add | 3/3 · 925s · 3.54M · $2.95 | 3/3 · 841s · 4.74M · $3.91 |
| l-route-recurring | 3/3 · 1410s · 5.50M · $7.93 | 3/3 · 1019s · 9.13M · $9.68 |
| **平均** | **21/21 · 674s · 3.46M · $3.33 · 1.5 子 agent** | **21/21 · 488s · 3.39M · $3.12 · 0.9 子 agent** |

两组都是 0 次催促。flow:execute 的第一次 `l-route-recurring` 跑出过 2/3 和 2 次催促，原因是 prompt 的日期校验范围有歧义（“没给 repeat 的还跟现在一样”被读成不带 repeat 时仍接受 2026-02-30）；澄清 prompt 后重跑 3/3、0 催促，上表用的是重跑结果。

## 结论

- **改**：flow:execute 的成功率不低于基线（21/21），打断次数不高于基线（0），耗时降 28%，费用降 6%，子 agent 从 1.5 降到 0.9；执行入口也不再依赖 pstack 的 Cursor 专属分支。
- 成本收益有限的原因：省下的是实现和复核的子代理，但 route 在 M 路径上仍会跑 review 阶段的 `pstack:interrogate`（L 题的 `l-route-recurring` 上出现 3–4 个审查子代理，token 反升 66%）。**下一个杠杆是 review 阶段，不是 execute 入口。**
- 保留 poteto-mode 作为多 ticket / 多天工作的提供者；只改阶段表一格即可切回。

## 限制

- 每题 3 个样本，比较的是“不更差”，不是统计显著的更好。
- 题目都是自包含的 M/L 任务；spec 阶段（grill / to-spec / to-tickets）仍未被 eval 覆盖。
- review 阶段的 interrogate 是否应默认运行，需要单独一轮评测再定。
