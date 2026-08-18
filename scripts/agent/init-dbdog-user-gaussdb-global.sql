-- dbdog 监控用户初始化(GaussDB 集中式)——全局部分(整实例只跑一次,连任意库执行)。
-- 用法(gsql 变量传密码,凭证不入 shell 历史):
--   gsql -d postgres -p <port> -v dbdog_pw="'<监控用户密码>'" -f /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-global.sql
-- 正常路径不用手工跑这一步:agent-install.sh(不带 --host-only)的建号链会自动处理
-- (含 password_encryption_type=1 与 MD5 HBA 预检);本文件是兜底与 DBA 手工接入参考。
-- 密码须与 Agent conf.d/gaussdb.d/conf.yaml 一致。
-- 与 PG 版差异,登记单源见 dbdog-web docs/design/dbm-gaussdb-cent.md:
--   * GaussDB 无 pg_monitor 角色,监控读权限(dbe_perf/全局 pg_stat_activity/
--     pg_thread_wait_status)走 MONADMIN 属性(2026-07-23 实证);
--   * 建用户会在当前库自动创建同名 schema(A 模式行为)。

CREATE USER dbdog WITH MONADMIN PASSWORD :dbdog_pw;
