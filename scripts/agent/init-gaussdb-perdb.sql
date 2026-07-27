-- dbdog-agent GaussDB 每库兼容对象；安装器以目标机 GaussDB 管理用户幂等执行。
-- 日常采集不调用 gsql，这些对象由打包在 Agent 中的 gaussdb integration 通过连接池读取。

DO $$ BEGIN CREATE SCHEMA dbdog; EXCEPTION WHEN OTHERS THEN NULL; END $$;
GRANT USAGE ON SCHEMA dbdog TO dbdog;

CREATE OR REPLACE FUNCTION dbdog.explain_statement(l_query text, OUT explain json)
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

GRANT EXECUTE ON FUNCTION dbdog.explain_statement(text) TO dbdog;

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
