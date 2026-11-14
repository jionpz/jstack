#!/usr/bin/env bash
# flow 插件阶段门禁的测试：对构建产物 plugins/flow 运行 stage.sh 和三个 hook，喂 JSON、断言输出和状态文件。
# 每项打印一行 ✓ 或 ✗，有 ✗ 时 exit 1。./jstack check 用 /bin/bash 跑它，顺带确认兼容 macOS 的 bash 3.2：
# 脚本都用当前解释器 $BASH 运行，而不是各自的 shebang。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset JSTACK_SESSION_ID PI_SESSION_ID CLAUDE_CODE_SESSION_ID CURSOR_CONVERSATION_ID JSTACK_NO_JQ JSTACK_STAGES_FILE
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
stage() { CLAUDE_CODE_SESSION_ID=$SID "$BASH" "$ST" "$@"; }
hook() { printf '%s' "$2" | "$BASH" "$H/$1.sh"; }
state_is() { [ "$(cat "$STATE")" = "$(printf '%s\n' "$@")" ]; }
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
bash_input() {
	local cmd
	cmd=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
	printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$SID" "$cmd"
}
stop_in() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' "${2:-$SID}" "${1:-false}" "${3:-完成了。}"; }
prompt_in() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID"; }
cursor_shell_in() { printf '{"conversation_id":"%s","hook_event_name":"beforeShellExecution","command":"%s","cwd":"/tmp","sandbox":false}' "$SID" "$1"; }
cursor_pre_in() { printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"%s"}}' "$SID" "$1"; }
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
	cmd=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
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
		printf '%s\n' "$out" | grep -qF "\"$ST\" enter verify" &&
		[ "$(printf '%s' "$out" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -lt 1500 ]
}
prompt_gate() { hook prompt "$(prompt_in)" | grep -qF '本阶段门禁：No evidence means not done'; }
prompt_defaults() { hook prompt "$(prompt_in)" | grep -qF '已采用的默认决定：1 条'; }

for f in "$ST" "$H/prompt.sh" "$H/stop.sh" "$H/guard.sh"; do
	t "${f#"$CLAUDE_PLUGIN_ROOT"/} 可执行" test -x "$f"
done
if command -v jq >/dev/null; then
	t "hooks.json 注册了 UserPromptSubmit、PreToolUse(Bash)、Stop" jq -e '
		(.hooks.UserPromptSubmit[0].hooks[0].command | endswith("/hooks/prompt.sh")) and
		(.hooks.PreToolUse[0].matcher == "Bash") and
		(.hooks.PreToolUse[0].hooks[0].command | endswith("/hooks/guard.sh")) and
		(.hooks.Stop[0].hooks[0].command | endswith("/hooks/stop.sh"))' "$H/hooks.json"
	t "hooks.cursor.json 注册了 Cursor 原生事件" jq -e '
		(.version == 1) and
		(.hooks.beforeShellExecution[0].command | endswith("/hooks/guard.sh")) and
		(.hooks.beforeSubmitPrompt[0].command | endswith("/hooks/prompt.sh")) and
		(.hooks.stop[0].command | endswith("/hooks/stop.sh")) and
		(.hooks.stop[0].loop_limit == 3)' "$H/hooks.cursor.json"
fi
t "flow 的 Cursor 清单指向 hooks.cursor.json" grep -q '"hooks"[[:space:]]*:[[:space:]]*"\./hooks/hooks\.cursor\.json"' "$CLAUDE_PLUGIN_ROOT/.cursor-plugin/plugin.json"

