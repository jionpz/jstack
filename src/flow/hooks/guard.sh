#!/usr/bin/env bash
# PreToolUse hook（Bash）：命令命中 must-stop.md 的模式时，让 harness 先问用户。不看阶段状态，对所有会话生效。
# 命令在 ;、&&、||、|、换行处切段，每段对每条模式做 grep -E，报命令里最靠前的那一段命中的第一条。
# 没有 jq 时用整段输入做匹配，宁可多问。内部出错一律无输出地放行。
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

main() {
	local input tool cmd segs pats line hook rest re src hit_src= n best= hit= tab action reason cfg
	input=$(cat)
	tool=$(jstack_json_str tool_name "$input")
	[ -z "$tool" ] || [ "$tool" = Bash ] || return 0
	if ! jstack_has_jq || ! cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty | strings'); then
		cmd=$(printf '%s\n' "$input" | awk '{ gsub(/\\n/, "\n"); gsub(/\\t|"/, " "); print }')
	fi
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
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
		"$(jstack_json_escape "$reason")"
}

main
exit 0
