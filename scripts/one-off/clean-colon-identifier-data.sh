#!/usr/bin/env bash
# 一次性：清掉 database_instance 里还带冒号的历史数据。
#
# 用法（在 dbdog-server 所在机器上跑，需能读 prod.env）：
#   clean-colon-identifier-data.sh [--apply]      # 不带 --apply 只统计、不删
#   EXCLUDE='metric_points' clean-colon-identifier-data.sh --apply   # 跳过指定表（空格分隔）
#
# 背景：2026-08-06 起 agent 的 database_identifier 模板由 `$resolved_hostname:$port`
# 改为 `-$port`（`:` 是 DD 查询语法的 key/value 分隔符，标识里带它会让「按实例过滤」必须整体
# 加引号——round-19 实证：裸写 database_instance:<host>:<port> 的调用 104 次、98% 报错，而
# skill 教的 service:<engine> 写法 80 次仅 4% 报错）。切换后同一实例会出现新旧两个标识，
# 图表/看板按实例分组时会裂成两条。
#
# 为什么直接删而不是改写：这是**开发中的内网环境**（owner 2026-08-06 确认两套环境的数据
# 都可清理）。改写要动 ORDER BY 键、代价与风险都高于重采；删掉后按新标识重新积累即可。
#
# 一次性代码：全部环境切完就该删掉本脚本，别留成常驻工具。
#
# 顺序铁律：**先换模板 + 重启 agent，再跑本脚本**。反过来会先删完、agent 又按旧模板写回来。
# **多主机注意**：每台被采集的 DB 主机都要先切完。漏掉一台就会把那台的当前数据当历史删掉，
# 且它立刻按旧模板写回来（2026-08-06 干跑即撞上：GaussDB 那台还没切，占 22864 行）。
#
# ── 2026-08-07 重写：原版漏了四类地方，报「全部为 0」时其实还剩约 5800 万行 ──────────
# 原版只找「列名叫 instance 的 MergeTree 表」+ 手工特判 events，于是漏掉：
#   1. 列名叫 database_instance 的表（profile_metrics、profiles）
#   2. tags 是 Map 的表，标识藏在 tags['database_instance'] 里（metric_points 5117 万、
#      metric_points_5m 706 万）——注释里明明写着「metric_points 用 tags」，代码却没做
#   3. 标签字典 metric_tag_index（tag_key/tag_value 两列形态）
#   4. **整个 PostgreSQL 面**：租户 schema 里 7 张表共 3821 行（dbm_settings 2326、
#      dataobs_assets 1241、dbm_schema_objects 128、dbm_recommendations 87、
#      dbm_extensions 33、dbm_collection_configs 3、dbm_instances 3）
# 教训：表清单一律由 information_schema / system.columns **推导**，任何手写清单都会随
# schema 演进而悄悄失配，且失配时脚本照样打印「0」，比报错更难发现。
#
# TTL 提示：metric_points 的 TTL 只有 1 天，冒号数据会自然过期，通常不值得为它跑一次
# 五千万行的 mutation（用 EXCLUDE 跳过即可）。metric_points_5m 的 TTL 是 455 天，不清会留一年多。

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
EXCLUDE="${EXCLUDE:-}"

excluded() {
  local t="$1" e
  for e in $EXCLUDE; do [ "$e" = "$t" ] && return 0; done
  return 1
}

ENV_FILE="${PROD_ENV:-/home/dbdogt/dev/prod.env}"
[ -f "$ENV_FILE" ] || die "找不到 prod.env（可用 PROD_ENV= 指定）: $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

CH_DB="${DBDOG_CH_DATABASE:-obs}"
CH_USER="${DBDOG_CH_USERNAME:-default}"
: "${CH_PASSWORD:?prod.env 里没有 CH_PASSWORD}"
ch() { curl -sS -u "$CH_USER:$CH_PASSWORD" "http://127.0.0.1:8123/" --data-binary "$1"; }

PG_SCHEMA="${DBDOG_PG_SCHEMA:-public}"
PSQL="${PSQL:-/home/dbdogt/dev/pgsql/bin/psql}"
pg() { "$PSQL" "$PG_SCHEMA_DSN" -At -F$'\t' -c "$1"; }
PG_SCHEMA_DSN="${PG_DSN:?prod.env 里没有 PG_DSN}"

printf 'ClickHouse 库: %s    PostgreSQL schema: %s\n' "$CH_DB" "$PG_SCHEMA"

# ── 目标推导 ────────────────────────────────────────────────────────────────────
# 只取真实表：system.columns 也会列出 View（如 dbm_activity_read），对 View 跑
# ALTER … DELETE 会直接报错。用 system.tables.engine 过滤掉非 MergeTree 家族。

