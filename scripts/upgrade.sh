#!/usr/bin/env bash
# 内网：按 manifest 升级模块。下载 → 校验 → 解包 → 停服务 → 迁移钩子 → 切软链 → 起服务。
# 用法：
#   upgrade.sh                 # 升级所有「已安装且版本/产物 SHA 与 manifest 不同」的 stack 模块
#   upgrade.sh <模块>...       # 升级/安装指定模块（未装的也会装，但不负责初始化配置）
#   upgrade.sh dbdog-agent     # DB 主机上的 Agent 首装/升级（含配置、数据库准备和验收）
#   upgrade.sh dbdog-agent --host-only  # 通用主机模式（仅主机基线，不接数据库引擎）
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
    *-x86_64.tar.gz) echo "x86_64" ;;
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

validate_module_runtime() { # <模块> <版本目录> <aarch64|x86_64|noarch>
  local module="$1" dir="$2" expected_arch="$3" candidate info deps rc
  local machine_count=0
  command -v file >/dev/null 2>&1 || die "缺少运行时检查命令: file"
  command -v ldd >/dev/null 2>&1 || die "缺少运行时检查命令: ldd"
  case "$expected_arch" in
    aarch64 | x86_64 | noarch) ;;
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
        case "$expected_arch" in
          aarch64 | x86_64) ;;
          *) die "noarch 模块含 ELF 机器码: $candidate ($info)" ;;
        esac
        case "$expected_arch" in
          aarch64)
            case "$info" in
              *ELF*64-bit*LSB*ARM\ aarch64*) ;;
              *) die "模块 ELF 不是 Linux AArch64: $candidate ($info)" ;;
            esac
            ;;
          x86_64)
            case "$info" in
              *ELF*64-bit*LSB*x86-64*) ;;
              *) die "模块 ELF 不是 Linux x86-64: $candidate ($info)" ;;
            esac
            ;;
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

  case "$expected_arch" in
    aarch64 | x86_64)
      [ "$machine_count" -gt 0 ] || \
        die "$expected_arch 模块内没有发现任何 ELF 机器码: $dir"
      ;;
  esac

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
  if [ -n "$LOCAL_ARTIFACT" ]; then
    # 快升级：包自证身份（名字给模块与版本，内容给 SHA）。模块必须仍是 manifest 里
    # 登记的 stack 模块——快升级放宽的只有「装哪个版本」，不放宽「这机器上能装什么」。
    artifact="$(basename "$LOCAL_ARTIFACT")"
    case "$artifact" in
      "$m"-*.tar.gz) ;;
      *) die "--artifact 产物名不属于模块 $m: $artifact" ;;
    esac
    version="${artifact#"$m"-}"
    version="${version%.tar.gz}"
    version="${version%-*}"
    [ -n "$version" ] || die "无法从产物名解析版本: $artifact"
    sha256="$(sha256sum "$LOCAL_ARTIFACT" | awk '{print $1}')"
    mkdir -p "$CACHE_DIR"
    install -m 0644 "$LOCAL_ARTIFACT" "$CACHE_DIR/$artifact"
    log "$m: 快升级产物 ${artifact}（sha ${sha256:0:12}）已预置 cache"
  else
    version="$(manifest_get "$m" 5)"
    artifact="$(manifest_get "$m" 6)"
    sha256="$(manifest_get "$m" 7)"
  fi
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

# 升级的目的是让点名的模块跑上新版本，所以升级计划内的服务在收尾时必须是运行态。
# upgrade_one 只把「切包前确实在跑」的服务原样拉回：崩溃后残留的、以及产物身份已经
# 匹配而走了跳过分支的模块，都会被静默留在停止态，而随后的验收是无条件执行的，于是
# 出现「包已切好」和「端点不可用」同时成立（bugs/upgrade-mcp-0.1.9-oauth-verify-failure.md）。
# 这里在验收之前统一收口，并把失败落到「哪个服务没起来」而不是「去翻日志」。
start_target_services() {
  local m s svcs pending=""
  for m in "$@"; do
    svcs="$(module_services "$m")"
    for s in $svcs; do
      if "$DBDOGCTL" status "$s" | grep -q 运行中; then continue; fi
      case " $pending " in *" $s "*) continue ;; esac
      pending="$pending $s"
    done
  done
  [ -n "$pending" ] || return 0
  log "升级计划内未在运行的服务，按计划拉起:$pending"
  # pending 由仓内固定服务名组成，需要有意拆词传给 dbdogctl。
  # shellcheck disable=SC2086
  "$DBDOGCTL" start $pending \
    || die "升级后这些服务未能启动:${pending}；查看 $LOGS_DIR/ 下对应服务日志"
}

