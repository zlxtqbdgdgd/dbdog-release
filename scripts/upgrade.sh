#!/usr/bin/env bash
# 内网：按 manifest 升级模块。下载 → 校验 → 解包 → 停服务 → 迁移钩子 → 切软链 → 起服务。
# 用法：
#   upgrade.sh                 # 升级所有「已安装且版本与 manifest 不同」的 stack 模块
#   upgrade.sh <模块>...       # 升级/安装指定模块（未装的也会装，但不负责初始化配置）
# 回滚：ln -sfn $DBDOG_HOME/modules/<模块>/<旧版目录> $DBDOG_HOME/modules/<模块>/current 后重启。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DBDOGCTL="$(dirname "${BASH_SOURCE[0]}")/dbdogctl"

ACTIVE_UPGRADE_STAGE=""
ACTIVE_UPGRADE_STAGE_PARENT=""
ACTIVE_DOWNLOAD_PART=""
ACTIVE_DOWNLOAD_CACHE=""
ACTIVE_DOWNLOAD_SHA=""
UPGRADE_RECOVERY_ACTIVE=0
UPGRADE_RECOVERY_CURRENT=""
UPGRADE_RECOVERY_OLD_PRESENT=0
UPGRADE_RECOVERY_OLD_TARGET=""
UPGRADE_RECOVERY_RUNNING=""

cleanup_upgrade_temporary_files() {
  if [ -n "$ACTIVE_UPGRADE_STAGE" ]; then
    case "$ACTIVE_UPGRADE_STAGE" in
      "$ACTIVE_UPGRADE_STAGE_PARENT"/.upgrade-staging.*)
        rm -rf -- "$ACTIVE_UPGRADE_STAGE"
        ;;
      *)
        warn "拒绝清理意外的升级 staging 路径: $ACTIVE_UPGRADE_STAGE"
        ;;
    esac
  fi

  if [ -n "$ACTIVE_DOWNLOAD_PART" ]; then
    case "$ACTIVE_DOWNLOAD_PART" in
      "$CACHE_DIR"/*.part) rm -f -- "$ACTIVE_DOWNLOAD_PART" ;;
      *) warn "拒绝清理意外的下载临时路径: $ACTIVE_DOWNLOAD_PART" ;;
    esac
  fi

  # download_artifact 会先校验 .part 再移入 cache。这里额外清理调用前就存在的
  # 无效 cache；命中或下载成功的有效 cache 始终保留，供下次复用。
  if [ -n "$ACTIVE_DOWNLOAD_CACHE" ] && [ -f "$ACTIVE_DOWNLOAD_CACHE" ]; then
    if ! sha256_verify "$ACTIVE_DOWNLOAD_CACHE" "$ACTIVE_DOWNLOAD_SHA"; then
      case "$ACTIVE_DOWNLOAD_CACHE" in
        "$CACHE_DIR"/*) rm -f -- "$ACTIVE_DOWNLOAD_CACHE" ;;
        *) warn "拒绝清理意外的无效 cache 路径: $ACTIVE_DOWNLOAD_CACHE" ;;
      esac
    fi
  fi
}

recover_failed_upgrade() {
  local restored=1 current_target="" s
  [ "$UPGRADE_RECOVERY_ACTIVE" -eq 1 ] || return 0

  warn "升级未完成，开始恢复升级前的 current 与服务状态"
  # start 阶段可能只拉起了部分新进程；先统一停掉，避免恢复软链后仍跑着新二进制。
  if [ -n "$UPGRADE_RECOVERY_RUNNING" ]; then
    # shellcheck disable=SC2086
    "$DBDOGCTL" stop $UPGRADE_RECOVERY_RUNNING \
      || warn "恢复前停止残留服务失败，请人工核对进程"
  fi
  if [ "$UPGRADE_RECOVERY_OLD_PRESENT" -eq 1 ]; then
    if [ -L "$UPGRADE_RECOVERY_CURRENT" ]; then
      current_target="$(readlink "$UPGRADE_RECOVERY_CURRENT")"
    fi
    if [ "$current_target" != "$UPGRADE_RECOVERY_OLD_TARGET" ]; then
      if [ -e "$UPGRADE_RECOVERY_CURRENT" ] && [ ! -L "$UPGRADE_RECOVERY_CURRENT" ]; then
        warn "current 变成了非软链路径，拒绝自动覆盖: $UPGRADE_RECOVERY_CURRENT"
        restored=0
      elif ! ln -sfn "$UPGRADE_RECOVERY_OLD_TARGET" "$UPGRADE_RECOVERY_CURRENT"; then
        warn "恢复旧 current 失败: $UPGRADE_RECOVERY_CURRENT"
        restored=0
      fi
    fi
  else
    if [ -L "$UPGRADE_RECOVERY_CURRENT" ]; then
      if ! rm -f -- "$UPGRADE_RECOVERY_CURRENT"; then
        warn "移除失败安装创建的 current 失败: $UPGRADE_RECOVERY_CURRENT"
        restored=0
      fi
    elif [ -e "$UPGRADE_RECOVERY_CURRENT" ]; then
      warn "current 变成了非软链路径，拒绝自动删除: $UPGRADE_RECOVERY_CURRENT"
      restored=0
    fi
  fi

  if [ "$restored" -eq 1 ]; then
    for s in $UPGRADE_RECOVERY_RUNNING; do
      "$DBDOGCTL" start "$s" || warn "恢复启动失败，请人工启动: $s"
    done
  else
    warn "旧 current 未恢复，未自动启动原服务，避免运行错误版本"
  fi
  UPGRADE_RECOVERY_ACTIVE=0
}

on_upgrade_exit() {
  local rc=$?
  trap - EXIT
  set +e
  cleanup_upgrade_temporary_files
  recover_failed_upgrade
  exit "$rc"
}

trap on_upgrade_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_path_component() {
  local label="$1" value="$2"
  case "$value" in
    "" | "." | ".." | */* | *$'\n'* | *$'\r'*)
      die "$label 不是安全的单层路径名: $value"
      ;;
  esac
}

