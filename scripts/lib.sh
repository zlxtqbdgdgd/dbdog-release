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

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_layout() {
  mkdir -p "$MODULES_DIR" "$ETC_DIR" "$DATA_DIR" "$LOGS_DIR" "$RUN_DIR" "$CACHE_DIR"
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

installed_version() { # 已装版本；未装输出 "-"
  local m="$1" link="$MODULES_DIR/$1/current"
  if [ -L "$link" ]; then basename "$(readlink "$link")" | sed "s/^$m-//"; else echo "-"; fi
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
  mkdir -p "$CACHE_DIR"
  if [ -f "$dest" ] && sha256_verify "$dest" "$sha"; then
    log "缓存命中: $artifact" >&2
  else
    log "下载: $BUCKET_URL/$artifact" >&2
    curl -fL --retry 3 -o "$dest.part" "$BUCKET_URL/$artifact" || die "下载失败: ${artifact}（内网需放行 objects.githubusercontent.com）"
    mv "$dest.part" "$dest"
    sha256_verify "$dest" "$sha" || die "sha256 校验失败: $artifact"
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
