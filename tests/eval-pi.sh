#!/usr/bin/env bash
# eval runner 的无模型测试：用假的 pi / claude 只验证 argv、事件解析、失败判定、进程组清理和样本隔离。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
cleanup() {
	if [ -n "${JSTACK_TEST_KEEP:-}" ]; then
		echo "测试目录保留在 $T"
		return
	fi
	chmod -R u+w "$T" 2>/dev/null || true
	rm -r "$T" 2>/dev/null || true
}
trap cleanup EXIT
BIN="$T/bin"
FIX="$T/fixture"
TASKS="$T/tasks"
OUT="$T/out"
TMP="$T/tmp"
mkdir -p "$BIN" "$FIX" "$TASKS/t-one" "$TASKS/t-multi" "$OUT" "$TMP"
printf 'fixture context marker\n' >"$FIX/AGENTS.md"
printf 'do the thing\n' >"$TASKS/t-one/prompt.md"
cat >"$TASKS/t-one/check.sh" <<'SH'
#!/usr/bin/env bash
grep -qx 'done' "$ANSWER_FILE"
SH
printf 'answer it\n' >"$TASKS/t-multi/prompt.md"
cat >"$TASKS/t-multi/check.sh" <<'SH'
#!/usr/bin/env bash
grep -qx 'first line' "$ANSWER_FILE" && grep -qx 'second line' "$ANSWER_FILE"
SH
fails=0
t() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then echo "✓ $name"; else
		echo "✗ $name"
		fails=$((fails + 1))
	fi
}
pair() { awk -v k="$1" -v v="$2" 'p == k && $0 == v { ok = 1 } { p = $0 } END { exit !ok }' "$3"; }

cat >"$T/pi.tpl" <<'SH'
#!/usr/bin/env bash
out='@OUT@'
printf '%s\n' "$@" >"$out/pi-args.txt"
prev=
for a in "$@"; do
	if [ "$prev" = "--append-system-prompt" ]; then
		cp "$a" "$out/pi-context.txt" 2>/dev/null || true
	fi
	prev=$a
done
mode='@MODE@'
if [ "$mode" = timeout ]; then
	trap '' TERM
	bash -c 'trap "" TERM; sleep 100' &
	printf '%s\n' "$!" >"$out/child.pid"
	wait
	exit 0
fi
printf '%s\n' '{"type":"session","version":3,"id":"mock","cwd":"/tmp"}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s\n' '{"type":"turn_start"}'
if [ "$mode" = ok ] || [ "$mode" = exit ]; then
	printf '%s\n' '{"type":"tool_execution_start","toolCallId":"c1","toolName":"read","args":{"path":"/repo/plugins/flow/skills/route/SKILL.md"}}'
fi
if [ "$mode" = error ]; then
	printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"api":"x","provider":"mock-provider","model":"mock-model","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"total":0.1}},"stopReason":"error","errorMessage":"boom"}}'
elif [ "$mode" = no_usage ]; then
	printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"api":"x","provider":"mock-provider","model":"mock-model","stopReason":"stop"}}'
