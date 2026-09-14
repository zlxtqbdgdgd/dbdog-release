#!/usr/bin/env bash
# 逃生门重建：删库重建初始化。会清空 PG（ctl、dbdog_benchweb）与 ClickHouse(obs) 的全部数据：
# 租户、API key、dashboard、全部监控历史，以及 benchweb 的用例、复现记录与落盘文件。
# 仅用于升级损坏或确认无法增量的场合。
# 用法：./scripts/reset.sh --yes-i-mean-it

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "${1:-}" = "--yes-i-mean-it" ] || die "这是删库重建。确认请执行: ./scripts/reset.sh --yes-i-mean-it"

log "停止全部服务"
"$SCRIPTS_DIR/dbdogctl" stop all

# benchweb 的用例文件/复现日志与它在 PG 里的元数据是一体的：库清了而文件留着，列表为空、
# 同编号重新推送时却撞上旧文件，所以同进同退。
log "删除数据目录: $DATA_DIR/pg $DATA_DIR/clickhouse $DATA_DIR/dbdog-benchweb"
rm -rf "$DATA_DIR/pg" "$DATA_DIR/clickhouse" "$DATA_DIR/dbdog-benchweb"

log "重新初始化"
"$SCRIPTS_DIR/install.sh" --init-db-only
"$SCRIPTS_DIR/install.sh" --finish

log "重建完成。租户/API key/agent 对接需重新配置。"
