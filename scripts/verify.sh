#!/usr/bin/env bash
# 内网全家桶基础验收：配置合同、数据库查询和 HTTP 存活；不替代业务场景测试。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0

check() { # check <名称> <命令/函数> [参数...]
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    log "通过: $name"
  else
    warn "失败: $name"
    failures=$((failures + 1))
  fi
}

load_env() { # load_env <服务名>
  local envf="$ETC_DIR/$1.env"
  [ -f "$envf" ] || return 1
  set -a
  if ! source "$envf"; then
    set +a
    return 1
  fi
  set +a
}

clear_probe_env() {
  # 验收的是持久化到 ~/dbdog/etc/*.env 的值，不能借用调用者临时 export 的配置。
  unset PG_DSN DATABASE_URL CH_URL CH_DATABASE DBDOG_METRIC_URL
  unset DBDOG_CH_ADDR DBDOG_CH_DATABASE DBDOG_CH_USERNAME CH_PASSWORD
  unset DBDOG_HTTP_ADDR DDSQL_ADDR PORT DBDOG_HTTP_PORT
  unset DBDOG_INTERNAL_TOKEN DBDOG_OAUTH_JWT_SECRET DBDOG_SERVER_URL
  unset PUBLIC_APP_URL PUBLIC_INGEST_URL PUBLIC_MCP_URL
  unset DBDOG_BASE_URL DBDOG_OAUTH_ISSUER DBDOG_PUBLIC_MCP_URL DBDOG_APP_BASE_URL
}

env_value() ( # env_value <服务名> <变量名>
  local svc="$1" key="$2"
  clear_probe_env
  load_env "$svc" || return 1
  eval "printf '%s' \"\${$key:-}\""
)

valid_secret() {
  local value="$1"
  [ "${#value}" -ge 16 ] || return 1
  case "$value" in
    change-me* | *user:pass*) return 1 ;;
  esac
}

valid_url() {
  local value="$1"
  case "$value" in
    http://* | https://*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *epyc-256c.e6.luyouxia.net* | *change-me*) return 1 ;;
  esac
}

retry_http() { # retry_http <URL> [curl 其他参数...]
  local url="$1" i; shift
  for ((i=1; i<=30; i++)); do
    curl -fsS "$@" "$url" && return 0
    sleep 1
  done
  return 1
}

probe_env_files() {
  local svc
  for svc in dbdog-server ddsql-server dbdog-web dbdog-mcp; do
    [ -f "$ETC_DIR/$svc.env" ] || return 1
  done
}

probe_shared_internal_token() {
  local server web mcp
  server="$(env_value dbdog-server DBDOG_INTERNAL_TOKEN)" || return 1
  web="$(env_value dbdog-web DBDOG_INTERNAL_TOKEN)" || return 1
  mcp="$(env_value dbdog-mcp DBDOG_INTERNAL_TOKEN)" || return 1
  valid_secret "$server" && [ "$server" = "$web" ] && [ "$server" = "$mcp" ]
}

probe_shared_oauth_secret() {
  local web mcp
  web="$(env_value dbdog-web DBDOG_OAUTH_JWT_SECRET)" || return 1
  mcp="$(env_value dbdog-mcp DBDOG_OAUTH_JWT_SECRET)" || return 1
  valid_secret "$web" && [ "$web" = "$mcp" ]
}

probe_web_urls() {
  local key value
  for key in DBDOG_SERVER_URL PUBLIC_APP_URL PUBLIC_INGEST_URL PUBLIC_MCP_URL; do
    value="$(env_value dbdog-web "$key")" || return 1
    valid_url "$value" || return 1
  done
}

probe_mcp_urls() {
  local key value
  for key in DBDOG_BASE_URL DBDOG_OAUTH_ISSUER DBDOG_PUBLIC_MCP_URL DBDOG_APP_BASE_URL; do
    value="$(env_value dbdog-mcp "$key")" || return 1
    valid_url "$value" || return 1
  done
}

probe_ddsql_contract() (
  clear_probe_env
  load_env dbdog-server || return 1
  load_env ddsql-server || return 1
  [ -n "${PG_DSN:-}" ] && [ -n "${CH_URL:-}" ] && [ -n "${CH_DATABASE:-}" ] \
    && [ -n "${DBDOG_METRIC_URL:-}" ]
)