else
	printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"api":"x","provider":"mock-provider","model":"mock-model","usage":{"input":10,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":12,"cost":{"total":0.5}},"stopReason":"stop"}}'
fi
printf '%s\n' '{"type":"turn_end","message":{},"toolResults":[]}'
if [ "$mode" != no_end ]; then
	printf '%s\n' '{"type":"agent_end","messages":[],"willRetry":false}'
	printf '%s\n' '{"type":"agent_settled","aborted":false}'
fi
if [ "$mode" = exit ]; then exit 1; fi
SH

cat >"$T/claude.tpl" <<'SH'
#!/usr/bin/env bash
out='@OUT@'
mode='@MODE@'
printf '%s\n' "$@" >"$out/claude-args.txt"
printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" >"$out/claude-config-dir.txt"
printf '%s\n' "${GH_CONFIG_DIR:-}" >"$out/claude-gh-config.txt"
printf '%s\n' "$(command -v gbrain)" >"$out/claude-gbrain.txt"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/settings.json" ]; then
	printf '%s\n' "$(jq -r 'has("hooks")' "$CLAUDE_CONFIG_DIR/settings.json" 2>/dev/null)" >"$out/claude-user-hooks.txt"
else
	printf 'missing\n' >"$out/claude-user-hooks.txt"
fi
if [ -f .claude/settings.json ] && grep -q '\.jstack/vendor/plugins/flow' .claude/settings.json &&
	[ -L .claude/skills/route ] && [ -d .jstack/vendor/plugins/flow ]; then
	printf 'project\n' >"$out/claude-install.txt"
else
	printf 'none\n' >"$out/claude-install.txt"
fi
printf '%s\n' '{"type":"system","subtype":"init","model":"mock-claude"}'
printf '%s\n' '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"done"},{"type":"tool_use","name":"Skill","input":{"skill":"route"}}]}}'
# 只有装了项目级 hooks 的样本才会收到 Stop 门禁的拦回消息。
if [ -f .claude/settings.json ]; then
	printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"Stop hook feedback:\njstack verify 门禁：当前阶段 execute，还没有记录验证证据"}]}}'
fi
if [ "$mode" = multi ]; then
	printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"first line\nsecond line","session_id":"s","num_turns":1,"modelUsage":{"mock-claude":{"inputTokens":3,"outputTokens":2}},"total_cost_usd":0.1}'
else
	printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s","num_turns":1,"modelUsage":{"mock-claude":{"inputTokens":3,"outputTokens":2}},"total_cost_usd":0.1}'
fi
SH

write_pi() {
	sed -e "s|@OUT@|$2|g" -e "s|@MODE@|$1|g" "$T/pi.tpl" >"$BIN/pi"
	chmod +x "$BIN/pi"
}
write_claude() {
	local mode=${2:-ok}
	sed -e "s|@OUT@|$1|g" -e "s|@MODE@|$mode|g" "$T/claude.tpl" >"$BIN/claude"
	chmod +x "$BIN/claude"
}
run_eval() {
	local name=$1
	shift
	local out="$OUT/$name"
	mkdir -p "$out"
	PATH="$BIN:$PATH" TMPDIR="$TMP" \
		JSTACK_EVAL_TASKS="$TASKS" JSTACK_EVAL_FIXTURE="$FIX" \
		JSTACK_EVAL_RESULTS="$out/results.jsonl" JSTACK_EVAL_REPORTS="$out/reports" JSTACK_EVAL_SCRATCH="$out/scratch" \
		"$ROOT/evals/run.sh" "$@" >"$out/run.log" 2>&1
}
run_ok() {
	local name=$1
	shift
	if run_eval "$name" "$@"; then return 0; fi
	echo "✗ $name 运行失败，见 $OUT/$name/run.log"
	fails=$((fails + 1))
	return 1
}
check_flags() {
	local f
	for f in --no-session --no-mcp --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve; do
		grep -qx -- "$f" "$1" || return 1
	done
}
check_build() {
	pair -e "$ROOT/plugins/flow/extensions/pi.ts" "$1" &&
		pair --skill "$ROOT/plugins/pstack/skills" "$1" &&
		pair --skill "$ROOT/plugins/spec/skills" "$1" &&
		pair --skill "$ROOT/plugins/flow/skills" "$1"
}
check_model_args() { grep -qx mock-provider "$1" && grep -qx mock-model "$1" && grep -qx high "$1"; }
check_context() { grep -q '/AGENTS.md$' "$1" && grep -qx 'fixture context marker' "$2"; }
check_prompt_last() { [ "$(tail -1 "$1")" = 'do the thing' ]; }
timeout_clean() { jq -e '.pass == false and .timed_out == true' "$1" >/dev/null && p=$(cat "$2") && ! kill -0 "$p" 2>/dev/null; }
legacy_readable() { head -1 "$1" | jq -e 'has("task") and ((.harness // "claude") == "claude")' >/dev/null; }

