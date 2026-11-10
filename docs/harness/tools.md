# 阶段工具与原生映射

本文说明 jstack 如何把阶段和辅助角色绑定到工具能力，以及把能力翻译成 Pi、Claude Code 的原生工具。工具存在、工具启用、操作授权和 OS/网络边界是不同事实；这里只描述前两项，不声称后两项。

## 唯一来源

- [`src/flow/skills/route/stages.md`](../../src/flow/skills/route/stages.md) 的 Tool profile 列定义阶段到 profile 的引用。
- [`src/flow/skills/route/tool-policy.json`](../../src/flow/skills/route/tool-policy.json) 只定义 profile（`role`、`capabilities`、`optional_capabilities`）和 harness 映射候选，不复制阶段表。
- investigator、tianwen 是辅助角色，有 profile 但没有阶段行，不能据此制造第二套工作流。

八个阶段使用 router、analyst、planner、developer、verifier、reviewer、releaser、archivist；investigator 和 tianwen 用于调查与证据/决策候选。能力先保留八个可验证原语：

`read`、`grep`、`find`、`ls`、`edit`、`write`、`bash`、`delegate`

另有明确可选的 `web_search`、`web_fetch`。Fact、decision、tracker、PR、授权和长期记忆走 Keel 已接线的协议或网关；没有实现时标为 unavailable，不新造一个工具名宣称可用。

## 导出协议

```bash
./jstack tools export
./jstack tools export --pretty
./jstack tools export --root /path/to/jstack-or-plugin
```

输出是一个稳定 JSON 对象：

| 字段 | 含义 |
|---|---|
| `protocol_version` | 固定 `1.0` |
| `source_commit` | `git rev-parse HEAD` 的结果；不是 Git 仓库时为 `unversioned`。它只描述 Git 身份，不替代内容校验 |
| `stages` | 阶段名到 profile 名的映射，按阶段表顺序 |
| `profiles` | profile 名到 `{role, capabilities, optional_capabilities}` |
| `harnesses` | `pi` / `claude-code` 到“能力 → `{native, fallback?, extension?}`”的映射 |
| `content_digest` | 对除 `content_digest` 外的整个对象计算的内容摘要 |

`content_digest` 的算法：

1. 从对象中删掉 `content_digest`。
2. 递归按键排序（等价于 `json.dumps(..., sort_keys=True)`）。
3. 用紧凑分隔符 `,` 和 `:`、`ensure_ascii=False` 序列化，再按 UTF-8 编码。
4. 对字节串取 SHA256，输出小写十六进制，不带前缀。

Python 复算：

```python
import hashlib, json
body = {k: v for k, v in payload.items() if k != "content_digest"}
canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
assert hashlib.sha256(canonical).hexdigest() == payload["content_digest"]
```

导出只读取仓库或插件目录内的普通文件，拒绝越出根目录的路径、坏引用、未知能力、未知 profile 和重复 JSON 字段。阶段表引用变化会直接改变 `stages` 和 digest；重复导出同一内容得到相同字节，不带时间戳或绝对路径。

## 解析为原生工具

```bash
./jstack tools resolve \
  --stage execute \
  --harness pi \
  --inventory inventory.json

./jstack tools resolve \
  --role verifier \
  --harness claude-code \
  --inventory inventory.json \
  --allow-shell-fallback
```

`--stage` 和 `--role` 二选一。inventory 是当前 harness 真实注册的工具清单，支持两种形状：

```json
["read", "bash", "edit", "write", "grep", "find", "ls", "Agent"]
```

```json
{"tools": [{"name": "read"}, {"name": "bash"}, {"name": "Agent"}]}
```

`resolve` 不根据 harness 品牌猜测工具是否存在；inventory 里没有就是没有。输出字段：

| 字段 | 含义 |
|---|---|
| `harness`、`stage`、`profile`、`role` | 本次解析的身份；辅助角色没有 `stage` |
| `native_tools` | 按 profile 能力顺序选出的原生工具，去重 |
| `permissions.allowed_tools` | 与 `native_tools` 相同的清单，供启动参数使用 |
| `degradations` | 显式接受的 shell fallback，逐项写明能力、原生候选、实际工具和原因 |
| `missing_optional` | inventory 里缺失的可选能力；不会用同名空壳冒充 |

缺必需工具时命令失败并列出能力、原生候选和原因，不输出半截 JSON。原生搜索/列目录缺失时，只有在传 `--allow-shell-fallback` 后才使用 shell 工具；否则拒绝。这样可以避免给只读角色悄悄加 Bash。

## Pi 映射

