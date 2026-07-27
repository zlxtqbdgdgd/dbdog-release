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
PREVIOUS_DB_PASSWORD=""
DB_PASSWORD_CHANGED=0
PREVIOUS_ACTIVE_UNITS=""
PREVIOUS_ENABLED_UNITS=""

usage() {
  cat <<'EOF'
用法：sudo ./scripts/agent-install.sh

首次安装需要两个外部值；可通过环境变量传入，终端执行时缺失项会安全提示输入：
  DBDOG_SERVER_URL                       dbdog-server origin，例如 http://10.0.0.8:8080
  DBDOG_API_KEY                          dbdog-web 签发的 Agent ingest key

可选覆盖（正常情况下自动发现或使用稳定默认值）：
  DBDOG_GAUSSDB_MONITOR_PASSWORD         默认首次生成、升级保留
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
  if [ "$rc" -ne 0 ] && [ "$DB_PASSWORD_CHANGED" -eq 1 ] && \
    [ -n "$PREVIOUS_DB_PASSWORD" ]; then
    warn "恢复安装前的 GaussDB 监控用户密码"
    if ! agent_set_gaussdb_password "$PREVIOUS_DB_PASSWORD"; then
      warn "GaussDB 监控用户密码自动恢复失败，请立即人工核对"
    fi
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
  for command in awk chmod chown cp curl file find grep hostname install mktemp mv od \
    readlink rm runuser sed sort systemctl tar timeout tr; do
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

generate_agent_secret() {
  od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]'
}

resolve_inputs() {
  local old_datadog="$AGENT_CONFIG_DIR/datadog.yaml"
  local old_gauss="$AGENT_CONFIG_DIR/conf.d/gaussdb.d/conf.yaml"
  local old

  PREVIOUS_DB_PASSWORD="$(agent_existing_gauss_scalar "$old_gauss" password 2>/dev/null || true)"

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
    DBDOG_GAUSSDB_MONITOR_PASSWORD="$(generate_agent_secret)"
    log "已生成 GaussDB dbdog 监控用户随机密码（只写入 root 0600 配置）"
  fi

  DBDOG_SERVER_URL="$(agent_validate_server_url "$DBDOG_SERVER_URL")"
  agent_require_single_line DBDOG_API_KEY "$DBDOG_API_KEY"
  agent_require_single_line DBDOG_GAUSSDB_MONITOR_PASSWORD "$DBDOG_GAUSSDB_MONITOR_PASSWORD"
  [ -n "$DBDOG_API_KEY" ] || die "DBDOG_API_KEY 不能为空"
  [ -n "$DBDOG_GAUSSDB_MONITOR_PASSWORD" ] || die "GaussDB 监控密码不能为空"
  case "$DBDOG_API_KEY" in *[!A-Za-z0-9._-]*) die "DBDOG_API_KEY 含不支持的字符" ;; esac

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
  RC_ROOT_JSON="$(compact_json_file "$rc_root")" || die "Remote Config trust root 非法"
  case "$RC_ROOT_JSON" in *$'\n'* | *$'\r'*) die "Remote Config trust root 含换行" ;; esac
}

agent_sql_literal() { # SQL 单引号字面量内容（调用方负责外层引号）
  agent_require_single_line "SQL value" "$1"
  printf '%s' "$1" | sed "s/'/''/g"
}

agent_gsql() { # <进程索引> [gsql 参数...]；stdin 可传 SQL
  local index="$1" home owner port gsql
  shift
  home="${AGENT_GAUSS_PID_HOMES[$index]}"
  owner="${AGENT_GAUSS_PID_OWNERS[$index]}"
  port="${AGENT_GAUSS_PID_PORTS[$index]}"
  [ -n "$home" ] || die "无法从 gaussdb 进程确定 GAUSSHOME"
  [ -n "$owner" ] || die "无法从 gaussdb 进程确定运行用户"
  gsql="$home/bin/gsql"
  [ -x "$gsql" ] || die "目标 GaussDB 没有可执行 gsql: $gsql"
  runuser -u "$owner" -- env \
    GAUSSHOME="$home" \
    LD_LIBRARY_PATH="$home/lib" \
    PATH="$home/bin:/usr/bin:/bin" \
    "$gsql" -q -A -t -v ON_ERROR_STOP=1 -p "$port" \
    -d "$DBDOG_GAUSSDB_DBNAME" "$@"
}

agent_set_gaussdb_password() { # <密码>；所有发现实例上设置同一个 dbdog MONADMIN 密码
  local password="$1" escaped sql="$WORK_DIR/set-gaussdb-password.sql" index count exists
  escaped="$(agent_sql_literal "$password")"
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ "$count" -gt 0 ] || return 1
  for ((index=0; index<count; index++)); do
    exists="$(agent_gsql "$index" -c \
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_user WHERE usename='dbdog') THEN 1 ELSE 0 END;" \
      | awk 'NF { value=$0 } END { print value }')" || return 1
    case "$exists" in
      0) printf "SET password_encryption_type = 1;\nCREATE USER dbdog WITH MONADMIN PASSWORD '%s';\n" "$escaped" >"$sql" ;;
      1) printf "SET password_encryption_type = 1;\nALTER USER dbdog WITH MONADMIN PASSWORD '%s';\n" "$escaped" >"$sql" ;;
      *) die "无法判断 GaussDB 监控用户是否存在（实例索引 $index）" ;;
    esac
    chmod 0600 "$sql"
    agent_gsql "$index" <"$sql" || return 1
  done
}