# 快升级（「部署」）：与慢升级共用**同一套部署代码路径**，只换包来源——版本与 SHA 取自
# 给定产物本身（recipe 产出名 <模块>-<版本>-<arch|noarch>.tar.gz）而非 manifest；产物预置进
# cache 后 download_artifact 直接缓存命中，其后的 staging/身份/钩子/服务/OAuth 验收与
# manifest 路径逐行相同。不能搞两套部署——这是快慢升级同构的唯一实现点。
LOCAL_ARTIFACT=""
if [ "${1:-}" = "--artifact" ]; then
  [ "$#" -ge 3 ] || die "用法: upgrade.sh --artifact <产物tar.gz> <模块>"
  LOCAL_ARTIFACT="$2"
  shift 2
  [ "$#" -eq 1 ] || die "--artifact 一次只装一个模块"
  [ -f "$LOCAL_ARTIFACT" ] || die "产物不存在: $LOCAL_ARTIFACT"
  [ "$1" != dbdog-agent ] || die "dbdog-agent 的快升级是组件级路径（fast-upgrade.sh），不走 --artifact"
fi

# Agent 位于 DB 主机且拥有独立的 root/config/systemd 事务。统一入口在参数校验后
# 直接 exec 同一份首装/升级实现，避免先创建 stack 布局，也避免维护第二套 cutover。
for requested in "$@"; do
  if [ "$requested" = dbdog-agent ]; then
    [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = "--host-only" ]; } || \
      die "dbdog-agent 位于 DB 主机，不能与 stack 模块混合升级；仅支持附加 --host-only"
    exec "$SCRIPTS_DIR/agent-install.sh" ${2:+--host-only}
  fi
done

ensure_layout
stack_config_requested=0
oauth_url_migration_requested=0
if [ "$#" -eq 0 ]; then
  # 无参升级也负责收口已知的旧模板配置；即使模块产物未变，配置漂移仍是一项升级。
  stack_config_requested=1
  oauth_url_migration_requested=1
else
  for requested in "$@"; do
    case "$requested" in
      dbdog-server) stack_config_requested=1 ;;
      dbdog-web | dbdog-mcp)
        stack_config_requested=1
        oauth_url_migration_requested=1
        ;;
    esac
  done
fi
if [ "$oauth_url_migration_requested" -eq 1 ]; then
  migrate_legacy_web_public_urls "$ETC_DIR/dbdog-web.env"
  migrate_legacy_mcp_public_urls "$ETC_DIR/dbdog-mcp.env"
fi
if [ "$stack_config_requested" -eq 1 ]; then
  # 已有完整应用栈时，升级与首次安装共用同一套默认配置校准：缺失/空值/占位
  # 自动补齐，真实自定义地址和凭证保持不变。
  if [ -f "$ETC_DIR/dbdog-server.env" ] \
    && [ -f "$ETC_DIR/dbdog-web.env" ] \
    && [ -f "$ETC_DIR/dbdog-mcp.env" ]; then
    configure_ready_to_use_stack
  fi
