#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 老格式：任务没有 due 字段。
cat >"$TASKNOTES_FILE" <<'JSON'
[
  { "id": 1, "title": "Old open", "done": false },
  { "id": 2, "title": "Old done", "done": true }
]
JSON
out=$(tn list) || fail "list exited non-zero on an old-format file"
grep -q 'Old open' <<<"$out" || fail "list lost Old open: $out"
out=$(tn list --open) || fail "list --open exited non-zero"
grep -q 'Old open' <<<"$out" || fail "list --open misses the open task: $out"
grep -q 'Old done' <<<"$out" && fail "list --open shows a done task: $out"
out=$(tn list --done) || fail "list --done exited non-zero"
grep -q 'Old done' <<<"$out" || fail "list --done misses the done task: $out"
grep -q 'Old open' <<<"$out" && fail "list --done shows an open task: $out"

# 批量 done：Alpha、Beta、Gamma、Delta 的 id 分别是 3、4、5、6。
for t in Alpha Beta Gamma Delta; do tn add "$t" >/dev/null || fail "add $t failed"; done
tn done 5 6 >/dev/null || fail "done 5 6 exited non-zero"
out=$(tn list --done) || fail "list --done exited non-zero"
grep -q 'Alpha' <<<"$out" && fail "done 5 6 wrongly completed Alpha: $out"
grep -q 'Beta' <<<"$out" && fail "done 5 6 wrongly completed Beta: $out"
grep -q 'Gamma' <<<"$out" || fail "done 5 6 missed Gamma: $out"
grep -q 'Delta' <<<"$out" || fail "done 5 6 missed Delta: $out"

# clean：删掉所有已完成的（Old done、Gamma、Delta 共 3 条），报告数量，剩余 id 不变。
out=$(tn clean) || fail "clean exited non-zero"
grep -qE '(^|[^0-9])3([^0-9]|$)' <<<"$out" || fail "clean did not report 3 removed tasks: $out"
out=$(tn list) || fail "list exited non-zero after clean"
grep -q 'Old open' <<<"$out" || fail "clean removed an open task: $out"
grep -qE '^\[ \] 4 Beta' <<<"$out" || fail "clean renumbered the remaining tasks: $out"
grep -q 'Old done' <<<"$out" && fail "clean left a done task behind: $out"

# 未知 id：整批失败。
tn done 4 99 >/dev/null 2>&1 && fail "done with an unknown id exited zero"
exit 0
