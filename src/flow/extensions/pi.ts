// Pi 的阶段门禁：把 Pi 的扩展事件翻译成 flow 的 Claude 风格 hook。
// - before_agent_start -> prompt.sh：每轮注入当前阶段，清掉 ask。
// - agent_before_settle -> stop.sh：缺验证证据时请求一次续跑，把理由作为自定义消息发给模型。
// - tool_call(bash) -> guard.sh：must-stop 命中时，交互模式用确认框，非交互模式直接拦下。
// 判定逻辑在 hooks/*.sh；这里只做协议翻译。Pi package 通过根 package.json 的 pi.extensions 加载本文件。

import { flowRoot, isSubagent, jsonField, lastAssistantText, runHook, sessionId } from "./common.ts";

export default function (pi: any) {
	const root = flowRoot();
	if (!root) return;
	// Pi 没有 Claude 的 stop_hook_active：agent_before_settle 的 continue 只针对本次结算，
	// 下一轮又是 false，模型硬顶着不记证据时会无限续跑。按 Cursor 的 loop_limit 兜一层：
	// 同一条用户消息最多拦 3 次，之后放行；用户发新消息或门禁满足时清零。
	const blocked = new Map<string, number>();
	const limit = 3;

	pi.on("before_agent_start", async (event: any, ctx: any) => {
		if (isSubagent(ctx)) return;
		const sid = sessionId(ctx);
		if (!sid) return;
		if (event?.messageType === "user") blocked.delete(sid);
		const hook = runHook(root, "prompt", {
			session_id: sid,
			hook_event_name: "UserPromptSubmit",
			prompt: String(event?.prompt ?? ""),
		});
		if (!hook.ok || !hook.out) return;
		return { message: { customType: "jstack-gates", content: hook.out, display: false } };
	});

	pi.on("agent_before_settle", async (event: any, ctx: any) => {
		if (isSubagent(ctx)) return;
		// 用户中断或出错时不追问，和 Cursor 的 stop 只看 completed 一致。
		if (event?.outcome && event.outcome !== "completed") return;
		const sid = sessionId(ctx);
		if (!sid) return;
		if ((blocked.get(sid) ?? 0) >= limit) return;
		const hook = runHook(root, "stop", {
			session_id: sid,
			hook_event_name: "Stop",
			stop_hook_active: Boolean(event?.continue),
			last_assistant_message: lastAssistantText(event?.context?.contextMessages, event?.context?.pendingMessages),
		});
		if (!hook.ok) return;
		const reason = jsonField(hook.out, "reason");
		if (!reason) {
			blocked.delete(sid);
			return;
		}
		blocked.set(sid, (blocked.get(sid) ?? 0) + 1);
		return {
			continue: true,
			entries: [{ type: "custom_message", customType: "jstack-gates", content: reason, display: false }],
		};
	});

	pi.on("tool_call", async (event: any, ctx: any) => {
		if (event?.toolName !== "bash") return;
		const command = event?.input?.command;
		if (typeof command !== "string" || !command) return;
		const hook = runHook(root, "guard", {
			session_id: sessionId(ctx),
			hook_event_name: "PreToolUse",
			tool_name: "Bash",
			tool_input: { command },
		});
		if (!hook.ok) return;
		const reason = jsonField(hook.out, "permissionDecisionReason");
		if (!reason) return;
		// Pi 只有交互和 RPC 能弹确认；JSON / print 模式没有 UI，降级为拦下，和 Cursor 的 preToolUse 一致。
		if (ctx?.hasUI && typeof ctx?.ui?.confirm === "function") {
			if (await ctx.ui.confirm("jstack must-stop", reason)) return;
		}
		return { block: true, reason };
	});
}