agent_install_hba_rule() { # <进程索引>
  local index="$1" data hba backup temp reload
  data="${AGENT_GAUSS_PID_DATA_DIRS[$index]}"
  hba="$(agent_gsql "$index" -c 'SHOW hba_file;' 2>/dev/null \
    | awk 'NF { value=$0 } END { print value }' || true)"
  if [ -z "$hba" ] && [ -n "$data" ]; then hba="$data/pg_hba.conf"; fi
  [ -n "$hba" ] || die "无法确定 GaussDB HBA 文件"
  case "$hba" in /*) ;; *) [ -n "$data" ] && hba="$data/$hba" ;; esac
  hba="$(readlink -f "$hba" 2>/dev/null || true)"
  [ -f "$hba" ] || die "GaussDB HBA 不是普通文件: $hba"
  backup="$WORK_DIR/pg_hba.$index.before"
  cp -a -- "$hba" "$backup"
  temp="$(mktemp "$(dirname "$hba")/.dbdog-pg-hba.XXXXXX")"
  if ! awk '
    BEGIN {
      skip=0
      print "# dbdog-release BEGIN: local Agent monitor"
      print "host all dbdog 127.0.0.1/32 md5"
      print "# dbdog-release END: local Agent monitor"
    }
    $0 == "# dbdog-release BEGIN: local Agent monitor" { skip=1; next }
    $0 == "# dbdog-release END: local Agent monitor" { skip=0; next }
    !skip { print }
  ' "$hba" >"$temp"; then
    rm -f -- "$temp"
    die "生成 GaussDB HBA 配置失败"
  fi
  chown --reference="$hba" "$temp"
  chmod --reference="$hba" "$temp"
  mv -- "$temp" "$hba"
  command -v restorecon >/dev/null 2>&1 && restorecon "$hba" >/dev/null 2>&1 || true
  reload="$(agent_gsql "$index" -c 'SELECT pg_reload_conf();' 2>/dev/null \
    | awk 'NF { value=$0 } END { print value }' || true)"
  if [ "$reload" != t ] && [ "$reload" != true ] && [ "$reload" != 1 ]; then
    cp -a -- "$backup" "$hba"
    agent_gsql "$index" -c 'SELECT pg_reload_conf();' >/dev/null 2>&1 || true
    die "GaussDB HBA reload 失败，已恢复原文件"
  fi
}

bootstrap_gaussdb_monitoring() {
  local sql="$SCRIPT_DIR/agent/init-gaussdb-perdb.sql" index count
  [ -f "$sql" ] || die "缺少 GaussDB 兼容对象 SQL: $sql"
  count="${#AGENT_GAUSS_PID_PORTS[@]}"
  [ "$count" -gt 0 ] || die "安装验收要求 GaussDB 正在运行"
  log "使用目标机 GAUSSHOME/gsql 幂等准备 dbdog 监控账号与兼容视图（仅安装阶段）..."
  if [ -n "$PREVIOUS_DB_PASSWORD" ] && \
    [ "$PREVIOUS_DB_PASSWORD" != "$DBDOG_GAUSSDB_MONITOR_PASSWORD" ]; then
    DB_PASSWORD_CHANGED=1
  fi
  agent_set_gaussdb_password "$DBDOG_GAUSSDB_MONITOR_PASSWORD" || \
    die "无法通过目标 GaussDB 的本地管理连接准备监控用户"
  for ((index=0; index<count; index++)); do
    agent_gsql "$index" <"$sql" || die "创建 GaussDB 兼容视图失败（实例索引 $index）"
    agent_install_hba_rule "$index"
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
  for required in ./.install_root ./provenance/build.txt ./provenance/gaussdb.txt \
    ./bin/agent/agent ./embedded/bin/trace-loader ./embedded/bin/trace-agent \
    ./embedded/bin/process-agent ./embedded/bin/system-probe; do
    grep -Fqx "$required" "$list" || die "Agent tarball 缺少: $required"
  done
  if grep -Eq '^\./(embedded/)?bin/(gsql|gaussdb)$' "$list"; then
    die "Agent tarball 不应打包目标 GaussDB 的 gsql/gaussdb 二进制"
  fi
}

build_field() { # <文件> <key>
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); found=1 } END { exit !found }' "$1"
}

validate_runtime_tree() { # <目录> <manifest version>
  local tree="$1" expected_version="$2" info="$1/provenance/build.txt" bin link resolved
  local integration_info="$1/provenance/gaussdb.txt" module_path distribution_path
  [ -f "$tree/.install_root" ] || die "Agent runtime 缺少 .install_root"
  [ "$(build_field "$info" product)" = dbdog-agent ] || die "Agent provenance product 错误"
  [ "$(build_field "$info" version)" = "$expected_version" ] || die "Agent provenance version 错误"
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
}

prepare_runtime() { # <tarball> <version> <sha>
  local package="$1" version="$2" sha="$3" installed_sha=""
  if [ -f "$AGENT_RUNTIME_DIR/.dbdog-artifact-sha256" ]; then
    installed_sha="$(tr -d '\r\n' <"$AGENT_RUNTIME_DIR/.dbdog-artifact-sha256")"
  fi
  if [ "$installed_sha" = "$sha" ] && [ -x "$AGENT_RUNTIME_DIR/bin/agent/agent" ]; then
    log "Agent runtime 产物 SHA 已一致；本次刷新配置并重新验收"
    RUNTIME_CHANGED=0
    return
  fi

  RUNTIME_STAGE="$(mktemp -d /opt/.dbdog-agent-stage.XXXXXX)"
  log "解包并验证 Agent runtime staging ..."
  tar --no-same-owner -xzf "$package" -C "$RUNTIME_STAGE"
  validate_runtime_tree "$RUNTIME_STAGE" "$version"
  printf '%s\n' "$version" >"$RUNTIME_STAGE/.dbdog-release-version"
  printf '%s\n' "$sha" >"$RUNTIME_STAGE/.dbdog-artifact-sha256"
  chmod 0444 "$RUNTIME_STAGE/.dbdog-release-version" "$RUNTIME_STAGE/.dbdog-artifact-sha256"
  install -d -o root -g root -m 0700 "$RUNTIME_STAGE/run"
  if [ -d "$AGENT_RUN_DIR" ]; then
    cp -a "$AGENT_RUN_DIR/." "$RUNTIME_STAGE/run/"
  fi
  rm -f -- "$RUNTIME_STAGE/run/sysprobe.sock" "$RUNTIME_STAGE/run/system-probe.pid" \
    "$RUNTIME_STAGE/run/process-agent.pid" "$RUNTIME_STAGE/run/trace-agent.pid"
  chown -hR root:root "$RUNTIME_STAGE"
  RUNTIME_CHANGED=1
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
  local unit health_out="$WORK_DIR/agent-health.out" check_out="$AGENT_LOG_DIR/install-gaussdb-check.log"
  systemctl start dbdog-agent-sysprobe.service
  wait_active dbdog-agent-sysprobe.service 60 || die "system-probe 未能启动"
  wait_socket "$AGENT_RUN_DIR/sysprobe.sock" 90 || die "system-probe socket 未就绪"
  systemctl start dbdog-agent.service
  wait_active dbdog-agent.service 90 || die "Agent Core 未能启动"
  systemctl start dbdog-agent-trace.service dbdog-agent-process.service
  wait_active dbdog-agent-trace.service 90 || die "trace-agent 未能启动"
  wait_active dbdog-agent-process.service 90 || die "process-agent 未能启动"

  timeout 30 "$AGENT_RUNTIME_DIR/bin/agent/agent" configcheck \
    -c "$AGENT_CONFIG_DIR" >"$WORK_DIR/configcheck.out" 2>&1 || \
    die "Agent 配置校验失败（不会保留本次切换）"

  local ready=0 i
  for ((i=1; i<=30; i++)); do
    if timeout 10 "$AGENT_RUNTIME_DIR/bin/agent/agent" health \
      -c "$AGENT_CONFIG_DIR" >"$health_out" 2>&1 && \
      grep -Eq '^=== [1-9][0-9]* healthy components ===$' "$health_out"; then
      ready=1
      break
    fi
    sleep 2
  done
  [ "$ready" -eq 1 ] || die "Agent forwarder health 未在 60 秒内就绪"

  : >"$check_out"
  chmod 0600 "$check_out"
  timeout 180 "$AGENT_RUNTIME_DIR/bin/agent/agent" check gaussdb \
    -c "$AGENT_CONFIG_DIR" >"$check_out" 2>&1 || \
    die "GaussDB check 未通过；详情留在 $check_out，本次安装会回滚"
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
  bootstrap_gaussdb_monitoring
  render_install_state
  cutover
  start_and_verify

  INSTALL_SUCCEEDED=1
  MUTATION_STARTED=0
  log "dbdog-agent $version 安装/升级并验收通过"
  log "已启用：GaussDB DBM、schema/settings/activity、日志、主机指标、Live Processes、NPM/USM、APM/OpenLineage、Remote Config"
  [ -z "$OLD_RUNTIME" ] || log "上一 runtime 回滚副本: $OLD_RUNTIME"
  [ -z "$OLD_CONFIG" ] || log "上一配置回滚副本: $OLD_CONFIG"
  log "日常状态: systemctl status dbdog-agent dbdog-agent-process dbdog-agent-trace dbdog-agent-sysprobe"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
