-- dbdog 监控用户初始化(MySQL)——全局部分(整实例只跑一次,任意库执行;建议 root 经本机 socket)。
-- 用法(密码是 __DBDOG_PW__ 占位,sed 替换后经 stdin 喂 mysql——凭证不进 argv 不落盘):
--   sed "s/__DBDOG_PW__/<监控用户密码>/" /opt/dbdog-agent/scripts/init-dbdog-user-mysql-global.sql \
--     | mysql -u root -P <port> -h 127.0.0.1
-- 这是接入的第 1 步(控制台「添加数据库实例」向导按本文件拼命令,安装器只验不建——
-- 与 Datadog 同边界:Agent 从不建库内账号,CREATE USER 由 DBA 跑。
-- 密码须与向导第 2 步交给安装器的 DBDOG_MYSQL_MONITOR_PASSWORD 一致。
-- 每个被监控库还要各跑一遍 init-dbdog-user-mysql-perdb.sql(all-databases.sh 代劳)。
-- 与 PG 版差异(军规 8:引擎各立)：
--   * MySQL 无角色体系：监控读权限 = GRANT SELECT/PROCESS/REPLICATION CLIENT（上游 README 口径）；
--   * explain 与 consumers 开关是存储过程，集中放 dbdog 库（品牌命名，军规 5 有意偏离上游默认
--     datadog.*；check 出货模板已配三个 query_samples override 对齐）；
--   * 密码无 psql -v 等价物：占位符 + sed（凭证只经 stdin 管道）。
-- 采集固定走 127.0.0.1 TCP：账号只建 'dbdog'@'127.0.0.1'；不显式指定认证插件
-- （8.0 默认 caching_sha2_password，pymysql+ cryptography 可连；8.4 起 mysql_native_password
-- 已移除，写死反而锁死升级路径）。

CREATE USER IF NOT EXISTS 'dbdog'@'127.0.0.1' IDENTIFIED BY '__DBDOG_PW__';
-- 幂等重设密码：重接入/换密码时同一文件可重复执行。
ALTER USER 'dbdog'@'127.0.0.1' IDENTIFIED BY '__DBDOG_PW__';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'dbdog'@'127.0.0.1';
GRANT SELECT ON mysql.innodb_index_stats TO 'dbdog'@'127.0.0.1';
-- 上游口径：监控连接上限 5，防采集把业务连接槽吃满。
ALTER USER 'dbdog'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 5;

CREATE DATABASE IF NOT EXISTS dbdog;

DELIMITER $$
DROP PROCEDURE IF EXISTS dbdog.explain_statement$$
CREATE PROCEDURE dbdog.explain_statement(IN query TEXT)
SQL SECURITY DEFINER
BEGIN
    SET @explain := CONCAT('EXPLAIN FORMAT=JSON ', query);
    PREPARE stmt FROM @explain;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END$$

DROP PROCEDURE IF EXISTS dbdog.enable_events_statements_consumers$$
CREATE PROCEDURE dbdog.enable_events_statements_consumers()
SQL SECURITY DEFINER
BEGIN
    UPDATE performance_schema.setup_consumers SET ENABLED = 'YES' WHERE NAME LIKE 'events_statements_%';
    UPDATE performance_schema.setup_consumers SET ENABLED = 'YES' WHERE NAME = 'events_waits_current';
END$$
DELIMITER ;

-- DROP+CREATE 会清掉过程上的旧授权，GRANT 必须在重建之后。
GRANT EXECUTE ON PROCEDURE dbdog.explain_statement TO 'dbdog'@'127.0.0.1';
GRANT EXECUTE ON PROCEDURE dbdog.enable_events_statements_consumers TO 'dbdog'@'127.0.0.1';
