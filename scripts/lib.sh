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
# 基础运行时必须先于应用；应用按当前依赖图先 server、再 web、最后 MCP。
# 表结构的跨模块兼容不能依赖这个顺序，必须使用 expand/contract 迁移。
UPGRADE_MODULE_ORDER=(node goose postgresql clickhouse dbdog-server dbdog-web dbdog-mcp)
# 配置校准会在 upgrade 切包前发生；调用方用这些标记决定是否需要重启仍在运行、
# 但因产物身份相同而被 upgrade_one 跳过的服务。
# shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh 读取
DBDOG_SERVER_CONFIG_CHANGED=0
# shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh 读取
DBDOG_WEB_CONFIG_CHANGED=0
# shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh/合同测试读取
DBDOG_MCP_CONFIG_CHANGED=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_layout() {
  mkdir -p "$MODULES_DIR" "$ETC_DIR" "$DATA_DIR" "$LOGS_DIR" "$RUN_DIR" "$CACHE_DIR"
  chmod 700 "$ETC_DIR"
  find "$ETC_DIR" -type f -name '*.env' -exec chmod 600 {} +
}

ensure_env_default() { # ensure_env_default <env 文件> <KEY> <默认值> <占位片段>
  local file="$1" key="$2" value="$3" placeholder="$4" count tmp
  case "$key" in "" | *[!A-Z0-9_]*) die "非法 env key: $key" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "env 文件不存在或不是普通文件: $file"
  count="$(awk -v prefix="$key=" 'index($0, prefix) == 1 { n++ } END { print n + 0 }' "$file")"
  [ "$count" -le 1 ] || die "env 文件含重复键，拒绝猜测生效值: $file: $key"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if ! awk -v key="$key" -v value="$value" -v placeholder="$placeholder" '
      BEGIN { prefix = key "="; found = 0 }
      index($0, prefix) == 1 {
        found = 1
        current = substr($0, length(prefix) + 1)
        semantic = current
        sub(/[[:space:]]+#.*$/, "", semantic)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", semantic)
        if (semantic == "" || (placeholder != "" && index(semantic, placeholder) > 0)) {
          print prefix value
        } else {
          print
        }
        next
      }
      { print }
      END { if (!found) print prefix value }
    ' "$file" >"$tmp"; then
    rm -f -- "$tmp"
    die "更新 env 默认值失败: $file: $key"
  fi
  chmod 0600 "$tmp"
  mv -- "$tmp" "$file"
}

env_literal_value() { # env_literal_value <env 文件> <KEY>；只读简单 KEY=value，不执行文件
  local file="$1" key="$2" count
  [ -f "$file" ] && [ ! -L "$file" ] || die "env 文件不存在或不是普通文件: $file"
  count="$(awk -v prefix="$key=" 'index($0, prefix) == 1 { n++ } END { print n + 0 }' "$file")"
  [ "$count" -le 1 ] || die "env 文件含重复键，拒绝猜测生效值: $file: $key"
  awk -v prefix="$key=" '
    index($0, prefix) == 1 {
      value = substr($0, length(prefix) + 1)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file"
}

detect_advertise_host() {
  local host="${DBDOG_ADVERTISE_HOST:-}"
  if [ -z "$host" ] && command -v ip >/dev/null 2>&1; then
    host="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit } }')"
  fi
  if [ -z "$host" ] && command -v hostname >/dev/null 2>&1; then
    host="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  fi
  [ -n "$host" ] || host="127.0.0.1"
  case "$host" in *[!A-Za-z0-9._-]* | "") die "无法把 DBDOG_ADVERTISE_HOST 用作 URL host: $host" ;; esac
  printf '%s\n' "$host"
}

