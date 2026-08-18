#!/usr/bin/env bash
# Configure or clean up PostgreSQL's per-database DBM objects — one entry, one goal:
# give the monitoring user what it needs in a database, or take exactly that back.
# This intentionally lives in deployment tooling: the monitoring Agent must not
# mutate monitored databases at runtime.
#
# 与 openGauss/GaussDB 同名脚本同形;引擎差异只在:psql 而非 gsql、schema 里还要建
# pg_stat_statements/pg_buffercache 扩展、canonical explain 入口在 dbdog schema 而不是
# public (PG 的 SECURITY DEFINER 不改写 search_path,不受 PITFALLS #22b 影响)。
#
# 语义(2026-08-18 五合一重设计,替代旧 --all/--check/--exclude 三开关):
#   无 --db            对实例内每个非 template 可连库做 configure
#   --db X             X 未配置→configure;已配置→先问「是否去掉这个库的监控采集」,
#                      确认才清理(对称清理),误操作回答 N 则什么都不动
#   --cleanup          显式清理(--db X 清单库,无 --db 清全实例用户库),执行前必确认
#   configure = per-db SQL(perdb.sql 原样) + ALTER ROLE dbdog IN DATABASE X SET search_path
#              (把该库用户自建 schema 追加到监控用户,追加语义:与现值合并去重)
#   cleanup   = 对称原则:configure 往库里新增了什么就同等清掉什么——dbdog schema、
#              授出的 public USAGE、search_path 设置;唯一例外:扩展保留(业务可能自用),
#              dbdog 登录角色也保留(实例级对象,重接入零成本)。
#
# 本仓是这个脚本的唯一 owning path：agent-install.sh 把它与同目录的 per-db SQL 一起装到
# DB 主机的 /opt/dbdog-agent/scripts/，控制台「采集配置」页按该绝对路径直接给出可执行命令
# （dbdog-web src/lib/db-init-commands.ts 的 DB_INIT_SCRIPT_DIR）。新增业务库后由 DBA 在 DB
# 主机上执行；改路径或改脚本名要同步改控制台，否则页面上的命令会指向不存在的文件。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PERDB_SQL=${PG_PERDB_SQL:-$SCRIPT_DIR/init-dbdog-user-pg-perdb.sql}
PSQL_BIN=${PG_PSQL_BIN:-psql}
PG_ADMIN_DB=${PG_ADMIN_DB:-postgres}
PG_HOST=${PG_HOST:-}
PG_ADMIN_USER=${PG_ADMIN_USER:-}

MONITOR_ROLE=dbdog

target_db=""
want_cleanup=false
assume_yes=false

