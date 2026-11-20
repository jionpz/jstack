# jstack 定义工作流，Keel 驱动无人值守执行

jstack 在一张阶段表中定义阶段、门禁、提供者及各 launcher 的阶段要求。交互式会话通过 route 驱动，Keel 负责无人值守的排队、调度、运行环境与权限边界。Keel 接收带摘要的工作流包，每次运行按该版本执行。

阶段表的 `Managed ticket` 列声明托管写入任务必经的阶段，包括 review。ticket 与 route 两种导出共用这一列。托管阶段的增删或重排需要同时更新 Keel 的协议校验。
