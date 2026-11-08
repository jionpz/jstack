#!/usr/bin/env bash
# jstack eval：用 claude -p headless 跑 evals/tasks 里的固定任务，衡量工作流本身。
#
#   ./jstack eval [--samples N] [--jobs N] [--model M] [--max-nudges N] [--keep] [任务名...]
#   ./jstack eval list
#   ./jstack eval --selftest [任务名...]   不调模型：初始状态 check 必须失败，参考解下必须通过
#
# 环境变量：JSTACK_EVAL_TASKS（任务目录）、JSTACK_EVAL_FIXTURE（种子项目）、
# JSTACK_EVAL_TIMEOUT（每轮秒数，默认 1800）、JSTACK_PREMIUM_MODELS（premium 模型名正则）。
# 不传 --model 时用用户级配置（~/.jstack/config.json，旧 ~/.config/jstack/models.json）
# 里 claude-code 的 bulk[0]；读不到就拒绝运行，不跟随 Claude Code 的默认模型。
set -euo pipefail
# 变量后紧跟中文标点时必须写成 ${VAR}（macOS bash 3.2 会把标点首字节算进变量名）。

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TASKS_DIR=${JSTACK_EVAL_TASKS:-$ROOT/evals/tasks}
FIXTURE=${JSTACK_EVAL_FIXTURE:-$ROOT/evals/fixture}
TIMEOUT=${JSTACK_EVAL_TIMEOUT:-1800}
PREMIUM=${JSTACK_PREMIUM_MODELS:-'(^|/)(claude|anthropic)|opus'}
NUDGE='我现在不在电脑前，回答不了问题。需要决定的地方按你推荐的方案处理，把这件事做完。'
# 关掉用户已装的 jstack 插件（改用仓库里的构建产物）和用户 hooks。
SETTINGS='{"disableAllHooks":true,"enabledPlugins":{"pstack@jstack":false,"spec@jstack":false,"flow@jstack":false}}'
SANDBOX= KEEP=