t "stage.sh 没有会话 id 时只打印说明" sh -c '[ "$("$1" "$2" start nope 2>&1)" = "jstack: 这个 harness 没有会话 id，阶段门禁不生效" ] && [ ! -e "$3" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Cursor 会话里用 CURSOR_CONVERSATION_ID" sh -c 'CURSOR_CONVERSATION_ID=cursor-session "$1" "$2" start execute >/dev/null && [ -f "$3/cursor-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Pi 会话里用 PI_SESSION_ID" sh -c 'PI_SESSION_ID=pi-session "$1" "$2" start execute >/dev/null && [ -f "$3/pi-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 OMP 会话里用 JSTACK_SESSION_ID" sh -c 'JSTACK_SESSION_ID=omp-session "$1" "$2" start execute >/dev/null && [ -f "$3/omp-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在 Workloop 会话里用 WORKLOOP_SESSION_ID 并提示未强制" sh -c 'WORKLOOP_SESSION_ID=workloop-session "$1" "$2" start execute | grep -q "门禁未强制" && [ -f "$3/workloop-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 在其他 harness 不提示 Workloop 未强制" sh -c '! PI_SESSION_ID=pi-other WORKLOOP_SESSION_ID=w "$1" "$2" start execute | grep -q "门禁未强制"' _ "$BASH" "$ST" "$JSTACK_STATE_DIR"
t "stage.sh 的会话 id 依次取 JSTACK_SESSION_ID、PI_SESSION_ID、Claude、Cursor" sh -c 'JSTACK_SESSION_ID=omp-session PI_SESSION_ID=pi-session CLAUDE_CODE_SESSION_ID=$4 CURSOR_CONVERSATION_ID=$4 "$1" "$2" start execute >/dev/null && [ -f "$3/omp-session" ]' _ "$BASH" "$ST" "$JSTACK_STATE_DIR" "$SID"
rm -f "$JSTACK_STATE_DIR/cursor-session" "$JSTACK_STATE_DIR/pi-session" "$JSTACK_STATE_DIR/omp-session"
t "stage.sh start 不认识的阶段时失败" not stage start execute,deploy
t "stage.sh start 失败时不写状态" test ! -e "$STATE"
t "stage.sh enter 没有状态时失败" not stage enter execute
stage start clarify,execute,verify,land >/dev/null
t "stage.sh start 的状态文件" state_is 'path clarify,execute,verify,land' 'stage clarify'
t "stop.sh 在 clarify 阶段放行" silent hook stop "$(stop_in)"
stage ask >/dev/null
stage ask >/dev/null
t "stage.sh ask 只加一行 ask" state_is 'path clarify,execute,verify,land' 'stage clarify' 'ask'
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
	stage ask >/dev/null
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
t "stage.sh evidence 把参数拼成一行追加" state_is 'path clarify,execute,verify,land' 'stage execute' 'evidence ./run-tests -> 12 passed 0 failed'
t "stop.sh 有证据时放行" silent hook stop "$(stop_in)"
stage enter verify >/dev/null
stage enter execute >/dev/null
t "stage.sh 再次进入 execute 时清掉旧证据" state_is 'path clarify,execute,verify,land' 'stage execute'
t "stop.sh 下一张 ticket 没有新证据时拦下" blocks "$(stop_in)"
stage start execute >/dev/null
t "stop.sh 在路径不含 verify 时放行" silent hook stop "$(stop_in)"
stage start verify,land >/dev/null
t "stop.sh 在路径不含 execute 时放行" silent hook stop "$(stop_in)"
stage end >/dev/null
t "stage.sh end 删掉状态文件" test ! -e "$STATE"
stage start execute,verify >/dev/null
t "stage.sh end 路径含 verify 且没有证据时拒绝收尾" not stage end
t "stage.sh end 拒绝后状态还在" state_is 'path execute,verify' 'stage execute'
stage evidence './run-tests -> 12 passed' >/dev/null
t "stage.sh end 有证据时收尾" stage end
t "stage.sh end 收尾后状态文件已删除" test ! -e "$STATE"
t "stage.sh show 没有状态时打印 none" prints none stage show
t "stop.sh 没有状态时放行" silent hook stop "$(stop_in)"
t "prompt.sh 没有状态时不输出" silent hook prompt "$(prompt_in)"
t "stage.sh start 顺带删掉 7 天前的状态文件" old_file_cleaned
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
stage evidence 'npm test -> 12 passed' >/dev/null
stage end >/dev/null

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
	for c in 'rm -r x' 'rm -f x' 'git push origin main' 'git push --follow-tags' 'echo sudoku'; do
		t "[$mode] guard.sh 放行 $c" silent hook guard "$(bash_input "$c")"
	done
	t "[$mode] guard.sh 放行非 Bash 工具" silent hook guard '{"session_id":"x","tool_name":"Write","tool_input":{"file_path":"/tmp/rm -rf x","content":"sudo ls"}}'
done
unset JSTACK_NO_JQ
t "guard.sh 在插件目录不完整时放行" sh -c 'printf "%s" "$1" | CLAUDE_PLUGIN_ROOT=$2 "$3" "$4" | grep -q . && exit 1 || exit 0' _ "$(bash_input 'rm -rf x')" "$T/nowhere" "$BASH" "$H/guard.sh"

# 仓库级配置：.jstack/config.json 追加 must-stop、替换阶段表、注入提示。
REPO="$T/repo"
SID2=test-session-0002
mkdir -p "$REPO/.jstack" "$REPO/.git"
cat >"$REPO/.jstack/config.json" <<'JSON'
{
  "tracker": { "type": "local" },
  "must_stop": [
    { "action": "运行 ./deploy.sh", "hook": "deploy", "regex": "(^|[[:space:]/])\\./deploy\\.sh([[:space:]]|$)" }
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
| land | Commits | must-stop | `pstack:poteto-mode/playbooks/opening-a-pr.md` |
MD
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
if command -v jq >/dev/null; then
	t "仓库配置：guard.sh 问 ./deploy.sh 并标明仓库追加" repo_asks './deploy.sh --all'
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
		printf "%s\n" "$out" | grep -qF "must-stop 追加=1 条"' \
		_ "$REPO" "$(repo_prompt_in)" "$BASH" "$H/prompt.sh"
	repo_stage evidence './scripts/verify.sh -> ok' >/dev/null
	repo_stage end >/dev/null
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

[ "$fails" -eq 0 ]
