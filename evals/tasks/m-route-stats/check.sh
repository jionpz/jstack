#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 用本地日期造边界：昨天到期（逾期）、今天到期（不算）、明天到期、没有日期，
# 再加一条已完成的过期任务（不算逾期）和一条已完成的普通任务。
node - "$TASKNOTES_FILE" <<'JS'
const fs = require('node:fs');
const pad = (n) => String(n).padStart(2, '0');
const day = (offset) => {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
const tasks = [
  { id: 1, title: 'Overdue open', done: false, due: day(-1) },
  { id: 2, title: 'Due today', done: false, due: day(0) },
  { id: 3, title: 'Due tomorrow', done: false, due: day(1) },
  { id: 4, title: 'No due', done: false, due: null },
  { id: 5, title: 'Old done', done: true, due: day(-3) },
  { id: 6, title: 'Done today', done: true, due: day(0) },
];
fs.writeFileSync(process.argv[2], JSON.stringify(tasks, null, 2) + '\n');
JS

tn stats --json >"$tmp/stats.json" || fail "stats --json exited non-zero"
node - "$tmp/stats.json" <<'JS' || exit 1
const fs = require('node:fs');
const fail = (msg) => { console.error(msg); process.exit(1); };
const text = fs.readFileSync(process.argv[2], 'utf8');
let stats;
try { stats = JSON.parse(text); } catch { fail(`stats --json is not valid JSON: ${text.slice(0, 200)}`); }
if (stats.open !== 4) fail(`open should be 4: ${JSON.stringify(stats)}`);
if (stats.done !== 2) fail(`done should be 2: ${JSON.stringify(stats)}`);
if (stats.overdue !== 1) fail(`overdue should be 1 (only the open task due yesterday): ${JSON.stringify(stats)}`);
JS

out=$(tn stats) || fail "stats exited non-zero"
grep -qE '(^|[^0-9])4([^0-9]|$)' <<<"$out" || fail "stats text does not mention open=4: $out"
grep -qE '(^|[^0-9])2([^0-9]|$)' <<<"$out" || fail "stats text does not mention done=2: $out"
grep -qE '(^|[^0-9])1([^0-9]|$)' <<<"$out" || fail "stats text does not mention overdue=1: $out"
exit 0
