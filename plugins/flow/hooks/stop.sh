#!/usr/bin/env bash
# Stop hook（Claude Code 的 Stop / Codex 的 Stop / Cursor 的 stop）：路径含 verify、已进入 execute 或之后的阶段、
# 却没有按阶段记录 verify、review、land 的产出时，拦下这次结束。因 stop hook 而继续的一轮、
# 标了具体问题且这次回复完整提出该问题、
# 没有状态文件时都放行。Cursor 的 stop 输入没有最后一条回复，ask 无法核对，只能凭排队问题放行。
# Codex 的输入与 Claude Code 同形（stop_hook_active、last_assistant_message 都有），走同一条分支。
# 内部出错一律无输出地放行。
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

# A queued human question must appear verbatim in the final assistant reply.
# A stray question mark cannot bypass verification.
asks_user() {
    local input=$1 file=$2 msg question
    msg=$(jstack_json_str last_assistant_message "$input")
    [ -n "$msg" ] || return 1
    while IFS= read -r question; do
        [ -n "$question" ] || continue
        case $msg in *"$question"*) return 0 ;; esac
    done < <(sed -n 's/^ask //p' "$file")
    return 1
}

main() {
	local input evt cursor=0 file st reason status loop_count missing cwd
	input=$(cat)
	evt=$(jstack_json_str hook_event_name "$input")
	jstack_cursor_defer "$0" stop && return 0
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
		grep -q '^ask [^ ]' "$file" && return 0
	else
		# ask 只在这次回复确实向用户提了问题时才放行，否则它就成了跳过验证的出口。
		grep -q '^ask [^ ]' "$file" && asks_user "$input" "$file" && return 0
	fi
    cwd=$(jstack_json_str cwd "$input")
    if [ -n "$cwd" ] && [ -z "${JSTACK_REPO:-}" ]; then
        cd "$cwd" 2>/dev/null || true
    fi
    missing=$(jstack_gate_missing "$file" stop | tr '\n' ';')
    [ -n "$missing" ] || return 0
    st="\"$route/stage.sh\""
    reason="jstack verify/review/land 门禁：以下阶段产出尚未齐全：${missing}。请按当前阶段进入并记录真实结果；执行 $st show 可查看现有状态。等待用户决定时先执行 $st ask \"<具体问题>\"，再在回复中完整提出该问题。"

	if [ "$cursor" -eq 1 ]; then
		printf '{"followup_message":"%s"}\n' "$(jstack_json_escape "$reason")"
	else
		printf '{"decision":"block","reason":"%s"}\n' "$(jstack_json_escape "$reason")"
	fi
}

main
exit 0
