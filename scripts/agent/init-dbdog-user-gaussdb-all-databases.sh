#!/usr/bin/env bash
# Configure or clean up GaussDB's per-database DBM objects — one entry, one goal:
# give the monitoring user what it needs in a database, or take exactly that back.
# This intentionally lives in deployment tooling: the monitoring Agent must not
# mutate monitored databases at runtime.
#
# 语义(2026-08-18 五合一重设计,替代旧 --all/--check/--exclude 三开关):
#   无 --db            对实例内每个非 template 可连库做 configure
#   --db X             X 未配置→configure;已配置→先问「是否去掉这个库的监控采集」,
#                      确认才清理(对称清理),误操作回答 N 则什么都不动
#   --cleanup          显式清理(--db X 清单库,无 --db 清全实例用户库),执行前必确认
#   configure = per-db SQL(perdb.sql 原样) + ALTER ROLE dbdog IN DATABASE X SET search_path
#              (把该库用户自建 schema 追加到监控用户,追加语义:与现值合并去重)
#   cleanup   = 对称原则:configure 往库里新增了什么就同等清掉什么——dbdog schema、
#              public 上的 canonical explain 入口、授出的 public USAGE、search_path 设置;
#              无扩展可清(本引擎无 pg_stat_statements,query metrics 走 dbe_perf.statement),
#              dbdog 登录角色保留(实例级对象,重接入零成本)。
#
# 与 PG/openGauss 版同名脚本同形;引擎差异只在:gsql、无扩展位(readiness 四位)、
# canonical explain 入口在 public、用户 schema 黑名单最长(Kernel 507 实测系统 schema
# 44 个:dbe_* 29 个 + pkg_*/prvt_ilm/resource_manager/sys/cstore/snapshot/sqladvisor/
# db4ai/blockchain 等)、库兼容模式 M 另走一套(见 database_mode 上方注释)。
#
# 本仓是这个脚本的唯一 owning path：agent-install.sh 把它与同目录的 per-db SQL 一起装到
# DB 主机的 /opt/dbdog-agent/scripts/，控制台「采集配置」页按该绝对路径直接给出可执行命令
# （dbdog-web src/lib/db-init-commands.ts 的 DB_INIT_SCRIPT_DIR）。新增业务库后由 DBA 在 DB
# 主机上执行；改路径或改脚本名要同步改控制台，否则页面上的命令会指向不存在的文件。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PERDB_SQL=${GAUSSDB_PERDB_SQL:-$SCRIPT_DIR/init-dbdog-user-gaussdb-perdb.sql}
GSQL_BIN=${GAUSSDB_GSQL_BIN:-gsql}
GAUSSDB_ADMIN_DB=${GAUSSDB_ADMIN_DB:-postgres}
GAUSSDB_HOST=${GAUSSDB_HOST:-}
GAUSSDB_ADMIN_USER=${GAUSSDB_ADMIN_USER:-}

MONITOR_ROLE=dbdog

target_db=""
want_cleanup=false
assume_yes=false

