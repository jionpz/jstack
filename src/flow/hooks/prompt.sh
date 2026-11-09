#!/usr/bin/env bash
# UserPromptSubmit hook（Claude Code / Codex）/ beforeSubmitPrompt（Cursor）：用户回话时，
# 把当前阶段、它的产出和门禁、stage.sh 的用法注入上下文，并清掉 ask。
# 没有状态文件就不输出。内部出错一律无输出地放行，hook 不能卡住用户。
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

# <文本> <协议>：Claude Code 直接输出文本，Cursor 放进 additional_context，
# Codex 放进 hookSpecificOutput.additionalContext。
emit() {
	if [ "$2" = cursor ]; then
		if jstack_has_jq; then
			printf '%s' "$1" | jq -Rs '{continue: true, additional_context: .}'
		else
			printf '{"continue":true,"additional_context":"%s"}\n' \
				"$(jstack_json_escape "$(printf '%s' "$1" | tr '\n' ' ')")"
		fi
	elif [ "$2" = codex ]; then
		if jstack_has_jq; then
			printf '%s' "$1" | jq -Rs '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}'
		else
			printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
				"$(jstack_json_escape "$(printf '%s' "$1" | tr '\n' ' ')")"
		fi
	else
		printf '%s\n' "$1"
	fi
}

main() {
	local input evt proto=claude file path stage row next arrow n st cfg warn stages text
	input=$(cat)
	evt=$(jstack_json_str hook_event_name "$input")
	if [ "$evt" = beforeSubmitPrompt ]; then
		proto=cursor
	elif jstack_is_codex "$input"; then
		proto=codex
	fi
	warn=$(jstack_config_warning)
	file=$(jstack_state_file "$(jstack_hook_sid "$input")") && [ -f "$file" ] || {
		[ -z "$warn" ] || emit "$warn" "$proto"
		return 0
	}
	if grep -qx ask "$file"; then
		grep -vx ask "$file" | jstack_replace "$file" || return 0
	fi
	path=$(jstack_get path "$file")
	stage=$(jstack_get stage "$file")
	[ -n "$path" ] && [ -n "$stage" ] || return 0
	stages=$(jstack_stages_path "$route/stages.md")
	row=$(jstack_stage_rows "$stages" | awk -F'\t' -v s="$stage" '$1 == s { print; exit }')
	next=$(printf '%s\n' "$path" | tr ',' '\n' | awk -v s="$stage" 'f { print; exit } $0 == s { f = 1 }')
	arrow=$(printf '%s\n' "$path" | tr ',' '\n' |
		awk -v s="$stage" '{ printf "%s%s", (NR > 1 ? " → " : ""), ($0 == s ? "[" $0 "]" : $0) }')
	n=$(grep -c '^evidence ' "$file")
	st="\"$route/stage.sh\""
	text=$(
		printf '%s\n' "jstack 阶段门禁：当前阶段 ${stage}" \
			"路径：${arrow}" \
			"本阶段产出：$(printf '%s' "$row" | cut -f2)" \
			"本阶段门禁：$(printf '%s' "$row" | cut -f3)" \
			"已记录验证证据：${n} 条" \
			"下一阶段：${next:-无，这是路径上的最后一个阶段}"
		[ -z "$next" ] || echo "门禁满足后运行 $st enter ${next}"
		printf '%s\n' "每条验证证据运行 $st evidence \"<命令> -> <结果>\"" \
			"停下来问用户之前运行 $st ask，并在回复里写出要问的问题（只标 ask 不提问，Stop 门禁仍会拦）" \
			"任务结束运行 $st end"
		cfg=$(jstack_cfg_summary 2>/dev/null) || cfg=
		[ -z "$cfg" ] || printf '%s\n' "仓库配置：$(printf '%s' "$cfg" | tr '\n' ' ' | sed 's/ $//')"
		[ -z "$warn" ] || printf '%s\n' "$warn"
	)
	emit "$text" "$proto"
}

main
exit 0
