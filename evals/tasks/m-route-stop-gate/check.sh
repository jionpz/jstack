#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tn() { node bin/tasknotes.js "$@"; }

# 在干净环境里跑仓库自己的测试：TASKNOTES_FILE 是下面测 CLI 用的，不能漏进测试进程。
node --test >/dev/null 2>&1 || fail "unit tests fail"
export TASKNOTES_FILE="$tmp/tasks.json"

tn add "One" >/dev/null || fail "add exited non-zero"
tn add "Two" >/dev/null || fail "add exited non-zero"
tn add "Three" --due 2026-12-01 >/dev/null || fail "add --due exited non-zero"
tn done 2 >/dev/null || fail "done exited non-zero"

out=$(tn clear) || fail "clear exited non-zero"
grep -qE '(^|[^0-9])3([^0-9]|$)' <<<"$out" || fail "clear did not report 3 removed tasks: $out"
node - "$TASKNOTES_FILE" <<'JS' || exit 1
const fs = require('node:fs');
const tasks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!Array.isArray(tasks) || tasks.length !== 0) {
  console.error(`tasks.json after clear: ${JSON.stringify(tasks)}`);
  process.exit(1);
}
JS

out=$(tn list) || fail "list exited non-zero"
grep -qiE 'nothing to do|no tasks' <<<"$out" || fail "list after clear is not empty: $out"

# 空列表再清一次：0 条，也正常退出。
out=$(tn clear) || fail "second clear exited non-zero"
grep -qiE '(^|[^0-9])0([^0-9]|$)|nothing|no .*tasks?' <<<"$out" || fail "second clear did not report 0: $out"

# 清空后重新开始编号。
tn add "Fresh" >/dev/null || fail "add after clear exited non-zero"
out=$(tn list) || fail "list after add exited non-zero"
grep -qE '^\[ \] 1 Fresh' <<<"$out" || fail "id after clear is not 1: $out"
exit 0