usage() {
  cat <<'EOF'
Usage:
  GAUSSDB_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-all-databases.sh
  GAUSSDB_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-all-databases.sh --db DB
  GAUSSDB_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-all-databases.sh --db DB --cleanup
  GAUSSDB_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-gaussdb-all-databases.sh --cleanup

Behaviour (one entry point, one goal):
  (no --db)        configure every non-template, connectable database
  --db DB          DB unconfigured -> configure it; already configured -> ask
                   whether to remove monitoring collection from DB (confirm ->
                   symmetric cleanup; answer N -> nothing happens)
  --cleanup        explicit cleanup (--db DB cleans that one database; without
                   --db cleans every user database on the instance)
  --yes            skip the interactive confirmation (for non-tty runs only;
                   cleanup and configured-database reruns refuse to run
                   non-interactively without it)

configure = per-database SQL + ALTER ROLE dbdog IN DATABASE DB SET search_path
            (append every user-created schema of DB to the monitoring role).
cleanup   = exactly what configure added, taken back: dbdog schema, the public
            explain entry function, granted public USAGE, search_path setting.
            The dbdog login role is kept.

Connection environment:
  GAUSSDB_GSQL_BIN    gsql executable (default: gsql)
  GAUSSDB_HOST        host name or local socket directory (optional)
  GAUSSDB_PORT        port (required)
  GAUSSDB_ADMIN_DB    database used for enumeration (default: postgres)
  GAUSSDB_ADMIN_USER  administrative user passed to gsql with -U (optional)
  GAUSSDB_PERDB_SQL   per-database SQL file override (default:
                      init-dbdog-user-gaussdb-perdb.sql next to this script)

Prerequisite: the dbdog login role must already exist. agent-install.sh never creates
it (the installer only writes the local MD5 HBA rule and verifies credentials): run
init-dbdog-user-gaussdb-global.sql once per instance — console "Add database instance"
wizard step 1, or by hand; it is installed next to this script. password_encryption_type
must be 1 before creating the role. Authentication stays in gsql's normal protected mechanisms (for example
an OS database account or password environment/file). This script never accepts or
prints a password argument.
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

: "${GAUSSDB_PORT:?set GAUSSDB_PORT explicitly}"
command -v "$GSQL_BIN" >/dev/null 2>&1 || { echo "gsql executable not found: $GSQL_BIN" >&2; exit 1; }
[[ -f "$PERDB_SQL" ]] || { echo "per-database SQL not found: $PERDB_SQL" >&2; exit 1; }

gsql_base=("$GSQL_BIN" -p "$GAUSSDB_PORT")
[[ -z "$GAUSSDB_HOST" ]] || gsql_base+=(-h "$GAUSSDB_HOST")
[[ -z "$GAUSSDB_ADMIN_USER" ]] || gsql_base+=(-U "$GAUSSDB_ADMIN_USER")

# 每库一连接执行一条 SQL；-A -t 只取值，ON_ERROR_STOP 让失败立刻冒出来。
run_sql() { # <database> <sql>
  "${gsql_base[@]}" -d "$1" -A -t -v ON_ERROR_STOP=1 -c "$2"
}

# 库兼容模式从库本身量(pg_database.datcompatibility)，不按库名猜；量不到就当普通库走原路径，
# 让原路径自己的查询报出连接/目录错误。DB_MODE 是「当前正在处理的库」的模式，主流程每库设一次。
#
# M 兼容库的内核事实(host109-vm202 GaussDB Kernel 507.0.0，2026-09-18 01:17–01:20 CST，
# 实例属主 gsql 逐条执行 perdb.sql 与本脚本的每条语句，库 loopfix_compat_m)：
#   * perdb.sql 第一条 DO 块报 `DO is not supported`，ON_ERROR_STOP 下整个文件停在那里(rc=3)；
#   * DROP/CREATE FUNCTION 一律报 `CREATE/DROP FUNCTION is not supported outside of upgrade mode
#     or not initial user`(实例初始用户执行也报)——explain 入口与列统计函数在 M 库里装不上，
#     随后的 REVOKE/GRANT ON FUNCTION 没有对象可指(语法错)；
#   * 内核允许的只有:CREATE SCHEMA IF NOT EXISTS(重复执行只 NOTICE，幂等)、两条 GRANT USAGE；
#   * `||` 是逻辑或(readiness_sql 返回 t/f 而不是位串)，拼位串用 CONCAT；
#   * 双引号是字符串:`ALTER ROLE ... IN DATABASE "库"` 语法错，库名要反引号(search_path 的值双引号照收)；
#   * `ALTER ROLE ... IN DATABASE ... RESET search_path` 语法错，`SET search_path TO DEFAULT` 可用，
#     且连同内核随 SET 一起写入的 current_schema 一并清掉；
#   * `DROP SCHEMA ... CASCADE` 语法错；不带 CASCADE 的 DROP SCHEMA 本身就连带删表。
# 所以 M 库只做 schema + 授权 + search_path，函数类跳过并明说「内核不支持」，验收也按这个预期。
DB_MODE=""
M_FUNCTIONS_UNSUPPORTED="explain plans and column statistics are unavailable in this database: GaussDB rejects CREATE FUNCTION in DBCOMPATIBILITY 'M' databases (CREATE/DROP FUNCTION is not supported outside of upgrade mode or not initial user)"

