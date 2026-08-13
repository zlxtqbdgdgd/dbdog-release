# clean-colon-identifier-data.sh 环境兼容性问题事实记录

> 本文只记录事实（原始命令输出、脚本代码段、环境配置），不包含结论与修复建议。
> 供外部定位一次性脚本 `scripts/one-off/clean-colon-identifier-data.sh` 在多租户 / 无密码 CH 环境下的兼容性问题。

## 环境

| 项 | 值 |
|----|----|
| 主机 | 10.44.136.167（stack 服务器，aarch64） |
| 连接用户 | dbdog |
| ClickHouse | 26.8.1.184，HTTP :8123，native :9000 |
| ClickHouse 数据库 | `obs`（0 张 MergeTree 表）、`obs_t_1`（25 张 MergeTree 表） |
| ClickHouse 认证 | default 用户，**无密码**（`curl -u "default:"` 可连；`curl -u "default:x"` 认证失败） |
| PostgreSQL | 16.14，DSN `postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable` |
| PostgreSQL schema | `public`（无冒号数据）、`t_1`（冒号数据所在） |
| 脚本 | `~/dbdog-release/scripts/one-off/clean-colon-identifier-data.sh`（origin/main @ c39652c） |
| prod.env | **不存在**（脚本默认找 `/home/dbdogt/dev/prod.env`，该路径在 167 上不存在） |
| psql 路径 | `/home/dbdog/dbdog/modules/postgresql/current/bin/psql`（脚本默认 `/home/dbdogt/dev/pgsql/bin/psql`，该路径不存在） |
| 时间 | 2026-08-07 12:39–13:10 CST |

## 执行命令（首次尝试）

```bash
cd ~/dbdog-release
bash scripts/one-off/clean-colon-identifier-data.sh
```

输出：
```
ERROR: 找不到 prod.env（可用 PROD_ENV= 指定）: /home/dbdogt/dev/prod.env
```

---

## 问题一：CH_PASSWORD 强制非空，无密码 CH 环境无法运行

### 脚本相关代码段（scripts/one-off/clean-colon-identifier-data.sh:57-59）

```bash
CH_DB="${DBDOG_CH_DATABASE:-obs}"
CH_USER="${DBDOG_CH_USERNAME:-default}"
: "${CH_PASSWORD:?prod.env 里没有 CH_PASSWORD}"
```

`${CH_PASSWORD:?msg}` 在变量为空字符串或未设置时，向 stderr 输出 msg 并使脚本退出（`set -euo pipefail` 下）。

### ch() 函数（line 60）

```bash
ch() { curl -sS -u "$CH_USER:$CH_PASSWORD" "http://127.0.0.1:8123/" --data-binary "$1"; }
```

curl 的 `-u "default:$CH_PASSWORD"`：当 `CH_PASSWORD` 为空字符串时，展开为 `-u "default:"`，即 HTTP Basic Auth 用户名 `default`、密码为空。

### 实测：CH 无密码环境的认证行为

```
$ curl -sS "http://127.0.0.1:8123/?query=SELECT%201" -u "default:"
1

$ curl -sS "http://127.0.0.1:8123/?query=SELECT%201" -u "default:x"
Code: 194. DB::Exception: default: Authentication failed: password is incorrect,
or there is no user with such name ...
(REQUIRED_PASSWORD)

$ curl -sS "http://127.0.0.1:8123/?query=SELECT%201" -u "default: "
Code: 194. DB::Exception: default: Authentication failed: password is incorrect,
or there is no user with such name
```

CH default 用户配置为无密码认证（空密码可连，任意非空密码认证失败）。
脚本 `${CH_PASSWORD:?}` 检查阻止了空字符串，但 `ch()` 函数的 `curl -u "default:"`（空密码）本可以正常连接。

### 绕过方式

未找到不改脚本代码的绕过方式：`${CH_PASSWORD:?}` 在空值时强制退出，任何非空占位值都会导致 curl 传错密码触发 CH 认证失败。最终手动执行等效 SQL 完成清理（见下文"实际清理执行"）。

---

## 问题二：默认查 `obs` 库，但冒号数据全在 `obs_t_1`

### 脚本相关代码段（line 57）

```bash
CH_DB="${DBDOG_CH_DATABASE:-obs}"
```

脚本所有 CH 查询都以 `$CH_DB` 为库名：

```bash
# line 77 (ch_scalar)
WHERE c.database = '$CH_DB' AND c.name IN ('instance','database_instance')

# line 86 (ch_tagmap)
WHERE c.database = '$CH_DB' AND c.name = 'tags' AND c.type LIKE '%Map(%'

# line 94 (ch_tagindex)
WHERE c.database = '$CH_DB' AND c.name = 'tag_value' AND t.engine LIKE '%MergeTree'

# line 112 (统计)
n="$(ch "SELECT count() FROM $CH_DB.$t WHERE position($c, ':') > 0 FORMAT TSV")"

# line 149 (删除)
ch "ALTER TABLE $CH_DB.$t DELETE WHERE position($c, ':') > 0" >/dev/null
```

