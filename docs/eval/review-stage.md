# review 阶段对比：#37

2026-11-09。用 `./jstack eval` 比较 review 阶段的默认行为：改动前 route 在每个 review 阶段跑 `pstack:interrogate`（arena 扇出 2 个对抗审查子代理），改动后默认跑 `flow:review`（主会话自审、修掉或驳回发现并记录证据），interrogate 只在设计有争议、改动碰 must-stop、或用户要求时运行。结论是**改**。

## 方法

- 七道硬题：`m-route-store-guard`、`m-route-sort-policy`、`m-route-batch-clean`、`l-route-archive`、`m-route-stats`、`m-route-concurrent-add`、`l-route-recurring`，每题 3 个样本。
- 模型 `opencode-go/deepseek-v4.1-flash:xhigh`，`--max-nudges 2`，样本仓库按 `seed/CLAUDE.md` 从 `flow:route` 开始。
- 基线：`20261109-143615-26919`、`20261109-152552-18378`（review 走 interrogate）。
- 对比组：`20261109-173027-20242`（六题）+ `20261109-181510-20200`（`l-route-archive` 重跑，原因见下）。
- 判定只看 check.sh 的功能检查；route / poteto / 子 agent / token 由 runner 记录。

## 改动

- 新增 `src/flow/skills/review/SKILL.md`：主会话内重读 diff、对照任务、修掉或驳回每个发现，用 `stage.sh evidence` 记录；不派子代理。
- `stages.md` 的 review 一行改为 `` `flow:review` `pstack:interrogate` `pstack:swarm` ``；route 的 review 段写清 interrogate 的触发条件（设计有争议、碰 must-stop、用户要求），swarm 只在门禁要求对争议设计做群体审查时运行。
- 顺带修了 #18 留下的 frontmatter 问题：`execute` 的 description 含未加引号的 `: `，Cursor 加载器会丢掉整个 skill。

## 首轮与 check 修复

首轮 19/21：`l-route-archive` #1 和 #3 失败，都是 check.sh 自己的缺陷，不是功能问题。

- `export TASKNOTES_FILE` 写在 `node --test` 之前，check 自己的变量漏进样本的 CLI 测试；#3 的 25 个测试在干净环境下全过，重建样本后确认。
- 第二次 archive 的 0 条提示只认数字 0 或 "nothing"；#1 输出 "No completed tasks to archive."，语义相同但匹配不上。

修法是让 `node --test` 在导出变量之前跑，并把 `no .*tasks?` 加进零条匹配。两个失败样本在修好的 check 下都通过；`l-route-archive` 重跑 3/3、0 催促。基线当时在更严格的 check 下已是 3/3，这次修改只放宽、不会让基线由过变不过，所以基线不用重跑。

## 结果

单个样本均值；`tokens` 为单样本，非三样本合计。

| 任务 | interrogate 通过/耗时/tokens/$ | flow:review 通过/耗时/tokens/$ |
|---|---|---|
| m-route-store-guard | 3/3 · 145s · 0.89M · $0.69 | 3/3 · 260s · 1.36M · $0.94 |
| m-route-sort-policy | 3/3 · 166s · 0.94M · $0.77 | 3/3 · 102s · 0.44M · $0.43 |
| m-route-batch-clean | 3/3 · 268s · 1.82M · $1.11 | 3/3 · 410s · 1.25M · $0.87 |
| l-route-archive | 3/3 · 802s · 5.32M · $5.00 | 3/3 · 689s · 2.38M · $1.52 |
| m-route-stats | 3/3 · 172s · 0.90M · $0.66 | 3/3 · 238s · 1.28M · $0.82 |
| m-route-concurrent-add | 3/3 · 841s · 4.74M · $3.91 | 3/3 · 605s · 2.22M · $1.55 |
| l-route-recurring | 3/3 · 1019s · 9.13M · $9.68 | 3/3 · 716s · 2.79M · $1.70 |
| **平均** | **21/21 · 0 催促 · 488s · 3.39M · $3.12 · 0.9 子 agent** | **21/21 · 0 催促 · 431s · 1.67M · $1.12 · 0 子 agent** |

## 结论

- **改**：通过率与打断次数都不低于基线（21/21、0），耗时降 12%，token 降 51%，费用降 64%，子 agent 从 0.9 降到 0。
- 收益集中在 L 题，也就是改动前真正会跑 interrogate 的地方：`l-route-recurring` 9.13M → 2.79M token（$9.68 → $1.70），`l-route-archive` 5.32M → 2.38M（$5.00 → $1.52）。M 题本来大多没触发 interrogate，两组差异主要是样本波动（`m-route-store-guard`、`m-route-stats` 反而略升）。
- `flow:review` 的自审在样本里留下了证据（例如 "review -> read full diff against task; npm test 26/26; manual CLI; ..."），review 门禁的输出仍有：每个发现修掉或驳回并记录。
- 保留 interrogate / swarm 作为争议设计和 must-stop 改动的条件提供者；只改阶段表一格即可调整触发条件。

## 限制

- 每题 3 个样本，比较的是"不更差"，不是统计显著的更好。
- 题目都是自包含的 M/L 任务，没有真正"设计有争议"的样本，interrogate 在争议设计上的价值没有被测到。
- `m-route-store-guard` 与 `m-route-stats` 的耗时/token 上升属于样本波动，没有单独归因。
