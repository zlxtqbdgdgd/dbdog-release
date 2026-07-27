#!/usr/bin/env bash
# 内网：全家桶机器首次安装（dbdog 账户执行，无 root）。
# 用法：
#   install.sh                # 一键安装、配置、迁移、启动并验收
#   install.sh --finish       # 兼容旧版未完成安装：补配置、迁移、启动并验收
#   install.sh --init-db-only # 只做数据目录初始化（reset.sh 复用）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBDOGCTL="$SCRIPTS_DIR/dbdogctl"

BASE_MODULES=(node goose postgresql clickhouse)
APP_MODULES=(dbdog-server dbdog-web dbdog-mcp)

preflight_host() {
  local arch cmd
  arch="$(uname -m)"
  [ "$arch" = "aarch64" ] || die "仅支持 aarch64，当前架构: $arch"
  for cmd in id git curl tar awk grep find install mktemp readlink file ldd env; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少必需命令: $cmd"
  done
  [ "$(id -un)" = "dbdog" ] || die "请用专用 dbdog 账户执行，当前用户: $(id -un)"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "缺少 sha256sum/shasum"
}

install_modules() {
  for m in "$@"; do "$SCRIPTS_DIR/upgrade.sh" "$m"; done
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

configure_ready_to_use_stack() {
  local server_env="$ETC_DIR/dbdog-server.env"
  local web_env="$ETC_DIR/dbdog-web.env"
  local mcp_env="$ETC_DIR/dbdog-mcp.env"
  local internal_token oauth_secret advertise_host app_url ingest_url mcp_url

  configure_local_database_clients
  internal_token="$(choose_shared_secret DBDOG_INTERNAL_TOKEN "$server_env" "$web_env" "$mcp_env")"
  oauth_secret="$(choose_shared_secret DBDOG_OAUTH_JWT_SECRET "$web_env" "$mcp_env")"
  advertise_host="$(detect_advertise_host)"
  app_url="http://${advertise_host}:3000"
  ingest_url="http://${advertise_host}:8080"
  mcp_url="http://${advertise_host}:8090/mcp"

  ensure_env_default "$server_env" DBDOG_INTERNAL_TOKEN "$internal_token" change-me
  ensure_env_default "$server_env" DBDOG_HTTP_ADDR :8080 change-me
  ensure_env_default "$server_env" DBDOG_PUBLIC_BASE_URL "$app_url" change-me

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

  log "已生成可直接使用的本机配置（访问地址: ${app_url}；已有真实配置保持不变）"
}

finish_installation() {
  configure_ready_to_use_stack
  "$DBDOGCTL" start postgresql clickhouse \
    || die "数据库未全部启动就绪；未执行迁移或启动应用服务"
  run_migrations
  "$DBDOGCTL" start all || die "服务未全部启动；本次新启动的服务已回滚"
  "$SCRIPTS_DIR/verify.sh"
  echo
  "$DBDOGCTL" status all
}

gen_clickhouse_config() {
  local cfg="$ETC_DIR/clickhouse/config.xml"
  local users="$ETC_DIR/clickhouse/users.xml"
  local cfg_tmp="$cfg.tmp" users_tmp="$users.tmp"
  if [ -f "$cfg" ]; then
    if [ ! -s "$users" ] || ! grep -q '</clickhouse>' "$cfg" || ! grep -q '</clickhouse>' "$users"; then
      die "ClickHouse 配置不完整，请检查 $cfg 与 $users"
    fi
    chmod 700 "$ETC_DIR/clickhouse"
    chmod 600 "$cfg"
    chmod 600 "$users"
    return 0
  fi
  mkdir -p "$ETC_DIR/clickhouse" "$DATA_DIR/clickhouse"
  rm -f "$cfg_tmp" "$users_tmp"
  cat >"$cfg_tmp" <<EOF
<!-- 由 install.sh 生成的最小配置；只监听本机。[首跑校准] 端口/内存按需调 -->
<clickhouse>
    <logger>
        <level>information</level>
        <log>$LOGS_DIR/clickhouse.log</log>
        <errorlog>$LOGS_DIR/clickhouse.err.log</errorlog>
    </logger>
    <listen_host>127.0.0.1</listen_host>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <path>$DATA_DIR/clickhouse/</path>
    <tmp_path>$DATA_DIR/clickhouse/tmp/</tmp_path>
    <user_files_path>$DATA_DIR/clickhouse/user_files/</user_files_path>
    <user_directories>
        <users_xml><path>$ETC_DIR/clickhouse/users.xml</path></users_xml>
    </user_directories>
    <mark_cache_size>536870912</mark_cache_size>
</clickhouse>
EOF
  cat >"$users_tmp" <<'EOF'
<clickhouse>
    <users>
        <default>
            <password></password>
            <networks><ip>127.0.0.1</ip><ip>::1</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
    </users>
    <profiles><default/></profiles>
    <quotas><default/></quotas>
</clickhouse>
EOF
  chmod 700 "$ETC_DIR/clickhouse"
  chmod 600 "$cfg_tmp" "$users_tmp"
  mv "$users_tmp" "$users"
  mv "$cfg_tmp" "$cfg"
  log "已生成 ${cfg}（默认仅本机访问、default 用户空密码）"
}

init_databases() {
  local pgbin="$MODULES_DIR/postgresql/current/bin"
  local ctl_exists
  [ -x "$pgbin/initdb" ] || die "postgresql 模块未安装（先 upgrade.sh postgresql）"

  if [ -d "$DATA_DIR/pg" ]; then
    [ -s "$DATA_DIR/pg/PG_VERSION" ] && [ -f "$DATA_DIR/pg/postgresql.conf" ] \
      && [ -f "$DATA_DIR/pg/pg_hba.conf" ] && [ -d "$DATA_DIR/pg/base" ] \
      || die "PostgreSQL 数据目录是不完整的初始化残留: $DATA_DIR/pg（先检查后移走，再重跑）"
  else
    log "初始化 PostgreSQL 数据目录"
    "$pgbin/initdb" -D "$DATA_DIR/pg" -E UTF8 --no-locale
    # [首跑校准] 如需远程访问/改端口，编辑 data/pg/postgresql.conf、pg_hba.conf
  fi
  gen_clickhouse_config

  # dbdogctl 对两项服务做稳定 PID + SQL 就绪检查，并在部分启动失败时只回滚
  # 本次新拉起的服务。两库全部就绪前，不创建任何逻辑数据库。
  "$DBDOGCTL" start postgresql clickhouse \
    || die "数据库未全部启动就绪；未继续创建 ctl/obs，请查看 $LOGS_DIR 下数据库日志"

  if ! ctl_exists="$("$pgbin/psql" -h 127.0.0.1 -d postgres -Atqc \
      "SELECT 1 FROM pg_database WHERE datname = 'ctl'")"; then
    die "查询 PG 数据库列表失败；未继续初始化逻辑数据库"
  fi
  case "$ctl_exists" in
    1) log "PG 库 ctl 已存在" ;;
    "")
      "$pgbin/createdb" -h 127.0.0.1 ctl || die "创建 PG 库 ctl 失败"
      log "已创建 PG 库 ctl"
      ;;
    *) die "PG 数据库列表返回了意外结果: $ctl_exists" ;;
  esac

  if ! "$MODULES_DIR/clickhouse/current/bin/clickhouse" client --host 127.0.0.1 \
      --query "CREATE DATABASE IF NOT EXISTS obs"; then
    die "创建 ClickHouse 数据库 obs 失败；可修复后安全重跑初始化"
  fi
  log "已确保 CH 库 obs"
}

run_migrations() {
  # 重跑各应用模块 current 的 pre-switch 钩子（内部即 goose up / drizzle 迁移，幂等）
  for m in dbdog-server dbdog-web; do
    local cur="$MODULES_DIR/$m/current"
    [ -L "$cur" ] || die "缺少应用模块 current，无法执行迁移: $m"
    DBDOG_MIGRATION_REQUIRED=1 run_hook "$cur" pre-switch
  done
}

main() {
case "${1:-}" in
  --init-db-only)
    preflight_host; ensure_layout; init_databases ;;
  --finish)
    preflight_host; ensure_layout
    finish_installation ;;
  "")
    preflight_host; ensure_layout
    log "== 1/5 安装基础件: ${BASE_MODULES[*]}"
    install_modules "${BASE_MODULES[@]}"
    log "== 2/5 初始化数据库"
    init_databases
    log "== 3/5 安装应用件: ${APP_MODULES[*]}"
    install_modules "${APP_MODULES[@]}"
    log "== 4/5 自动配置、迁移并启动"
    finish_installation
    log "== 5/5 安装完成"
    ;;
  *) die "用法: install.sh [--finish|--init-db-only]" ;;
esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
