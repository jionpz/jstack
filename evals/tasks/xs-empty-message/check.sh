#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

expected='No tasks yet. Add one with: tasknotes add <title>'
printf '[]\n' > "$TASKNOTES_FILE"
out=$(tn list) || fail "list exited non-zero on an empty list"
[ "$out" = "$expected" ] || fail "empty list printed: $out"

tn add "Buy milk" >/dev/null || fail "add exited non-zero"
out=$(tn list) || fail "list exited non-zero"
grep -q 'Buy milk' <<<"$out" || fail "non-empty list lost the task: $out"
grep -q 'No tasks yet' <<<"$out" && fail "non-empty list still printed the empty message"
exit 0
