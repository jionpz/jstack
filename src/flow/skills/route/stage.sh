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
用法：stage.sh start [--size <XS|S|M|L|XL|Question>] <阶段>,<阶段>,...
                                      记录阶段路径并进入第一个阶段
      stage.sh enter <阶段>              进入路径上的某个阶段
      stage.sh size <XS|S|M|L|XL|Question> 更新任务规模
      stage.sh evidence <文本>           记录当前阶段证据；verify 证据写成 "<命令> -> <结果>"
      stage.sh review finding <ID> <说明>      在 review 阶段记录一条发现
      stage.sh review resolution <ID> fixed|dismissed <理由>   记录每条发现的处置
      stage.sh review complete <结论>         所有发现处理完后记录审查结论（允许零发现）
      stage.sh land commit <SHA>         在 land 阶段记录 commit
      stage.sh land pr <URL>             在 land 阶段记录 PR URL
      stage.sh default <文本>            记录一个替用户采用的默认决定，写成 "<决定> -> <理由>"
      stage.sh ask <具体问题>            排队一个问题；本轮回复必须包含该问题
      stage.sh end                       所需阶段产出齐全后写运行记录并删除会话记录
      stage.sh show                      打印当前记录
      stage.sh pending [<PR URL> <文本>]  记一条合并后归档待补（PR 还没合）；不带参数时列出本仓库的待补
      stage.sh settled <PR URL>          合并后归档做完，删掉这条待补
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

pending=$(jstack_pending_file)

need_state() { [ -f "$file" ] || die "还没有阶段记录，先运行 stage.sh start <阶段>,<阶段>,..."; }

cmd=${1:-}
[ $# -gt 0 ] && shift
# Extensions and tool hooks can mark a delegated worker. No worker may change
# the parent session state, even though it may inherit the parent session ID.
case $cmd in
start | enter | size | evidence | review | land | default | ask | end | pending | settled)
    [ -z "${JSTACK_SUBAGENT_ID:-}" ] || die "子代理不能修改主会话阶段记录；请将结果交给主会话"
    ;;
esac
case $cmd in
start)
	size=${JSTACK_SIZE:--}
	if [ "${1:-}" = --size ]; then
		[ $# -ge 3 ] && [ -n "$2" ] || usage
		size=$2
		shift 2
	fi
	[ $# -eq 1 ] && [ -n "$1" ] || usage
	case $size in
	- | XS | S | M | L | XL | Question) ;;
	*) die "未知任务规模：${size}（可用：XS、S、M、L、XL、Question）" ;;
	esac
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
	if [ -f "$file" ]; then
		[ "$(jstack_get path "$file")" != "$1" ] || { echo "jstack: 此路径已经启动，保留当前阶段与证据"; exit 0; }
		die "本会话已有未结束的阶段记录；先 stage.sh show，完成或处理原任务，不能 start 覆盖"
	fi
	mkdir -p "$dir"
	find "$dir" -type f -mmin +10080 -delete 2>/dev/null || true
	repo=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || repo=$(pwd -P)
	repo=$(cd "$repo" 2>/dev/null && pwd -P) || repo=$PWD
	branch=$(git -C "$PWD" branch --show-current 2>/dev/null || true)
	ticket=${JSTACK_TICKET:-}
	if [ -z "$ticket" ]; then
		ticket=$(printf '%s\n' "$branch" | sed -n 's/.*[Ii]ssue-\([0-9][0-9]*\).*/#\1/p')
	fi
	[ -n "$ticket" ] || ticket=${branch:--}
	ticket=$(printf '%s' "$ticket" | tr '\r\n' '  ')
	started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	started_epoch=$(date +%s)
	run=$(date -u +%Y%m%dT%H%M%SZ)-$sid
	base=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
	printf 'path %s\nstage %s\nstarted %s\nstarted_epoch %s\nrun %s\nrepo %s\nticket %s\nsize %s\nasks 0\nbase %s\n' \
		"$1" "${1%%,*}" "$started" "$started_epoch" "$run" "$repo" "$ticket" "$size" "${base:--}" |
		jstack_replace "$file"
	jstack_run_snapshot "$file"
	echo "jstack: 阶段路径 $(printf '%s' "$1" | sed 's/,/ → /g')，当前阶段 ${1%%,*}"
	# Workloop 没有 Stop hook：状态照记，但不能让人以为门禁在执行。
	if [ "$sid" = "${WORKLOOP_SESSION_ID:-}" ]; then
		echo "jstack: Workloop 没有 Stop hook，门禁未强制。结束前自己运行 stage.sh show 核对证据，并在收尾摘要的门禁一行写明“本会话阶段门禁未强制（Workloop）”"
	fi
	# 之前停在 PR-ready 的任务：PR 合并后的归档要在这里补上。
	if [ -s "$pending" ]; then
		echo "jstack: 本仓库有 $(grep -c . "$pending") 条合并后归档待补。逐条查 PR 状态：已合并就按 archive 的“合并后”一段做完并运行 stage.sh settled <PR URL>；没合并就留着，不要自己合并"
		sed 's/^/  /' "$pending"
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
	awk -v s="$1" '/^stage / { print "stage " s; next } /^ask / { next } s == "execute" && (/^evidence / || /^review / || /^land /) { next } { print }' "$file" | jstack_replace "$file"
	jstack_run_snapshot "$file"
	echo "jstack: 当前阶段 $1"
	;;
