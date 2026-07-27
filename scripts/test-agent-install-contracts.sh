#!/usr/bin/env bash
# 本机纯函数契约测试：不需要 root，不启动 systemd，也不执行 AArch64 runtime。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-agent-contracts.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-agent-contracts.??????) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

export DBDOG_HOME="$TEST_ROOT/home"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
export AGENT_RUNTIME_DIR="$TEST_ROOT/opt/dbdog-agent"
export AGENT_CONFIG_DIR="$TEST_ROOT/etc/dbdog-agent"
export AGENT_LOG_DIR="$TEST_ROOT/var/log/dbdog-agent"
export AGENT_RUN_DIR="$AGENT_RUNTIME_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/agent-lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

PROC="$TEST_ROOT/proc"
PID=4242
DATA="$TEST_ROOT/gauss/data"
GAUSSLOG="$TEST_ROOT/gauss/log"
mkdir -p "$PROC/$PID" "$DATA" "$GAUSSLOG/gs_log/dn_6001"
printf 'gaussdb\n' >"$PROC/$PID/comm"
printf '/opt/gauss/bin/gaussdb\0-D\0%s\0' "$DATA" >"$PROC/$PID/cmdline"
printf 'GAUSSHOME=/opt/gauss\0GAUSSLOG=%s\0PGPORT=37001\0' "$GAUSSLOG" >"$PROC/$PID/environ"
printf 'Name:\tgaussdb\nUid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$PROC/$PID/status"
printf '4242\n%s\n0\n15432\n' "$DATA" >"$DATA/postmaster.pid"
# 模拟同实例的另一个 gaussdb backend；安装事实必须按端口去重。
mkdir -p "$PROC/4243"
printf 'gaussdb\n' >"$PROC/4243/comm"
printf 'gaussdb: dbdog postgres 127.0.0.1\0' >"$PROC/4243/cmdline"
printf 'GAUSSHOME=/opt/gauss\0GAUSSLOG=%s\0PGDATA=%s\0PGPORT=15432\0' \
  "$GAUSSLOG" "$DATA" >"$PROC/4243/environ"
cp "$PROC/$PID/status" "$PROC/4243/status"

DBDOG_PROC_ROOT="$PROC"
export DBDOG_PROC_ROOT
agent_detect_gaussdb
[ "${AGENT_GAUSS_PORTS[*]}" = 15432 ] || fail "没有优先使用运行态 postmaster.pid 端口"
[ "${#AGENT_GAUSS_PID_PORTS[@]}" -eq 1 ] || fail "把同一实例的 backend 进程重复识别为多个实例"
[ "${AGENT_GAUSS_LOG_GLOBS[*]}" = "$GAUSSLOG/gs_log/*/gaussdb-*.log" ] || \
  fail "没有从进程 GAUSSLOG 生成日志 glob"
[ "$AGENT_GAUSS_DEPLOYMENT" = centralized ] || fail "单实例拓扑推断错误"
pass "从目标机运行进程发现 GaussDB 端口、目录与日志，不执行 .bashrc"

PROFILE_HOME="$TEST_ROOT/profile-home"
mkdir -p "$PROFILE_HOME"
printf 'export GAUSSLOG=/srv/gauss/runtime-log\ntouch %s/should-not-exist\n' "$TEST_ROOT" \
  >"$PROFILE_HOME/.bashrc"
[ "$(agent_profile_literal "$PROFILE_HOME" GAUSSLOG)" = /srv/gauss/runtime-log ] || \
  fail "未能静态读取 profile 中的 GAUSSLOG 字面量"
[ ! -e "$TEST_ROOT/should-not-exist" ] || fail "错误执行了目标用户 .bashrc"
pass "profile 仅作静态字面量兜底，不执行目标用户 shell 代码"

CONF="$TEST_ROOT/rendered"
UNITS="$TEST_ROOT/units"
mkdir -p "$CONF/conf.d"
agent_render_datadog_yaml "$CONF/datadog.yaml" 'http://dbdog.internal:8080' \
  'key_abc-123' 'gauss-node-01' '{"signed":{"version":1}}'
agent_render_system_probe_yaml "$CONF/system-probe.yaml"
agent_render_checks "$CONF/conf.d" "pa'ss: #1" dbdog postgres prod
agent_render_units "$UNITS"
if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f) }' \
    "$CONF/datadog.yaml" "$CONF/system-probe.yaml" \
    "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "生成的 YAML 无法解析"
fi

for expected in \
  'database_monitoring:' \
  'logs_enabled: true' \
  'apm_config:' \
  'ol_proxy_config:' \
  'process_collection:' \
  'process_discovery:' \
  'remote_configuration:' \
  'inventories_enabled: true'; do
  grep -Fq "$expected" "$CONF/datadog.yaml" || fail "缺少已验证功能开关: $expected"
done
grep -Fq 'network_config:' "$CONF/system-probe.yaml" || fail "NPM 未启用"
grep -Fq 'service_monitoring_config:' "$CONF/system-probe.yaml" || fail "USM 未启用"
grep -Fq 'dbm: true' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "GaussDB DBM 未启用"
grep -Fq 'collect_activity_metrics: true' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "activity 未启用"
grep -Fq "password: 'pa''ss: #1'" "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "密码 YAML 转义错误"
grep -Fq 'port: 15432' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "探测端口没有落入配置"
grep -Fq "$GAUSSLOG/gs_log/*/gaussdb-*.log" "$CONF/conf.d/gaussdb.d/conf.yaml" || \
  fail "探测日志路径没有落入配置"
