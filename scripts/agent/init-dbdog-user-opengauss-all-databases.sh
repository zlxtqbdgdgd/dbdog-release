#!/usr/bin/env bash
# Configure or clean up openGauss's per-database DBM objects — one entry, one goal:
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
# 与 PG 版同名脚本同形;引擎差异只在:gsql 而非 psql、无 pg_stat_statements/pg_buffercache
# 扩展位(readiness 三位)、canonical explain 入口在 public 而不是 dbdog schema
# (SECURITY DEFINER 按函数所属 schema 解析未限定表名)、
# 用户 schema 黑名单长得多(dbe_* 等 15 个系统 schema)。
#
# 本仓是这个脚本的唯一 owning path：agent-install.sh 把它与同目录的 per-db SQL 一起装到
# DB 主机的 /opt/dbdog-agent/scripts/，控制台「采集配置」页按该绝对路径直接给出可执行命令
# （dbdog-web src/lib/db-init-commands.ts 的 DB_INIT_SCRIPT_DIR）。新增业务库后由 DBA 在 DB
# 主机上执行；改路径或改脚本名要同步改控制台，否则页面上的命令会指向不存在的文件。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PERDB_SQL=${OPENGAUSS_PERDB_SQL:-$SCRIPT_DIR/init-dbdog-user-opengauss-perdb.sql}
GSQL_BIN=${OPENGAUSS_GSQL_BIN:-gsql}
OPENGAUSS_ADMIN_DB=${OPENGAUSS_ADMIN_DB:-postgres}
OPENGAUSS_HOST=${OPENGAUSS_HOST:-}
OPENGAUSS_ADMIN_USER=${OPENGAUSS_ADMIN_USER:-}

MONITOR_ROLE=dbdog

target_db=""
want_cleanup=false
assume_yes=false

