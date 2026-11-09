#!/usr/bin/env bash
# 记录当前任务走到 stages.md 的哪个阶段，供 flow 插件的 hooks / 扩展执行门禁。状态文件格式见 lib.sh。
# 会话 id 依次取 JSTACK_SESSION_ID（flow 的 OMP 扩展）、PI_SESSION_ID（Pi）、
# CLAUDE_CODE_SESSION_ID（Claude Code）、CURSOR_CONVERSATION_ID（Cursor）、
# CODEX_SESSION_ID（Codex）、WORKLOOP_SESSION_ID（Workloop）；没有它的 harness 里打印一行说明，什么也不做。
# JSTACK_STAGES_FILE 可覆盖阶段表的路径，只用于测试。
# 变量后紧跟中文标点时必须写成 ${VAR}：macOS 的 bash 3.2 在 UTF-8 locale 下会把标点首字节算进变量名。
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
stages=${JSTACK_STAGES_FILE:-$here/stages.md}
[ -n "${JSTACK_STAGES_FILE:-}" ] || stages=$(jstack_stages_path "$stages")

usage() {
	cat >&2 <<'EOF'
用法：stage.sh start <阶段>,<阶段>,...   记录阶段路径并进入第一个阶段
      stage.sh enter <阶段>              进入路径上的某个阶段
      stage.sh evidence <文本>           记录一条验证证据，写成 "<命令> -> <结果>"
      stage.sh default <文本>            记录一个替用户采用的默认决定，写成 "<决定> -> <理由>"
      stage.sh ask                       停下来问用户之前运行
      stage.sh end                       任务结束，删掉记录
      stage.sh show                      打印当前记录
EOF
	exit 2
}
die() { printf 'jstack: %s\n' "$*" >&2; exit 1; }

sid=${JSTACK_SESSION_ID:-${PI_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CURSOR_CONVERSATION_ID:-${CODEX_SESSION_ID:-${WORKLOOP_SESSION_ID:-}}}}}}
if [ -z "$sid" ]; then
	echo "jstack: 这个 harness 没有会话 id，阶段门禁不生效"
	exit 0
fi
file=$(jstack_state_file "$sid") || { echo "jstack: 会话 id ${sid} 不能用作文件名，阶段门禁不生效"; exit 0; }
dir=$(dirname "$file")

need_state() { [ -f "$file" ] || die "还没有阶段记录，先运行 stage.sh start <阶段>,<阶段>,..."; }

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
start)
	[ $# -eq 1 ] && [ -n "$1" ] || usage
	[ -f "$stages" ] || die "找不到阶段表 ${stages}"
	known=$(jstack_stage_rows "$stages" | cut -f1)
	[ -n "$known" ] || die "阶段表 ${stages} 里没有解析出任何阶段"
	printf '%s\n' "$known" | grep -qx execute || die "阶段表 ${stages} 缺少 execute 阶段"
	bad=
	old_ifs=$IFS
	IFS=,
	set -f
	for s in $1; do
		printf '%s\n' "$known" | grep -qxF -- "$s" || bad="${bad:+$bad, }${s:-（空）}"
	done
	set +f
	IFS=$old_ifs
	[ -z "$bad" ] || die "不是 stages.md 里的阶段：${bad}。可用的阶段：$(echo $known)"
	mkdir -p "$dir"
	find "$dir" -type f -mmin +10080 -delete 2>/dev/null || true
	printf 'path %s\nstage %s\n' "$1" "${1%%,*}" | jstack_replace "$file"
	echo "jstack: 阶段路径 $(printf '%s' "$1" | sed 's/,/ → /g')，当前阶段 ${1%%,*}"
	# Workloop 没有 Stop hook：状态照记，但不能让人以为门禁在执行。
	if [ "$sid" = "${WORKLOOP_SESSION_ID:-}" ]; then
		echo "jstack: Workloop 没有 Stop hook，门禁未强制。结束前自己运行 stage.sh show 核对证据，并在收尾摘要的门禁一行写明“本会话阶段门禁未强制（Workloop）”"
	fi
	;;
enter)
	[ $# -eq 1 ] && [ -n "$1" ] || usage
	need_state
	path=$(jstack_get path "$file")
	case ",$path," in
	*",$1,"*) ;;
	*) die "阶段 $1 不在路径 ${path} 上" ;;
	esac
	# 每次进入 execute 是一个新的工作单元（L 路径的下一张 ticket），之前的证据不再算数。
	awk -v s="$1" '/^stage / { print "stage " s; next } $0 == "ask" { next } s == "execute" && /^evidence / { next } { print }' "$file" | jstack_replace "$file"
	echo "jstack: 当前阶段 $1"
	;;
evidence)
	text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$text" ] || die "证据不能为空，写成 \"<命令> -> <结果>\""
	need_state
	{ cat "$file"; printf 'evidence %s\n' "$text"; } | jstack_replace "$file"
	echo "jstack: 已记录证据：${text}"
	;;
default)
	text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$text" ] || die "默认决定不能为空，写成 \"<决定> -> <理由>\""
	need_state
	{ cat "$file"; printf 'default %s\n' "$text"; } | jstack_replace "$file"
	echo "jstack: 已记录默认决定：${text}"
	;;
ask)
	[ $# -eq 0 ] || usage
	need_state
	grep -qx ask "$file" || { cat "$file"; echo ask; } | jstack_replace "$file"
	echo "jstack: 已标记为等待用户回答"
	;;
end)
	[ $# -eq 0 ] || usage
	rm -f "$file"
	echo "jstack: 已清除阶段记录"
	;;
show)
	[ $# -eq 0 ] || usage
	if [ -f "$file" ]; then cat "$file"; else echo none; fi
	;;
*) usage ;;
esac
