#!/usr/bin/env bash
set -eu
fail() { echo "$*" >&2; exit 1; }
answer=$(cat "${ANSWER_FILE:-/dev/null}" 2>/dev/null)
has() { grep -qiE "$1" <<<"$answer"; }
has '(只|仅).{0,8}(删除|清理|移除).{0,12}(已完成|完成的)' || fail "answer must choose completed tasks only"
has '((保留|不删|不删除).{0,12}(未完成|未完成的)|(未完成|未完成的).{0,12}(保留|不删|不删除))' || fail "answer must preserve open tasks"
has '((无需|不需要|不用).{0,12}(确认|二次确认)|(不增加|不加|无需增加).{0,12}(确认|二次确认))' || fail "answer must adopt no-confirmation default"
data=$(mktemp)
trap 'rm -f "$data"' EXIT
export TASKNOTES_FILE="$data"
printf '%s\n' '[{"id":3,"title":"Done item","done":true},{"id":2,"title":"Open item","done":false}]' >"$data"
node bin/tasknotes.js clear </dev/null
jq -e '. == [{"id":2,"title":"Open item","done":false}]' "$data"
