#!/usr/bin/env bash
# jstack eval：用 claude -p 或 pi -p headless 跑 evals/tasks 里的固定任务，衡量工作流本身。
#
#   ./jstack eval [--harness claude|pi] [--provider P] [--thinking L] [--samples N] [--jobs N]
#                 [--model M] [--max-nudges N] [--group workflow|control|both] [--keep] [任务名...]
#   ./jstack eval list
#   ./jstack eval --selftest [任务名...]   不调模型：初始状态 check 必须失败，参考解下必须通过
#
# 默认 --harness claude，保持旧行为和旧基线可读；--harness pi 必须显式 --model，单轮运行，
# 因此 --max-nudges 只能是 0。--provider / --thinking 只用于 Pi。
# 默认 --group both：每个任务跑两遍，工作流组和对照组并排。工作流组的样本仓库先做
# ./jstack install --scope project，Claude Code 从 .claude/skills 读入口、从 .claude/settings.json
# 跑 flow 的 prompt / guard / stop hooks，门禁真的生效；对照组去掉 seed 里指导走工作流的文件，
# 不装插件、不开 hooks。--group workflow 或 control 只跑一组，用于调试。
# 环境变量：JSTACK_EVAL_TASKS（任务目录）、JSTACK_EVAL_FIXTURE（种子项目）、
# JSTACK_EVAL_TIMEOUT（每轮秒数，默认 1800）、JSTACK_EVAL_KILL_GRACE（超时后 TERM 到 KILL 的秒数，默认 10）、
# JSTACK_PREMIUM_MODELS（premium 模型名正则）。测试还可以覆盖 JSTACK_EVAL_RESULTS、
# JSTACK_EVAL_REPORTS、JSTACK_EVAL_SCRATCH，避免写仓库里的基线。
# 不传 --model 时 Claude 用用户级配置（~/.jstack/config.json，旧 ~/.config/jstack/models.json）
# 里 claude-code 的 bulk[0]；读不到就拒绝运行，不跟随 Claude Code 的默认模型。Pi 从不猜模型。
set -euo pipefail
# 变量后紧跟中文标点时必须写成 ${VAR}（macOS bash 3.2 会把标点首字节算进变量名）。

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TASKS_DIR=${JSTACK_EVAL_TASKS:-$ROOT/evals/tasks}
FIXTURE=${JSTACK_EVAL_FIXTURE:-$ROOT/evals/fixture}
TIMEOUT=${JSTACK_EVAL_TIMEOUT:-1800}
PREMIUM=${JSTACK_PREMIUM_MODELS:-'(^|/)(claude|anthropic)|opus'}
GRACE=${JSTACK_EVAL_KILL_GRACE:-10}
RESULTS=${JSTACK_EVAL_RESULTS:-$ROOT/evals/results.jsonl}
REPORTS=${JSTACK_EVAL_REPORTS:-$ROOT/evals/reports}
SCRATCH=${JSTACK_EVAL_SCRATCH:-$ROOT/.scratch/evals}
NUDGE='我现在不在电脑前，回答不了问题。需要决定的地方按你推荐的方案处理，把这件事做完。'
# 工作流组：关掉用户已装的 jstack marketplace 插件（样本仓库用的是项目级安装的 vendor 树），
# 但保留项目 .claude/settings.json 里的 flow hooks，门禁才真的生效。
SETTINGS='{"disableAllHooks":false,"enabledPlugins":{"pstack@jstack":false,"spec@jstack":false,"flow@jstack":false}}'
# 对照组：不加载任何 jstack 入口，连用户自己的 hooks 也关掉，比较的基线只有模型本身。
SETTINGS_CONTROL='{"disableAllHooks":true,"enabledPlugins":{"pstack@jstack":false,"spec@jstack":false,"flow@jstack":false}}'
SANDBOX= KEEP= HARNESS=claude MODEL= PROVIDER= THINKING= MAX_NUDGES= GROUP=both
# 每个样本额外传给 agent 的环境（见 isolate_sample）：沙箱里的 PATH、GH_CONFIG_DIR、CLAUDE_CONFIG_DIR。
SAMPLE_ENV=()

