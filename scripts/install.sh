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

install_modules() {
  for m in "$@"; do "$SCRIPTS_DIR/upgrade.sh" "$m"; done
}

gen_clickhouse_config() {
  local cfg="$ETC_DIR/clickhouse/config.xml"
  [ -f "$cfg" ] && return 0
  mkdir -p "$ETC_DIR/clickhouse" "$DATA_DIR/clickhouse"
  cat >"$cfg" <<EOF
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
  cat >"$ETC_DIR/clickhouse/users.xml" <<'EOF'
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
  log "已生成 $cfg（默认仅本机访问、default 用户空密码）"
}

init_databases() {
  local pgbin="$MODULES_DIR/postgresql/current/bin"
  [ -x "$pgbin/initdb" ] || die "postgresql 模块未安装（先 upgrade.sh postgresql）"

  if [ ! -d "$DATA_DIR/pg" ]; then
    log "初始化 PostgreSQL 数据目录"
    "$pgbin/initdb" -D "$DATA_DIR/pg" -E UTF8 --no-locale
    # [首跑校准] 如需远程访问/改端口，编辑 data/pg/postgresql.conf、pg_hba.conf
  fi
  gen_clickhouse_config

  "$DBDOGCTL" start postgresql clickhouse
  sleep 2
  "$pgbin/createdb" -h 127.0.0.1 ctl 2>/dev/null && log "已创建 PG 库 ctl" || log "PG 库 ctl 已存在"
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
    ensure_layout; init_databases ;;
  --finish)
    run_migrations
    "$DBDOGCTL" start all
    echo; "$DBDOGCTL" status all ;;
  "")
    ensure_layout
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
