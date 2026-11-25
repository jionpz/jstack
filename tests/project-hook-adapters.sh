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
  def imported: select(.type == "command" and .timeout == 10 and (.command | startswith("JSTACK_CURSOR_HOOK_SOURCE=claude-project exec ")));
  ([.hooks.UserPromptSubmit[].hooks[] | imported] | length == 1) and
  ([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | imported] | length == 1) and
  ([.hooks.PreToolUse[] | select(.matcher == "Write|Edit|MultiEdit|NotebookEdit") | .hooks[] | imported] | length == 1) and
  ([.hooks.Stop[].hooks[] | imported] | length == 1)
' "$REPO/.claude/settings.json" >/dev/null || die "Claude hook template is incomplete"
jq -e '
  .version == 1 and
  (.hooks.beforeShellExecution[0].command | contains("hooks/guard.sh")) and
  (.hooks.preToolUse[0].command | contains("hooks/guard.sh")) and
  (.hooks.beforeSubmitPrompt[0].command | contains("hooks/prompt.sh")) and
  (.hooks.stop[0].command | contains("hooks/stop.sh")) and
  (.hooks.stop[0].loop_limit == 3)
' "$REPO/.cursor/hooks.json" >/dev/null || die "Cursor hook template is incomplete"
jq -e '
  ([.hooks.UserPromptSubmit[0].hooks[0].command,
    .hooks.PreToolUse[0].hooks[0].command,
    .hooks.PreToolUse[1].hooks[0].command,
    .hooks.Stop[0].hooks[0].command] |
    all(startswith("repo=$(git rev-parse --show-toplevel) && exec \"$repo/.jstack/vendor/plugins/flow/hooks/"))) and
  ([.hooks.PreToolUse[].matcher] | index("Bash") != null) and
  ([.hooks.PreToolUse[].matcher] | index("apply_patch") != null)
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