usage() {
  cat <<'EOF'
Usage:
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh --db DB
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh --db DB --cleanup
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh --cleanup

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
  OPENGAUSS_GSQL_BIN    gsql executable (default: gsql)
  OPENGAUSS_HOST        host name or local socket directory (optional)
  OPENGAUSS_PORT        port (required)
  OPENGAUSS_ADMIN_DB    database used for enumeration (default: postgres)
  OPENGAUSS_ADMIN_USER  administrative user passed to gsql with -U (optional)
  OPENGAUSS_PERDB_SQL   per-database SQL file override (optional)

Prerequisite: the dbdog login role must already exist (created by agent-install.sh
without --host-only, or run init-dbdog-user-opengauss-global.sql once per instance —
it is installed next to this script). Authentication stays in gsql's normal protected
mechanisms (for example an OS database account or password environment/file). This
script never accepts or prints a password argument.
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

: "${OPENGAUSS_PORT:?set OPENGAUSS_PORT explicitly}"
command -v "$GSQL_BIN" >/dev/null 2>&1 || { echo "gsql executable not found: $GSQL_BIN" >&2; exit 1; }
[[ -f "$PERDB_SQL" ]] || { echo "per-database SQL not found: $PERDB_SQL" >&2; exit 1; }

gsql_base=("$GSQL_BIN" -p "$OPENGAUSS_PORT")
[[ -z "$OPENGAUSS_HOST" ]] || gsql_base+=(-h "$OPENGAUSS_HOST")
[[ -z "$OPENGAUSS_ADMIN_USER" ]] || gsql_base+=(-U "$OPENGAUSS_ADMIN_USER")

# 每库一连接执行一条 SQL；-A -t 只取值，ON_ERROR_STOP 让失败立刻冒出来。
run_sql() { # <database> <sql>
  "${gsql_base[@]}" -d "$1" -A -t -v ON_ERROR_STOP=1 -c "$2"
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

# 用户自建 schema 发现：黑名单按引擎各立(openGauss 系统 schema 实测 19 个,用户仅 2-3 个,
# 军规 8)。在 PG 侧黑名单之上追加 gauss 系专属:前缀 ^dbe_ 及 cstore/db4ai/blockchain/
# coverage/snapshot/sqladvisor/xmltype/pkg_*/prvt_ilm/resource_manager/sys。
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
  # run_sql 失败必须立刻冒出来:本函数常在 &&/|| 链里被调(set -e 失效),若继续走到
  # echo,其退出码会把失败洗白(2026-08-19 实锤,三引擎同修)。
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE \"${database}\" SET search_path TO ${joined};" || {
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

# 位串拆解：核心三位置 1 = 已配置；第四位是 search_path(缺它只补，不弹清理确认)。
readiness_bits() { # <database>
  run_sql "$1" "$readiness_sql"
}

core_configured() { # <bits>
  [[ "$1" == 1\|1\|1\|* ]]
}

searchpath_set() { # <bits>
  [[ "$1" == *\|1 ]]
}

verify_database() { # <database>
  local database=$1 bits
  if ! bits=$(readiness_bits "$database"); then
    echo "VERIFY_FAILED database=$database (connection or catalog query failed)" >&2
    return 1
  fi
  bits=${bits//$'\r'/}
  if [[ "$bits" != "1|1|1|1" ]]; then
    echo "MISSING database=$database bits=$bits (schema|explain|colstats|search_path)" >&2
    return 1
  fi
  echo "READY database=$database"
}

configure_database() { # <database>
  local database=$1
  echo "CONFIGURE database=$database"
  if ! "${gsql_base[@]}" -d "$database" -v ON_ERROR_STOP=1 -f "$PERDB_SQL"; then
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
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE \"${database}\" RESET search_path;" \
    || { echo "CLEANUP_FAILED database=$database (reset search_path)" >&2; return 1; }
  run_sql "$database" "DROP SCHEMA IF EXISTS dbdog CASCADE;" \
    || { echo "CLEANUP_FAILED database=$database (drop schema)" >&2; return 1; }
  run_sql "$database" "DROP FUNCTION IF EXISTS public.dbdog_explain_statement(text);" \
    || { echo "CLEANUP_FAILED database=$database (drop public explain entry)" >&2; return 1; }
  run_sql "$database" "REVOKE USAGE ON SCHEMA public FROM ${MONITOR_ROLE};" \
    || { echo "CLEANUP_FAILED database=$database (revoke public usage)" >&2; return 1; }
  verify_clean_database "$database"
}

verify_clean_database() { # <database>
  local database=$1 bits
  bits=$(readiness_bits "$database") || { echo "VERIFY_FAILED database=$database" >&2; return 1; }
  bits=${bits//$'\r'/}
  if [[ "$bits" != "0|0|0|0" ]]; then
    echo "CLEAN_VERIFY_UNEXPECTED database=$database bits=$bits (schema|explain|colstats|search_path)" >&2
    return 1
  fi
  echo "CLEANED database=$database"
}

# ---- 主流程 ----

if [[ -n "$target_db" ]]; then
  databases=("$target_db")
else
  list_sql="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false AND datallowconn ORDER BY datname;"
  if ! database_output=$("${gsql_base[@]}" -d "$OPENGAUSS_ADMIN_DB" -A -t -v ON_ERROR_STOP=1 -c "$list_sql"); then
    echo "failed to enumerate openGauss databases via $OPENGAUSS_ADMIN_DB" >&2
    exit 1
  fi
  databases=()
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

# 前置门:监控角色必须先存在(实例级对象,归安装器建号链或 global SQL 管)。
# openGauss 查 pg_user(og7 的 pg_roles 对非超管隐藏性更强,pg_user 是脚本
# 既有口径);缺角色时给一句人话和现成命令,不再等 perdb.sql 深处才炸。
global_hint="$SCRIPT_DIR/init-dbdog-user-opengauss-global.sql"
role_exists=$(run_sql "$OPENGAUSS_ADMIN_DB" "SELECT 1 FROM pg_catalog.pg_user WHERE usename='${MONITOR_ROLE}';")
if [[ "$role_exists" != 1 ]]; then
  echo "PREREQ_MISSING: monitoring role '${MONITOR_ROLE}' does not exist on this instance." >&2
  echo "This script never creates it (no password handling). Create it once per instance:" >&2
  echo "  gsql -d ${OPENGAUSS_ADMIN_DB} -p ${OPENGAUSS_PORT} -v dbdog_pw=\"'密码'\" -f ${global_hint}" >&2
  exit 1
fi

failures=0

if [[ "$want_cleanup" == true ]]; then
  echo "About to clean up monitoring objects in: ${databases[*]}"
  echo "(dbdog schema + public explain entry + granted public USAGE + search_path setting; the dbdog login role is kept)"
  confirm "Remove monitoring collection from these databases?" || { echo "aborted; nothing changed" >&2; exit 1; }
  for database in "${databases[@]}"; do
    cleanup_database "$database" || failures=$((failures + 1))
  done
  if ((failures > 0)); then
    echo "openGauss cleanup failed for $failures database(s)" >&2
    exit 1
  fi
  echo "openGauss cleanup complete: ${#databases[@]} database(s)"
  exit 0
fi

for database in "${databases[@]}"; do
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
  echo "openGauss per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "openGauss per-database DBM setup complete: ${#databases[@]} database(s)"