migrate_legacy_web_public_urls() { # <dbdog-web.env>；只迁移旧公网验收模板的三联 URL
  local file="$1" app ingest mcp legacy_host advertise_host
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  app="$(env_literal_value "$file" PUBLIC_APP_URL)"
  ingest="$(env_literal_value "$file" PUBLIC_INGEST_URL)"
  mcp="$(env_literal_value "$file" PUBLIC_MCP_URL)"
  case "$app" in http://*:25629) ;; *) return 0 ;; esac
  legacy_host="${app#http://}"; legacy_host="${legacy_host%:25629}"
  [ -n "$legacy_host" ] || return 0
  [ "$app" = "http://${legacy_host}:25629" ] \
    && [ "$ingest" = "http://${legacy_host}:21753" ] \
    && [ "$mcp" = "http://${legacy_host}:24267/mcp" ] \
    || return 0

  advertise_host="$(detect_advertise_host)"
  ensure_env_default "$file" PUBLIC_APP_URL \
    "http://${advertise_host}:3000" "$app"
  ensure_env_default "$file" PUBLIC_INGEST_URL \
    "http://${advertise_host}:8080" "$ingest"
  ensure_env_default "$file" PUBLIC_MCP_URL \
    "http://${advertise_host}:8090/mcp" "$mcp"
  # shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh 读取
  DBDOG_WEB_CONFIG_CHANGED=1
  log "已把旧验收模板的 PUBLIC_* URL 迁移为本机地址（${advertise_host}）"
}

migrate_legacy_mcp_public_urls() { # <dbdog-mcp.env>；只迁移旧公网验收模板的三联 URL
  local file="$1" issuer resource app legacy_host advertise_host
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  issuer="$(env_literal_value "$file" DBDOG_OAUTH_ISSUER)"
  resource="$(env_literal_value "$file" DBDOG_PUBLIC_MCP_URL)"
  app="$(env_literal_value "$file" DBDOG_APP_BASE_URL)"
  case "$issuer" in http://*:25629) ;; *) return 0 ;; esac
  legacy_host="${issuer#http://}"; legacy_host="${legacy_host%:25629}"
  [ -n "$legacy_host" ] || return 0
  [ "$issuer" = "http://${legacy_host}:25629" ] \
    && [ "$app" = "$issuer" ] \
    && [ "$resource" = "http://${legacy_host}:24267/mcp" ] \
    || return 0

  advertise_host="$(detect_advertise_host)"
  ensure_env_default "$file" DBDOG_OAUTH_ISSUER \
    "http://${advertise_host}:3000" "$issuer"
  ensure_env_default "$file" DBDOG_APP_BASE_URL \
    "http://${advertise_host}:3000" "$app"
  ensure_env_default "$file" DBDOG_PUBLIC_MCP_URL \
    "http://${advertise_host}:8090/mcp" "$resource"
  # shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh/合同测试读取
  DBDOG_MCP_CONFIG_CHANGED=1
  log "已把旧验收模板的 MCP OAuth/public URL 迁移为本机地址（${advertise_host}）"
}

configure_local_database_clients() {
  local server_env="$ETC_DIR/dbdog-server.env" web_env="$ETC_DIR/dbdog-web.env"
  local pg_dsn="postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable"
  # 只接管缺失值和随产物发布的 user:pass 占位；已有真实 DSN 永不覆盖。
  ensure_env_default "$server_env" PG_DSN "$pg_dsn" user:pass
  ensure_env_default "$web_env" DATABASE_URL "$pg_dsn" user:pass
  log "已校准 server/web 的本机 ctl 数据库连接（已有真实 DSN 保持不变）"
}

generate_secret() {
  "$MODULES_DIR/node/current/bin/node" -e \
    'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))'
}

choose_shared_secret() { # choose_shared_secret <KEY> <env 文件>...
  local key="$1" chosen="" value file; shift
  for file in "$@"; do
    value="$(env_literal_value "$file" "$key")"
    case "$value" in "" | change-me*) continue ;; esac
    [ "${#value}" -ge 16 ] || die "$file 的 $key 少于 16 字符，拒绝启动"
    if [ -z "$chosen" ]; then
      chosen="$value"
    elif [ "$chosen" != "$value" ]; then
      die "$key 在多个服务配置中不一致，拒绝猜测应覆盖哪一个"
    fi
  done
  [ -n "$chosen" ] || chosen="$(generate_secret)"
  printf '%s\n' "$chosen"
}