# 用户级本地 flow 同时以 Cursor 原生插件和 Claude 兼容导入加载时，导入副本应让原生副本执行。
plugin="$ROOT/plugins/flow"
plugin_prompt=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$plugin/hooks/hooks.json")
local_home="$T/local-home"
local_flow="$local_home/.cursor/plugins/local/flow"
mkdir -p "$local_flow/hooks"
cp -R "$plugin/hooks/." "$local_flow/hooks/"
cp -R "$plugin/skills" "$local_flow/"
imported_duplicate=$(printf '%s' "$prompt_json" |
	HOME="$local_home" CLAUDE_PLUGIN_ROOT="$plugin" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$plugin_prompt")
[ -z "$imported_duplicate" ] || die "Imported Claude plugin prompt ran beside the native Cursor plugin"
rm "$local_flow/hooks/hooks.cursor.json"
imported_fallback=$(printf '%s' "$prompt_json" |
	HOME="$local_home" CLAUDE_PLUGIN_ROOT="$plugin" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$plugin_prompt")
[ -n "$imported_fallback" ] || die "Imported Claude plugin stopped without a native Cursor plugin"
printf '%s' "$imported_fallback" | jq -e 'has("additional_context")' >/dev/null ||
	die "Imported Claude plugin fallback has the wrong protocol"
say "Cursor-native and imported copies of the user plugin produce one prompt response"

# 项目级 Cursor hooks 存在时，同名的用户级插件脚本应退出；项目 vendor 自己仍要执行。
user_flow="$T/user-flow"
mkdir -p "$user_flow"
cp -R "$plugin/hooks" "$user_flow/"
cp -R "$plugin/skills" "$user_flow/"
user_prompt_out=$(printf '%s' "$prompt_json" |
	CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 CURSOR_CONVERSATION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash "$user_flow/hooks/prompt.sh")
[ -z "$user_prompt_out" ] || die "User-level prompt ran beside the project-level Cursor hook"
no_project_prompt=$(printf '%s' "$prompt_json" |
	CURSOR_VERSION=1 CURSOR_CONVERSATION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash "$user_flow/hooks/prompt.sh")
[ -n "$no_project_prompt" ] || die "User-level prompt stopped without a project-level hook"
user_guard_out=$(printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/.env"}}' "$SID" |
	CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash "$user_flow/hooks/guard.sh")
[ -z "$user_guard_out" ] || die "User-level guard ran beside the project-level Cursor hook"
project_guard_out=$(printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/.env"}}' "$SID" |
	CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash "$FLOW/hooks/guard.sh")
printf '%s' "$project_guard_out" | jq -e '.permission == "deny"' >/dev/null ||
	die "Project guard stopped when it was the active Cursor hook"
say "Project Cursor hooks suppress user-level copies without suppressing themselves"

no_jq_user_prompt() {
	printf '%s' "$prompt_json" |
		JSTACK_NO_JQ=1 CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 CURSOR_CONVERSATION_ID="$SID" \
		JSTACK_STATE_DIR="$T/state" bash "$user_flow/hooks/prompt.sh"
}
[ -z "$(no_jq_user_prompt)" ] || die "User-level prompt ran beside its project event without jq"
jq -n --arg prompt "$cursor_prompt" --arg stop "$cursor_stop" \
	'{version:1,hooks:{beforeSubmitPrompt:[{command:$stop}],stop:[{command:$prompt}]}}' >"$REPO/.cursor/hooks.json"
[ -n "$(no_jq_user_prompt)" ] || die "User-level prompt yielded to a command registered for a different event"
say "Without jq, project ownership requires the exact event and command"

jq -n '{version:1,hooks:{}}' >"$REPO/.cursor/hooks.json"
fallback_out=$(printf '%s' "$prompt_json" |
	HOME="$local_home" CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$REPO" CURSOR_VERSION=1 JSTACK_STATE_DIR="$T/state" bash -c "$claude_prompt")
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
install_cursor_hooks "$REPO" 0
cp "$REPO/.cursor/hooks.json" "$T/project-cursor-hooks.json"
cp "$plugin/hooks/hooks.cursor.json" "$local_flow/hooks/"
imported_flow="$local_home/.claude/plugins/cache/jstack/flow/test"
mkdir -p "$imported_flow"
cp -R "$plugin/hooks" "$plugin/skills" "$imported_flow/"
replay_cursor() {
	printf '%s' "$1" |
		PATH="$replay_path" HOME="$local_home" CLAUDE_PROJECT_DIR="$REPO" CURSOR_PROJECT_DIR="$2" \
		CLAUDE_PLUGIN_ROOT="$plugin" CURSOR_PLUGIN_ROOT="$local_flow" CURSOR_VERSION=1 \
		CURSOR_CONVERSATION_ID="$SID" JSTACK_STATE_DIR="$T/state" /bin/bash -c "$3"
}
business_prompt="printf '%s' '{\"additional_context\":\"business probe\"}'"
edit_json=$(printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/.env"}}' "$SID")
shell_json=$(printf '{"conversation_id":"%s","hook_event_name":"beforeShellExecution","command":"git clean -fd"}' "$SID")
import_shell_json=$(printf '{"conversation_id":"%s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git clean -fd"}}' "$SID")
for replay_path in "$PATH" "$no_jq_bin"; do
	for event in beforeSubmitPrompt beforeShellExecution preToolUse stop; do
		case $event in
		beforeSubmitPrompt) section='.hooks.UserPromptSubmit[0]'; payload=$prompt_json; import_payload=$payload; response='has("additional_context")' ;;
		beforeShellExecution) section='.hooks.PreToolUse[0]'; payload=$shell_json; import_payload=$import_shell_json; response='.permission == "ask"' ;;
		preToolUse) section='.hooks.PreToolUse[1]'; payload=$edit_json; import_payload=$payload; response='.permission == "deny"' ;;
		stop) section='.hooks.Stop[0]'; payload=$stop_json; import_payload=$payload; response='has("followup_message")' ;;
		esac
		project_native=$(jq -r --arg event "$event" '.hooks[$event][0].command' "$T/project-cursor-hooks.json")
		user_native=$(jq -r --arg event "$event" '.hooks[$event][0].command' "$local_flow/hooks/hooks.cursor.json")
		cache_import="CURSOR_PLUGIN_ROOT=\"$imported_flow\"; $user_native"
		project_import=$(jq -r "$section.hooks[0].command" "$REPO/.claude/settings.json")
		plugin_import=$(jq -r "$section.hooks[0].command" "$plugin/hooks/hooks.json")
		replay_cursor "$payload" "$REPO" "$project_native" | jq -e "$response" >/dev/null ||
			die "Project Cursor hook did not respond for $event"
		[ -z "$(replay_cursor "$payload" "$REPO" "$user_native")" ] &&
			[ -z "$(replay_cursor "$payload" "$REPO" "$cache_import")" ] &&
			[ -z "$(replay_cursor "$import_payload" "$REPO" "$project_import")" ] &&
			[ -z "$(replay_cursor "$import_payload" "$REPO" "$plugin_import")" ] ||
			die "More than one JStack hook responded for $event"
		replay_cursor "$payload" "" "$user_native" | jq -e "$response" >/dev/null ||
			die "User-only Cursor hook did not respond for $event"
		[ -z "$(replay_cursor "$import_payload" "" "$plugin_import")" ] ||
			die "Imported Claude plugin ran beside its user-level Cursor hook for $event"
		[ -z "$(replay_cursor "$payload" "" "$cache_import")" ] ||
			die "Claude cache plugin's native hook ran beside its user-level Cursor hook for $event"
	done
	replay_cursor "$prompt_json" "$REPO" "$business_prompt" | jq -e '.additional_context == "business probe"' >/dev/null ||
		die "Independent Cursor hook did not respond"
done
say "Mixed Cursor hook commands respond once per event with and without jq, and the business hook still runs"

replay_path=$no_jq_bin
mv "$local_flow/hooks/hooks.cursor.json" "$T/user-cursor-hooks.json"
jq -n '{version:1,hooks:{}}' >"$REPO/.cursor/hooks.json"
replay_cursor "$prompt_json" "$REPO" "$claude_prompt" | jq -e 'has("additional_context")' >/dev/null ||
	die "Imported Claude prompt did not fall back without jq and a native config"
project_shell=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REPO/.claude/settings.json")
replay_cursor "$import_shell_json" "$REPO" "$project_shell" | jq -e '.permission == "deny"' >/dev/null ||
	die "Imported Claude shell guard did not fall back without native shell hooks"
say "Imported Claude hooks still handle prompts and shell commands without native Cursor hooks"

codex_prompt=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$REPO/.codex/hooks.json")
codex_prompt_out=$(cd "$REPO" && printf '{"session_id":"%s","turn_id":"turn-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$SID" |
	CODEX_SESSION_ID="$SID" JSTACK_STATE_DIR="$T/state" bash -c "$codex_prompt")
printf '%s' "$codex_prompt_out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null ||
	die "Codex portable hook did not resolve vendor from Git root"
say "Codex hooks resolve from Git root with spaces"