size)
	[ $# -eq 1 ] && [ -n "$1" ] || usage
	case $1 in
	XS | S | M | L | XL | Question) ;;
	*) die "未知任务规模：$1（可用：XS、S、M、L、XL、Question）" ;;
	esac
	need_state
	awk -v s="$1" 'BEGIN { done = 0 } /^size / { print "size " s; done = 1; next } { print } END { if (!done) print "size " s }' "$file" | jstack_replace "$file"
	jstack_run_snapshot "$file"
	echo "jstack: 任务规模 $1"
	;;
evidence)
	text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$text" ] || die "证据不能为空，写成 \"<命令> -> <结果>\""
	need_state
	stage=$(jstack_get stage "$file")
	{ cat "$file"; printf 'evidence %s %s\n' "$stage" "$text"; } | jstack_replace "$file"
	jstack_run_snapshot "$file"
	echo "jstack: 已记录 ${stage} 阶段证据：${text}"
	;;
review)
    [ $# -ge 2 ] || usage
    need_state
    [ "$(jstack_get stage "$file")" = review ] || die "先 enter review 再记录审查"
    kind=$1; shift
    case $kind in
    finding | resolution)
        [ $# -ge 2 ] || usage
        id=$1; shift
        case $id in '' | *[!a-zA-Z0-9_-]*) die "review finding ID 只能包含字母、数字、下划线和短横线" ;; esac
        if [ "$kind" = finding ]; then
            grep -q "^review finding $id " "$file" && die "review finding ID 已存在：$id"
        else
            grep -q "^review finding $id " "$file" || die "review finding 不存在：$id"
            action=$1; shift
            case $action in fixed | dismissed) ;; *) die "review resolution 必须是 fixed 或 dismissed" ;; esac
        fi
        ;;
    complete) ;;
    *) usage ;;
    esac
    text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$text" ] || die "review 结论或处置原因不能为空"
    case $kind in
    finding) entry="review finding $id $text" ;;
    resolution) entry="review resolution $id $action $text" ;;
    complete) entry="review complete $text" ;;
    esac
    { cat "$file"; printf '%s\n' "$entry"; } | jstack_replace "$file"
    jstack_run_snapshot "$file"
    echo "jstack: 已记录 $entry"
    ;;
land)
    [ $# -eq 2 ] || usage
    need_state
    [ "$(jstack_get stage "$file")" = land ] || die "先 enter land 再记录落地凭据"
    kind=$1 value=$2
    case $kind in
    commit)
        case $value in '' | *[!0-9a-fA-F]*) die "commit 必须是十六进制 SHA" ;; esac
        [ "${#value}" -ge 7 ] && [ "${#value}" -le 64 ] || die "commit SHA 长度不合法"
        ;;
    pr)
        case $value in https://*/*/pull/[0-9]* | https://*/*/merge_requests/[0-9]*) ;; *) die "PR URL 应指向 pull 或 merge_requests" ;; esac
        ;;
    *) usage ;;
    esac
    { cat "$file"; printf 'land %s %s\n' "$kind" "$value"; } | jstack_replace "$file"
    jstack_run_snapshot "$file"
    echo "jstack: 已记录 land ${kind}：${value}"
    ;;
default)
	text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$text" ] || die "默认决定不能为空，写成 \"<决定> -> <理由>\""
	need_state
	{ cat "$file"; printf 'default %s\n' "$text"; } | jstack_replace "$file"
	jstack_run_snapshot "$file"
	echo "jstack: 已记录默认决定：${text}"
	;;
ask)
    [ $# -gt 0 ] || usage
    need_state
    text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case $text in *\?* | *？*) ;; *) die "ask 必须包含一条具体问句（? 或 ？）" ;; esac
    if ! grep -qxF "ask $text" "$file"; then
        asks=$(jstack_get asks "$file")
        case $asks in
        '' | *[!0-9]*) asks=0 ;;
        esac
        asks=$((asks + 1))
        {
            awk -v n="$asks" 'BEGIN { done = 0 } /^asks / { if (!done) { print "asks " n; done = 1 } next } { print } END { if (!done) print "asks " n }' "$file"
            printf 'ask %s\n' "$text"
        } | jstack_replace "$file"
        jstack_run_snapshot "$file"
    fi
    echo "jstack: 已排队问题：${text}"
    ;;
end)
    [ $# -eq 0 ] || usage
    need_state
    missing=$(jstack_gate_missing "$file")
    [ -z "$missing" ] || die "阶段未完成，不能清除记录：$missing"
    jstack_run_finish "$file"
    rm -f "$file"
    echo "jstack: 已清除阶段记录"
    ;;
show)
	[ $# -eq 0 ] || usage
	if [ -f "$file" ]; then cat "$file"; else echo none; fi
	;;
pending)
	if [ $# -eq 0 ]; then
		if [ -s "$pending" ]; then cat "$pending"; else echo none; fi
	else
		text=$(printf '%s' "$*" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$text" ] || die "待补不能为空，写成 \"<PR URL> <还剩什么>\""
		mkdir -p "$(dirname "$pending")"
		{ [ ! -f "$pending" ] || awk -v u="${text%% *}" '$1 != u' "$pending"; printf '%s\n' "$text"; } | jstack_replace "$pending"
		echo "jstack: 已记录合并后归档待补：${text}"
	fi
	;;
settled)
	[ $# -eq 1 ] && [ -n "$1" ] || usage
	[ -s "$pending" ] && awk -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$pending" || die "待补清单里没有 $1"
	awk -v u="$1" '$1 != u' "$pending" | jstack_replace "$pending"
	[ -s "$pending" ] || rm -f "$pending"
	echo "jstack: 已清掉待补：$1"
	;;
*) usage ;;
esac
