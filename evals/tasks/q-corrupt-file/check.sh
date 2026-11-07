#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }

answer=$(cat "${ANSWER_FILE:-/dev/null}" 2>/dev/null)
has() { grep -qiE "$1" <<<"$answer"; }

has 'store' || fail "answer does not point at store"
has 'JSON\.parse|parse|解析' || fail "answer does not mention the parse failure"
has 'catch|异常|错误|exception' || fail "answer does not mention the swallowed error"
has 'save|写回|覆盖|overwrite' || fail "answer does not mention the overwrite"
[ -z "$(git status --porcelain -- src bin)" ] || fail "code under src or bin was changed"
exit 0
