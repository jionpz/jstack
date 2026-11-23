#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM

export HOME="$T/home"
export XDG_STATE_HOME="$T/state-home"
export JSTACK_STATE_DIR="$T/state/jstack/sessions"
mkdir -p "$HOME" "$JSTACK_STATE_DIR"

ST="$ROOT/plugins/flow/skills/route/stage.sh"
STOP="$ROOT/plugins/flow/hooks/stop.sh"
FAILS=0

t() {
	local name=$1
	shift
	if "$@" >/dev/null 2>"$T/test-error"; then
		echo "✓ $name"
	else
		echo "✗ $name"
		sed 's/^/  /' "$T/test-error"
		FAILS=$((FAILS + 1))
	fi
}

not() { ! "$@"; }

stage() {
	local sid=$1 repo=$2
	shift 2
	(
		cd "$repo" &&
			JSTACK_SESSION_ID="$sid" JSTACK_STATE_DIR="$JSTACK_STATE_DIR" \
				"$BASH" "$ST" "$@"
	)
}

make_repo() {
	local repo=$1 id=$2
	mkdir -p "$repo/.jstack"
	git -C "$repo" init -q
	git -C "$repo" config user.name Fixture
	git -C "$repo" config user.email fixture@example.invalid
	git -C "$repo" remote add origin "https://github.com/example/$id.git"
	printf 'fixture\n' >"$repo/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -qm fixture
}

discover() {
	local session=$1 repo=$2 ticket=$3 out=$4
	(
		cd "$repo" &&
			JSTACK_SESSION_ID="$session" JSTACK_STATE_DIR="$JSTACK_STATE_DIR" \
				"$BASH" "$ST" resume --ticket "$ticket"
	) >"$out"
}

resume() {
	local session=$1 repo=$2 run_id=$3 from=$4 ticket=$5
	(
		cd "$repo" &&
			JSTACK_SESSION_ID="$session" JSTACK_STATE_DIR="$JSTACK_STATE_DIR" \
				"$BASH" "$ST" resume "$run_id" --from-session "$from" --ticket "$ticket"
	)
}

run_id_from_state() {
	sed -n 's/^run //p' "$1" | head -1
}

discovery_ok() {
	local file=$1 run_id=$2
	python3 -I - "$file" "$run_id" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1, rows
row = rows[0]
assert row["run_id"] == sys.argv[2], row
assert row["session"] == "old-worker", row
assert row["current_ticket"] == "#2", row
assert row["stage"] == "verify", row
assert row["tickets"] == ["#1", "#2"], row
assert isinstance(row["evidence"], list), row
assert row["worktree"], row
PY
}

discovery_matches_any_ticket() {
	local file=$1 run_id=$2
	python3 -I - "$file" "$run_id" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1 and rows[0]["run_id"] == sys.argv[2], rows
assert rows[0]["current_ticket"] == "#2", rows
assert "#1" in rows[0]["tickets"], rows
PY
}

takeover_ok() {
	local run_id=$1 winner=$2
	test ! -e "$JSTACK_STATE_DIR/old-worker" &&
		test -f "$JSTACK_STATE_DIR/$winner" || return 1
	python3 -I - "$JSTACK_STATE_DIR/$winner" "$run_id" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
fields = {}
for line in lines:
    key, _, value = line.partition(" ")
    fields.setdefault(key, []).append(value)
assert fields["run"][0] == sys.argv[2], fields
assert fields["ticket"] == ["#1", "#2"], fields
assert fields["stage"] == ["verify"], fields
assert fields["visited"][-1] == "verify", fields
assert any(line.startswith("prior evidence verify ") for line in lines), lines
assert any(line.startswith("prior land pr ") for line in lines), lines
assert not any(line.startswith("evidence verify ") for line in lines), lines
assert not any(line.startswith("land ") for line in lines), lines
assert not any(line.startswith("review ") for line in lines), lines
PY
}

setup_old_run() {
	stage old-worker "$repo" start --size L --ticket '#1' clarify,plan,execute,verify,review,land,archive &&
		stage old-worker "$repo" enter plan &&
		stage old-worker "$repo" enter execute &&
		stage old-worker "$repo" evidence "first implementation -> ready" &&
		stage old-worker "$repo" enter verify &&
		stage old-worker "$repo" evidence "first verify -> passed" &&
		stage old-worker "$repo" enter review &&
		stage old-worker "$repo" review complete "first review -> clean" &&
		stage old-worker "$repo" enter land &&
		stage old-worker "$repo" land commit 0123456789abcdef0123456789abcdef01234567 &&
		stage old-worker "$repo" land pr https://github.com/example/repo/pull/1 &&
		stage old-worker "$repo" enter execute --ticket '#2' &&
		stage old-worker "$repo" evidence "second implementation -> ready" &&
		stage old-worker "$repo" enter verify &&
		stage old-worker "$repo" evidence "second verify -> passed"
}

stop_reason() {
	local session=$1
	printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"done"}' "$session" |
		"$BASH" "$STOP"
}

other_discovery_is_empty() {
	discover other-worker "$other_repo" '#2' "$T/other-discovery" &&
		test ! -s "$T/other-discovery"
}

collision_is_refused() {
	stage collided "$repo" start --ticket '#3' execute,verify &&
		not resume collided "$repo" "$run_id" old-worker '#2' &&
		grep -q '^ticket #3$' "$JSTACK_STATE_DIR/collided"
}

repo="$T/repo"
other_repo="$T/other"
make_repo "$repo" repo
make_repo "$other_repo" other