write_pi ok "$OUT/pi-argv"
run_ok pi-argv --harness pi --provider mock-provider --model mock-model --thinking high --group workflow --keep t-one
A="$OUT/pi-argv/pi-args.txt"
R="$OUT/pi-argv/results.jsonl"
t "Pi argv：-p 和 json 模式" grep -qx -- -p "$A"
t "Pi argv：json 模式" grep -qx json "$A"
t "Pi argv：禁用用户资源" check_flags "$A"
t "Pi argv：显式加载构建产物" check_build "$A"
t "Pi argv：三个 --skill" test "$(grep -cx -- --skill "$A")" = 3
t "Pi argv：只有一个 --model" test "$(grep -cx -- --model "$A")" = 1
t "Pi argv：provider/model/thinking" check_model_args "$A"
t "Pi argv：显式传入 AGENTS" check_context "$A" "$OUT/pi-argv/pi-context.txt"
t "Pi argv：prompt 在最后" check_prompt_last "$A"
t "Pi 记录：harness/provider/thinking" jq -e '.harness == "pi" and .provider == "mock-provider" and .thinking == "high" and .pass == true' "$R"
t "Pi 记录：usage 和 route" jq -e '.tokens == 12 and .premium_tokens == 0 and .cost_usd == 0.5 and .route == true and .turns == 1' "$R"
t "Pi 记录：工作流组和门禁来源" jq -e '.group == "workflow" and .gates == "extension" and .stop_blocks == 0' "$R"

write_pi no_usage "$OUT/pi-usage"
run_ok pi-usage --harness pi --model mock-model --group workflow --keep t-one
t "Pi 缺 usage 时为 null 而不是 0" jq -e '.tokens == null and .premium_tokens == null and .cost_usd == null and .pass == true' "$OUT/pi-usage/results.jsonl"

write_pi no_end "$OUT/pi-no-end"
run_ok pi-no-end --harness pi --model mock-model --group workflow --keep t-one
t "Pi 缺 agent_end 不假绿" jq -e '.pass == false and (.error | contains("agent_end"))' "$OUT/pi-no-end/results.jsonl"

write_pi error "$OUT/pi-error"
run_ok pi-error --harness pi --model mock-model --group workflow --keep t-one
t "Pi 助手报错不假绿" jq -e '.pass == false and (.error | contains("boom"))' "$OUT/pi-error/results.jsonl"

write_pi exit "$OUT/pi-exit"
run_ok pi-exit --harness pi --model mock-model --group workflow --keep t-one
t "Pi 非零退出不假绿" jq -e '.pass == false and (.error | contains("退出码 1"))' "$OUT/pi-exit/results.jsonl"

write_pi timeout "$OUT/pi-timeout"
JSTACK_EVAL_TIMEOUT=1 JSTACK_EVAL_KILL_GRACE=1 run_eval pi-timeout --harness pi --model mock-model --group workflow --keep t-one || true
t "Pi 超时标记且不留子进程" timeout_clean "$OUT/pi-timeout/results.jsonl" "$OUT/pi-timeout/child.pid"

write_pi ok "$OUT/pi-control"
run_ok pi-control --harness pi --model mock-model --group control --keep t-one
t "Pi 对照组：不加载 flow 扩展和 skill" bash -c '! grep -qx -- -e "$1" && ! grep -qx -- --skill "$1"' _ "$OUT/pi-control/pi-args.txt"
t "Pi 对照组：记录标记门禁关闭" jq -e '.group == "control" and .gates == "off"' "$OUT/pi-control/results.jsonl"

run_eval bad-harness --harness omp --model m >/dev/null 2>&1
t "未知 harness 拒绝运行" test "$?" -ne 0
t "未知 harness 有明确报错" grep -q '只能是 claude 或 pi' "$OUT/bad-harness/run.log"
run_eval no-model --harness pi >/dev/null 2>&1
t "Pi 不允许默认模型" test ! -e "$OUT/no-model/pi-args.txt"
t "Pi 缺模型有明确报错" grep -q '必须显式传 --model' "$OUT/no-model/run.log"
run_eval bad-nudges --harness pi --model mock-model --max-nudges 1 >/dev/null 2>&1
t "Pi 拒绝非零 max-nudges" grep -q 'max-nudges 只能是 0' "$OUT/bad-nudges/run.log"
run_eval bad-provider --harness claude --provider x --model m >/dev/null 2>&1
t "Claude 拒绝 --provider" grep -q '只用于 --harness pi' "$OUT/bad-provider/run.log"

