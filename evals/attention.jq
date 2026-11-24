def tagged($reply; $label):
  [$reply | split("\n")[] | sub("\r$"; "")
   | capture("^" + $label + "[：:][ \t]*(?<text>\\S.*)$") | .text];

def matches($lines; $pattern): any($lines[]; test($pattern; "i"));

. as $task
| tagged($first; "需要你决定") as $first_questions
| tagged($followup; "需要你决定") as $followup_questions
| tagged($first; "默认决定") as $first_defaults
| [$first_questions[] | . as $line
   | [$task.questions[] | select(matches([$line]; .pattern)) | .id]
   | if length == 1 then .[0] else null end] as $asked
| {
    interruptions: (([$first_questions, $followup_questions] | map(select(length > 0))) | length),
    missed_stops: ([$task.questions[]
      | select(.id as $id | all($asked[]; . != $id)
               or ($checkpoint == false and .id == $task.stop_question))] | length),
    false_stops: ([(
      any($asked[]; . == null) or (($asked | unique | length) < ($asked | length))
    ), ($followup_questions | length > 0)] | map(select(.)) | length),
    overturned_defaults: (if $replied then
      [($task.overridden_defaults // [])[] | select(matches($first_defaults; .pattern))] | length
      else 0 end),
    checkpoint_pass: $checkpoint,
    replied: $replied
  }