database_mode() { # <database>；设 DB_MODE
  local mode
  if mode=$(run_sql "$1" "SELECT datcompatibility FROM pg_catalog.pg_database WHERE datname = current_database();"); then
    DB_MODE=${mode//$'\r'/}
  else
    DB_MODE=""
  fi
}

# M 库标识符用反引号；名字里带反引号的转义写法没实测过，直接拒绝，不猜。
m_quote_ident() { # <identifier>
  [[ "$1" != *'`'* ]] || { echo "M_IDENTIFIER_UNSUPPORTED name=$1 (backtick in an M-compatibility identifier)" >&2; return 1; }
  printf '`%s`' "$1"
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

# 用户自建 schema 发现：黑名单按引擎各立(GaussDB Kernel 507 实测 47 schema、用户仅
# test/tpcc 两个,军规 8)。在 PG 侧黑名单之上追加 gauss 系专属:前缀 ^dbe_/^pkg_ 及
# cstore/db4ai/blockchain/coverage/snapshot/sqladvisor/xmltype/prvt_ilm/resource_manager/sys。
user_schemas() { # <database>
  run_sql "$1" "SELECT nspname FROM pg_catalog.pg_namespace
WHERE nspname !~ '^pg_'
  AND nspname !~ '^dbe_'
  AND nspname !~ '^pkg_'
  AND nspname NOT IN ('information_schema','public','dbdog','datadog','cstore','db4ai',
                      'blockchain','coverage','snapshot','sqladvisor','xmltype',
                      'prvt_ilm','resource_manager','sys')
ORDER BY nspname;"
}

# 监控角色在该库的现存 search_path 设置(pg_db_role_setting 是全局表，任意库可查本库行)。
current_role_setting() { # <database>
  run_sql "$1" "SELECT COALESCE(array_to_string(s.setconfig, ',', ''), '')
FROM pg_catalog.pg_db_role_setting s
JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
JOIN pg_catalog.pg_roles r ON r.oid = s.setrole
WHERE d.datname = current_database() AND r.rolname = '${MONITOR_ROLE}';"
}

quote_ident() { # <identifier>
  local raw=$1
  raw=${raw//\"/\"\"}
  printf '"%s"' "$raw"
}

# 追加语义：现有元素(我们只会写全双引号形，朴素逗号切分安全)在前，新发现的补后，
# public/pg_catalog 兜底压尾；合并去重后整体重写。pg_db_role_setting 是全局目录，
# ALTER ROLE ... IN DATABASE 在任意连接上执行即可，这里顺手用每库连接。
set_search_path() { # <database>
  local database=$1 existing entry value token
  local -a keep=() final=()
  local -A seen=()
  existing=$(current_role_setting "$database")
  if [[ -n "$existing" && "$existing" == *search_path=* ]]; then
    entry=${existing#*search_path=}
    entry=${entry%%,*}
    # setconfig 里 search_path 之后的其余 GUC 不该被吞掉，这里只取同一条目内的值；
    # 值里嵌套逗号属于人工手改场景，朴素切分按元素近似合并。
    IFS=',' read -ra tokens <<<"$entry"
    for token in "${tokens[@]}"; do
      token=${token//\"/}
      [[ -n "$token" ]] || continue
      [[ -n "${seen[$token]:-}" ]] || { keep+=("$token"); seen[$token]=1; }
    done
  fi
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    [[ -n "${seen[$token]:-}" ]] || { keep+=("$token"); seen[$token]=1; }
  done < <(user_schemas "$database")
  for token in public pg_catalog; do
    [[ -n "${seen[$token]:-}" ]] || { keep+=("$token"); seen[$token]=1; }
  done
  for token in "${keep[@]}"; do
    final+=("$(quote_ident "$token")")
  done
  (( ${#final[@]} > 0 )) || { echo "SEARCH_PATH_SKIP database=$database (no schemas)" >&2; return 0; }
  joined="$(IFS=,; echo "${final[*]}")"
  local db_ident="\"${database}\""
  if [[ "$DB_MODE" == M ]]; then
    db_ident=$(m_quote_ident "$database") || { echo "SEARCH_PATH_FAILED database=$database" >&2; return 1; }
  fi
  # run_sql 失败必须立刻冒出来:本函数常在 &&/|| 链里被调(set -e 失效),若继续走到
  # echo,其退出码会把失败洗白(2026-08-19 实锤,三引擎同修)。
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE ${db_ident} SET search_path TO ${joined};" || {
    echo "SEARCH_PATH_FAILED database=$database" >&2
    return 1
  }
  echo "SEARCH_PATH database=$database -> ${joined}"
}

# 就绪位串：schema|explain(public)|colstats|search_path。2026-08-02 起 DB 侧只保留
# 特权必需物;statements/activity 视图已由 collector 内联取代,存量库残留视图不影响验收。
readiness_sql=$(cat <<'SQL'
SELECT
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'dbdog'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'dbdog_explain_statement'
      -- 带 OUT/TABLE 参数的旧形态在 proc_outparam_override 下单参调用解析不到,不算就绪
      -- (位置 0 → 未配置 → configure 重跑 perdb.sql 替换)。A 兼容库 '' 即 NULL,别用 COALESCE 空串。
      AND (p.proargmodes IS NULL OR p.proargmodes::text !~ '[ot]')
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'dbdog' AND p.proname = 'column_statistics'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting s
    JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
    JOIN pg_catalog.pg_roles r ON r.oid = s.setrole
    WHERE d.datname = current_database() AND r.rolname = 'dbdog'
      AND array_to_string(s.setconfig, ',', '') LIKE '%search_path=%'
  ) THEN 1 ELSE 0 END;
SQL
)

# M 库位串：schema|usage(监控角色对 dbdog schema 有 USAGE)|search_path。没有函数位——
# 函数在 M 库里建不出来，不是「缺了待补」。CONCAT 在 A/B/C/PG/M 五种库上实测同为位串。
readiness_sql_m=$(cat <<'SQL'
SELECT CONCAT(
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'dbdog'
  ) THEN 1 ELSE 0 END, '|',
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace n
    WHERE n.nspname = 'dbdog' AND pg_catalog.has_schema_privilege('dbdog', n.oid, 'USAGE')
  ) THEN 1 ELSE 0 END, '|',
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting s
    JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
    JOIN pg_catalog.pg_roles r ON r.oid = s.setrole
    WHERE d.datname = current_database() AND r.rolname = 'dbdog'
      AND array_to_string(s.setconfig, ',', '') LIKE '%search_path=%'
  ) THEN 1 ELSE 0 END);
SQL
)

# 位串拆解：核心位置 1 = 已配置(普通库三位、M 库两位)；最后一位是 search_path(缺它只补，不弹清理确认)。
readiness_bits() { # <database>
  if [[ "$DB_MODE" == M ]]; then
    run_sql "$1" "$readiness_sql_m"
  else
    run_sql "$1" "$readiness_sql"
  fi
}

core_configured() { # <bits>
  if [[ "$DB_MODE" == M ]]; then
    [[ "$1" == 1\|1\|* ]]
  else
    [[ "$1" == 1\|1\|1\|* ]]
  fi
}

searchpath_set() { # <bits>
  [[ "$1" == *\|1 ]]
}

verify_database() { # <database>
  local database=$1 bits expected="1|1|1|1" legend="schema|explain|colstats|search_path"
  if [[ "$DB_MODE" == M ]]; then
    expected="1|1|1"
    legend="schema|usage|search_path"
  fi
  if ! bits=$(readiness_bits "$database"); then
    echo "VERIFY_FAILED database=$database (connection or catalog query failed)" >&2
    return 1
  fi
  bits=${bits//$'\r'/}
  if [[ "$bits" != "$expected" ]]; then
    echo "MISSING database=$database bits=$bits ($legend)" >&2
    return 1
  fi
  echo "READY database=$database"
  if [[ "$DB_MODE" == M ]]; then
    echo "FUNCTIONS_UNSUPPORTED database=$database datcompatibility=M: $M_FUNCTIONS_UNSUPPORTED"
  fi
}

# M 库只执行 perdb.sql 里内核允许的那部分：schema(CREATE SCHEMA 换成 M 上实测幂等的 IF NOT EXISTS，
# 原文的 DO 护栏 M 不许)与两条 USAGE 授权(与 perdb.sql 同文)；函数类整段跳过并明说。
configure_m_database() { # <database>
  local database=$1 statement
  for statement in \
    "CREATE SCHEMA IF NOT EXISTS dbdog;" \
    "GRANT USAGE ON SCHEMA dbdog TO dbdog;" \
    "GRANT USAGE ON SCHEMA public TO dbdog;"; do
    run_sql "$database" "$statement" || { echo "APPLY_FAILED database=$database ($statement)" >&2; return 1; }
  done
  echo "SKIP_FUNCTIONS database=$database datcompatibility=M: explain entry and column statistics functions not created ($M_FUNCTIONS_UNSUPPORTED)"
}

configure_database() { # <database>
  local database=$1
  echo "CONFIGURE database=$database"
  if [[ "$DB_MODE" == M ]]; then
    configure_m_database "$database" || return 1
  elif ! "${gsql_base[@]}" -d "$database" -v ON_ERROR_STOP=1 -f "$PERDB_SQL"; then
    echo "APPLY_FAILED database=$database" >&2
    return 1
  fi
  set_search_path "$database"
  verify_database "$database"
}

# 对称清理：configure 新增什么就清什么。public 入口函数 DROP schema 带不走,单独删;
# REVOKE USAGE 无害幂等。登录角色明确保留。
cleanup_database() { # <database>
  local database=$1
  echo "CLEANUP database=$database"
  if [[ "$DB_MODE" == M ]]; then
    cleanup_m_database "$database"
    return
  fi
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE \"${database}\" RESET search_path;" \
    || { echo "CLEANUP_FAILED database=$database (reset search_path)" >&2; return 1; }
  run_sql "$database" "DROP SCHEMA IF EXISTS dbdog CASCADE;" \
    || { echo "CLEANUP_FAILED database=$database (drop schema)" >&2; return 1; }
  # 两条签名:新形态 (text);带 OUT 的旧形态在 proc_outparam_override 下只认完整签名。
  run_sql "$database" "DROP FUNCTION IF EXISTS public.dbdog_explain_statement(l_query text, OUT explain json);" \
    || { echo "CLEANUP_FAILED database=$database (drop legacy public explain entry)" >&2; return 1; }
  run_sql "$database" "DROP FUNCTION IF EXISTS public.dbdog_explain_statement(text);" \
    || { echo "CLEANUP_FAILED database=$database (drop public explain entry)" >&2; return 1; }
  run_sql "$database" "REVOKE USAGE ON SCHEMA public FROM ${MONITOR_ROLE};" \
    || { echo "CLEANUP_FAILED database=$database (revoke public usage)" >&2; return 1; }
  verify_clean_database "$database"
}

# M 库的对称清理：configure 在 M 库只加了 schema、授权与 search_path，就只收这三样；函数从来没建出来，
# 没有 DROP FUNCTION 可发(M 上 DROP FUNCTION IF EXISTS 同样被内核拒绝)。
cleanup_m_database() { # <database>
  local database=$1 db_ident
  db_ident=$(m_quote_ident "$database") || { echo "CLEANUP_FAILED database=$database (reset search_path)" >&2; return 1; }
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE ${db_ident} SET search_path TO DEFAULT;" \
    || { echo "CLEANUP_FAILED database=$database (reset search_path)" >&2; return 1; }
  run_sql "$database" "DROP SCHEMA IF EXISTS dbdog;" \
    || { echo "CLEANUP_FAILED database=$database (drop schema)" >&2; return 1; }
  run_sql "$database" "REVOKE USAGE ON SCHEMA public FROM ${MONITOR_ROLE};" \
    || { echo "CLEANUP_FAILED database=$database (revoke public usage)" >&2; return 1; }
  verify_clean_database "$database"
}

verify_clean_database() { # <database>
  local database=$1 bits expected="0|0|0|0" legend="schema|explain|colstats|search_path"
  if [[ "$DB_MODE" == M ]]; then
    expected="0|0|0"
    legend="schema|usage|search_path"
  fi
  bits=$(readiness_bits "$database") || { echo "VERIFY_FAILED database=$database" >&2; return 1; }
  bits=${bits//$'\r'/}
  if [[ "$bits" != "$expected" ]]; then
    echo "CLEAN_VERIFY_UNEXPECTED database=$database bits=$bits ($legend)" >&2
    return 1
  fi
  echo "CLEANED database=$database"
}

# ---- 主流程 ----

if [[ -n "$target_db" ]]; then
  databases=("$target_db")
else
  list_sql="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false AND datallowconn ORDER BY datname;"
  if ! database_output=$("${gsql_base[@]}" -d "$GAUSSDB_ADMIN_DB" -A -t -v ON_ERROR_STOP=1 -c "$list_sql"); then
    echo "failed to enumerate GaussDB databases via $GAUSSDB_ADMIN_DB" >&2
    exit 1
  fi
  databases=()
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

# 前置门:监控角色必须先存在(实例级对象,归向导第 1 步的 global SQL 管;安装器只验不建)。
# GaussDB 查 pg_user,提示里带上 MONADMIN 语义;HBA 由安装器写、密码加密模式由安装器
# warn 指路,这里只管角色在不在。
global_hint="$SCRIPT_DIR/init-dbdog-user-gaussdb-global.sql"
role_exists=$(run_sql "$GAUSSDB_ADMIN_DB" "SELECT 1 FROM pg_catalog.pg_user WHERE usename='${MONITOR_ROLE}';")
if [[ "$role_exists" != 1 ]]; then
  echo "PREREQ_MISSING: monitoring role '${MONITOR_ROLE}' does not exist on this instance." >&2
  echo "This script never creates it (no password handling). Create it once per instance:" >&2
  echo "  gsql -d ${GAUSSDB_ADMIN_DB} -p ${GAUSSDB_PORT} -v dbdog_pw=\"'密码'\" -f ${global_hint}" >&2
  exit 1
fi

failures=0

if [[ "$want_cleanup" == true ]]; then
  echo "About to clean up monitoring objects in: ${databases[*]}"
  echo "(dbdog schema + public explain entry + granted public USAGE + search_path setting; the dbdog login role is kept)"
  confirm "Remove monitoring collection from these databases?" || { echo "aborted; nothing changed" >&2; exit 1; }
  for database in "${databases[@]}"; do
    database_mode "$database"
    cleanup_database "$database" || failures=$((failures + 1))
  done
  if ((failures > 0)); then
    echo "GaussDB cleanup failed for $failures database(s)" >&2
    exit 1
  fi
  echo "GaussDB cleanup complete: ${#databases[@]} database(s)"
  exit 0
fi

for database in "${databases[@]}"; do
  database_mode "$database"
  bits=$(readiness_bits "$database") || { echo "READINESS_FAILED database=$database" >&2; failures=$((failures + 1)); continue; }
  bits=${bits//$'\r'/}
  if ! core_configured "$bits"; then
    # 未配置(或上次半途而废)→ 补齐并验收
    configure_database "$database" || failures=$((failures + 1))
  elif ! searchpath_set "$bits"; then
    # 核心对象在、search_path 缺(旧版脚本装的库)→ 只补 search_path
    echo "TOPOFF database=$database (core objects present, search_path missing)"
    set_search_path "$database" && verify_database "$database" || failures=$((failures + 1))
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
  echo "GaussDB per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "GaussDB per-database DBM setup complete: ${#databases[@]} database(s)"