t "original worker records two tickets" setup_old_run
run_id=$(run_id_from_state "$JSTACK_STATE_DIR/old-worker")
printf 'changed snapshot\n' >>"$repo/README.md"
same_repo_clone="$T/repo-clone"
git clone -q "$repo" "$same_repo_clone" >/dev/null 2>&1
git -C "$same_repo_clone" remote set-url origin https://github.com/example/repo.git

t "discovery finds a matching ticket in current repository" \
	discover new-worker "$repo" '#2' "$T/discovery"
t "discovery emits requested metadata" discovery_ok "$T/discovery" "$run_id"
t "discovery matches any ticket in the run" \
	discover new-worker "$repo" '#1' "$T/discovery-first-ticket"
t "first-ticket discovery retains current ticket metadata" \
	discovery_matches_any_ticket "$T/discovery-first-ticket" "$run_id"
t "another repository has no matching discoveries" other_discovery_is_empty

t "wrong current ticket cannot take over" \
	not resume wrong-ticket "$repo" "$run_id" old-worker '#1'
t "wrong-ticket attempt leaves old state" test -f "$JSTACK_STATE_DIR/old-worker"
t "different worktree cannot take over" \
	not resume wrong-worktree "$same_repo_clone" "$run_id" old-worker '#2'
t "subagent cannot take over parent state" \
	not env JSTACK_SUBAGENT_ID=worker-1 JSTACK_SESSION_ID=subagent JSTACK_STATE_DIR="$JSTACK_STATE_DIR" \
		"$BASH" "$ST" resume "$run_id" --from-session old-worker --ticket '#2'
t "collision state is not overwritten" collision_is_refused

compete() {
	resume "$1" "$repo" "$run_id" old-worker '#2' >"$T/$1.out" 2>"$T/$1.err"
}

race_takeover() {
	compete successor-a &
	local first=$!
	compete successor-b &
	local second=$!
	local first_status=0 second_status=0
	wait "$first" || first_status=$?
	wait "$second" || second_status=$?
	[ $(( (first_status == 0) + (second_status == 0) )) -eq 1 ] || return 1
	if [ -f "$JSTACK_STATE_DIR/successor-a" ] && [ ! -e "$JSTACK_STATE_DIR/successor-b" ]; then
		WINNER=successor-a
	elif [ -f "$JSTACK_STATE_DIR/successor-b" ] && [ ! -e "$JSTACK_STATE_DIR/successor-a" ]; then
		WINNER=successor-b
	else
		return 1
	fi
}

t "one of two successor sessions wins takeover" race_takeover
winner=${WINNER:-successor-a}
t "takeover preserves run ID and prior receipts" takeover_ok "$run_id" "$winner"
t "first ticket PR remains historical, not replayed" \
	sh -c 'grep -q "^prior land pr https://github.com/example/repo/pull/1$" "$1" && ! grep -q "^land pr " "$1"' _ \
	"$JSTACK_STATE_DIR/$winner"

verify_gate_blocks() {
	stop_reason "$1" | grep -q "verify 缺少本阶段"
}
verify_gate_passes() {
	! stop_reason "$1" | grep -q "verify 缺少本阶段"
}

t "takeover requires fresh verify evidence" verify_gate_blocks "$winner"
t "new verification evidence is accepted after takeover" \
	stage "$winner" "$repo" evidence "fresh verify -> passed"
t "fresh verification is distinct from prior evidence" \
	sh -c 'grep -q "^evidence verify fresh verify -> passed$" "$1" && grep -q "^prior evidence verify second verify -> passed$" "$1"' _ \
	"$JSTACK_STATE_DIR/$winner"
t "stop gate no longer reports missing verify evidence" verify_gate_passes "$winner"

resume_after_land() {
	stage "$winner" "$repo" enter review &&
		stage "$winner" "$repo" review complete "second review -> clean" &&
		stage "$winner" "$repo" enter land &&
		stage "$winner" "$repo" land commit 89abcdef0123456789abcdef0123456789abcdef &&
		stage "$winner" "$repo" land pr https://github.com/example/repo/pull/2 &&
		resume after-land "$repo" "$run_id" "$winner" '#2' &&
		takeover_ok "$run_id" after-land &&
		grep -qx 'prior review complete second review -> clean' "$JSTACK_STATE_DIR/after-land" &&
		grep -qx 'prior land pr https://github.com/example/repo/pull/2' "$JSTACK_STATE_DIR/after-land"
}

t "handoff from land rechecks gates and retains both PR receipts" resume_after_land

resume_requires_verification() {
	local verification_repo="$T/verify-repo" verification_run
	make_repo "$verification_repo" verify-repo &&
		stage before-verify "$verification_repo" start --size S --ticket '#57' execute,verify &&
		stage before-verify "$verification_repo" enter verify &&
		printf '{"verify":{"command":"exit 23"}}\n' >"$verification_repo/.jstack/config.json" &&
		! stage before-verify "$verification_repo" verify &&
		test -f "$JSTACK_STATE_DIR/before-verify.verify.json" || return 1
	mv "$verification_repo/.jstack/config.json" "$T/previous-verification.json" || return 1
	verification_run=$(run_id_from_state "$JSTACK_STATE_DIR/before-verify")
	resume after-verify "$verification_repo" "$verification_run" before-verify '#57' &&
		stage after-verify "$verification_repo" evidence 'fixture -> passed' &&
		! stage after-verify "$verification_repo" end || return 1
	printf '{"verify":{"command":"exit 0"}}\n' >"$verification_repo/.jstack/config.json" &&
		stage after-verify "$verification_repo" end
}
t "resumed run requires revalidation when its old execution had a receipt" resume_requires_verification

exit "$FAILS"