validate_staged_module() {
  local stage="$1" expected_name="$2" expected="$1/$2"
  local entry count=0

  [ -d "$expected" ] && [ ! -L "$expected" ] || \
    die "包内目录不符合约定（应为 $expected_name/）"

  # 最终目录只能来自唯一的约定顶层目录，不能把额外文件悄悄发布出去。
  for entry in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    count=$((count + 1))
    [ "$entry" = "$expected" ] || \
      die "包内含约定目录之外的顶层路径: $(basename "$entry")"
  done
  [ "$count" -eq 1 ] || die "包内顶层目录数量异常（应仅有 $expected_name/）"
}

upgrade_one() {
  local m="$1"
  local version artifact sha256 target
  version="$(manifest_get "$m" 5)"
  artifact="$(manifest_get "$m" 6)"
  sha256="$(manifest_get "$m" 7)"
  target="$(manifest_get "$m" 3)"

  [ "$version" != "-" ] || { warn "$m 尚未发布，跳过"; return 0; }
  [ "$target" = "stack" ] || { warn "$m 不装在本机（target=${target}），跳过；DB 主机用 agent-install.sh"; return 0; }
  require_path_component "模块名" "$m"
  require_path_component "版本" "$version"
  require_path_component "产物名" "$artifact"
  [ "${#sha256}" -eq 64 ] || die "$m 的 manifest sha256 长度不是 64"
  case "$sha256" in
    *[!0-9a-f]*) die "$m 的 manifest sha256 不是小写十六进制" ;;
  esac

  local inst; inst="$(installed_version "$m")"
  if [ "$inst" = "$version" ]; then log "$m 已是 ${version}，跳过"; return 0; fi

  local pkg="$CACHE_DIR/$artifact"
  ACTIVE_DOWNLOAD_PART="$pkg.part"
  ACTIVE_DOWNLOAD_CACHE="$pkg"
  ACTIVE_DOWNLOAD_SHA="$sha256"
  rm -f -- "$ACTIVE_DOWNLOAD_PART"
  download_artifact "$artifact" "$sha256" >/dev/null
  rm -f -- "$ACTIVE_DOWNLOAD_PART"
  ACTIVE_DOWNLOAD_PART=""
  ACTIVE_DOWNLOAD_CACHE=""
  ACTIVE_DOWNLOAD_SHA=""

  local mdir="$MODULES_DIR/$m" newdir="$MODULES_DIR/$m/$m-$version"
  mkdir -p "$mdir"
  if [ -e "$newdir" ] || [ -L "$newdir" ]; then
    [ -d "$newdir" ] && [ ! -L "$newdir" ] || \
      die "目标版本路径已存在但不是实际目录: $newdir"
  else
    local expected_name="$m-$version"
    ACTIVE_UPGRADE_STAGE_PARENT="$mdir"
    ACTIVE_UPGRADE_STAGE="$(mktemp -d "$mdir/.upgrade-staging.XXXXXX")"
    log "解包 $artifact"
    if ! tar -xzf "$pkg" -C "$ACTIVE_UPGRADE_STAGE"; then
      die "解包失败: $artifact"
    fi
    validate_staged_module "$ACTIVE_UPGRADE_STAGE" "$expected_name"

    # staging 与最终目录同在 mdir 下；该 mv 是同文件系统内的原子 rename。
    # 发布前再次拒绝已有路径，避免把 staging 嵌套进疑似完整的版本目录。
    [ ! -e "$newdir" ] && [ ! -L "$newdir" ] || \
      die "目标版本目录在解包期间出现，拒绝覆盖: $newdir"
    mv -- "$ACTIVE_UPGRADE_STAGE/$expected_name" "$newdir"
    rmdir -- "$ACTIVE_UPGRADE_STAGE"
    ACTIVE_UPGRADE_STAGE=""
    ACTIVE_UPGRADE_STAGE_PARENT=""
  fi

  # 停该模块的服务（记录原本在跑的，升级后拉回来）
  local svcs running=""
  svcs="$(module_services "$m")"
  for s in $svcs; do
    if "$DBDOGCTL" status "$s" | grep -q 运行中; then running="$running $s"; fi
  done

  local current="$mdir/current"
  UPGRADE_RECOVERY_CURRENT="$current"
  UPGRADE_RECOVERY_OLD_PRESENT=0
  UPGRADE_RECOVERY_OLD_TARGET=""
  UPGRADE_RECOVERY_RUNNING="$running"
  if [ -L "$current" ]; then
    UPGRADE_RECOVERY_OLD_PRESENT=1
    UPGRADE_RECOVERY_OLD_TARGET="$(readlink "$current")"
  elif [ -e "$current" ]; then
    die "current 已存在但不是软链，拒绝升级: $current"
  fi
  # 从停服务开始进入事务；其后任一步失败，EXIT trap 都恢复旧 current，
  # 并只拉回升级前确实在运行的服务。
  UPGRADE_RECOVERY_ACTIVE=1
  # running 是由仓内固定服务名组成的参数列表，需要有意拆词传给 dbdogctl。
  # shellcheck disable=SC2086
  [ -n "$running" ] && "$DBDOGCTL" stop $running

  run_hook "$newdir" pre-switch     # 数据库增量迁移在这里（goose up / drizzle）
  if [ "$UPGRADE_RECOVERY_OLD_PRESENT" -eq 1 ]; then
    [ -L "$current" ] && \
      [ "$(readlink "$current")" = "$UPGRADE_RECOVERY_OLD_TARGET" ] || \
      die "pre-switch 期间 current 被外部改变，拒绝覆盖: $current"
  else
    [ ! -e "$current" ] && [ ! -L "$current" ] || \
      die "pre-switch 期间 current 被外部创建，拒绝覆盖: $current"
  fi
  ln -sfn "$newdir" "$current"
  run_hook "$newdir" post-switch

  # 首次安装时把包内配置模板放进 etc/（已存在则不覆盖——配置永不被升级碰）
  if [ -d "$newdir/etc" ]; then
    for f in "$newdir/etc/"*.example; do
      [ -f "$f" ] || continue
      local dst
      dst="$ETC_DIR/$(basename "${f%.example}")"
      if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
        install -m 0600 "$f" "$dst"
        warn "已生成配置 ${dst}（mode 0600）—— 请检查并填写"
      fi
    done
  fi

  # shellcheck disable=SC2086
  [ -n "$running" ] && "$DBDOGCTL" start $running
  UPGRADE_RECOVERY_ACTIVE=0
  UPGRADE_RECOVERY_CURRENT=""
  UPGRADE_RECOVERY_OLD_PRESENT=0
  UPGRADE_RECOVERY_OLD_TARGET=""
  UPGRADE_RECOVERY_RUNNING=""
  log "$m: $inst → $version 完成"
}

ensure_layout
if [ $# -gt 0 ]; then
  targets=("$@")
else
  # 默认：已安装且版本与 manifest 不同的模块
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
log "全部完成。运行 $DBDOGCTL status all 查看服务状态。"
