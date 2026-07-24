#!/usr/bin/env bash
# 内网：检查哪些模块有新版本。只读，不做任何变更。
# 用法：check-upgrade.sh [--pull]   （--pull 先拉取 release 仓 main）
# 退出码：0 = 全部最新；10 = 有可升级模块。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = "--pull" ]; then
  log "拉取 dbdog-release main ..."
  git -C "$RELEASE_DIR" pull --ff-only || warn "git pull 失败，用本地 manifest 继续"
fi

updates=0
printf '%-14s %-12s %-12s %s\n' "模块" "已装" "最新" "状态"
printf '%s\n' "--------------------------------------------------------"
while IFS=$'\t' read -r m kind target service version artifact sha256 source_sha; do
  [ "$target" = "stack" ] || continue   # agent 在 DB 主机上单独检查（agent-install.sh）
  inst="$(installed_version "$m")"
  if [ "$version" = "-" ]; then
    st="未发布"
  elif [ "$inst" = "-" ]; then
    st="未安装（install.sh 或 upgrade.sh ${m}）"
  elif [ "$inst" = "$version" ]; then
    st="最新"
  else
    st="可升级 ←"
    updates=$((updates + 1))
  fi
  printf '%-14s %-12s %-12s %s\n' "$m" "$inst" "$version" "$st"
done < <(manifest_rows)

echo
if [ "$updates" -gt 0 ]; then
  log "$updates 个模块可升级。执行: scripts/upgrade.sh"
  exit 10
fi
log "全部为最新。"
