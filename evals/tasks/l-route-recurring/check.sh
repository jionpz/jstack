#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
export TZ=UTC
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

# 参数校验。
tn add "No due" --repeat weekly >/dev/null 2>&1 && fail "repeat without due should fail"
tn add "Bad date" --due 2026-02-30 >/dev/null 2>&1 && fail "impossible date should fail"
tn add "Bad repeat" --due 2026-12-01 --repeat yearly >/dev/null 2>&1 && fail "unknown repeat should fail"

node - "$TASKNOTES_FILE" <<'JS'
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');

const fail = (msg) => { console.error(msg); process.exit(1); };
const file = process.argv[2];
const DAY = 86400000;
const pad = (n) => String(n).padStart(2, '0');
const iso = (ms) => {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
};
const parse = (s) => Date.parse(`${s}T00:00:00Z`);
const addDays = (s, n) => iso(parse(s) + n * DAY);
const today = iso(Date.now());

const cli = (args, env = process.env) =>
  execFileSync(process.execPath, ['bin/tasknotes.js', ...args], { encoding: 'utf8', env });

const tasks = () => JSON.parse(fs.readFileSync(file, 'utf8'));
const byTitle = (title) => {
  const t = tasks().find((x) => x.title === title);
  if (!t) fail(`missing task ${title}`);
  return t;
};

// weekly：存 due 和 repeat；done 加 7 天，不标完成。
cli(['add', 'Weekly', '--due', addDays(today, 1), '--repeat', 'weekly']);
let t = byTitle('Weekly');
if (t.repeat !== 'weekly') fail(`repeat not stored: ${JSON.stringify(t)}`);
if (t.done !== false) fail(`weekly task starts done: ${JSON.stringify(t)}`);
cli(['done', String(t.id)]);
t = byTitle('Weekly');
if (t.done !== false) fail(`done marked a repeating task complete: ${JSON.stringify(t)}`);
if (t.due !== addDays(today, 8)) fail(`weekly advance: expected ${addDays(today, 8)}, got ${t.due}`);

// monthly：短月钳到月末，下个月回到原日号。
cli(['add', 'Monthly', '--due', '2030-01-31', '--repeat', 'monthly']);
t = byTitle('Monthly');
cli(['done', String(t.id)]);
if (byTitle('Monthly').due !== '2030-02-28') fail(`monthly clamp: expected 2030-02-28, got ${byTitle('Monthly').due}`);
cli(['done', String(t.id)]);
if (byTitle('Monthly').due !== '2030-03-31') fail(`monthly anchor restore: expected 2030-03-31, got ${byTitle('Monthly').due}`);

// 过期的 weekly：一直推到不早于今天。
const overdueDue = addDays(today, -20);
cli(['add', 'Overdue', '--due', overdueDue, '--repeat', 'weekly']);
t = byTitle('Overdue');
cli(['done', String(t.id)]);
const expectedOverdue = addDays(overdueDue, 21);
if (byTitle('Overdue').due !== expectedOverdue) fail(`overdue weekly advance: expected ${expectedOverdue}, got ${byTitle('Overdue').due}`);

// agenda：只列今天到期和过期的未完成任务，按 due 升序。
cli(['add', 'Plants', '--due', addDays(today, -1), '--repeat', 'weekly']);
cli(['add', 'Late', '--due', addDays(today, -2)]);
cli(['add', 'DueToday', '--due', today]);
cli(['add', 'Future', '--due', addDays(today, 2)]);
cli(['add', 'OldDone', '--due', addDays(today, -1)]);
cli(['done', String(byTitle('OldDone').id)]);
cli(['add', 'NoDue']);

const agenda = cli(['agenda']).trimEnd().split('\n');
const lateLine = `[ ] ${byTitle('Late').id} Late (due ${addDays(today, -2)}) (overdue)`;
const plantsLine = `[ ] ${byTitle('Plants').id} Plants (due ${addDays(today, -1)}) (repeats weekly) (overdue)`;
const todayLine = `[ ] ${byTitle('DueToday').id} DueToday (due ${today})`;
if (agenda.length !== 3) fail(`agenda should list 3 tasks, got:\n${agenda.join('\n')}`);
if (agenda[0] !== lateLine) fail(`agenda[0]: expected ${JSON.stringify(lateLine)}, got ${JSON.stringify(agenda[0])}`);
if (agenda[1] !== plantsLine) fail(`agenda[1]: expected ${JSON.stringify(plantsLine)}, got ${JSON.stringify(agenda[1])}`);
if (agenda[2] !== todayLine) fail(`agenda[2]: expected ${JSON.stringify(todayLine)}, got ${JSON.stringify(agenda[2])}`);

const json = JSON.parse(cli(['agenda', '--json']));
if (!Array.isArray(json) || json.length !== 3) fail(`agenda --json should list 3 tasks: ${JSON.stringify(json)}`);
const j = (title) => json.find((x) => x.title === title) || fail(`agenda --json missing ${title}`);
const plants = j('Plants');
if (plants.due !== addDays(today, -1) || plants.repeat !== 'weekly' || plants.overdue !== true) {
  fail(`agenda --json Plants: ${JSON.stringify(plants)}`);
}
const todayItem = j('DueToday');
if (todayItem.repeat !== null || todayItem.overdue !== false) fail(`agenda --json DueToday: ${JSON.stringify(todayItem)}`);
const ids = json.map((x) => x.id);
const expectedIds = [byTitle('Late').id, byTitle('Plants').id, byTitle('DueToday').id];
if (JSON.stringify(ids) !== JSON.stringify(expectedIds)) fail(`agenda --json order: ${JSON.stringify(ids)}`);

// list 里的 repeat 后缀。
const list = cli(['list']).split('\n');
const weeklyLine = list.find((l) => l.includes(' Weekly'));
if (!weeklyLine || !weeklyLine.endsWith('(repeats weekly)')) fail(`list repeat suffix: ${weeklyLine}`);
const monthlyLine = list.find((l) => l.includes(' Monthly'));
if (!monthlyLine || !monthlyLine.endsWith('(repeats monthly)')) fail(`list repeat suffix: ${monthlyLine}`);

// 非重复任务的 done 保持原样。
cli(['done', String(byTitle('DueToday').id)]);
if (byTitle('DueToday').done !== true) fail('non-repeating done broken');

// 老文件：没有 due / repeat 也能读写、加任务。
const oldFile = file.replace(/tasks\.json$/, 'old.json');
fs.writeFileSync(oldFile, JSON.stringify([
  { id: 1, title: 'One', done: false },
  { id: 2, title: 'Two', done: true },
]) + '\n');
const oldEnv = { ...process.env, TASKNOTES_FILE: oldFile };
const oldList = cli(['list'], oldEnv);
if (!oldList.includes('[ ] 1 One') || !oldList.includes('[x] 2 Two')) fail(`old file list: ${oldList}`);
cli(['done', '1'], oldEnv);
cli(['add', 'Three'], oldEnv);
const oldTasks = JSON.parse(fs.readFileSync(oldFile, 'utf8'));
const one = oldTasks.find((x) => x.id === 1);
if (!one || one.done !== true) fail(`old file done: ${JSON.stringify(oldTasks)}`);
if (!oldTasks.find((x) => x.title === 'Three')) fail(`old file add: ${JSON.stringify(oldTasks)}`);
JS
