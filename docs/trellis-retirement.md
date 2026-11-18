# 清退项目里的 Trellis

从 jstack checkout 预览目标 Git 仓库的清退：

```bash
./jstack retire trellis --repo /path/to/repo
```

1. 从 `.trellis/spec/` 把仍适用的约定迁到目标仓库的 `docs/agents/conventions/`，更新目标仓库的规范索引。核对清单中需要人工判断的入口和规则，按文件的实际用途处理。
2. 把在途任务迁到项目已有的 tracker，保留原任务 ID、状态和依赖。准备 JSON 对象记录原任务 ID 与新 ticket 的对应关系，例如 `{"01-refresh-api":"#123"}`。重跑前按原 ID 查找已迁任务。
3. 加上 `--task-map /path/to/task-map.json` 重跑预览。确认所有阻塞项已处理，检查哪些入口会从共享配置中移除。
4. 加上 `--apply` 应用清退。移动的资料在 `.jstack-retired-trellis/project/`，改写前的共享配置在 `.jstack-retired-trellis/originals/`。任务映射保存在 `task-map.json`。归档目录默认忽略内容，先逐份核对其中的项目历史和私有配置，再用 `git add -f -- <已审查的归档路径>` 仅提交应进入 Git 的资料。
5. 生成 jstack 项目级安装产物。一起 review 旧入口移除、新入口、项目约定及应该保留的历史。在干净 clone 打开目标 harness，验证工作流入口、阶段提示和验证门禁。

已提交的接线变更可以用 Git 回退。恢复未跟踪资料时，从归档的 `project/` 按原路径取回。共享配置先与 `originals/` 中的原件比较，再合并需要恢复的条目，保留清退后新增的配置。tracker 里的 ticket 根据任务映射单独处理。

工具作用于目标仓库。用户级配置、已打开的会话、外部 tracker 写入由各自的入口管理。
