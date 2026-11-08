# 阶段门禁的共用部分，由同目录的 stage.sh 和插件的 hooks/*.sh source，不单独运行。
# 状态文件是 <状态目录>/<会话 id>，纯文本，每行一条：
#   path <逗号分隔的阶段>    stage <当前阶段>    evidence <文本>（可多行）    ask（存在即等人）
# JSTACK_NO_JQ 非空时当作没有 jq，只用于测试 sed 退路。

jstack_state_dir() {
	printf '%s\n' "${JSTACK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jstack/sessions}"
}

# 会话 id 要当文件名用，只接受这些字符。
jstack_state_file() {
	case $1 in
	'' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	printf '%s/%s\n' "$(jstack_state_dir)" "$1"
}

# 状态文件里键 $1 的第一个值。
jstack_get() { sed -n "s/^$1 //p" "$2" | head -1; }

# 用 stdin 替换文件 $1：先写同目录的临时文件再 mv，读的一方不会看到半截文件。
jstack_replace() {
	local tmp
	tmp=$(mktemp "$1.XXXXXX") || return 1
	if cat >"$tmp" && mv "$tmp" "$1"; then return 0; fi
	rm -f "$tmp"
	return 1
}

# stages.md 的 Stages 表，每行"阶段<TAB>产出<TAB>门禁"。
jstack_stage_rows() {
	awk -F'|' '
		/^## / { sec = ($0 ~ /^## Stages[ \t]*$/); next }
		!sec { next }
		/^\|/ { rows++ }
		rows && !/^\|/ { exit }
		!/^\|/ || rows == 1 || /^\|[-:| \t]+$/ { next }
		{
			for (i = 2; i <= 4; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
			print $2 "\t" $3 "\t" $4
		}
	' "$1"
}

jstack_has_jq() { [ -z "${JSTACK_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; }

# hook 输入 $2 里顶层字符串字段 $1 的值。
jstack_json_str() {
	if jstack_has_jq; then
		printf '%s' "$2" | jq -r --arg k "$1" '.[$k] // empty | strings'
	else
		printf '%s' "$2" | tr '\n' ' ' | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" | head -1
	fi
}

# hook 输入 $2 里顶层字段 $1 是否为 true。
jstack_json_true() {
	if jstack_has_jq; then
		printf '%s' "$2" | jq -e --arg k "$1" '.[$k] == true' >/dev/null
	else
		printf '%s' "$2" | tr '\n' ' ' | grep -qE "\"$1\"[[:space:]]*:[[:space:]]*true"
	fi
}

# hook 的会话 id：先取输入里的 session_id，取不到再用 CLAUDE_CODE_SESSION_ID。
jstack_hook_sid() {
	local sid
	sid=$(jstack_json_str session_id "$1")
	printf '%s\n' "${sid:-${CLAUDE_CODE_SESSION_ID:-}}"
}

jstack_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
