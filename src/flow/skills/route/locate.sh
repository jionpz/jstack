#!/usr/bin/env bash
# 按 stages.md 的 Providers 列打印每个提供者文件的绝对路径，每行"提供者<TAB>路径"。
# 提供者写成 <插件>:<skill>（指 SKILL.md）或 <插件>:<skill>/<文件>（指 skill 目录里的那个文件）。
# 任一提供者找不到时，先打印找得到的，再在 stderr 点名缺的，最后 exit 1。
# JSTACK_STAGES_FILE 可覆盖表的路径，只用于测试。
# 变量后紧跟中文标点时必须写成 ${VAR}：macOS 的 bash 3.2 在 UTF-8 locale 下会把标点首字节算进变量名。
# 支持的布局：
#   本地 marketplace       plugins/<插件>/skills/...
#   Claude GitHub 缓存     cache/jstack/<插件>/<版本>/skills/...
#   Pi package             <包>/<插件>/skills/...，或 node_modules 下同级的 <插件>、jstack-<插件>、@jstack/<插件>
#   OMP marketplace 缓存   cache/plugins/jstack___<插件>___<版本>/skills/...
#   Cursor 本地插件        <Cursor 插件根>/local/<插件>/skills/...
# 缓存里同一插件留有多个版本时，取最近写入的那个。
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
base=$(dirname "$root")
[ "$(basename "$base")" = flow ] && base=$(dirname "$base")
home=${HOME:-}
pi_agent=${PI_AGENT_DIR:-$home/.pi/agent}
pi_npm=$pi_agent/npm/node_modules
omp_plugins=${OMP_PLUGINS_DIR:-$home/.omp/plugins}
claude_plugins=${CLAUDE_PLUGINS_DIR:-$home/.claude/plugins}
cursor_plugins=${CURSOR_PLUGINS_DIR:-$home/.cursor/plugins}
stages=${JSTACK_STAGES_FILE:-$(dirname "${BASH_SOURCE[0]}")/stages.md}
[ -f "$stages" ] || { echo "locate: 找不到阶段表 ${stages}" >&2; exit 1; }
# 只在当前 harness 的目录里找备用安装，避免把 Cursor 路由到 Claude Code 的 pstack 树。
case $root in
*/.cursor/plugins/*) harness=cursor ;;
*/.omp/plugins/*) harness=omp ;;
*/.pi/agent/* | */.pi/npm/* | */.pi/git/*) harness=pi ;;
*) harness=claude ;;
esac

# 找到的 skill 目录放进 found。
try_skill() {
	[ -f "$1/SKILL.md" ] || return 1
	found=$1
}

# $1 是技能目录，里面直接放 <名字>/SKILL.md 或 <分类>/<名字>/SKILL.md。
look_skills_dir() {
	local dir=$1 name=$2 rel
	for rel in "$name" "engineering/$name" "productivity/$name"; do
		try_skill "$dir/$rel" && return 0
	done
	return 1
}

# $1 是插件根目录，先找 <根>/skills/...，再找 <根>/<版本>/skills/...。
look_plugin_root() {
	local plugin_root=$1 name=$2 rel hit
	for rel in "skills/$name" "skills/engineering/$name" "skills/productivity/$name"; do
		try_skill "$plugin_root/$rel" && return 0
		hit=$(ls -dt "$plugin_root"/*/"$rel"/SKILL.md 2>/dev/null | head -1 || true)
		[ -n "$hit" ] || continue
		try_skill "$(dirname "$hit")"
		return 0
	done
	return 1
}

look_roots() {
	local name=$1 plugin_root
	shift
	for plugin_root in "$@"; do
		look_plugin_root "$plugin_root" "$name" && return 0
	done
	return 1
}

