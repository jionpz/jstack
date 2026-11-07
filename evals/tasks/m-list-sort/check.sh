#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

tn add "Book flights" --due 2026-12-03 >/dev/null || fail "add exited non-zero"
tn add "Renew passport" --due 2026-12-01 >/dev/null || fail "add exited non-zero"
tn add "Water plants" >/dev/null || fail "add exited non-zero"
tn add "Call landlord" --due 2026-12-02 >/dev/null || fail "add exited non-zero"

sorted_by_due() {
  node -e '
    const lines = require("node:fs").readFileSync(0, "utf8").split("\n");
    const at = (title) => lines.findIndex((l) => l.includes(title));
    const pos = ["Renew passport", "Call landlord", "Book flights", "Water plants"].map(at);
    if (pos.some((p) => p === -1)) process.exit(1);
    if (!(pos[0] < pos[1] && pos[1] < pos[2])) process.exit(1);
  '
}

for args in "list" "list --sort due" "list --sort=due"; do
  out=$(tn $args 2>/dev/null) || continue
  sorted_by_due <<<"$out" && exit 0
done
fail "none of list, list --sort due, list --sort=due showed all tasks with dated ones in due order"
