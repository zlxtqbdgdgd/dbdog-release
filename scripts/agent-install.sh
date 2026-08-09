#!/usr/bin/env bash
# GaussDB 主机：dbdog-agent 首装与升级实现（由 upgrade.sh dbdog-agent 统一调用）。
# 下载、目标机事实探测、配置、四个 systemd 服务、验收与失败回滚都在本流程内完成。

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/agent-lib.sh"

AGENT_UNITS=("${AGENT_SYSTEMD_UNITS[@]}")

WORK_DIR=""
RUNTIME_STAGE=""
CONFIG_STAGE=""
UNIT_STAGE=""
OLD_RUNTIME=""
OLD_CONFIG=""
UNIT_BACKUP=""
MUTATION_STARTED=0
INSTALL_SUCCEEDED=0
RUNTIME_CHANGED=0
PREVIOUS_INSTALL=0
HAD_CONFIG=0
PREVIOUS_ACTIVE_UNITS=""
PREVIOUS_ENABLED_UNITS=""
INSTALLER_CONTRACT_SHA256=""
AGENT_HOST_ARCH=""
AGENT_HEALTH_TIMEOUT_SECONDS=90
AGENT_HEALTH_WAIT_ATTEMPTS=0
AGENT_HEALTH_WAIT_ELAPSED=0
AGENT_HEALTH_WAIT_REASON="not-started"

usage() {
  cat <<'EOF'
用法：sudo ./scripts/agent-install.sh

首次安装需要两个外部值；可通过环境变量传入，终端执行时缺失项会安全提示输入：
  DBDOG_SERVER_URL                       dbdog-server origin，例如 http://10.0.0.8:8080
  DBDOG_API_KEY                          dbdog-web 签发的 Agent ingest key

可选覆盖（正常情况下自动发现或使用稳定默认值）：
  DBDOG_GAUSSDB_MONITOR_PASSWORD         默认首次生成、升级保留
  DBDOG_GAUSSDB_PID                      极特殊场景显式指定实例主进程 PID
  DBDOG_GAUSSDB_ENV_FILE                 显式 GaussDB 客户端环境文件（绝对路径）
  DBDOG_GAUSSDB_PGHOST                   仅安装期 gsql 使用的本地 Unix socket 目录
  DBDOG_GAUSSDB_LD_LIBRARY_PATH           显式 gsql 动态库搜索路径
  DBDOG_GAUSSDB_PORT                     仅在无法从运行进程发现时使用
  DBDOG_GAUSSDB_LOG_GLOB                 仅在无法从 GAUSSLOG 发现时使用
  DBDOG_GAUSSDB_DBNAME                   默认 postgres
  DBDOG_GAUSSDB_DEPLOYMENT               centralized 或 distributed
  DBDOG_OPENGAUSS_MONITOR_PASSWORD       openGauss 监控密码（只验不建；升级路径自动按现有 conf 逐实例沿用）
  DBDOG_OPENGAUSS_DBNAME                 openGauss 主连接库，默认 postgres
  DBDOG_POSTGRES_MONITOR_PASSWORD        PostgreSQL 监控密码（只验不建；升级路径自动按现有 conf 逐实例沿用）
  DBDOG_POSTGRES_DBNAME                  PostgreSQL 主连接库，默认 postgres
  DBDOG_POSTGRES_EXCLUDE_PORTS           显式排除的 PG 实例端口（空格/逗号分隔）；停监控是操作者决策，必须点名
  DBDOG_ENV                              默认 prod
  DBDOG_AGENT_HOSTNAME                   默认 hostname -s
  DBDOG_AGENT_HEALTH_TIMEOUT             全组件 readiness 截止时间，默认 90 秒（30–600）

也可通过统一入口 sudo ./scripts/upgrade.sh dbdog-agent 调用；已落地的 server URL、
API key 和数据库密码默认保留。
EOF
}

remove_known_stage() { # <路径> <允许的精确前缀>
  local path="$1" prefix="$2"
  [ -z "$path" ] && return 0
  [ ! -e "$path" ] && return 0
  case "$path" in "$prefix"??????) rm -rf -- "$path" ;; *) warn "拒绝清理非 staging 路径: $path" ;; esac
}