probe_postgresql() (
  clear_probe_env
  load_env dbdog-server || return 1
  if [ -z "${PG_DSN:-}" ] || [[ "$PG_DSN" = *user:pass* ]]; then
    return 1
  fi
  "$MODULES_DIR/postgresql/current/bin/psql" "$PG_DSN" -v ON_ERROR_STOP=1 \
    -Atc "SELECT current_database(), 1" | grep -qx 'ctl|1'
)

probe_web_postgresql() (
  clear_probe_env
  load_env dbdog-web || return 1
  if [ -z "${DATABASE_URL:-}" ] || [[ "$DATABASE_URL" = *user:pass* ]]; then
    return 1
  fi
  "$MODULES_DIR/postgresql/current/bin/psql" "$DATABASE_URL" -v ON_ERROR_STOP=1 \
    -Atc "SELECT current_database(), 1" | grep -qx 'ctl|1'
)

probe_clickhouse() (
  clear_probe_env
  load_env dbdog-server || return 1
  local clickhouse="$MODULES_DIR/clickhouse/current/bin/clickhouse"
  local addr="${DBDOG_CH_ADDR:-127.0.0.1:9000}" host port database
  addr="${addr%%,*}"
  host="${addr%:*}"; port="${addr##*:}"; database="${DBDOG_CH_DATABASE:-obs}"
  "$clickhouse" client --host "$host" --port "$port" \
    --user "${DBDOG_CH_USERNAME:-default}" --password "${CH_PASSWORD:-}" \
    --database "$database" --query "SELECT currentDatabase(), 1 FORMAT TSV" \
    | grep -qx "$database"$'\t''1'
)

probe_dbdog_server() (
  clear_probe_env
  load_env dbdog-server || return 1
  local addr="${DBDOG_HTTP_ADDR:-:8080}" port
  port="${addr##*:}"
  retry_http "http://127.0.0.1:$port/healthz"
)

probe_ddsql() (
  clear_probe_env
  load_env dbdog-server || return 1
  load_env ddsql-server || return 1
  local addr="${DDSQL_ADDR:-127.0.0.1:8770}" port
  port="${addr##*:}"
  retry_http "http://127.0.0.1:$port/healthz"
)

probe_web() (
  clear_probe_env
  load_env dbdog-web || return 1
  retry_http "http://127.0.0.1:${PORT:-3000}/login" -o /dev/null
)

probe_mcp() (
  clear_probe_env
  load_env dbdog-mcp || return 1
  retry_http "http://127.0.0.1:${DBDOG_HTTP_PORT:-8090}/healthz"
)

main() {
  ensure_layout
  echo "进程状态（仅供参考）："
  "$SCRIPTS_DIR/dbdogctl" status all
  echo

  check "4 个应用 env 文件存在" probe_env_files
  check "server/web/MCP 内部 token 一致且非占位" probe_shared_internal_token
  check "web/MCP OAuth JWT 一致且非占位" probe_shared_oauth_secret
  check "web 后端与 PUBLIC_* URL 已配置" probe_web_urls
  check "MCP 后端/OAuth/public URL 已配置" probe_mcp_urls
  check "DDSQL 的 PG/CH/metric 配置完整" probe_ddsql_contract
  check "server PG_DSN 可查询 ctl" probe_postgresql
  check "web DATABASE_URL 可查询 ctl" probe_web_postgresql
  check "ClickHouse 可查询目标库" probe_clickhouse
  check "dbdog-server /healthz" probe_dbdog_server
  check "ddsql-server /healthz（仅存活）" probe_ddsql
  check "dbdog-web /login（仅 HTTP smoke）" probe_web
  check "dbdog-mcp /healthz（仅存活）" probe_mcp

  echo
  if [ "$failures" -gt 0 ]; then
    die "$failures 项基础验收失败；查看 $LOGS_DIR/ 下对应服务日志"
  fi
  log "基础部署验收通过；DDSQL、鉴权和 agent 仍需业务场景验证"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