choose_shared_url() { # choose_shared_url <说明> <默认值> <env 文件> <KEY>...
  local label="$1" default_value="$2" chosen="" value file key; shift 2
  [ $(( $# % 2 )) -eq 0 ] || die "$label 的 env/key 参数不成对"
  while [ "$#" -gt 0 ]; do
    file="$1"; key="$2"; shift 2
    value="$(env_literal_value "$file" "$key")"
    case "$value" in "" | change-me*) continue ;; esac
    case "$value" in
      http://* | https://*) ;;
      *) die "$file 的 $key 不是合法 HTTP(S) URL，拒绝带病启动" ;;
    esac
    if [ -z "$chosen" ]; then
      chosen="$value"
    elif [ "${chosen%/}" != "${value%/}" ]; then
      die "$label 在多个服务配置中不一致，拒绝猜测应覆盖哪一个"
    fi
  done
  [ -n "$chosen" ] || chosen="$default_value"
  printf '%s\n' "$chosen"
}

configure_ready_to_use_stack() {
  local server_env="$ETC_DIR/dbdog-server.env"
  local web_env="$ETC_DIR/dbdog-web.env"
  local mcp_env="$ETC_DIR/dbdog-mcp.env"
  local internal_token oauth_secret advertise_host app_url ingest_url mcp_url config_file rc_key_path
  local server_before web_before mcp_before
  for config_file in "$server_env" "$web_env" "$mcp_env"; do
    [ -f "$config_file" ] && [ ! -L "$config_file" ] \
      || die "缺少可校准的应用配置: $config_file"
  done
  server_before="$(cksum "$server_env")"
  web_before="$(cksum "$web_env")"
  mcp_before="$(cksum "$mcp_env")"

  configure_local_database_clients
  internal_token="$(choose_shared_secret DBDOG_INTERNAL_TOKEN "$server_env" "$web_env" "$mcp_env")"
  oauth_secret="$(choose_shared_secret DBDOG_OAUTH_JWT_SECRET "$web_env" "$mcp_env")"
  advertise_host="$(detect_advertise_host)"
  app_url="$(choose_shared_url 'Web/MCP OAuth 地址' "http://${advertise_host}:3000" \
    "$web_env" PUBLIC_APP_URL \
    "$mcp_env" DBDOG_OAUTH_ISSUER \
    "$mcp_env" DBDOG_APP_BASE_URL)"
  ingest_url="http://${advertise_host}:8080"
  mcp_url="$(choose_shared_url 'Web/MCP resource 地址' "http://${advertise_host}:8090/mcp" \
    "$web_env" PUBLIC_MCP_URL \
    "$mcp_env" DBDOG_PUBLIC_MCP_URL)"

  ensure_env_default "$server_env" DBDOG_INTERNAL_TOKEN "$internal_token" change-me
  ensure_env_default "$server_env" DBDOG_HTTP_ADDR :8080 change-me
  ensure_env_default "$server_env" DBDOG_PUBLIC_BASE_URL "$app_url" change-me
  # Agent 首装会从 server 获取并信任 TUF root。这里启用 server 自己持久化的
  # signing seed，让普通安装/升级无需再手工开启 Remote Config。已有绝对路径保留。
  ensure_env_default "$server_env" DBDOG_RC_KEY_PATH "$DATA_DIR/remote-config.seed" change-me
  rc_key_path="$(env_literal_value "$server_env" DBDOG_RC_KEY_PATH)"
  case "$rc_key_path" in
    /*) ;;
    *) die "$server_env 的 DBDOG_RC_KEY_PATH 必须是绝对路径" ;;
  esac

  ensure_env_default "$web_env" DBDOG_INTERNAL_TOKEN "$internal_token" change-me
  ensure_env_default "$web_env" DBDOG_OAUTH_JWT_SECRET "$oauth_secret" change-me
  ensure_env_default "$web_env" DBDOG_SERVER_URL http://127.0.0.1:8080 change-me
  ensure_env_default "$web_env" PORT 3000 change-me
  ensure_env_default "$web_env" HOSTNAME 0.0.0.0 change-me
  ensure_env_default "$web_env" COOKIE_SECURE 0 change-me
  ensure_env_default "$web_env" PUBLIC_APP_URL "$app_url" change-me
  ensure_env_default "$web_env" PUBLIC_INGEST_URL "$ingest_url" change-me
  ensure_env_default "$web_env" PUBLIC_MCP_URL "$mcp_url" change-me

  ensure_env_default "$mcp_env" DBDOG_INTERNAL_TOKEN "$internal_token" change-me
  ensure_env_default "$mcp_env" DBDOG_OAUTH_JWT_SECRET "$oauth_secret" change-me
  ensure_env_default "$mcp_env" DBDOG_BASE_URL http://127.0.0.1:8080 change-me
  ensure_env_default "$mcp_env" DBDOG_HTTP_HOST 0.0.0.0 change-me
  ensure_env_default "$mcp_env" DBDOG_HTTP_PORT 8090 change-me
  ensure_env_default "$mcp_env" DBDOG_OAUTH_ISSUER "$app_url" change-me
  ensure_env_default "$mcp_env" DBDOG_PUBLIC_MCP_URL "$mcp_url" change-me
  ensure_env_default "$mcp_env" DBDOG_APP_BASE_URL "$app_url" change-me

  if [ "$server_before" != "$(cksum "$server_env")" ]; then
    # shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh 读取
    DBDOG_SERVER_CONFIG_CHANGED=1
  fi
  if [ "$web_before" != "$(cksum "$web_env")" ]; then
    # shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh 读取
    DBDOG_WEB_CONFIG_CHANGED=1
  fi
  if [ "$mcp_before" != "$(cksum "$mcp_env")" ]; then
    # shellcheck disable=SC2034 # 由 source 本库的 upgrade.sh/合同测试读取
    DBDOG_MCP_CONFIG_CHANGED=1
  fi
  log "已生成可直接使用的本机配置（访问地址: ${app_url}；已有真实配置保持不变）"
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

agent_marker_value() { # <Agent marker 路径> <runtime 根>；输出 -（未安装）或 ?（损坏）
  local marker="$1" runtime_root="$2" value lines
  if [ ! -e "$marker" ]; then
    [ -d "$runtime_root" ] && printf '%s\n' '?' || printf '%s\n' -
    return 0
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || \
    { printf '%s\n' '?'; return 0; }
  lines="$(awk 'END { print NR }' "$marker")"
  value="$(tr -d '\r\n' <"$marker")"
  [ "$lines" -eq 1 ] && [ -n "$value" ] || { printf '%s\n' '?'; return 0; }
  printf '%s\n' "$value"
}

canonicalize_upgrade_modules() { # canonicalize_upgrade_modules <模块>... → ORDERED_UPGRADE_MODULES
  local requested=("$@") candidate known seen
  local -a validated=()
  ORDERED_UPGRADE_MODULES=()

  for candidate in "${requested[@]}"; do
    case "$candidate" in
      "" | "." | ".." | */* | *$'\n'* | *$'\r'*)
        die "模块名不是安全的单层路径名: $candidate"
        ;;
    esac
    manifest_get "$candidate" 1 >/dev/null
    # `${array[@]+...}` 兼容 macOS Bash 3.2 在 set -u 下展开空数组。
    for seen in ${validated[@]+"${validated[@]}"}; do
      [ "$seen" != "$candidate" ] || die "升级模块重复: $candidate"
    done
    validated+=("$candidate")
  done

  # 已知依赖按固定顺序；未来新增且尚未写入顺序表的模块保留用户/manifest 顺序。
  for known in "${UPGRADE_MODULE_ORDER[@]}"; do
    for candidate in "${validated[@]}"; do
      if [ "$candidate" = "$known" ]; then
        ORDERED_UPGRADE_MODULES+=("$candidate")
        break
      fi
    done
  done
  for candidate in "${validated[@]}"; do
    known=0
    for seen in ${ORDERED_UPGRADE_MODULES[@]+"${ORDERED_UPGRADE_MODULES[@]}"}; do
      if [ "$seen" = "$candidate" ]; then known=1; break; fi
    done
    [ "$known" -eq 1 ] || ORDERED_UPGRADE_MODULES+=("$candidate")
  done
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
    # curl 原生处理 https_proxy/HTTPS_PROXY、ALL_PROXY 与 NO_PROXY；不显式传
    # --proxy，保留其大小写优先级、协议选择和本机绕过规则。
    if ! curl "${curl_args[@]}" -o "$dest.part" "$BUCKET_URL/$artifact"; then
      rm -f "$dest.part"
      die "下载失败: ${artifact}（代理用 https_proxy/HTTPS_PROXY，重签 CA 用 CURL_CA_BUNDLE；需放行 github.com 与 release-assets.githubusercontent.com）"
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
    DBDOG_MIGRATION_REQUIRED="${DBDOG_MIGRATION_REQUIRED:-0}" \
    bash "$script" || die "钩子失败: ${script}（修复后可手动重跑）"
}
