-- dbdog 监控用户初始化(GaussDB 集中式)——全局部分(整实例只跑一次,连任意库执行)。
-- 用法(gsql 变量传密码,凭证不入 shell 历史):
--   gsql -d postgres -p <port> -v dbdog_pw="'<监控用户密码>'" -f /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-global.sql
-- 这是接入的第 1 步(控制台「添加数据库实例」向导按本文件拼命令),安装器只验不建。
-- 前置:SHOW password_encryption_type 须为 1(否则新号没有 MD5 凭证,标准 libpq 连不上);
-- 本机 MD5 HBA 规则由安装器写,不用 DBA 改 gs_hba.conf。
-- 密码须与向导第 2 步交给安装器的 DBDOG_GAUSSDB_MONITOR_PASSWORD 一致。
-- 与 PG 版的差异:
--   * GaussDB 无 pg_monitor 角色,监控读权限(dbe_perf/全局 pg_stat_activity/
--     pg_thread_wait_status)走 MONADMIN 属性(2026-07-23 实证);
--   * 建用户会在当前库自动创建同名 schema(A 模式行为)。

CREATE USER dbdog WITH MONADMIN PASSWORD :dbdog_pw;
