# 阶段门禁的共用部分，由同目录的 stage.sh 和插件的 hooks/*.sh source，不单独运行。
# 状态文件是 <状态目录>/<会话 id>，纯文本，每行一条：
#   path <逗号分隔的阶段>    stage <当前阶段>    evidence <文本>（可多行）
#   default <文本>（替用户采用的默认决定）    ask <问题>（存在即等人）
#   started / started_epoch / run / repo / ticket / ticket_explicit / size / asks / base（运行记录用的元数据）
# 合并后归档的待补清单是 <状态目录的上一级>/pending/<仓库 key>，每行 "<PR URL> <还剩什么>"，按仓库存、跨会话。
# 运行记录在 <状态目录的上一级>/runs：完成的任务一行一条 JSON；未完成的任务留在 runs/active/<会话 id>.json。
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

# 合并后归档待补清单的路径。key 取 git 公共目录（同一仓库的各个 worktree 共用一份），不在 git 仓库里时取当前目录。
jstack_pending_file() {
	local d=${JSTACK_REPO:-$PWD} root
	root=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || root=$d
	printf '%s/pending/%s\n' "$(dirname "$(jstack_state_dir)")" "$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
}

# 状态文件里键 $1 的第一个值。
jstack_get() { sed -n "s/^$1 //p" "$2" | head -1; }

# 状态文件里键 $1 的最后一个值（ticket 历史里最后一条就是当前票）。
jstack_get_last() { sed -n "s/^$1 //p" "$2" | tail -1; }

# 用 stdin 替换文件 $1：先写同目录的临时文件再 mv，读的一方不会看到半截文件。
jstack_replace() {
	local tmp
	tmp=$(mktemp "$1.XXXXXX") || return 1
	if cat >"$tmp" && mv "$tmp" "$1"; then return 0; fi
	rm -f "$tmp"
	return 1
}

# 运行记录根目录。和状态目录放在同一级，不跟随仓库提交。
jstack_run_root() {
	printf '%s/runs\n' "$(dirname "$(jstack_state_dir)")"
}

jstack_run_log() {
	printf '%s/runs.jsonl\n' "$(dirname "$(jstack_state_dir)")"
}

jstack_run_active() {
	case $1 in
	'' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	printf '%s/active/%s.json\n' "$(jstack_run_root)" "$1"
}

# JSON 字符串转义；状态里的证据和默认决定已折叠成单行，这里再兜底去掉换行和制表符。
jstack_run_escape() {
	printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 状态文件里所有 "<key> <文本>" 行，输出成 JSON 字符串数组。
jstack_run_json_list() {
	local key=$1 file=$2 line first=1
	printf '['
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		[ "$first" -eq 1 ] || printf ','
		first=0
		printf '"%s"' "$(jstack_run_escape "${line#"$key "}")"
	done < <(grep "^$key " "$file" 2>/dev/null || true)
	printf ']'
}

# 把 Markdown 报告编码成 JSON 字符串；换行写成 \n，保证运行记录仍是一行一个对象。
jstack_run_report_json() {
	local file=$1
	[ -f "$file" ] || { printf 'null'; return 0; }
	awk 'BEGIN { printf "\"" } {
		gsub(/\\/, "\\\\")
		gsub(/"/, "\\\"")
		gsub(/\t/, "\\t")
		gsub(/\r/, "\\r")
		printf "%s\\n", $0
	} END { printf "\"" }' "$file"
}

# 把状态文件序列化成一行 JSON。$2 是 completed 或 unfinished；$3 是结束时间，未完成时为空；
# $4 是可选 Markdown 报告文件，只在 completed 时读取。
jstack_run_json() {
	local file=$1 status=$2 ended=$3 report_file=${4:-}
	local run started started_epoch duration=null repo ticket ticket_explicit=false size asks needs=false
	local evidence defaults prs report=null base head premium=null now tickets session worktree
	run=$(jstack_get run "$file")
	started=$(jstack_get started "$file")
	started_epoch=$(jstack_get started_epoch "$file")
	repo=$(jstack_get repo "$file")
	ticket=$(jstack_get_last ticket "$file")
	case $(jstack_get ticket_explicit "$file") in 1 | true) ticket_explicit=true ;; esac
	size=$(jstack_get size "$file")
	asks=$(jstack_get asks "$file")
	base=$(jstack_get base "$file")
	session=$(basename "$file")
	worktree=$repo
	case $asks in
	'' | *[!0-9]*) asks=0 ;;
	esac
	if [ "$asks" -gt 0 ] || grep -q '^ask ' "$file"; then needs=true; fi
	case $started_epoch in
	'' | *[!0-9]*) ;;
	*)
		now=$(date +%s)
		duration=$((now - started_epoch))
		;;
	esac
	if [ -n "$repo" ] && [ "$repo" != - ]; then
		head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
	else
		head=
	fi
	case ${JSTACK_PREMIUM_TOKENS:-} in
	'' | *[!0-9]*) ;;
	*) premium=$JSTACK_PREMIUM_TOKENS ;;
	esac
	evidence=$(jstack_run_json_list evidence "$file")
	defaults=$(jstack_run_json_list default "$file")
	prs=$(jstack_run_json_list 'land pr' "$file")
	tickets=$(jstack_run_json_list ticket "$file")
	if [ "$status" = completed ] && [ -n "$report_file" ]; then
		report=$(jstack_run_report_json "$report_file")
	fi
	printf '{"run_id":"%s","status":"%s","started_at":"%s","ended_at":"%s","duration_s":%s,"repo":"%s","ticket":"%s","ticket_explicit":%s,"current_ticket":"%s","tickets":%s,"session":"%s","worktree":"%s","size":"%s","path":"%s","stage":"%s","asks":%s,"needs_human":%s,"evidence":%s,"defaults":%s,"prs":%s,"report":%s,"base":"%s","head":"%s","premium_tokens":%s}\n' \
		"$(jstack_run_escape "${run:--}")" "$status" \
		"$(jstack_run_escape "${started:--}")" "$(jstack_run_escape "$ended")" "$duration" \
		"$(jstack_run_escape "${repo:--}")" "$(jstack_run_escape "${ticket:--}")" "$ticket_explicit" \
		"$(jstack_run_escape "${ticket:--}")" "$tickets" \
		"$(jstack_run_escape "$session")" "$(jstack_run_escape "${worktree:--}")" \
		"$(jstack_run_escape "${size:--}")" \
		"$(jstack_run_escape "$(jstack_get path "$file")")" \
		"$(jstack_run_escape "$(jstack_get stage "$file")")" \
		"$asks" "$needs" "$evidence" "$defaults" "$prs" "$report" \
		"$(jstack_run_escape "${base:--}")" "$(jstack_run_escape "${head:--}")" "$premium"
}

