#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 添加顺序故意打乱：完成状态、有无日期、日期相同的并列项都要被覆盖。
tn add "Done early" --due 2026-01-01 >/dev/null || fail "add failed"
tn add "Open march" --due 2026-03-01 >/dev/null || fail "add failed"
tn add "Open someday" >/dev/null || fail "add failed"
tn add "Open feb first" --due 2026-02-01 >/dev/null || fail "add failed"
tn add "Done someday" >/dev/null || fail "add failed"
tn add "Open feb second" --due 2026-02-01 >/dev/null || fail "add failed"
tn done 1 >/dev/null || fail "done failed"
tn done 5 >/dev/null || fail "done failed"

out=$(tn list) || fail "list exited non-zero"
expected=$'Open feb first\nOpen feb second\nOpen march\nOpen someday\nDone early\nDone someday'
actual=$(sed -E 's/^\[[ x]\] [0-9]+ //; s/ \(due [0-9-]+\)$//' <<<"$out")
[ "$actual" = "$expected" ] || fail "list order is wrong:$'\n'$out"
exit 0
