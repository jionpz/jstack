#!/usr/bin/env bash
set -u
fail() { echo "$*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TASKNOTES_FILE="$tmp/tasks.json"
tn() { node bin/tasknotes.js "$@"; }

node --test >/dev/null 2>&1 || fail "unit tests fail"

cat > "$TASKNOTES_FILE" <<'JSON'
[
  { "id": 1, "title": "Old chore", "done": false, "due": null },
  { "id": 2, "title": "Old errand", "done": false, "due": "2026-11-20" }
]
JSON

out=$(tn list) || fail "list exited non-zero on an old-format file"
grep -q 'Old chore' <<<"$out" && grep -q 'Old errand' <<<"$out" || fail "old tasks missing from list: $out"

tn add "Pack bag" --tag work --tag home >/dev/null || fail "add with --tag exited non-zero"

out=$(tn list --tag work) || fail "list --tag work exited non-zero"
grep -q 'Pack bag' <<<"$out" || fail "list --tag work misses the tagged task: $out"
grep -q 'Old ' <<<"$out" && fail "list --tag work shows untagged tasks: $out"
grep -q -- '--tag' <<<"$out" && fail "tag flags leaked into the title: $out"

out=$(tn list --tag home) || fail "list --tag home exited non-zero"
grep -q 'Pack bag' <<<"$out" || fail "list --tag home misses the tagged task: $out"

tn done 1 >/dev/null || fail "done on an old task exited non-zero"

out=$(tn list) || fail "list exited non-zero"
for t in 'Old chore' 'Old errand' 'Pack bag'; do
  grep -q "$t" <<<"$out" || fail "list lost $t: $out"
done
grep -q 'work' <<<"$out" || fail "list does not show tags: $out"
exit 0