# 更新未完成任务的快照；写不进去不影响门禁。
jstack_run_snapshot() {
	local file=$1 active
	active=$(jstack_run_active "$(basename "$file")") || return 0
	mkdir -p "$(dirname "$active")" 2>/dev/null || return 0
	jstack_run_json "$file" unfinished "" | jstack_replace "$active" || true
}

# 任务收尾：追加完成记录，再删掉活动快照，最后打印运行 ID。
jstack_run_finish() {
	local file=$1 report_file=${2:-} log active run
	log=$(jstack_run_log)
	run=$(jstack_get run "$file")
	mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
	jstack_run_json "$file" completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$report_file" >>"$log" || return 1
	active=$(jstack_run_active "$(basename "$file")") && rm -f "$active"
	printf '%s\n' "${run:--}"
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

# Return unmet, structured stage outputs (one diagnostic per line).
# An unscoped evidence line from an older session is intentionally insufficient.
# Hook and CLI call the same function so Stop and end cannot disagree.
jstack_gate_missing() {
    local file=$1 path stage repo
    [ -f "$file" ] || return 0
    path=$(jstack_get path "$file")
    stage=$(jstack_get stage "$file")
    [ -n "$path" ] && [ -n "$stage" ] || { echo "阶段状态缺少 path/stage"; return 0; }
    # Clarification and investigation may end a turn before execution starts.
    printf '%s\n' "$path" | tr ',' '\n' | awk -v s="$stage" '
        !($0 in i) { i[$0] = NR }
        END { exit !(("execute" in i) && (s in i) && i[s] >= i["execute"]) }
    ' || return 0
    case ",$path," in
    *,verify,*)
        grep -q '^evidence verify [^ ]' "$file" ||
            echo "verify 缺少本阶段的验证结果：先 enter verify，再 evidence \"<命令> -> <结果>\""
        ;;
    esac
    case ",$path," in
    *,review,*)
        grep -q '^review complete [^ ]' "$file" ||
            echo "review 缺少审查结论：先 enter review，再 review complete \"<结论>\""
        awk '
            /^review finding / { finding[$3] = 1 }
            /^review resolution / { resolved[$3] = 1 }
            END { for (id in finding) if (!(id in resolved))
                print "review 发现 " id " 尚未用 review resolution 记录 fixed/dismissed 及原因"
            }
        ' "$file"
        ;;
    esac
    case ",$path," in
    *,land,*)
        grep -Eq '^land commit [0-9a-fA-F]{7,64}$' "$file" ||
            echo "land 缺少 commit SHA：先 enter land，再 land commit <SHA>"
        repo=$PWD
        [ -z "${JSTACK_REPO:-}" ] || repo=$JSTACK_REPO
        if git -C "$repo" remote 2>/dev/null | grep -q .; then
            grep -Eq '^land pr https://[^ ]+' "$file" ||
                echo "land 缺少 PR URL：仓库有 remote，须在 land 阶段记录 land pr <URL>"
        fi
        ;;
    esac
}