# A. 标量标识列：列名 instance 或 database_instance
ch_scalar() {
  ch "SELECT c.table, c.name FROM system.columns AS c
      INNER JOIN system.tables AS t ON t.database = c.database AND t.name = c.table
      WHERE c.database = '$CH_DB' AND c.name IN ('instance','database_instance')
        AND t.engine LIKE '%MergeTree'
      ORDER BY c.table, c.name FORMAT TSV"
}
# B. tags 是 Map 的表：标识在 tags['database_instance']。类型可能是
#    Map(...) 或 SimpleAggregateFunction(anyLast, Map(...))，故用 %Map(% 而非 Map%。
ch_tagmap() {
  ch "SELECT c.table FROM system.columns AS c
      INNER JOIN system.tables AS t ON t.database = c.database AND t.name = c.table
      WHERE c.database = '$CH_DB' AND c.name = 'tags' AND c.type LIKE '%Map(%'
        AND t.engine LIKE '%MergeTree'
      ORDER BY c.table FORMAT TSV"
}
# C. 标签字典：同时有 tag_key / tag_value 两列
ch_tagindex() {
  ch "SELECT c.table FROM system.columns AS c
      INNER JOIN system.tables AS t ON t.database = c.database AND t.name = c.table
      WHERE c.database = '$CH_DB' AND c.name = 'tag_value' AND t.engine LIKE '%MergeTree'
      ORDER BY c.table FORMAT TSV"
}
# D. PG 面：租户 schema 里带 database_instance 列的表。
#    刻意排除数组列 database_instances（dbm_query_optimizations）——一行可关联多个实例，
#    「数组里含冒号形」不等于「整行该删」，删了会连带毁掉同行其它实例的记录。
pg_tables() {
  pg "SELECT table_name FROM information_schema.columns
      WHERE column_name = 'database_instance' AND table_schema = '$PG_SCHEMA'
      ORDER BY table_name"
}

total=0
note() { printf '  %-30s %-20s %s\n' "$1" "$2" "$3"; total=$((total + $3)); }

printf '\n== ClickHouse：标量标识列 ==\n'
while IFS=$'\t' read -r t c; do
  [ -n "$t" ] || continue
  n="$(ch "SELECT count() FROM $CH_DB.$t WHERE position($c, ':') > 0 FORMAT TSV")"
  [ "${n:-0}" -gt 0 ] && note "$t" "$c" "$n"
done < <(ch_scalar)

printf '\n== ClickHouse：tags map ==\n'
while read -r t; do
  [ -n "$t" ] || continue
  n="$(ch "SELECT count() FROM $CH_DB.$t WHERE position(tags['database_instance'], ':') > 0 FORMAT TSV")"
  [ "${n:-0}" -gt 0 ] && note "$t" "tags[...]" "$n"
done < <(ch_tagmap)

printf '\n== ClickHouse：标签字典 ==\n'
while read -r t; do
  [ -n "$t" ] || continue
  n="$(ch "SELECT count() FROM $CH_DB.$t WHERE tag_key = 'database_instance' AND position(tag_value, ':') > 0 FORMAT TSV")"
  [ "${n:-0}" -gt 0 ] && note "$t" "tag_value" "$n"
done < <(ch_tagindex)

printf '\n== PostgreSQL：%s schema ==\n' "$PG_SCHEMA"
while read -r t; do
  [ -n "$t" ] || continue
  n="$(pg "SELECT count(*) FROM $PG_SCHEMA.$t WHERE database_instance LIKE '%:%'")"
  [ "${n:-0}" -gt 0 ] && note "$t" "database_instance" "$n"
done < <(pg_tables)

printf '\n合计 %s 行\n' "$total"
[ -n "$EXCLUDE" ] && printf '（EXCLUDE 跳过: %s）\n' "$EXCLUDE"

if [ "$APPLY" -ne 1 ]; then
  printf '\n（未加 --apply，只统计，什么都没删）\n'
  exit 0
fi

printf '\n== 开始删除（CH 的 ALTER … DELETE 是异步 mutation，提交后用 system.mutations 看进度） ==\n'
while IFS=$'\t' read -r t c; do
  [ -n "$t" ] || continue
  excluded "$t" && { printf '  跳过(EXCLUDE): %s.%s\n' "$t" "$c"; continue; }
  ch "ALTER TABLE $CH_DB.$t DELETE WHERE position($c, ':') > 0" >/dev/null
  printf '  已提交: %s.%s\n' "$t" "$c"
done < <(ch_scalar)

while read -r t; do
  [ -n "$t" ] || continue
  excluded "$t" && { printf '  跳过(EXCLUDE): %s.tags\n' "$t"; continue; }
  ch "ALTER TABLE $CH_DB.$t DELETE WHERE position(tags['database_instance'], ':') > 0" >/dev/null
  printf '  已提交: %s.tags\n' "$t"
done < <(ch_tagmap)

while read -r t; do
  [ -n "$t" ] || continue
  excluded "$t" && { printf '  跳过(EXCLUDE): %s\n' "$t"; continue; }
  ch "ALTER TABLE $CH_DB.$t DELETE WHERE tag_key = 'database_instance' AND position(tag_value, ':') > 0" >/dev/null
  printf '  已提交: %s\n' "$t"
done < <(ch_tagindex)

# PG 是同步删除，放在一个事务里
pg_sql=""
while read -r t; do
  [ -n "$t" ] || continue
  excluded "$t" && { printf '  跳过(EXCLUDE): %s.%s\n' "$PG_SCHEMA" "$t"; continue; }
  pg_sql+="DELETE FROM $PG_SCHEMA.$t WHERE database_instance LIKE '%:%'; "
done < <(pg_tables)
if [ -n "$pg_sql" ]; then
  "$PSQL" "$PG_SCHEMA_DSN" -v ON_ERROR_STOP=1 -c "BEGIN; $pg_sql COMMIT;" >/dev/null
  printf '  已删除(PG, 事务): %s\n' "$PG_SCHEMA"
fi

printf '\nCH 进度: SELECT table, is_done, parts_to_do, latest_fail_reason FROM system.mutations WHERE database='"'"'%s'"'"' AND is_done=0\n' "$CH_DB"
