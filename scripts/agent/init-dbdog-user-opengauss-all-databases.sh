#!/usr/bin/env bash
# Apply or verify openGauss's per-database DBM objects across the databases that
# query sampling can reference. This intentionally lives in deployment tooling:
# the monitoring Agent must not mutate monitored databases at runtime.
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

mode=apply
select_all=false
declare -a requested_databases=()
declare -a excluded_databases=()

usage() {
  cat <<'EOF'
Usage:
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh --all
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh --check --all
  OPENGAUSS_PORT=<port> [connection env...] /opt/dbdog-agent/scripts/init-dbdog-user-opengauss-all-databases.sh [--check] DB [DB...]

Options:
  --all           enumerate every non-template, connectable database
  --check         verify objects only; make no database changes
  --exclude DB    omit DB from --all (repeatable)
  -h, --help      show this help

Connection environment:
  OPENGAUSS_GSQL_BIN    gsql executable (default: gsql)
  OPENGAUSS_HOST        host name or local socket directory (optional)
  OPENGAUSS_PORT        port (required)
  OPENGAUSS_ADMIN_DB    database used for --all enumeration (default: postgres)
  OPENGAUSS_ADMIN_USER  administrative user passed to gsql with -U (optional)
  OPENGAUSS_PERDB_SQL   per-database SQL file override (optional)

Authentication stays in gsql's normal protected mechanisms (for example an OS
database account or password environment/file). This script never accepts or
prints a password argument.
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

: "${OPENGAUSS_PORT:?set OPENGAUSS_PORT explicitly}"
command -v "$GSQL_BIN" >/dev/null 2>&1 || { echo "gsql executable not found: $GSQL_BIN" >&2; exit 1; }
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

gsql_base=("$GSQL_BIN" -p "$OPENGAUSS_PORT")
[[ -z "$OPENGAUSS_HOST" ]] || gsql_base+=(-h "$OPENGAUSS_HOST")
[[ -z "$OPENGAUSS_ADMIN_USER" ]] || gsql_base+=(-U "$OPENGAUSS_ADMIN_USER")

is_excluded() {
  local candidate=$1 excluded
  for excluded in "${excluded_databases[@]}"; do
    [[ "$candidate" != "$excluded" ]] || return 0
  done
  return 1
}

if [[ "$select_all" == true ]]; then
  list_sql="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false AND datallowconn ORDER BY datname;"
  if ! database_output=$("${gsql_base[@]}" -d "$OPENGAUSS_ADMIN_DB" -A -t -v ON_ERROR_STOP=1 -c "$list_sql"); then
    echo "failed to enumerate openGauss databases via $OPENGAUSS_ADMIN_DB" >&2
    exit 1
  fi
  while IFS= read -r database; do
    [[ -n "$database" ]] || continue
    is_excluded "$database" || requested_databases+=("$database")
  done <<< "$database_output"
fi

[[ ${#requested_databases[@]} -gt 0 ]] || { echo "no databases selected" >&2; exit 1; }

# 2026-08-02 起 DB 侧只保留特权必需物:校验 schema + explain function + column_statistics。
# statements/activity 视图已由 collector 内联取代,存量库残留视图不影响验收。
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
  ) THEN 1 ELSE 0 END;
SQL
)

verify_database() {
  local database=$1 readiness schema_ready explain_ready colstats_ready
  if ! readiness=$("${gsql_base[@]}" -d "$database" -A -t -v ON_ERROR_STOP=1 -c "$readiness_sql"); then
    echo "VERIFY_FAILED database=$database (connection or catalog query failed)" >&2
    return 1
  fi
  readiness=${readiness//$'\r'/}
  IFS='|' read -r schema_ready explain_ready colstats_ready <<< "$readiness"
  if [[ "$schema_ready|$explain_ready|$colstats_ready" != "1|1|1" ]]; then
    echo "MISSING database=$database schema=$schema_ready explain=$explain_ready colstats=$colstats_ready" >&2
    return 1
  fi
  echo "READY database=$database"
}

failures=0
for database in "${requested_databases[@]}"; do
  if [[ "$mode" == apply ]]; then
    echo "APPLY database=$database"
    if ! "${gsql_base[@]}" -d "$database" -v ON_ERROR_STOP=1 -f "$PERDB_SQL"; then
      echo "APPLY_FAILED database=$database" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  verify_database "$database" || failures=$((failures + 1))
done

if ((failures > 0)); then
  echo "openGauss per-database DBM setup failed for $failures database(s)" >&2
  exit 1
fi
echo "openGauss per-database DBM setup $mode complete: ${#requested_databases[@]} database(s)"