# 输入：每轮一个数组（该轮 stream-json 的全部事件）。输出：一个样本的记录。
read -r -d '' RECORD_JQ <<'JQ' || true
def tokens_of($re): [(.modelUsage // {}) | to_entries[] | select(.key | test($re)) | .value
  | (.inputTokens // 0) + (.outputTokens // 0) + (.cacheReadInputTokens // 0) + (.cacheCreationInputTokens // 0)] | add // 0;
# --resume 之后 result 里的 modelUsage 和 total_cost_usd 是整个会话的累计值，所以按轮取增量；
# 某轮比上一轮小，说明累计没有续上，按原值计。
def delta(f): reduce (.[] | select(. != null) | f) as $v ({prev: 0, sum: 0};
  {prev: $v, sum: (.sum + (if $v >= .prev then $v - .prev else $v end))}) | .sum;
def is_skill($name): .name == "Skill" and ((.input.skill // "") | tostring | endswith($name));
# Stop hook 拦下一次结束时，Claude Code 把理由作为一条 user 消息塞回会话，前缀固定。
# 数它就是门禁真正拦住过几次；对照组和没有进入 execute 的样本应为 0。
def stop_blocks: [.[][]
  | select(.type == "user")
  | (.message.content // empty)
  | (if type == "array" then .[] else . end)
  | select(type == "object" and .type == "text")
  | .text | strings
  | select(startswith("Stop hook feedback:"))] | length;

. as $rounds
| [$rounds[] | map(select(.type == "result")) | last] as $res
| [$rounds[][] | select(.type == "assistant" and (.parent_tool_use_id // null) == null)
   | .message.content[]? | select(.type == "tool_use")] as $tools
| {
    run_id: $run_id, date: $date, commit: $commit,
    harness: "claude", provider: null, thinking: null,
    model: (first($rounds[][] | select(.type == "system" and .subtype == "init") | .model) // null),
    task: $task, sample: $sample, group: $group, gates: $gates,
    pass: ($pass == 1), timed_out: ($timed_out == 1),
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
    stop_blocks: stop_blocks,
    error: (if $timed_out == 1 then null else
      first(range(0; $res | length) as $i | $res[$i] as $r
        | if $r == null then "第 \($i + 1) 轮没有 result 事件（退出码 \($rcs[$i])）"
          elif ($rcs[$i] // 0) != 0 then "第 \($i + 1) 轮退出码 \($rcs[$i])"
          elif $r.is_error then "第 \($i + 1) 轮出错（\($r.subtype)）：\($r.result // "" | tostring | .[0:200])"
          else empty end) // null end)
  }
JQ

# 输入：本次运行的全部记录。输出：报告里的一节。
read -r -d '' REPORT_JQ <<'JQ' || true
def r1: . * 10 | round / 10;
def avg(f): (map(f) | add) / length | r1;
def frac(f): "\(map(select(f)) | length)/\(length)";
def sumf(f): (map(f) | map(select(. != null)) | if length == 0 then "未知" else add end);
# 旧记录没有 group：按老约定，任务名以 -vanilla 结尾的是对照组。
def grp: (.group // (if (.task | endswith("-vanilla")) then "control" else "workflow" end));
def gname: if (.[0] | grp) == "workflow" then "工作流" else "对照" end;
def gates: ([.[].gates // "off"] | unique | join(","));
def row($name): "| \($name) | \(gname) | \(frac(.pass)) | \(avg(.nudges)) | \(avg(.turns)) | \(avg(.wall_s)) | \(sumf(.tokens)) | \(sumf(.premium_tokens)) | \(frac(.route)) | \(frac(.poteto)) | \(avg(.subagents)) | \(sumf(.stop_blocks // 0)) | \(gates) |";

. as $all
| ([$all[].model | select(. != null)] | unique | join(", ")) as $models
| ([$all[].harness // "claude"] | unique | join(", ")) as $harnesses
| ([$all[] | .provider // empty] | unique | join(", ")) as $providers
| ([$all[] | .thinking // empty] | unique | join(", ")) as $thinkings
| ([$all[] | grp] | unique | join(", ")) as $groups
| [$all[] | select(.error != null) | "\(.task) [\(.sample)]：\(.error)"] as $errors
| ["## \($run_id)", "",
   "- commit: `\($commit)`",
   "- harness: \($harnesses)",
   "- provider: \(if $providers == "" then "—" else $providers end)",
   "- thinking: \(if $thinkings == "" then "—" else $thinkings end)",
   "- model: \(if $models == "" then "未知" else $models end)",
   "- 组: \($groups)",
   "- 样本: \($all | length)（每个任务 \($samples) 个 × \([$all[] | grp] | unique | length) 组）",
   "- max-nudges: \($max_nudges)"]
  + (if $harnesses == "pi" then ["- 说明: Pi 单轮运行，nudges 固定 0；不要直接拿它和 claude 的打断次数比较"] else [] end)
  + (if $errors == [] then [] else ["- 出错样本: " + ($errors | join("；"))] end)
  + ["",
     "| 任务 | 组 | 通过 | 平均打断 | 平均 turns | 平均耗时 (s) | tokens | premium tokens | route | poteto | 平均子 agent | Stop 拦截 | 门禁 |",
     "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
  + ($all | sort_by(.task, (if grp == "workflow" then 0 else 1 end)) | group_by([.task, grp]) | map(row(.[0].task)))
  + ($all | sort_by(grp) | group_by(grp) | map(row("**合计**")))
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

# 把当前工作区的构建产物按 `./jstack install --scope project` 装进样本仓库：入口 skill 在
# .claude/skills，flow 的 prompt / guard / stop hooks 在 .claude/settings.json（命令指向 .jstack/vendor）。
# 安装产物写进 .git/info/exclude，既不进初始提交，也不出现在样本的 diff.patch 里。
install_project_sample() {
	local work=$1 log
	log=$(dirname "$work")/install.log
	"$ROOT/jstack" install --scope project --repo "$work" >"$log" 2>&1 || {
		say "  ✗ 项目级安装失败，日志在 $log"
		tail -5 "$log" | sed 's/^/    /'
		return 1
	}
	printf '/.jstack/\n/.claude/\n' >>"$work/.git/info/exclude"
}

# 按题目契约准备工作目录：fixture、seed、git init 后提交一次。打印工作目录路径。
# 第二个参数是组：workflow 装项目级产物（门禁生效）并带完整 seed；control 去掉 seed 里指导
# 走工作流的说明文件（题目本身要的坏代码、仓库约定保留）；plain 什么都不装，自检用。
prepare_workdir() {
	local task=$1 mode=${2:-plain} work f
	work="$(mktemp -d "$SANDBOX/XXXXXXXX")/tasknotes"
	mkdir -p "$work"
	cp -R "$FIXTURE/." "$work/"
	if [ -d "$TASKS_DIR/$task/seed" ]; then
		cp -R "$TASKS_DIR/$task/seed/." "$work/"
		if [ "$mode" = control ]; then
			for f in AGENTS.override.md AGENTS.md CLAUDE.md; do rm -f "$work/$f"; done
		fi
	fi
	git -C "$work" -c init.defaultBranch=main init -q || return 1
	if [ "$mode" = workflow ] && [ "$HARNESS" = claude ]; then
		install_project_sample "$work" || return 1
	fi
	git -C "$work" add -A || return 1
	git -C "$work" -c user.name=tasknotes -c user.email=tasknotes@localhost -c commit.gpgsign=false \
		-c core.hooksPath=/dev/null commit -qm 'initial commit' || return 1
	printf '%s\n' "$work"
}

# 在工作目录 $2 跑任务 $1 的 check.sh，ANSWER_FILE=$3，输出写到 $4。
run_check() {
	(cd "$2" && ANSWER_FILE=$3 bash "$TASKS_DIR/$1/check.sh") </dev/null >"$4" 2>&1
}

# 在工作目录 $1 用干净环境跑一轮 agent，stdout/stderr 写到 $2/$3；超过 TIMEOUT 秒就杀掉整个进程组并创建 $4。
# $5 是门禁状态目录；其余参数是命令和原生参数。macOS 没有 timeout 命令，用后台看门狗；
# set -m 让子进程成为进程组组长，超时用负 PID 杀掉整组，避免留下 shell 子进程。
run_agent() {
	local work=$1 out=$2 err=$3 flag=$4 state=$5 pid wd rc=0 deadline had_m=0 n
	shift 5
	local env_args=(HOME="$HOME" USER="${USER:-$(id -un)}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}"
		TMPDIR="${TMPDIR:-/tmp}" SHELL=/bin/zsh JSTACK_STATE_DIR="$state")
	env_args+=("${SAMPLE_ENV[@]}")
	[ -z "${LC_ALL:-}" ] || env_args+=(LC_ALL="$LC_ALL")
	case $- in *m*) had_m=1 ;; esac
	set -m
	(cd "$work" && exec env -i "${env_args[@]}" "$@") </dev/null >"$out" 2>"$err" &
	pid=$!
	[ "$had_m" = 1 ] || set +m
	deadline=$(($(date +%s) + TIMEOUT))
	(
		while kill -0 "$pid" 2>/dev/null; do
			if [ "$(date +%s)" -ge "$deadline" ]; then
				: >"$flag"
				kill -TERM -"$pid" 2>/dev/null || true
				n=0
				while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$GRACE" ]; do
					sleep 1
					n=$((n + 1))
				done
				kill -KILL -"$pid" 2>/dev/null || true
				exit 0
			fi
			sleep 1
		done
	) &
	wd=$!
	wait "$pid" 2>/dev/null || rc=$?
	wait "$wd" || true
	if kill -0 -"$pid" 2>/dev/null; then
		kill -TERM -"$pid" 2>/dev/null || true
		sleep 1
		kill -KILL -"$pid" 2>/dev/null || true
	fi
	return $rc
}

# Pi 的答案在最后一条非空助手文本里；Claude 的答案在最后一个 result 事件的全文里。
# 不能对 jq 的输出接 tail -1：那取的是答案文本的最后一行，不是最后一个 result 事件。
extract_answer() {
	case $HARNESS in
	pi) jq -Rrs 'split("\n") | map(fromjson? | select(.type == "message_end" and .message.role == "assistant") | .message.content
		| if type == "string" then . else ([.[]? | select(.type? == "text") | .text // ""] | join("\n")) end)
		| map(select(length > 0)) | last // ""' "$1" ;;
	*) jq -Rrs 'split("\n") | map(fromjson? | select(.type == "result")) | last | .result // "" | tostring' "$1" ;;
	esac
}

# 本轮是否干净结束：Claude 要有非 error 的 result；Pi 要有 agent_end，且最后一条助手消息不是 error/aborted/length。
claude_round_ok() {
	jq -R -s -e '
		[split("\n")[] | fromjson? | objects] as $ev
		| ([$ev[] | select(.type == "result")] | last) as $r
		| ($r != null) and (($r.is_error // false) == false)
	' "$1" >/dev/null 2>&1
}
pi_round_ok() {
	jq -R -s -e '
		[split("\n")[] | fromjson? | objects] as $ev
		| ([$ev[] | select(.type == "message_end" and .message.role == "assistant")] | length) > 0
		and any($ev[]; .type == "agent_end")
		and (([$ev[] | select(.type == "message_end" and .message.role == "assistant") | .message.stopReason] | last)
		  | . != "error" and . != "aborted" and . != "length")
	' "$1" >/dev/null 2>&1
}
round_ok_fn() {
	case $HARNESS in pi) pi_round_ok "$1" ;; *) claude_round_ok "$1" ;; esac
}

# 记录生成失败时也要留下一条可读记录，不能让样本静默消失。
record_fallback() {
	local file=$1 task=$2 sample=$3 rounds=$4 pass=$5 timed_out=$6 nudges=$7 wall=$8 error=$9 group=${10} gates=${11}
	jq -cn --arg run_id "$RUN_ID" --arg date "$RUN_DATE" --arg commit "$COMMIT" --arg task "$task" \
		--arg harness "$HARNESS" --arg provider "$PROVIDER" --arg thinking "$THINKING" --arg model "$MODEL" \
		--arg group "$group" --arg gates "$gates" \
		--argjson sample "$sample" --argjson rounds "$rounds" --argjson pass "$pass" --argjson timed_out "$timed_out" \
		--argjson nudges "$nudges" --argjson wall "$wall" --arg error "$error" \
		'{run_id: $run_id, date: $date, commit: $commit, harness: $harness,
		  provider: (if $provider == "" then null else $provider end),
		  thinking: (if $thinking == "" then null else $thinking end),
		  model: (if $model == "" then null else $model end),
		  task: $task, sample: $sample, group: $group, gates: $gates,
		  pass: ($pass == 1), timed_out: ($timed_out == 1), rounds: $rounds,
		  nudges: $nudges, turns: 0, wall_s: $wall, tokens: null, premium_tokens: null, cost_usd: null,
		  route: false, poteto: false, subagents: 0, stop_blocks: 0, error: $error}' >"$file"
}

# 门禁来源，写进记录的 gates 字段：
#   project    Claude Code 从项目级安装的 .claude/settings.json 跑 flow hooks
#   extension  Pi 用 -e 显式加载 flow 扩展（Pi 的项目级入口要信任，eval 里不打开）
#   off        对照组，不加载任何 jstack 入口
gates_for() {
	if [ "$1" != workflow ]; then
		printf 'off\n'
	elif [ "$HARNESS" = pi ]; then
		printf 'extension\n'
	else
		printf 'project\n'
	fi
}

# 样本隔离（issue #83）：样本只能动自己的沙箱，两组只差装没装 jstack。
# - PATH 最前面放一个占位的 gbrain；写回失败时 archive 按既有降级把页面内容打印出来；
# - GH_CONFIG_DIR 指向空目录，gh 没有登录态，建不了真实 issue；
# - CLAUDE_CONFIG_DIR 只放用户 settings 里的网关 env：用户级 hooks、用户 CLAUDE.md 和用户插件都不加载，
#   工作流组仍然有样本仓库自己的项目级 flow hooks。HOME 保持真实，换掉会报 Not logged in。
isolate_sample() {
	local aux=$1
	mkdir -p "$aux/bin" "$aux/gh" "$aux/claude-config"
	cat >"$aux/bin/gbrain" <<'SH'
#!/bin/sh
echo "gbrain: jstack eval 沙箱里不可用" >&2
exit 1
SH
	chmod +x "$aux/bin/gbrain"
	if ! jq '{env: (.env // {})}' "$HOME/.claude/settings.json" >"$aux/claude-config/settings.json" 2>/dev/null; then
		printf '{}\n' >"$aux/claude-config/settings.json"
	fi
	SAMPLE_ENV=(PATH="$aux/bin:$PATH" GH_CONFIG_DIR="$aux/gh" CLAUDE_CONFIG_DIR="$aux/claude-config")
}

# 一个样本：第一轮发 prompt；Claude check 不通过就 --resume 催促，最多 MAX_NUDGES 次。
# Pi 单轮（MAX_NUDGES 固定 0），记录写到 record.json；只有 check 通过、退出码 0、且本轮干净结束时才算通过。
# 第三个参数是组：workflow 或 control。
run_sample() {
	local task=$1 n=$2 group=$3 gates dir="$RUN_DIR/$1-$2-$3" work base start round=1 nudges=0 pass=0 timed_out=0 sid msg rcs= rc=0 state_dir=
	local ctx= check_ok=0 round_ok=0 f pi_args claude_args record_ok=0
	gates=$(gates_for "$group")
	mkdir -p "$dir"
	work=$(prepare_workdir "$task" "$group") || { say "✗ $task [$group] #${n}：准备工作目录失败"; return 1; }
	state_dir=$(dirname "$work")/gates
	isolate_sample "$(dirname "$work")"
	base=$(git -C "$work" rev-parse HEAD)
	msg=$(cat "$TASKS_DIR/$task/prompt.md")
	for f in AGENTS.override.md AGENTS.md CLAUDE.md; do
		if [ -f "$work/$f" ]; then ctx="$work/$f"; break; fi
	done
	start=$(date +%s)
	say "→ $task [$group] #$n 开始"
	while :; do
		rc=0
		if [ "$HARNESS" = pi ]; then
			pi_args=(-p --mode json --no-session --no-mcp --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve)
			if [ "$group" = workflow ]; then
				pi_args+=(-e "$ROOT/plugins/flow/extensions/pi.ts"
					--skill "$ROOT/plugins/pstack/skills" --skill "$ROOT/plugins/spec/skills" --skill "$ROOT/plugins/flow/skills")
			fi
			[ -z "$PROVIDER" ] || pi_args+=(--provider "$PROVIDER")
			pi_args+=(--model "$MODEL")
			[ -z "$THINKING" ] || pi_args+=(--thinking "$THINKING")
			[ -z "$ctx" ] || pi_args+=(--append-system-prompt "$ctx")
			pi_args+=(-- "$msg")
			run_agent "$work" "$dir/round-$round.jsonl" "$dir/round-$round.err" "$dir/timed-out" "$state_dir" pi "${pi_args[@]}" || rc=$?
		else
			# 工作流组不传 --plugin-dir：入口 skill 和 hooks 都来自样本仓库里的项目级安装。
			if [ "$group" = workflow ]; then
				claude_args=(--settings "$SETTINGS")
			else
				claude_args=(--settings "$SETTINGS_CONTROL")
			fi
			claude_args+=(--output-format stream-json --verbose --permission-mode bypassPermissions --strict-mcp-config)
			[ -z "$MODEL" ] || claude_args+=(--model "$MODEL")
			if [ -z "$sid" ]; then
				claude_args=(-p "$msg" "${claude_args[@]}")
			else
				claude_args=(-p "$NUDGE" --resume "$sid" "${claude_args[@]}")
			fi
			run_agent "$work" "$dir/round-$round.jsonl" "$dir/round-$round.err" "$dir/timed-out" "$state_dir" claude "${claude_args[@]}" || rc=$?
		fi
		rcs="$rcs${rcs:+,}$rc"
		if [ -e "$dir/timed-out" ]; then
			timed_out=1
			break
		fi
		extract_answer "$dir/round-$round.jsonl" >"$dir/answer-$round.txt" || true
		check_ok=0
		run_check "$task" "$work" "$dir/answer-$round.txt" "$dir/check-$round.txt" && check_ok=1
		round_ok=0
		round_ok_fn "$dir/round-$round.jsonl" && round_ok=1
		if [ "$check_ok" = 1 ] && [ "$round_ok" = 1 ] && [ "$rc" = 0 ]; then
			pass=1
			break
		fi
		if [ "$check_ok" = 1 ] || [ "$round_ok" != 1 ] || [ "$rc" != 0 ] || [ "$HARNESS" = pi ]; then break; fi
		sid=$(jq -Rr 'fromjson? | select(.type=="result") | .session_id // empty' "$dir/round-$round.jsonl" | tail -1 || true)
		[ "$nudges" -lt "$MAX_NUDGES" ] && [ -n "$sid" ] || break
		nudges=$((nudges + 1))
		round=$((round + 1))
	done
	(git -C "$work" add -A && git -C "$work" diff --cached --binary "$base") >"$dir/diff.patch" 2>/dev/null || true
	if [ -n "$KEEP" ]; then
		say "  $task [$group] #$n 的工作目录保留在 $work（门禁状态在 $state_dir）"
	else
		case $work in
		"$SANDBOX"/*) rm -rf "$(dirname "$work")" ;;
		*) say "  拒绝删除不在 sandbox 里的路径 $work" ;;
		esac
	fi
	{
		local r
		for r in $(seq 1 "$round"); do
			jq -cRn '[inputs | fromjson? | objects]' "$dir/round-$r.jsonl"
		done
	} >"$dir/rounds.jsonl" 2>"$dir/rounds.err" || true
	if [ "$HARNESS" = pi ]; then
		if jq -cs --arg run_id "$RUN_ID" --arg date "$RUN_DATE" --arg commit "$COMMIT" --arg task "$task" \
			--arg group "$group" --arg gates "$gates" \
			--argjson sample "$n" --argjson pass "$pass" --argjson timed_out "$timed_out" \
			--argjson nudges "$nudges" --argjson wall "$(($(date +%s) - start))" \
			--argjson rcs "[$rcs]" --arg premium "$PREMIUM" --arg harness "$HARNESS" --arg provider "$PROVIDER" --arg thinking "$THINKING" \
			-f "$ROOT/evals/pi-record.jq" "$dir/rounds.jsonl" >"$dir/record.json"; then
			record_ok=1
		fi
	else
		if jq -cs --arg run_id "$RUN_ID" --arg date "$RUN_DATE" --arg commit "$COMMIT" --arg task "$task" \
			--arg group "$group" --arg gates "$gates" \
			--argjson sample "$n" --argjson pass "$pass" --argjson timed_out "$timed_out" \
			--argjson nudges "$nudges" --argjson wall "$(($(date +%s) - start))" \
			--argjson rcs "[$rcs]" --arg premium "$PREMIUM" --arg harness "$HARNESS" --arg provider "$PROVIDER" --arg thinking "$THINKING" \
			"$RECORD_JQ" "$dir/rounds.jsonl" >"$dir/record.json"; then
			record_ok=1
		fi
	fi
	if [ "$record_ok" != 1 ]; then
		say "  $task [$group] #$n 的记录解析失败，写回退记录；原始事件在 $dir/rounds.jsonl"
		record_fallback "$dir/record.json" "$task" "$n" "$round" 0 "$timed_out" "$nudges" "$(($(date +%s) - start))" "记录解析失败，见 rounds.jsonl" "$group" "$gates"
	fi
	say "$([ "$pass" = 1 ] && echo ✓ || echo ✗) $task [$group] #${n}：$([ "$pass" = 1 ] && echo 通过 || echo 未通过)，$round 轮，催促 $nudges 次，门禁拦截 $(jq -r '.stop_blocks // 0' "$dir/record.json") 次，$(jq -r .wall_s "$dir/record.json") 秒$([ "$timed_out" = 1 ] && echo "，超时")"
}

cmd_run() {
	local samples=1 jobs=1 t n g i=0 pids=() records report section max_nudges_set=0 groups=
	HARNESS=claude MODEL= MAX_NUDGES= PROVIDER= THINKING= KEEP= GROUP=both
	while [ $# -gt 0 ]; do
		case $1 in
		--harness) HARNESS=${2:-}; shift 2 || die "--harness 后面要跟 claude 或 pi" ;;
		--provider) PROVIDER=${2:-}; shift 2 || die "--provider 后面要跟 provider 名" ;;
		--thinking) THINKING=${2:-}; shift 2 || die "--thinking 后面要跟推理等级" ;;
		--samples) samples=${2:-}; shift 2 || die "--samples 后面要跟数字" ;;
		--jobs) jobs=${2:-}; shift 2 || die "--jobs 后面要跟数字" ;;
		--model) MODEL=${2:-}; shift 2 || die "--model 后面要跟模型名" ;;
		--max-nudges) MAX_NUDGES=${2:-}; max_nudges_set=1; shift 2 || die "--max-nudges 后面要跟数字" ;;
		--group) GROUP=${2:-}; shift 2 || die "--group 后面要跟 workflow、control 或 both" ;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		-*) die "未知参数：$1" ;;
		*) break ;;
		esac
	done
	case $HARNESS in
	claude | pi) ;;
	*) die "--harness 只能是 claude 或 pi（收到 ${HARNESS}）" ;;
	esac
	case $GROUP in
	both) groups="workflow control" ;;
	workflow | control) groups=$GROUP ;;
	*) die "--group 只能是 workflow、control 或 both（收到 ${GROUP}）" ;;
	esac
	if [ "$HARNESS" = claude ]; then
		[ -z "$PROVIDER" ] || die "--provider 只用于 --harness pi"
		[ -z "$THINKING" ] || die "--thinking 只用于 --harness pi"
	else
		case $THINKING in
		'' | off | minimal | low | medium | high | xhigh | max) ;;
		*) die "--thinking 只能是 off、minimal、low、medium、high、xhigh、max" ;;
		esac
		if [ "$max_nudges_set" = 1 ]; then
			is_uint "$MAX_NUDGES" || die "--max-nudges 要是非负整数"
			[ "$MAX_NUDGES" -eq 0 ] || die "--harness pi 单轮运行，--max-nudges 只能是 0"
		fi
		MAX_NUDGES=0
	fi
	[ "$HARNESS" = pi ] || MAX_NUDGES=${MAX_NUDGES:-2}
	is_uint "$samples" && [ "$samples" -ge 1 ] || die "--samples 要是正整数"
	is_uint "$jobs" && [ "$jobs" -ge 1 ] || die "--jobs 要是正整数"
	is_uint "$MAX_NUDGES" || die "--max-nudges 要是非负整数"
	is_uint "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || die "JSTACK_EVAL_TIMEOUT 要是正整数（秒）"
	is_uint "$GRACE" && [ "$GRACE" -ge 1 ] || die "JSTACK_EVAL_KILL_GRACE 要是正整数（秒）"
	for t in jq git node; do command -v "$t" >/dev/null || die "缺少依赖 $t"; done
	if [ "$HARNESS" = pi ]; then
		command -v pi >/dev/null || die "缺少依赖 pi"
		[ -f "$ROOT/plugins/flow/extensions/pi.ts" ] || die "缺少构建产物 plugins/flow/extensions/pi.ts，先运行 ./jstack build"
		for t in pstack spec flow; do
			[ -d "$ROOT/plugins/$t/skills" ] || die "缺少构建产物 plugins/$t/skills，先运行 ./jstack build"
		done
	else
		command -v claude >/dev/null || die "缺少依赖 claude"
	fi
	[ -d "$FIXTURE" ] || die "没有种子项目 $FIXTURE"
	if [ "$HARNESS" = pi ]; then
		[ -n "$MODEL" ] || die "Pi 必须显式传 --model；runner 不读用户配置，也不跟随 Pi 的默认模型"
		say "模型 ${MODEL}（--model，provider ${PROVIDER:-未指定}，thinking ${THINKING:-默认}）"
	else
		if [ -z "$MODEL" ]; then
			MODEL=$(default_model || true)
			[ -n "$MODEL" ] || die "没有 --model，也读不到用户级配置里的 models.claude-code.bulk[0]；显式传 --model，或先运行 ./jstack models set"
			say "模型 ${MODEL}（用户级配置的 claude-code.bulk[0]）"
		else
			say "模型 ${MODEL}（--model）"
		fi
	fi
	pick_tasks "$@"
	for t in $TASKS; do
		[ -f "$TASKS_DIR/$t/prompt.md" ] && [ -f "$TASKS_DIR/$t/check.sh" ] || die "任务 $t 缺少 prompt.md 或 check.sh"
	done

	RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
	RUN_DATE=$(date +%Y-%m-%d)
	COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)
	[ -z "$(git -C "$ROOT" status --porcelain)" ] || COMMIT="$COMMIT-dirty"
	RUN_DIR="$SCRATCH/$RUN_ID"
	mkdir -p "$RUN_DIR" "$(dirname "$RESULTS")" "$REPORTS"
	make_sandbox
	say "评测 ${RUN_ID}：harness ${HARNESS}，任务 $(echo $TASKS)，组 ${groups}，每组 $samples 个样本，并发 ${jobs}，max-nudges ${MAX_NUDGES}，原始材料在 ${RUN_DIR}"

	# 每个样本写自己的 record.json，全部结束后按任务、组、样本顺序合并，避免并发写同一文件。
	for t in $TASKS; do
		for g in $groups; do
			for n in $(seq 1 "$samples"); do
				[ "$i" -lt "$jobs" ] || wait "${pids[$((i - jobs))]}" || true
				run_sample "$t" "$n" "$g" &
				pids[i]=$!
				i=$((i + 1))
			done
		done
	done
	wait || true

	records="$RUN_DIR/records.jsonl"
	: >"$records"
	for t in $TASKS; do
		for g in $groups; do
			for n in $(seq 1 "$samples"); do
				if [ -s "$RUN_DIR/$t-$n-$g/record.json" ]; then
					cat "$RUN_DIR/$t-$n-$g/record.json" >>"$records"
				else
					say "✗ $t [$g] #$n 没有产生记录，写回退记录；原始日志在 $RUN_DIR/$t-$n-$g"
					mkdir -p "$RUN_DIR/$t-$n-$g"
					record_fallback "$RUN_DIR/$t-$n-$g/record.json" "$t" "$n" 1 0 0 0 0 "样本没有产生记录，见原始日志" "$g" "$(gates_for "$g")"
					cat "$RUN_DIR/$t-$n-$g/record.json" >>"$records"
				fi
			done
		done
	done
	[ -s "$records" ] || die "没有任何样本产生记录"
	cat "$records" >>"$RESULTS"

	report="$REPORTS/$RUN_DATE.md"
	[ -f "$report" ] || printf '# 工作流评测 %s\n' "$RUN_DATE" >"$report"
	section=$(jq -rs --arg run_id "$RUN_ID" --arg commit "$COMMIT" --argjson samples "$samples" \
		--argjson max_nudges "$MAX_NUDGES" "$REPORT_JQ" "$records")
	printf '\n%s\n' "$section" >>"$report"
	say ""
	say "$section"
	say ""
	say "记录已追加到 ${RESULTS#"$ROOT"/}，报告在 ${report#"$ROOT"/}"
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
		work=$(prepare_workdir "$t") || {
			say "✗ ${t}：准备工作目录失败"
			bad=1
			continue
		}
		if run_check "$t" "$work" "$empty" "$log"; then
			say "✗ ${t}：初始状态下 check 就通过了"
			bad=1
			continue
		fi
		work=$(prepare_workdir "$t") || {
			say "✗ ${t}：准备工作目录失败"
			bad=1
			continue
		}
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
