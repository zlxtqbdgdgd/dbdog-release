-- dbdog 监控用户初始化(PostgreSQL)——每库部分(每个要监控的库都各跑一遍,可重复执行)。
-- 前置:先跑过一次 init-dbdog-user-pg-global.sql(建用户/角色)。
-- 用法:
--   psql -U postgres -d <被监控库> -f init-dbdog-user-pg-perdb.sql
-- 2026-08-18 起完整 configure 语义(含把该库用户自建 schema 经
--   ALTER ROLE dbdog IN DATABASE <库> SET search_path 追加到监控用户)由
--   init-dbdog-user-pg-all-databases.sh 单入口承载;本文件只管库内 DDL 部分,
--   直接 -f 执行不会配置 search_path。
-- 配套:postgres.d/conf.yaml 须设 username: dbdog、
--   query_samples.explain_function: dbdog.explain_statement 与
--   collect_column_statistics.function_name: dbdog.column_statistics()
--   (两项上游默认值都是 datadog.*)。

-- 扩展是库内对象,每库各建一份(与 schema/函数同理)。
-- pg_buffercache 对应 collect_buffercache_metrics(出货模板默认 true):缺它时
-- buffercache 查询每个采集周期抛 UndefinedTable,主连接进异常态,会连累挂在同一条
-- 连接上的结构采集——现象是「该库的表在 Schema 树里整个消失」,且只在 agent 日志里
-- 报错,控制台看不出来(2026-08-04 dbname 从 postgres 切到 bench 时实地踩过)。
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

CREATE SCHEMA IF NOT EXISTS dbdog;
GRANT USAGE ON SCHEMA dbdog TO dbdog;
GRANT USAGE ON SCHEMA public TO dbdog;

-- explain plan 采集入口(SECURITY DEFINER:dbdog 用户借道拿任意语句的计划)
CREATE OR REPLACE FUNCTION dbdog.explain_statement(l_query text, OUT explain json)
 RETURNS SETOF json
 LANGUAGE plpgsql
 STRICT SECURITY DEFINER
AS $function$
DECLARE
  curs REFCURSOR;
  plan JSON;
BEGIN
  OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
  FETCH curs INTO plan;
  CLOSE curs;
  RETURN QUERY SELECT plan;
END;
$function$;

GRANT EXECUTE ON FUNCTION dbdog.explain_statement(text) TO dbdog;

-- 列统计采集入口(SECURITY DEFINER:pg_stats 按 has_column_privilege 过滤行,
-- dbdog 无业务表 SELECT 权限会读到空集,故借函数属主身份读取)。
-- search_path 钉死是官方写法:本函数全部对象都写全名,钉死可防 public 同名对象劫持。
CREATE OR REPLACE FUNCTION dbdog.column_statistics()
RETURNS TABLE (
  schemaname name,
  tablename name,
  attname name,
  n_distinct real,
  avg_width integer,
  null_frac real,
  inherited boolean,
  correlation real,
  most_common_freqs real[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT schemaname,
         tablename,
         attname,
         n_distinct,
         avg_width,
         null_frac,
         inherited,
         correlation,
         most_common_freqs
    FROM pg_catalog.pg_stats
   WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
$function$;

REVOKE ALL ON FUNCTION dbdog.column_statistics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dbdog.column_statistics() TO dbdog;
