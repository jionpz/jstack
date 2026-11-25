#!/usr/bin/env bash
# flow 插件阶段门禁的测试：对构建产物 plugins/flow 运行 stage.sh 和三个 hook，喂 JSON、断言输出和状态文件。
# 每项打印一行 ✓ 或 ✗，有 ✗ 时 exit 1。./jstack check 用 /bin/bash 跑它，顺带确认兼容 macOS 的 bash 3.2：
# 脚本都用当前解释器 $BASH 运行，而不是各自的 shebang。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset JSTACK_SESSION_ID PI_SESSION_ID CLAUDE_CODE_SESSION_ID CURSOR_CONVERSATION_ID CODEX_SESSION_ID WORKLOOP_SESSION_ID JSTACK_NO_JQ JSTACK_STAGES_FILE
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/flow" JSTACK_STATE_DIR="$T/state"
SID=test-session-0001
ST="$CLAUDE_PLUGIN_ROOT/skills/route/stage.sh"
H="$CLAUDE_PLUGIN_ROOT/hooks"
STATE="$JSTACK_STATE_DIR/$SID"
fails=0

t() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then echo "✓ $name"; else echo "✗ $name"; fails=$((fails + 1)); fi
}
state_body() { sed -E '/^(started|started_epoch|run|repo|ticket|ticket_explicit|size|asks|base|visited) /d' "$STATE"; }
state_is() { [ "$(state_body)" = "$(printf '%s\n' "$@")" ]; }
stage() { CLAUDE_CODE_SESSION_ID=$SID "$BASH" "$ST" "$@"; }
hook() { printf '%s' "$2" | "$BASH" "$H/$1.sh"; }
silent() { [ -z "$("$@")" ]; }
not() { ! "$@"; }
prints() { [ "$("${@:2}")" = "$1" ]; }
valid_json() {
	if command -v jq >/dev/null; then printf '%s' "$1" | jq -e . >/dev/null; else printf '%s' "$1" | grep -q '^{.*}$'; fi
}
blocks() {
	local out
	out=$(hook stop "$1")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"decision":"block"' &&
		printf '%s' "$out" | grep -qF 'jstack verify' && printf '%s' "$out" | grep -qF "$ST"
}
asks() {
	local out
	out=$(hook guard "$(bash_input "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"ask"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
json_str() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '%s' "$value"
}
bash_input() {
	local cmd
	cmd=$(json_str "$1")
	printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$SID" "$cmd"
}
stop_in() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' "${2:-$SID}" "${1:-false}" "${3:-完成了。}"; }
prompt_in() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID"; }
cursor_shell_in() { printf '{"conversation_id":"%s","hook_event_name":"beforeShellExecution","command":"%s","cwd":"/tmp","sandbox":false}' "$SID" "$(json_str "$1")"; }
cursor_pre_in() { printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"%s"}}' "$SID" "$(json_str "$1")"; }
edit_in() {
	local tool=$1 path
	path=$(json_str "$2")
	printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$tool" "$path"
}
cursor_edit_in() {
	local tool=$1 path
	path=$(json_str "$2")
	printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$tool" "$path"
}
patch_in() {
	local patch
	patch=$(json_str "$1")
	printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"input":"%s"}}' "$SID" "$patch"
}
codex_patch_in() {
	local patch
	patch=$(json_str "$1")
	printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"input":"%s"}}' "$SID" "$patch"
}
cursor_stop_in() { printf '{"conversation_id":"%s","hook_event_name":"stop","status":"%s","loop_count":%s}' "${2:-$SID}" "${1:-completed}" "${3:-0}"; }
cursor_prompt_in() { printf '{"conversation_id":"%s","hook_event_name":"beforeSubmitPrompt","prompt":"hi"}' "$SID"; }
cursor_asks() {
	local out
	out=$(hook guard "$(cursor_shell_in "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permission":"ask"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
cursor_denies() {
	local out
	out=$(hook guard "$(cursor_pre_in "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permission":"deny"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
cursor_edit_denies() {
	local out
	out=$(hook guard "$(cursor_edit_in "$1" "$2")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permission":"deny"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $3. Confirm before it runs."
}
edit_asks() {
	local out
	out=$(hook guard "$(edit_in "$1" "$2")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"ask"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $3. Confirm before it runs."
}
asks_patch() {
	local out
	out=$(hook guard "$1")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"ask"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
codex_patch_denies() {
	local out
	out=$(hook guard "$(codex_patch_in "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"deny"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
both_shell_ask() {
	local cmd=$1 action=$2
	t "[$mode] Claude 问 $cmd" asks "$cmd" "$action"
	t "[$mode] Cursor 问 $cmd" cursor_asks "$cmd" "$action"
}
both_shell_silent() {
	t "[$mode] Claude 放行 $1" silent hook guard "$(bash_input "$1")"
	t "[$mode] Cursor 放行 $1" silent hook guard "$(cursor_shell_in "$1")"
}
both_edit_ask() {
	local tool=$1 path=$2 action=$3
	t "[$mode] Claude 问 $tool $path" edit_asks "$tool" "$path" "$action"
	t "[$mode] Cursor 拒绝 $tool $path" cursor_edit_denies "$tool" "$path" "$action"
}
cursor_blocks() {
	local out
	out=$(hook stop "$(cursor_stop_in "${1:-completed}" "$SID" "${2:-0}")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"followup_message"' &&
		printf '%s' "$out" | grep -qF 'jstack verify'
}
cursor_prompts() {
	local out
	out=$(hook prompt "$(cursor_prompt_in)")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"additional_context"' &&
		printf '%s' "$out" | grep -qF '当前阶段 execute'
}
# Codex 的 hook 输入是 Claude 的形状，但多一个 turn_id；输出协议只有 PreToolUse 不同（不支持 ask）。
codex_input() {
	local cmd
	cmd=$(json_str "$1")
	printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"PreToolUse","model":"deepseek","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"%s"},"tool_use_id":"call-1","transcript_path":null}' "$SID" "$cmd"
}
codex_stop_in() { printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' "${2:-$SID}" "${1:-false}" "${3:-完成了。}"; }
codex_prompt_in() { printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"UserPromptSubmit","model":"deepseek","permission_mode":"default","prompt":"hi","transcript_path":null}' "$SID"; }
codex_denies() {
	local out
	out=$(hook guard "$(codex_input "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"deny"' &&
		printf '%s' "$out" | grep -qF "jstack must-stop: $2. Confirm before it runs."
}
codex_prompts() {
	local out
	out=$(hook prompt "$(codex_prompt_in)")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"hookSpecificOutput"' &&
		printf '%s' "$out" | grep -qF '"additionalContext"' &&
		printf '%s' "$out" | grep -qF '当前阶段 execute'
}
# 首轮还没有任务状态时也要能观测提示 hook，不能靠配置文件推断它已运行。
injection_receipt() {
	local proto=$1 out text
	case $proto in
	claude) out=$(hook prompt "$(prompt_in)"); text=$out ;;
	cursor)
		out=$(hook prompt "$(cursor_prompt_in)")
		valid_json "$out" || return 1
		text=$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["additional_context"])') ;;
	codex)
		out=$(hook prompt "$(codex_prompt_in)")
		valid_json "$out" || return 1
		text=$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])') ;;
	esac
	printf '%s' "$text" | grep -qF "jstack 提示门禁注入：session=$SID" &&
		printf '%s' "$text" | grep -qF 'Stop/guard 未由此验证'
}
old_file_cleaned() {
	mkdir -p "$JSTACK_STATE_DIR"
	touch -t 202001010000 "$JSTACK_STATE_DIR/stale-session"
	stage start execute,verify && [ ! -e "$JSTACK_STATE_DIR/stale-session" ]
}
prompt_shows() {
	local out
	out=$(hook prompt "$(prompt_in)")
	printf '%s\n' "$out" | grep -qF '当前阶段 execute' &&
		printf '%s\n' "$out" | grep -qF '路径：clarify → [execute] → verify → land' &&
		printf '%s\n' "$out" | grep -qF 'The change, committed in small verified units' &&
		printf '%s\n' "$out" | grep -qF '本阶段门禁：None' &&
		printf '%s\n' "$out" | grep -qF "阶段脚本：\"$ST\"" &&
		printf '%s\n' "$out" | grep -qF '门禁满足后运行 enter verify' &&
		[ "$(printf '%s\n' "$out" | grep -Fo -- "\"$ST\"" | wc -l | tr -d ' ')" -eq 1 ] &&
		[ "$(printf '%s' "$out" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -lt 1500 ]
}
prompt_gate() { hook prompt "$(prompt_in)" | grep -qF '本阶段门禁：No evidence means not done'; }
prompt_defaults() { hook prompt "$(prompt_in)" | grep -qF '已采用的默认决定：1 条'; }

for f in "$ST" "$H/prompt.sh" "$H/stop.sh" "$H/guard.sh"; do
	t "${f#"$CLAUDE_PLUGIN_ROOT"/} 可执行" test -x "$f"
done
if command -v jq >/dev/null; then
	t "hooks.json 注册了 UserPromptSubmit、PreToolUse(shell+edit)、Stop" jq -e '
		(.hooks.UserPromptSubmit[0].hooks[0].command | endswith("/hooks/prompt.sh")) and
		([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command | endswith("/hooks/guard.sh")] | length == 1) and
		([.hooks.PreToolUse[] | select(.matcher == "Write|Edit|MultiEdit|NotebookEdit") | .hooks[0].command | endswith("/hooks/guard.sh")] | length == 1) and
		(.hooks.Stop[0].hooks[0].command | endswith("/hooks/stop.sh"))' "$H/hooks.json"
	t "hooks.cursor.json 注册了 Cursor 原生事件" jq -e '
		(.version == 1) and
		(.hooks.beforeShellExecution[0].command | endswith("/hooks/guard.sh")) and
		(.hooks.preToolUse[0].command | endswith("/hooks/guard.sh")) and
		(.hooks.beforeSubmitPrompt[0].command | endswith("/hooks/prompt.sh")) and
		(.hooks.stop[0].command | endswith("/hooks/stop.sh")) and
		(.hooks.stop[0].loop_limit == 3)' "$H/hooks.cursor.json"
fi
t "flow 的 Cursor 清单指向 hooks.cursor.json" grep -q '"hooks"[[:space:]]*:[[:space:]]*"\./hooks/hooks\.cursor\.json"' "$CLAUDE_PLUGIN_ROOT/.cursor-plugin/plugin.json"

t "stage.sh 没有会话 id 时只打印说明" sh -c '[ "$("$1" "$2" start nope 2>&1)" = "jstack: 这个 harness 没有会话 id，阶段门禁不生效" ] && [ ! -e "$3" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Cursor 会话里用 CURSOR_CONVERSATION_ID" sh -c 'CURSOR_CONVERSATION_ID=cursor-session "$1" "$2" start execute >/dev/null && [ -f "$3/cursor-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Pi 会话里用 PI_SESSION_ID" sh -c 'PI_SESSION_ID=pi-session "$1" "$2" start execute >/dev/null && [ -f "$3/pi-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 OMP 会话里用 JSTACK_SESSION_ID" sh -c 'JSTACK_SESSION_ID=omp-session "$1" "$2" start execute >/dev/null && [ -f "$3/omp-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Codex 会话里用 CODEX_SESSION_ID" sh -c 'CODEX_SESSION_ID=codex-session "$1" "$2" start execute >/dev/null && [ -f "$3/codex-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Workloop 会话里用 WORKLOOP_SESSION_ID 并提示未强制" sh -c 'WORKLOOP_SESSION_ID=workloop-session "$1" "$2" start execute | grep -q "门禁未强制" && [ -f "$3/workloop-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在其他 harness 不提示 Workloop 未强制" sh -c '! PI_SESSION_ID=pi-other WORKLOOP_SESSION_ID=w "$1" "$2" start execute | grep -q "门禁未强制"' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 的会话 id 依次取 JSTACK_SESSION_ID、PI_SESSION_ID、Claude、Cursor" sh -c 'JSTACK_SESSION_ID=omp-session PI_SESSION_ID=pi-session CLAUDE_CODE_SESSION_ID=$4 CURSOR_CONVERSATION_ID=$4 "$1" "$2" start execute >/dev/null && [ -f "$3/omp-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR" "$SID"
rm -f "$JSTACK_STATE_DIR/cursor-session" "$JSTACK_STATE_DIR/pi-session" "$JSTACK_STATE_DIR/omp-session"
t "stage.sh start 不认识的阶段时失败" not stage start execute,deploy
t "stage.sh start 失败时不写状态" test ! -e "$STATE"
t "stage.sh enter 没有状态时失败" not stage enter execute
stage start clarify,execute,verify,land >/dev/null
t "stage.sh start 的状态文件" state_is 'path clarify,execute,verify,land' 'stage clarify'
t "stage.sh start 记录运行元数据" sh -c '
	grep -q "^started " "$1" && grep -q "^repo " "$1" && grep -q "^ticket " "$1" &&
	grep -qx "size -" "$1" && grep -qx "asks 0" "$1"' _ "$STATE"
t "stop.sh 在 clarify 阶段放行" silent hook stop "$(stop_in)"
stage ask '排序按 due 还是按标题？' >/dev/null
stage ask '排序按 due 还是按标题？' >/dev/null
t "stage.sh ask 只加一行 ask" state_is 'path clarify,execute,verify,land' 'stage clarify' 'ask 排序按 due 还是按标题？'
t "stage.sh ask 记录打断次数" grep -qx 'asks 1' "$STATE"
stage enter execute >/dev/null
t "stage.sh enter 更新阶段并清掉 ask" state_is 'path clarify,execute,verify,land' 'stage execute'
t "stage.sh enter 不在路径上的阶段时失败" not stage enter review
t "stage.sh evidence 空文本时失败" not stage evidence "  "
for mode in jq nojq; do
	if [ $mode = nojq ]; then export JSTACK_NO_JQ=1; else command -v jq >/dev/null || continue; fi
	t "[$mode] stop.sh 在 execute 阶段没有证据时拦下" blocks "$(stop_in)"
	t "[$mode] stop.sh 的 stop_hook_active=true 时放行" silent hook stop "$(stop_in true)"
	t "[$mode] stop.sh 对别的会话放行" silent hook stop "$(stop_in false other-session)"
	t "[$mode] stop.sh 输入没有 session_id 时用 CLAUDE_CODE_SESSION_ID" sh -c '
		out=$(printf "{\"stop_hook_active\":false}" | CLAUDE_CODE_SESSION_ID=$1 "$2" "$3")
		printf "%s" "$out" | grep -qF "\"decision\":\"block\""' _ "$SID" "$BASH" "$H/stop.sh"
	t "[$mode] stop.sh 输入没有 session_id 时用 PI_SESSION_ID" sh -c '
		out=$(printf "{\"stop_hook_active\":false}" | PI_SESSION_ID=$1 "$2" "$3")
		printf "%s" "$out" | grep -qF "\"decision\":\"block\""' _ "$SID" "$BASH" "$H/stop.sh"
	t "[$mode] stop.sh 的 JSTACK_SESSION_ID 优先于 PI_SESSION_ID" sh -c '
		out=$(printf "{\"stop_hook_active\":false}" | JSTACK_SESSION_ID=other-session PI_SESSION_ID=$1 "$2" "$3")
		[ -z "$out" ]' _ "$SID" "$BASH" "$H/stop.sh"
	t "[$mode] guard.sh 对 Cursor 的 beforeShellExecution 返回 permission=ask" cursor_asks 'rm -rf build' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] guard.sh 对 Cursor 的 preToolUse 降级为 deny" cursor_denies 'rm -rf build' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] guard.sh 对 Codex 的 PreToolUse 降级为 deny" codex_denies 'rm -rf build' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] stop.sh 对 Cursor 的 completed 返回 followup_message" cursor_blocks
	t "[$mode] stop.sh 对 Cursor 的 aborted 放行" silent hook stop "$(cursor_stop_in aborted)"
	t "[$mode] stop.sh 在 Cursor 达到 loop_limit 后放行" silent hook stop "$(cursor_stop_in completed "$SID" 3)"
	t "[$mode] stop.sh 对别的 Cursor 会话放行" silent hook stop "$(cursor_stop_in completed other-session)"
	t "[$mode] stop.sh 对 Codex 输入同样拦下" blocks "$(codex_stop_in)"
	t "[$mode] stop.sh 对 Codex 的 stop_hook_active=true 放行" silent hook stop "$(codex_stop_in true)"
	stage ask '排序按 due 还是按标题？' >/dev/null
	t "[$mode] stop.sh 标了 ask 但回复没有提问时仍拦下" blocks "$(stop_in)"
	t "[$mode] stop.sh 标了 ask 且回复向用户提问时放行" silent hook stop "$(stop_in false "$SID" "排序按 due 还是按标题？")"
	t "[$mode] stop.sh 在 Cursor 标了 ask 时放行（无法核对回复）" silent hook stop "$(cursor_stop_in)"
	t "[$mode] prompt.sh 有状态时注入当前阶段、产出、门禁和下一步" prompt_shows
	t "[$mode] prompt.sh 对 Cursor 的 beforeSubmitPrompt 注入 additional_context" cursor_prompts
	t "[$mode] prompt.sh 对 Codex 的 UserPromptSubmit 注入 hookSpecificOutput" codex_prompts
	t "[$mode] prompt.sh 清掉 ask" state_is 'path clarify,execute,verify,land' 'stage execute'
	stage enter verify >/dev/null
	t "[$mode] prompt.sh 注入 verify 阶段的门禁" prompt_gate
	t "[$mode] stop.sh 在 verify 阶段没有证据时拦下" blocks "$(stop_in)"
	stage enter execute >/dev/null
done
unset JSTACK_NO_JQ
stage evidence './run-tests' '->' "12 passed
0 failed" >/dev/null
t "stage.sh evidence 把参数拼成一行追加" state_is 'path clarify,execute,verify,land' 'stage execute' 'evidence execute ./run-tests -> 12 passed 0 failed'
t "execute 的证据不能替代 verify" blocks "$(stop_in)"
stage enter verify >/dev/null
stage enter execute >/dev/null
t "stage.sh 再次进入 execute 时把旧证据标成历史" state_is 'path clarify,execute,verify,land' 'stage execute' 'prior evidence execute ./run-tests -> 12 passed 0 failed'
t "stop.sh 下一张 ticket 没有新证据时拦下" blocks "$(stop_in)"
SID=second-case-0002; STATE="$JSTACK_STATE_DIR/$SID"
stage start execute >/dev/null
t "stop.sh 在路径不含 verify 时放行" silent hook stop "$(stop_in)"
stage end >/dev/null
stage start verify,land >/dev/null
t "stop.sh 在路径不含 execute 时放行" silent hook stop "$(stop_in)"
stage end >/dev/null
t "stage.sh end 删掉状态文件" test ! -e "$STATE"
stage start execute,verify >/dev/null
t "stage.sh end 路径含 verify 且没有证据时拒绝收尾" not stage end
t "stage.sh end 拒绝后状态还在" state_is 'path execute,verify' 'stage execute'
stage enter verify >/dev/null
stage evidence './run-tests -> 12 passed' >/dev/null
t "stage.sh end 有证据时收尾" stage end
t "stage.sh end 收尾后状态文件已删除" test ! -e "$STATE"
t "stage.sh show 没有状态时打印 none" prints none stage show
t "stop.sh 没有状态时放行" silent hook stop "$(stop_in)"
for mode in jq nojq; do
	if [ "$mode" = nojq ]; then export JSTACK_NO_JQ=1; else command -v jq >/dev/null || continue; fi
	for proto in claude cursor codex; do
		t "[$mode] $proto 首轮没有状态时也输出会话注入标记" injection_receipt "$proto"
	done
	t "[$mode] 提示注入不创建或恢复任务状态" test ! -e "$STATE"
	t "[$mode] prompt 没有会话 id 时不假报注入" silent hook prompt '{"hook_event_name":"UserPromptSubmit"}'
	t "[$mode] prompt 拒绝非法会话 id" silent hook prompt '{"session_id":"../escape","hook_event_name":"UserPromptSubmit"}'
done
unset JSTACK_NO_JQ
stage start investigate >/dev/null
t "调查路线不进入实现阶段" state_is 'path investigate' 'stage investigate'
t "调查提示注入引用证据回答的产出" sh -c '
	out=$(printf "%s" "$1" | "$2" "$3")
	printf "%s" "$out" | grep -qF "当前阶段 investigate" &&
	printf "%s" "$out" | grep -qF "A cited answer"' _ "$(prompt_in)" "$BASH" "$H/prompt.sh"
t "调查路线不要求实现验证证据" silent hook stop "$(stop_in)"
stage end >/dev/null
t "stage.sh start 顺带删掉 7 天前的状态文件" old_file_cleaned
stage enter verify >/dev/null
stage evidence "npm test -> ok" >/dev/null
stage end >/dev/null

# 默认决定：记录替用户做的选择，收尾摘要里逐条列出；进入下一张 ticket 时保留。
stage start execute,verify >/dev/null
stage default '按标题排序' '->' '任务只要求排序' >/dev/null
t "stage.sh default 把参数拼成一行追加" state_is 'path execute,verify' 'stage execute' 'default 按标题排序 -> 任务只要求排序'
t "stage.sh default 空文本时失败" not stage default '  '
stage enter verify >/dev/null
stage enter execute >/dev/null
t "stage.sh 再次进入 execute 时保留默认决定" state_is 'path execute,verify' 'stage execute' 'default 按标题排序 -> 任务只要求排序'
t "prompt.sh 注入已采用的默认决定" prompt_defaults
stage enter verify >/dev/null
stage evidence 'npm test -> 12 passed' >/dev/null
stage end >/dev/null

# 合并后归档待补：按仓库存，跨会话；start 时列出来。
PEND_REPO="$T/pend-repo"
mkdir -p "$PEND_REPO" && git -C "$PEND_REPO" init -q
pstage() { (cd "$PEND_REPO" && CLAUDE_CODE_SESSION_ID=${PSID:-$SID} "$BASH" "$ST" "$@"); }
t "stage.sh pending 没有待补时打印 none" prints none pstage pending
t "stage.sh pending 不需要阶段记录就能记" pstage pending https://example.test/o/r/pull/7 'closes #74,' worktree wt-a
t "stage.sh pending 列出待补" prints 'https://example.test/o/r/pull/7 closes #74, worktree wt-a' pstage pending
pstage pending https://example.test/o/r/pull/7 'closes #74' >/dev/null
pstage pending https://example.test/o/r/pull/70 'closes #75' >/dev/null
t "stage.sh pending 同一个 PR 只留最新一条" prints 'https://example.test/o/r/pull/7 closes #74
https://example.test/o/r/pull/70 closes #75' pstage pending
t "另一个会话 start 时列出待补" sh -c '
	out=$(cd "$1" && CLAUDE_CODE_SESSION_ID=other-session-9 "$2" "$3" start execute,verify)
	printf "%s" "$out" | grep -qF "2 条合并后归档待补" && printf "%s" "$out" | grep -qF "pull/7 closes #74" &&
		printf "%s" "$out" | grep -qF "不要自己合并"' _ "$PEND_REPO" "$BASH" "$ST"
t "别的仓库看不到这份待补" sh -c '
	mkdir -p "$1" && git -C "$1" init -q && cd "$1" &&
		[ "$(CLAUDE_CODE_SESSION_ID=other-session-9 "$2" "$3" pending)" = none ]' _ "$T/pend-other" "$BASH" "$ST"
t "stage.sh settled 拒绝清单里没有的 PR" not pstage settled https://example.test/o/r/pull/9
t "stage.sh settled 只删点名的那条" pstage settled https://example.test/o/r/pull/7
t "stage.sh settled 之后剩另一条" prints 'https://example.test/o/r/pull/70 closes #75' pstage pending
pstage settled https://example.test/o/r/pull/70 >/dev/null
t "待补清完后 start 不再提示" sh -c '
	out=$(cd "$1" && CLAUDE_CODE_SESSION_ID=other-session-9 "$2" "$3" start execute,verify)
	! printf "%s" "$out" | grep -q 待补' _ "$PEND_REPO" "$BASH" "$ST"
(cd "$PEND_REPO" && CLAUDE_CODE_SESSION_ID=other-session-9 "$BASH" "$ST" enter verify >/dev/null &&
  CLAUDE_CODE_SESSION_ID=other-session-9 "$BASH" "$ST" evidence "test -> ok" >/dev/null &&
  CLAUDE_CODE_SESSION_ID=other-session-9 "$BASH" "$ST" end >/dev/null)

# 运行记录：完成的任务落到 runs.jsonl，没 end 的任务留在 runs/active 里，jstack runs 两种都列。
if command -v jq >/dev/null; then
	RUN_STATE="$T/run-state/sessions"
	RUN_REPO="$T/run-repo"
	RUN_SID=run-log-session-0001
	mkdir -p "$RUN_REPO" && git -C "$RUN_REPO" init -q
	run_stage() { (cd "$RUN_REPO" && JSTACK_STATE_DIR="$RUN_STATE" CLAUDE_CODE_SESSION_ID=$RUN_SID "$BASH" "$ST" "$@"); }
	run_stage start --size S execute,verify >/dev/null
	t "stage.sh start --size 记录任务规模" grep -qx 'size S' "$RUN_STATE/$RUN_SID"
	run_stage evidence './author-check -> ok' >/dev/null
	run_stage default '按标题排序 -> 任务只要求排序' >/dev/null
	run_stage ask '排序按 due 还是按标题？' >/dev/null
	t "未完成任务出现在 jstack runs" sh -c '
		JSTACK_STATE_DIR="$3" "$1" runs --repo "$2" --json |
		jq -e "select(.status == \"unfinished\" and .size == \"S\" and .asks == 1 and .needs_human == true and (.evidence | length) == 1 and (.defaults | length) == 1)"' _ "$ROOT/jstack" "$RUN_REPO" "$RUN_STATE"
	t "jstack runs 表格列出未完成任务" sh -c '
		JSTACK_STATE_DIR="$3" "$1" runs --repo "$2" | grep -q "unfinished.*execute→verify"' _ "$ROOT/jstack" "$RUN_REPO" "$RUN_STATE"
	run_stage enter verify >/dev/null
	run_stage evidence './verify-check -> ok' >/dev/null
	run_stage end >/dev/null
	RUN_ID=$(JSTACK_STATE_DIR="$RUN_STATE" "$ROOT/jstack" runs --repo "$RUN_REPO" --json | jq -r 'select(.status == "completed") | .run_id')
	t "完成任务写入 jstack runs" sh -c '
		JSTACK_STATE_DIR="$3" "$1" runs --repo "$2" --json |
		jq -e "select(.status == \"completed\" and .size == \"S\" and (.evidence | length) == 2 and (.defaults | length) == 1)"' _ "$ROOT/jstack" "$RUN_REPO" "$RUN_STATE"
	t "jstack runs --show 能查到证据和默认决定" sh -c '
		JSTACK_STATE_DIR="$3" "$1" runs --show "$4" --json |
		jq -e "select((.evidence | any(. == \"verify ./verify-check -> ok\")) and (.defaults | any(. == \"按标题排序 -> 任务只要求排序\")))"' _ "$ROOT/jstack" "$RUN_REPO" "$RUN_STATE" "$RUN_ID"
	RUN_SID=run-log-abandoned-0002
	run_stage start --size M execute,verify >/dev/null
	t "未 end 的任务在 jstack runs 中标为未完成" sh -c '
		JSTACK_STATE_DIR="$3" "$1" runs --repo "$2" --json |
		jq -e "select(.status == \"unfinished\" and .size == \"M\")"' _ "$ROOT/jstack" "$RUN_REPO" "$RUN_STATE"
else
	echo "- 没有 jq，跳过 jstack runs 测试"
fi

for mode in jq nojq; do
	if [ $mode = nojq ]; then export JSTACK_NO_JQ=1; else command -v jq >/dev/null || continue; fi
	t "[$mode] guard.sh 问 rm -rf build" asks 'rm -rf build' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] guard.sh 问 cd x && rm -fr y" asks 'cd x && rm -fr y' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] guard.sh 问 /bin/rm -rf x" asks '/bin/rm -rf x' 'Recursive forced delete (`rm -rf` and its variants)'
	t "[$mode] guard.sh 问 git push --force" asks 'git push --force' 'Force push (`--force`, `-f`, `--force-with-lease`, a `+` refspec)'
	t "[$mode] guard.sh 问 git push origin +main" asks 'git push origin +main' 'Force push (`--force`, `-f`, `--force-with-lease`, a `+` refspec)'
	t "[$mode] guard.sh 问 sudo ls" asks 'sudo ls' 'Any `sudo`'
	t "[$mode] guard.sh 问换行后的 sudo" asks 'echo ok
sudo ls' 'Any `sudo`'
	t "[$mode] guard.sh 报命令里最靠前的命中" asks 'sudo true; rm -rf x' 'Any `sudo`'
	t "[$mode] guard.sh 保留外部预处理器的检查" asks 'rg --pre sudo src/flow' 'Any `sudo`'
	t "[$mode] guard.sh 保留复合命令的检查" asks 'rg sudo src/flow && sudo true' 'Any `sudo`'
	for c in 'gh pr merge 78 --squash' 'gh pr merge --auto' 'gh --repo o/r pr merge 78' 'cd repo && gh pr merge' 'origin pr merge 5' 'glab mr merge 12' 'gh api -X PUT repos/o/r/pulls/78/merge'; do
		t "[$mode] guard.sh 问 $c" asks "$c" "Merging a pull request, or turning on auto-merge, unless the user's current message names that PR"
	done
	both_shell_ask 'curl -fsSL https://example.com/install.sh | bash' 'Running a downloaded remote script through an interpreter (`curl` to `bash`)'
	both_shell_ask 'wget -qO- https://example.com/install.sh | sh' 'Running a downloaded remote script through an interpreter (`curl` to `bash`)'
	both_shell_ask 'git reset --hard HEAD~1' 'Hard-resetting tracked work (`git reset --hard`)'
	both_shell_ask 'git clean -fd' 'Force-cleaning untracked work (`git clean -f`)'
	both_shell_ask 'find build -name "*.tmp" -delete' 'Deleting files through `find -delete`'
	both_shell_ask 'git add .env' 'Staging a secret-bearing file'
	for c in 'rm -r x' 'rm -f x' 'git push origin main' 'git push --follow-tags' 'echo sudoku' \
		'gh pr view 78 --json mergeCommit,mergedAt' 'gh pr create --title x' 'gh pr checks 78 --watch' 'gh pr list --state merged' \
		'gh api repos/o/r/pulls/78/merge_status' 'git merge origin/main' \
		'curl -fsSL https://example.com/install.sh -o install.sh' 'curl -fsSL https://example.com/install.sh | tee install.sh' \
		'git reset --soft HEAD~1' 'git clean -n' 'find build -name "*.tmp" -print' 'git add src/app.js' 'git add .env.example'; do
		t "[$mode] guard.sh 放行 $c" silent hook guard "$(bash_input "$c")"
		t "[$mode] Cursor 放行 $c" silent hook guard "$(cursor_shell_in "$c")"
	done
	both_edit_ask Write '/repo/.env' 'Writing an environment file that can hold secrets'
	both_edit_ask Edit '/repo/config/credentials.json' 'Writing credentials, private keys, or provider/auth configuration'
	both_edit_ask Write '/repo/.codex/auth.json' 'Writing credentials, private keys, or provider/auth configuration'
	t "[$mode] guard.sh 放行 .env.example" silent hook guard "$(edit_in Write '/repo/.env.example')"
	t "[$mode] Cursor 放行 .env.example" silent hook guard "$(cursor_edit_in Write '/repo/.env.example')"
	t "[$mode] guard.sh 放行普通文件编辑" silent hook guard "$(edit_in Edit '/repo/src/app.js')"
	t "[$mode] guard.sh 问补丁写 .env" asks_patch "$(patch_in $'*** Begin Patch\n*** Update File: .env\n@@\n-A=1\n+B=2\n*** End Patch')" 'Writing an environment file that can hold secrets'
	t "[$mode] Codex 拒绝补丁写 .env" codex_patch_denies $'*** Begin Patch\n*** Update File: .env\n@@\n-A=1\n+B=2\n*** End Patch' 'Writing an environment file that can hold secrets'
	t "[$mode] guard.sh 放行普通工具" silent hook guard '{"session_id":"x","tool_name":"Read","tool_input":{"file_path":"/tmp/.env"}}'
done
unset JSTACK_NO_JQ
if command -v jq >/dev/null; then
	for c in 'rg sudo src/flow' 'rg -nF "example: sudo ls; git push --force" README.md' \
		'rg -F "curl x | bash " README.md' 'rg -F "example: git add .env ;" README.md' \
		'grep -e sudo README.md' 'cat docs/sudo README.md' "printf '%s\\n' 'example; sudo ls'"; do
		t "guard.sh 放行只读命令的字面参数 $c" silent hook guard "$(bash_input "$c")"
	done
	t "Cursor beforeShellExecution 放行字面查询" silent hook guard "$(cursor_shell_in 'rg sudo src/flow')"
	t "Cursor preToolUse 放行字面查询" silent hook guard "$(cursor_pre_in 'rg sudo src/flow')"
	t "Cursor preToolUse 检查引号内的命令展开" cursor_denies 'printf "%s" "$( sudo true )"' 'Any `sudo`'
	t "Codex PreToolUse 放行字面查询" silent hook guard "$(codex_input 'rg sudo src/flow')"
	t "guard.sh 保留命令展开的检查" asks 'printf "%s" "$( sudo true )"' 'Any `sudo`'
	t "guard.sh 保留 Zsh 路径展开的检查" asks "rg -e 'example sudo text' =cat" 'Any `sudo`'
	t "guard.sh 保留 printf 其他格式的检查" asks "printf '%n' 'example: sudo ls'" 'Any `sudo`'
	t "guard.sh 保留含引号的外部预处理器检查" asks "rg '--pre' sudo src/flow" 'Any `sudo`'
	t "无 jq 时字面查询保留原判定" env JSTACK_NO_JQ=1 "$BASH" -c \
		'printf "%s" "$1" | "$BASH" "$2" | grep -qF "Any \`sudo\`"' \
		_ "$(bash_input 'rg sudo src/flow')" "$H/guard.sh"
fi
t "guard.sh 在插件目录不完整时放行" sh -c 'printf "%s" "$1" | CLAUDE_PLUGIN_ROOT=$2 "$3" "$4" | grep -q . && exit 1 || exit 0' _ "$(bash_input 'rm -rf x')" "$T/nowhere" "$BASH" "$H/guard.sh"

# 仓库级配置：.jstack/config.json 追加 must-stop、替换阶段表、注入提示。
REPO="$T/repo"
SID2=test-session-0002
mkdir -p "$REPO/.jstack" "$REPO/scripts"
git -C "$REPO" init -q
cat >"$REPO/.jstack/config.json" <<'JSON'
{
  "tracker": { "type": "local" },
  "must_stop": [
    { "action": "运行 ./deploy.sh", "hook": "deploy", "regex": "(^|[[:space:]/])\\./deploy\\.sh([[:space:]]|$)" },
    { "action": "覆盖生产配置", "hook": "prod-config", "path_regex": "(^|/)config/prod\\.yaml$" },
    { "action": "审查该搜索", "hook": "sudo", "regex": "^rg sudo src/flow$" }
  ],
  "stages_file": ".jstack/stages.md",
  "verify": { "command": "./scripts/verify.sh" }
}
JSON
cat >"$REPO/.jstack/stages.md" <<'MD'
# 仓库自己的阶段表

## Stages

| Stage | Output | Gate | Providers |
|---|---|---|---|
| size | One sentence | None | `flow:route` |
| execute | The change | None | `pstack:poteto-mode` |
| verify | Evidence | No evidence means not done | `pstack:principle-prove-it-works` |
| land | Commits | must-stop | `flow:land` |
MD
export VERIFY_COUNTER="$T/verify-count"
cat >"$REPO/scripts/verify.sh" <<'SH'
#!/bin/bash
printf 'run\n' >>"$VERIFY_COUNTER"
case "$(cat verify-input)" in
pass) ;;
slow) sleep 5 ;;
fail) printf 'fixture failure\twith details\n'; exit 23 ;;
esac
SH
chmod +x "$REPO/scripts/verify.sh"
printf 'pass\n' >"$REPO/verify-input"
git -C "$REPO" add .
git -C "$REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
repo_stage() { (cd "$REPO" && CLAUDE_CODE_SESSION_ID=$SID2 "$BASH" "$ST" "$@"); }
repo_hook() { (cd "$REPO" && printf '%s' "$2" | "$BASH" "$H/$1.sh"); }
repo_state="$JSTACK_STATE_DIR/$SID2"
repo_prompt_in() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID2"; }
repo_asks() {
	local out
	out=$(repo_hook guard "$(bash_input "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"ask"' &&
		printf '%s' "$out" | grep -qF 'jstack must-stop: 运行 ./deploy.sh（仓库追加）. Confirm before it runs.'
}
repo_edit_asks() {
	local out
	out=$(repo_hook guard "$(edit_in Write "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"ask"' &&
		printf '%s' "$out" | grep -qF 'jstack must-stop: 覆盖生产配置（仓库追加）. Confirm before it runs.'
}
repo_cursor_edit_denies() {
	local out
	out=$(repo_hook guard "$(cursor_edit_in Write "$1")")
	valid_json "$out" && printf '%s' "$out" | grep -qF '"permission":"deny"' &&
		printf '%s' "$out" | grep -qF 'jstack must-stop: 覆盖生产配置（仓库追加）. Confirm before it runs.'
}
if command -v jq >/dev/null; then
	t "仓库配置：guard.sh 问 ./deploy.sh 并标明仓库追加" repo_asks './deploy.sh --all'
	t "仓库配置：guard.sh 按路径问生产配置" repo_edit_asks 'config/prod.yaml'
	t "仓库配置：Cursor preToolUse 按路径拒绝生产配置" repo_cursor_edit_denies 'config/prod.yaml'
	t "仓库配置：guard.sh 放行非生产路径" silent repo_hook guard "$(edit_in Write 'config/dev.yaml')"
	t "仓库配置：git add 生产配置也问" sh -c '
		out=$(cd "$1" && printf "%s" "$2" | "$3" "$4")
		printf "%s" "$out" | grep -qF "覆盖生产配置（仓库追加）"' \
		_ "$REPO" "$(bash_input 'git add config/prod.yaml')" "$BASH" "$H/guard.sh"
	t "仓库配置：字面查询仍命中仓库规则，即使 hook 名和内置规则相同" sh -c '
		out=$(cd "$1" && printf "%s" "$2" | "$3" "$4")
		printf "%s" "$out" | grep -qF "jstack must-stop: 审查该搜索（仓库追加）."' \
		_ "$REPO" "$(bash_input 'rg sudo src/flow')" "$BASH" "$H/guard.sh"
	t "仓库配置：guard.sh 仍问内置的 rm -rf" sh -c '
		out=$(cd "$1" && printf "%s" "$2" | "$3" "$4")
		printf "%s" "$out" | grep -qF "permissionDecision" && printf "%s" "$out" | grep -qF "Recursive forced delete"' \
		_ "$REPO" "$(bash_input 'rm -rf build')" "$BASH" "$H/guard.sh"
	repo_stage start execute,verify >/dev/null
	t "仓库配置：stage.sh start 接受 stages_file 里的阶段" test "$(sed -n 's/^path //p' "$repo_state")" = execute,verify
	t "仓库配置：stage.sh start 拒绝表外阶段" not repo_stage start clarify
	t "仓库配置：prompt.sh 注入仓库配置" sh -c '
		out=$(cd "$1" && printf "%s" "$2" | "$3" "$4")
		printf "%s\n" "$out" | grep -qF "仓库配置：阶段表=.jstack/stages.md" &&
		printf "%s\n" "$out" | grep -qF "tracker=local" &&
		printf "%s\n" "$out" | grep -qF "验证命令=./scripts/verify.sh" &&
		printf "%s\n" "$out" | grep -qF "must-stop 追加=3 条"' \
		_ "$REPO" "$(repo_prompt_in)" "$BASH" "$H/prompt.sh"
	repo_stage enter verify >/dev/null
	repo_stage evidence './scripts/verify.sh -> claimed pass' >/dev/null
	verify_receipt="$repo_state.verify.json"
	verify_count() { test "$(wc -l <"$VERIFY_COUNTER" | tr -d ' ')" = "$1"; }
	verify_reply() {
		local result
		result=$(repo_hook stop "$1")
		printf '%s' "$result" | jq -e --arg property "$2" --arg detail "$3" \
			'.[$property] | strings | contains($detail)' >/dev/null
	}
	t "Stop 直接执行配置的命令并通过" silent repo_hook stop "$(stop_in false "$SID2")"
	t "执行器回执包含退出码、提交、耗时和干净状态" jq -e --arg commit "$(git -C "$REPO" rev-parse HEAD)" \
		'.exit_code == 0 and .commit == $commit and .dirty == false and (.duration_ms | type) == "number"' "$verify_receipt"
	t "相同快照在 Cursor 协议中复用成功回执" silent repo_hook stop "$(cursor_stop_in completed "$SID2")"
	t "同一快照只执行过一次" verify_count 1

	printf 'fail\n' >"$REPO/verify-input"
	t "Claude Stop 执行脏工作区验证并返回失败输出" verify_reply "$(stop_in false "$SID2")" reason '退出码 23'
	t "Cursor Stop 不能用文本证据越过失败" verify_reply "$(cursor_stop_in completed "$SID2")" followup_message 'fixture failure'
	verify_from_other_repo() {
		local event result
		mkdir -p "$T/other"
		git -C "$T/other" init -q
		event=$(stop_in false "$SID2" | jq --arg cwd "$T/other" '.cwd = $cwd')
		result=$(printf '%s' "$event" | "$BASH" "$H/stop.sh")
		jq -e '.decision == "block" and (.reason | contains("退出码 23"))' <<<"$result"
	}
	t "Stop 更换当前目录后仍验证任务启动时的仓库" verify_from_other_repo
	t "失败回执也可复用" verify_count 2
	t "验证失败时 CLI 同样拒绝清除状态" not repo_stage end
	t "CLI 拒绝后阶段记录仍在" test -f "$repo_state"
	t "显式重试再次执行命令" not repo_stage verify --retry
	t "重试产生第三次执行" verify_count 3

	printf 'pass\n' >"$REPO/verify-input"
	printf 'one\n' >"$REPO/untracked"
	t "修正内容后通过重新验证" repo_stage verify
	printf 'two\n' >"$REPO/untracked"
	t "未跟踪文件内容变化使回执失效" silent repo_hook stop "$(stop_in false "$SID2")"
	t "修改未跟踪文件会重新执行" verify_count 5
	git -C "$REPO" -c user.name=Fixture -c user.email=fixture@example.invalid \
		commit --allow-empty -qm next
	t "提交变化后运行新验证" silent repo_hook stop "$(stop_in false "$SID2")"
	t "新提交产生第六次执行" verify_count 6

	printf 'slow\n' >"$REPO/verify-input"
	t "长验证令 Stop 暂缓结束，命令在后台继续" verify_reply "$(stop_in false "$SID2")" reason '仍在运行'
	t "CLI 等待同一次验证完成" repo_stage verify
	t "Stop 和 CLI 只执行一次长验证" verify_count 7

	jq '.verify.timeout_s = 0.25' "$REPO/.jstack/config.json" >"$T/config"
	mv "$T/config" "$REPO/.jstack/config.json"
	t "配置超时后 Cursor 阻止结束" verify_reply "$(cursor_stop_in completed "$SID2")" followup_message '超时'
	t "超时有结构化失败回执" jq -e '.timed_out and .exit_code == 124' "$verify_receipt"

	jq '.verify.command = "./deploy.sh"' "$REPO/.jstack/config.json" >"$T/config"
	mv "$T/config" "$REPO/.jstack/config.json"
	printf '#!/bin/bash\nprintf unexpected >>"$VERIFY_COUNTER"\n' >"$REPO/deploy.sh"
	chmod +x "$REPO/deploy.sh"
	t "命中仓库 must-stop 的验证命令被拒绝" verify_reply "$(stop_in false "$SID2")" reason 'must-stop'
	t "被拒绝的命令未执行" sh -c '! grep -q unexpected "$1"' _ "$VERIFY_COUNTER"

	mv "$REPO/.jstack/config.json" "$T/verify-config"
	t "运行中移除配置文件时文本证据无法通过 Stop" \
		verify_reply "$(stop_in false "$SID2")" reason '请恢复 verify.command'
	t "运行中移除配置文件时 CLI 仍拒绝收尾" not repo_stage end
	jq 'del(.verify)' "$T/verify-config" >"$REPO/.jstack/config.json"
	t "仅移除 verify.command 时 Cursor 同样拒绝结束" \
		verify_reply "$(cursor_stop_in completed "$SID2")" followup_message '请恢复 verify.command'
	jq '.verify = {"command":"./scripts/verify.sh"}' "$T/verify-config" >"$REPO/.jstack/config.json"
	printf 'pass\n' >"$REPO/verify-input"
	t "恢复验证配置并重验后可以收尾" repo_stage end

	jq 'del(.verify)' "$REPO/.jstack/config.json" >"$T/config"
	mv "$T/config" "$REPO/.jstack/config.json"
	repo_stage start execute,verify >/dev/null
	repo_stage enter verify >/dev/null
	repo_stage evidence 'fixture -> passed' >/dev/null
	t "初始未配置命令时保留分阶段文本证据行为" repo_stage end
fi
BAD="$T/badrepo"
mkdir -p "$BAD/.jstack" "$BAD/.git"
printf '{ "must_stop": [\n' >"$BAD/.jstack/config.json"
t "仓库配置坏掉时 prompt.sh 警告配置未生效" sh -c '
	out=$(cd "$1" && printf "%s" "$2" | "$3" "$4")
	printf "%s\n" "$out" | grep -qF "不是合法的 JSON 对象"' _ "$BAD" "$(prompt_in)" "$BASH" "$H/prompt.sh"
t "仓库配置坏掉时 stage.sh 不受影响" sh -c 'cd "$1" && CLAUDE_CODE_SESSION_ID=$2 "$3" "$4" start execute,verify >/dev/null' _ "$BAD" "$SID2" "$BASH" "$ST"
t "没有 jq 时仓库追加的 must-stop 不生效" sh -c '
	out=$(cd "$1" && printf "%s" "$2" | JSTACK_NO_JQ=1 "$3" "$4")
	[ -z "$out" ]' _ "$REPO" "$(bash_input './deploy.sh')" "$BASH" "$H/guard.sh"

# #58: stage-specific receipts, unresolved findings, remote PR and subagent isolation.
GATE_REPO="$T/gate-repo"
mkdir -p "$GATE_REPO"
git -C "$GATE_REPO" init -q
git -C "$GATE_REPO" remote add origin https://github.com/example/fixture.git
export JSTACK_REPO="$GATE_REPO"
SID=gate-session-0058
STATE="$JSTACK_STATE_DIR/$SID"
stage start execute,verify,review,land >/dev/null
stage evidence 'npm test -> passed' >/dev/null
t "执行阶段证据无法冒充 verify/review/land" blocks "$(stop_in)"
t "阶段记录不能被新路径覆盖" not stage start execute,verify
previous=$(cat "$STATE")
stage start execute,verify,review,land >/dev/null
t "重复 start 原路径不丢进度" test "$(cat "$STATE")" = "$previous"
t "未记录具体问题不能用 ask 绕过门禁" not stage ask '稍后再问'
stage ask '要采用方案二吗？' >/dev/null
previous=$(cat "$STATE")
t "有无关问号不能绕过门禁" blocks "$(stop_in false "$SID" '现在几点？')"
t "实际提出排队问题才允许中断" silent hook stop "$(stop_in false "$SID" '要采用方案二吗？')"
t "子代理命令不能清除主会话状态" not sh -c 'JSTACK_SUBAGENT_ID=child CLAUDE_CODE_SESSION_ID="$1" "$2" "$3" end' _ "$SID" "$BASH" "$ST"
t "子代理命令不能覆盖主会话路径" not sh -c 'JSTACK_SUBAGENT_ID=child CLAUDE_CODE_SESSION_ID="$1" "$2" "$3" start execute,verify' _ "$SID" "$BASH" "$ST"
t "被拒绝的子代理操作不改变主记录" test "$(cat "$STATE")" = "$previous"

subagent_guard() {
    local out
    out=$(hook guard '{"session_id":"gate-session-0058","agent_id":"agent-child","tool_name":"Bash","tool_input":{"command":"./stage.sh end"}}')
    valid_json "$out" && printf '%s' "$out" | grep -qF '"permissionDecision":"deny"'
}
for mode in jq nojq; do
    if [ "$mode" = nojq ]; then export JSTACK_NO_JQ=1; else unset JSTACK_NO_JQ; fi
    t "[$mode] 子代理 PreToolUse 拒绝改写主记录" subagent_guard
done
unset JSTACK_NO_JQ
stage enter verify >/dev/null
stage evidence 'npm test -> passed' >/dev/null
t "只有 verify 时不能冒充 review" blocks "$(stop_in)"
stage enter review >/dev/null
stage review finding F1 '原有并发写入有数据丢失风险' >/dev/null
stage review complete '发现 F1，等待修复' >/dev/null
t "未处置的 review finding 会阻止结束" not stage end
stage review resolution F1 fixed '增加锁与并发回归测试' >/dev/null
stage enter land >/dev/null
stage land commit deadbeef >/dev/null
t "有 remote 但缺少 PR URL 会阻止 Stop" blocks "$(stop_in)"
t "有 remote 但缺少 PR URL 会阻止 end" not stage end
stage land pr https://github.com/example/fixture/pull/42 >/dev/null
t "verify、review、commit、PR 全齐后 Stop 放行" silent hook stop "$(stop_in)"
t "verify、review、commit、PR 全齐后可结束" stage end
t "完成后状态文件被删除" test ! -e "$STATE"
unset JSTACK_REPO

RECHECK_STATE_DIR="$T/recheck-state"
new_recheck_fixture() {
	local repo=$1
	mkdir -p "$repo/src/one" "$repo/src/two" "$repo/api"
	git -C "$repo" init -q
	git -C "$repo" config user.name "jstack fixture"
	git -C "$repo" config user.email "jstack-fixture@example.test"
	git -C "$repo" config core.hooksPath /dev/null
	git -C "$repo" config commit.gpgsign false
	printf 'one baseline\n' >"$repo/src/one/item.txt"
	printf 'two baseline\n' >"$repo/src/two/item.txt"
	printf 'api baseline\n' >"$repo/api/contract.yaml"
	git -C "$repo" add src api
	git -C "$repo" commit -qm baseline
}
recheck_stage() {
	local repo=$1 sid=$2
	shift 2
	(cd "$repo" && CLAUDE_CODE_SESSION_ID="$sid" JSTACK_STATE_DIR="$RECHECK_STATE_DIR" "$BASH" "$ST" "$@")
}
recheck_path_is() {
	local state_file="$RECHECK_STATE_DIR/$2"
	[ "$(sed -n 's/^path //p' "$state_file")" = "$3" ]
}
recheck_stage_is() {
	local state_file="$RECHECK_STATE_DIR/$2"
	[ "$(sed -n 's/^stage //p' "$state_file")" = "$3" ]
}
recheck_end_requires_review() {
	local out
	if out=$(recheck_stage "$1" "$2" end 2>&1); then return 1; fi
	printf '%s' "$out" | grep -qF 'review 缺少审查结论'
}
recheck_finish() {
	recheck_stage "$1" "$2" enter archive >/dev/null &&
		recheck_stage "$1" "$2" end >/dev/null &&
		[ ! -e "$RECHECK_STATE_DIR/$2" ]
}

MULTI_REPO="$T/recheck-multi"
MULTI_SID=recheck-multi
new_recheck_fixture "$MULTI_REPO"
recheck_stage "$MULTI_REPO" "$MULTI_SID" start --size S --ticket '#72' execute,verify,land,archive --recheck-size >/dev/null
printf 'one task change\n' >"$MULTI_REPO/src/one/item.txt"
git -C "$MULTI_REPO" add src/one/item.txt
git -C "$MULTI_REPO" commit -qm 'change src one'
printf 'two untracked task change\n' >"$MULTI_REPO/src/two/new.txt"
recheck_stage "$MULTI_REPO" "$MULTI_SID" enter verify --ticket '#72' >/dev/null
t "recheck-size：跨 src/one、src/two 的 commit 与 untracked 改动补 review" \
	recheck_path_is "$MULTI_REPO" "$MULTI_SID" 'execute,verify,review,land,archive'
t "自动补 review 后仍停在 verify" recheck_stage_is "$MULTI_REPO" "$MULTI_SID" verify
t "范围复核后运行记录保留 ticket 和新阶段路径" jq -e \
	'.current_ticket == "#72" and .path == "execute,verify,review,land,archive"' \
	"$T/runs/active/$MULTI_SID.json"
recheck_stage "$MULTI_REPO" "$MULTI_SID" enter verify >/dev/null
t "重复进入 verify 不重复插入 review" \
	recheck_path_is "$MULTI_REPO" "$MULTI_SID" 'execute,verify,review,land,archive'
rm -f "$MULTI_REPO/src/two/new.txt"
printf 'one small final change\n' >"$MULTI_REPO/src/one/item.txt"
recheck_stage "$MULTI_REPO" "$MULTI_SID" enter verify >/dev/null
t "实际改动缩小后保留已插入的 review" \
	recheck_path_is "$MULTI_REPO" "$MULTI_SID" 'execute,verify,review,land,archive'
recheck_stage "$MULTI_REPO" "$MULTI_SID" evidence 'fixture verify -> passed' >/dev/null
recheck_stage "$MULTI_REPO" "$MULTI_SID" enter review >/dev/null
t "缺少 review 结论时 stage.sh end 明确拒绝" \
	recheck_end_requires_review "$MULTI_REPO" "$MULTI_SID"
recheck_stage "$MULTI_REPO" "$MULTI_SID" review complete '回归检查完成' >/dev/null
recheck_stage "$MULTI_REPO" "$MULTI_SID" enter land >/dev/null
MULTI_HEAD=$(git -C "$MULTI_REPO" rev-parse HEAD)
recheck_stage "$MULTI_REPO" "$MULTI_SID" land commit "$MULTI_HEAD" >/dev/null
t "补齐 review 结论后可继续 archive 并结束" recheck_finish "$MULTI_REPO" "$MULTI_SID"

PREEXISTING_REPO="$T/recheck-preexisting"
PREEXISTING_SID=recheck-preexisting
new_recheck_fixture "$PREEXISTING_REPO"
printf 'edit made before task\n' >"$PREEXISTING_REPO/src/two/item.txt"
recheck_stage "$PREEXISTING_REPO" "$PREEXISTING_SID" start execute,verify,land,archive --recheck-size >/dev/null
printf 'one task change\n' >"$PREEXISTING_REPO/src/one/item.txt"
recheck_stage "$PREEXISTING_REPO" "$PREEXISTING_SID" enter verify >/dev/null
t "任务前 src/two 未提交编辑不影响 src/one 单模块短路径" \
	recheck_path_is "$PREEXISTING_REPO" "$PREEXISTING_SID" 'execute,verify,land,archive'

API_REPO="$T/recheck-api"
API_SID=recheck-api
new_recheck_fixture "$API_REPO"
recheck_stage "$API_REPO" "$API_SID" start execute,verify,land,archive --recheck-size >/dev/null
printf 'api task change\n' >"$API_REPO/api/contract.yaml"
git -C "$API_REPO" add api/contract.yaml
printf 'api baseline\n' >"$API_REPO/api/contract.yaml"
t "直接进入 land 也复核仅暂存的 API 变动并拒绝跳过 review" \
	not recheck_stage "$API_REPO" "$API_SID" enter land
t "仅暂存单个 api/ 路径改动也补 review" \
	recheck_path_is "$API_REPO" "$API_SID" 'execute,verify,review,land,archive'
t "未完成 review 时保持原阶段" recheck_stage_is "$API_REPO" "$API_SID" execute
t "land 被拒绝后运行记录仍保留新增的 review" jq -e \
	'.stage == "execute" and .path == "execute,verify,review,land,archive"' \
	"$T/runs/active/$API_SID.json"

MANY_REPO="$T/recheck-many"
MANY_SID=recheck-many
new_recheck_fixture "$MANY_REPO"
recheck_stage "$MANY_REPO" "$MANY_SID" start execute,verify,land,archive --recheck-size >/dev/null
for name in a b c d; do printf 'new\n' >"$MANY_REPO/src/one/$name.txt"; done
recheck_stage "$MANY_REPO" "$MANY_SID" enter verify >/dev/null
t "同模块超过三个改动路径也补 review" \
	recheck_path_is "$MANY_REPO" "$MANY_SID" 'execute,verify,review,land,archive'

[ "$fails" -eq 0 ]