find_skill() {
	local plugin=$1 name=$2 around r

	# 脚本自己所在的安装树：本地 marketplace、Claude 缓存、Pi package、OMP 缓存、Cursor 本地插件。
	look_roots "$name" \
		"$base/$plugin" \
		"$base/jstack-$plugin" \
		"$base/@jstack/$plugin" \
		"$base/@jionpz/$plugin" \
		"$base/plugins/$plugin" \
		"$root" && return 0

	# 平铺的 Pi package：<包>/skills/<名字>/SKILL.md，或 <包>/skills/<插件>/<名字>/SKILL.md。
	look_skills_dir "$root/skills" "$name" && return 0
	look_skills_dir "$root/skills/$plugin" "$name" && return 0

	# 仓库源码：src/flow 旁边的 plugins/。
	if [ -d "$base/../plugins" ]; then
		around=$(cd "$base/../plugins" && pwd -P)
		look_plugin_root "$around/$plugin" "$name" && return 0
	fi

	# OMP 把安装内容放成 <插件>___<版本> 的兄弟目录。
	for r in $(ls -dt "$base"/*___"$plugin"___* 2>/dev/null || true); do
		look_plugin_root "$r" "$name" && return 0
	done

	# 当前 harness 的固定安装位置，用于定位不在脚本旁边的同名插件。
	case $harness in
	pi)
		look_roots "$name" \
			"$pi_npm/$plugin" \
			"$pi_npm/jstack-$plugin" \
			"$pi_npm/@jstack/$plugin" \
			"$pi_npm/@jionpz/$plugin" \
			"$pi_npm/jstack/plugins/$plugin" \
			"$pi_npm/jstack/$plugin" && return 0
		look_skills_dir "$pi_npm/jstack/skills" "$name" && return 0
		look_skills_dir "$pi_npm/jstack/skills/$plugin" "$name" && return 0
		for r in $(ls -dt "$pi_agent"/git/*/*/jstack* 2>/dev/null || true); do
			look_roots "$name" "$r" "$r/plugins/$plugin" "$r/$plugin" && return 0
			look_skills_dir "$r/skills" "$name" && return 0
		done
		;;
	omp)
		look_roots "$name" \
			"$omp_plugins/cache/plugins/$plugin" \
			"$omp_plugins/cache/marketplaces/jstack/plugins/$plugin" \
			"$omp_plugins/cache/marketplaces/jstack/$plugin" && return 0
		for r in $(ls -dt "$omp_plugins"/cache/plugins/*___"$plugin"___* 2>/dev/null || true); do
			look_plugin_root "$r" "$name" && return 0
		done
		;;
	cursor)
		look_plugin_root "$cursor_plugins/local/$plugin" "$name" && return 0
		;;
	*)
		look_plugin_root "$claude_plugins/cache/jstack/$plugin" "$name" && return 0
		;;
	esac
	return 1
}

# 只读 "## Stages" 标题下的第一张表：跳过表头和分隔行，取第 4 列里反引号括起来的提供者，按首次出现去重。
providers=$(awk '
	/^## / { sec = ($0 ~ /^## Stages[ \t]*$/); next }
	!sec { next }
	/^\|/ { rows++ }
	rows && !/^\|/ { exit }
	!/^\|/ || rows == 1 || /^\|[-:| \t]+$/ { next }
	{
		split($0, col, "|")
		cell = col[5]
		while (match(cell, /`[^`]*`/)) {
			tok = substr(cell, RSTART + 1, RLENGTH - 2)
			cell = substr(cell, RSTART + RLENGTH)
			if (tok ~ /^[a-z][a-z0-9-]*:[A-Za-z0-9._\/-]+$/ && !seen[tok]++) print tok
		}
	}
' "$stages")
[ -n "$providers" ] || { echo "locate: ${stages} 的 Stages 表里没有解析出任何提供者" >&2; exit 1; }

missing=0
while IFS= read -r tok; do
	plugin=${tok%%:*} rest=${tok#*:}
	name=${rest%%/*} file=SKILL.md
	[ "$rest" = "$name" ] || file=${rest#*/}
	if ! find_skill "$plugin" "$name"; then
		echo "locate: 找不到 ${tok}：${plugin} 插件里没有 ${name} skill，已检查 Claude Code、Pi、OMP、Cursor 的安装布局" >&2
		missing=1
	elif [ ! -f "$found/$file" ]; then
		echo "locate: 找不到 ${tok}：${found} 里没有 ${file}" >&2
		missing=1
	else
		printf '%s\t%s\n' "$tok" "$found/$file"
	fi
done <<<"$providers"
exit $missing
