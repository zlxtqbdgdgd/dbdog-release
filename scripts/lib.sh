#!/usr/bin/env bash
# dbdog-release 公共函数库（被 source，不直接执行）。
# 内网可用性是第一原则：只依赖 bash + coreutils + curl + tar + awk + git。

set -euo pipefail

# ---- 路径与常量 ----
DBDOG_HOME="${DBDOG_HOME:-$HOME/dbdog}"
RELEASE_DIR="${RELEASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="${MANIFEST:-$RELEASE_DIR/manifest.tsv}"
BUCKET_URL="${BUCKET_URL:-https://github.com/zlxtqbdgdgd/dbdog-release/releases/download/artifacts}"
ARCH="aarch64"

MODULES_DIR="$DBDOG_HOME/modules"
ETC_DIR="$DBDOG_HOME/etc"
DATA_DIR="$DBDOG_HOME/data"
LOGS_DIR="$DBDOG_HOME/logs"
RUN_DIR="$DBDOG_HOME/run"
CACHE_DIR="$DBDOG_HOME/cache"
MODULE_VERSION_MARKER=".dbdog-manifest-version"
MODULE_ARTIFACT_SHA256_MARKER=".dbdog-artifact-sha256"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_layout() {
  mkdir -p "$MODULES_DIR" "$ETC_DIR" "$DATA_DIR" "$LOGS_DIR" "$RUN_DIR" "$CACHE_DIR"
  chmod 700 "$ETC_DIR"
  find "$ETC_DIR" -type f -name '*.env' -exec chmod 600 {} +
}

# ---- manifest 访问 ----
# 列：1 module, 2 kind, 3 target, 4 service, 5 version, 6 artifact, 7 sha256, 8 source_sha
manifest_rows() { grep -Ev '^[[:space:]]*(#|$)' "$MANIFEST"; }

manifest_get() { # manifest_get <module> <列号>
  local m="$1" col="$2"
  manifest_rows | awk -F'\t' -v m="$m" -v c="$col" '$1==m {print $c; found=1} END {exit !found}' \
    || die "manifest 里没有模块: $m"
}

manifest_modules() { # manifest_modules [target 过滤]
  local t="${1:-}"
  manifest_rows | awk -F'\t' -v t="$t" 't=="" || $3==t {print $1}'
}

installed_module_dir() { # installed_module_dir <模块>；仅返回模块目录内的 current 实体
  local m="$1" link="$MODULES_DIR/$1/current" dir module_root
  [ -L "$link" ] || return 1
  dir="$(cd "$link" 2>/dev/null && pwd -P)" || return 1
  [ -d "$dir" ] || return 1
  module_root="$(cd "$MODULES_DIR/$m" 2>/dev/null && pwd -P)" || return 1
  case "$dir" in
    "$module_root"/*) printf '%s\n' "$dir" ;;
    *) return 1 ;;
  esac
}

module_marker_value() { # module_marker_value <版本目录> <marker 文件名>
  local dir="$1" marker="$1/$2" value lines
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  lines="$(awk 'END { print NR }' "$marker")"
  [ "$lines" -eq 1 ] || return 1
  value="$(<"$marker")"
  case "$value" in
    "" | *$'\n'* | *$'\r'*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

installed_version() { # 已装 manifest 版本；旧目录无 marker 时兼容目录名
  local m="$1" link="$MODULES_DIR/$1/current" dir marker value base
  if ! dir="$(installed_module_dir "$m")"; then
    if [ -e "$link" ] || [ -L "$link" ]; then echo "?"; else echo "-"; fi
    return
  fi
  marker="$dir/$MODULE_VERSION_MARKER"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if value="$(module_marker_value "$dir" "$MODULE_VERSION_MARKER")"; then
      case "$value" in
        "." | ".." | */*) echo "?" ;;
        *) printf '%s\n' "$value" ;;
      esac
    else
      echo "?"
    fi
    return
  fi
  base="$(basename "$(readlink "$link")")"
  case "$base" in
    "$m-"*) printf '%s\n' "${base#"$m-"}" ;;
    *) printf '%s\n' "$base" ;;
  esac
}