usage() {
  cat <<'EOF'
Usage:
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh --db DB
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh --db DB --cleanup
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh --cleanup

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
cleanup   = exactly what configure added, taken back: dbdog schema, granted
            public USAGE, search_path setting. Extensions (pg_stat_statements,
            pg_buffercache) and the dbdog login role are kept.

Connection environment:
  PG_PSQL_BIN     psql executable (default: psql)
  PG_HOST         host name or local socket directory (optional)
  PG_PORT         port (required)
  PG_ADMIN_DB     database used for enumeration (default: postgres)
  PG_ADMIN_USER   administrative user passed to psql with -U (optional)
  PG_PERDB_SQL    per-database SQL file override (optional)

Prerequisite: the dbdog login role must already exist (init-dbdog-user-pg-global.sql,
run once per instance). Authentication stays in psql's normal protected mechanisms
(for example an OS database account, PGPASSFILE, or an interactive prompt). This
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

: "${PG_PORT:?set PG_PORT explicitly}"
command -v "$PSQL_BIN" >/dev/null 2>&1 || { echo "psql executable not found: $PSQL_BIN" >&2; exit 1; }
[[ -f "$PERDB_SQL" ]] || { echo "per-database SQL not found: $PERDB_SQL" >&2; exit 1; }

psql_base=("$PSQL_BIN" -p "$PG_PORT" -X -q)
[[ -z "$PG_HOST" ]] || psql_base+=(-h "$PG_HOST")
[[ -z "$PG_ADMIN_USER" ]] || psql_base+=(-U "$PG_ADMIN_USER")

# 每库一连接执行一条 SQL；-A -t 只取值，ON_ERROR_STOP 让失败立刻冒出来。
run_sql() { # <database> <sql>
  "${psql_base[@]}" -d "$1" -A -t -v ON_ERROR_STOP=1 -c "$2"
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

# 用户自建 schema 发现：黑名单按引擎各立(实测三引擎系统 schema 清单差异大，军规 8)。
# PG 侧系统/监控自带：pg_* 前缀、information_schema、public、dbdog、datadog。
user_schemas() { # <database>
  run_sql "$1" "SELECT nspname FROM pg_catalog.pg_namespace
WHERE nspname !~ '^pg_'
  AND nspname NOT IN ('information_schema','public','dbdog','datadog')
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
# public/pg_catalog 兜底压尾；合并去重后整体重写。SET 的多值分隔符是逗号(list 语法)，
# 数组 join 不能用 ${arr[*]}(空格连)——2026-08-18 116 机首验实锤。
# pg_db_role_setting 是全局目录，ALTER ROLE ... IN DATABASE 在任意连接上执行即可。
set_search_path() { # <database>
  local database=$1 existing entry value token joined
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
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE \"${database}\" SET search_path TO ${joined};"
  echo "SEARCH_PATH database=$database -> ${joined}"
}

# 就绪位串：schema|explain|colstats|pg_stat_statements|pg_buffercache|search_path。
# 与 openGauss/GaussDB 的差异：PG 要两个扩展，explain 入口在 dbdog schema。
readiness_sql=$(cat <<'SQL'
SELECT
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'dbdog'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'dbdog' AND p.proname = 'explain_statement'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'dbdog' AND p.proname = 'column_statistics'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_stat_statements'
  ) THEN 1 ELSE 0 END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_buffercache'
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

# 位串拆解：核心五位置 1 = 已配置；第六位是 search_path(缺它只补，不弹清理确认)。
readiness_bits() { # <database> -> "core" or "core|searchpath" readiness string
  run_sql "$1" "$readiness_sql"
}

core_configured() { # <bits>
  local bits=$1
  [[ "${bits%%|*}" != "0" ]] || return 1
  [[ "$bits" == 1\|1\|1\|1\|1\|* ]]
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
  if [[ "$bits" != "1|1|1|1|1|1" ]]; then
    echo "MISSING database=$database bits=$bits (schema|explain|colstats|pg_stat_statements|pg_buffercache|search_path)" >&2
    return 1
  fi
  echo "READY database=$database"
}

configure_database() { # <database>
  local database=$1
  echo "CONFIGURE database=$database"
  if ! "${psql_base[@]}" -d "$database" -v ON_ERROR_STOP=1 -f "$PERDB_SQL"; then
    echo "APPLY_FAILED database=$database" >&2
    return 1
  fi
  set_search_path "$database"
  verify_database "$database"
}

# 对称清理：configure 新增什么就清什么。REVOKE USAGE 无害幂等；公共角色 PUBLIC 自带的
# public USAGE 不归我们管也不必验(has_schema_privilege 分不清直授与经 PUBLIC 继承，执行
# 成功即回收完成)。扩展与登录角色明确保留。
cleanup_database() { # <database>
  local database=$1
  echo "CLEANUP database=$database"
  run_sql "$database" "ALTER ROLE ${MONITOR_ROLE} IN DATABASE \"${database}\" RESET search_path;" \
    || { echo "CLEANUP_FAILED database=$database (reset search_path)" >&2; return 1; }
  run_sql "$database" "DROP SCHEMA IF EXISTS dbdog CASCADE;" \
    || { echo "CLEANUP_FAILED database=$database (drop schema)" >&2; return 1; }
  run_sql "$database" "REVOKE USAGE ON SCHEMA public FROM ${MONITOR_ROLE};" \
    || { echo "CLEANUP_FAILED database=$database (revoke public usage)" >&2; return 1; }
  verify_clean_database "$database"
}

verify_clean_database() { # <database>
  local database=$1 bits
  bits=$(readiness_bits "$database") || { echo "VERIFY_FAILED database=$database" >&2; return 1; }
  bits=${bits//$'\r'/}
  if [[ "$bits" != "0|0|0|1|1|0" ]]; then
    echo "CLEAN_VERIFY_UNEXPECTED database=$database bits=$bits (schema|explain|colstats|pg_stat_statements|pg_buffercache|search_path; extensions expected to remain)" >&2
    return 1
  fi
  echo "CLEANED database=$database"
}

# ---- 主流程 ----

if [[ -n "$target_db" ]]; then
  databases=("$target_db")
else
  list_sql="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false AND datallowconn ORDER BY datname;"
  if ! database_output=$("${psql_base[@]}" -d "$PG_ADMIN_DB" -A -t -v ON_ERROR_STOP=1 -c "$list_sql"); then
    echo "failed to enumerate PostgreSQL databases via $PG_ADMIN_DB" >&2
    exit 1
  fi
  databases=()
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

failures=0

if [[ "$want_cleanup" == true ]]; then
  echo "About to clean up monitoring objects in: ${databases[*]}"
  echo "(dbdog schema + granted public USAGE + search_path setting; extensions and the dbdog login role are kept)"
  confirm "Remove monitoring collection from these databases?" || { echo "aborted; nothing changed" >&2; exit 1; }
  for database in "${databases[@]}"; do
    cleanup_database "$database" || failures=$((failures + 1))
  done
  if ((failures > 0)); then
    echo "PostgreSQL cleanup failed for $failures database(s)" >&2
    exit 1
  fi
  echo "PostgreSQL cleanup complete: ${#databases[@]} database(s)"
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
  echo "PostgreSQL per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "PostgreSQL per-database DBM setup complete: ${#databases[@]} database(s)"
