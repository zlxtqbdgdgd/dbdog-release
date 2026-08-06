#!/usr/bin/env bash
# Apply or verify PostgreSQL's per-database DBM objects across the databases that
# query sampling can reference. This intentionally lives in deployment tooling:
# the monitoring Agent must not mutate monitored databases at runtime.
#
# 与 openGauss/GaussDB 同名脚本同形;引擎差异只在:psql 而非 gsql、schema 里还要建
# pg_stat_statements 扩展、canonical explain 入口在 dbdog schema 而不是 public
# (PG 的 SECURITY DEFINER 不改写 search_path,不受 PITFALLS #22b 影响)。
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

mode=apply
select_all=false
declare -a requested_databases=()
declare -a excluded_databases=()

usage() {
  cat <<'EOF'
Usage:
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh --all
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh --check --all
  PG_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-pg-all-databases.sh [--check] DB [DB...]

Options:
  --all           enumerate every non-template, connectable database
  --check         verify objects only; make no database changes
  --exclude DB    omit DB from --all (repeatable)
  -h, --help      show this help

Connection environment:
  PG_PSQL_BIN     psql executable (default: psql)
  PG_HOST         host name or local socket directory (optional)
  PG_PORT         port (required)
  PG_ADMIN_DB     database used for --all enumeration (default: postgres)
  PG_ADMIN_USER   administrative user passed to psql with -U (optional)
  PG_PERDB_SQL    per-database SQL file override (optional)

Authentication stays in psql's normal protected mechanisms (for example an OS
database account, PGPASSFILE, or an interactive prompt). This script never
accepts or prints a password argument.
EOF
}

while (($#)); do
  case "$1" in
    --all)
      select_all=true
      shift
      ;;
    --check)
      mode=check
      shift
      ;;
    --exclude)
      (($# >= 2)) || { echo "--exclude requires a database name" >&2; exit 2; }
      excluded_databases+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      requested_databases+=("$@")
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      requested_databases+=("$1")
      shift
      ;;
  esac
done

: "${PG_PORT:?set PG_PORT explicitly}"
command -v "$PSQL_BIN" >/dev/null 2>&1 || { echo "psql executable not found: $PSQL_BIN" >&2; exit 1; }
[[ -f "$PERDB_SQL" ]] || { echo "per-database SQL not found: $PERDB_SQL" >&2; exit 1; }

if [[ "$select_all" == true && ${#requested_databases[@]} -gt 0 ]]; then
  echo "use either --all or explicit database names, not both" >&2
  exit 2
fi
if [[ "$select_all" == false && ${#requested_databases[@]} -eq 0 ]]; then
  echo "select databases with --all or explicit database names" >&2
  usage >&2
  exit 2
fi
if [[ "$select_all" == false && ${#excluded_databases[@]} -gt 0 ]]; then
  echo "--exclude is only valid with --all" >&2
  exit 2
fi

psql_base=("$PSQL_BIN" -p "$PG_PORT" -X -q)
[[ -z "$PG_HOST" ]] || psql_base+=(-h "$PG_HOST")
[[ -z "$PG_ADMIN_USER" ]] || psql_base+=(-U "$PG_ADMIN_USER")

is_excluded() {
  local candidate=$1 excluded
  for excluded in "${excluded_databases[@]}"; do
    [[ "$candidate" != "$excluded" ]] || return 0
  done
  return 1
}

if [[ "$select_all" == true ]]; then
  list_sql="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false AND datallowconn ORDER BY datname;"
  if ! database_output=$("${psql_base[@]}" -d "$PG_ADMIN_DB" -A -t -v ON_ERROR_STOP=1 -c "$list_sql"); then
    echo "failed to enumerate PostgreSQL databases via $PG_ADMIN_DB" >&2
    exit 1
  fi
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    is_excluded "$database" || requested_databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#requested_databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

# DB 侧特权必需物:dbdog schema + explain function + column_statistics + pg_stat_statements 扩展。
# 与 openGauss/GaussDB 的差异:那两个引擎无 pg_stat_statements(走 dbe_perf.statement),
# 且 canonical explain 入口在 public;PG 两者都在 dbdog schema 下。
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
  ) THEN 1 ELSE 0 END;
SQL
)

verify_database() {
  local database=$1 readiness schema_ready explain_ready colstats_ready pgss_ready buffercache_ready
  if ! readiness=$("${psql_base[@]}" -d "$database" -A -t -v ON_ERROR_STOP=1 -c "$readiness_sql"); then
    echo "VERIFY_FAILED database=$database (connection or catalog query failed)" >&2
    return 1
  fi
  readiness=${readiness//$'\r'/}
  IFS='|' read -r schema_ready explain_ready colstats_ready pgss_ready buffercache_ready <<< "$readiness"
  if [[ "$schema_ready|$explain_ready|$colstats_ready|$pgss_ready|$buffercache_ready" != "1|1|1|1|1" ]]; then
    echo "MISSING database=$database schema=$schema_ready explain=$explain_ready" \
      "colstats=$colstats_ready pg_stat_statements=$pgss_ready pg_buffercache=$buffercache_ready" >&2
    return 1
  fi
  echo "READY database=$database"
}

failures=0
for database in "${requested_databases[@]}"; do
  if [[ "$mode" == apply ]]; then
    echo "APPLY database=$database"
    if ! "${psql_base[@]}" -d "$database" -v ON_ERROR_STOP=1 -f "$PERDB_SQL"; then
      echo "APPLY_FAILED database=$database" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  verify_database "$database" || failures=$((failures + 1))
done

if ((failures > 0)); then
  echo "PostgreSQL per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "PostgreSQL per-database DBM setup $mode complete: ${#requested_databases[@]} database(s)"
