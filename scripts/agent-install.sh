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

AGENT_UNITS=(
  dbdog-agent-sysprobe.service
  dbdog-agent.service
  dbdog-agent-trace.service
  dbdog-agent-process.service
)

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

usage() {
  cat <<'EOF'
用法：sudo ./scripts/agent-install.sh

首次安装需要两个外部值；可通过环境变量传入，终端执行时缺失项会安全提示输入：
  DBDOG_SERVER_URL                       dbdog-server origin，例如 http://10.0.0.8:8080
  DBDOG_API_KEY                          dbdog-web 签发的 Agent ingest key

可选覆盖（正常情况下自动发现或使用稳定默认值）：
  DBDOG_GAUSSDB_MONITOR_PASSWORD         默认首次生成、升级保留
  DBDOG_GAUSSDB_ENV_FILE                 显式 GaussDB 客户端环境文件（绝对路径）
  DBDOG_GAUSSDB_PGHOST                   仅安装期 gsql 使用的本地 Unix socket 目录
  DBDOG_GAUSSDB_LD_LIBRARY_PATH           显式 gsql 动态库搜索路径
  DBDOG_GAUSSDB_PORT                     仅在无法从运行进程发现时使用
  DBDOG_GAUSSDB_LOG_GLOB                 仅在无法从 GAUSSLOG 发现时使用
  DBDOG_GAUSSDB_DBNAME                   默认 postgres
  DBDOG_GAUSSDB_DEPLOYMENT               centralized 或 distributed
  DBDOG_ENV                              默认 prod
  DBDOG_AGENT_HOSTNAME                   默认 hostname -s

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
  local arch
  [ "$EUID" -eq 0 ] || die "请用 sudo 运行；安装需要写 /opt、/etc 和 systemd"
  arch="$(uname -m)"
  [ "$arch" = aarch64 ] || [ "$arch" = arm64 ] || die "dbdog-agent 产物仅支持 aarch64，当前为 $arch"
  [ -d /run/systemd/system ] || die "当前主机不是运行中的 systemd 环境"
  local command
  for command in awk bash cat chmod chown cmp cp curl env file find grep hostname install ldd \
    mktemp mv od readlink rm runuser sed sort systemctl tar timeout tr; do
    command -v "$command" >/dev/null 2>&1 || die "缺少安装依赖命令: $command"
  done
  [ -x /usr/bin/timeout ] || die "systemd 单元需要 /usr/bin/timeout"
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

agent_hba_has_dbdog_trust() { # <HBA 文件>
  awk '
    /^[[:space:]]*#/ { next }
    {
      kind=tolower($1); user=$3
      method=(kind == "local" ? tolower($4) : tolower($5))
      gsub(/^"|"$/, "", user)
      count=split(user, users, ",")
      for (i=1; i<=count; i++) {
        gsub(/^"|"$/, "", users[i])
        if ((users[i] == "dbdog" || users[i] == "all") && method == "trust") found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

preflight_gaussdb_clients() {
  local index count gsql ldd_bin out value mode hba
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ "$count" -gt 0 ] || die "安装验收要求 GaussDB 正在运行"
  log "预检目标 GaussDB 的 gsql 动态库、版本、本地连接和认证兼容性 ..."
  for ((index=0; index<count; index++)); do
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
    ! agent_hba_has_dbdog_trust "$hba" || die \
      "GaussDB HBA 含 dbdog trust 规则；请 DBA 删除该规则并按数据库规范重新加载。dbdog 安装器不会修改 pg_hba.conf: $hba"
    agent_hba_has_required_tcp_md5 "$hba" || die \
      "GaussDB HBA 缺少受支持的本机认证规则：host all dbdog 127.0.0.1/32 md5；请 DBA 添加并按数据库规范重新加载。dbdog 安装器不会修改 pg_hba.conf: $hba"
  done
}

agent_monitor_password_works() { # 经 127.0.0.1 TCP 验证密码；0=有效，2=明确拒绝，1=基础设施失败
  local index="$1" password="$2" python password_file out attempt rc success=0 rejected=0
  local timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  python="${DBDOG_AGENT_PYTHON:-$AGENT_RUNTIME_DIR/embedded/bin/python3}"
  [ -x "$python" ] && [ -x "$timeout_bin" ] || return 1
  password_file="$WORK_DIR/monitor-password.$index"
  printf '%s' "$password" >"$password_file" || return 1
  chmod 0600 "$password_file" || return 1
  out="$WORK_DIR/gsql-monitor-auth.$index.out"
  for ((attempt=1; attempt<=5; attempt++)); do
    : >"$out"
    rc=0
    "$timeout_bin" --kill-after=2 10 /usr/bin/env -i \
      PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$python" -I - "$password_file" "${AGENT_GAUSS_PID_PORTS[$index]}" \
      "$DBDOG_GAUSSDB_DBNAME" >"$out" 2>&1 <<'PY' || rc=$?
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
    warn "实例索引 ${index} 当前生效的 127.0.0.1 TCP 认证不是 MD5；请 DBA 核对 HBA 顺序并确认配置已重新加载"
    return 1
  fi
}

agent_prepare_gaussdb_user() { # <密码>；创建用户或验证已有用户凭证
  local password="$1" escaped sql="$WORK_DIR/set-gaussdb-password.sql"
  local index count exists mode reset=0 password_status
  escaped="$(agent_sql_literal "$password")" || return 1
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ "$count" -gt 0 ] || return 1
  for ((index=0; index<count; index++)); do
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
        password_status=0
        agent_monitor_password_works "$index" "$password" || password_status=$?
        case "$password_status" in
          0)
            printf 'ALTER USER dbdog WITH MONADMIN;\n' >"$sql" || return 1
            ;;
          2)
            warn "实例索引 ${index} 已存在 dbdog 用户，但已保存密码无法经 127.0.0.1 TCP + MD5 登录；安装器不会擅自重置已有数据库账号，请核对 /etc/dbdog-agent 配置或由 DBA 处理后重跑"
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
      if ! agent_monitor_password_works "$index" "$password"; then
        warn "实例索引 ${index} 已设置 dbdog 密码，但标准 libpq 仍无法经 127.0.0.1 TCP + MD5 登录"
        return 1
      fi
    fi
    agent_active_auth_is_md5 "$index" || return 1
    reset=0
  done
}

