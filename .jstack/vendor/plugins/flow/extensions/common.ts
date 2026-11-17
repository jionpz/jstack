// Pi / OMP 扩展的共用部分，由同目录的 pi.ts 和 omp.ts 引用，不单独加载。
// 判定逻辑全在 hooks/*.sh 里：扩展只把 harness 的事件翻译成 Claude 风格的 hook 输入，
// 再把输出翻译回该 harness 的结果类型。不要在这里复制门禁规则。

import { spawnSync } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// 本文件在 <flow>/extensions/common.ts；JSTACK_FLOW_ROOT 供测试覆盖。
export function flowRoot(): string {
	const env = process.env.JSTACK_FLOW_ROOT;
	if (env) return env;
	try {
		return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
	} catch {
		return "";
	}
}

export interface HookRun {
	ok: boolean;
	out: string;
}

// 用 Claude 风格输入跑一个 hook 脚本；脚本内部出错时它自己无输出放行，这里也一律不拦。
export function runHook(root: string, name: string, payload: unknown, timeoutMs = 8000): HookRun {
	const script = path.join(root, "hooks", `${name}.sh`);
	const bash = process.env.JSTACK_BASH || "/bin/bash";
	const res = spawnSync(bash, [script], {
		input: JSON.stringify(payload),
		encoding: "utf8",
		timeout: timeoutMs,
		env: { ...process.env, CLAUDE_PLUGIN_ROOT: root },
	});
	if (res.error || res.status !== 0) return { ok: false, out: "" };
	return { ok: true, out: (res.stdout || "").trim() };
}

// hook 输出里的字段：guard 的 permissionDecisionReason 在 hookSpecificOutput 里，其余在顶层。
export function jsonField(out: string, field: string): string {
	if (!out) return "";
	let data: any;
	try {
		data = JSON.parse(out);
	} catch {
		return "";
	}
	if (!data || typeof data !== "object") return "";
	const top = data[field];
	if (typeof top === "string" && top) return top;
	const nested = data.hookSpecificOutput && data.hookSpecificOutput[field];
	return typeof nested === "string" ? nested : "";
}

// 一条助手消息里的纯文本：content 可能是字符串，也可能是 text 块数组。
export function messageText(message: unknown): string {
	if (!message || typeof message !== "object") return "";
	const content = (message as any).content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter(block => block && block.type === "text" && typeof block.text === "string")
		.map(block => block.text)
		.join("\n");
}

// 事件里能拿到的最后一条助手回复；拿不到就返回空串，交给 stop.sh 按“没提问”处理。
export function lastAssistantText(...candidates: unknown[]): string {
	for (const candidate of candidates) {
		if (Array.isArray(candidate)) {
			for (let i = candidate.length - 1; i >= 0; i--) {
				const message = candidate[i] as any;
				if (message && message.role === "assistant") {
					const text = messageText(message);
					if (text) return text;
				}
			}
		} else if (candidate && typeof candidate === "object") {
			const text = messageText(candidate);
			if (text) return text;
		}
	}
	return "";
}

export function sessionId(ctx: any): string {
	const sid = ctx?.sessionManager?.getSessionId?.();
	return typeof sid === "string" ? sid : "";
}

// 子 agent 的会话带 parentSession；它们的 prompt / Stop 门禁不归路由管，跳过。
export function isSubagent(ctx: any): boolean {
	try {
		return Boolean(ctx?.sessionManager?.getHeader?.()?.parentSession);
	} catch {
		return false;
	}
}
