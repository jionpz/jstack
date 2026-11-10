// OMP 的阶段门禁：同 pi.ts，但 OMP 的事件名和输出协议不同。
// - session_start / session_switch -> 把会话 id 写进 process.env.JSTACK_SESSION_ID，
//   OMP 的 bash 子进程继承进程环境，stage.sh 才能在模型跑的 shell 里找到同一个会话；
//   子 agent 的会话带 parentSession，不覆盖，子 agent 的 shell 继续用主会话的 id。
// - before_agent_start -> prompt.sh
// - session_stop -> stop.sh：返回 decision:"block" + reason，OMP 会接着跑一轮。
// - tool_call(bash) -> guard.sh：交互模式用确认框，非交互模式直接拦下。
// 判定逻辑在 hooks/*.sh。安装时由 ./jstack install 在 ~/.omp/agent/extensions/ 写一个转出本文件的入口。

import { flowRoot, isSubagent, jsonField, lastAssistantText, runHook, sessionId } from "./common.ts";

export default function (pi: any) {
	const root = flowRoot();
	if (!root) return;

	const publishSid = (ctx: any) => {
		if (isSubagent(ctx)) return;
		const sid = sessionId(ctx);
		if (sid) process.env.JSTACK_SESSION_ID = sid;
	};
	pi.on("session_start", async (_event: any, ctx: any) => publishSid(ctx));
	pi.on("session_switch", async (_event: any, ctx: any) => publishSid(ctx));

	pi.on("before_agent_start", async (event: any, ctx: any) => {
		if (isSubagent(ctx)) return;
		const sid = sessionId(ctx);
		if (!sid) return;
		const hook = runHook(root, "prompt", {
			session_id: sid,
			hook_event_name: "UserPromptSubmit",
			prompt: String(event?.prompt ?? ""),
		});
		if (!hook.ok || !hook.out) return;
		return { message: { customType: "jstack-gates", content: hook.out, display: false } };
	});

	pi.on("session_stop", async (event: any, ctx: any) => {
		if (isSubagent(ctx)) return;
		if (event?.signal?.aborted) return;
		const sid = String(event?.session_id || sessionId(ctx) || "");
		if (!sid) return;
		const hook = runHook(root, "stop", {
			session_id: sid,
			hook_event_name: "Stop",
			stop_hook_active: Boolean(event?.stop_hook_active),
			last_assistant_message: lastAssistantText(event?.last_assistant_message),
		});
		if (!hook.ok) return;
		const reason = jsonField(hook.out, "reason");
		if (!reason) return;
		return { decision: "block", reason };
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
		if (ctx?.hasUI && typeof ctx?.ui?.confirm === "function") {
			if (await ctx.ui.confirm("jstack must-stop", reason)) return;
		}
		return { block: true, reason };
	});
}