cleanup_stages() {
  remove_known_stage "$WORK_DIR" /tmp/dbdog-agent-install.
  remove_known_stage "$RUNTIME_STAGE" /opt/.dbdog-agent-stage.
  remove_known_stage "$CONFIG_STAGE" /etc/.dbdog-agent-stage.
  remove_known_stage "$UNIT_STAGE" /etc/systemd/system/.dbdog-agent-units.
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

stop_private_units() {
  local unit
  # 只触碰 dbdog 私有四单元；同机官方 datadog-agent 不在作用域内。
  for unit in dbdog-agent-process.service dbdog-agent-trace.service \
    dbdog-agent.service dbdog-agent-sysprobe.service; do
    unit_exists "$unit" || continue
    systemctl stop "$unit" || return 1
    ! systemctl is-active --quiet "$unit" || return 1
  done
}

unit_was_in() { # <空格分隔的 unit 集合> <unit>
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

rollback_install() {
  local unit
  set +e
  warn "Agent 安装/升级失败，开始恢复安装前状态"
  stop_private_units || warn "回滚前未能完全停止本次 Agent 服务"

  if [ -n "$OLD_CONFIG" ] && [ -d "$OLD_CONFIG" ]; then
    [ ! -e "$AGENT_CONFIG_DIR" ] || mv -- "$AGENT_CONFIG_DIR" "${OLD_CONFIG}.failed"
    mv -- "$OLD_CONFIG" "$AGENT_CONFIG_DIR"
  elif [ "$HAD_CONFIG" -eq 0 ] && [ -d "$AGENT_CONFIG_DIR" ]; then
    mv -- "$AGENT_CONFIG_DIR" "${AGENT_CONFIG_DIR}.failed.$(date +%Y%m%d%H%M%S)"
  fi

  if [ "$RUNTIME_CHANGED" -eq 1 ] && [ -n "$OLD_RUNTIME" ] && [ -d "$OLD_RUNTIME" ]; then
    [ ! -e "$AGENT_RUNTIME_DIR" ] || mv -- "$AGENT_RUNTIME_DIR" "${OLD_RUNTIME}.failed"
    mv -- "$OLD_RUNTIME" "$AGENT_RUNTIME_DIR"
  elif [ "$PREVIOUS_INSTALL" -eq 0 ] && [ "$RUNTIME_CHANGED" -eq 1 ] && [ -d "$AGENT_RUNTIME_DIR" ]; then
    mv -- "$AGENT_RUNTIME_DIR" "${AGENT_RUNTIME_DIR}.failed.$(date +%Y%m%d%H%M%S)"
  fi

  if [ -n "$UNIT_BACKUP" ] && [ -d "$UNIT_BACKUP" ]; then
    for unit in "${AGENT_UNITS[@]}"; do
      if [ -f "$UNIT_BACKUP/$unit" ]; then
        install -o root -g root -m 0644 "$UNIT_BACKUP/$unit" "/etc/systemd/system/$unit"
      else
        rm -f -- "/etc/systemd/system/$unit"
      fi
    done
  fi
  systemctl daemon-reload || true
  for unit in "${AGENT_UNITS[@]}"; do
    if unit_was_in "$PREVIOUS_ENABLED_UNITS" "$unit"; then
      systemctl enable "$unit" >/dev/null 2>&1 || true
    else
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
  done
  # 按依赖顺序只恢复安装前确实 active 的单元。
  for unit in "${AGENT_UNITS[@]}"; do
    unit_was_in "$PREVIOUS_ACTIVE_UNITS" "$unit" || continue
    systemctl start "$unit" || true
  done
  warn "已执行自动回滚；失败后的新目录保留为 *.failed.* 供排查"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$MUTATION_STARTED" -eq 1 ] && [ "$INSTALL_SUCCEEDED" -eq 0 ]; then
    rollback_install
  fi
  cleanup_stages
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

require_root_host() {
  [ "$EUID" -eq 0 ] || die "请用 sudo 运行；安装需要写 /opt、/etc 和 systemd"
  # host_arch 规范化 uname -m（含 arm64/amd64 别名）并对未知架构 fail closed；
  # 保存为全局供后续 runtime 校验、下载与 marker 比较统一取同一个 manifest 行。
  AGENT_HOST_ARCH="$(host_arch)"
  [ -d /run/systemd/system ] || die "当前主机不是运行中的 systemd 环境"
  local command
  for command in awk bash cat chmod chown cmp cp curl env file find grep head hostname install ldd \
    mktemp mv od readlink rm runuser sed sort stat systemctl tar timeout tr; do
    command -v "$command" >/dev/null 2>&1 || die "缺少安装依赖命令: $command"
  done
  [ -x /usr/bin/timeout ] || die "systemd 单元需要 /usr/bin/timeout"
}

configure_agent_health_timeout() {
  local requested="${DBDOG_AGENT_HEALTH_TIMEOUT:-90}"
  case "$requested" in '' | *[!0-9]*) die "DBDOG_AGENT_HEALTH_TIMEOUT 必须是 30–600 的整数秒" ;; esac
  [ "$requested" -ge 30 ] && [ "$requested" -le 600 ] || \
    die "DBDOG_AGENT_HEALTH_TIMEOUT 必须在 30–600 秒之间"
  AGENT_HEALTH_TIMEOUT_SECONDS="$requested"
}

prompt_value() { # <变量名> <提示> <是否隐藏:0|1>
  local name="$1" prompt="$2" secret="$3" value
  eval 'value="${'"$name"':-}"'
  [ -z "$value" ] || return 0
  [ -t 0 ] || die "$name 未设置，且当前不是可交互终端"
  if [ "$secret" -eq 1 ]; then
    read -r -s -p "$prompt: " value
    echo
  else
    read -r -p "$prompt: " value
  fi
  [ -n "$value" ] || die "$name 不能为空"
  printf -v "$name" '%s' "$value"
  export "$name=$value"
}

latest_failed_agent_config() { # 首装验收失败后复用同一次生成的凭证
  local dir suffix latest=""
  for dir in "$AGENT_CONFIG_DIR".failed.*; do
    [ -d "$dir" ] || continue
    suffix="${dir#"$AGENT_CONFIG_DIR.failed."}"
    case "$suffix" in "" | *[!0-9]*) continue ;; esac
    [ "${#suffix}" -eq 14 ] || continue
    if [ -z "$latest" ] || [[ "$dir" > "$latest" ]]; then latest="$dir"; fi
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

resolve_inputs() {
  local old_datadog="$AGENT_CONFIG_DIR/datadog.yaml"
  local old_gauss="$AGENT_CONFIG_DIR/conf.d/gaussdb.d/conf.yaml"
  local old recovery=""

  if [ ! -f "$old_gauss" ]; then
    recovery="$(latest_failed_agent_config 2>/dev/null || true)"
    if [ -n "$recovery" ] && [ -f "$recovery/conf.d/gaussdb.d/conf.yaml" ]; then
      old_datadog="$recovery/datadog.yaml"
      old_gauss="$recovery/conf.d/gaussdb.d/conf.yaml"
      log "复用上次首装失败目录中的凭证，避免已创建监控用户在重跑时凭证失配: $recovery"
    fi
  fi

  if [ -z "${DBDOG_SERVER_URL:-}" ]; then
    old="$(agent_existing_top_scalar "$old_datadog" dd_url 2>/dev/null || true)"
    [ -z "$old" ] || DBDOG_SERVER_URL="$old"
  fi
  if [ -z "${DBDOG_API_KEY:-}" ]; then
    old="$(agent_existing_top_scalar "$old_datadog" api_key 2>/dev/null || true)"
    [ -z "$old" ] || DBDOG_API_KEY="$old"
  fi
  if [ -z "${DBDOG_GAUSSDB_MONITOR_PASSWORD:-}" ]; then
    old="$(agent_existing_gauss_scalar "$old_gauss" password 2>/dev/null || true)"
    [ -z "$old" ] || DBDOG_GAUSSDB_MONITOR_PASSWORD="$old"
  fi
  # openGauss/PostgreSQL 凭证只验不建：升级路径从现有 conf 收割（首实例），
  # 首装由环境变量提供；两个引擎的 conf 实例块与 gauss 同形，收割器可直接复用。
  if [ -z "${DBDOG_OPENGAUSS_MONITOR_PASSWORD:-}" ]; then
    old="$(agent_existing_gauss_scalar "$AGENT_CONFIG_DIR/conf.d/opengauss.d/conf.yaml" password 2>/dev/null || true)"
    [ -z "$old" ] || DBDOG_OPENGAUSS_MONITOR_PASSWORD="$old"
  fi
  if [ -z "${DBDOG_POSTGRES_MONITOR_PASSWORD:-}" ]; then
    old="$(agent_existing_gauss_scalar "$AGENT_CONFIG_DIR/conf.d/postgres.d/conf.yaml" password 2>/dev/null || true)"
    [ -z "$old" ] || DBDOG_POSTGRES_MONITOR_PASSWORD="$old"
  fi

  prompt_value DBDOG_SERVER_URL "dbdog-server 地址（如 http://10.0.0.8:8080）" 0
  prompt_value DBDOG_API_KEY "dbdog-web 签发的 Agent ingest key" 1
  if [ -z "${DBDOG_GAUSSDB_MONITOR_PASSWORD:-}" ]; then
    DBDOG_GAUSSDB_MONITOR_PASSWORD="$(agent_generate_gaussdb_password)" || \
      die "无法生成 GaussDB 监控用户随机密码"
    log "已生成 GaussDB dbdog 监控用户随机密码（只写入 root 0600 配置）"
  fi

  DBDOG_SERVER_URL="$(agent_validate_server_url "$DBDOG_SERVER_URL")"
  agent_require_single_line DBDOG_API_KEY "$DBDOG_API_KEY"
  agent_require_single_line DBDOG_GAUSSDB_MONITOR_PASSWORD "$DBDOG_GAUSSDB_MONITOR_PASSWORD"
  [ -n "$DBDOG_API_KEY" ] || die "DBDOG_API_KEY 不能为空"
  [ -n "$DBDOG_GAUSSDB_MONITOR_PASSWORD" ] || die "GaussDB 监控密码不能为空"
  agent_validate_gaussdb_password "$DBDOG_GAUSSDB_MONITOR_PASSWORD" || \
    die "GaussDB 监控密码必须为 8-32 个无空白可打印字符，并至少包含大小写字母、数字、特殊字符中的三类"
  case "$DBDOG_API_KEY" in *[!A-Za-z0-9._-]*) die "DBDOG_API_KEY 含不支持的字符" ;; esac

  agent_require_single_line DBDOG_OPENGAUSS_MONITOR_PASSWORD "${DBDOG_OPENGAUSS_MONITOR_PASSWORD:-}"
  agent_require_single_line DBDOG_POSTGRES_MONITOR_PASSWORD "${DBDOG_POSTGRES_MONITOR_PASSWORD:-}"
  agent_require_single_line DBDOG_GAUSSDB_ENV_FILE "${DBDOG_GAUSSDB_ENV_FILE:-}"
  agent_require_single_line DBDOG_GAUSSDB_PGHOST "${DBDOG_GAUSSDB_PGHOST:-}"
  agent_require_single_line DBDOG_GAUSSDB_LD_LIBRARY_PATH \
    "${DBDOG_GAUSSDB_LD_LIBRARY_PATH:-}"
  case "${DBDOG_GAUSSDB_ENV_FILE:-}" in "" | /*) ;; *) die "DBDOG_GAUSSDB_ENV_FILE 必须是绝对路径" ;; esac

  DBDOG_GAUSSDB_USER="${DBDOG_GAUSSDB_USER:-dbdog}"
  DBDOG_GAUSSDB_DBNAME="${DBDOG_GAUSSDB_DBNAME:-postgres}"
  DBDOG_ENV="${DBDOG_ENV:-prod}"
  DBDOG_AGENT_HOSTNAME="${DBDOG_AGENT_HOSTNAME:-$(hostname -s)}"
  agent_require_single_line DBDOG_GAUSSDB_USER "$DBDOG_GAUSSDB_USER"
  agent_require_single_line DBDOG_GAUSSDB_DBNAME "$DBDOG_GAUSSDB_DBNAME"
  agent_require_single_line DBDOG_ENV "$DBDOG_ENV"
  agent_require_single_line DBDOG_AGENT_HOSTNAME "$DBDOG_AGENT_HOSTNAME"
  [ "$DBDOG_GAUSSDB_USER" = dbdog ] || \
    die "当前 GaussDB integration 的兼容 schema 固定属于 dbdog，暂不支持改监控用户名"
}

curl_tls_args() { # 设置 CURL_TLS_ARGS
  CURL_TLS_ARGS=(-fsS --connect-timeout 10 --max-time 30 --noproxy '*')
  case "${CURL_INSECURE:-0}" in
    0 | '') ;;
    1) CURL_TLS_ARGS+=(-k); warn "CURL_INSECURE=1：server bootstrap 临时关闭 TLS 校验" ;;
    *) die "CURL_INSECURE 只接受 0 或 1" ;;
  esac
}

compact_json_file() { # <输入文件>
  local input="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$input" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(value, dict) or not value:
    raise SystemExit("JSON root must be a non-empty object")
print(json.dumps(value, ensure_ascii=True, separators=(",", ":")))
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -ce 'objects | select(length > 0)' "$input"
  else
    die "缺少 python3 或 jq，无法校验 Remote Config trust root"
  fi
}

compact_tuf_root_file() { # <输入文件>；只接受 Agent 可直接信任的 TUF root metadata
  local input="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$input" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
signed = value.get("signed") if type(value) is dict else None
valid = (
    type(signed) is dict
    and signed.get("_type") == "root"
    and type(signed.get("version")) is int
    and signed["version"] > 0
    and type(signed.get("keys")) is dict
    and type(signed.get("roles")) is dict
    and type(value.get("signatures")) is list
    and len(value["signatures"]) > 0
)
if not valid:
    raise SystemExit("JSON is not signed TUF root metadata")
print(json.dumps(value, ensure_ascii=True, separators=(",", ":")))
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -ce '
      select(
        type == "object"
        and (.signed | type) == "object"
        and .signed._type == "root"
        and (.signed.version | type) == "number"
        and .signed.version > 0
        and (.signed.version | floor) == .signed.version
        and (.signed.keys | type) == "object"
        and (.signed.roles | type) == "object"
        and (.signatures | type) == "array"
        and (.signatures | length) > 0
      )
    ' "$input"
  else
    die "缺少 python3 或 jq，无法校验 Remote Config trust root"
  fi
}

fetch_server_bootstrap() { # 设置 RC_ROOT_JSON
  local header="$WORK_DIR/api-key.header" validate="$WORK_DIR/validate.json"
  local rc_root="$WORK_DIR/configuration-root.json" compact
  printf 'DD-API-KEY: %s\n' "$DBDOG_API_KEY" >"$header"
  chmod 0600 "$header"
  curl_tls_args
  log "验证 dbdog-server 可达性与 Agent API key ..."
  curl "${CURL_TLS_ARGS[@]}" -H "@$header" \
    "$DBDOG_SERVER_URL/api/v1/validate" >"$validate" || \
    die "dbdog-server 不可达或 Agent API key 无效"
  compact="$(compact_json_file "$validate")" || die "server validate 返回的不是合法 JSON"
  [ "$compact" = '{"valid":true}' ] || die "server 未确认 Agent API key 有效"

  curl "${CURL_TLS_ARGS[@]}" -H "@$header" \
    "$DBDOG_SERVER_URL/api/v0.1/configuration-root" >"$rc_root" || \
    die "无法取得 Remote Config trust root"
  RC_ROOT_JSON="$(compact_tuf_root_file "$rc_root")" || \
    die "Remote Config trust root 不是带签名的 TUF root metadata"
  case "$RC_ROOT_JSON" in *$'\n'* | *$'\r'*) die "Remote Config trust root 含换行" ;; esac
}

agent_sql_literal() { # SQL 单引号字面量内容（调用方负责外层引号）
  agent_require_single_line "SQL value" "$1"
  printf '%s' "$1" | sed "s/'/''/g"
}

agent_gauss_exec() { # <进程索引> <命令> [参数...]；复用该实例真实客户端环境
  local index="$1" home owner owner_home host port ld path
  shift
  home="${AGENT_GAUSS_PID_HOMES[$index]}"
  owner="${AGENT_GAUSS_PID_OWNERS[$index]}"
  owner_home="${AGENT_GAUSS_PID_OWNER_HOMES[$index]}"
  host="${AGENT_GAUSS_PID_HOSTS[$index]}"
  port="${AGENT_GAUSS_PID_PORTS[$index]}"
  ld="${AGENT_GAUSS_PID_LD_LIBRARY_PATHS[$index]}"
  path="${AGENT_GAUSS_PID_PATHS[$index]}"
  [ -n "$home" ] || die "无法从 gaussdb 进程确定 GAUSSHOME"
  [ -n "$owner" ] || die "无法从 gaussdb 进程确定运行用户"
  [ -n "$host" ] || die "无法从 gaussdb 进程确定本地 socket"
  runuser -u "$owner" -- env -i \
    HOME="${owner_home:-/}" USER="$owner" LOGNAME="$owner" LC_ALL=C \
    GAUSSHOME="$home" PGHOST="$host" PGPORT="$port" \
    PGCONNECT_TIMEOUT=8 LD_LIBRARY_PATH="$ld" PATH="$path" "$@"
}

agent_gauss_timed_exec() { # <进程索引> <秒> <命令> [参数...]
  local index="$1" seconds="$2" timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  shift 2
  [ -x "$timeout_bin" ] || return 1
  agent_gauss_exec "$index" "$timeout_bin" --kill-after=2 "$seconds" "$@"
}

agent_gsql() { # <进程索引> [gsql 参数...]；stdin 可传 SQL
  local index="$1" host port gsql
  shift
  host="${AGENT_GAUSS_PID_HOSTS[$index]}"
  port="${AGENT_GAUSS_PID_PORTS[$index]}"
  gsql="${AGENT_GAUSS_PID_GSQLS[$index]}"
  [ -x "$gsql" ] || die "目标 GaussDB 没有可执行 gsql: $gsql"
  agent_gauss_timed_exec "$index" 30 "$gsql" -X -q -A -t -v ON_ERROR_STOP=1 \
    -h "$host" -p "$port" -d "$DBDOG_GAUSSDB_DBNAME" "$@"
}

agent_show_preflight_error() { # <文件> <错误>
  local file="$1" message="$2"
  [ ! -s "$file" ] || sed -n '1,160p' "$file" >&2
  die "$message"
}

agent_gaussdb_hba_file() { # <进程索引>；输出规范化 HBA 路径
  local index="$1" data hba
  data="${AGENT_GAUSS_PID_DATA_DIRS[$index]}"
  hba="$(agent_gsql "$index" -c 'SHOW hba_file;' 2>/dev/null \
    | awk 'NF { value=$0 } END { print value }' || true)"
  if [ -z "$hba" ] && [ -n "$data" ]; then hba="$data/pg_hba.conf"; fi
  [ -n "$hba" ] || return 1
  case "$hba" in /*) ;; *) [ -n "$data" ] && hba="$data/$hba" ;; esac
  hba="$(readlink -f "$hba" 2>/dev/null || true)"
  [ -f "$hba" ] || return 1
  printf '%s\n' "$hba"
}

agent_hba_has_required_tcp_md5() { # <HBA 文件>
  awk '
    /^[[:space:]]*#/ { next }
    {
      kind=tolower($1); database=$2; user=$3; address=$4; method=tolower($5)
      gsub(/^"|"$/, "", user)
      if (kind == "host" && database == "all" && user == "dbdog" \
          && address == "127.0.0.1/32" && method == "md5") found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

agent_classify_gauss_engines() {
  # openGauss 的主进程/客户端与 GaussDB 同名同构，检测阶段无法区分；这里按 gsql
  # --version 的自报身份分流（openGauss 的版本串含 "openGauss"）。分类结果决定渲染
  # 归属与建号策略：GaussDB 走完整建号链，openGauss 凭证只验不建（与 PostgreSQL 同待遇）。
  local index count out version_line
  AGENT_GAUSS_PID_ENGINES=()
  AGENT_GAUSSDB_RENDER_PORTS=()
  AGENT_OPENGAUSS_RENDER_PORTS=()
  AGENT_OPENGAUSS_LOG_GLOBS=()
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  for ((index=0; index<count; index++)); do
    out="$WORK_DIR/engine-classify.$index.out"
    if ! agent_gauss_timed_exec "$index" 20 "${AGENT_GAUSS_PID_GSQLS[$index]}" --version >"$out" 2>&1; then
      agent_show_preflight_error "$out" "无法读取实例 gsql 版本以分类引擎（实例索引 ${index}）"
    fi
    version_line="$(head -1 "$out")"
    if printf '%s' "$version_line" | grep -qi opengauss; then
      AGENT_GAUSS_PID_ENGINES+=(opengauss)
      agent_add_unique AGENT_OPENGAUSS_RENDER_PORTS "${AGENT_GAUSS_PID_PORTS[$index]}"
      # openGauss 单机日志在 $PGDATA/pg_log（GAUSSLOG 常缺省），从数据目录直接推导。
      [ ! -d "${AGENT_GAUSS_PID_DATA_DIRS[$index]}/pg_log" ] || \
        agent_add_unique AGENT_OPENGAUSS_LOG_GLOBS "${AGENT_GAUSS_PID_DATA_DIRS[$index]}/pg_log/postgresql-*.log"
    else
      AGENT_GAUSS_PID_ENGINES+=(gaussdb)
      agent_add_unique AGENT_GAUSSDB_RENDER_PORTS "${AGENT_GAUSS_PID_PORTS[$index]}"
    fi
    log "引擎分类: 127.0.0.1:${AGENT_GAUSS_PID_PORTS[$index]} -> ${AGENT_GAUSS_PID_ENGINES[$index]}"
  done
  # GaussDB 实例在场时 GAUSSLOG 仍是硬要求（openGauss 日志已另行从 PGDATA/pg_log 推导）。
  if [ -n "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] && [ -z "${AGENT_GAUSS_LOG_GLOBS[*]-}" ]; then
    die "存在 GaussDB 实例但无法发现 GAUSSLOG；请只在首次安装时显式设置 DBDOG_GAUSSDB_LOG_GLOB"
  fi
  # 三引擎共用 127.0.0.1 TCP 命名空间：跨引擎端口也必须唯一，否则渲染前 fail closed。
  local port seen=" "
  for port in ${AGENT_GAUSS_PORTS[@]+"${AGENT_GAUSS_PORTS[@]}"} ${AGENT_PG_PORTS[@]+"${AGENT_PG_PORTS[@]}"}; do
    case "$seen" in *" $port "*) \
      die "跨引擎端口冲突：127.0.0.1:${port} 被多个实例占用，TCP 监控无法唯一区分" ;; esac
    seen="$seen$port "
  done
}

agent_assemble_engine_credentials() {
  # og/pg 凭证按实例组装：升级路径从现有 conf 的 port→password 对收割（同引擎多实例
  # 密码可各不相同——构建机 5432/5433 实测就是两套），无命中的端口回退环境变量的
  # 整引擎默认。空缺不在这里 die：渲染前的逐端口检查会带着 DBA 指路一次报清。
  local pairs index port pw
  AGENT_OPENGAUSS_RENDER_PASSWORDS=()
  AGENT_PG_RENDER_PASSWORDS=()
  pairs="$(agent_harvest_engine_passwords "$AGENT_CONFIG_DIR/conf.d/opengauss.d/conf.yaml")"
  for ((index=0; index<${#AGENT_OPENGAUSS_RENDER_PORTS[@]}; index++)); do
    port="${AGENT_OPENGAUSS_RENDER_PORTS[$index]}"
    pw="$(printf '%s\n' "$pairs" | awk -F'\t' -v p="$port" '$1==p{print $2; exit}')"
    [ -n "$pw" ] || pw="${DBDOG_OPENGAUSS_MONITOR_PASSWORD:-}"
    AGENT_OPENGAUSS_RENDER_PASSWORDS+=("$pw")
  done
  pairs="$(agent_harvest_engine_passwords "$AGENT_CONFIG_DIR/conf.d/postgres.d/conf.yaml")"
  for ((index=0; index<${#AGENT_PG_PORTS[@]}; index++)); do
    port="${AGENT_PG_PORTS[$index]}"
    pw="$(printf '%s\n' "$pairs" | awk -F'\t' -v p="$port" '$1==p{print $2; exit}')"
    [ -n "$pw" ] || pw="${DBDOG_POSTGRES_MONITOR_PASSWORD:-}"
    AGENT_PG_RENDER_PASSWORDS+=("$pw")
  done
}

agent_require_probe_credentials() {
  # openGauss/PostgreSQL 只验不建：凭证必须在启动验收前被 TCP 实测有效，失败即指路
  # DBA 工具（安装器不创建、不修改这两个引擎的用户与 HBA）。在 cutover 之后执行——
  # 探测用的 embedded psycopg 来自新 runtime，首装时 cutover 前还没有可用 Python。
  local index port rc
  for ((index=0; index<${#AGENT_OPENGAUSS_RENDER_PORTS[@]}; index++)); do
    port="${AGENT_OPENGAUSS_RENDER_PORTS[$index]}"
    rc=0
    agent_tcp_password_probe "$port" "${DBDOG_OPENGAUSS_DBNAME:-postgres}" \
      "${AGENT_OPENGAUSS_RENDER_PASSWORDS[$index]}" "og.$index" || rc=$?
    [ "$rc" -eq 0 ] || die "openGauss 监控凭证验证失败（127.0.0.1:${port}，rc=${rc}）；安装器不创建/修改 openGauss 用户，请 DBA 核对 $SCRIPT_DIR/agent/init-dbdog-user-opengauss-all-databases.sh 的执行结果与 HBA 后重试，本次安装会回滚"
  done
  for ((index=0; index<${#AGENT_PG_PORTS[@]}; index++)); do
    port="${AGENT_PG_PORTS[$index]}"
    rc=0
    agent_tcp_password_probe "$port" "${DBDOG_POSTGRES_DBNAME:-postgres}" \
      "${AGENT_PG_RENDER_PASSWORDS[$index]}" "pg.$index" || rc=$?
    [ "$rc" -eq 0 ] || die "PostgreSQL 监控凭证验证失败（127.0.0.1:${port}，rc=${rc}）；安装器不创建/修改 PostgreSQL 用户，请 DBA 核对 $SCRIPT_DIR/agent/init-dbdog-user-pg-all-databases.sh 的执行结果与 pg_hba 后重试，本次安装会回滚"
  done
}

preflight_gaussdb_clients() {
  local index count gsql ldd_bin out value mode hba exists
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  if [ -z "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ]; then
    return 0
  fi
  log "预检目标 GaussDB 的 gsql 动态库、版本、本地连接和认证兼容性 ..."
  for ((index=0; index<count; index++)); do
    [ "${AGENT_GAUSS_PID_ENGINES[$index]:-gaussdb}" = gaussdb ] || continue
    gsql="${AGENT_GAUSS_PID_GSQLS[$index]}"
    ldd_bin="$(agent_find_in_path "${AGENT_GAUSS_PID_PATHS[$index]}" ldd 2>/dev/null || true)"
    [ -n "$ldd_bin" ] || die "GaussDB 客户端环境找不到 ldd（实例索引 ${index}）"

    out="$WORK_DIR/gsql-ldd.$index.out"
    if ! agent_gauss_timed_exec "$index" 20 "$ldd_bin" "$gsql" >"$out" 2>&1; then
      agent_show_preflight_error "$out" "gsql 动态库预检执行失败（实例索引 ${index}）"
    fi
    if grep -Eq '(^|[[:space:]])not found($|[[:space:]])|=>[[:space:]]+not found' "$out"; then
      agent_show_preflight_error "$out" \
        "gsql 仍有未解析运行库；请核对数据库用户 profile 或设置 DBDOG_GAUSSDB_ENV_FILE/DBDOG_GAUSSDB_LD_LIBRARY_PATH"
    fi

    out="$WORK_DIR/gsql-version.$index.out"
    agent_gauss_timed_exec "$index" 20 "$gsql" --version >"$out" 2>&1 || \
      agent_show_preflight_error "$out" "gsql --version 失败（实例索引 ${index}）"
    [ -s "$out" ] || agent_show_preflight_error "$out" "gsql --version 没有返回版本信息"

    out="$WORK_DIR/gsql-select.$index.out"
    agent_gsql "$index" -c 'SELECT 1;' >"$out" 2>&1 || \
      agent_show_preflight_error "$out" \
        "gsql 本地管理连接失败；PGHOST 必须指向该实例可用的 Unix socket，可用 DBDOG_GAUSSDB_PGHOST 覆盖"
    value="$(awk 'NF { value=$0 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$out")"
    [ "$value" = 1 ] || agent_show_preflight_error "$out" "gsql SELECT 1 返回异常（实例索引 ${index}）"

    mode="$(agent_gsql "$index" -c 'SHOW password_encryption_type;' 2>"$WORK_DIR/gsql-password-mode.$index.err" \
      | awk 'NF { value=$0 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }')" || \
      agent_show_preflight_error "$WORK_DIR/gsql-password-mode.$index.err" \
        "无法读取 password_encryption_type（实例索引 ${index}）"
    # 日常采集的已验证兼容合同是标准 libpq 经 127.0.0.1 TCP + MD5 HBA。
    # mode=1 让新建监控用户同时具有 SHA256 与 MD5 凭证；安装器只读校验。
    [ "$mode" = 1 ] || die \
      "GaussDB 前置条件不满足：SHOW password_encryption_type 当前为 ${mode}，必须由 DBA 按数据库规范配置为 1 并确认生效；dbdog 安装器不会修改 postgresql.conf"
    hba="$(agent_gaussdb_hba_file "$index")" || \
      die "无法在预检阶段确定 GaussDB HBA 文件（实例索引 ${index}）"
    agent_hba_has_required_tcp_md5 "$hba" || die \
      "GaussDB HBA 缺少受支持的本机认证规则：host all dbdog 127.0.0.1/32 md5；请 DBA 把它放在可能匹配 dbdog 的宽泛规则之前并按数据库规范重新加载。dbdog 安装器不会修改 pg_hba.conf: $hba"
    exists="$(agent_gsql "$index" -c \
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_user WHERE usename='dbdog') THEN 1 ELSE 0 END;" \
      | awk 'NF { value=$0 } END { print value }')" || \
      die "无法在预检阶段判断 GaussDB 监控用户是否存在（实例索引 ${index}）"
    case "$exists" in
      0)
        # 不存在的角色可能按服务端全局密码策略收到防枚举用的模拟 challenge，
        # 不能拿它推断新账号创建后的 verifier。CREATE 后会立即做 code=5 + 真实 libpq 验收。
        ;;
      1)
        agent_active_auth_is_md5 "$index" || die \
          "GaussDB 当前生效的本机 TCP 认证不是 MD5；请 DBA 核对 HBA 顺序、用户凭证与 reload 状态（实例索引 ${index}）"
        ;;
      *) die "无法判断 GaussDB 监控用户是否存在（实例索引 ${index}）" ;;
    esac

    agent_warn_gaussdb_collection_gucs "$index"
  done
}

# 只影响采集质量、不影响能否装成的 GUC 一律 warn，不 die：装不上是硬失败，采不全可以先上线
# 再让 DBA 调。安装器保持只读，不改 postgresql.conf（与上面几条硬门禁同一口径）。
readonly AGENT_GAUSSDB_EXPECTED_LOG_LINE_PREFIX='%m %n %u %d %h %p %S %x %a '
readonly AGENT_GAUSSDB_MIN_TRACK_ACTIVITY_QUERY_SIZE=4096

# agent_gsql 已带 -A -t（无对齐、纯元组），输出没有前导填充。log_line_prefix 的结尾空格是
# %a 与 query_id 的分隔符、属于取值的一部分，所以这里只去掉行尾 CR，绝不 trim 空格——
# 把它 trim 掉会让任何正确配置都被判成不符。命令替换只吃掉换行，空格得以保留。
agent_show_guc_raw() { # <进程索引> <GUC 名>；读不到时输出空串而不是失败
  local index=$1 name=$2
  agent_gsql "$index" -c "SHOW ${name};" 2>/dev/null | head -n 1 | tr -d '\r'
}

agent_show_guc() { # <进程索引> <GUC 名>；去首尾空白，供数值类 GUC 使用
  local value
  value="$(agent_show_guc_raw "$@")"
  printf '%s' "${value#"${value%%[![:space:]]*}"}" | sed 's/[[:space:]]*$//'
}

agent_warn_gaussdb_collection_gucs() { # <进程索引>
  local index=$1 prefix size

  # log_line_prefix 决定 gs_log 能否被 dbdog-server 的 GaussDB grok 切开。前缀不符时整条失配、
  # 落 fallback：没有 attribute、没有 db.date、时间戳退化成采集时间、级别一律 info，ERROR/FATAL
  # 在日志检索里根本看不见——而 Agent 侧看起来一切正常，很难从现象反推到这里。
  prefix="$(agent_show_guc_raw "$index" log_line_prefix)"
  if [ -z "$prefix" ]; then
    warn "无法读取 log_line_prefix（实例索引 ${index}）；gs_log 能否被正确解析未经确认"
  elif [ "$prefix" != "$AGENT_GAUSSDB_EXPECTED_LOG_LINE_PREFIX" ]; then
    warn "GaussDB log_line_prefix 与 dbdog 解析契约不一致（实例索引 ${index}）：当前 '${prefix}'，期望 '${AGENT_GAUSSDB_EXPECTED_LOG_LINE_PREFIX}'。指标与 DBM 采集不受影响，但 gs_log 会整条解析失败：日志检索里拿不到数据库/用户/级别等字段，ERROR/FATAL 也不会被识别。请 DBA 按数据库规范修改 postgresql.conf 并重新加载；dbdog 安装器不修改它。"
  fi

  # track_activity_query_size 决定 pg_stat_activity 里 SQL 正文的截断长度，直接影响 DBM 语句
  # 采样能看到多少内容。推荐值 4096 与 agent-core 的 GaussDB 集成同一口径。
  size="$(agent_show_guc "$index" track_activity_query_size)"
  case "$size" in
    '')
      warn "无法读取 track_activity_query_size（实例索引 ${index}）；DBM 语句采样的截断长度未经确认"
      ;;
    *[!0-9]*)
      warn "track_activity_query_size 取值无法解析为字节数（实例索引 ${index}）：'${size}'"
      ;;
    *)
      if [ "$size" -lt "$AGENT_GAUSSDB_MIN_TRACK_ACTIVITY_QUERY_SIZE" ]; then
        warn "GaussDB track_activity_query_size=${size} 低于推荐值 ${AGENT_GAUSSDB_MIN_TRACK_ACTIVITY_QUERY_SIZE}（实例索引 ${index}）：超过该长度的 SQL 正文会在 pg_stat_activity 里被截断，DBM 语句采样只能看到前半截。请 DBA 按数据库规范调高并重启生效；dbdog 安装器不修改它。"
      fi
      ;;
  esac
}

agent_tcp_password_probe() { # <端口> <库名> <密码> <输出标签>；经 127.0.0.1 TCP 验证；0=有效，2=明确拒绝，1=基础设施失败
  local probe_port="$1" probe_dbname="$2" password="$3" probe_tag="$4"
  local python password_file out attempt rc success=0 rejected=0
  local timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  python="${DBDOG_AGENT_PYTHON:-$AGENT_RUNTIME_DIR/embedded/bin/python3}"
  [ -x "$python" ] && [ -x "$timeout_bin" ] || return 1
  password_file="$WORK_DIR/monitor-password.$probe_tag"
  printf '%s' "$password" >"$password_file" || return 1
  chmod 0600 "$password_file" || return 1
  out="$WORK_DIR/monitor-auth.$probe_tag.out"
  for ((attempt=1; attempt<=5; attempt++)); do
    : >"$out"
    rc=0
    "$timeout_bin" --kill-after=2 10 /usr/bin/env -i \
      PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$python" -I - "$password_file" "$probe_port" \
      "$probe_dbname" >"$out" 2>&1 <<'PY' || rc=$?
import pathlib
import sys

import psycopg

password = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
try:
    with psycopg.connect(
        host="127.0.0.1",
        port=int(sys.argv[2]),
        dbname=sys.argv[3],
        user="dbdog",
        password=password,
        connect_timeout=5,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            if cursor.fetchone() != (1,):
                raise RuntimeError("unexpected SELECT 1 result")
except psycopg.Error as error:
    if error.sqlstate == "28P01":
        raise SystemExit(42)
    print(f"database authentication probe failed: sqlstate={error.sqlstate or 'unknown'}", file=sys.stderr)
    raise SystemExit(43)
except Exception as error:
    print(f"database authentication probe infrastructure failed: {type(error).__name__}", file=sys.stderr)
    raise SystemExit(44)
PY
    case "$rc" in
      0)
        success=1
        break
        ;;
      42)
        rejected=1
        break
        ;;
    esac
    sleep 1
  done
  rm -f -- "$password_file" || return 1
  [ "$success" -eq 1 ] && return 0
  [ "$rejected" -eq 1 ] && return 2
  return 1
}

agent_monitor_password_works() { # <gauss 实例索引> <密码>；兼容包装，语义同 agent_tcp_password_probe
  agent_tcp_password_probe "${AGENT_GAUSS_PID_PORTS[$1]}" "$DBDOG_GAUSSDB_DBNAME" "$2" "gauss.$1"
}

agent_active_auth_is_md5() { # <进程索引>；读取当前生效的 PostgreSQL v3 认证请求，不提交失败密码
  local index="$1" python out
  local timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  python="${DBDOG_AGENT_PYTHON:-$AGENT_RUNTIME_DIR/embedded/bin/python3}"
  [ -x "$python" ] && [ -x "$timeout_bin" ] || return 1
  out="$WORK_DIR/active-auth.$index.out"
  if ! "$timeout_bin" --kill-after=2 10 /usr/bin/env -i \
    PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    "$python" -I - "${AGENT_GAUSS_PID_PORTS[$index]}" \
    "$DBDOG_GAUSSDB_DBNAME" >"$out" 2>&1 <<'PY'
import socket
import struct
import sys


def receive_exact(connection, length):
    chunks = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("database closed connection during authentication probe")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


parameters = (
    b"user\0dbdog\0database\0"
    + sys.argv[2].encode("utf-8")
    + b"\0application_name\0dbdog-auth-probe\0\0"
)
payload = struct.pack("!I", 196608) + parameters
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as connection:
    connection.sendall(struct.pack("!I", len(payload) + 4) + payload)
    message_type = receive_exact(connection, 1)
    message_length = struct.unpack("!I", receive_exact(connection, 4))[0]
    if message_length < 8 or message_length > 1024 * 1024:
        raise RuntimeError("invalid authentication response length")
    body = receive_exact(connection, message_length - 4)

if message_type != b"R":
    raise SystemExit("database did not return an AuthenticationRequest")
authentication_code = struct.unpack("!I", body[:4])[0]
if authentication_code != 5:
    raise SystemExit(f"active authentication method is not MD5 (code={authentication_code})")
print("active authentication method: MD5")
PY
  then
    [ ! -s "$out" ] || sed -n '1,80p' "$out" >&2
    warn "实例索引 ${index} 当前生效的 127.0.0.1 TCP 首匹配认证不是 MD5 code=5；请 DBA 核对 HBA 顺序并确认配置已重新加载"
    return 1
  fi
}

agent_prepare_gaussdb_user() { # <密码>；创建用户或验证已有用户凭证
  local password="$1" escaped sql="$WORK_DIR/set-gaussdb-password.sql"
  local index count exists mode reset=0 password_status
  escaped="$(agent_sql_literal "$password")" || return 1
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ -n "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] || return 1
  for ((index=0; index<count; index++)); do
    # 建号链只属于真 GaussDB；openGauss 实例凭证只验不建（agent_require_probe_credentials）。
    [ "${AGENT_GAUSS_PID_ENGINES[$index]:-gaussdb}" = gaussdb ] || continue
    exists="$(agent_gsql "$index" -c \
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_user WHERE usename='dbdog') THEN 1 ELSE 0 END;" \
      | awk 'NF { value=$0 } END { print value }')" || return 1
    mode="$(agent_gsql "$index" -c 'SHOW password_encryption_type;' \
      | awk 'NF { value=$0 } END { print value }')" || return 1
    case "$exists" in
      0)
        [ "$mode" = 1 ] || return 1
        printf "CREATE USER dbdog WITH MONADMIN PASSWORD '%s';\n" "$escaped" >"$sql" || return 1
        reset=1
        ;;
      1)
        agent_active_auth_is_md5 "$index" || return 1
        password_status=0
        agent_monitor_password_works "$index" "$password" || password_status=$?
        case "$password_status" in
          0)
            printf 'ALTER USER dbdog WITH MONADMIN;\n' >"$sql" || return 1
            ;;
          2)
            warn "实例索引 ${index} 已确认生效 MD5 challenge，但已有 dbdog 用户拒绝保存密码；该用户可能缺少 MD5 verifier，或 Agent 保存密码不匹配。mode=1 不会转换旧凭证，安装器不会擅自改密"
            return 1
            ;;
          *)
            warn "实例索引 ${index} 无法可靠判定现有 dbdog 密码；拒绝把探测故障当作密码错误并重置"
            return 1
            ;;
        esac
        ;;
      *) die "无法判断 GaussDB 监控用户是否存在（实例索引 ${index}）" ;;
    esac
    chmod 0600 "$sql" || return 1
    agent_gsql "$index" <"$sql" || return 1
    if [ "$reset" -eq 1 ]; then
      agent_active_auth_is_md5 "$index" || return 1
      if ! agent_monitor_password_works "$index" "$password"; then
        warn "实例索引 ${index} 已设置 dbdog 密码，但标准 libpq 仍无法经 127.0.0.1 TCP + MD5 登录"
        return 1
      fi
    fi
    reset=0
  done
}

# 安装器只负责「装机当时存在的库」；此后每次 CREATE DATABASE 都要由 DBA 重跑每库初始化。
# 把批量脚本和它用的 SQL 一起落到 runtime 树下的固定路径，控制台「采集配置」页就能给出
# 绝对路径的可执行命令（dbdog-web src/lib/db-init-commands.ts DB_INIT_SCRIPT_DIR），
# 研发不必再去研发仓找 .sh。cutover 会整树替换 runtime，所以每次安装都要重新落一遍。
#
# 三引擎全装：主机装的是哪种引擎由现场决定，而控制台按实例 dbms 给命令；只发 GaussDB 那套
# 会让 PostgreSQL/openGauss 实例的页面指向不存在的文件。多出的两套是惰性文本，无服务加载。
AGENT_DBM_INIT_ASSETS="\
init-dbdog-user-gaussdb-all-databases.sh:init-gaussdb-perdb.sql
init-dbdog-user-pg-all-databases.sh:init-dbdog-user-pg-perdb.sql
init-dbdog-user-opengauss-all-databases.sh:init-dbdog-user-opengauss-perdb.sql"

install_dbm_init_scripts() {
  local target="$AGENT_RUNTIME_DIR/scripts" source="$SCRIPT_DIR/agent" entry script sql count=0
  install -d -o root -g root -m 0755 "$target" || die "无法创建每库初始化工具目录: $target"
  while IFS= read -r entry; do
    script="${entry%%:*}"
    sql="${entry##*:}"
    [ -f "$source/$script" ] || die "缺少每库 DBM 初始化脚本: $source/$script"
    [ -f "$source/$sql" ] || die "缺少每库 DBM 对象 SQL: $source/$sql"
    # DBA 用数据库 OS 账号（非 root）执行，故给 a+rx / a+r。
    install -o root -g root -m 0755 "$source/$script" "$target/$script" || \
      die "无法安装每库 DBM 初始化脚本: $target/$script"
    install -o root -g root -m 0444 "$source/$sql" "$target/$sql" || \
      die "无法安装每库 DBM 对象 SQL: $target/$sql"
    count=$((count + 1))
  done <<<"$AGENT_DBM_INIT_ASSETS"
  [ "$count" -eq 3 ] || die "每库 DBM 初始化工具数量异常: $count"
  log "每库 DBM 初始化工具已就位: $target（新增库后用数据库 OS 账号跑对应引擎的 --all）"
}

bootstrap_gaussdb_monitoring() {
  local sql="$SCRIPT_DIR/agent/init-gaussdb-perdb.sql" index count
  # 建号链只属于真 GaussDB；主机没有 gauss 实例（纯 openGauss/PostgreSQL）时整段跳过。
  if [ -z "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ]; then
    return 0
  fi
  [ -f "$sql" ] || die "缺少 GaussDB 兼容对象 SQL: $sql"
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  log "使用目标机 GAUSSHOME/gsql 幂等准备 dbdog 监控账号与兼容视图（仅安装阶段）..."
  # password_encryption_type 与 HBA 已在预检中只读核对。这里仅创建/校验账号，
  # 并用交付给 integration 的同一凭证经内嵌 psycopg/libpq 做真实 TCP 登录探测。
  agent_prepare_gaussdb_user "$DBDOG_GAUSSDB_MONITOR_PASSWORD" || \
    die "无法通过目标 GaussDB 的本地管理连接准备监控用户"
  for ((index=0; index<count; index++)); do
    [ "${AGENT_GAUSS_PID_ENGINES[$index]:-gaussdb}" = gaussdb ] || continue
    agent_gsql "$index" <"$sql" || die "创建 GaussDB 兼容视图失败（实例索引 ${index}）"
  done
}

validate_archive_members() { # <tarball>
  local package="$1" list="$WORK_DIR/archive.list" duplicate
  tar -tzf "$package" >"$list" || die "无法读取 Agent tarball"
  [ -s "$list" ] || die "Agent tarball 为空"
  awk '
    BEGIN { bad=0 }
    {
      if ($0 != "." && $0 != "./" && index($0, "./") != 1) bad=1
      n=split($0, part, "/")
      for (i=1; i<=n; i++) if (part[i] == "..") bad=1
    }
    END { exit bad }
  ' "$list" || die "Agent tarball 含越界路径"
  duplicate="$(LC_ALL=C sort "$list" | awk 'previous == $0 { print; exit } { previous=$0 }')"
  [ -z "$duplicate" ] || die "Agent tarball 含重复成员: $duplicate"
  for required in ./.install_root ./provenance/build.txt ./provenance/agent-version.txt \
    ./provenance/gaussdb.txt ./version-manifest.txt ./version-manifest.json \
    ./bin/agent/agent ./embedded/bin/trace-loader ./embedded/bin/trace-agent \
    ./embedded/bin/process-agent ./embedded/bin/system-probe; do
    grep -Fqx "$required" "$list" || die "Agent tarball 缺少: $required"
  done
  if grep -Eq '^\./(embedded/)?bin/(gsql|gaussdb)$' "$list"; then
    die "Agent tarball 不应打包目标 GaussDB 的 gsql/gaussdb 二进制"
  fi
  if grep -Fqx "./$AGENT_INSTALLER_CONTRACT_MARKER" "$list"; then
    die "Agent tarball 不得预置安装器验收 marker: $AGENT_INSTALLER_CONTRACT_MARKER"
  fi
}

build_field() { # <文件> <key>
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); found=1 } END { exit !found }' "$1"
}

agent_version_manifest_json_value() { # <version-manifest.json>；输出唯一 build_version
  local input="$1" parser env_bin
  env_bin="$(command -v env 2>/dev/null || true)"
  [ -n "$env_bin" ] || return 1
  if parser="$(command -v python3 2>/dev/null)"; then
    "$env_bin" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$parser" - "$input" <<'PY'
import json
import pathlib
import sys


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key!r}")
        value[key] = item
    return value


document = json.loads(
    pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"),
    object_pairs_hook=unique_object,
)
version = document.get("build_version") if type(document) is dict else None
if type(version) is not str or not version:
    raise SystemExit("version-manifest.json has no string build_version")
print(version)
PY
  elif parser="$(command -v jq 2>/dev/null)"; then
    "$env_bin" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$parser" -er \
      'if type == "object" and (.build_version | type) == "string" and (.build_version | length) > 0 then .build_version else error("missing build_version") end' \
      "$input"
  else
    return 1
  fi
}

agent_version_output_sha256() { # <单行 version 输出>；哈希口径与发布端 printf '%s\n' 一致
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s\n' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

validate_runtime_tree() { # <目录> <manifest version>
  local tree="$1" expected_version="$2" info="$1/provenance/build.txt" bin link resolved
  local integration_info="$1/provenance/gaussdb.txt" module_path distribution_path
  local version_info="$1/provenance/agent-version.txt"
  local manifest_text="$1/version-manifest.txt" manifest_json="$1/version-manifest.json"
  local env_bin timeout_bin runtime_ld version_output version_rc=0 label reported_version separator details
  local json_version build_binary_sha version_binary_sha build_text_sha version_text_sha
  local build_json_sha version_json_sha build_output_sha version_output_sha actual_output_sha value
  local elf_pattern
  [ -n "$AGENT_HOST_ARCH" ] || die "验证 Agent runtime 前必须先确定主机架构（AGENT_HOST_ARCH 未设置）"
  case "$AGENT_HOST_ARCH" in
    aarch64) elf_pattern='ELF 64-bit LSB.*(ARM aarch64|aarch64)' ;;
    x86_64) elf_pattern='ELF 64-bit LSB.*x86-64' ;;
    *) die "dbdog-agent 不支持的目标架构: $AGENT_HOST_ARCH" ;;
  esac
  [ -f "$tree/.install_root" ] || die "Agent runtime 缺少 .install_root"
  [ "$(build_field "$info" product)" = dbdog-agent ] || die "Agent provenance product 错误"
  [ "$(build_field "$info" version)" = "$expected_version" ] || die "Agent provenance version 错误"
  [ "$(build_field "$info" compiled_agent_version)" = "$expected_version" ] || \
    die "Agent provenance compiled_agent_version 与 manifest 版本不一致"
  [ "$(build_field "$info" architecture)" = "$AGENT_HOST_ARCH" ] || die "Agent provenance architecture 错误"
  [ "$(build_field "$info" install_prefix)" = "$AGENT_RUNTIME_DIR" ] || die "Agent install prefix 不匹配"
  # provenance 记录的是 integration 版本；只验证采集插件完整，不拿它限制目标
  # GaussDB 服务端版本。Python minor 随未来 Agent 升级时也不应成为安装器写死条件。
  module_path="$(build_field "$integration_info" module_path)" || \
    die "Agent runtime 缺少 GaussDB integration module provenance"
  distribution_path="$(build_field "$integration_info" distribution_path)" || \
    die "Agent runtime 缺少 GaussDB integration distribution provenance"
  case "$module_path" in
    ./embedded/lib/python*/site-packages/datadog_checks/gaussdb/__init__.py) ;;
    *) die "Agent runtime 的 GaussDB integration module path 非法" ;;
  esac
  case "$distribution_path" in
    ./embedded/lib/python*/site-packages/datadog_gaussdb-*.dist-info) ;;
    *) die "Agent runtime 的 GaussDB integration distribution path 非法" ;;
  esac
  [ -f "$tree/${module_path#./}" ] || die "Agent runtime 缺少 GaussDB integration module"
  [ -d "$tree/${distribution_path#./}" ] || die "Agent runtime 缺少 GaussDB integration distribution"
  find "$tree/embedded/lib" -type f -path '*psycopg_c.libs/libpq-*' -print -quit | grep -q . \
    || die "Agent runtime 缺少 psycopg/libpq 连接运行库"
  for bin in bin/agent/agent embedded/bin/trace-loader embedded/bin/trace-agent \
    embedded/bin/process-agent embedded/bin/system-probe; do
    [ -x "$tree/$bin" ] || die "Agent runtime 缺少可执行文件: $bin"
    file "$tree/$bin" | grep -Eq "$elf_pattern" || \
      die "Agent 二进制不是 Linux $AGENT_HOST_ARCH: $bin"
  done
  while IFS= read -r -d '' link; do
    resolved="$(readlink -m "$link")"
    case "$resolved" in "$tree" | "$tree"/*) ;; *) die "Agent runtime 符号链接越界: $link" ;; esac
  done < <(find "$tree" -type l -print0)

  # 必须执行即将切换的那一个 binary；空环境只注入候选 tree 的私有库目录，避免误用
  # 同机官方 Agent、用户 PATH 或旧 runtime 的 LD_LIBRARY_PATH。麒麟构建的稳定格式为
  # `Agent <release> - Commit: ...`，其中
  # version token 必须完整相等，不能用前缀匹配让 .3 接受 .30/7.79 等版本。
  env_bin="$(command -v env 2>/dev/null || true)"
  timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  [ -n "$env_bin" ] && [ -x "$timeout_bin" ] || \
    die "缺少 Agent version 最小环境所需的 env/timeout"
  [ -d "$tree/embedded/lib" ] || die "Agent runtime 缺少私有动态库目录: embedded/lib"
  runtime_ld="$tree/embedded/lib"
  [ ! -d "$tree/embedded/lib64" ] || runtime_ld="$runtime_ld:$tree/embedded/lib64"
  version_output="$("$timeout_bin" --kill-after=2 30 "$env_bin" -i \
    LD_LIBRARY_PATH="$runtime_ld" PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    "$tree/bin/agent/agent" version 2>&1)" || version_rc=$?
  [ "$version_rc" -eq 0 ] || \
    die "Agent binary version 执行失败（rc=$version_rc）: ${version_output:-无输出}"
  case "$version_output" in
    "" | *$'\n'* | *$'\r'*) die "Agent binary version 输出不是单行文本" ;;
  esac
  IFS=' ' read -r label reported_version separator details <<<"$version_output"
  [ "$label" = Agent ] && [ "$reported_version" = "$expected_version" ] \
    && [ "$separator" = - ] && [ -n "$details" ] || \
    die "Agent binary version 与 manifest 不一致: 期望 $expected_version，实际 $version_output"

  [ -f "$version_info" ] || die "Agent runtime 缺少 provenance/agent-version.txt"
  [ "$(build_field "$version_info" compiled_version)" = "$expected_version" ] || \
    die "Agent version provenance 的 compiled_version 不一致"
  [ "$(build_field "$version_info" manifest_header_version)" = "$expected_version" ] || \
    die "Agent version provenance 的 manifest_header_version 不一致"
  [ "$(build_field "$version_info" manifest_component_version)" = "$expected_version" ] || \
    die "Agent version provenance 的 manifest_component_version 不一致"
  [ "$(build_field "$version_info" manifest_json_version)" = "$expected_version" ] || \
    die "Agent version provenance 的 manifest_json_version 不一致"
  [ "$(build_field "$version_info" binary_path)" = ./bin/agent/agent ] || \
    die "Agent version provenance 的 binary_path 不一致"
  [ "$(build_field "$version_info" version_manifest_text_path)" = ./version-manifest.txt ] || \
    die "Agent version provenance 的 version_manifest_text_path 不一致"
  [ "$(build_field "$version_info" version_manifest_json_path)" = ./version-manifest.json ] || \
    die "Agent version provenance 的 version_manifest_json_path 不一致"
  [ "$(build_field "$version_info" version_output)" = "$version_output" ] || \
    die "Agent 实际 version 输出与 provenance 不一致"

  awk -v expected="$expected_version" '
    $1 == "agent" {
      header_count++
      if (NR != 1 || NF != 2 || $2 != expected) bad=1
    }
    $1 == "datadog-agent" {
      count++
      if (NF < 2 || $2 != expected) bad=1
    }
    END { exit(NR > 0 && header_count == 1 && count == 1 && !bad ? 0 : 1) }
  ' "$manifest_text" || die "version-manifest.txt 与 manifest 版本不一致"
  json_version="$(agent_version_manifest_json_value "$manifest_json")" || \
    die "无法严格读取 version-manifest.json build_version"
  [ "$json_version" = "$expected_version" ] || \
    die "version-manifest.json build_version 与 manifest 版本不一致"

  build_binary_sha="$(build_field "$info" agent_binary_sha256)" || die "build provenance 缺少 binary SHA"
  version_binary_sha="$(build_field "$version_info" binary_sha256)" || die "version provenance 缺少 binary SHA"
  build_text_sha="$(build_field "$info" agent_version_manifest_text_sha256)" || die "build provenance 缺少 text manifest SHA"
  version_text_sha="$(build_field "$version_info" version_manifest_text_sha256)" || die "version provenance 缺少 text manifest SHA"
  build_json_sha="$(build_field "$info" agent_version_manifest_json_sha256)" || die "build provenance 缺少 JSON manifest SHA"
  version_json_sha="$(build_field "$version_info" version_manifest_json_sha256)" || die "version provenance 缺少 JSON manifest SHA"
  build_output_sha="$(build_field "$info" agent_version_output_sha256)" || die "build provenance 缺少 version output SHA"
  version_output_sha="$(build_field "$version_info" version_output_sha256)" || die "version provenance 缺少 version output SHA"
  [ "$build_binary_sha" = "$version_binary_sha" ] \
    && [ "$build_text_sha" = "$version_text_sha" ] \
    && [ "$build_json_sha" = "$version_json_sha" ] \
    && [ "$build_output_sha" = "$version_output_sha" ] || \
    die "Agent build/version provenance 的 SHA 记录不一致"
  for value in "$build_binary_sha" "$build_text_sha" "$build_json_sha" "$build_output_sha"; do
    [ "${#value}" -eq 64 ] || die "Agent version provenance 含无效 SHA-256"
    case "$value" in *[!0-9a-f]*) die "Agent version provenance 含无效 SHA-256" ;; esac
  done
  sha256_verify "$tree/bin/agent/agent" "$build_binary_sha" || die "Agent binary SHA-256 与 provenance 不一致"
  sha256_verify "$manifest_text" "$build_text_sha" || die "version-manifest.txt SHA-256 与 provenance 不一致"
  sha256_verify "$manifest_json" "$build_json_sha" || die "version-manifest.json SHA-256 与 provenance 不一致"
  actual_output_sha="$(agent_version_output_sha256 "$version_output")" || \
    die "无法计算 Agent version 输出 SHA-256"
  [ "$actual_output_sha" = "$build_output_sha" ] || \
    die "Agent version 输出 SHA-256 与 provenance 不一致"
}

prepare_runtime() { # <tarball> <version> <sha>
  local package="$1" version="$2" sha="$3" installed_sha="" installed_version=""
  if [ -d "$AGENT_RUNTIME_DIR" ]; then
    installed_sha="$(agent_marker_value \
      "$AGENT_RUNTIME_DIR/.dbdog-artifact-sha256" "$AGENT_RUNTIME_DIR")"
    installed_version="$(agent_marker_value \
      "$AGENT_RUNTIME_DIR/.dbdog-release-version" "$AGENT_RUNTIME_DIR")"
  fi
  if [ "$installed_sha" = "$sha" ]; then
    [ "$installed_version" = "$version" ] || \
      die "Agent runtime SHA 虽一致，但 release-version marker 不匹配，拒绝跳过切换"
    validate_runtime_tree "$AGENT_RUNTIME_DIR" "$version"
    log "Agent runtime 版本、产物 SHA、provenance 与 binary 已一致；本次刷新配置并重新验收"
    RUNTIME_CHANGED=0
    return
  fi

  RUNTIME_STAGE="$(mktemp -d /opt/.dbdog-agent-stage.XXXXXX)"
  log "解包并验证 Agent runtime staging ..."
  tar --no-same-owner -xzf "$package" -C "$RUNTIME_STAGE"
  validate_runtime_tree "$RUNTIME_STAGE" "$version"
  printf '%s\n' "$version" >"$RUNTIME_STAGE/.dbdog-release-version"
  printf '%s\n' "$sha" >"$RUNTIME_STAGE/.dbdog-artifact-sha256"
  chmod 0444 "$RUNTIME_STAGE/.dbdog-release-version" \
    "$RUNTIME_STAGE/.dbdog-artifact-sha256"
  install -d -o root -g root -m 0700 "$RUNTIME_STAGE/run"
  if [ -d "$AGENT_RUN_DIR" ]; then
    cp -a "$AGENT_RUN_DIR/." "$RUNTIME_STAGE/run/"
  fi
  rm -f -- "$RUNTIME_STAGE/run/sysprobe.sock" "$RUNTIME_STAGE/run/system-probe.pid" \
    "$RUNTIME_STAGE/run/process-agent.pid" "$RUNTIME_STAGE/run/trace-agent.pid"
  chown -hR root:root "$RUNTIME_STAGE"
  RUNTIME_CHANGED=1
}

write_installer_contract_marker() { # 在全部验收成功后原子确认安装器合约
  local marker="$AGENT_RUNTIME_DIR/$AGENT_INSTALLER_CONTRACT_MARKER" temp current=""
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    warn "Agent 安装器合约 marker 被目录占用，拒绝覆盖: $marker"
    return 1
  fi
  if { [ -e "$marker" ] || [ -L "$marker" ]; } && \
     [ ! -f "$marker" ] && [ ! -L "$marker" ]; then
    warn "Agent 安装器合约 marker 不是普通文件或符号链接，拒绝覆盖: $marker"
    return 1
  fi
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    current="$(awk 'NR == 1 { value=$0 } END { if (NR == 1) print value }' "$marker" 2>/dev/null || true)"
  fi
  [ "$current" != "$INSTALLER_CONTRACT_SHA256" ] || return 0
  temp="$(mktemp "$AGENT_RUNTIME_DIR/.dbdog-installer-contract.XXXXXX")" || return 1
  if ! printf '%s\n' "$INSTALLER_CONTRACT_SHA256" >"$temp" \
    || ! chown root:root "$temp" \
    || ! chmod 0444 "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if [ -L "$marker" ] && ! rm -f -- "$marker"; then
    rm -f -- "$temp"
    return 1
  fi
  if ! mv -- "$temp" "$marker"; then
    rm -f -- "$temp"
    return 1
  fi
}

render_install_state() {
  CONFIG_STAGE="$(mktemp -d /etc/.dbdog-agent-stage.XXXXXX)"
  UNIT_STAGE="$(mktemp -d /etc/systemd/system/.dbdog-agent-units.XXXXXX)"
  install -d -m 0700 "$CONFIG_STAGE/conf.d"
  agent_render_datadog_yaml "$CONFIG_STAGE/datadog.yaml" "$DBDOG_SERVER_URL" \
    "$DBDOG_API_KEY" "$DBDOG_AGENT_HOSTNAME" "$RC_ROOT_JSON"
  agent_render_system_probe_yaml "$CONFIG_STAGE/system-probe.yaml"
  # 升级路径的一次性提醒（2026-08-06）：agent_render_checks 会整份重写 conf.d，因此
  # database_identifier 模板自动切到新的横线形（'$resolved_hostname-$port'）。但**历史数据里
  # 的冒号标识不会自己消失**——同一实例会裂成新旧两个 database_instance，按实例分组的图会断。
  # 清理动作在 dbdog-server 那侧（CH/PG），本机做不了，故只在这里检测并指路。
  # 顺序铁律：先换模板 + 重启 agent，再去服务端清理；反过来会先删完、agent 又按旧模板写回来。
  if grep -rqs 'resolved_hostname:\$port' /etc/dbdog-agent/conf.d 2>/dev/null; then
    printf '\n[!] 本机原有 conf 使用**冒号**形 database_identifier，升级后将切为横线形。\n'
    printf '    历史数据需在 dbdog-server 机器上一次性清理（否则同实例标识裂成两个）：\n'
    printf '      dbdog-release/scripts/one-off/clean-colon-identifier-data.sh          # 先只统计\n'
    printf '      dbdog-release/scripts/one-off/clean-colon-identifier-data.sh --apply  # 确认后再删\n'
    printf '    全部环境切完后请把该一次性脚本删掉，别留成常驻工具。\n\n'
  fi
  agent_render_checks "$CONFIG_STAGE/conf.d" "$DBDOG_GAUSSDB_MONITOR_PASSWORD" \
    "$DBDOG_GAUSSDB_USER" "$DBDOG_GAUSSDB_DBNAME" "$DBDOG_ENV"
  find "$CONFIG_STAGE" -type d -exec chmod 0700 {} +
  find "$CONFIG_STAGE" -type f -exec chmod 0600 {} +
  chown -R root:root "$CONFIG_STAGE"
  agent_render_units "$UNIT_STAGE"
  find "$UNIT_STAGE" -type f -exec chmod 0644 {} +
}

cutover() {
  local stamp unit
  stamp="$(date +%Y%m%d%H%M%S)"
  [ -d "$AGENT_RUNTIME_DIR" ] && PREVIOUS_INSTALL=1
  [ -d "$AGENT_CONFIG_DIR" ] && HAD_CONFIG=1
  UNIT_BACKUP="/etc/systemd/system/.dbdog-agent-units-before-$stamp"
  install -d -o root -g root -m 0700 "$UNIT_BACKUP"
  for unit in "${AGENT_UNITS[@]}"; do
    [ ! -f "/etc/systemd/system/$unit" ] || cp -a "/etc/systemd/system/$unit" "$UNIT_BACKUP/$unit"
    systemctl is-active --quiet "$unit" && PREVIOUS_ACTIVE_UNITS="$PREVIOUS_ACTIVE_UNITS $unit" || true
    systemctl is-enabled --quiet "$unit" && PREVIOUS_ENABLED_UNITS="$PREVIOUS_ENABLED_UNITS $unit" || true
  done

  MUTATION_STARTED=1
  stop_private_units || die "无法完全停止旧 dbdog-agent 私有服务，拒绝切换文件"
  if [ "$RUNTIME_CHANGED" -eq 1 ]; then
    if [ -d "$AGENT_RUNTIME_DIR" ]; then
      OLD_RUNTIME="/opt/.dbdog-agent-before-$stamp"
      [ ! -e "$OLD_RUNTIME" ] || die "回滚目录已存在: $OLD_RUNTIME"
      mv -- "$AGENT_RUNTIME_DIR" "$OLD_RUNTIME"
    fi
    mv -- "$RUNTIME_STAGE" "$AGENT_RUNTIME_DIR"
    RUNTIME_STAGE=""
  fi

  install -d -o root -g root -m 0755 "$AGENT_LOG_DIR"
  install -d -o root -g root -m 0700 "$AGENT_RUN_DIR"
  rm -f -- "$AGENT_RUN_DIR/sysprobe.sock" "$AGENT_RUN_DIR/system-probe.pid" \
    "$AGENT_RUN_DIR/process-agent.pid" "$AGENT_RUN_DIR/trace-agent.pid"

  if [ -d "$AGENT_CONFIG_DIR" ]; then
    OLD_CONFIG="/etc/.dbdog-agent-before-$stamp"
    [ ! -e "$OLD_CONFIG" ] || die "回滚目录已存在: $OLD_CONFIG"
    mv -- "$AGENT_CONFIG_DIR" "$OLD_CONFIG"
  fi
  mv -- "$CONFIG_STAGE" "$AGENT_CONFIG_DIR"
  CONFIG_STAGE=""

  for unit in "${AGENT_UNITS[@]}"; do
    install -o root -g root -m 0644 "$UNIT_STAGE/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
  for unit in "${AGENT_UNITS[@]}"; do systemctl enable "$unit" >/dev/null; done
}

wait_active() { # <unit> <seconds>
  local unit="$1" limit="$2" i
  for ((i=1; i<=limit; i++)); do
    systemctl is-active --quiet "$unit" && return 0
    sleep 1
  done
  systemctl status "$unit" --no-pager >&2 || true
  return 1
}

wait_socket() { # <path> <seconds>
  local path="$1" limit="$2" i
  for ((i=1; i<=limit; i++)); do [ -S "$path" ] && return 0; sleep 1; done
  return 1
}

wait_agent_readiness() { # <diagnostic output> <wall-clock deadline seconds>
  local output="$1" limit="$2" attempt_output start_seconds elapsed remaining
  local command_timeout rc sleep_seconds unit
  attempt_output="$(mktemp "$WORK_DIR/agent-health-attempt.XXXXXX")"
  : >"$output"
  chmod 0600 "$output"
  start_seconds=$SECONDS
  AGENT_HEALTH_WAIT_ATTEMPTS=0
  AGENT_HEALTH_WAIT_ELAPSED=0
  AGENT_HEALTH_WAIT_REASON="deadline-exceeded"

  while :; do
    elapsed=$((SECONDS - start_seconds))
    [ "$elapsed" -lt "$limit" ] || break
    remaining=$((limit - elapsed))
    command_timeout=5
    [ "$remaining" -ge "$command_timeout" ] || command_timeout="$remaining"
    AGENT_HEALTH_WAIT_ATTEMPTS=$((AGENT_HEALTH_WAIT_ATTEMPTS + 1))
    : >"$attempt_output"
    if timeout "$command_timeout" "$AGENT_RUNTIME_DIR/bin/agent/agent" health \
      -c "$AGENT_CONFIG_DIR" >"$attempt_output" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    elapsed=$((SECONDS - start_seconds))
    AGENT_HEALTH_WAIT_ELAPSED="$elapsed"
    printf '\n===== readiness attempt %s at %s elapsed=%ss command_timeout=%ss rc=%s =====\n' \
      "$AGENT_HEALTH_WAIT_ATTEMPTS" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
      "$elapsed" "$command_timeout" "$rc" >>"$output"
    cat "$attempt_output" >>"$output"
    if [ "$rc" -eq 0 ] && \
      grep -Eq '^=== [1-9][0-9]* healthy components ===$' "$attempt_output"; then
      AGENT_HEALTH_WAIT_REASON="ready"
      return 0
    fi

    for unit in "${AGENT_UNITS[@]}"; do
      if ! systemctl is-active --quiet "$unit"; then
        AGENT_HEALTH_WAIT_REASON="unit-inactive:$unit"
        printf '\nunit became inactive while waiting for readiness: %s\n' "$unit" >>"$output"
        return 1
      fi
    done

    elapsed=$((SECONDS - start_seconds))
    AGENT_HEALTH_WAIT_ELAPSED="$elapsed"
    [ "$elapsed" -lt "$limit" ] || break
    remaining=$((limit - elapsed))
    sleep_seconds=2
    [ "$remaining" -ge "$sleep_seconds" ] || sleep_seconds="$remaining"
    [ "$sleep_seconds" -gt 0 ] || break
    sleep "$sleep_seconds"
  done
  AGENT_HEALTH_WAIT_ELAPSED=$((SECONDS - start_seconds))
  return 1
}

capture_agent_unit_snapshot() { # <output> <require live generation: 0|1>; unit<TAB>MainPID<TAB>NRestarts<TAB>InvocationID
  local output="$1" require_generation="$2" unit state pid restarts invocation
  : >"$output"
  chmod 0600 "$output"
  for unit in "${AGENT_UNITS[@]}"; do
    state="$(systemctl show "$unit" --no-pager -p MainPID -p NRestarts -p InvocationID)" || return 1
    pid="$(awk -F= '$1 == "MainPID" { print $2; exit }' <<<"$state")"
    restarts="$(awk -F= '$1 == "NRestarts" { print $2; exit }' <<<"$state")"
    invocation="$(awk -F= '$1 == "InvocationID" { print $2; exit }' <<<"$state")"
    [ -n "$invocation" ] || invocation=-
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    if [ "$require_generation" -eq 1 ] && { [ "$pid" -eq 0 ] || [ "$invocation" = - ]; }; then
      return 1
    fi
    case "$restarts" in '' | *[!0-9]*) return 1 ;; esac
    case "$invocation" in *[!0-9A-Fa-f-]*) return 1 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$unit" "$pid" "$restarts" "$invocation" >>"$output"
  done
}

compare_agent_stability_snapshots() { # <pre-start> <all-active> <after> <diagnostic output>
  local baseline="$1" active="$2" after="$3" output="$4"
  local unit active_pid active_restarts active_invocation line
  local baseline_pid baseline_restarts baseline_invocation
  local after_pid after_restarts after_invocation window_restart_delta unstable=0
  local baseline_count active_count after_count
  baseline_count="$(awk 'END { print NR + 0 }' "$baseline")"
  active_count="$(awk 'END { print NR + 0 }' "$active")"
  after_count="$(awk 'END { print NR + 0 }' "$after")"
  printf 'snapshot_counts baseline=%s active=%s after=%s\n' \
    "$baseline_count" "$active_count" "$after_count" >>"$output"
  if [ "$active_count" -eq 0 ] || [ "$baseline_count" -ne "$active_count" ] || \
    [ "$after_count" -ne "$active_count" ]; then
    return 1
  fi
  while IFS=$'\t' read -r unit active_pid active_restarts active_invocation; do
    line="$(awk -F'\t' -v wanted="$unit" '$1 == wanted { print; exit }' "$baseline")"
    if [ -z "$line" ]; then
      printf 'unit missing from pre-start snapshot: %s\n' "$unit" >>"$output"
      unstable=1
      continue
    fi
    IFS=$'\t' read -r _ baseline_pid baseline_restarts baseline_invocation <<<"$line"
    line="$(awk -F'\t' -v wanted="$unit" '$1 == wanted { print; exit }' "$after")"
    if [ -z "$line" ]; then
      printf 'unit missing from final snapshot: %s\n' "$unit" >>"$output"
      unstable=1
      continue
    fi
    IFS=$'\t' read -r _ after_pid after_restarts after_invocation <<<"$line"
    window_restart_delta=$((after_restarts - active_restarts))
    printf '%s baseline_pid=%s active_pid=%s after_pid=%s baseline_restarts=%s active_restarts=%s after_restarts=%s startup_restarts=%s window_restart_delta=%s baseline_invocation=%s active_invocation=%s after_invocation=%s\n' \
      "$unit" "$baseline_pid" "$active_pid" "$after_pid" "$baseline_restarts" \
      "$active_restarts" "$after_restarts" "$active_restarts" "$window_restart_delta" \
      "$baseline_invocation" "$active_invocation" "$after_invocation" >>"$output"
    # cutover 会先完整停止全部私有 unit，因此 all-active 时的非零 NRestarts
    # 属于本次新生命周期；升级前历史计数只作诊断，绝不能跨生命周期相减。
    if [ "$active_restarts" -ne 0 ] || [ "$window_restart_delta" -ne 0 ] || \
      [ "$active_pid" != "$after_pid" ] || \
      [ "$active_invocation" != "$after_invocation" ]; then
      unstable=1
    fi
  done <"$active"
  [ "$unstable" -eq 0 ]
}

verify_agent_stability_window() { # <pre-start snapshot> <all-active snapshot> <diagnostic output>
  local baseline="$1" active="$2" output="$3" after unit
  local elapsed=0 step=5
  after="$(mktemp "$WORK_DIR/agent-units-after.XXXXXX")"
  : >"$output"
  chmod 0600 "$output"
  printf 'stability_window_seconds=35\n' >>"$output"
  while [ "$elapsed" -lt 35 ]; do
    sleep "$step"
    elapsed=$((elapsed + step))
    for unit in "${AGENT_UNITS[@]}"; do
      if ! systemctl is-active --quiet "$unit"; then
        printf 'unit became inactive at +%ss: %s\n' "$elapsed" "$unit" >>"$output"
        systemctl show "$unit" --no-pager -p ActiveState -p SubState -p MainPID \
          -p NRestarts -p Result -p ExecMainCode -p ExecMainStatus >>"$output" 2>&1 || true
        return 1
      fi
    done
  done
  capture_agent_unit_snapshot "$after" 1 || {
    printf 'cannot capture final MainPID/NRestarts/InvocationID snapshot\n' >>"$output"
    return 1
  }
  compare_agent_stability_snapshots "$baseline" "$active" "$after" "$output"
}

agent_log_file_identity() { # <regular non-symlink file>; dev<TAB>inode<TAB>size
  local file="$1" identity dev inode size
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if identity="$(stat -Lc '%d %i %s' -- "$file" 2>/dev/null)"; then
    :
  elif identity="$(stat -f '%d %i %z' "$file" 2>/dev/null)"; then
    # BSD stat is used only by the local shell contract tests; production is Linux.
    :
  else
    return 1
  fi
  read -r dev inode size <<<"$identity"
  case "$dev:$inode:$size" in *[!0-9:]* | :* | *::* | *:) return 1 ;; esac
  printf '%s\t%s\t%s\n' "$dev" "$inode" "$size"
}

agent_log_prefix_tail_signature() { # <file> <prefix size>; SHA-256 of the prefix's final <=4KiB
  local file="$1" prefix_size="$2" sample_size=4096 sample_offset signature
  case "$prefix_size" in '' | *[!0-9]*) return 1 ;; esac
  if [ "$prefix_size" -eq 0 ]; then
    printf '%s\n' empty
    return 0
  fi
  if [ "$prefix_size" -lt "$sample_size" ]; then sample_size="$prefix_size"; fi
  sample_offset=$((prefix_size - sample_size))
  signature="$(od -An -v -j "$sample_offset" -N "$sample_size" -tx1 "$file" 2>/dev/null \
    | tr -d '[:space:]' | agent_sha256_stdin)" || return 1
  [ "${#signature}" -eq 64 ] || return 1
  case "$signature" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$signature"
}

capture_agent_log_cursor() { # <output>; state<TAB>dev<TAB>inode<TAB>size<TAB>prefix-boundary-sha256
  local output="$1" log_file="$AGENT_LOG_DIR/agent.log" identity dev inode size signature
  : >"$output"
  chmod 0600 "$output"
  if [ ! -e "$log_file" ]; then
    printf 'missing\n' >"$output"
    return 0
  fi
  identity="$(agent_log_file_identity "$log_file")" || return 1
  IFS=$'\t' read -r dev inode size <<<"$identity"
  signature="$(agent_log_prefix_tail_signature "$log_file" "$size")" || return 1
  printf 'present\t%s\t%s\t%s\t%s\n' "$dev" "$inode" "$size" "$signature" >"$output"
}

append_agent_log_copytruncate_window() { # <dev> <inode> <size> <signature> <current log> <output>
  local old_dev="$1" old_inode="$2" old_size="$3" old_signature="$4"
  local log_file="$5" output="$6" candidate identity dev inode size signature start_byte
  local found_candidate=0 selected_candidate=""
  # copytruncate keeps agent.log's inode but copies the pre-truncate contents to
  # a different inode. Match that candidate by the cursor boundary SHA, append
  # its post-cursor bytes, then append the current file from byte zero.
  while IFS= read -r -d '' candidate; do
    identity="$(agent_log_file_identity "$candidate")" || continue
    IFS=$'\t' read -r dev inode size <<<"$identity"
    [ "$dev:$inode" != "$old_dev:$old_inode" ] || continue
    [ "$size" -ge "$old_size" ] || continue
    signature="$(agent_log_prefix_tail_signature "$candidate" "$old_size")" || continue
    [ "$signature" = "$old_signature" ] || continue
    found_candidate=$((found_candidate + 1))
    selected_candidate="$candidate"
  done < <(find "$AGENT_LOG_DIR" -xdev -type f -print0 2>/dev/null)
  if [ "$found_candidate" -ne 1 ]; then
    {
      printf 'agent.log cursor_continuity=false: copytruncate rotation candidate count=%s (required=1)\n' \
        "$found_candidate"
      # 旧代际无法唯一证明时不能把验收当作完整，但当前 inode 的内容仍是
      # 本次启动后可见的有用证据；保留它，避免错误报告只剩一条 continuity 提示。
      printf 'agent.log copytruncate current inode contents follow (old generation unproven)\n'
      cat "$log_file"
    } >>"$output"
    return 1
  fi
  start_byte=$((old_size + 1))
  {
    printf 'agent.log copytruncate candidate=%s\n' "$selected_candidate"
    tail -c "+$start_byte" "$selected_candidate"
    printf 'agent.log copytruncate current inode full contents follow\n'
    cat "$log_file"
  } >>"$output"
}

append_agent_log_from_cursor() { # <cursor> <output>; append only bytes created in this validation window
  local cursor="$1" output="$2" log_file="$AGENT_LOG_DIR/agent.log"
  local state old_dev old_inode old_size old_signature identity current_dev current_inode current_size
  local current_signature candidate candidate_identity candidate_dev candidate_inode candidate_size
  local start_byte found_old=0
  IFS=$'\t' read -r state old_dev old_inode old_size old_signature <"$cursor" || return 1
  if [ "$state" = missing ]; then
    if [ -e "$log_file" ]; then
      agent_log_file_identity "$log_file" >/dev/null || return 1
      printf 'agent.log cursor_mode=created_after_validation_start\n' >>"$output"
      cat "$log_file" >>"$output"
    else
      printf 'agent.log does not exist\n' >>"$output"
    fi
    return 0
  fi
  [ "$state" = present ] || return 1
  case "$old_dev:$old_inode:$old_size" in *[!0-9:]* | :* | *::* | *:) return 1 ;; esac
  [ -n "$old_signature" ] || return 1

  if [ ! -e "$log_file" ]; then
    printf 'agent.log disappeared after validation start\n' >>"$output"
    return 1
  fi
  identity="$(agent_log_file_identity "$log_file")" || return 1
  IFS=$'\t' read -r current_dev current_inode current_size <<<"$identity"

  if [ "$current_dev:$current_inode" = "$old_dev:$old_inode" ]; then
    if [ "$current_size" -lt "$old_size" ]; then
      printf 'agent.log cursor_mode=copytruncate current_size=%s previous_size=%s\n' \
        "$current_size" "$old_size" >>"$output"
      append_agent_log_copytruncate_window "$old_dev" "$old_inode" "$old_size" \
        "$old_signature" "$log_file" "$output"
      return
    fi
    current_signature="$(agent_log_prefix_tail_signature "$log_file" "$old_size")" || return 1
    if [ "$current_signature" != "$old_signature" ]; then
      # copytruncate can regrow past the old byte offset before validation ends.
      printf 'agent.log cursor_mode=copytruncate_regrown current_size=%s previous_size=%s\n' \
        "$current_size" "$old_size" >>"$output"
      append_agent_log_copytruncate_window "$old_dev" "$old_inode" "$old_size" \
        "$old_signature" "$log_file" "$output"
      return
    fi
    printf 'agent.log cursor_mode=same_inode_append\n' >>"$output"
    start_byte=$((old_size + 1))
    tail -c "+$start_byte" "$log_file" >>"$output"
    return 0
  fi

  # rename/create rotation: finish the old inode from its original byte cursor,
  # then read the replacement agent.log from byte zero. Never apply the old
  # offset to the replacement inode.
  while IFS= read -r -d '' candidate; do
    candidate_identity="$(agent_log_file_identity "$candidate")" || continue
    IFS=$'\t' read -r candidate_dev candidate_inode candidate_size <<<"$candidate_identity"
    [ "$candidate_dev:$candidate_inode" = "$old_dev:$old_inode" ] || continue
    found_old=1
    [ "$candidate_size" -ge "$old_size" ] || return 1
    current_signature="$(agent_log_prefix_tail_signature "$candidate" "$old_size")" || return 1
    [ "$current_signature" = "$old_signature" ] || return 1
    printf 'agent.log cursor_mode=rename_create old_inode_path=%s\n' "$candidate" >>"$output"
    start_byte=$((old_size + 1))
    tail -c "+$start_byte" "$candidate" >>"$output"
    break
  done < <(find "$AGENT_LOG_DIR" -xdev -type f -inum "$old_inode" -print0 2>/dev/null)
  if [ "$found_old" -ne 1 ]; then
    printf 'agent.log old inode unavailable after rename/create rotation: dev=%s inode=%s\n' \
      "$old_dev" "$old_inode" >>"$output"
    return 1
  fi
  printf 'agent.log replacement inode full contents follow\n' >>"$output"
  cat "$log_file" >>"$output"
}

append_agent_validation_logs() { # <start epoch> <agent.log cursor> <output>
  local since="$1" log_cursor="$2" output="$3" unit journal_tmp journal_rc journal_bytes journal_lines
  local -a journal_args=() pipeline_status=()
  : >"$output"
  chmod 0600 "$output"
  for unit in "${AGENT_UNITS[@]}"; do journal_args+=(-u "$unit"); done
  printf '===== systemd journal since validation start =====\n' >>"$output"
  command -v journalctl >/dev/null 2>&1 || {
    printf 'journal_complete=false reason=journalctl_missing\n' >>"$output"
    return 1
  }
  journal_tmp="$(mktemp "$WORK_DIR/agent-validation-journal.XXXXXX")"
  set +o pipefail
  journalctl "${journal_args[@]}" --since "@$since" -n 1001 -o short-iso \
    --no-pager 2>&1 | head -c 1048577 >"$journal_tmp"
  pipeline_status=("${PIPESTATUS[@]}")
  set -o pipefail
  journal_rc="${pipeline_status[0]}"
  journal_bytes="$(agent_log_file_identity "$journal_tmp" | awk -F'\t' '{ print $3 }')" || return 1
  journal_lines="$(awk 'END { print NR + 0 }' "$journal_tmp")"
  cat "$journal_tmp" >>"$output"
  rm -f -- "$journal_tmp"
  case "$journal_rc" in 0 | 141) ;; *)
    printf 'journal_complete=false reason=journalctl_exit_%s\n' "$journal_rc" >>"$output"
    return 1
    ;;
  esac
  if [ "$journal_bytes" -gt 1048576 ] || [ "$journal_lines" -gt 1000 ]; then
    printf 'journal_complete=false reason=bounded_output_exceeded lines=%s bytes=%s\n' \
      "$journal_lines" "$journal_bytes" >>"$output"
    return 1
  fi
  printf 'journal_complete=true lines=%s bytes=%s\n' "$journal_lines" "$journal_bytes" >>"$output"
  printf '\n===== new agent.log bytes since validation start =====\n' >>"$output"
  append_agent_log_from_cursor "$log_cursor" "$output"
}

agent_validation_has_known_runtime_error() { # <file>...
  local pattern
  pattern="$(agent_known_runtime_error_pattern)"
  grep -Eqi "$pattern" "$@"
}

start_and_verify() {
  local unit health_out="$AGENT_LOG_DIR/install-agent-health.log"
  local config_out="$AGENT_LOG_DIR/install-configcheck.log"
  local config_attempt="$WORK_DIR/configcheck-attempt.out"
  local check_out="$AGENT_LOG_DIR/install-gaussdb-check.log"
  local stability_out="$AGENT_LOG_DIR/install-agent-stability.log"
  local validation_out="$AGENT_LOG_DIR/install-agent-validation.log"
  local baseline_snapshot="$WORK_DIR/agent-units-pre-start.snapshot"
  local active_snapshot="$WORK_DIR/agent-units-all-active.snapshot"
  local agent_log_cursor="$WORK_DIR/agent-log.cursor"
  local validation_start
  validation_start="$(date +%s)"
  capture_agent_log_cursor "$agent_log_cursor" || \
    die "无法记录 Agent 启动前 agent.log 的 dev/inode/size 游标，本次安装会回滚"
  capture_agent_unit_snapshot "$baseline_snapshot" 0 || \
    die "无法记录 Agent 启动前 NRestarts 基线，本次安装会回滚"
  systemctl start dbdog-agent-sysprobe.service
  wait_active dbdog-agent-sysprobe.service 60 || die "system-probe 未能启动"
  wait_socket "$AGENT_RUN_DIR/sysprobe.sock" 90 || die "system-probe socket 未就绪"
  systemctl start dbdog-agent.service
  wait_active dbdog-agent.service 90 || die "Agent Core 未能启动"
  systemctl start dbdog-agent-trace.service dbdog-agent-process.service
  wait_active dbdog-agent-trace.service 90 || die "trace-agent 未能启动"
  wait_active dbdog-agent-process.service 90 || die "process-agent 未能启动"
  capture_agent_unit_snapshot "$active_snapshot" 1 || \
    die "无法记录四个 Agent 单元全部 active 后的 PID/NRestarts，本次安装会回滚"

  local ready=0 i
  # configcheck 通过 Core command API 取配置，不是离线 YAML parser。即使 systemd
  # 已 active，API 仍可能短暂未监听，所以直接保留有限重试与完整诊断。
  : >"$config_out"
  chmod 0600 "$config_out"
  for ((i=1; i<=8; i++)); do
    : >"$config_attempt"
    if timeout 8 "$AGENT_RUNTIME_DIR/bin/agent/agent" configcheck \
      -c "$AGENT_CONFIG_DIR" >"$config_attempt" 2>&1; then
      printf '\n===== configcheck attempt %s: success =====\n' "$i" >>"$config_out"
      cat "$config_attempt" >>"$config_out"
      ready=1
      break
    fi
    printf '\n===== configcheck attempt %s: failed =====\n' "$i" >>"$config_out"
    cat "$config_attempt" >>"$config_out"
    systemctl is-active --quiet dbdog-agent.service || break
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    systemctl status dbdog-agent.service --no-pager >>"$config_out" 2>&1 || true
    die "Agent 配置校验失败；详情留在 ${config_out}，本次安装会回滚"
  fi

  if ! wait_agent_readiness "$health_out" "$AGENT_HEALTH_TIMEOUT_SECONDS"; then
    printf '\n===== systemd units after readiness failure =====\n' >>"$health_out"
    for unit in "${AGENT_UNITS[@]}"; do
      systemctl status "$unit" --no-pager >>"$health_out" 2>&1 || true
    done
    append_agent_validation_logs "$validation_start" "$agent_log_cursor" "$validation_out" || true
    if grep -Eqi '(^|[^0-9])413([^0-9]|$)|payload too large|单批事件数超过上限|请求体超过摄入上限' \
      "$health_out" "$validation_out"; then
      die "Agent forwarder 收到摄入端 413；延长等待不能修复协议拒绝，请升级/检查 dbdog-server 摄入合同。详情留在 ${health_out}"
    fi
    die "Agent readiness 未在 ${AGENT_HEALTH_TIMEOUT_SECONDS} 秒内全部就绪（reason=${AGENT_HEALTH_WAIT_REASON}, attempts=${AGENT_HEALTH_WAIT_ATTEMPTS}, elapsed=${AGENT_HEALTH_WAIT_ELAPSED}s）；查看 ${health_out} 和 ${validation_out}，本次安装会回滚"
  fi

  : >"$check_out"
  chmod 0600 "$check_out"
  local engine
  for engine in gaussdb opengauss postgres; do
    case "$engine" in
      gaussdb) [ -n "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] || continue ;;
      opengauss) [ -n "${AGENT_OPENGAUSS_RENDER_PORTS[*]-}" ] || continue ;;
      postgres) [ -n "${AGENT_PG_PORTS[*]-}" ] || continue ;;
    esac
    printf '\n===== agent check %s =====\n' "$engine" >>"$check_out"
    timeout 180 "$AGENT_RUNTIME_DIR/bin/agent/agent" check "$engine" \
      -c "$AGENT_CONFIG_DIR" >>"$check_out" 2>&1 || \
      die "${engine} check 未通过；详情留在 ${check_out}，本次安装会回滚"
  done
  for unit in "${AGENT_UNITS[@]}"; do
    systemctl is-active --quiet "$unit" || die "验收时服务已退出: $unit"
  done
  if ! verify_agent_stability_window "$baseline_snapshot" "$active_snapshot" "$stability_out"; then
    append_agent_validation_logs "$validation_start" "$agent_log_cursor" "$validation_out" || true
    die "Agent 在本次启动/验收及随后 35 秒稳定窗（至少两个 15s 采集周期）内发生退出/重启；查看 ${stability_out} 和 ${validation_out}，并运行 sudo ${SCRIPT_DIR}/dbdogctl diagnose dbdog-agent；本次安装会回滚"
  fi
  append_agent_validation_logs "$validation_start" "$agent_log_cursor" "$validation_out" || \
    die "无法生成 Agent 验收日志差量；查看 ${validation_out}，本次安装会回滚"
  if agent_validation_has_known_runtime_error "$check_out" "$validation_out"; then
    die "Agent 验收发现已知 GaussDB SQL/metadata 错误或 system-probe EventMonitor panic；查看 ${check_out} 和 ${validation_out}，并运行 sudo ${SCRIPT_DIR}/dbdogctl diagnose dbdog-agent；请修复/升级 Agent，不要手工修改生产库绕过"
  fi
}

agent_preflight_artifact_only() { # <tarball> <version>
  # 只做本机架构产物门禁：下载后的 archive 成员、解包 ELF/ldd/version/provenance。
  # 不写 /opt、/etc，不停 systemd，不碰数据库。
  local package="$1" version="$2" stage
  validate_archive_members "$package"
  stage="$WORK_DIR/preflight-runtime"
  mkdir -p "$stage"
  tar --no-same-owner -xzf "$package" -C "$stage"
  validate_runtime_tree "$stage" "$version"
  log "DBDOG_AGENT_PREFLIGHT_ONLY=1：artifact 门禁通过（version=$version arch=$AGENT_HOST_ARCH）；未改配置、未停服务"
}

main() {
  case "${1:-}" in
    "") ;;
    -h | --help) usage; return 0 ;;
    *) usage >&2; die "不支持的参数: $1" ;;
  esac
  [ "$#" -le 1 ] || { usage >&2; die "参数过多"; }
  require_root_host
  configure_agent_health_timeout
  WORK_DIR="$(mktemp -d /tmp/dbdog-agent-install.XXXXXX)"
  INSTALLER_CONTRACT_SHA256="$(agent_installer_contract_fingerprint "$SCRIPT_DIR")" || \
    die "无法计算 dbdog-agent 安装器合约指纹"

  local version artifact sha256 package old_gauss
  version="$(manifest_get dbdog-agent 5)"
  artifact="$(manifest_get dbdog-agent 6)"
  sha256="$(manifest_get dbdog-agent 7)"
  [ "$version" != - ] || die "dbdog-agent 尚未发布"
  log "dbdog-agent 目标版本: $version"
  package="$(download_artifact "$artifact" "$sha256")"
  if [ "${DBDOG_AGENT_PREFLIGHT_ONLY:-}" = "1" ]; then
    agent_preflight_artifact_only "$package" "$version"
    INSTALL_SUCCEEDED=1
    return 0
  fi
  validate_archive_members "$package"
  prepare_runtime "$package" "$version" "$sha256"

  resolve_inputs
  old_gauss="$AGENT_CONFIG_DIR/conf.d/gaussdb.d/conf.yaml"
  AGENT_EXISTING_GAUSS_CONFIG="$old_gauss"
  export AGENT_EXISTING_GAUSS_CONFIG
  # 零 gaussdb 进程不再直接 die：openGauss 主进程同名会进 gauss 检测链（随后分类分流），
  # 纯 PostgreSQL 主机则由 agent_detect_postgres 兜住；「一个受支持引擎都没有」才是硬失败。
  AGENT_GAUSS_ALLOW_NONE=1
  agent_detect_gaussdb
  agent_detect_postgres
  agent_classify_gauss_engines
  agent_assemble_engine_credentials
  [ -n "${AGENT_GAUSS_PORTS[*]-}" ] || [ -n "${AGENT_PG_PORTS[*]-}" ] || \
    die "未发现任何受支持的运行中数据库实例（GaussDB/openGauss/PostgreSQL）"
  [ -z "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] || \
    log "发现 GaussDB 端口: ${AGENT_GAUSSDB_RENDER_PORTS[*]}（日志: ${AGENT_GAUSS_LOG_GLOBS[*]-}）"
  [ -z "${AGENT_OPENGAUSS_RENDER_PORTS[*]-}" ] || \
    log "发现 openGauss 端口: ${AGENT_OPENGAUSS_RENDER_PORTS[*]}（日志: ${AGENT_OPENGAUSS_LOG_GLOBS[*]-}）"
  [ -z "${AGENT_PG_PORTS[*]-}" ] || \
    log "发现 PostgreSQL 端口: ${AGENT_PG_PORTS[*]}（日志: ${AGENT_PG_LOG_GLOBS[*]-}）"
  fetch_server_bootstrap
  preflight_gaussdb_clients
  render_install_state
  cutover
  install_dbm_init_scripts
  agent_require_probe_credentials
  bootstrap_gaussdb_monitoring
  start_and_verify

  # marker 是事务提交记录。屏蔽可捕获信号覆盖“原子写入 → 提交内存状态”的极短窗口：
  # SIGKILL 若落在该窗口，磁盘上的 runtime/config/services 已经完整验收，marker 仍然真实。
  trap '' INT TERM HUP
  if ! write_installer_contract_marker; then
    trap 'exit 130' INT TERM HUP
    die "无法写入 dbdog-agent 安装器合约 marker"
  fi
  INSTALL_SUCCEEDED=1
  MUTATION_STARTED=0
  trap 'exit 130' INT TERM HUP
  log "dbdog-agent $version 安装/升级并验收通过"
  local enabled_engines=""
  [ -z "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] || enabled_engines="GaussDB"
  [ -z "${AGENT_OPENGAUSS_RENDER_PORTS[*]-}" ] || enabled_engines="${enabled_engines:+$enabled_engines/}openGauss"
  [ -z "${AGENT_PG_PORTS[*]-}" ] || enabled_engines="${enabled_engines:+$enabled_engines/}PostgreSQL"
  log "已启用：${enabled_engines} DBM（含 database_autodiscovery）、日志、主机指标、Live Processes、NPM/USM、APM/OpenLineage、Remote Config"
  [ -z "$OLD_RUNTIME" ] || log "上一 runtime 回滚副本: $OLD_RUNTIME"
  [ -z "$OLD_CONFIG" ] || log "上一配置回滚副本: $OLD_CONFIG"
  log "日常状态: systemctl status dbdog-agent dbdog-agent-process dbdog-agent-trace dbdog-agent-sysprobe"
  log "一键诊断: sudo ${SCRIPT_DIR}/dbdogctl diagnose dbdog-agent"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
