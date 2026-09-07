-- dbdog 监控用户初始化(openGauss 单机/集中式)——全局部分(整实例只跑一次,连任意库执行)。
-- 用法(gsql 变量传密码,凭证不入 shell 历史):
--   gsql -d postgres -p <port> -v dbdog_pw="'<监控用户密码>'" -f /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-global.sql
-- 这是接入的第 1 步(控制台「添加数据库实例」向导按本文件拼命令),安装器只验不建。
-- 前置:SHOW password_encryption_type 须为 1(否则新号没有 MD5 凭证,标准 libpq 连不上)。
-- 密码须与向导第 2 步交给安装器的 DBDOG_OPENGAUSS_MONITOR_PASSWORD 一致。
-- 与 PG 版差异(军规 8 引擎各立):
--   * openGauss 无 pg_monitor 角色,监控读权限(dbe_perf/全局 pg_stat_activity/
--     pg_thread_wait_status)走 MONADMIN 属性;
--   * 建用户会在当前库自动创建同名 schema(A 模式行为)。

CREATE USER dbdog WITH MONADMIN PASSWORD :dbdog_pw;
