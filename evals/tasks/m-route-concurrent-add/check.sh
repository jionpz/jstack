#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# Force two readers to see the same snapshot before either writes, rather than
# relying on a probabilistic collision in 20 repeated concurrency stress runs.
tn add "Warm up" >/dev/null || fail "sequential add failed"
tn done 1 >/dev/null || fail "sequential done failed"
mkdir "$tmp/read-barrier"
cat >"$tmp/read-barrier.cjs" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const target = process.env.TASKNOTES_FILE;
const barrier = process.env.TASKNOTES_READ_BARRIER;
const read = fs.readFileSync;
let observed = false;
fs.readFileSync = function (file, ...args) {
  const data = read.call(this, file, ...args);
  if (!observed && String(file) === target && process.argv[2] === 'add') {
    observed = true;
    fs.writeFileSync(path.join(barrier, String(process.pid)), 'ready');
    const deadline = Date.now() + 2500;
    const sleeper = new Int32Array(new SharedArrayBuffer(4));
    while (fs.readdirSync(barrier).length < 2 && Date.now() < deadline) {
      Atomics.wait(sleeper, 0, 0, 10);
    }
  }
  return data;
};
JS

pids=()
for i in 1 2; do
  TASKNOTES_READ_BARRIER="$tmp/read-barrier" NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$tmp/read-barrier.cjs" tn add "Probe $i" >"$tmp/probe-$i.out" 2>"$tmp/probe-$i.err" &
  pids+=("$!")
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || fail "concurrent probe command failed: $(cat "$tmp"/probe-*.err | head -3)"

node - "$TASKNOTES_FILE" <<'JS' || fail "concurrent read-modify-write lost an update"
const fs = require('node:fs');
const tasks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (tasks.length !== 3) throw new Error('expected 3 tasks after barrier probe, got ' + tasks.length);
const ids = new Set(tasks.map(t => t.id));
if (ids.size !== tasks.length) throw new Error('duplicate IDs in barrier probe');
for (const name of ['Probe 1', 'Probe 2']) {
  if (!tasks.some(t => t.title === name)) throw new Error('lost ' + name);
}
JS

# Also run one large batch to catch lock timeouts and duplicate IDs.
pids=()
for i in $(seq 1 20); do
  tn add "Parallel $i" >/dev/null 2>"$tmp/err-$i.txt" &
  pids+=("$!")
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || fail "a concurrent add exited non-zero: $(cat "$tmp"/err-*.txt | head -3)"

node - "$TASKNOTES_FILE" <<'JS' || exit 1
const fs = require('node:fs');
const fail = msg => { console.error(msg); process.exit(1); };
const tasks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (tasks.length !== 23) fail('expected 23 tasks after 20 concurrent adds, got ' + tasks.length);
const ids = new Set(tasks.map(t => t.id));
if (ids.size !== tasks.length) fail('duplicate ids: ' + JSON.stringify(tasks.map(t => t.id)));
const titles = new Set(tasks.map(t => t.title));
for (let i = 1; i <= 20; i++) {
  if (!titles.has('Parallel ' + i)) fail('lost task Parallel ' + i);
}
if (!tasks.every(t => Number.isInteger(t.id) && t.id >= 1)) fail('bad ids: ' + JSON.stringify(tasks.map(t => t.id)));
JS
