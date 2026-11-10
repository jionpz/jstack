# Keel managed 调查协议（JT-01）

首个只读接入切片，尚不代表完整后台工程工作流或委托审批已经实现。

```bash
./jstack managed-export > /tmp/jstack-investigation.json
```

导出器读取 `src/flow/skills/route/SKILL.md` 的 Question 路线、阶段表和 `src/managed/investigate.md`，确认只走 execute 后输出 `protocol_version=1.0` 的包。`--root` 只用于显式选择导出来源和测试；不运行该目录的脚本。缺文件、空文件、越界软链或不兼容路线均拒绝。

Keel 接收并保存完整内容和摘要；旧任务不受本地文件或后续升级影响。`source_commit` 记录导出时 HEAD 作为补充来源信息，工作区新增/修改内容的确切身份以 Keel 内容摘要为准。

调查模型没有原生工具，通过 `read_files` 向 Keel 请求相对路径。所有需要人工的问题以 `waiting_decision` 提案提交；Keel 先运行天问并保存建议，再接受真实用户答复。完成报告须引用已观察的路径和内容摘要。

当前是影子模式：不自动批准、不修改源码、不调用 shell、不部署；不运行完整 L/XL/pstack/land/archive 路线。现有交互式 route、must-stop 与插件安装行为保持原有语义。模型和凭据由 Keel 的运行环境明确配置，不由项目包指定。

验证：`python3 tests/managed-export.py` 的 4 项确定性测试已加入 `./jstack check`。真实模型运行由 Keel 的单独验收承担；缺推理 CLI 的静态检查不等于真实模型验收。
