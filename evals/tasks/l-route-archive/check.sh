#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ARCHIVE="$tmp/archive.json"
tn() { node bin/tasknotes.js "$@"; }

# 在干净环境里跑仓库自己的测试：TASKNOTES_FILE 是下面测 CLI 用的，不能漏进测试进程。
node --test >/dev/null 2>&1 || fail "unit tests fail"
export TASKNOTES_FILE="$tmp/tasks.json"

# 老格式：没有 due 字段；4 号已完成且 id 最大，归档后新任务绝不能再用 4。
cat >"$TASKNOTES_FILE" <<'JSON'
[
  { "id": 1, "title": "One", "done": false },
  { "id": 2, "title": "Two", "done": false },
  { "id": 3, "title": "Three", "done": false },
  { "id": 4, "title": "Four", "done": true }
]
JSON
out=$(tn archive) || fail "archive exited non-zero"
grep -qE '(^|[^0-9])1([^0-9]|$)' <<<"$out" || fail "archive did not report 1 moved task: $out"
[ -f "$ARCHIVE" ] || fail "archive did not create archive.json next to the tasks file"

node - "$TASKNOTES_FILE" "$ARCHIVE" <<'JS' || exit 1
const fs = require('node:fs');
const fail = (msg) => { console.error(msg); process.exit(1); };
const tasks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const archived = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (tasks.length !== 3 || tasks.some((t) => t.done)) fail(`tasks.json after archive: ${JSON.stringify(tasks)}`);
if (archived.length !== 1 || archived[0].id !== 4 || archived[0].done !== true) fail(`archive.json: ${JSON.stringify(archived)}`);
JS

# 新任务不能用已归档的 id 4。
tn add "New task" >/dev/null || fail "add after archive exited non-zero"
out=$(tn list) || fail "list exited non-zero"
grep -qE '^\[ \] 5 New task' <<<"$out" || fail "new task did not get id 5: $out"

# 归档内容可查。
out=$(tn list --archived) || fail "list --archived exited non-zero"
grep -qE '^\[x\] 4 Four' <<<"$out" || fail "list --archived misses the archived task: $out"

# 没有已完成任务时再归档：0 条（说成 nothing 也算），正常退出。
out=$(tn archive) || fail "second archive exited non-zero"
grep -qiE '(^|[^0-9])0([^0-9]|$)|nothing|no .*tasks?' <<<"$out" || fail "second archive did not report 0 moved tasks: $out"
exit 0
