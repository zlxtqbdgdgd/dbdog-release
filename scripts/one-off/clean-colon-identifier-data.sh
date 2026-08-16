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
# **写入侧不止 agent（2026-08-16 补）**：profiling 面的写入者是 ddprof 的 systemd 单元
# （`-T database_instance:<v>`，见 dbdog-agent/dbdog-deploy/systemd/dbdog-profiled-*.service），
# 与 DBM 的 conf.d 模板是两套东西。08-06 只切了 agent 模板、漏了这些单元，于是 profiles /
# profile_metrics 的冒号行删掉后立刻被 ddprof 写回来——直到 08-16 才被发现（agent 拿
# find_dbdog_database_instances 的横线标识查 profiling 面 0 行，误判「本实例无 profiling 数据」）。
# 跑本脚本前先确认这些单元已换成横线形并重部署：
#   sh dbdog-agent/dbdog-deploy/scripts/test-profiling-instance-identifier.sh
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
# ── 2026-08-07 再修：默认值把自己坑了 ────────────────────────────────────────────
# 内网实证暴露三类环境假设错误，其中两类是**静默**的：
#   1. 默认 CH 库 obs / PG schema public，而多租户环境的数据在 obs_t_1 / t_1 ——
#      所有 count() 返回 0、note 不打印、报「合计 0 行」。清理工具静默空转比报错更危险。
#      现在查不到候选表就 fail closed，并列出实际有数据的库/schema。
#   2. ${CH_PASSWORD:?} 强制非空，而内网 CH default 用户是无密码（空密码可连、非空反而
#      认证失败），导致脚本根本跑不起来且无法绕过。改为 ${CH_PASSWORD-}。
#   3. prod.env / psql 只认开发机布局，内网是 ~/dbdog/ 布局。改为按序探测。
#
# TTL 提示：metric_points 的 TTL 是 **15 天**（原注释写「1 天」是错的，实测
# `TTL toDateTime(ts) + toIntervalDay(15)`）。所以别指望它很快自然过期——内网实测
# 3.33 亿行冒号数据横跨 9 天，按 15 天算要留到两周后。要不要用 EXCLUDE 跳过它，
# 得按当下数据量和 mutation 代价现算。metric_points_5m 的 TTL 是 455 天，不清会留一年多。

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

# ── 环境定位：两套部署布局 ──────────────────────────────────────────────────────
# 开发机是 /home/dbdogt/dev/（prod.env + 自带 pgsql），内网 stack 是 ~/dbdog/
# （etc/dbdog-server.env + modules/postgresql/current/bin/psql）。原版只认前者，
# 在内网直接死在「找不到 prod.env」（2026-08-07 实证）。
DBDOG_HOME="${DBDOG_HOME:-$HOME/dbdog}"
ENV_FILE="${PROD_ENV:-}"
if [ -z "$ENV_FILE" ]; then
  for candidate in "$DBDOG_HOME/etc/dbdog-server.env" /home/dbdogt/dev/prod.env; do
    [ -f "$candidate" ] || continue
    ENV_FILE="$candidate"
    break
  done
fi
[ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] \
  || die "找不到 server 配置（可用 PROD_ENV= 指定）：试过 $DBDOG_HOME/etc/dbdog-server.env 与 /home/dbdogt/dev/prod.env"
# 命令行传进来的覆盖必须赢过配置文件——`set -a; . file` 会把调用者的值冲掉，
# 于是「用 DBDOG_CH_DATABASE= 指定后重跑」这类提示根本不生效（实测）。先存后覆。
_override_ch_db="${DBDOG_CH_DATABASE:-}"
_override_pg_schema="${DBDOG_PG_SCHEMA:-}"
_override_ch_user="${DBDOG_CH_USERNAME:-}"
_override_ch_password="${CH_PASSWORD+set:$CH_PASSWORD}"
_override_pg_dsn="${PG_DSN:-}"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
# stack 布局把租户面的两个关键值放在 ddsql-server.env 里（CH_DATABASE=obs_t_N、
# DBDOG_PG_SCHEMA=t_N），dbdog-server.env 里没有——verify.sh 也是同时 load 两个才拿得到。
# 少读这一个，就会退回 obs/public 默认值，正是内网那次静默空转的来源。
DDSQL_ENV="${DDSQL_ENV:-${ENV_FILE%/*}/ddsql-server.env}"
if [ -f "$DDSQL_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DDSQL_ENV"
  printf '配置来源: %s + %s\n' "$ENV_FILE" "$DDSQL_ENV"
else
  printf '配置来源: %s\n' "$ENV_FILE"
fi
set +a
[ -n "$_override_ch_db" ] && DBDOG_CH_DATABASE="$_override_ch_db"
[ -n "$_override_pg_schema" ] && DBDOG_PG_SCHEMA="$_override_pg_schema"
[ -n "$_override_ch_user" ] && DBDOG_CH_USERNAME="$_override_ch_user"
[ -n "$_override_pg_dsn" ] && PG_DSN="$_override_pg_dsn"
# CH_PASSWORD 要区分「没传」和「显式传空串」，所以用 ${VAR+...} 记录是否定义过。
case "$_override_ch_password" in set:*) CH_PASSWORD="${_override_ch_password#set:}" ;; esac

