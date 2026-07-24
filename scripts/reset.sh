#!/usr/bin/env bash
# 逃生门重建：删库重建初始化。会清空 PG(ctl) 与 ClickHouse(obs) 的全部数据：
# 租户、API key、dashboard、全部监控历史。仅用于升级损坏或确认无法增量的场合。
# 用法：reset.sh --yes-i-mean-it

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "${1:-}" = "--yes-i-mean-it" ] || die "这是删库重建。确认请执行: reset.sh --yes-i-mean-it"

log "停止全部服务"
"$SCRIPTS_DIR/dbdogctl" stop all

log "删除数据目录: $DATA_DIR/pg $DATA_DIR/clickhouse"
rm -rf "$DATA_DIR/pg" "$DATA_DIR/clickhouse"

log "重新初始化"
"$SCRIPTS_DIR/install.sh" --init-db-only
"$SCRIPTS_DIR/install.sh" --finish

log "重建完成。租户/API key/agent 对接需重新配置。"