### 实测：167 上两个 CH 库的 MergeTree 表数量

```
$ curl -sS "http://127.0.0.1:8123/" --data-binary "SELECT database, count() AS tables FROM system.tables WHERE database IN ('obs','obs_t_1') AND engine LIKE '%MergeTree%' GROUP BY database ORDER BY database FORMAT TSV"
obs_t_1	25
```

`obs` 库有 **0** 张 MergeTree 表，`obs_t_1` 有 **25** 张。
脚本默认查 `obs`，会输出"全部为 0"且不报错——所有 `count()` 查询返回 0，`note()` 不打印（`[ "${n:-0}" -gt 0 ]` 为假），最终 `合计 0 行`。

### 实测：带冒号数据的表全在 obs_t_1

三类表在 `obs_t_1` 库的查询结果（`obs` 库为空）：

标量标识列（`system.columns` 查 `instance` / `database_instance`）：
```
dbm_activity          instance
dbm_gaussdb_activity  instance
dbm_opengauss_activity instance
dbm_plans             instance
dbm_postgres_activity  instance
dbm_query_statements  instance
events                database_instance
profile_metrics       database_instance
profiles              database_instance
```

tags map（`system.columns` 查 `tags` 列且 type LIKE `%Map(%`）：
```
dbm_activity, dbm_gaussdb_activity, dbm_opengauss_activity, dbm_plans,
dbm_postgres_activity, dbm_query_statements, hosts, metric_points,
metric_points_5m, profile_metrics, profiles, spans
```

标签字典（`system.columns` 查 `tag_value` 列）：
```
metric_tag_index
```

### 多租户背景

167 上 dbdog-server 的 DDSQL default org 配置为 `t_1 / obs_t_1`（升级 hook 输出 `[hook] DDSQL default org 配置已确保为 t_1 / obs_t_1`）。
CH 数据库名 `obs_t_1` 对应 PG schema `t_1`，是租户 `t_1` 的数据面。脚本默认 `obs` / `public` 对应默认租户，但本环境实际数据在 `obs_t_1` / `t_1`。

---

## 问题三：默认查 `public` schema，但 PG 冒号数据全在 `t_1`

### 脚本相关代码段（line 63-64）

```bash
PG_SCHEMA="${DBDOG_PG_SCHEMA:-public}"
PSQL="${PSQL:-/home/dbdogt/dev/pgsql/bin/psql}"
```

PG 查询以 `$PG_SCHEMA` 为 schema 名（line 99-103）：

```bash
pg_tables() {
  pg "SELECT table_name FROM information_schema.columns
      WHERE column_name = 'database_instance' AND table_schema = '$PG_SCHEMA'
      ORDER BY table_name"
}
```

### 实测：两个 schema 的冒号数据行数

```
=== schema: public ===
（无输出，所有表 count = 0）

=== schema: t_1 ===
  dataobs_assets: 1440
  dbm_extensions: 23
  dbm_instances: 1
  dbm_schema_objects: 142
  dbm_settings: 1167
```

`public` schema 有 0 行冒号数据，`t_1` schema 有 2773 行。脚本默认查 `public`，会输出"合计 0 行"。

---

## 问题四：注释中 metric_points TTL 描述与实际配置不符

### 脚本注释（line 35-36）

```
# TTL 提示：metric_points 的 TTL 只有 1 天，冒号数据会自然过期，通常不值得为它跑一次
# 五千万行的 mutation（用 EXCLUDE 跳过即可）。metric_points_5m 的 TTL 是 455 天，不清会留一年多。
```

### 实测：两张表的实际 TTL（system.tables.engine_full）

```
metric_points:
  ReplacingMergeTree(version) PARTITION BY (toYYYYMMDD(ts), toHour(ts))
  ORDER BY (metric_name, tag_hash, ts)
  TTL toDateTime(ts) + toIntervalDay(15)
  SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1

metric_points_5m:
  AggregatingMergeTree PARTITION BY toYYYYMM(ts)
  ORDER BY (metric_name, tag_hash, ts)
  TTL toDateTime(ts) + toIntervalDay(455)
  SETTINGS ttl_only_drop_parts = 1, index_granularity = 8192
```

- metric_points：注释说 "TTL 只有 1 天"，实际 `toIntervalDay(15)`（15 天）
- metric_points_5m：注释说 "455 天"，实际 `toIntervalDay(455)`（455 天）✓

### 实测：metric_points 冒号数据的时间范围与行数

```
$ curl -sS "http://127.0.0.1:8123/" --data-binary "SELECT count() AS colon_rows, min(ts) AS min_ts, max(ts) AS max_ts FROM obs_t_1.metric_points WHERE position(tags['database_instance'], ':') > 0 FORMAT TSV"
333125819	2026-07-30 07:42:15.439	2026-08-07 04:44:34.000
```

3.33 亿行，时间跨度 2026-07-30 至 2026-08-07（9 天）。
若 TTL 为 15 天，最早数据（7/30）要到 8/14 才过期，冒号数据会留存约 2 周。
若 TTL 为注释所述 1 天，7/30 的数据应已过期，但 8/7 实测仍存在 7/30 的数据。

