#!/usr/bin/env bash
# 内网：检查已安装模块是否与 manifest 的版本及产物 SHA 一致。
# 用法：check-upgrade.sh [--pull]   （--pull 先拉取 release 仓 main）
# 退出码：0 = 已安装模块身份均一致；10 = 存在版本/SHA 不同或身份未知。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in
  "" | --pull) ;;
  *) die "用法: check-upgrade.sh [--pull]" ;;
esac
[ "$#" -le 1 ] || die "用法: check-upgrade.sh [--pull]"

if [ "${1:-}" = "--pull" ]; then
  log "拉取 dbdog-release main ..."
  if ! git -C "$RELEASE_DIR" pull --ff-only; then
    die "git pull/fetch 失败；停止检查，未使用可能过期的本地 manifest 判断是否为最新"
  fi
fi

updates=0
printf '%-14s %-12s %-12s %s\n' "模块" "已装" "manifest" "状态"
printf '%s\n' "--------------------------------------------------------"
while IFS=$'\t' read -r m _kind target _service version _artifact sha256 _source_sha; do
  [ "$target" = "stack" ] || continue   # agent 在 DB 主机上单独检查（agent-install.sh）
  inst="$(installed_version "$m")"
  inst_sha256="$(installed_artifact_sha256 "$m")"
  if [ "$version" = "-" ]; then
    st="未发布"
  elif [ "$inst" = "-" ]; then
    st="未安装（install.sh 或 upgrade.sh ${m}）"
  elif [ "$inst" = "?" ]; then
    st="版本 marker 损坏 ←"
    updates=$((updates + 1))
  elif [ "$inst" != "$version" ]; then
    st="版本不同 ←"
    updates=$((updates + 1))
  elif [ "$inst_sha256" = "-" ]; then
    st="版本一致；产物身份未知 ←"
    updates=$((updates + 1))
  elif [ "$inst_sha256" = "?" ]; then
    st="产物身份 marker 损坏 ←"
    updates=$((updates + 1))
  elif [ "$inst_sha256" != "$sha256" ]; then
    st="版本一致；产物 SHA 不同 ←"
    updates=$((updates + 1))
  else
    st="一致"
  fi
  printf '%-14s %-12s %-12s %s\n' "$m" "$inst" "$version" "$st"
done < <(manifest_rows)

echo
if [ "$updates" -gt 0 ]; then
  log "$updates 个已安装模块需升级或校准产物身份。执行: scripts/upgrade.sh"
  exit 10
fi
if [ "${1:-}" = "--pull" ]; then
  log "远端 manifest 拉取成功，已安装模块均一致（未安装项见上表）。"
else
  log "按当前本地 manifest，已安装模块均一致（未安装项见上表；确认远端请加 --pull）。"
fi
