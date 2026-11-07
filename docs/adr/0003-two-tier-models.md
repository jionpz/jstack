# 两层模型：可切换的高级模型做判断，无限模型做执行与验证

工作流同时用两类模型。**高级模型**能力最强，但 token 有限，具体用哪个模型可以随时切换。**无限模型**是 DeepSeek、GLM、Kimi 这类 token 几乎不限的模型，要求的是准确和质量。我们不按"贵 / 便宜"分工，而是按"判断 / 体力"分工：高级模型只在门禁点做高杠杆、短上下文的判断，比如批准拆解、架构取舍、最终审查结论、要不要叫人；主循环、探索、写代码、测试、验证都交给无限模型。无限 token 用来换质量：多次采样再投票，验证者和作者分开，对抗审查用不同家族的模型。

角色到层级的映射写在 jstack 自己的一份配置里，不写死在 skill 里：

- 层级 `premium`：当前绑定的高级模型。可切换，额度暂定不限，但保留预算上限和并发上限两个开关（例如 AnyRouter 不能并发）。
- 层级 `bulk`：一个或多个无限模型家族。审查面板至少用两个不同家族。
- 每个 harness 怎么表达层级由 adapter 负责。Claude Code 的子 agent `model` 只收 `opus` / `sonnet` / `haiku` / `fable` 别名，所以通过 magpie / env 映射：`opus` 指 premium，`sonnet`、`haiku` 指 bulk 家族。Pi、OMP、Codex 直接写 `provider/modelId`；Cursor 用原生 slug。

## Consequences

- 改 magpie 或 `~/.claude/settings.json` 的模型映射，会改变数据发往哪个 provider，所以落地前要用户确认（全局红线：provider 配置决定数据流向）。
- pstack 的分角色模型表（setup-pstack 写的规则）由 jstack 的配置生成，不再手填。
- 预算上限打开后，premium 用尽时降级到最好的 bulk 模型，并在收尾摘要里写明。
- 主会话默认跑在 bulk 上。用户也可以让主会话跑在 premium 上，这时委派仍按角色走 bulk。
