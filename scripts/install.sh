#!/usr/bin/env bash
# 内网：全家桶机器首次安装（dbdog 账户执行，无 root）。
# 用法：
#   install.sh                # 完整引导：装基础件+初始化库+装应用件，最后提示填配置
#   install.sh --finish       # 配置填好后：跑数据库迁移 + 启动全部服务
#   install.sh --init-db-only # 只做数据目录初始化（reset.sh 复用）
#
# 注：本脚本按设计一次写成，内网首跑大概率要校准（标 [首跑校准] 处）。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBDOGCTL="$SCRIPTS_DIR/dbdogctl"

BASE_MODULES=(node goose postgresql clickhouse)
APP_MODULES=(dbdog-server dbdog-web dbdog-mcp)

preflight_host() {
  local arch cmd
  arch="$(uname -m)"
  [ "$arch" = "aarch64" ] || die "仅支持 aarch64，当前架构: $arch"
  for cmd in id git curl tar awk grep find install mktemp readlink; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少必需命令: $cmd"
  done
  [ "$(id -un)" = "dbdog" ] || die "请用专用 dbdog 账户执行，当前用户: $(id -un)"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "缺少 sha256sum/shasum"
}

install_modules() {
  for m in "$@"; do "$SCRIPTS_DIR/upgrade.sh" "$m"; done
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

wait_for_databases() {
  local pgbin="$MODULES_DIR/postgresql/current/bin"
  local chbin="$MODULES_DIR/clickhouse/current/bin/clickhouse"
  local i

  for ((i=1; i<=30; i++)); do
    "$pgbin/pg_isready" -h 127.0.0.1 -d postgres >/dev/null 2>&1 && break
    sleep 1
  done
  [ "$i" -le 30 ] || die "PostgreSQL 30 秒内未就绪，查看 $LOGS_DIR/postgresql.log"

  for ((i=1; i<=30; i++)); do
    "$chbin" client --host 127.0.0.1 --query "SELECT 1" >/dev/null 2>&1 && break
    sleep 1
  done
  [ "$i" -le 30 ] || die "ClickHouse 30 秒内未就绪，查看 $LOGS_DIR/clickhouse.err.log"
}

init_databases() {
  local pgbin="$MODULES_DIR/postgresql/current/bin"
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

  "$DBDOGCTL" start postgresql clickhouse
  wait_for_databases
  if "$pgbin/psql" -h 127.0.0.1 -d postgres -Atqc \
      "SELECT 1 FROM pg_database WHERE datname = 'ctl'" | grep -qx 1; then
    log "PG 库 ctl 已存在"
  else
    "$pgbin/createdb" -h 127.0.0.1 ctl || die "创建 PG 库 ctl 失败"
    log "已创建 PG 库 ctl"
  fi
  "$MODULES_DIR/clickhouse/current/bin/clickhouse" client --host 127.0.0.1 \
    --query "CREATE DATABASE IF NOT EXISTS obs" && log "已确保 CH 库 obs"
}

run_migrations() {
  # 重跑各应用模块 current 的 pre-switch 钩子（内部即 goose up / drizzle 迁移，幂等）
  for m in dbdog-server dbdog-web; do
    local cur="$MODULES_DIR/$m/current"
    [ -L "$cur" ] && run_hook "$cur" pre-switch
  done
}

case "${1:-}" in
  --init-db-only)
    preflight_host; ensure_layout; init_databases ;;
  --finish)
    preflight_host; ensure_layout
    "$DBDOGCTL" start postgresql clickhouse
    wait_for_databases
    run_migrations
    "$DBDOGCTL" start all
    echo; "$DBDOGCTL" status all ;;
  "")
    preflight_host; ensure_layout
    log "== 1/4 安装基础件: ${BASE_MODULES[*]}"
    install_modules "${BASE_MODULES[@]}"
    log "== 2/4 初始化数据库"
    init_databases
    log "== 3/4 安装应用件: ${APP_MODULES[*]}"
    install_modules "${APP_MODULES[@]}"
    log "== 4/4 剩下的事"
    echo
    echo "请编辑 $ETC_DIR/ 下各 .env（连接串、密钥等），然后执行："
    echo "    $SCRIPTS_DIR/install.sh --finish"
    ;;
  *) die "用法: install.sh [--finish|--init-db-only]" ;;
esac
