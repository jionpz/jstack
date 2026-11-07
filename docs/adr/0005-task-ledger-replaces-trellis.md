# 任务只记在 tracker，gbrain 只存认知，Trellis 被替代

任务状态原来分散在三处：spec 的 issue tracker、Trellis 的 `.trellis/tasks/`、gbrain。三处都能写，就没有一处可信。我们定为：

- **tracker**（默认 GitHub Issues，没有远端时用本地 markdown）是唯一的任务账本，记录 ticket、依赖、状态和需要人回答的问题。
- **gbrain** 只存认知层：项目状态卡、决策、教训、跨项目知识，不存任务清单。
- **Trellis** 被替代。它独有的、值得保留的两点由 jstack 吸收：
  1. **逐轮阶段提示**：Trellis 用 UserPromptSubmit hook 每轮注入"当前在哪个阶段、下一步必须做什么"。这条要保留，因为模型最容易跳过必做步骤。jstack 用 flow 插件的 hook 实现，阶段来自 ADR-0002 的表。
  2. **项目约定库与教训回写**：Trellis 按包、按层存放编码约定，按需注入子 agent，任务结束后把新教训写回约定。jstack 在业务仓库的 `docs/agents/conventions/` 存约定，委派时只注入相关的那几页，归档阶段负责把教训写回。

不吸收的部分：`task.py` 任务生命周期（由 tracker 代替）、`workspace/` 会话日志（由收尾摘要和 gbrain 代替）、开发者身份、`.runtime/` 会话指针。

## Consequences

- 已使用 Trellis 的仓库（jspace、keel、tugo）要做非破坏迁移：把 `.trellis/spec/` 迁到 `docs/agents/conventions/`，确认没有未完成的任务后再移除 Trellis 的 hook 和目录。
- 全局治理文档 `~/.agents/AGENTS.md` 里"执行细节留在 Trellis"的说法要改成"留在 tracker"。
