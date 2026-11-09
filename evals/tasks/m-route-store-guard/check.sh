#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 文件不存在：当成空列表，list 正常退出，add 能建出文件。
out=$(tn list) || fail "list exited non-zero when the file is missing"
grep -q 'Nothing to do' <<<"$out" || fail "missing file should behave like an empty list: $out"
tn add "First task" >/dev/null || fail "add exited non-zero when the file is missing"
grep -q 'First task' "$TASKNOTES_FILE" || fail "add did not create the task file"

# 文件坏了：每个命令都要失败，且文件一个字节都不能变。
bad='[{"id": 1, "title": "Keep me", "done": false}'
printf '%s' "$bad" >"$TASKNOTES_FILE"
before=$(cksum "$TASKNOTES_FILE")
for args in "list" "add Another" "done 1" "rm 1"; do
	tn $args >/dev/null 2>&1 && fail "tasknotes $args exited zero on a corrupt file"
	[ "$(cksum "$TASKNOTES_FILE")" = "$before" ] || fail "tasknotes $args modified the corrupt file"
done

# 正常文件照旧工作。
printf '[]\n' >"$TASKNOTES_FILE"
tn add "Buy milk" --due 2026-11-10 >/dev/null || fail "add exited non-zero on a valid file"
tn add "Call mom" >/dev/null || fail "add exited non-zero on a valid file"
tn done 2 >/dev/null || fail "done exited non-zero on a valid file"
out=$(tn list) || fail "list exited non-zero on a valid file"
grep -qE '^\[x\] 2 Call mom' <<<"$out" || fail "done did not mark task 2: $out"
tn rm 1 >/dev/null || fail "rm exited non-zero on a valid file"
out=$(tn list) || fail "list exited non-zero after rm"
grep -q 'Buy milk' <<<"$out" && fail "rm did not remove task 1: $out"
exit 0