| 能力 | 原生候选 | 备注 |
|---|---|---|
| `read` | `read` | 内置 |
| `grep` | `grep`，fallback `bash` | grep 默认未启用，需显式启用；缺失时 shell fallback |
| `find` | `find`，fallback `bash` | find 不是 glob；缺失时 shell fallback |
| `ls` | `ls`，fallback `bash` | 默认未启用；缺失时 shell fallback |
| `edit` | `edit` | 内置 |
| `write` | `write` | 内置 |
| `bash` | `bash` | 内置 |
| `delegate` | `Agent` | 来自已装 `@tintinweb/pi-subagents` 扩展，不是内置工具 |
| `web_search` | `web_search` | 可选；来自已审查的 web 扩展，不是内置能力 |
| `web_fetch` | `fetch_content` | 可选；同上 |

Pi 原生 `--tools` 接受逗号分隔的 allowlist，例如：

```bash
pi --tools read,grep,find,ls,edit,write,bash,Agent
```

只读角色去掉写和 shell 能力；需要 shell fallback 时，把 `bash` 加入清单并把 `degradations` 记录到启动报告。`grep`、`find`、`ls` 默认关闭，`--tools` 里写出来才会启用。

## Claude Code 映射

| 能力 | 原生候选 | 备注 |
|---|---|---|
| `read` | `Read` | |
| `grep` | `Grep`，fallback `Bash` | 2.1.314 的 init 不含 Grep，实际缺失时用 shell |
| `find` | `Glob`，fallback `Bash` | 2.1.314 不含 Glob，实际缺失时用 shell |
| `ls` | `LS`，fallback `Bash` | 2.1.314 不含 LS，实际缺失时用 shell |
| `edit` | `Edit` | 不要用 `write` 冒充 `Edit` |
| `write` | `Write` | |
| `bash` | `Bash` | |
| `delegate` | `Task`、`Agent` | 按 inventory 选择，不同版本可能只有其中一个 |
| `web_search` | `WebSearch` | 可选 |
| `web_fetch` | `WebFetch` | 可选 |

原生启动参数用 `--allowedTools`：

```bash
claude --allowedTools "Read Grep Glob LS Edit Write Bash Task"
```

当前 Claude Code 2.1.314 的真实 inventory 没有 `Grep`、`Glob`、`LS`，因此 `resolve` 在未传 `--allow-shell-fallback` 时会拒绝，传了才会把 `Bash` 加进清单并列出三项降级。web 能力是否出现在 inventory 取决于当前版本和权限，缺了就列 `missing_optional`。

## Pi 默认推荐套件

默认只推荐两样：

1. jstack 自己的 Pi package（三个插件和 flow 门禁扩展）。
2. 已审查的 `@tintinweb/pi-subagents@0.23.2`，用于 `Agent` 和子代理工具。

不另外安装来源不明的 hooks 包：门禁由 Pi 原生 extension 事件和 flow 扩展承载。autoresearch、goal-loop、statusline、web/cookie 配置不进入默认 managed 套件。

安装行为：

- `./jstack install-pi` 和 `./jstack install --all` 在用户作用域安装 jstack package 后，检查用户作用域是否已有 subagents；没有才执行原生 `pi install npm:@tintinweb/pi-subagents@0.23.2 --approve`。
- 项目级 `./jstack install --scope project` 检查仓库作用域；没有则执行带 `-l` 的安装，cwd 是该仓库，结果记入 `.jstack/lock.json` 的 `recommended.pi`（source、固定版本、scope、`.pi/settings.json`），并作为 lock 记录参与 `doctor` 核对。
- 安装命令设置 `npm_config_ignore_scripts=true`，禁用 lifecycle scripts。脚本不读写 provider、models、auth 或权限配置。
- 已有包按作用域跳过并报告实测版本和路径；用户作用域已装不会让项目作用域误判为已装。已有较新版本保留，不降级。
- `--dry-run` 只查询本地 `pi list` 并打印将执行的命令，不联网、不安装、不写文件。

## 托管边界

- `resolve` 只输出工具清单。它不启动 harness、不修改设置、不在交互式会话里动态切换阶段工具；阶段 profile 在交互式 route 里是职责约定，不是已执行的强制隔离。
- Pi 子代理通过 SDK 创建会话，工具由角色定义独立计算，并不简单继承父 `--tools` 清单；角色 memory 还可能补 `read`/`write`/`edit`。因此 managed 模式不能因为启用了 `Agent` 就宣称委派权限继承成立，父子工具交集尚未原生验收。固定角色、固定工具和负例证明完成前，不把委派当作受控边界。
- OS、网络和凭据边界由执行环境（挂载、网络出口、凭据注入）保证，不能靠角色文本或工具名字保证。`isolated=true` 之类的配置不是 OS 隔离。
- Keel 的 Fact、decision、tracker、PR、授权和长期记忆仍走 Keel 协议/网关；网关能力不能伪装成 harness 原生工具。
