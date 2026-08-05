-- dbdog-agent GaussDB 每库兼容对象；安装器以目标机 GaussDB 管理用户幂等执行。
-- 日常采集不调用 gsql，这些对象由打包在 Agent 中的 gaussdb integration 通过连接池读取。

DO $$ BEGIN CREATE SCHEMA dbdog; EXCEPTION WHEN OTHERS THEN NULL; END $$;
GRANT USAGE ON SCHEMA dbdog TO dbdog;

-- 业务 SQL 通常依赖默认 public，因此 canonical explain 入口必须放在 public：GaussDB 的
-- SECURITY DEFINER 动态 SQL 按函数所属 schema 解析未限定表名，入口若只在 dbdog schema，
-- 解释默认 public 下的业务 SQL 会失败。函数不向 PUBLIC 开放，只授权监控用户执行。
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

-- 列统计采集入口（SECURITY DEFINER：pg_stats 按 has_column_privilege 过滤行，dbdog 无业务表
-- SELECT 权限会读到空集，故借函数属主身份读取）。integration 的 collect_column_statistics
-- 默认调 datadog.column_statistics()，dbdog 命名下必须在 conf.yaml 显式配 function_name。
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

-- GaussDB 无 pg_stat_statements；integration 的默认 view 指向本兼容视图。
CREATE OR REPLACE VIEW dbdog.statements AS
SELECT unique_sql_id AS queryid,
       query,
       n_calls AS calls,
       total_elapse_time / 1000.0 AS total_time,
       n_returned_rows AS "rows",
       n_blocks_hit AS shared_blks_hit,
       greatest(n_blocks_fetched - n_blocks_hit, 0) AS shared_blks_read,
       db_id AS dbid,
       user_id AS userid
FROM dbe_perf.statement;

GRANT SELECT ON dbdog.statements TO dbdog;

-- 补齐 PostgreSQL 兼容 activity 视图缺失的等待事件与阻塞者字段。
CREATE OR REPLACE VIEW dbdog.activity AS
SELECT a.*,
       w.wait_status AS wait_event_type,
       w.wait_event AS wait_event,
       CASE WHEN w.block_sessionid IS NOT NULL AND w.block_sessionid <> 0
            THEN ARRAY[b.pid] END AS blocking_pids
FROM pg_stat_activity a
LEFT JOIN pg_thread_wait_status w ON a.sessionid = w.sessionid
LEFT JOIN pg_stat_activity b ON b.sessionid = w.block_sessionid;

GRANT SELECT ON dbdog.activity TO dbdog;
