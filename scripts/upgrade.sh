#!/usr/bin/env bash
# 内网：按 manifest 升级模块。下载 → 校验 → 解包 → 停服务 → 迁移钩子 → 切软链 → 起服务。
# 用法：
#   upgrade.sh                 # 升级所有「已安装且版本/产物 SHA 与 manifest 不同」的 stack 模块
#   upgrade.sh <模块>...       # 升级/安装指定模块（未装的也会装，但不负责初始化配置）
#   upgrade.sh dbdog-agent     # DB 主机上的 Agent 首装/升级（含配置、数据库准备和验收）
# 回滚：把 current 恢复为升级前 readlink 记录的目标后重启；旧身份目录不会自动删除。

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"
DBDOGCTL="$SCRIPTS_DIR/dbdogctl"

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
  local entry marker count=0

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

  # 产物不能自称已安装；身份 marker 只能由 upgrade 在运行时校验通过后写入。
  for marker in "$MODULE_VERSION_MARKER" "$MODULE_ARTIFACT_SHA256_MARKER"; do
    [ ! -e "$expected/$marker" ] && [ ! -L "$expected/$marker" ] || \
      die "包内含保留的产物身份 marker: $marker"
  done
}

artifact_arch_from_name() {
  case "$1" in
    *-aarch64.tar.gz) echo "aarch64" ;;
    *-noarch.tar.gz) echo "noarch" ;;
    *) die "产物名没有受支持的架构后缀: $1" ;;
  esac
}

validate_artifact_identity() { # <版本目录> <manifest 版本> <artifact sha256>
  local dir="$1" version="$2" sha256="$3" actual_version actual_sha256
  actual_version="$(module_marker_value "$dir" "$MODULE_VERSION_MARKER" 2>/dev/null || true)"
  actual_sha256="$(module_marker_value "$dir" "$MODULE_ARTIFACT_SHA256_MARKER" 2>/dev/null || true)"
  [ "$actual_version" = "$version" ] || \
    die "版本目录的 manifest 版本 marker 缺失或不匹配: $dir"
  [ "$actual_sha256" = "$sha256" ] || \
    die "版本目录的 artifact SHA marker 缺失或不匹配: $dir"
}

write_artifact_identity() { # <已通过 runtime 校验的 staging 版本目录> <版本> <sha256>
  local dir="$1" version="$2" sha256="$3" version_tmp sha_tmp
  [ ! -e "$dir/$MODULE_VERSION_MARKER" ] && [ ! -L "$dir/$MODULE_VERSION_MARKER" ] || \
    die "拒绝覆盖已有版本 marker: $dir/$MODULE_VERSION_MARKER"
  [ ! -e "$dir/$MODULE_ARTIFACT_SHA256_MARKER" ] && \
    [ ! -L "$dir/$MODULE_ARTIFACT_SHA256_MARKER" ] || \
    die "拒绝覆盖已有 SHA marker: $dir/$MODULE_ARTIFACT_SHA256_MARKER"

  version_tmp="$(mktemp "$dir/.dbdog-version-marker.tmp.XXXXXX")"
  sha_tmp="$(mktemp "$dir/.dbdog-sha-marker.tmp.XXXXXX")"
  printf '%s\n' "$version" >"$version_tmp"
  printf '%s\n' "$sha256" >"$sha_tmp"
  chmod 0444 "$version_tmp" "$sha_tmp"
  mv -- "$version_tmp" "$dir/$MODULE_VERSION_MARKER"
  mv -- "$sha_tmp" "$dir/$MODULE_ARTIFACT_SHA256_MARKER"
  validate_artifact_identity "$dir" "$version" "$sha256"
}

current_matches_artifact_identity() { # <模块> <manifest 版本> <artifact sha256>
  local module="$1" version="$2" sha256="$3" dir actual_version actual_sha256
  dir="$(installed_module_dir "$module")" || return 1
  actual_version="$(module_marker_value "$dir" "$MODULE_VERSION_MARKER" 2>/dev/null)" || return 1
  actual_sha256="$(module_marker_value "$dir" "$MODULE_ARTIFACT_SHA256_MARKER" 2>/dev/null)" || return 1
  [ "$actual_version" = "$version" ] && [ "$actual_sha256" = "$sha256" ]
}

