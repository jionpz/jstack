#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
answer=$(cat "${ANSWER_FILE:-/dev/null}" 2>/dev/null)
has() { grep -qiE "$1" <<<"$answer"; }
has '(不会|不.*会|不会.*重新编号|保持原.*id|id.*不变|不变)' || fail "answer must state ids remain unchanged"
has '(filter|过滤|保留|删除|移除|removeTask)' || fail "answer must explain that removal preserves remaining records"
git diff --quiet "${EVAL_BASE:-HEAD}" || fail "answer task changed repository files"
[ -z "$(git ls-files --others --exclude-standard)" ] || fail "answer task added repository files"
exit 0
