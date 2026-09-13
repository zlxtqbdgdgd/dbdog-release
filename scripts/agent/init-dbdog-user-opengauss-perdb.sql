-- dbdog 监控用户初始化(openGauss 单机/集中式)——每库部分(每个 query samples
-- 可能引用的库都要跑,幂等)。批量应用/验收优先使用同目录
-- init-dbdog-user-opengauss-all-databases.sh;新建业务库后须再次执行。
-- 2026-08-18 起完整 configure 语义(含把该库用户自建 schema 经
--   ALTER ROLE dbdog IN DATABASE <库> SET search_path 追加到监控用户)由
--   该脚本单入口承载;本文件只管库内 DDL 部分,直接 -f 执行不会配置 search_path。
-- 前置:先跑过一次 init-dbdog-user-opengauss-global.sql(建用户)。
-- 用法:
--   gsql -d <被监控库> -p <port> -f init-dbdog-user-opengauss-perdb.sql
-- 2026-08-02 起 DB 侧只保留特权必需物(schema + explain function):
-- statements/activity 兼容视图已由 collector 引擎内联 SQL 取代——内联 SQL 承载
-- 原视图全部列映射与 openGauss 差异点(dbe_perf.statement 无 db_id 的
-- current_database() OID shim、A 模式空串=NULL 的 TRIM(query) IS NOT NULL 谓词、
-- blocking CASE、µs→ms 换算)。pg_stat_statements_view/pg_stat_activity_view 为
-- 出厂默认哨兵值时走内联,显式配置视图名才沿用旧视图(存量部署零中断)。
-- 含视图旧版存档与 DROP 对照见 legacy/init-dbdog-user-opengauss-perdb-with-views.sql。
-- 与 GaussDB 版共通差异点:
--   * CREATE SCHEMA 无 IF NOT EXISTS——幂等靠 DO 异常护栏;
--   * explain 出 FORMAT JSON 前必须 set local explain_perf_mode = normal。

DO $$ BEGIN CREATE SCHEMA dbdog; EXCEPTION WHEN OTHERS THEN NULL; END $$;
GRANT USAGE ON SCHEMA dbdog TO dbdog;
-- canonical explain 入口在 public(见下),dbdog 需要 USAGE 才够得着;
-- 加固过的实例会 REVOKE ALL ON SCHEMA public FROM PUBLIC,这条即为刚需(与 PG 版对齐)。
GRANT USAGE ON SCHEMA public TO dbdog;

-- explain plan 采集入口(SECURITY DEFINER:dbdog 用户借道拿任意语句的计划)。
-- openGauss 与 GaussDB 同规则:SECURITY DEFINER 动态 SQL 按函数所属 schema 解析
-- 未限定表名,业务 SQL 通常依赖默认 public,因此 canonical 入口必须放 public
-- (即上面的解析规则);函数不向 PUBLIC 开放,只授权监控用户执行。
-- 形态不带 OUT 参数(RETURNS SETOF json,入参只有 l_query):库级/会话级
-- behavior_compat_options 含 proc_outparam_override 时,plpgsql 函数的 OUT 与 RETURNS TABLE 列都计入
-- 调用签名(LANGUAGE sql 不受影响,列统计入口不用改),带 OUT 的旧形态单参调用报 `function public.dbdog_explain_statement(unknown)
-- does not exist`,按 (text) 写的 REVOKE/GRANT 也解析不到——ON_ERROR_STOP 让本文件停在
-- 那一行,兼容入口与列统计都没建(203 mogdb1 的半截初始化即此)。补一个 NULL 占位的
-- 双参调用能解析,但返回 0 行,拿不到计划。无 OUT 的 SETOF json 在该选项开/关下单参
-- 调用都成立(2026-09-13 loop S321 在 203 openGauss 7.0.0-RC1 / 202 GaussDB 507
-- 自建库实测四格)。
-- 旧形态替换:按带 OUT 的完整签名 DROP——选项开时只命中旧形态,选项关时 OUT 不计入
-- 签名、新旧形态都命中;随后 CREATE OR REPLACE 重建并重新授权。整段放一个事务,
-- 并发的 explain 探针看不到函数缺失的空窗(空窗一次会让 agent 按库退避 ≥5 分钟)。
-- 已在网的旧形态库由 agent 升级自愈(agent-install.sh agent_heal_gauss_dbm_objects)。
BEGIN;
DROP FUNCTION IF EXISTS dbdog.explain_statement(l_query text, OUT explain json);
DROP FUNCTION IF EXISTS public.dbdog_explain_statement(l_query text, OUT explain json);

CREATE OR REPLACE FUNCTION public.dbdog_explain_statement(l_query text)
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

-- 旧配置兼容入口;实现只委托给 public 中的 canonical 函数,避免保留两份 explain 逻辑。
CREATE OR REPLACE FUNCTION dbdog.explain_statement(l_query text)
 RETURNS SETOF json
 LANGUAGE plpgsql
 STRICT SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY SELECT * FROM public.dbdog_explain_statement(l_query);
END;
$function$;

REVOKE ALL ON FUNCTION dbdog.explain_statement(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dbdog.explain_statement(text) TO dbdog;
COMMIT;

-- 列统计采集入口(SECURITY DEFINER:pg_stats 按 has_column_privilege 过滤行,
-- dbdog 无业务表 SELECT 权限会读到空集,故借函数属主身份读取)。
-- 与 explain 入口不同,本函数不必放 public:函数体内所有对象都写了全名,
-- 不依赖 SECURITY DEFINER 的未限定名解析规则,因此不受该解析陷阱影响。
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
