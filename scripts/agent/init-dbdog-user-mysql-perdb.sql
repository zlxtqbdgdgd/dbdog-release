-- dbdog 监控用户初始化(MySQL)——每库部分(每个要监控的库都各跑一遍,以目标库为默认库喂入)。
-- 用法(init-dbdog-user-mysql-all-databases.sh 代劳;手工跑):
--   mysql -u root <目标库> < init-dbdog-user-mysql-perdb.sql
-- 前置:先跑过一次 init-dbdog-user-mysql-global.sql(建登录用户/dbdog 库/全局过程)。
-- 本文件在**目标库**里建 explain_statement 裸名过程——check 的第一解析策略是在语句所在库
-- 找裸名过程;全限定兜底 dbdog.explain_statement 已由 global 建,两者同体。
-- GRANT 里不写库名前缀:MySQL 按**当前默认库**解析(与喂入方式配套,别改用 -e 串执行)。
-- 不要对系统库(information_schema/performance_schema/sys/mysql)执行。

DROP PROCEDURE IF EXISTS explain_statement;
DELIMITER $$
CREATE PROCEDURE explain_statement(IN query TEXT)
SQL SECURITY DEFINER
BEGIN
    SET @explain := CONCAT('EXPLAIN FORMAT=JSON ', query);
    PREPARE stmt FROM @explain;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END$$
DELIMITER ;
-- DROP+CREATE 会清掉过程上的旧授权，GRANT 必须在重建之后（对象=当前默认库的裸名过程）。
GRANT EXECUTE ON PROCEDURE explain_statement TO 'dbdog'@'127.0.0.1';