installed_artifact_sha256() { # 已装产物 SHA；旧目录/缺失 marker 输出 "-"，损坏输出 "?"
  local m="$1" dir marker value
  if ! dir="$(installed_module_dir "$m")"; then
    if [ -e "$MODULES_DIR/$m/current" ] || [ -L "$MODULES_DIR/$m/current" ]; then
      echo "?"
    else
      echo "-"
    fi
    return
  fi
  marker="$dir/$MODULE_ARTIFACT_SHA256_MARKER"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    echo "-"
    return
  fi
  if ! value="$(module_marker_value "$dir" "$MODULE_ARTIFACT_SHA256_MARKER")"; then
    echo "?"
    return
  fi
  if [ "${#value}" -ne 64 ]; then
    echo "?"
    return
  fi
  case "$value" in
    *[!0-9a-f]*) echo "?" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# ---- 下载与校验 ----
sha256_verify() { # sha256_verify <文件> <期望值>（mac 无 sha256sum，用 shasum 兜底）
  local got
  if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$1" | awk '{print $1}')"
  else got="$(shasum -a 256 "$1" | awk '{print $1}')"; fi
  [ "$got" = "$2" ]
}

download_artifact() { # download_artifact <artifact> <sha256> → stdout 本地路径
  local artifact="$1" sha="$2" dest="$CACHE_DIR/$1"
  local curl_insecure="${CURL_INSECURE:-0}"
  # 数组保持非空，兼容 macOS Bash 3.2 在 set -u 下展开空数组会报错的行为。
  local -a curl_args=(-fL --retry 3)
  case "$curl_insecure" in
    "" | 0) ;;
    1) ;;
    *) die "CURL_INSECURE 只能为 0 或 1，当前值: $curl_insecure" ;;
  esac
  mkdir -p "$CACHE_DIR"
  if [ -f "$dest" ] && sha256_verify "$dest" "$sha"; then
    log "缓存命中: $artifact" >&2
  else
    if [ -n "${CURL_CA_BUNDLE:-}" ]; then
      [ -f "$CURL_CA_BUNDLE" ] && [ -r "$CURL_CA_BUNDLE" ] \
        || die "CURL_CA_BUNDLE 不是可读文件: $CURL_CA_BUNDLE"
      curl_args+=(--cacert "$CURL_CA_BUNDLE")
    fi
    if [ "$curl_insecure" = 1 ]; then
      warn "危险：CURL_INSECURE=1，HTTPS 证书与主机名校验已关闭；仅限临时排障，SHA-256 不能验证下载来源"
      curl_args+=(--insecure)
    fi
    log "下载: $BUCKET_URL/$artifact" >&2
    rm -f "$dest.part"
    if ! curl "${curl_args[@]}" -o "$dest.part" "$BUCKET_URL/$artifact"; then
      rm -f "$dest.part"
      die "下载失败: ${artifact}（内网需放行 github.com 与 release-assets.githubusercontent.com）"
    fi
    if ! sha256_verify "$dest.part" "$sha"; then
      rm -f "$dest.part"
      die "sha256 校验失败: $artifact"
    fi
    mv "$dest.part" "$dest"
  fi
  printf '%s\n' "$dest"
}

# ---- 模块 → 服务映射（dbdogctl 视角）----
module_services() {
  case "$1" in
    dbdog-server) echo "dbdog-server ddsql-server" ;;
    dbdog-web) echo "dbdog-web" ;;
    dbdog-mcp) echo "dbdog-mcp" ;;
    postgresql) echo "postgresql" ;;
    clickhouse) echo "clickhouse" ;;
    *) echo "" ;;
  esac
}

# ---- 钩子 ----
run_hook() { # run_hook <模块新版本目录> <pre-switch|post-switch>
  local dir="$1" hook="$2" script="$1/hooks/$2.sh"
  [ -f "$script" ] || return 0
  log "执行钩子: $(basename "$dir")/hooks/$2.sh"
  DBDOG_HOME="$DBDOG_HOME" ETC_DIR="$ETC_DIR" MODULES_DIR="$MODULES_DIR" \
    bash "$script" || die "钩子失败: ${script}（修复后可手动重跑）"
}
