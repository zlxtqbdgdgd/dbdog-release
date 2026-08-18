-- dbdog 监控用户初始化(GaussDB 集中式)——每库部分(每个 query samples
-- 可能引用的库都要跑,幂等)。批量应用/验收优先使用同目录
-- init-dbdog-user-gaussdb-all-databases.sh;新建业务库后须再次执行。
-- 2026-08-18 起完整 configure 语义(含把该库用户自建 schema 经
--   ALTER ROLE dbdog IN DATABASE <库> SET search_path 追加到监控用户)由
--   该脚本单入口承载;本文件只管库内 DDL 部分,直接 -f 执行不会配置 search_path。
-- 前置:先跑过一次 init-dbdog-user-gaussdb-global.sql(建用户)。
-- 用法:
--   gsql -d <被监控库> -p <port> -f init-dbdog-user-gaussdb-perdb.sql
-- 2026-08-02 起 DB 侧只保留特权必需物(schema + explain function):
-- statements/activity 兼容视图已由 collector 引擎内联 SQL 取代——
-- pg_stat_statements_view/pg_stat_activity_view 为上游默认哨兵值时走内联,
-- 显式配置视图名才沿用旧视图(存量部署零中断)。含视图旧版存档与 DROP 对照见
-- legacy/init-dbdog-user-gaussdb-perdb-with-views.sql。
-- 与 PG 版(init-dbdog-user-pg-perdb.sql)差异,登记单源见
-- dbdog-web docs/design/dbm-gaussdb-cent.md:
--   * 无 pg_stat_statements——query metrics 走 dbe_perf.statement,无需建扩展;
--   * CREATE SCHEMA 无 IF NOT EXISTS(9.2 血统)——幂等靠 DO 异常护栏(已实证);
--   * explain 出 FORMAT JSON 前必须 set local explain_perf_mode = normal,
--     否则报 "explain_perf_mode requires FORMAT TEXT"(已实证)。

DO $$ BEGIN CREATE SCHEMA dbdog; EXCEPTION WHEN OTHERS THEN NULL; END $$;
GRANT USAGE ON SCHEMA dbdog TO dbdog;
-- canonical explain 入口在 public(见下),dbdog 需要 USAGE 才够得着;
-- 加固过的实例会 REVOKE ALL ON SCHEMA public FROM PUBLIC,这条即为刚需(与 PG 版对齐)。
GRANT USAGE ON SCHEMA public TO dbdog;

-- GaussDB 会在 SECURITY DEFINER 函数所属 schema 解析动态 SQL 中未限定 schema 的表名。
-- 业务 SQL 通常依赖默认 public，因此 canonical explain 入口必须放在 public；函数本身
-- 不向 PUBLIC 开放，只授权监控用户执行。
CREATE OR REPLACE FUNCTION public.dbdog_explain_statement(l_query text, OUT explain json)
 RETURNS SETOF json
 LANGUAGE plpgsql
 STRICT SECURITY DEFINER
AS $function$
DECLARE
  curs REFCURSOR;
  plan JSON;
BEGIN
  EXECUTE 'set local explain_perf_mode = normal';
  OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
  FETCH curs INTO plan;
  CLOSE curs;
  RETURN QUERY SELECT plan;
END;
$function$;

REVOKE ALL ON FUNCTION public.dbdog_explain_statement(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dbdog_explain_statement(text) TO dbdog;

-- 旧配置兼容入口；实现只委托给 public 中的 canonical 函数，避免保留两份 explain 逻辑。
CREATE OR REPLACE FUNCTION dbdog.explain_statement(l_query text, OUT explain json)
 RETURNS SETOF json
 LANGUAGE plpgsql
 STRICT SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY SELECT plan.explain
  FROM public.dbdog_explain_statement(l_query) AS plan;
END;
$function$;

REVOKE ALL ON FUNCTION dbdog.explain_statement(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dbdog.explain_statement(text) TO dbdog;

-- 列统计采集入口(SECURITY DEFINER:pg_stats 按 has_column_privilege 过滤行,
-- dbdog 无业务表 SELECT 权限会读到空集,故借函数属主身份读取)。
-- 与 explain 入口不同,本函数不必放 public:函数体内所有对象都写了全名,
-- 不依赖 SECURITY DEFINER 的未限定名解析规则,因此不受 PITFALLS #22b 影响。
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
