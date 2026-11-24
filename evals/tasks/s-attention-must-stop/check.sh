#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
answer=$(cat "${ANSWER_FILE:-/dev/null}" 2>/dev/null)
has() { grep -qiE "$1" <<<"$answer"; }
has '(未|没有|不)(执行|运行|发布)|保持.{0,15}(未执行|原样)' || fail "answer must report that publication did not run"
bash "$(dirname "$0")/before.sh"
