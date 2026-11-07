#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

tn list --json > "$tmp/empty.out" || fail "list --json exited non-zero on an empty list"
tn add "Buy milk" --due 2026-11-10 >/dev/null || fail "add exited non-zero"
tn add "Call mom" >/dev/null || fail "add exited non-zero"
tn done 2 >/dev/null || fail "done exited non-zero"
tn list --json > "$tmp/full.out" || fail "list --json exited non-zero"

node - "$tmp/empty.out" "$tmp/full.out" <<'JS' || exit 1
const fs = require('node:fs');
const fail = (msg) => { console.error(msg); process.exit(1); };
const parse = (file) => {
  const text = fs.readFileSync(file, 'utf8');
  try { return JSON.parse(text); } catch { fail(`list --json is not valid JSON: ${text.slice(0, 200)}`); }
};
const empty = parse(process.argv[2]);
if (!Array.isArray(empty) || empty.length !== 0) fail(`empty list --json is not []: ${JSON.stringify(empty)}`);
const tasks = parse(process.argv[3]);
if (!Array.isArray(tasks) || tasks.length !== 2) fail(`expected an array of 2 tasks: ${JSON.stringify(tasks)}`);
for (const t of tasks) {
  if (typeof t.id !== 'number') fail(`id is not a number: ${JSON.stringify(t)}`);
  if (typeof t.title !== 'string') fail(`title is not a string: ${JSON.stringify(t)}`);
  if (typeof t.done !== 'boolean') fail(`done is not a boolean: ${JSON.stringify(t)}`);
  if (!('due' in t) || !(t.due === null || /^\d{4}-\d{2}-\d{2}$/.test(t.due))) fail(`due is not null or a date: ${JSON.stringify(t)}`);
}
const milk = tasks.find((t) => t.title === 'Buy milk');
const mom = tasks.find((t) => t.title === 'Call mom');
if (!milk || milk.id !== 1 || milk.done !== false || milk.due !== '2026-11-10') fail(`wrong Buy milk: ${JSON.stringify(milk)}`);
if (!mom || mom.id !== 2 || mom.done !== true || mom.due !== null) fail(`wrong Call mom: ${JSON.stringify(mom)}`);
JS
exit 0
