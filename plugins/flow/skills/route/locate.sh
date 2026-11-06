#!/usr/bin/env bash
# 打印 jstack 各插件入口 SKILL.md 的绝对路径，每行"名字<TAB>路径"。
# 本地 marketplace 的布局是 plugins/<插件>/，从 GitHub 安装的布局是 cache/jstack/<插件>/<版本>/，两种都支持。
# 缓存里同一插件留有多个版本时，取最近写入的那个。
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
base=$(dirname "$root")
[ "$(basename "$base")" = flow ] && base=$(dirname "$base")
find_skill() {
	local plugin=$1 rel=$2 hit
	hit=$(ls -dt "$base/$plugin/$rel" "$base/$plugin"/*/"$rel" 2>/dev/null | head -1 || true)
	[ -n "$hit" ] || { echo "locate: 找不到 $plugin 插件的 $rel，确认 $plugin@jstack 已安装" >&2; return 1; }
	printf '%s\t%s\n' "/$plugin:$(basename "$(dirname "$hit")")" "$hit"
}
find_skill pstack skills/poteto-mode/SKILL.md
for s in setup-matt-pocock-skills grill-with-docs to-spec to-tickets wayfinder; do
	find_skill spec "skills/engineering/$s/SKILL.md"
done
find_skill spec skills/productivity/handoff/SKILL.md
