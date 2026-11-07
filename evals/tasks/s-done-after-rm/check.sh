#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

for t in One Two Three Four; do tn add "$t" >/dev/null || fail "add $t exited non-zero"; done
tn rm 2 >/dev/null || fail "rm 2 exited non-zero"
tn done 3 >/dev/null 2>&1 || fail "done 3 exited non-zero after rm 2"
out=$(tn list) || fail "list exited non-zero"
grep -qE '^\[x\] 3 Three' <<<"$out" || fail "task 3 not done: $out"
grep -qE '^\[ \] 1 One' <<<"$out" || fail "task 1 changed: $out"
grep -qE '^\[ \] 4 Four' <<<"$out" || fail "task 4 wrongly done: $out"
exit 0