write_claude "$OUT/claude-default"
run_ok claude-default --group workflow --model mock-claude --keep t-one
t "Claude 默认 harness 保持可用" jq -e '.harness == "claude" and .pass == true and .route == true' "$OUT/claude-default/results.jsonl"
t "Claude 工作流组：样本仓库装的是项目级产物" grep -qx project "$OUT/claude-default/claude-install.txt"
t "Claude 工作流组：不再用 --plugin-dir 加载插件" bash -c '! grep -qx -- --plugin-dir "$1"' _ "$OUT/claude-default/claude-args.txt"
t "Claude 工作流组：开 hooks 的 settings" grep -q '"disableAllHooks":false' "$OUT/claude-default/claude-args.txt"
t "Claude 记录：工作流组和门禁来源、Stop 拦截次数" jq -e '.group == "workflow" and .gates == "project" and .stop_blocks == 1' "$OUT/claude-default/results.jsonl"
t "旧记录仍可读且 harness 默认为 claude" legacy_readable "$ROOT/evals/results.jsonl"
t "样本环境：gbrain 指向沙箱占位并拒绝执行" bash -c 'p=$(cat "$1"); [ -n "$p" ] && [ -x "$p" ] && ! "$p" >/dev/null 2>&1 && "$p" 2>&1 | grep -q "沙箱里不可用"' _ "$OUT/claude-default/claude-gbrain.txt"
t "样本环境：gh 配置目录在沙箱里且为空" bash -c 'd=$(cat "$1"); [ -n "$d" ] && [ -d "$d" ] && [ -z "$(ls -A "$d")" ]' _ "$OUT/claude-default/claude-gh-config.txt"
t "样本环境：工作流组不加载用户级 hooks" bash -c '[ "$(cat "$1")" = false ]' _ "$OUT/claude-default/claude-user-hooks.txt"
t "样本环境：CLAUDE_CONFIG_DIR 在沙箱里" bash -c 'd=$(cat "$1"); [ -n "$d" ] && [ "$d" != "$HOME/.claude" ] && [ -d "$d" ]' _ "$OUT/claude-default/claude-config-dir.txt"

write_claude "$OUT/claude-control"
run_ok claude-control --group control --model mock-claude --keep t-one
t "Claude 对照组：没有项目级安装产物" grep -qx none "$OUT/claude-control/claude-install.txt"
t "Claude 对照组：关掉全部 hooks" grep -q '"disableAllHooks":true' "$OUT/claude-control/claude-args.txt"
t "Claude 对照组：记录标记门禁关闭" jq -e '.group == "control" and .gates == "off" and .stop_blocks == 0' "$OUT/claude-control/results.jsonl"
t "样本环境：对照组同样不加载用户级 hooks" bash -c '[ "$(cat "$1")" = false ]' _ "$OUT/claude-control/claude-user-hooks.txt"

write_claude "$OUT/claude-answer" multi
run_ok claude-answer --group control --model mock-claude --keep t-multi
t "Claude 答案取整个 result：第一行还在" grep -qx 'first line' "$OUT"/claude-answer/scratch/*/t-multi-1-control/answer-1.txt
t "Claude 答案取整个 result：最后一行还在" grep -qx 'second line' "$OUT"/claude-answer/scratch/*/t-multi-1-control/answer-1.txt

run_eval bad-group --model mock-claude --group vanilla >/dev/null 2>&1
t "未知组拒绝运行" grep -q 'group 只能是' "$OUT/bad-group/run.log"

[ "$fails" -eq 0 ]