grep -Fq "hostname: 'gauss-node-01'" "$CONF/datadog.yaml" || fail "没有使用目标机 hostname"
grep -Fq "dd_url: 'http://dbdog.internal:8080'" "$CONF/datadog.yaml" || fail "没有使用安装输入的 server"
pass "外网已验证功能集默认开启，机器事实与秘密在安装时渲染"

for check in cpu disk file_handle io load memory network process system_core uptime gaussdb; do
  [ -f "$CONF/conf.d/$check.d/conf.yaml" ] || fail "缺少默认 check: $check"
done
[ "$(find "$UNITS" -type f -name 'dbdog-agent*.service' | wc -l | tr -d ' ')" = 4 ] || \
  fail "没有生成四个 Agent systemd 单元"
grep -Fq "$AGENT_RUNTIME_DIR/embedded/bin/process-agent" "$UNITS/dbdog-agent-process.service" || \
  fail "process-agent unit 没有使用私有 runtime"
if grep -R -Fq '/opt/datadog-agent' "$UNITS"; then fail "systemd unit 错误引用官方 Agent"; fi
pass "主机 checks 与 Core/Trace/Process/System Probe 四服务一次生成且物理隔离"

[ "$(agent_existing_top_scalar "$CONF/datadog.yaml" api_key)" = key_abc-123 ] || \
  fail "升级无法保留 API key"
[ "$(agent_existing_top_scalar "$CONF/datadog.yaml" dd_url)" = http://dbdog.internal:8080 ] || \
  fail "升级无法保留 server URL"
[ "$(agent_existing_gauss_scalar "$CONF/conf.d/gaussdb.d/conf.yaml" password)" = "pa'ss: #1" ] || \
  fail "升级无法保留 GaussDB 密码"
pass "重复运行安装器可保留现有 server URL 与两项凭证"

if [ -f "$RELEASE_DIR/../dbdog-agent-core/gaussdb/datadog_checks/gaussdb/connection_pool.py" ]; then
  grep -Fq 'ConnectionPool' \
    "$RELEASE_DIR/../dbdog-agent-core/gaussdb/datadog_checks/gaussdb/connection_pool.py" || \
    fail "GaussDB integration 没有使用连接池"
fi
if awk '/^start_and_verify\(\)/ { scan=1 } /^main\(\)/ { scan=0 } scan { print }' \
  "$SCRIPTS_DIR/agent-install.sh" | grep -Fq gsql; then
  fail "运行期采集流程不应调用 gsql"
fi
grep -Fq 'psycopg_c.libs/libpq-' "$SCRIPTS_DIR/agent-install.sh" || fail "安装器未验证私有 libpq"
grep -Fq 'provenance/gaussdb.txt' "$SCRIPTS_DIR/agent-install.sh" || fail "安装器未验证 GaussDB integration"
# shellcheck disable=SC2016
grep -Fq 'exec "$SCRIPTS_DIR/agent-install.sh"' "$SCRIPTS_DIR/upgrade.sh" || \
  fail "统一 upgrade.sh 没有委托 Agent 的完整安装/升级事务"
MARKER_RUNTIME="$TEST_ROOT/marker-runtime"
[ "$(agent_marker_value "$MARKER_RUNTIME/.dbdog-release-version" "$MARKER_RUNTIME")" = - ] || \
  fail "未安装 Agent 的身份判断错误"
mkdir -p "$MARKER_RUNTIME"
[ "$(agent_marker_value "$MARKER_RUNTIME/.dbdog-release-version" "$MARKER_RUNTIME")" = '?' ] || \
  fail "Agent runtime 缺失身份 marker 时未 fail closed"
printf '7.81.1-dbdog.1\n' >"$MARKER_RUNTIME/.dbdog-release-version"
[ "$(agent_marker_value "$MARKER_RUNTIME/.dbdog-release-version" "$MARKER_RUNTIME")" = 7.81.1-dbdog.1 ] || \
  fail "Agent 身份 marker 读取错误"
grep -Fq 'CREATE OR REPLACE VIEW dbdog.statements' \
  "$SCRIPTS_DIR/agent/init-gaussdb-perdb.sql" || fail "缺少 GaussDB query metrics 兼容视图"
grep -Fq 'CREATE OR REPLACE VIEW dbdog.activity' \
  "$SCRIPTS_DIR/agent/init-gaussdb-perdb.sql" || fail "缺少 GaussDB activity 兼容视图"
CURRENT_AGENT_ARTIFACT="$(manifest_get dbdog-agent 6)"
CURRENT_AGENT_VERSION="$(manifest_get dbdog-agent 5)"
if [ -f "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" ]; then
  tar -tzf "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" \
    | grep -Eq '^\./(embedded/)?bin/(gsql|gaussdb)$' && \
    fail "Agent 产物错误打包了目标 GaussDB 的 gsql/gaussdb"
  tar -xOf "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" ./provenance/build.txt \
    | grep -Fqx "version=$CURRENT_AGENT_VERSION" || \
    fail "Agent 当前产物 provenance 版本与 manifest 不一致"
fi
pass "安装器要求预编译 GaussDB integration + psycopg/libpq，运行期不走 gsql 短连接"

printf 'ALL PASS: 6 agent install contract tests\n'
