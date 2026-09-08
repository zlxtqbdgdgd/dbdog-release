#!/usr/bin/env bash
# Configure or clean up MySQL's per-database DBM objects — one entry, one goal:
# give the monitoring user what it needs in a database, or take exactly that back.
# This intentionally lives in deployment tooling: the monitoring Agent must not
# mutate monitored databases at runtime.
#
# 与 pg/gauss 系同名脚本同形；MySQL 语义差异（军规 8：引擎各立）：
#   * 库即 schema：枚举走 information_schema.SCHEMATA，系统库
#     information_schema/performance_schema/sys/mysql 与 dbdog 自身不入循环；
#   * 每库对象只有一个裸名 explain_statement 过程（check 的第一解析策略在语句所在库找它）；
#     GRANT EXECUTE 不写库名前缀——按当前默认库解析，perdb.sql 以「mysql <目标库> < file」喂入；
#   * 无 search_path 环节（PG 系专属），configure 后立即验收，没有 TOPOFF 分支；
#   * 对称清理只删各库的裸名过程（procs_priv 行随 DROP 过程自动消失）；dbdog 库、登录用户、
#     全局 GRANT 保留（重接入零成本）。
#
# 语义(五合一,与 pg 版同款)：
#   无 --db            对实例内每个用户库做 configure
#   --db X             X 未配置→configure；已配置→先问「是否去掉这个库的监控采集」,
#                      确认才清理(对称清理),误操作回答 N 则什么都不动
#   --cleanup          显式清理(--db X 清单库,无 --db 清全实例用户库),执行前必确认
#
# 本仓是这个脚本的唯一 owning path：agent-install.sh 把它与同目录的 per-db SQL 一起装到
# DB 主机的 /opt/dbdog-agent/scripts/，控制台「采集配置」页按该绝对路径直接给出可执行命令
# （dbdog-web src/lib/db-init-commands.ts 的 DB_INIT_SCRIPT_DIR）。新增业务库后由 DBA 在 DB
# 主机上执行；改路径或改脚本名要同步改控制台，否则页面上的命令会指向不存在的文件。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PERDB_SQL=${MYSQL_PERDB_SQL:-$SCRIPT_DIR/init-dbdog-user-mysql-perdb.sql}
MYSQL_BIN=${MYSQL_BIN:-mysql}
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}
MYSQL_ADMIN_USER=${MYSQL_ADMIN_USER:-}

MONITOR_USER_HOST="dbdog@127.0.0.1"

target_db=""
want_cleanup=false
assume_yes=false

usage() {
  cat <<'EOF'
Usage:
  MYSQL_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-mysql-all-databases.sh
  MYSQL_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-mysql-all-databases.sh --db DB
  MYSQL_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-mysql-all-databases.sh --db DB --cleanup
  MYSQL_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-mysql-all-databases.sh --cleanup

Behaviour (one entry point, one goal):
  (no --db)        configure every user database (system schemas skipped)
  --db DB          DB unconfigured -> configure it; already configured -> ask
                   whether to remove monitoring collection from DB (confirm ->
                   symmetric cleanup; answer N -> nothing happens)
  --cleanup        explicit cleanup (--db DB cleans that one database; without
                   --db cleans every user database on the instance)

configure = per-database bare explain_statement procedure + GRANT EXECUTE
            (fed as the connection's default database).
cleanup   = exactly what configure added, taken back: the per-database
            procedure (its procs_priv row disappears with it). The dbdog
            schema, the login user and the global grants are kept.

Connection environment:
  MYSQL_BIN         mysql executable (default: mysql)
  MYSQL_HOST        host (default: 127.0.0.1; point at the socket dir to use
                    the Unix socket instead)
  MYSQL_PORT        port (required)
  MYSQL_ADMIN_USER  administrative user passed to mysql with -u (optional)
  MYSQL_PERDB_SQL   per-database SQL file override (optional)

Prerequisite: the dbdog login user must already exist (created by the console
"Add database instance" wizard step 1 — or run init-dbdog-user-mysql-global.sql
once per instance; it is installed next to this script). Authentication stays
in mysql's normal protected mechanisms (for example an OS root socket, or
MYSQL_PWD). This script never accepts or prints a password argument.
EOF
}