# CH 口令：内网 default 用户是**无密码**（空密码可连，任意非空反而认证失败），
# 所以这里不能用 ${CH_PASSWORD:?} 强制非空——那会让无密码环境根本跑不起来，
# 且没有不改代码的绕过方式（2026-08-07 实证）。用 ${VAR-} 只在「未定义」时兜底，
# 显式设成空串同样有效。
CH_DB="${DBDOG_CH_DATABASE:-${CH_DATABASE:-obs}}"
CH_USER="${DBDOG_CH_USERNAME:-${CH_USERNAME:-default}}"
CH_PASSWORD="${CH_PASSWORD-}"
ch() { curl -sS -u "$CH_USER:$CH_PASSWORD" "http://127.0.0.1:8123/" --data-binary "$1"; }

PG_SCHEMA="${DBDOG_PG_SCHEMA:-public}"
if [ -z "${PSQL:-}" ]; then
  for candidate in "$DBDOG_HOME/modules/postgresql/current/bin/psql" \
    /home/dbdogt/dev/pgsql/bin/psql; do
    [ -x "$candidate" ] || continue
    PSQL="$candidate"
    break
  done
fi
[ -n "${PSQL:-}" ] || PSQL="$(command -v psql || true)"
[ -n "$PSQL" ] && [ -x "$PSQL" ] || die "找不到 psql（可用 PSQL= 指定）"
pg() { "$PSQL" "$PG_SCHEMA_DSN" -At -F$'\t' -c "$1"; }
PG_SCHEMA_DSN="${PG_DSN:?配置里没有 PG_DSN}"

printf 'ClickHouse 库: %s    PostgreSQL schema: %s    psql: %s\n' "$CH_DB" "$PG_SCHEMA" "$PSQL"

# ── 目标库/schema 合理性：查不到候选表就停下，绝不静默打印 0 ────────────────────
# 这是本脚本最危险的失效方式：多租户环境里数据在 obs_t_1 / t_1，而默认值是 obs / public，
# 于是所有 count() 返回 0、一行 note 都不打印、最后报「合计 0 行」——看到的人会以为
# 没有冒号数据就走了。2026-08-07 内网实证：默认值下报 0，实际 CH 25 张表、PG 2773 行。
ch_table_count="$(ch "SELECT count() FROM system.tables
  WHERE database = '$CH_DB' AND engine LIKE '%MergeTree%' FORMAT TSV")"
if [ "${ch_table_count:-0}" -eq 0 ]; then
  printf '\nClickHouse 库 %s 里没有任何 MergeTree 表。实际有数据的库：\n' "$CH_DB" >&2
  ch "SELECT database, count() FROM system.tables WHERE engine LIKE '%MergeTree%'
      GROUP BY database ORDER BY database FORMAT TSV" >&2
  die "目标 CH 库不对，用 DBDOG_CH_DATABASE= 指定后重跑（多租户环境通常是 obs_t_<租户号>）"
fi
pg_table_count="$(pg "SELECT count(*) FROM information_schema.columns
  WHERE column_name = 'database_instance' AND table_schema = '$PG_SCHEMA'")"
printf '候选表: CH %s 张 MergeTree，PG %s 张带 database_instance\n' "$ch_table_count" "$pg_table_count"

# 「本 schema 里有没有那些表」抓不住多租户错配——public 里同样建了这些表（server 级
# migration 的公共镜像），只是没数据。真正的信号是「这里报 0，而别处有」，所以放到
# 统计完之后再判（见下方 total==0 分支）。
other_schema_colon_rows() { # 回显 "<schema> <表> <行数>"，只看非目标 schema
  local sch tbl n
  while IFS=$'\t' read -r sch tbl; do
    [ -n "$sch" ] || continue
    [ "$sch" = "$PG_SCHEMA" ] && continue
    n="$(pg "SELECT count(*) FROM \"$sch\".\"$tbl\" WHERE database_instance LIKE '%:%'")"
    [ "${n:-0}" -gt 0 ] && printf '%s\t%s\t%s\n' "$sch" "$tbl" "$n"
  done < <(pg "SELECT table_schema, table_name FROM information_schema.columns
               WHERE column_name = 'database_instance'
                 AND table_schema NOT IN ('information_schema','pg_catalog')
               ORDER BY table_schema, table_name")
}

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

# 报 0 是本脚本最危险的输出：看到的人会以为没有冒号数据就走了，而实际可能只是
# 指错了库/schema（2026-08-07 内网实证：默认 obs/public 报 0，真实数据 CH 25 张表、
# PG 2773 行都在 obs_t_1/t_1）。所以报 0 时主动去别处找一遍，找到就大声说并非零退出。
if [ "$total" -eq 0 ]; then
  found_elsewhere=0
  printf '\n本次目标里一行都没有。正在确认别处是否有冒号数据 ...\n'
  while IFS=$'\t' read -r sch tbl n; do
    [ -n "$sch" ] || continue
    found_elsewhere=1
    printf '  其它 schema: %s.%s  %s 行\n' "$sch" "$tbl" "$n" >&2
  done < <(other_schema_colon_rows)
  ch_other="$(ch "SELECT database, count() FROM system.tables
      WHERE engine LIKE '%MergeTree%' AND database NOT IN ('$CH_DB','system')
      GROUP BY database ORDER BY database FORMAT TSV")"
  if [ -n "$ch_other" ]; then
    printf '  其它 CH 库（含 MergeTree 表，未逐表统计）:\n' >&2
    printf '%s\n' "$ch_other" | sed 's/^/    /' >&2
  fi
  if [ "$found_elsewhere" -eq 1 ] || [ -n "$ch_other" ]; then
    die "目标可能指错了：本次的 $CH_DB / $PG_SCHEMA 是空的，但别处有数据。用 DBDOG_CH_DATABASE= / DBDOG_PG_SCHEMA= 指定后重跑（多租户环境通常是 obs_t_<N> / t_<N>）"
  fi
  printf '别处也没有，确认干净。\n'
fi

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
