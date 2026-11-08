#!/usr/bin/env bash
# PreToolUse hook（Claude Code 的 Bash / Cursor 的 beforeShellExecution）：
# 命令命中 must-stop.md 的模式时，让 harness 先问用户。不看阶段状态，对所有会话生效。
# 命令在 ;、&&、||、|、换行处切段，每段对每条模式做 grep -E，报命令里最靠前的那一段命中的第一条。
# 没有 jq 时用整段输入做匹配，宁可多问。内部出错一律无输出地放行。
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

main() {
	local input evt tool cmd segs pats line hook rest re src hit_src= n best= hit= tab action reason cfg
	input=$(cat)
	evt=$(jstack_json_str hook_event_name "$input")
	case $evt in
	beforeShellExecution)
		# Cursor 的 shell 审批钩子：输入是顶层的 command，没有 tool_name。
		cmd=$(jstack_json_str command "$input")
		;;
	preToolUse)
		# Cursor 也认 Claude 的 preToolUse，但它不执行 ask；这里只认 Shell，输出按下面的降级处理。
		tool=$(jstack_json_str tool_name "$input")
		[ -z "$tool" ] || [ "$tool" = Shell ] || return 0
		cmd=$(printf '%s' "$input" | tr '\n' ' ' |
			sed -nE 's/.*"tool_input"[[:space:]]*:[[:space:]]*\{[^}]*"command"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
		;;
	*)
		tool=$(jstack_json_str tool_name "$input")
		[ -z "$tool" ] || [ "$tool" = Bash ] || return 0
		if ! jstack_has_jq || ! cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty | strings'); then
			cmd=$(printf '%s\n' "$input" | awk '{ gsub(/\\n/, "\n"); gsub(/\\t|"/, " "); print }')
		fi
		;;
	esac
	[ -n "$cmd" ] || return 0
	segs=$(printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||[;|]/, "\n"); print }')
	# 内置模式加仓库追加的模式，每条带来源列：builtin / repo。
	pats=$(
		awk '/^```patterns[ \t]*$/ { f = 1; next } f && /^```/ { exit } f && NF' "$route/must-stop.md" |
			awk -F'\t' 'NF >= 2 { print $1 "\t" $2 "\tbuiltin" }'
		if repo_pats=$(jstack_cfg_patterns 2>/dev/null); then
			printf '%s\n' "$repo_pats" | awk -F'\t' 'NF >= 2 { print $1 "\t" $2 "\trepo" }'
		fi
	)
	tab=$(printf '\t')
	while IFS= read -r line; do
		hook=${line%%"$tab"*}
		rest=${line#*"$tab"}
		re=${rest%%"$tab"*}
		src=${rest#*"$tab"}
		[ -n "$hook" ] && [ "$re" != "$rest" ] || continue
		n=$(printf '%s\n' "$segs" | grep -nE -- "$re" | head -1 | cut -d: -f1)
		[ -n "$n" ] || continue
		if [ -z "$best" ] || [ "$n" -lt "$best" ]; then best=$n hit=$hook hit_src=$src; fi
	done <<<"$pats"
	[ -n "$hit" ] || return 0
	if [ "$hit_src" = repo ]; then
		cfg=$(jstack_repo_config) || cfg=
		action=
		[ -z "$cfg" ] || action=$(jq -r --arg h "$hit" \
			'(.must_stop // [])[] | select((.hook // .action) == $h) | .action // empty' "$cfg" 2>/dev/null | head -1)
		reason="jstack must-stop: ${action:-${hit}}（仓库追加）. Confirm before it runs."
	else
		action=$(awk -F'|' -v h="\`$hit\`" '
			/^## / { sec = ($0 ~ /^## Must stop[ \t]*$/); next }
			sec && /^\|/ {
				a = $2; k = $3
				gsub(/^[ \t]+|[ \t]+$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", k)
				if (k == h) { print a; exit }
			}
		' "$route/must-stop.md")
		reason="jstack must-stop: ${action:-$hit}. Confirm before it runs."
	fi
	case $evt in
	beforeShellExecution)
		# Cursor 的 beforeShellExecution 执行 ask：弹出确认，用户拒绝才拦下。
		printf '{"permission":"ask","user_message":"%s","agent_message":"%s"}\n' \
			"$(jstack_json_escape "$reason")" "$(jstack_json_escape "$reason")"
		;;
	preToolUse)
		# Cursor 的 preToolUse 接受 ask 但不执行，等于静默放行；降级为 deny，宁可拦下。
		printf '{"permission":"deny","user_message":"%s","agent_message":"%s"}\n' \
			"$(jstack_json_escape "$reason")" "$(jstack_json_escape "$reason")"
		;;
	*)
		printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
			"$(jstack_json_escape "$reason")"
		;;
	esac
}

main
exit 0