validate_module_runtime() { # <模块> <版本目录> <aarch64|noarch>
  local module="$1" dir="$2" expected_arch="$3" candidate info deps rc
  local machine_count=0
  command -v file >/dev/null 2>&1 || die "缺少运行时检查命令: file"
  command -v ldd >/dev/null 2>&1 || die "缺少运行时检查命令: ldd"
  case "$expected_arch" in
    aarch64 | noarch) ;;
    *) die "未知的模块目标架构: $expected_arch" ;;
  esac

  while IFS= read -r -d '' candidate; do
    info="$(LC_ALL=C file -b "$candidate")"
    case "$info" in
      *Mach-O* | *PE32*)
        die "模块混入非 Linux 机器码: $candidate ($info)"
        ;;
      *ELF*)
        machine_count=$((machine_count + 1))
        [ "$expected_arch" = "aarch64" ] || \
          die "noarch 模块含 ELF 机器码: $candidate ($info)"
        case "$info" in
          *ELF*64-bit*LSB*ARM\ aarch64*) ;;
          *) die "模块 ELF 不是 Linux AArch64: $candidate ($info)" ;;
        esac
        case "$info" in
          *"dynamically linked"* | *"shared object"*)
            deps="$(env -u LD_LIBRARY_PATH LC_ALL=C ldd "$candidate" 2>&1)" \
              || die "无法检查运行库: $candidate ($deps)"
            if grep -F 'not found' <<<"$deps" >/dev/null; then
              printf '%s\n' "$deps" >&2
              die "模块含目标机无法解析的运行库: $candidate"
            fi
            ;;
        esac
        ;;
      *ar\ archive*) : ;; # 静态库不在生产机执行；成员架构由发布端 verifier 负责。
    esac
  done < <(find "$dir" -type f -print0)

  if [ "$expected_arch" = "aarch64" ] && [ "$machine_count" -eq 0 ]; then
    die "aarch64 模块内没有发现任何 ELF 机器码: $dir"
  fi

  # 这些命令会触发动态装载和进程初始化，可在切 current 前发现 SIGILL/缺库。
  case "$module" in
    node) "$dir/bin/node" --version >/dev/null ;;
    goose) "$dir/bin/goose" -version >/dev/null ;;
    postgresql)
      "$dir/bin/postgres" --version >/dev/null
      "$dir/bin/initdb" --version >/dev/null
      "$dir/bin/psql" --version >/dev/null
      ;;
    clickhouse)
      if "$dir/bin/clickhouse" --version >/dev/null; then
        :
      else
        rc=$?
        if [ "$rc" -eq 132 ]; then
          die "ClickHouse 是 AArch64，但目标 CPU 不支持该官方构建所需指令（SIGILL/rc=132）；已在切换 current 前停止"
        fi
        die "ClickHouse 入口冒烟失败（rc=$rc）；已在切换 current 前停止"
      fi
      ;;
    # dbdog-server/ddsql-server 没有安全的 version 子命令，直接执行会连接后端并监听端口；
    # 它们只做上面的全文件架构与动态库门禁。
  esac
  log "$module: $expected_arch 架构、目标机运行库与安全入口冒烟通过"
}