fi
if [ $# -gt 0 ]; then
  targets=("$@")
else
  # 默认：已安装且版本或产物 SHA 与 manifest 不同（含旧目录无 SHA marker）的模块
  targets=()
  selected_arch="$(host_arch)"
  while IFS=$'\t' read -r m _kind target _svc version _artifact sha256 _source_sha _arch; do
    [ "$target" = "stack" ] || continue
    [ "$version" != "-" ] || continue
    [ -e "$MODULES_DIR/$m/current" ] || [ -L "$MODULES_DIR/$m/current" ] || continue
    current_matches_artifact_identity "$m" "$version" "$sha256" || targets+=("$m")
  done < <(manifest_selected_rows "" "$selected_arch")
  # 配置校准本身也是升级工作。把已安装的同版本模块放入计划后，upgrade_one 可以
  # 安全跳过产物切换，下面仍会重启受影响服务并执行 OAuth 验收。
  if [ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] \
    && { [ -e "$MODULES_DIR/dbdog-server/current" ] \
      || [ -L "$MODULES_DIR/dbdog-server/current" ]; }; then
    found=0
    for m in "${targets[@]}"; do [ "$m" = dbdog-server ] && found=1; done
    [ "$found" -eq 1 ] || targets+=(dbdog-server)
  fi
  if [ "$DBDOG_WEB_CONFIG_CHANGED" -eq 1 ] \
    && { [ -e "$MODULES_DIR/dbdog-web/current" ] \
      || [ -L "$MODULES_DIR/dbdog-web/current" ]; }; then
    found=0
    for m in "${targets[@]}"; do [ "$m" = dbdog-web ] && found=1; done
    [ "$found" -eq 1 ] || targets+=(dbdog-web)
  fi
  if [ "$DBDOG_MCP_CONFIG_CHANGED" -eq 1 ] \
    && { [ -e "$MODULES_DIR/dbdog-mcp/current" ] \
      || [ -L "$MODULES_DIR/dbdog-mcp/current" ]; }; then
    found=0
    for m in "${targets[@]}"; do [ "$m" = dbdog-mcp ] && found=1; done
    [ "$found" -eq 1 ] || targets+=(dbdog-mcp)
  fi
  [ ${#targets[@]} -gt 0 ] || { log "没有可升级的模块（check-upgrade.sh 可查看详情）"; exit 0; }
fi

canonicalize_upgrade_modules "${targets[@]}"
targets=("${ORDERED_UPGRADE_MODULES[@]}")
# Web/MCP 升级在切包后执行 OAuth 专项验收；前面的配置校准只补默认值或迁移精确
# 命中的旧模板，正常的内网域名、反代地址和任意自定义配置都不覆盖。
oauth_upgrade=0
# Web/MCP 显式升级也会执行全栈配置校准；若它顺带启用了 server RC，必须在
# 自动重启 server 后做同一项专项验收，不能只看命令行 targets。
remote_config_upgrade="$DBDOG_SERVER_CONFIG_CHANGED"
for m in "${targets[@]}"; do
  case "$m" in
    dbdog-server) remote_config_upgrade=1 ;;
    dbdog-web | dbdog-mcp) oauth_upgrade=1 ;;
  esac
done
server_was_running=0
ddsql_was_running=0
web_was_running=0
mcp_was_running=0
if [ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-server | grep -q '运行中'; then
  server_was_running=1
fi
if [ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status ddsql-server | grep -q '运行中'; then
  ddsql_was_running=1
fi
if [ "$DBDOG_WEB_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-web | grep -q '运行中'; then
  web_was_running=1
fi
if [ "$DBDOG_MCP_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-mcp | grep -q '运行中'; then
  mcp_was_running=1
fi
log "升级计划: ${targets[*]}"
for m in "${targets[@]}"; do upgrade_one "$m"; done
if [ "$server_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-server
fi
if [ "$ddsql_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart ddsql-server
fi
if [ "$web_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-web
fi
if [ "$mcp_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-mcp
fi
start_target_services "${targets[@]}"
if [ "$oauth_upgrade" -eq 1 ]; then
  "$SCRIPTS_DIR/verify.sh" --oauth
fi
if [ "$remote_config_upgrade" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-server | grep -q '运行中'; then
  "$SCRIPTS_DIR/verify.sh" --remote-config
fi
# Agent 的「采集配置快照」是初始化健康事件带上来的，而那条事件每个 agent 进程只发一次
# （6 小时去抖，且发送方拿不到投递结果）。server 升级期间它必然送不达：旧版本收下不落库、
# 重启窗口里直接连不上。于是配额已消耗、6 小时内不再重发，控制台的「采集配置」就一直空着
# ——2026-08-06 黄区实测即如此，当时误判成功能故障查了很久。重启 agent 会重置该状态，
# 几秒内即可重报。
for m in "${targets[@]}"; do
  [ "$m" = dbdog-server ] || continue
  warn "dbdog-server 已升级：请到各被采集 DB 主机上重启 agent（systemctl restart dbdog-agent）"
  warn "  不重启的话，控制台「采集配置」最多要等 6 小时才会重新出现——那是去抖，不是故障"
  break
done
log "全部完成。运行 $DBDOGCTL status all 查看服务状态。"