---

## 问题五：prod.env 和 psql 默认路径与 167 实际不符

### 脚本默认路径（line 55, 64）

```bash
ENV_FILE="${PROD_ENV:-/home/dbdogt/dev/prod.env}"
PSQL="${PSQL:-/home/dbdogt/dev/pgsql/bin/psql}"
```

### 实测：167 上的实际路径

```
$ find /home -name "prod.env" -type f
（无结果，prod.env 不存在）

$ ls ~/dbdog/etc/*.env
/home/dbdog/dbdog/etc/dbdog-mcp.env
/home/dbdog/dbdog/etc/dbdog-server.env
/home/dbdog/dbdog/etc/dbdog-web.env
/home/dbdog/dbdog/etc/ddsql-server.env

$ ls ~/dbdog/modules/postgresql/current/bin/psql
/home/dbdog/dbdog/modules/postgresql/current/bin/psql
```

- prod.env 不存在于 167；dbdog-server 的配置在 `~/dbdog/etc/dbdog-server.env`
- psql 在 `/home/dbdog/dbdog/modules/postgresql/current/bin/psql`，脚本默认的 `/home/dbdogt/dev/pgsql/bin/psql` 不存在

脚本默认路径 `/home/dbdogt/dev/` 是另一个部署布局（开发机 `dbdogt` 用户），
167 的部署布局是 `/home/dbdog/dbdog/`（`dbdog` 用户 + `dbdog` 子目录）。

---

## 实际清理执行（手动，不依赖脚本）

因上述兼容性问题，脚本无法在 167 上直接运行。手动执行等效 SQL 完成清理。

### PG t_1 schema（事务同步删除，2773 行）

```sql
BEGIN;
DELETE FROM t_1.dataobs_assets      WHERE database_instance LIKE '%:%';  -- 1440
DELETE FROM t_1.dbm_extensions      WHERE database_instance LIKE '%:%';  -- 23
DELETE FROM t_1.dbm_instances       WHERE database_instance LIKE '%:%';  -- 1
DELETE FROM t_1.dbm_schema_objects  WHERE database_instance LIKE '%:%';  -- 142
DELETE FROM t_1.dbm_settings        WHERE database_instance LIKE '%:%';  -- 1167
COMMIT;
```

输出：
```
BEGIN
DELETE 1440
DELETE 23
DELETE 1
DELETE 142
DELETE 1167
COMMIT
```

### CH obs_t_1（ALTER TABLE DELETE 异步 mutation）

标量标识列（instance）：
```
ALTER TABLE obs_t_1.dbm_activity          DELETE WHERE position(instance, ':') > 0
ALTER TABLE obs_t_1.dbm_gaussdb_activity  DELETE WHERE position(instance, ':') > 0
ALTER TABLE obs_t_1.dbm_plans             DELETE WHERE position(instance, ':') > 0
ALTER TABLE obs_t_1.dbm_query_statements  DELETE WHERE position(instance, ':') > 0
```

标量标识列（database_instance）：
```
ALTER TABLE obs_t_1.events DELETE WHERE position(database_instance, ':') > 0
```

tags map：
```
ALTER TABLE obs_t_1.dbm_activity          DELETE WHERE position(tags['database_instance'], ':') > 0
ALTER TABLE obs_t_1.dbm_gaussdb_activity  DELETE WHERE position(tags['database_instance'], ':') > 0
ALTER TABLE obs_t_1.dbm_plans             DELETE WHERE position(tags['database_instance'], ':') > 0
ALTER TABLE obs_t_1.dbm_query_statements  DELETE WHERE position(tags['database_instance'], ':') > 0
ALTER TABLE obs_t_1.metric_points_5m      DELETE WHERE position(tags['database_instance'], ':') > 0
```

标签字典：
```
ALTER TABLE obs_t_1.metric_tag_index DELETE WHERE tag_key = 'database_instance' AND position(tag_value, ':') > 0
```

metric_points（3.33 亿行，脚本注释建议 EXCLUDE 跳过，但因实际 TTL 15 天非 1 天，仍提交清理）：
```
ALTER TABLE obs_t_1.metric_points DELETE WHERE position(tags['database_instance'], ':') > 0
```

### 清理后验证（count 归零）

CH：
```
dbm_activity(instance)      0
dbm_plans(instance)         0
events(db_inst)             0
metric_tag_index            0
metric_points_5m(tags)      0
```

PG：
```
t_1.dbm_settings     0
t_1.dataobs_assets   0
t_1.dbm_instances    0
```

### metric_points mutation 进度（提交时）

```
$ curl -sS "http://127.0.0.1:8123/" --data-binary "SELECT table, is_done, parts_to_do FROM system.mutations WHERE database = 'obs_t_1' AND is_done = 0 FORMAT TSV"
metric_points	0	693
```

`is_done=0`，`parts_to_do=693`，异步执行中。