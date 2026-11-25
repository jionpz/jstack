#!/usr/bin/env bash
# PreToolUse hook for Claude Code, Codex, Cursor, Pi, and OMP.
# It checks shell commands against must-stop.md, and edit/write/patch tools against
# the same file's path patterns. A hit asks when the harness supports it; Codex,
# Cursor preToolUse, and headless Pi/OMP deny. Internal errors pass through.
exec 2>/dev/null
route=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/skills/route
. "$route/lib.sh" || exit 0

tab=$(printf '\t')

json_command() {
	local input=$1
	if jstack_has_jq; then
		printf '%s' "$input" | jq -r '.tool_input.command // empty | strings'
	else
		printf '%s' "$input" | tr '\n' ' ' |
			sed -nE 's/.*"tool_input"[[:space:]]*:[[:space:]]*\{[^}]*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' |
			head -1 | jstack_json_unescape
	fi
}

json_paths() {
	local input=$1
	if jstack_has_jq; then
		printf '%s' "$input" | jq -r '
			(.tool_input // {}) as $i |
			if ($i | type) == "object" then
				(($i["file_path"]? // empty) | strings),
				(($i["path"]? // empty) | strings),
				(($i["notebook_path"]? // empty) | strings)
			else empty end'
	else
		printf '%s' "$input" | tr '\n' ' ' |
			grep -oE '"(file_path|path|notebook_path)"[[:space:]]*:[[:space:]]*"[^"]*"' |
			sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//' || true
	fi
}

json_patch() {
	local input=$1
	if jstack_has_jq; then
		printf '%s' "$input" | jq -r '
			(.tool_input // empty) as $i |
			if ($i | type) == "string" then $i
			elif ($i | type) == "object" then (($i["input"]? // $i["patch"]? // empty) | strings)
			else empty end'
	else
		printf '%s' "$input" | tr '\n' ' ' |
			sed -nE 's/.*"(input|patch)"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\2/p' | head -1 |
			jstack_json_unescape
	fi
}

patch_paths() {
	printf '%s\n' "$1" |
		sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.*)$/\2/p; s/^\*\*\* Move to: (.*)$/\1/p' |
		sed -E 's/[[:space:]]+$//'
}

normalize_path() {
	local path=$1
	path=$(printf '%s' "$path" | tr '\\' '/')
	path=${path#file://}
	case $path in
	"~/"*) path=$HOME/${path#\~/} ;;
	esac
	path=${path#./}
	printf '%s\n' "$path"
}

path_matches() {
	local path=$1 re=$2 allow=${3:-}
	printf '%s\n' "$path" | grep -Eq -- "$re" || return 1
	if [ -n "$allow" ] && printf '%s\n' "$path" | grep -Eq -- "$allow"; then
		return 1
	fi
	return 0
}

builtin_action() {
	awk -F'|' -v h="\`$1\`" '
		/^## / { sec = ($0 ~ /^## Must stop[ \t]*$/); next }
		sec && /^\|/ {
			a = $2; k = $3
			gsub(/^[ \t]+|[ \t]+$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", k)
			if (k == h) { print a; exit }
		}
	' "$route/must-stop.md"
}

reason_for() {
	local hit=$1 src=$2 cfg action
	if [ "$src" = repo ]; then
		cfg=$(jstack_repo_config) || cfg=
		action=
		[ -z "$cfg" ] || action=$(jq -r --arg h "$hit" \
			'(.must_stop // [])[] | select((.hook // .action) == $h) | .action // empty' "$cfg" 2>/dev/null | head -1)
		printf 'jstack must-stop: %s（仓库追加）. Confirm before it runs.\n' "${action:-$hit}"
		return 0
	fi
	action=$(builtin_action "$hit")
	printf 'jstack must-stop: %s. Confirm before it runs.\n' "${action:-$hit}"
}

emit_result() {
	local reason=$1 decision=$2
	case $evt in
	beforeShellExecution)
		printf '{"permission":"%s","user_message":"%s","agent_message":"%s"}\n' \
			"$decision" "$(jstack_json_escape "$reason")" "$(jstack_json_escape "$reason")"
		;;
	preToolUse)
		# Cursor 的 preToolUse 接受 ask 但不执行，等于静默放行；降级为 deny。
		printf '{"permission":"deny","user_message":"%s","agent_message":"%s"}\n' \
			"$(jstack_json_escape "$reason")" "$(jstack_json_escape "$reason")"
		;;
	*)
		if [ "$decision" = deny ] || jstack_is_codex "$input"; then
			printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
				"$(jstack_json_escape "$reason")"
		else
			printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
				"$(jstack_json_escape "$reason")"
		fi
		;;
	esac
}

is_shell_tool() {
	case $1 in
	'' | Bash | bash | Shell | shell) return 0 ;;
	esac
	return 1
}

is_edit_tool() {
	case $1 in
	Write | write | Edit | edit | MultiEdit | multiedit | multi_edit | NotebookEdit | notebook_edit | \
		apply_patch | applyPatch | apply-patch | create_file | write_file | edit_file | replace_in_file) return 0 ;;
	esac
	return 1
}

builtin_patterns() {
	awk '/^```patterns[ \t]*$/ { f = 1; next } f && /^```/ { exit } f && NF' "$route/must-stop.md" |
		awk -F'\t' 'NF >= 2 {
			scope = ($3 == "full" ? "full" : "segment")
			print $1 "\t" $2 "\t" scope "\tbuiltin"
		}'
}

builtin_path_patterns() {
	awk '/^```path-patterns[ \t]*$/ { f = 1; next } f && /^```/ { exit } f && NF' "$route/must-stop.md" |
		awk -F'\t' 'NF >= 2 { print $1 "\t" $2 "\t" $3 "\tbuiltin" }'
}

git_add_tokens() {
	printf '%s\n' "$1" | awk '
		{
			s = $0
			if (!match(s, /(^|[[:space:]\/])git[[:space:]]+add[[:space:]]+/)) next
			s = substr(s, RSTART + RLENGTH)
			n = split(s, a, /[[:space:]]+/)
			for (i = 1; i <= n; i++) {
				t = a[i]
				if (t != "" && t !~ /^-/) print t
			}
		}'
}

shell_staged_secret_hit() {
	local segs=$1 builtin_paths repo_paths n=0 seg token line hook re allow rest
	builtin_paths=$(builtin_path_patterns) || builtin_paths=
	repo_paths=$(jstack_cfg_path_patterns 2>/dev/null) || repo_paths=
	while IFS= read -r seg; do
		n=$((n + 1))
		printf '%s\n' "$seg" | grep -Eq '(^|[[:space:]/])git[[:space:]]+add([[:space:]]|$)' || continue
		while IFS= read -r token; do
			[ -n "$token" ] || continue
			token=${token#\"}; token=${token%\"}
			token=${token#\'}; token=${token%\'}
			token=$(normalize_path "$token")
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				hook=${line%%"$tab"*}; rest=${line#*"$tab"}
				re=${rest%%"$tab"*}; rest=${rest#*"$tab"}
				allow=${rest%%"$tab"*}
				if path_matches "$token" "$re" "$allow"; then
					printf '%s\tbuiltin\tstage-secret\n' "$n"
					return 0
				fi
			done <<<"$builtin_paths"
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				hook=${line%%"$tab"*}; rest=${line#*"$tab"}
				re=${rest%%"$tab"*}; rest=${rest#*"$tab"}
				allow=${rest%%"$tab"*}
				if path_matches "$token" "$re" "$allow"; then
					printf '%s\trepo\t%s\n' "$n" "$hook"
					return 0
				fi
			done <<<"$repo_paths"
		done <<<"$(git_add_tokens "$seg")"
	done <<<"$segs"
}

match_shell() {
	local cmd=$1 segs builtin_segs= match_segs pats line hook re rest scope src n best_n= hit= hit_src= stage= stage_n stage_src stage_hit reason
	segs=$(printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||[;|]/, "\n"); print }')
	if jstack_has_jq; then
		builtin_segs=$(printf '%s\n' "$cmd" | awk -f "$route/../../hooks/literal-command.awk") || builtin_segs=
	fi
	pats=$(
		builtin_patterns
		if repo_pats=$(jstack_cfg_patterns 2>/dev/null); then
			printf '%s\n' "$repo_pats" |
				awk -F'\t' 'NF >= 2 { print $1 "\t" $2 "\tsegment\trepo" }'
		fi
	)
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		hook=${line%%"$tab"*}; rest=${line#*"$tab"}
		re=${rest%%"$tab"*}; rest=${rest#*"$tab"}
		scope=${rest%%"$tab"*}; rest=${rest#*"$tab"}
		src=${rest%%"$tab"*}; [ -n "$src" ] || src=${rest#*"$tab"}
		[ -n "$hook" ] && [ "$re" != "$rest" ] || continue
		if [ "$scope" = full ]; then
			printf '%s\n' "${builtin_segs:-$cmd}" | grep -Eq -- "$re" || continue
			n=1
		else
			match_segs=$segs
			[ "$src" != builtin ] || match_segs=${builtin_segs:-$segs}
			n=$(printf '%s\n' "$match_segs" | grep -nE -- "$re" | head -1 | cut -d: -f1)
			[ -n "$n" ] || continue
		fi
		if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then
			best_n=$n
			hit=$hook
			hit_src=$src
		fi
	done <<<"$pats"
	if [ -z "$builtin_segs" ]; then
		stage=$(shell_staged_secret_hit "$segs") || stage=
	fi
	if [ -n "$stage" ]; then
		stage_n=${stage%%"$tab"*}; rest=${stage#*"$tab"}
		stage_src=${rest%%"$tab"*}; stage_hit=${rest#*"$tab"}
		if [ -z "$best_n" ] || [ "$stage_n" -lt "$best_n" ]; then
			best_n=$stage_n
			hit=$stage_hit
			hit_src=$stage_src
		fi
	fi
	[ -n "$hit" ] || return 0
	reason=$(reason_for "$hit" "$hit_src")
	emit_result "$reason" ask
}

match_edit() {
	local paths patch builtin_paths repo_paths line hook re allow rest path reason
	paths=$(json_paths "$input") || paths=
	patch=$(json_patch "$input") || patch=
	if [ -n "$patch" ]; then
		paths=$paths$'\n'$(patch_paths "$patch")
	fi
	builtin_paths=$(builtin_path_patterns) || builtin_paths=
	repo_paths=$(jstack_cfg_path_patterns 2>/dev/null) || repo_paths=
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		path=$(normalize_path "$path")
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			hook=${line%%"$tab"*}; rest=${line#*"$tab"}
			re=${rest%%"$tab"*}; rest=${rest#*"$tab"}
			allow=${rest%%"$tab"*}
			path_matches "$path" "$re" "$allow" || continue
			reason=$(reason_for "$hook" builtin)
			emit_result "$reason" ask
			return 0
		done <<<"$builtin_paths"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			hook=${line%%"$tab"*}; rest=${line#*"$tab"}
			re=${rest%%"$tab"*}; rest=${rest#*"$tab"}
			allow=${rest%%"$tab"*}
			path_matches "$path" "$re" "$allow" || continue
			reason=$(reason_for "$hook" repo)
			emit_result "$reason" ask
			return 0
		done <<<"$repo_paths"
	done <<<"$paths"
}

main() {
	local input evt tool cmd kind= reason
	input=$(cat)
	evt=$(jstack_json_str hook_event_name "$input")
	case $evt in
	beforeShellExecution)
		kind=shell
		cmd=$(jstack_json_str command "$input")
		;;
	preToolUse)
		tool=$(jstack_json_str tool_name "$input")
		if is_shell_tool "$tool"; then
			kind=shell
			cmd=$(json_command "$input")
		elif is_edit_tool "$tool"; then
			kind=edit
		else
			return 0
		fi
		;;
	*)
		tool=$(jstack_json_str tool_name "$input")
		if is_shell_tool "$tool"; then
			kind=shell
			cmd=$(json_command "$input")
		elif is_edit_tool "$tool"; then
			kind=edit
		else
			return 0
		fi
		;;
	esac
	if [ "$kind" = shell ]; then
		[ -n "$cmd" ] || return 0
		# Claude Code's PreToolUse payload includes agent_id for subagents. Deny only
		# stage state mutations; read-only stage.sh show remains available. This is
		# best-effort protection, not a sandbox.
		if [ -n "$(jstack_json_str agent_id "$input")" ] &&
			printf '%s\n' "$cmd" | grep -Eq 'stage\.sh[^;&|]*(start|enter|evidence|verify|review|land|default|ask|end|pending|settled)([[:space:]]|$)'; then
			reason="jstack: 子代理不可修改主会话阶段记录；将验证、审查和落地结果交还主会话记录。"
			emit_result "$reason" deny
			return 0
		fi
		match_shell "$cmd"
		return 0
	fi
	match_edit
}

main
exit 0
