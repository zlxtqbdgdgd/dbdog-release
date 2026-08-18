-- dbdog 监控用户初始化(PostgreSQL)——全局部分(整个 PG 实例只跑一次,连任意库执行)。
-- 用法(psql 变量传密码,凭证不入 shell 历史):
--   su - postgres -c "psql -p <port> -d postgres -v dbdog_pw=\"'<监控用户密码>'\" -f /opt/dbdog-agent/scripts/init-dbdog-user-pg-global.sql"
-- 正常路径不用手工跑这一步:agent-install.sh(不带 --host-only)会经本地管理员连接
-- 自动建号(缺了就建/已存在只补授权),密码用 DBDOG_POSTGRES_MONITOR_PASSWORD。
-- 本文件是安装器建不了号(如拿不到数据库 OS 账户)时的兜底,以及 DBA 手工接入的参考。
-- 密码须与 Agent conf.d/postgres.d/conf.yaml 的 password 一致。

CREATE USER dbdog WITH PASSWORD :dbdog_pw;
GRANT pg_monitor TO dbdog;
