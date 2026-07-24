#!/usr/bin/env bash
# 内网：按 manifest 升级模块。下载 → 校验 → 解包 → 停服务 → 迁移钩子 → 切软链 → 起服务。
# 用法：
#   upgrade.sh                 # 升级所有「已安装且有新版」的 stack 模块
#   upgrade.sh <模块>...       # 升级/安装指定模块（未装的也会装，但不负责初始化配置）
# 回滚：ln -sfn $DBDOG_HOME/modules/<模块>/<旧版目录> $DBDOG_HOME/modules/<模块>/current 后重启。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DBDOGCTL="$(dirname "${BASH_SOURCE[0]}")/dbdogctl"

upgrade_one() {
  local m="$1"
  local version artifact sha256 target
  version="$(manifest_get "$m" 5)"
  artifact="$(manifest_get "$m" 6)"
  sha256="$(manifest_get "$m" 7)"
  target="$(manifest_get "$m" 3)"

  [ "$version" != "-" ] || { warn "$m 尚未发布，跳过"; return 0; }
  [ "$target" = "stack" ] || { warn "$m 不装在本机（target=${target}），跳过；DB 主机用 agent-install.sh"; return 0; }

  local inst; inst="$(installed_version "$m")"
  if [ "$inst" = "$version" ]; then log "$m 已是 ${version}，跳过"; return 0; fi

  local pkg; pkg="$(download_artifact "$artifact" "$sha256")"

  local mdir="$MODULES_DIR/$m" newdir="$MODULES_DIR/$m/$m-$version"
  mkdir -p "$mdir"
  if [ ! -d "$newdir" ]; then
    log "解包 $artifact"
    tar -xzf "$pkg" -C "$mdir"
    [ -d "$newdir" ] || die "包内目录不符合约定（应为 $m-$version/）: $artifact"
  fi

  # 停该模块的服务（记录原本在跑的，升级后拉回来）
  local svcs running=""
  svcs="$(module_services "$m")"
  for s in $svcs; do
    if "$DBDOGCTL" status "$s" | grep -q 运行中; then running="$running $s"; fi
  done
  [ -n "$running" ] && "$DBDOGCTL" stop $running

  run_hook "$newdir" pre-switch     # 数据库增量迁移在这里（goose up / drizzle）
  ln -sfn "$newdir" "$mdir/current"
  run_hook "$newdir" post-switch

  # 首次安装时把包内配置模板放进 etc/（已存在则不覆盖——配置永不被升级碰）
  if [ -d "$newdir/etc" ]; then
    for f in "$newdir/etc/"*.example; do
      [ -f "$f" ] || continue
      local dst="$ETC_DIR/$(basename "${f%.example}")"
      [ -f "$dst" ] || { cp "$f" "$dst"; warn "已生成配置 $dst —— 请检查并填写"; }
    done
  fi

  [ -n "$running" ] && "$DBDOGCTL" start $running
  log "$m: $inst → $version 完成"
}

ensure_layout
if [ $# -gt 0 ]; then
  targets=("$@")
else
  # 默认：已安装且版本落后的模块
  targets=()
  while IFS=$'\t' read -r m _kind target _svc version _a _s _ss; do
    [ "$target" = "stack" ] || continue
    inst="$(installed_version "$m")"
    [ "$inst" != "-" ] && [ "$version" != "-" ] && [ "$inst" != "$version" ] && targets+=("$m")
  done < <(manifest_rows)
  [ ${#targets[@]} -gt 0 ] || { log "没有可升级的模块（check-upgrade.sh 可查看详情）"; exit 0; }
fi

log "升级计划: ${targets[*]}"
for m in "${targets[@]}"; do upgrade_one "$m"; done
log "全部完成。dbdogctl status all 查看服务状态。"
