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

# hook 输入 $2 里顶层数字字段 $1 的值（转成字符串）。
jstack_json_num() {
	if jstack_has_jq; then
		printf '%s' "$2" | jq -r --arg k "$1" '.[$k] // empty | tostring'
	else
		printf '%s' "$2" | tr '\n' ' ' | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/p" | head -1
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

# hook 的会话 id：Claude Code 是 session_id，Cursor 是 conversation_id；
# 输入里没有时依次看 shell 环境：JSTACK_SESSION_ID（flow 的 OMP 扩展写入进程环境）、
# PI_SESSION_ID（Pi 的 bash 工具注入）、CLAUDE_CODE_SESSION_ID、CURSOR_CONVERSATION_ID。
# Cursor 的会话 id 是 UUID，它的 shell 环境变量只做 URI 编码，UUID 原样保留，两边值一致。
jstack_hook_sid() {
	local sid
	sid=$(jstack_json_str session_id "$1")
	[ -n "$sid" ] || sid=$(jstack_json_str conversation_id "$1")
	printf '%s\n' "${sid:-${JSTACK_SESSION_ID:-${PI_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CURSOR_CONVERSATION_ID:-${CODEX_SESSION_ID:-${WORKLOOP_SESSION_ID:-}}}}}}}"
}

# Codex 的 hook 输入带 turn_id（Claude Code / Cursor 都没有），用来区分输出协议：
# Codex 的 PreToolUse 不认 ask，必须改成 deny；UserPromptSubmit 要输出 hookSpecificOutput。
jstack_is_codex() { [ -n "$(jstack_json_str turn_id "$1")" ]; }

jstack_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 仓库根：JSTACK_REPO 优先；否则从当前目录向上，遇到 .jstack/config.json 或 .git 停。
jstack_repo_root() {
	local d=${JSTACK_REPO:-$PWD}
	[ -n "$d" ] || return 1
	while :; do
		[ -f "$d/.jstack/config.json" ] && { printf '%s\n' "$d"; return 0; }
		[ -d "$d/.git" ] && { printf '%s\n' "$d"; return 0; }
		[ "$d" = / ] && return 1
		d=$(dirname "$d")
	done
}

# 仓库级配置的路径；没有配置文件时返回 1。
jstack_repo_config() {
	local root
	root=$(jstack_repo_root) || return 1
	[ -f "$root/.jstack/config.json" ] || return 1
	printf '%s\n' "$root/.jstack/config.json"
}

# 用 jq 表达式读仓库级配置；没有 jq 或没有配置时返回 1。
jstack_cfg() {
	local cfg
	jstack_has_jq || return 1
	cfg=$(jstack_repo_config) || return 1
	jq -r "$1" "$cfg" 2>/dev/null
}

# 配置读不了时给提示注入用的一行警告；正常时不输出。
jstack_config_warning() {
	local cfg
	cfg=$(jstack_repo_config) || return 0
	if ! jstack_has_jq; then
		printf '仓库配置 %s 需要 jq，当前没有 jq，追加项未生效\n' "$cfg"
	elif ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
		printf '仓库配置 %s 不是合法的 JSON 对象，追加项未生效\n' "$cfg"
	fi
}

# 阶段表路径：仓库配置里的 stages_file 优先，否则用 $1。相对路径按仓库根解析。
jstack_stages_path() {
	local root f
	root=$(jstack_repo_root) || { printf '%s\n' "$1"; return 0; }
	f=$(jstack_cfg '.stages_file // empty') || { printf '%s\n' "$1"; return 0; }
	[ -n "$f" ] || { printf '%s\n' "$1"; return 0; }
	case $f in
	/*) printf '%s\n' "$f" ;;
	*) printf '%s\n' "$root/$f" ;;
	esac
}

# 仓库级配置里要注入提示的项，每行 "键=值"；没有配置或都取默认值时无输出。
jstack_cfg_summary() {
	jstack_cfg '
		(if (.stages_file // "") != "" then "阶段表=" + .stages_file else empty end),
		(if (.tracker.type // "") != "" then "tracker=" + .tracker.type else empty end),
		(if (.verify.command // "") != "" then "验证命令=" + .verify.command else empty end),
		((.must_stop // []) | length) as $m |
			(if $m > 0 then "must-stop 追加=" + ($m | tostring) + " 条" else empty end)
	'
}

# 仓库追加的 must-stop 命令模式，每行 "hook<TAB>正则"。
# 用 \u0001 拼字段再换成 TAB：@tsv 会把正则里的反斜杠再转义一次。
jstack_cfg_patterns() {
	jstack_cfg '(.must_stop // [])[] | select(.regex != null and .regex != "") |
		"\(.hook // .action // "repo")\u0001\(.regex)"' | tr '\001' '\t'
}