while (($#)); do
  case "$1" in
    --db)
      (($# >= 2)) || { echo "--db requires a database name" >&2; exit 2; }
      target_db=$2
      shift 2
      ;;
    --cleanup)
      want_cleanup=true
      shift
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || { echo "positional database names are gone; use --db DB" >&2; exit 2; }
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "positional database names are gone; use --db DB (got: $1)" >&2
      exit 2
      ;;
  esac
done

: "${MYSQL_PORT:?set MYSQL_PORT explicitly}"
command -v "$MYSQL_BIN" >/dev/null 2>&1 || { echo "mysql executable not found: $MYSQL_BIN" >&2; exit 1; }
[[ -f "$PERDB_SQL" ]] || { echo "per-database SQL not found: $PERDB_SQL" >&2; exit 1; }

# 库名进 SQL 一律反引号包裹（内部反引号双写）；--batch --skip-column-names 只取值。
mysql_base=("$MYSQL_BIN" -h "$MYSQL_HOST" -P "$MYSQL_PORT" --batch --skip-column-names)
[[ -z "$MYSQL_ADMIN_USER" ]] || mysql_base+=(-u "$MYSQL_ADMIN_USER")

run_sql() { # <database|-> <sql>
  if [ "$1" = "-" ]; then
    "${mysql_base[@]}" -e "$2"
  else
    "${mysql_base[@]}" -D "$1" -e "$2"
  fi
}

# 清理类动作的确认门：交互问一句；无 tty 且没给 --yes 时拒绝执行(fail closed)。
confirm() { # <prompt>
  local answer
  if [[ "$assume_yes" == true ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "REFUSED: non-interactive run needs --yes to proceed. $1" >&2
    return 1
  fi
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}

quote_ident() { # <identifier>（MySQL 用反引号）
  local raw=$1
  raw=${raw//\`/\`\`}
  printf '`%s`' "$raw"
}

# 就绪位串：proc|grant。
#   proc  = 当前库有裸名 explain_statement 过程（information_schema.ROUTINES）
#   grant = dbdog 有该过程的 EXECUTE（mysql.procs_priv）
readiness_sql() { # <database>
  cat <<EOF
SELECT
  CASE WHEN EXISTS (
    SELECT 1 FROM information_schema.ROUTINES
    WHERE ROUTINE_SCHEMA = '$1' AND ROUTINE_NAME = 'explain_statement' AND ROUTINE_TYPE = 'PROCEDURE'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM mysql.procs_priv
    WHERE Db = '$1' AND User = 'dbdog' AND Routine_name = 'explain_statement' AND Routine_type = 'PROCEDURE'
  ) THEN 1 ELSE 0 END;
EOF
}

readiness_bits() { # <database>
  run_sql - "$(readiness_sql "$1")"
}

configured() { # <bits>
  [[ "$1" == 1\|1 ]]
}

verify_database() { # <database>
  local database=$1 bits
  if ! bits=$(readiness_bits "$database"); then
    echo "VERIFY_FAILED database=$database (connection or catalog query failed)" >&2
    return 1
  fi
  bits=${bits//$'\r'/}
  if [[ "$bits" != "1|1" ]]; then
    echo "MISSING database=$database bits=$bits (proc|grant)" >&2
    return 1
  fi
  echo "READY database=$database"
}

configure_database() { # <database>
  local database=$1
  echo "CONFIGURE database=$database"
  # perdb.sql 以目标库为默认库喂 stdin：CREATE/GRANT 都按默认库解析（文件头有军规）。
  if ! "${mysql_base[@]}" -D "$database" <"$PERDB_SQL"; then
    echo "APPLY_FAILED database=$database" >&2
    return 1
  fi
  verify_database "$database"
}

# 对称清理：configure 新增什么就清什么。DROP PROCEDURE 连带清掉 procs_priv 的授权行。
# dbdog 库/登录用户/全局 GRANT 明确保留（global.sql 的辖区）。
cleanup_database() { # <database>
  local database=$1
  echo "CLEANUP database=$database"
  run_sql - "DROP PROCEDURE IF EXISTS $(quote_ident "$database").explain_statement;" \
    || { echo "CLEANUP_FAILED database=$database (drop procedure)" >&2; return 1; }
  verify_clean_database "$database"
}

verify_clean_database() { # <database>
  local database=$1 bits
  bits=$(readiness_bits "$database") || { echo "VERIFY_FAILED database=$database" >&2; return 1; }
  bits=${bits//$'\r'/}
  if [[ "$bits" != "0|0" ]]; then
    echo "CLEAN_VERIFY_UNEXPECTED database=$database bits=$bits (proc|grant; both expected gone)" >&2
    return 1
  fi
  echo "CLEANED database=$database"
}

# ---- 主流程 ----

if [[ -n "$target_db" ]]; then
  databases=("$target_db")
else
  # 系统库与 dbdog 自身不入循环：系统库不可建过程，dbdog 库归 global.sql 辖区。
  if ! database_output=$(run_sql - "SELECT schema_name FROM information_schema.SCHEMATA
WHERE schema_name NOT IN ('information_schema','performance_schema','sys','mysql','dbdog')
ORDER BY schema_name;"); then
    echo "failed to enumerate MySQL schemas" >&2
    exit 1
  fi
  databases=()
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

# 前置门:监控登录用户必须先存在。本脚本不建用户(永不碰密码),用户是实例级对象,归
# 向导第 1 步或 global SQL 管。进门一句人话,别等 perdb.sql 深处才炸。
global_hint="$SCRIPT_DIR/init-dbdog-user-mysql-global.sql"
role_exists=$(run_sql - "SELECT COUNT(*) FROM mysql.user WHERE User='dbdog' AND Host='127.0.0.1';")
if [[ "$role_exists" != 1 ]]; then
  echo "PREREQ_MISSING: monitoring user 'dbdog'@'127.0.0.1' does not exist on this instance." >&2
  echo "This script never creates it (no password handling). Create it once per instance:" >&2
  echo "  sed \"s/__DBDOG_PW__/<监控用户密码>/\" ${global_hint} | ${MYSQL_BIN} -u root -P ${MYSQL_PORT} -h ${MYSQL_HOST}" >&2
  echo "(或直接用控制台「添加数据库实例」向导第 1 步拼好的命令)" >&2
  exit 1
fi

failures=0

if [[ "$want_cleanup" == true ]]; then
  echo "About to clean up monitoring objects in: ${databases[*]}"
  echo "(each database's bare explain_statement procedure; the dbdog schema, login user and global grants are kept)"
  confirm "Remove monitoring collection from these databases?" || { echo "aborted; nothing changed" >&2; exit 1; }
  for database in "${databases[@]}"; do
    cleanup_database "$database" || failures=$((failures + 1))
  done
  if ((failures > 0)); then
    echo "MySQL cleanup failed for $failures database(s)" >&2
    exit 1
  fi
  echo "MySQL cleanup complete: ${#databases[@]} database(s)"
  exit 0
fi

for database in "${databases[@]}"; do
  bits=$(readiness_bits "$database") || { echo "READINESS_FAILED database=$database" >&2; failures=$((failures + 1)); continue; }
  bits=${bits//$'\r'/}
  if ! configured "$bits"; then
    # 未配置(或上次半途而废)→ 补齐并验收
    configure_database "$database" || failures=$((failures + 1))
  else
    # 已完整配置还要执行 → 先提醒是不是要去掉这个库的监控采集；误操作答 N 则不动
    echo "ALREADY_CONFIGURED database=$database"
    if confirm "database=$database is already configured. Remove monitoring collection from it?"; then
      cleanup_database "$database" || failures=$((failures + 1))
    else
      echo "SKIPPED database=$database (no changes made)" >&2
    fi
  fi
done

if ((failures > 0)); then
  echo "MySQL per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "MySQL per-database DBM setup complete: ${#databases[@]} database(s)"
