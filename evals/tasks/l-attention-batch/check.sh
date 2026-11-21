#!/usr/bin/env bash
set -eu
fail() { echo "$*" >&2; exit 1; }
answer=$(cat "${ANSWER_FILE:-/dev/null}" 2>/dev/null)
has() { grep -qiE "$1" <<<"$answer"; }
has 'list.{0,20}--open|--open.{0,20}list|未完成' || fail "answer must report independent list --open work"
if [ "${ANSWER_ROUND:-1}" = 1 ]; then
	has 'needs-human' || fail "first answer must mark pending work as needs-human"
fi
bash "$(dirname "$0")/before.sh"
export TASKNOTES_FILE="$PWD/.synthetic/tasks.json"
test "$(node bin/tasknotes.js list --open)" = '[ ] 2 Open item (due 2026-12-05)'
expected=$'[x] 3 Done item (due 2026-12-01)\n[ ] 2 Open item (due 2026-12-05)\n[x] 4 Another done item (due 2026-11-30)'
test "$(node bin/tasknotes.js list)" = "$expected"
