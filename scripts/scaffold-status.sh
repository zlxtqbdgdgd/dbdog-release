#!/usr/bin/env bash
# 升级脚手架现状：每条自哪个发布版本起随产物生效、距最新发布隔了几次。
# 用法：scaffold-status.sh
# 登记表（含病症、判据与删除清单）：docs/upgrade-scaffolds.md；规矩见家族军规 10。
# 生效版本不落字面量，一律由「引入提交之后该模块的第一次 publish 提交」推导。

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

REGISTRY="$RELEASE_DIR/docs/upgrade-scaffolds.md"
[ -f "$REGISTRY" ] || die "缺登记表: $REGISTRY"

scaffold_meta_field() { # <元数据行> <字段名>
  printf '%s\n' "$1" | awk -v k="$2" '{
    for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == k) { print kv[2]; exit } }
  }'
}

publish_versions_since() { # <模块> <引入提交>；按时间顺序列出该提交之后的发布版本
  git -C "$RELEASE_DIR" log --reverse --format=%s "$2..HEAD" \
    --grep="^publish: $1@" 2>/dev/null | sed "s/^publish: $1@//"
}

rows=0
printf '%-5s %-14s %-14s %-14s %s\n' "ID" "模块" "生效自" "当前 manifest" "状态"
printf '%s\n' "------------------------------------------------------------------------"
while IFS= read -r meta; do
  id="$(scaffold_meta_field "$meta" id)"
  module="$(scaffold_meta_field "$meta" module)"
  introduced="$(scaffold_meta_field "$meta" introduced)"
  [ -n "$id" ] && [ -n "$module" ] && [ -n "$introduced" ] \
    || die "登记表元数据缺 id/module/introduced: $meta"
  git -C "$RELEASE_DIR" cat-file -e "${introduced}^{commit}" 2>/dev/null \
    || die "$id 的引入提交在本仓不存在（写错或未推送）: $introduced"
  rows=$((rows + 1))

  current="$(awk -F'\t' -v m="$module" '$1 == m { print $5; exit }' "$RELEASE_DIR/manifest.tsv")"
  [ -n "$current" ] || current="-"
  effective=""
  releases=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ -n "$effective" ] || effective="$v"
    releases=$((releases + 1))
  done < <(publish_versions_since "$module" "$introduced")

  if [ -z "$effective" ]; then
    printf '%-5s %-14s %-14s %-14s %s\n' "$id" "$module" "待发布" "$current" \
      "尚未随产物发布：下一次 $module 发布即生效版本"
  else
    printf '%-5s %-14s %-14s %-14s %s\n' "$id" "$module" "$effective" "$current" \
      "此后已发布 $releases 次；线上最低 $module ≥ $effective 即可按删除清单删"
  fi
done < <(grep -o '<!-- scaffold [^>]*-->' "$REGISTRY" | sed 's/^<!-- scaffold //; s/ *-->$//')

echo
if [ "$rows" -eq 0 ]; then
  log "登记表为空：没有在册脚手架（有自愈逻辑却没登记 = 违反军规 10）"
else
  log "$rows 条在册。删之前先确认线上最老环境已升过生效版本，再照 $REGISTRY 的删除清单逐处删净"
fi
