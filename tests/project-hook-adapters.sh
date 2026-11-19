#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
REPO="$T/repo with spaces"
mkdir -p "$REPO/.claude" "$REPO/.cursor" "$REPO/.codex"
git -C "$REPO" init -q

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
say() { printf '✓ %s\n' "$*"; }
awk '
  /^install_claude_hooks\(\) \{|^install_cursor_hooks\(\) \{|^install_codex_hooks\(\) \{/ { copy=1 }
  copy { print }
  copy && /^}/ { copy=0 }
' "$ROOT/jstack" >"$T/hook-functions.sh"
source "$T/hook-functions.sh"

install_claude_hooks "$REPO" 0
install_cursor_hooks "$REPO" 0
install_codex_hooks "$REPO" 0
jq -e '
  ([.hooks.UserPromptSubmit[].hooks[] | select(.type == "command" and .timeout == 10 and (.command | contains("CURSOR_VERSION")))] | length == 1) and
  ([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.type == "command" and .timeout == 10 and (.command | contains("CURSOR_VERSION")))] | length == 1) and
  ([.hooks.Stop[].hooks[] | select(.type == "command" and .timeout == 10 and (.command | contains("CURSOR_VERSION")))] | length == 1)
' "$REPO/.claude/settings.json" >/dev/null || die "Claude hook template is incomplete"
jq -e '
  .version == 1 and
  (.hooks.beforeShellExecution[0].command | contains("hooks/guard.sh")) and
  (.hooks.beforeSubmitPrompt[0].command | contains("hooks/prompt.sh")) and
  (.hooks.stop[0].command | contains("hooks/stop.sh")) and
  (.hooks.stop[0].loop_limit == 3)
' "$REPO/.cursor/hooks.json" >/dev/null || die "Cursor hook template is incomplete"
jq -e '
  ([.hooks.UserPromptSubmit[0].hooks[0].command,
    .hooks.PreToolUse[0].hooks[0].command,
    .hooks.Stop[0].hooks[0].command] |
    all(startswith("repo=$(git rev-parse --show-toplevel) && exec \"$repo/.jstack/vendor/plugins/flow/hooks/"))) and
  (.hooks.PreToolUse[0].matcher == "Bash")
' "$REPO/.codex/hooks.json" >/dev/null || die "Codex hooks are not portable"
say "Project hook templates contain all three adapters"

FLOW="$REPO/.jstack/vendor/plugins/flow"
mkdir -p "$FLOW"
cp -R "$ROOT/plugins/flow/hooks" "$FLOW/"
cp -R "$ROOT/plugins/flow/skills" "$FLOW/"
SID=adapter-session
mkdir -p "$T/state"
printf 'path execute,verify\nstage execute\n' >"$T/state/$SID"

cursor_prompt=$(jq -r '.hooks.beforeSubmitPrompt[0].command' "$REPO/.cursor/hooks.json")
claude_prompt=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$REPO/.claude/settings.json")
cursor_stop=$(jq -r '.hooks.stop[0].command' "$REPO/.cursor/hooks.json")
claude_stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$REPO/.claude/settings.json")
prompt_json=$(printf '{"conversation_id":"%s","hook_event_name":"beforeSubmitPrompt","prompt":"hi"}' "$SID")
stop_json=$(printf '{"conversation_id":"%s","hook_event_name":"stop","status":"completed","loop_count":0}' "$SID")
cursor_prompt_out=$(printf '%s' "$prompt_json" | CURSOR_PROJECT_DIR="$REPO" CURSOR_CONVERSATION_ID="$SID" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$cursor_prompt")
claude_import_prompt_out=$(printf '%s' "$prompt_json" | CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$claude_prompt")
claude_prompt_out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID" |
	CLAUDE_PROJECT_DIR="$REPO" CLAUDE_CODE_SESSION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash -c "$claude_prompt")
[ -n "$cursor_prompt_out" ] && [ -z "$claude_import_prompt_out" ] && [ -n "$claude_prompt_out" ] ||
	die "Cursor prompt must respond once while Claude remains active in Claude"
printf '%s' "$cursor_prompt_out" | jq -e 'has("additional_context")' >/dev/null ||
	die "Cursor prompt response has the wrong protocol"
printf '%s' "$claude_prompt_out" | grep -qF 'jstack 提示门禁注入' ||
	die "Claude prompt response is missing"

cursor_stop_out=$(printf '%s' "$stop_json" | CURSOR_PROJECT_DIR="$REPO" CURSOR_CONVERSATION_ID="$SID" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$cursor_stop")
claude_import_stop_out=$(printf '%s' "$stop_json" | CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$claude_stop")
claude_stop_out=$(printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$SID" |
	CLAUDE_PROJECT_DIR="$REPO" CLAUDE_CODE_SESSION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash -c "$claude_stop")
[ -n "$cursor_stop_out" ] && [ -z "$claude_import_stop_out" ] && [ -n "$claude_stop_out" ] ||
	die "Cursor Stop must respond once while Claude remains active in Claude"
printf '%s' "$cursor_stop_out" | jq -e 'has("followup_message")' >/dev/null ||
	die "Cursor Stop response has the wrong protocol"
printf '%s' "$claude_stop_out" | jq -e '.decision == "block"' >/dev/null ||
	die "Claude Stop response has the wrong protocol"
say "Cursor and imported Claude prompt/Stop produce one response"

jq -n '{version:1,hooks:{}}' >"$REPO/.cursor/hooks.json"
fallback_out=$(printf '%s' "$prompt_json" |
	CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$claude_prompt")
[ -n "$fallback_out" ] || die "Claude fallback was suppressed without a native Cursor hook"
printf '%s' "$fallback_out" | jq -e 'has("additional_context")' >/dev/null ||
	die "Claude fallback did not keep the Cursor protocol"
say "Claude fallback runs when no native Cursor hook exists"

no_jq_bin="$T/no-jq-bin"
mkdir -p "$no_jq_bin"
IFS=: read -r -a path_entries <<<"$PATH"
for path_entry in "${path_entries[@]}"; do
	[ -d "$path_entry" ] || continue
	for executable in "$path_entry"/*; do
		[ -x "$executable" ] || continue
		name=${executable##*/}
		[ "$name" = jq ] && continue
		[ -e "$no_jq_bin/$name" ] || ln -s "$executable" "$no_jq_bin/$name"
	done
done
jq -n '{version:1,hooks:{beforeSubmitPrompt:[{command:"\"${CURSOR_PROJECT_DIR}/.jstack/vendor/plugins/flow\"/hooks/prompt.sh",timeout:10}]}}' >"$REPO/.cursor/hooks.json"
no_jq_out=$(printf '%s' "$prompt_json" |
	PATH="$no_jq_bin" CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" /bin/bash -c "$claude_prompt")
[ -n "$no_jq_out" ] || die "Claude fallback was suppressed when jq is unavailable"
say "Without jq, imported Claude hook remains the fallback"

codex_prompt=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$REPO/.codex/hooks.json")
codex_prompt_out=$(cd "$REPO" && printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID" |
	CODEX_SESSION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash -c "$codex_prompt")
printf '%s' "$codex_prompt_out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null ||
	die "Codex portable hook did not resolve vendor from Git root"
say "Codex hooks resolve from Git root with spaces"
