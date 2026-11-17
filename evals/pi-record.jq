def usage_items: [ .[] | select(.type == "message_end") | .message
  | select((.role // "") == "assistant" or (.role // "") == "toolResult")
  | .usage | select(type == "object") ];
def usage_total($u): ($u.input // 0) + ($u.output // 0) + ($u.cacheRead // 0) + ($u.cacheWrite // 0);
def usage_cost($u): if ((($u.cost // null) | type) == "object") and ((($u.cost.total // null) | type) == "number")
  then $u.cost.total else null end;
def has_end: any(.[]?; .type == "agent_end");
def assistant_messages: [ .[] | select(.type == "message_end" and (.message.role // "") == "assistant") | .message ];
def last_assistant: assistant_messages | last;
def last_model: (assistant_messages | map(.model | select(type == "string")) | last) // null;
def last_provider: (assistant_messages | map(.provider | select(type == "string")) | last) // null;
def last_thinking: (assistant_messages | map(.thinkingLevel | select(type == "string")) | last) // null;
def last_stop: (assistant_messages | map(.stopReason | select(type == "string")) | last) // null;
def auto_error: first(.[] | select(.type == "auto_retry_end" and .success == false)
  | (.finalError // "未知错误" | tostring | .[0:200])) // null;
def arg_path($t): ($t.args.path // $t.args.file_path // $t.args.filePath // "" | tostring);
def skill_read($name): (.toolName | tostring | test("^read$"; "i"))
  and ((arg_path(.) | test("(^|/)" + $name + "/SKILL.md$")));
def skill_call($name): (.toolName | tostring | test("^(Skill|skill)$"))
  and ((.args.skill // .args.name // "" | tostring) == $name);
def skill_bash($name): (.toolName | tostring | test("^bash$"; "i"))
  and ((.args.command // "" | tostring) | test("(^|/)" + $name + "/SKILL.md"));
# flow 扩展用 jstack-gates 自定义消息把 Stop 门禁的理由发给模型，数它就是拦截次数。
def stop_blocks: [ .[][] | .. | objects | select(.customType? == "jstack-gates")
  | .content // empty | strings | select(contains("jstack verify 门禁")) ] | length;
def round_error($i; $r):
  ($rcs[$i] // 0) as $rc
  | $r as $e
  | if ($e | has_end | not) then
      "第 \($i + 1) 轮没有 agent_end 事件（退出码 \($rc)）"
    elif $rc != 0 then
      "第 \($i + 1) 轮退出码 \($rc)"
    elif ($e | last_stop) == "error" or ($e | last_stop) == "aborted" or ($e | last_stop) == "length" then
      "第 \($i + 1) 轮出错（\($e | last_stop)）：\(($e | last_assistant | .errorMessage // "" | tostring | .[0:200]))"
    elif ($e | auto_error) != null then
      "第 \($i + 1) 轮自动重试失败：\($e | auto_error)"
    elif ($e | assistant_messages | length) == 0 then
      "第 \($i + 1) 轮没有助手消息"
    else empty end;

. as $rounds
| ([ $rounds[] | usage_items | .[] ]) as $usage
| ([ $rounds[] | assistant_messages | .[] | select((.usage // null) | type == "object")
     | select((.model // "" | tostring) | test($premium)) | usage_total(.usage) ]) as $premium_usage
| ([ $usage[] | usage_cost(.) | select(. != null) ]) as $costs
| ([ $rounds[] | .[] | select(.type == "tool_execution_start") ]) as $tools
| {
    run_id: $run_id, date: $date, commit: $commit,
    harness: $harness,
    provider: (if ($provider // "") != "" then $provider else ($rounds[-1] | last_provider) end),
    thinking: (if ($thinking // "") != "" then $thinking else ($rounds[-1] | last_thinking) end),
    model: ($rounds[-1] | last_model),
    task: $task, sample: $sample, group: $group, gates: $gates,
    pass: ($pass == 1), timed_out: ($timed_out == 1),
    rounds: ($rounds | length), nudges: $nudges,
    turns: (([ $rounds[] | [ .[] | select(.type == "turn_end") ] | length ] | add // 0) as $t
      | if $t == 0 then ([ $rounds[][] | select(.type == "message_end" and (.message.role // "") == "assistant") ] | length) else $t end),
    wall_s: $wall,
    tokens: (if ($usage | length) == 0 then null else ($usage | map(usage_total(.)) | add) end),
    premium_tokens: (if ($usage | length) == 0 then null else ($premium_usage | add // 0) end),
    cost_usd: (if ($costs | length) == 0 then null else ($costs | add) end),
    route: any($tools[]; (. | skill_read("route")) or (. | skill_call("route")) or (. | skill_bash("route"))),
    poteto: any($tools[]; (. | skill_read("poteto-mode")) or (. | skill_call("poteto-mode")) or (. | skill_bash("poteto-mode"))),
    subagents: ([ $tools[] | select((.toolName | tostring) | test("^(Agent|Task|subagent)$"; "i")) ] | length),
    stop_blocks: stop_blocks,
    error: (if $timed_out == 1 then null else
      first(range(0; $rounds | length) as $i | round_error($i; $rounds[$i])) // null end)
  }