# 输入：每轮一个数组（该轮 stream-json 的全部事件）。输出：一个样本的记录。
read -r -d '' RECORD_JQ <<'JQ' || true
def tokens_of($re): [(.modelUsage // {}) | to_entries[] | select(.key | test($re)) | .value
  | (.inputTokens // 0) + (.outputTokens // 0) + (.cacheReadInputTokens // 0) + (.cacheCreationInputTokens // 0)] | add // 0;
# --resume 之后 result 里的 modelUsage 和 total_cost_usd 是整个会话的累计值，所以按轮取增量；
# 某轮比上一轮小，说明累计没有续上，按原值计。
def delta(f): reduce (.[] | select(. != null) | f) as $v ({prev: 0, sum: 0};
  {prev: $v, sum: (.sum + (if $v >= .prev then $v - .prev else $v end))}) | .sum;
def is_skill($name): .name == "Skill" and ((.input.skill // "") | tostring | endswith($name));

. as $rounds
| [$rounds[] | map(select(.type == "result")) | last] as $res
| [$rounds[][] | select(.type == "assistant" and (.parent_tool_use_id // null) == null)
   | .message.content[]? | select(.type == "tool_use")] as $tools
| {
    run_id: $run_id, date: $date, commit: $commit,
    model: (first($rounds[][] | select(.type == "system" and .subtype == "init") | .model) // null),
    task: $task, sample: $sample, pass: ($pass == 1), timed_out: ($timed_out == 1),
    rounds: ($rounds | length), nudges: $nudges,
    turns: ([$res[] | select(. != null) | .num_turns // 0] | add // 0),
    wall_s: $wall,
    tokens: ($res | delta(tokens_of(""))),
    premium_tokens: ($res | delta(tokens_of($premium))),
    cost_usd: ($res | delta(.total_cost_usd // 0) | . * 1000000 | round / 1000000),
    route: any($tools[]; is_skill("route")),
    poteto: any($tools[]; is_skill("poteto-mode")
      or (.name == "Read" and ((.input.file_path // "") | tostring | endswith("poteto-mode/SKILL.md")))),
    subagents: ([$tools[] | select(.name == "Agent" or .name == "Task")] | length),
    error: (if $timed_out == 1 then null else
      first(range(0; $res | length) as $i | $res[$i] as $r
        | if $r == null then "第 \($i + 1) 轮没有 result 事件（退出码 \($rcs[$i])）"
          elif $r.is_error then "第 \($i + 1) 轮出错（\($r.subtype)）：\($r.result // "" | tostring | .[0:200])"
          else empty end) // null end)
  }
JQ

# 输入：本次运行的全部记录。输出：报告里的一节。
read -r -d '' REPORT_JQ <<'JQ' || true
def r1: . * 10 | round / 10;
def avg(f): (map(f) | add) / length | r1;
def frac(f): "\(map(select(f)) | length)/\(length)";
def row($name): "| \($name) | \(frac(.pass)) | \(avg(.nudges)) | \(avg(.turns)) | \(avg(.wall_s)) | \(map(.tokens) | add) | \(map(.premium_tokens) | add) | \(frac(.route)) | \(frac(.poteto)) | \(avg(.subagents)) |";

. as $all
| ([$all[].model | select(. != null)] | unique | join(", ")) as $models
| [$all[] | select(.error != null) | "\(.task) #\(.sample)：\(.error)"] as $errors
| ["## \($run_id)", "",
   "- commit: `\($commit)`",
   "- model: \(if $models == "" then "未知" else $models end)",
   "- 样本: \($all | length)（每个任务 \($samples) 个）",
   "- max-nudges: \($max_nudges)"]
  + (if $errors == [] then [] else ["- 出错样本: " + ($errors | join("；"))] end)
  + ["",
     "| 任务 | 通过 | 平均打断 | 平均 turns | 平均耗时 (s) | tokens | premium tokens | route | poteto | 平均子 agent |",
     "|---|---|---|---|---|---|---|---|---|---|"]
  + ($all | group_by(.task) | map(row(.[0].task)))
  + [$all | row("**合计**")]
| join("\n")
JQ

die() { printf 'jstack eval: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
is_uint() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }

# 用户级配置：新路径优先，旧 models.json 兜底（还没运行过 models 迁移时）。
user_config() {
	local cfg=${JSTACK_USER_CONFIG:-$HOME/.jstack/config.json}
	if [ -f "$cfg" ]; then printf '%s\n' "$cfg"; return 0; fi
	cfg=$HOME/.config/jstack/models.json
	[ -f "$cfg" ] && { printf '%s\n' "$cfg"; return 0; }
	return 1
}

# 没给 --model 时的默认模型：用户级配置里 claude-code 的 bulk[0]。
# 读不到就返回空，由 cmd_run 拒绝运行，避免跟随 Claude Code 默认模型跑到 premium。
default_model() {
	local cfg
	cfg=$(user_config) || return 1
	jq -r '(.models // .harnesses // {})["claude-code"].bulk[0] // empty' "$cfg" 2>/dev/null
}
cleanup() { [ -z "$SANDBOX" ] || [ -n "$KEEP" ] || rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 被测 agent 看到的路径里不能有 eval、test、judge、benchmark 这类元词。
make_sandbox() {
	SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}"/ws.XXXXXX)
	SANDBOX=$(cd "$SANDBOX" && pwd -P)
	if printf '%s' "$SANDBOX" | grep -qiE 'eval|test|judge|bench'; then
		die "临时目录 $SANDBOX 含有元词，会破坏盲测；把 TMPDIR 换到别处再运行"
	fi
}

all_tasks() {
	[ -d "$TASKS_DIR" ] || die "没有任务目录 $TASKS_DIR"
	(cd "$TASKS_DIR" && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done) | LC_ALL=C sort
}

# 任务名参数为空时取全部任务；否则核对每个名字存在。结果写到 TASKS（空格分隔）。
pick_tasks() {
	local t
	if [ $# -eq 0 ]; then
		TASKS=$(all_tasks | tr '\n' ' ')
	else
		TASKS=
		for t in "$@"; do
			[ -d "$TASKS_DIR/$t" ] || die "没有任务 ${t}，可选：$(all_tasks | tr '\n' ' ')"
			TASKS="$TASKS $t"
		done
	fi
	[ -n "${TASKS// /}" ] || die "$TASKS_DIR 下没有任务"
}

# 按题目契约准备工作目录：fixture、seed、git init 后提交一次。打印工作目录路径。
prepare_workdir() {
	local task=$1 work
	work="$(mktemp -d "$SANDBOX/XXXXXXXX")/tasknotes"
	mkdir -p "$work"
	cp -R "$FIXTURE/." "$work/"
	[ ! -d "$TASKS_DIR/$task/seed" ] || cp -R "$TASKS_DIR/$task/seed/." "$work/"
	git -C "$work" -c init.defaultBranch=main init -q
	git -C "$work" add -A
	git -C "$work" -c user.name=tasknotes -c user.email=tasknotes@localhost -c commit.gpgsign=false \
		-c core.hooksPath=/dev/null commit -qm 'initial commit'
	printf '%s\n' "$work"
}

# 在工作目录 $2 跑任务 $1 的 check.sh，ANSWER_FILE=$3，输出写到 $4。
run_check() {
	(cd "$2" && ANSWER_FILE=$3 bash "$TASKS_DIR/$1/check.sh") </dev/null >"$4" 2>&1
}

# 在工作目录 $1 用干净环境跑一轮 claude，stdout/stderr 写到 $2/$3；超过 TIMEOUT 秒就杀掉并创建 $4。
# macOS 没有 timeout 命令，用后台看门狗。其余参数原样传给 claude。
run_claude() {
	local work=$1 out=$2 err=$3 flag=$4 pid wd rc=0 deadline
	shift 4
	local env_args=(HOME="$HOME" USER="${USER:-$(id -un)}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}"
		TMPDIR="${TMPDIR:-/tmp}" SHELL=/bin/zsh)
	[ -z "${LC_ALL:-}" ] || env_args+=(LC_ALL="$LC_ALL")
	(cd "$work" && exec env -i "${env_args[@]}" claude "$@") </dev/null >"$out" 2>"$err" &
	pid=$!
	deadline=$(($(date +%s) + TIMEOUT))
	(
		while kill -0 "$pid" 2>/dev/null; do
			if [ "$(date +%s)" -ge "$deadline" ]; then
				: >"$flag"
				kill -TERM "$pid" 2>/dev/null || true
				sleep 10
				kill -KILL "$pid" 2>/dev/null || true
				exit 0
			fi
			sleep 1
		done
	) &
	wd=$!
	wait "$pid" || rc=$?
	wait "$wd" || true
	return $rc
}

# 一个样本：第一轮发 prompt，check 不通过就 --resume 催促，最多 MAX_NUDGES 次。记录写到 record.json。
run_sample() {
	local task=$1 n=$2 dir="$RUN_DIR/$1-$2" work base start round=1 nudges=0 pass=0 timed_out=0 sid msg rcs= rc
	local plugin_args=(--plugin-dir "$ROOT/plugins/pstack" --plugin-dir "$ROOT/plugins/spec" --plugin-dir "$ROOT/plugins/flow")
	[ -z "$MODEL" ] || plugin_args+=(--model "$MODEL")
	mkdir -p "$dir"
	work=$(prepare_workdir "$task")
	base=$(git -C "$work" rev-parse HEAD)
	msg=$(cat "$TASKS_DIR/$task/prompt.md")
	sid=
	start=$(date +%s)
	say "→ $task #$n 开始"
	while :; do
		rc=0
		if [ -z "$sid" ]; then
			run_claude "$work" "$dir/round-$round.jsonl" "$dir/round-$round.err" "$dir/timed-out" \
				-p "$msg" --output-format stream-json --verbose --permission-mode bypassPermissions \
				--strict-mcp-config --settings "$SETTINGS" "${plugin_args[@]}" || rc=$?
		else
			run_claude "$work" "$dir/round-$round.jsonl" "$dir/round-$round.err" "$dir/timed-out" \
				-p "$NUDGE" --resume "$sid" --output-format stream-json --verbose --permission-mode bypassPermissions \
				--strict-mcp-config --settings "$SETTINGS" "${plugin_args[@]}" || rc=$?
		fi
		rcs="$rcs${rcs:+,}$rc"
		if [ -e "$dir/timed-out" ]; then
			timed_out=1
			break
		fi
		jq -Rr 'fromjson? | select(.type=="result") | .result // "" | tostring' "$dir/round-$round.jsonl" >"$dir/answer-$round.txt" || true
		if run_check "$task" "$work" "$dir/answer-$round.txt" "$dir/check-$round.txt"; then
			pass=1
			break
		fi
		sid=$(jq -Rr 'fromjson? | select(.type=="result") | .session_id // empty' "$dir/round-$round.jsonl" | tail -1 || true)
		[ "$nudges" -lt "$MAX_NUDGES" ] && [ -n "$sid" ] || break
		nudges=$((nudges + 1))
		round=$((round + 1))
	done
	(git -C "$work" add -A && git -C "$work" diff --cached --binary "$base") >"$dir/diff.patch" 2>/dev/null || true
	if [ -n "$KEEP" ]; then
		say "  $task #$n 的工作目录保留在 $work"
	else
		rm -rf "$(dirname "$work")"
	fi
	local r
	for r in $(seq 1 "$round"); do
		jq -cRn '[inputs | fromjson? | objects]' "$dir/round-$r.jsonl"
	done | jq -cs \
		--arg run_id "$RUN_ID" --arg date "$RUN_DATE" --arg commit "$COMMIT" --arg task "$task" \
		--argjson sample "$n" --argjson pass "$pass" --argjson timed_out "$timed_out" \
		--argjson nudges "$nudges" --argjson wall "$(($(date +%s) - start))" \
		--argjson rcs "[$rcs]" --arg premium "$PREMIUM" "$RECORD_JQ" >"$dir/record.json"
	say "$([ "$pass" = 1 ] && echo ✓ || echo ✗) $task #$n：$([ "$pass" = 1 ] && echo 通过 || echo 未通过)，$round 轮，催促 $nudges 次，$(jq -r .wall_s "$dir/record.json") 秒$([ "$timed_out" = 1 ] && echo "，超时")"
}

cmd_run() {
	local samples=1 jobs=1 t n i=0 pids=() records report section
	MODEL= MAX_NUDGES=2
	while [ $# -gt 0 ]; do
		case $1 in
		--samples) samples=${2:-}; shift 2 || die "--samples 后面要跟数字" ;;
		--jobs) jobs=${2:-}; shift 2 || die "--jobs 后面要跟数字" ;;
		--model) MODEL=${2:-}; shift 2 || die "--model 后面要跟模型名" ;;
		--max-nudges) MAX_NUDGES=${2:-}; shift 2 || die "--max-nudges 后面要跟数字" ;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		-*) die "未知参数：$1" ;;
		*) break ;;
		esac
	done
	is_uint "$samples" && [ "$samples" -ge 1 ] || die "--samples 要是正整数"
	is_uint "$jobs" && [ "$jobs" -ge 1 ] || die "--jobs 要是正整数"
	is_uint "$MAX_NUDGES" || die "--max-nudges 要是非负整数"
	is_uint "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || die "JSTACK_EVAL_TIMEOUT 要是正整数（秒）"
	for t in jq git node claude; do command -v "$t" >/dev/null || die "缺少依赖 $t"; done
	[ -d "$FIXTURE" ] || die "没有种子项目 $FIXTURE"
	if [ -z "$MODEL" ]; then
		MODEL=$(default_model || true)
		[ -n "$MODEL" ] || die "没有 --model，也读不到用户级配置里的 models.claude-code.bulk[0]；显式传 --model，或先运行 ./jstack models set"
		say "模型 $MODEL（用户级配置的 claude-code.bulk[0]）"
	else
		say "模型 $MODEL（--model）"
	fi
	pick_tasks "$@"
	for t in $TASKS; do
		[ -f "$TASKS_DIR/$t/prompt.md" ] && [ -f "$TASKS_DIR/$t/check.sh" ] || die "任务 $t 缺少 prompt.md 或 check.sh"
	done

	RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
	RUN_DATE=$(date +%Y-%m-%d)
	COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)
	[ -z "$(git -C "$ROOT" status --porcelain)" ] || COMMIT="$COMMIT-dirty"
	RUN_DIR="$ROOT/.scratch/evals/$RUN_ID"
	mkdir -p "$RUN_DIR"
	make_sandbox
	say "评测 $RUN_ID：任务 $(echo $TASKS)，每个 $samples 个样本，并发 $jobs，max-nudges ${MAX_NUDGES}，原始材料在 .scratch/evals/$RUN_ID"

	# 每个样本写自己的 record.json，全部结束后按任务和样本顺序合并，避免并发写同一文件。
	for t in $TASKS; do
		for n in $(seq 1 "$samples"); do
			[ "$i" -lt "$jobs" ] || wait "${pids[$((i - jobs))]}" || true
			run_sample "$t" "$n" &
			pids[i]=$!
			i=$((i + 1))
		done
	done
	wait || true

	records="$RUN_DIR/records.jsonl"
	: >"$records"
	for t in $TASKS; do
		for n in $(seq 1 "$samples"); do
			if [ -s "$RUN_DIR/$t-$n/record.json" ]; then
				cat "$RUN_DIR/$t-$n/record.json" >>"$records"
			else
				say "✗ $t #$n 没有产生记录，见 .scratch/evals/$RUN_ID/$t-$n"
			fi
		done
	done
	[ -s "$records" ] || die "没有任何样本产生记录"
	cat "$records" >>"$ROOT/evals/results.jsonl"

	mkdir -p "$ROOT/evals/reports"
	report="$ROOT/evals/reports/$RUN_DATE.md"
	[ -f "$report" ] || printf '# 工作流评测 %s\n' "$RUN_DATE" >"$report"
	section=$(jq -rs --arg run_id "$RUN_ID" --arg commit "$COMMIT" --argjson samples "$samples" \
		--argjson max_nudges "$MAX_NUDGES" "$REPORT_JQ" "$records")
	printf '\n%s\n' "$section" >>"$report"
	say ""
	say "$section"
	say ""
	say "记录已追加到 evals/results.jsonl，报告在 ${report#"$ROOT"/}"
}

# 不调模型地验证每个任务：初始状态下 check 必须失败，打上参考解后必须通过。
cmd_selftest() {
	local t dir work empty bad=0 log ans
	for t in jq git node; do command -v "$t" >/dev/null || die "缺少依赖 $t"; done
	[ -d "$FIXTURE" ] || die "没有种子项目 $FIXTURE"
	pick_tasks "$@"
	make_sandbox
	empty="$SANDBOX/empty"
	: >"$empty"
	for t in $TASKS; do
		dir="$TASKS_DIR/$t" log="$SANDBOX/$t.log"
		if [ ! -f "$dir/prompt.md" ] || [ ! -f "$dir/check.sh" ]; then
			say "✗ ${t}：缺少 prompt.md 或 check.sh"
			bad=1
			continue
		fi
		work=$(prepare_workdir "$t")
		if run_check "$t" "$work" "$empty" "$log"; then
			say "✗ ${t}：初始状态下 check 就通过了"
			bad=1
			continue
		fi
		work=$(prepare_workdir "$t")
		if [ -f "$dir/solution.patch" ] && ! git -C "$work" apply "$dir/solution.patch" 2>"$log"; then
			say "✗ ${t}：solution.patch 打不上"
			sed 's/^/  /' "$log" | tail -5
			bad=1
			continue
		fi
		ans=$empty
		[ ! -f "$dir/answer.md" ] || ans="$dir/answer.md"
		if ! run_check "$t" "$work" "$ans" "$log"; then
			say "✗ ${t}：参考解下 check 没有通过"
			sed 's/^/  /' "$log" | tail -10
			bad=1
			continue
		fi
		say "✓ ${t}：初始状态失败，参考解通过"
	done
	return $bad
}

case "${1:-}" in
list) all_tasks ;;
--selftest) shift; cmd_selftest "$@" ;;
*) cmd_run "$@" ;;
esac
