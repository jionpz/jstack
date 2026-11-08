#!/usr/bin/env bash
# Stop hook（Claude Code 的 Stop / Cursor 的 stop）：路径含 verify、已进入 execute 或之后的阶段、
# 却没有一条验证证据时，拦下这次结束。因 stop hook 而继续的一轮、标了 ask 且这次回复确实向用户提问、
# 没有状态文件时都放行。Cursor 的 stop 输入没有最后一条回复，ask 无法核对，只能放行。
# 内部出错一律无输出地放行。
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

# 最后一条回复里有没有问号。没有 jq 时取 last_assistant_message 键之后的全部文本，宁可多放行一次也不误拦提问。
asks_user() {
	local msg
	if jstack_has_jq; then
		msg=$(printf '%s' "$1" | jq -r '.last_assistant_message // empty | strings')
	else
		msg=$(printf '%s' "$1" | tr '\n' ' ' | sed -n 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"//p')
	fi
	case $msg in
	*'?'* | *'？'*) return 0 ;;
	esac
	return 1
}

main() {
	local input evt cursor=0 file path stage st reason status loop_count
	input=$(cat)
	evt=$(jstack_json_str hook_event_name "$input")
	if [ "$evt" = stop ]; then cursor=1; fi
	if [ "$cursor" -eq 0 ]; then
		jstack_json_true stop_hook_active "$input" && return 0
	fi
	file=$(jstack_state_file "$(jstack_hook_sid "$input")") && [ -f "$file" ] || return 0
	if [ "$cursor" -eq 1 ]; then
		# 只有正常结束才拦；用户中断或出错时不追加消息。
		status=$(jstack_json_str status "$input")
		[ "$status" = completed ] || return 0
		# hooks.cursor.json 里的 loop_limit 也会让 Cursor 跳过，这里再兜一层。
		loop_count=$(jstack_json_num loop_count "$input")
		case $loop_count in
		'' | *[!0-9]*) ;;
		*) [ "$loop_count" -ge 3 ] && return 0 ;;
		esac
		# Cursor 的 stop 输入没有最后一条回复，无法核对是否真的向用户提问；标了 ask 就放行。
		grep -qx ask "$file" && return 0
	else
		# ask 只在这次回复确实向用户提了问题时才放行，否则它就成了跳过验证的出口。
		grep -qx ask "$file" && asks_user "$input" && return 0
	fi
	grep -q '^evidence ' "$file" && return 0
	path=$(jstack_get path "$file")
	stage=$(jstack_get stage "$file")
	printf '%s\n' "$path" | tr ',' '\n' | awk -v s="$stage" '
		!($0 in i) { i[$0] = NR }
		END { exit !(("verify" in i) && ("execute" in i) && (s in i) && i[s] >= i["execute"]) }
	' || return 0
	st="\"$route/stage.sh\""
	reason="jstack verify 门禁：当前阶段 ${stage}，还没有记录验证证据，不能结束。在真实表面上运行检查，再用 $st evidence \"<命令> -> <结果>\" 记录。只有停下来向用户提问时才运行 $st ask，并且要在回复里写出问题；ask 不能代替验证。"
	if [ "$cursor" -eq 1 ]; then
		printf '{"followup_message":"%s"}\n' "$(jstack_json_escape "$reason")"
	else
		printf '{"decision":"block","reason":"%s"}\n' "$(jstack_json_escape "$reason")"
	fi
}

main
exit 0