bootstrap_gaussdb_monitoring() {
  local sql="$SCRIPT_DIR/agent/init-gaussdb-perdb.sql" index count
  [ -f "$sql" ] || die "缺少 GaussDB 兼容对象 SQL: $sql"
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ "$count" -gt 0 ] || die "安装验收要求 GaussDB 正在运行"
  log "使用目标机 GAUSSHOME/gsql 幂等准备 dbdog 监控账号与兼容视图（仅安装阶段）..."
  # password_encryption_type 与 HBA 已在预检中只读核对。这里仅创建/校验账号，
  # 并用交付给 integration 的同一凭证经内嵌 psycopg/libpq 做真实 TCP 登录探测。
  agent_prepare_gaussdb_user "$DBDOG_GAUSSDB_MONITOR_PASSWORD" || \
    die "无法通过目标 GaussDB 的本地管理连接准备监控用户"
  for ((index=0; index<count; index++)); do
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
  local env_bin timeout_bin version_output version_rc=0 label reported_version separator details
  local json_version build_binary_sha version_binary_sha build_text_sha version_text_sha
  local build_json_sha version_json_sha build_output_sha version_output_sha actual_output_sha value
  [ -f "$tree/.install_root" ] || die "Agent runtime 缺少 .install_root"
  [ "$(build_field "$info" product)" = dbdog-agent ] || die "Agent provenance product 错误"
  [ "$(build_field "$info" version)" = "$expected_version" ] || die "Agent provenance version 错误"
  [ "$(build_field "$info" compiled_agent_version)" = "$expected_version" ] || \
    die "Agent provenance compiled_agent_version 与 manifest 版本不一致"
  [ "$(build_field "$info" architecture)" = aarch64 ] || die "Agent provenance architecture 错误"
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
    file "$tree/$bin" | grep -Eq 'ELF 64-bit LSB.*(ARM aarch64|aarch64)' || \
      die "Agent 二进制不是 Linux AArch64: $bin"
  done
  while IFS= read -r -d '' link; do
    resolved="$(readlink -m "$link")"
    case "$resolved" in "$tree" | "$tree"/*) ;; *) die "Agent runtime 符号链接越界: $link" ;; esac
  done < <(find "$tree" -type l -print0)

  # 必须执行即将切换的那一个 binary；空环境避免误用同机官方 Agent、用户 PATH 或
  # LD_LIBRARY_PATH。麒麟构建的稳定格式为 `Agent <release> - Commit: ...`，其中
  # version token 必须完整相等，不能用前缀匹配让 .3 接受 .30/7.79 等版本。
  env_bin="$(command -v env 2>/dev/null || true)"
  timeout_bin="${DBDOG_TIMEOUT_BIN:-/usr/bin/timeout}"
  [ -n "$env_bin" ] && [ -x "$timeout_bin" ] || \
    die "缺少 Agent version 最小环境所需的 env/timeout"
  version_output="$("$timeout_bin" --kill-after=2 30 "$env_bin" -i \
    PATH=/usr/bin:/bin LANG=C LC_ALL=C "$tree/bin/agent/agent" version 2>&1)" || version_rc=$?
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

start_and_verify() {
  local unit health_out="$AGENT_LOG_DIR/install-agent-health.log"
  local config_out="$AGENT_LOG_DIR/install-configcheck.log"
  local config_attempt="$WORK_DIR/configcheck-attempt.out"
  local check_out="$AGENT_LOG_DIR/install-gaussdb-check.log"
  systemctl start dbdog-agent-sysprobe.service
  wait_active dbdog-agent-sysprobe.service 60 || die "system-probe 未能启动"
  wait_socket "$AGENT_RUN_DIR/sysprobe.sock" 90 || die "system-probe socket 未就绪"
  systemctl start dbdog-agent.service
  wait_active dbdog-agent.service 90 || die "Agent Core 未能启动"
  systemctl start dbdog-agent-trace.service dbdog-agent-process.service
  wait_active dbdog-agent-trace.service 90 || die "trace-agent 未能启动"
  wait_active dbdog-agent-process.service 90 || die "process-agent 未能启动"

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

  ready=0
  : >"$health_out"
  chmod 0600 "$health_out"
  for ((i=1; i<=10; i++)); do
    if timeout 5 "$AGENT_RUNTIME_DIR/bin/agent/agent" health \
      -c "$AGENT_CONFIG_DIR" >"$health_out" 2>&1 && \
      grep -Eq '^=== [1-9][0-9]* healthy components ===$' "$health_out"; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    systemctl status dbdog-agent.service --no-pager >>"$health_out" 2>&1 || true
    die "Agent forwarder health 未在 60 秒内就绪；详情留在 ${health_out}"
  fi

  : >"$check_out"
  chmod 0600 "$check_out"
  timeout 180 "$AGENT_RUNTIME_DIR/bin/agent/agent" check gaussdb \
    -c "$AGENT_CONFIG_DIR" >"$check_out" 2>&1 || \
    die "GaussDB check 未通过；详情留在 ${check_out}，本次安装会回滚"
  for unit in "${AGENT_UNITS[@]}"; do
    systemctl is-active --quiet "$unit" || die "验收时服务已退出: $unit"
  done
}

main() {
  case "${1:-}" in
    "") ;;
    -h | --help) usage; return 0 ;;
    *) usage >&2; die "不支持的参数: $1" ;;
  esac
  [ "$#" -le 1 ] || { usage >&2; die "参数过多"; }
  require_root_host
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
  validate_archive_members "$package"
  prepare_runtime "$package" "$version" "$sha256"

  resolve_inputs
  old_gauss="$AGENT_CONFIG_DIR/conf.d/gaussdb.d/conf.yaml"
  AGENT_EXISTING_GAUSS_CONFIG="$old_gauss"
  export AGENT_EXISTING_GAUSS_CONFIG
  agent_detect_gaussdb
  log "发现 GaussDB 端口: ${AGENT_GAUSS_PORTS[*]}"
  log "发现 GaussDB 日志: ${AGENT_GAUSS_LOG_GLOBS[*]}"
  fetch_server_bootstrap
  preflight_gaussdb_clients
  render_install_state
  cutover
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
  log "已启用：GaussDB DBM、schema/settings/activity、日志、主机指标、Live Processes、NPM/USM、APM/OpenLineage、Remote Config"
  [ -z "$OLD_RUNTIME" ] || log "上一 runtime 回滚副本: $OLD_RUNTIME"
  [ -z "$OLD_CONFIG" ] || log "上一配置回滚副本: $OLD_CONFIG"
  log "日常状态: systemctl status dbdog-agent dbdog-agent-process dbdog-agent-trace dbdog-agent-sysprobe"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
