# CI 设计与故障排查

JStack 的必需 CI 是 [`.github/workflows/check.yml`](../.github/workflows/check.yml)：对 PR 和 `main` 提交，在 macOS 与 Ubuntu 上执行 `./jstack check`。它检验的是**可离线、可重复的工程约束**，而不是调用模型后的工作流质量。

## 三条原则

1. **相同输入得到相同结论**：自检必须明确构造失败条件，不依赖碰巧发生的并发竞态、网络延迟或随机数。
2. **所需环境可解释**：固定操作系统主版本、Python/Node 主版本及校验工具版本。`macos-15`、`ubuntu-24.04` 仍会接收 GitHub 镜像补丁，不能把固定标签理解为镜像字节完全不变。
3. **错误归因独立于红绿灯**：业务或测试失败、依赖安装失败、GitHub runner 排队、被新提交取消，是四种不同结果。不要通过重跑掩盖真正的断言失败。

## CI 执行什么

- 校验 upstream + patches 的构建产物一致性、manifest、插件与安装配置、工作流 hook、shell 兼容、模型配置逻辑及 `evals/tasks` 的样本自检。
- 校验 `claude plugin validate`。CI 固定用于校验 manifest 的 Claude Code CLI 版本；升级应单独提交、在两个系统上通过后再合并。
- **不执行**消耗 token 的 `./jstack eval`、需要真实模型与登录态的 smoke。它们应在特性变更和发布验收时独立进行，不能从静态 CI 绿色推断模型效果。

## 诊断顺序

1. 先打开 [Actions 运行记录](https://github.com/jionpz/jstack/actions/workflows/check.yml)，确认所看的 `head_sha`、事件类型、运行尝试及是否为最新提交。
2. 若是 `cancelled`：PR 又推了新提交时，`concurrency.cancel-in-progress` 会主动取消旧运行；检查**最新提交**的结果，不把旧运行算作失败。
3. 若是 `queued`：检查是否已经拿到 runner。未调度不是测试失败，尤其 macOS 在高峰期可能排队。
4. 若在 `setup-python`、`setup-node`、`npm`、`brew`、`apt-get` 失败：优先检查工具版本、对应 runner 镜像与外部服务可用性。
5. 若在 `./jstack check` 失败：定位第一条 `✗`，按报告给出的模块单独复现；macOS 使用系统 `/bin/bash` 和 UTF-8 locale，避免 Linux 默认 shell 掩盖差异。
6. 本地静态自检可运行 `./jstack check`；测试特定评测样本可使用 `./jstack eval --selftest m-route-concurrent-add`。

## 并发样本为什么要有受控屏障

`m-route-concurrent-add` 的初始实现采用未加锁的“读取—修改—写入”。仅启动许多进程并不保证它们读到相同旧状态；一次碰巧没有冲突，会让应失败的基线误判为通过。新版检查通过临时注入的 `fs.readFileSync` 屏障，使两个未加锁的 `add` 进程在读取旧数据后汇合，再检查任务是否丢失；随后额外运行一批并发写入检查锁竞争。

注入代码只存在于测试创建的临时目录，**不进入实际 CLI 产品代码或参考解**。参考解仍使用存储层文件锁；受保护的写入不应丢数据。屏障设置超时以避免 CI 无限挂起。

## 已知边界

- GitHub-hosted runner 的容量、系统补丁及公共 npm 服务无法完全冻结或由仓库修复。版本固定只是减少不必要的漂移。
- 如果校验器、macOS 或 Ubuntu 标签需要升级，应通过独立 PR 调整固定版本，观察双平台结果，并在 PR 中记录新的版本。
- `./jstack check` 的样本自检验证评测题“初始状态失败、参考解通过”的正确性，**不等价于对模型表现的评测**。修改 `evals/` 后仍应按 [维护规则](../AGENTS.md) 比较模型评测基线。
