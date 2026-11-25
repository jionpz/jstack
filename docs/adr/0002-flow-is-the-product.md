# flow 是产品核心，上游 skill 是可替换的提供者

jstack 不是"打包上游的 marketplace"，而是用户长期维护的整条 AI 开发工作流。pstack、Matt Pocock 的 skills、Trellis 都只是某一阶段的当前实现，随时可能被改写或替换。所以工作流由 jstack 自己定义成固定的阶段，每个阶段写明产出和门禁，再用一张表把阶段绑定到提供者。换掉某个上游只改表里一行，不改流程。

| 阶段 | 产出 | 门禁 | 当前提供者 |
|---|---|---|---|
| 分级 | 任务大小与路线 | 无 | `flow:route` |
| 澄清 | 已定决策，必要时写 ADR / GLOSSARY | 证据定不了的决策才问人 | `spec:grill-with-docs`（内部用 `grilling`、`domain-modeling`） |
| 规划 | spec 与 tickets（L / XL） | 高级模型审查拆解 | `spec:to-spec`、`spec:to-tickets`、`spec:wayfinder` |
| 执行 | 代码改动 | 无 | `pstack:poteto-mode` 的 playbook |
| 验证 | 可复现的验证证据 | 结构门禁：没有证据不能宣布完成 | pstack 的 prove-it-works，加项目自己的 verify skill |
| 审查 | 审查结论 | 高级模型裁决，跨家族的无限模型做对抗审查 | pstack `interrogate`、`swarm` |
| 落地 | PR 或合并 | 必须停的清单 | pstack 的 Opening a PR / Babysit / Shipping |
| 归档 | 关 ticket、更新 ADR / GLOSSARY、写回 gbrain、清理 worktree、教训回流 | 无 | 缺，由 jstack 自写 |

## Consequences

- 这张表的现行版本是 `src/flow/skills/route/stages.md`，以它为准；本 ADR 只记录决策时的样子。
- route 的职责从"把任务交给 poteto-mode"扩大到"驱动任务走完全部阶段"。`locate.sh` 里写死的入口名改为读这张表。
- 上游改名或换掉某个提供者，只改表和对应的定位逻辑；`jstack check` 要校验表里每个提供者都能被找到。
- 一个提供者不满足阶段的门禁时，门禁由 jstack 补齐（hook、脚本或 jstack 自己的 skill），不靠给上游打补丁。
- 精简或改写提供者时，用功能回归核对对应阶段的产出与门禁。
- 支持的 harness：Claude Code 是主力，所有门禁和 hook 先在 Claude Code 落地；Pi、OMP、Codex、Cursor 保证 skill 可用、route 可用、能派子 agent。某个门禁在某个 harness 上做不到时，明确跳过并说明，不静默降级。

## 发布支持分级

2026-11-13 确认 Claude Code 和 Pi 为一等支持。发布前，两者都必须通过真实 smoke。OMP、Cursor 和 Codex 为尽力而为支持，保留安装和运行检查，并在[门禁能力矩阵](../harness/gates.md)记录降级。`./jstack check --smoke` 和 `./jstack smoke all` 均报告所有 harness 的 smoke 结果，其中一等 harness 缺失或失败会使命令失败。单独运行指定 harness 的 smoke 时，该 harness 必须可用并通过。
