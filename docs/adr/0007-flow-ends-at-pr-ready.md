# ADR-0007：流程终点是 PR-ready，合并由用户来点

状态：已采纳（2026-11-13 用户确认，#74）

## 背景

land 的产出只写到“开了 PR”，之后的 CI、合并没有阶段也没有策略。archive 要求凭证据关 ticket、清理已合并的 worktree，却紧跟 land 在同一个会话里跑，那时 PR 还没合。2026-11-13 实际发生过：用户说“合并”（指 PR #77）之后，会话又自己开并合并了后续修复 PR #78，期间没有用户消息；must-stop 清单里没有“合并 PR”，guard 也没有对应的模式。

## 决定

1. 流程自己走到的终点是 **PR-ready**：PR 已开、verify 和 review 通过、CI 在验证过的 head 上是绿的。合并后并归档完才叫 **done**。运行报告的“状态”一行必须写明是哪一个。
2. 合并是用户的动作。只有用户当前这条消息点名某个 PR 时才合并，而且只合那一个；合并后的后续修复另开 PR，同样停在 PR-ready。合并 PR 和开启 auto-merge 进 must-stop 清单，guard 对 `gh pr merge`、`origin pr merge`、`glab mr merge` 和 `gh api …/pulls/<n>/merge` 先问人。
3. CI 红回到 execute，不算打断人；CI 没绿（红、没跑完、跑不了）的 PR 不是 PR-ready。
4. archive 拆成两段。合并前（文档、gbrain、教训）在做事的会话里跑；合并后（关 ticket、清 worktree）等 PR 合并。PR 没合时用 `stage.sh pending` 记一条待补，按仓库存、跨会话；下一次 `stage.sh start` 会列出来，由那次任务补上。

## 后果

- 待补只在下一次走 route 时被提醒；不走 route 的会话看不到。不为此加常驻进程或轮询（无人值守归 Keel）。
- “CI 红不报成完成”是 skill 规则，没有脚本去查 CI：脚本查 CI 要联网，也绑死某一个 forge。
- guard 只看得到 shell 命令。桌面端的 auto-merge 工具、网页上的合并按钮它看不到，靠规则约束。
- pstack 的 shipping playbook 写着“合并最低的未合并 PR”（`origin pr merge` / `gh pr merge`）。那是上游正文，不打补丁；route 的规则优先，guard 对这两条命令都会先问人。
- guard 不知道用户有没有点名：用户点名合并时 Claude Code 仍会弹一次确认；Cursor 的 preToolUse 和 Codex 只能 deny，在那里合并要用户自己执行命令。
- 等运行日志能证明通过独立验证和 premium 裁决的 PR 合并后没出过问题，再考虑对 XS、S 放开自动合并；放开之前要再问一次用户。
