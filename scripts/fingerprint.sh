#!/usr/bin/env bash
# 环境指纹：本机已装模块及版本快照，随问题卡片附带。
# 用法：fingerprint.sh [--oneline]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

release_rev="$(git -C "$RELEASE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
selected_arch="$(host_arch)"

if [ "${1:-}" = "--oneline" ]; then
  parts=""
  while IFS=$'\t' read -r m _k target _s version _a _h _ss _arch; do
    [ "$target" = "stack" ] || continue
    parts="$parts,$m=$(installed_version "$m")"
  done < <(manifest_selected_rows "" "$selected_arch")
  echo "dbdog[${parts#,}] release=$release_rev arch=$selected_arch $(date '+%Y-%m-%d')"
  exit 0
fi

echo "环境指纹  $(date '+%Y-%m-%d %H:%M')  release@$release_rev  arch@$selected_arch"
printf '%-14s %-12s %-12s\n' "模块" "已装" "manifest"
printf '%s\n' "----------------------------------------"
while IFS=$'\t' read -r m _k target _s version _a _h _ss _arch; do
  [ "$target" = "stack" ] || continue
  printf '%-14s %-12s %-12s\n' "$m" "$(installed_version "$m")" "$version"
done < <(manifest_selected_rows "" "$selected_arch")
