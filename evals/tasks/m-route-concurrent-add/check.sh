#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 顺序场景先确认没坏。
tn add "Warm up" >/dev/null || fail "sequential add failed"
tn done 1 >/dev/null || fail "sequential done failed"

# 20 个进程同时加：一条都不能丢，id 不能重复。
pids=()
for i in $(seq 1 20); do
	tn add "Parallel $i" >/dev/null 2>"$tmp/err-$i.txt" &
	pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || fail "a concurrent add exited non-zero: $(cat "$tmp"/err-*.txt 2>/dev/null | head -3)"

node - "$TASKNOTES_FILE" <<'JS' || exit 1
const fs = require('node:fs');
const fail = (msg) => { console.error(msg); process.exit(1); };
const tasks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (tasks.length !== 21) fail(`expected 21 tasks after 20 concurrent adds, got ${tasks.length}`);
const ids = new Set(tasks.map((t) => t.id));
if (ids.size !== tasks.length) fail(`duplicate ids: ${JSON.stringify(tasks.map((t) => t.id))}`);
const titles = new Set(tasks.map((t) => t.title));
for (let i = 1; i <= 20; i++) {
  if (!titles.has(`Parallel ${i}`)) fail(`lost task Parallel ${i}`);
}
if (!tasks.every((t) => Number.isInteger(t.id) && t.id >= 1)) fail(`bad ids: ${JSON.stringify(tasks.map((t) => t.id))}`);
JS
exit 0