upgrade_one() {
  local m="$1"
  local version artifact sha256 target artifact_arch
  version="$(manifest_get "$m" 5)"
  artifact="$(manifest_get "$m" 6)"
  sha256="$(manifest_get "$m" 7)"
  target="$(manifest_get "$m" 3)"

  [ "$version" != "-" ] || { warn "$m 尚未发布，跳过"; return 0; }
  [ "$target" = "stack" ] || die "$m 属于 ${target} 目标，不应进入 stack 模块升级器"
  require_path_component "模块名" "$m"
  require_path_component "版本" "$version"
  require_path_component "产物名" "$artifact"
  [ "${#sha256}" -eq 64 ] || die "$m 的 manifest sha256 长度不是 64"
  case "$sha256" in
    *[!0-9a-f]*) die "$m 的 manifest sha256 不是小写十六进制" ;;
  esac
  artifact_arch="$(artifact_arch_from_name "$artifact")"

  local inst inst_sha256
  inst="$(installed_version "$m")"
  inst_sha256="$(installed_artifact_sha256 "$m")"
  if current_matches_artifact_identity "$m" "$version" "$sha256"; then
    log "$m 已是 ${version}（artifact ${sha256:0:12}），跳过"
    return 0
  fi
  if [ "$inst" = "$version" ]; then
    warn "$m 版本号仍为 ${version}，但产物身份为 ${inst_sha256}；按 manifest SHA 重新安装"
  fi

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

  local mdir="$MODULES_DIR/$m"
  local newdir="$MODULES_DIR/$m/$m-$version.sha256-$sha256"
  local expected_name="$m-$version" candidate
  mkdir -p "$mdir"
  if [ -e "$newdir" ] || [ -L "$newdir" ]; then
    [ -d "$newdir" ] && [ ! -L "$newdir" ] || \
      die "目标产物身份路径已存在但不是实际目录: $newdir"
    validate_artifact_identity "$newdir" "$version" "$sha256"
    validate_module_runtime "$m" "$newdir" "$artifact_arch"
  else
    ACTIVE_UPGRADE_STAGE_PARENT="$mdir"
    ACTIVE_UPGRADE_STAGE="$(mktemp -d "$mdir/.upgrade-staging.XXXXXX")"
    log "解包 $artifact"
    if ! tar -xzf "$pkg" -C "$ACTIVE_UPGRADE_STAGE"; then
      die "解包失败: $artifact"
    fi
    validate_staged_module "$ACTIVE_UPGRADE_STAGE" "$expected_name"
    candidate="$ACTIVE_UPGRADE_STAGE/$expected_name"
    validate_module_runtime "$m" "$candidate" "$artifact_arch"
    write_artifact_identity "$candidate" "$version" "$sha256"

    # staging 与最终目录同在 mdir 下；GNU mv -T 保证同文件系统原子 rename，
    # 即使并发出现同名目录也不会把 candidate 嵌套进去或覆盖旧身份。
    [ ! -e "$newdir" ] && [ ! -L "$newdir" ] || \
      die "目标产物身份目录在解包期间出现，拒绝覆盖: $newdir"
    if ! mv -T -- "$candidate" "$newdir"; then
      die "发布产物身份目录失败（拒绝覆盖已有路径）: $newdir"
    fi
    rmdir -- "$ACTIVE_UPGRADE_STAGE"
    ACTIVE_UPGRADE_STAGE=""
    ACTIVE_UPGRADE_STAGE_PARENT=""
    validate_artifact_identity "$newdir" "$version" "$sha256"
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

  # 已安装模块升级时，迁移配置缺失必须硬失败；首次落包允许先生成配置，随后由
  # install.sh 的收尾阶段以 required=1 统一补跑。迁移失败发生在切 current 之前。
  DBDOG_MIGRATION_REQUIRED="$UPGRADE_RECOVERY_OLD_PRESENT" \
    run_hook "$newdir" pre-switch   # 数据库增量迁移在这里（goose up / drizzle）
  validate_artifact_identity "$newdir" "$version" "$sha256"
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
  validate_artifact_identity "$newdir" "$version" "$sha256"

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
  log "$m: $inst → ${version}（artifact ${sha256:0:12}）完成"
}

# Agent 位于 DB 主机且拥有独立的 root/config/systemd 事务。统一入口在参数校验后
# 直接 exec 同一份首装/升级实现，避免先创建 stack 布局，也避免维护第二套 cutover。
for requested in "$@"; do
  if [ "$requested" = dbdog-agent ]; then
    [ "$#" -eq 1 ] || die "dbdog-agent 位于 DB 主机，不能与 stack 模块混合升级"
    exec "$SCRIPTS_DIR/agent-install.sh"
  fi
done

ensure_layout
if [ $# -gt 0 ]; then
  targets=("$@")
else
  # 默认：已安装且版本或产物 SHA 与 manifest 不同（含旧目录无 SHA marker）的模块
  targets=()
  while IFS=$'\t' read -r m _kind target _svc version _artifact sha256 _source_sha; do
    [ "$target" = "stack" ] || continue
    [ "$version" != "-" ] || continue
    [ -e "$MODULES_DIR/$m/current" ] || [ -L "$MODULES_DIR/$m/current" ] || continue
    current_matches_artifact_identity "$m" "$version" "$sha256" || targets+=("$m")
  done < <(manifest_rows)
  [ ${#targets[@]} -gt 0 ] || { log "没有可升级的模块（check-upgrade.sh 可查看详情）"; exit 0; }
fi

canonicalize_upgrade_modules "${targets[@]}"
targets=("${ORDERED_UPGRADE_MODULES[@]}")
# 0.1.3 及更早的 Web 发布模板曾带一组三联公网验收端口。只在三个 URL 同时精确
# 命中该模板形状时自动迁移；正常的内网域名、反代地址和任意自定义配置都不覆盖。
for m in "${targets[@]}"; do
  if [ "$m" = "dbdog-web" ]; then
    migrate_legacy_web_public_urls "$ETC_DIR/dbdog-web.env"
    break
  fi
done
log "升级计划: ${targets[*]}"
for m in "${targets[@]}"; do upgrade_one "$m"; done
log "全部完成。运行 $DBDOGCTL status all 查看服务状态。"
