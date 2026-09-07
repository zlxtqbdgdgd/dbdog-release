-- dbdog 监控用户初始化(PostgreSQL)——全局部分(整个 PG 实例只跑一次,连任意库执行)。
-- 用法(psql 变量传密码,凭证不入 shell 历史):
--   su - postgres -c "psql -p <port> -d postgres -v dbdog_pw=\"'<监控用户密码>'\" -f /opt/dbdog-agent/scripts/init-dbdog-user-pg-global.sql"
-- 这是接入的第 1 步(控制台「添加数据库实例」向导按本文件拼命令),安装器只验不建——
-- 与 Datadog 同边界:Agent 从不建库内账号,CREATE USER 由 DBA 跑。
-- 密码须与向导第 2 步交给安装器的 DBDOG_POSTGRES_MONITOR_PASSWORD 一致。

CREATE USER dbdog WITH PASSWORD :dbdog_pw;
GRANT pg_monitor TO dbdog;
