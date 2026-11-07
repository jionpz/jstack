#!/usr/bin/env bash
# 打印 jstack 各插件入口 SKILL.md 的绝对路径，每行"名字<TAB>路径"。
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
# 只在当前 harness 的目录里找备用安装，避免把 Cursor 路由到 Claude Code 的 pstack 树。
case $root in
*/.cursor/plugins/*) harness=cursor ;;
*/.omp/plugins/*) harness=omp ;;
*/.pi/agent/* | */.pi/npm/* | */.pi/git/*) harness=pi ;;
*) harness=claude ;;
esac

try_skill() {
	local name=$1 hit=$2
	[ -f "$hit" ] || return 1
	printf '%s\t%s\n' "$name" "$hit"
}

# $1 是技能目录，里面直接放 <名字>/SKILL.md 或 <分类>/<名字>/SKILL.md。
look_skills_dir() {
	local dir=$1 name=$2 rel
	for rel in "$name/SKILL.md" "engineering/$name/SKILL.md" "productivity/$name/SKILL.md"; do
		try_skill "$name" "$dir/$rel" && return 0
	done
	return 1
}

# $1 是插件根目录，先找 <根>/skills/...，再找 <根>/<版本>/skills/...。
look_plugin_root() {
	local plugin_root=$1 name=$2 rel hit
	for rel in "skills/$name/SKILL.md" "skills/engineering/$name/SKILL.md" "skills/productivity/$name/SKILL.md"; do
		try_skill "$name" "$plugin_root/$rel" && return 0
		hit=$(ls -dt "$plugin_root"/*/"$rel" 2>/dev/null | head -1 || true)
		[ -n "$hit" ] || continue
		try_skill "$name" "$hit"
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

	echo "locate: 找不到 ${plugin} 插件的 ${name} skill，已检查 Claude Code、Pi、OMP、Cursor 的安装布局" >&2
	return 1
}

find_skill pstack poteto-mode
for s in setup-matt-pocock-skills grill-with-docs to-spec to-tickets wayfinder; do
	find_skill spec "$s"
done
find_skill spec handoff
