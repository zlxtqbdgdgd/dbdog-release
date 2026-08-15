#!/usr/bin/env bash
# fast-upgrade.sh 的 prune_installed_versions 守门。
#
# 它删的是**已安装的版本目录**，一旦误删 current 指向的那个，线上服务当场没了可执行文件。
# 所以这里断言的不是「删了几个」，而是**「current 指向的目录必须活着」**这条硬约束。
#
# 关键用例是「路径里含一段软链」：2026-08-16 首版实现用
#   ls -1dt <dir>/*/ | grep -vF "$(readlink -f .../current)/"
# 做保护——两条**独立推导**出来的路径串，只要中间任何一段是软链就对不上，
# 保护会**静默失效**。当时真机上没出事，只是碰巧那条路径没有软链。
# 现版改成候选与 current 都 readlink -f 之后再比，两边同一种归一化。
#
# 跑法：bash scripts/test-fast-upgrade-prune.sh
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
ok()   { echo "  PASS $*"; }
bad()  { echo "  FAIL $*"; fail=1; }

# 把被测函数从 fast-upgrade.sh 里原样取出来跑——不复制一份实现来测（复制品测了不算数）。
fn="$(awk '/^prune_installed_versions\(\)/,/^}$/' "$SCRIPTS_DIR/fast-upgrade.sh")"
[ -n "$fn" ] || { echo "FAIL 没能从 fast-upgrade.sh 取到 prune_installed_versions"; exit 1; }

log() { :; }                       # 静音
as_stack_user() { "$@"; }          # 测试里不切用户
STACK_USER="${STACK_USER:-dbdog}"
eval "$fn"

# ---- 假树：路径含软链；current 故意指向一个「很旧」的版本 ----
real="$(mktemp -d)"; linkbase="$(mktemp -d)"; ln -s "$real" "$linkbase/link"
export DBDOG_HOME="$linkbase/link"
mkdir -p "$real/modules/demo" "$real/cache"
for i in 1 2 3 4 5 6 7 8; do
  mkdir -p "$real/modules/demo/demo-v$i"; touch -d "2026-08-0$i" "$real/modules/demo/demo-v$i"
done
ln -s "$real/modules/demo/demo-v2" "$real/modules/demo/current"
for i in 1 2 3 4 5 6 7; do
  : > "$real/cache/demo-0.$i.tar.gz"; touch -d "2026-08-0$i" "$real/cache/demo-0.$i.tar.gz"
done

echo "case A：留 3 代，且 current 指向的旧版本必须豁免"
FAST_UPGRADE_KEEP=3 prune_installed_versions demo

t="$(readlink -f "$real/modules/demo/current")"
[ -d "$t" ] && ok "current 指向仍在（$(basename "$t")）" || bad "current 指向被删——这是最严重的失效"
left="$(ls -1d "$real/modules/demo/"*/ | grep -vc '/current/$')"
[ "$left" = 4 ] && ok "剩 4 个版本目录（保留 3 + current 指向的那个）" || bad "剩 $left 个，期望 4"
for v in demo-v2 demo-v6 demo-v7 demo-v8; do
  [ -d "$real/modules/demo/$v" ] || bad "$v 不该被删"
done
for v in demo-v1 demo-v3 demo-v4 demo-v5; do
  [ -d "$real/modules/demo/$v" ] && bad "$v 该被删却还在"
done
pk="$(ls -1 "$real/cache/"*.tar.gz | wc -l | tr -d ' ')"
[ "$pk" = 3 ] && ok "安装包缓存留 3 个" || bad "缓存剩 $pk 个，期望 3"

echo "case B：布局不符预期（current 不是软链）时一律不动手"
mkdir -p "$real/modules/odd"; mkdir -p "$real/modules/odd/current"
for i in 1 2 3 4 5; do mkdir -p "$real/modules/odd/odd-v$i"; done
FAST_UPGRADE_KEEP=1 prune_installed_versions odd
n="$(ls -1d "$real/modules/odd/"*/ | grep -vc '/current/$')"
[ "$n" = 5 ] && ok "布局不符时原样不动（仍 5 个）" || bad "布局不符却动了手，剩 $n 个"

rm -rf "$real" "$linkbase"
[ "$fail" = 0 ] && { echo "全部通过"; exit 0; } || { echo "有失败"; exit 1; }
