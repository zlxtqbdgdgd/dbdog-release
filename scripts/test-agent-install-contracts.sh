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
GAUSSHOME="$TEST_ROOT/gauss/app"
SOCKET_DIR="$TEST_ROOT/gauss/socket"
OWNER_HOME="$TEST_ROOT/gauss-owner"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$PROC/$PID" "$DATA" "$GAUSSLOG/gs_log/dn_6001" \
  "$GAUSSHOME/bin" "$GAUSSHOME/lib/libsimsearch" "$SOCKET_DIR" "$OWNER_HOME" "$FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' >"$GAUSSHOME/bin/gsql"
chmod 0755 "$GAUSSHOME/bin/gsql"
cat >"$FAKE_BIN/timeout" <<'EOF'
#!/bin/sh
case "$1" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat >"$FAKE_BIN/runuser" <<'EOF'
#!/bin/sh
[ "$1" = -u ] || exit 97
shift 2
[ "$1" = -- ] || exit 98
shift
exec "$@"
EOF
chmod 0755 "$FAKE_BIN/timeout" "$FAKE_BIN/runuser"
export DBDOG_TIMEOUT_BIN="$FAKE_BIN/timeout"
export DBDOG_RUNUSER_BIN="$FAKE_BIN/runuser"
export DBDOG_TEST_OWNER_HOME="$OWNER_HOME"
agent_owner_home() { printf '%s\n' "$DBDOG_TEST_OWNER_HOME"; }
agent_owner_name() { id -un; }

printf 'gaussdb\n' >"$PROC/$PID/comm"
printf '%s\0-D\0%s\0' "$GAUSSHOME/bin/gaussdb" "$DATA" >"$PROC/$PID/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGPORT=37001\0PGHOST=%s\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$SOCKET_DIR" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/$PID/environ"
printf 'Name:\tgaussdb\nUid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$PROC/$PID/status"
printf '4242\n%s\n0\n15432\n%s\n' "$DATA" "$SOCKET_DIR" >"$DATA/postmaster.pid"
# 模拟同实例的另一个 gaussdb backend；安装事实必须按端口去重。
mkdir -p "$PROC/4243"
printf 'gaussdb\n' >"$PROC/4243/comm"
printf 'gaussdb: dbdog postgres 127.0.0.1\0' >"$PROC/4243/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGDATA=%s\0PGPORT=15432\0PGHOST=%s\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$DATA" "$SOCKET_DIR" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/4243/environ"
cp "$PROC/$PID/status" "$PROC/4243/status"

DBDOG_PROC_ROOT="$PROC"
export DBDOG_PROC_ROOT
agent_detect_gaussdb
[ "${AGENT_GAUSS_PORTS[*]}" = 15432 ] || fail "没有优先使用运行态 postmaster.pid 端口"
[ "${#AGENT_GAUSS_PID_PORTS[@]}" -eq 1 ] || fail "把同一实例的 backend 进程重复识别为多个实例"
[ "${AGENT_GAUSS_PID_HOSTS[*]}" = "$SOCKET_DIR" ] || fail "没有发现实例 Unix socket"
[ "${AGENT_GAUSS_PID_GSQLS[*]}" = "$GAUSSHOME/bin/gsql" ] || fail "没有使用目标实例 gsql"
case ":${AGENT_GAUSS_PID_LD_LIBRARY_PATHS[0]}:" in
  *":$GAUSSHOME/lib/libsimsearch:"*) ;;
  *) fail "没有继承目标实例 libsimsearch 动态库目录" ;;
esac
[ "${AGENT_GAUSS_LOG_GLOBS[*]}" = "$GAUSSLOG/gs_log/*/gaussdb-*.log" ] || \
  fail "没有从进程 GAUSSLOG 生成日志 glob"
[ "$AGENT_GAUSS_DEPLOYMENT" = centralized ] || fail "单实例拓扑推断错误"
pass "优先从目标机运行进程发现 GaussDB 端口、socket、客户端库与日志"

DBDOG_GAUSSDB_PGHOST="$TEST_ROOT/explicit-socket"
DBDOG_GAUSSDB_LD_LIBRARY_PATH="$TEST_ROOT/explicit-lib"
export DBDOG_GAUSSDB_PGHOST DBDOG_GAUSSDB_LD_LIBRARY_PATH
agent_detect_gaussdb
[ "${AGENT_GAUSS_PID_HOSTS[0]}" = "$TEST_ROOT/explicit-socket" ] || fail "显式 PGHOST 未覆盖自动发现"
case "${AGENT_GAUSS_PID_LD_LIBRARY_PATHS[0]}" in
  "$TEST_ROOT/explicit-lib" | "$TEST_ROOT/explicit-lib:"*) ;;
  *) fail "显式 LD_LIBRARY_PATH 没有最高优先级" ;;
esac
unset DBDOG_GAUSSDB_PGHOST DBDOG_GAUSSDB_LD_LIBRARY_PATH
agent_detect_gaussdb
pass "特殊部署可显式覆盖 PGHOST/LD_LIBRARY_PATH，正常路径恢复自动发现"

PROFILE_HOME="$TEST_ROOT/profile-home"
mkdir -p "$PROFILE_HOME/socket" "$PROFILE_HOME/gauss/lib/libsimsearch"
cat >"$PROFILE_HOME/.bashrc" <<'EOF'
export GAUSSHOME="$HOME/gauss"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/libsimsearch"
export MPPDB_ENV_SEPARATE_PATH="$HOME/gauss_env_file"
EOF
cat >"$PROFILE_HOME/gauss_env_file" <<'EOF'
export GAUSSLOG="$HOME/runtime-log"
export PGHOST="$HOME/socket"
export PGPORT=15432
EOF
EXPLICIT_ENV="$PROFILE_HOME/explicit.env"
cat >"$EXPLICIT_ENV" <<'EOF'
export PGHOST="$HOME/explicit-socket"
export LD_LIBRARY_PATH="$HOME/explicit-lib"
EOF
agent_load_owner_environment "$(id -un)" "$PROFILE_HOME" "" "$EXPLICIT_ENV" || \
  fail "无法在受限数据库用户 shell 中加载 profile"
[ "$AGENT_OWNER_ENV_GAUSSHOME" = "$PROFILE_HOME/gauss" ] || fail "profile 变量展开失败"
[ "$AGENT_OWNER_ENV_GAUSSLOG" = "$PROFILE_HOME/runtime-log" ] || fail "gauss_env_file 未加载"
[ "$AGENT_OWNER_ENV_PGHOST" = "$PROFILE_HOME/explicit-socket" ] || fail "显式 env 文件未覆盖 PGHOST"
[ "$AGENT_OWNER_ENV_LD_LIBRARY_PATH" = "$PROFILE_HOME/explicit-lib" ] || \
  fail "显式 env 文件未覆盖 LD_LIBRARY_PATH"
BROKEN_EXPLICIT_ENV="$PROFILE_HOME/broken-explicit.env"
printf 'return 7\n' >"$BROKEN_EXPLICIT_ENV"
if agent_load_owner_environment "$(id -un)" "$PROFILE_HOME" "" "$BROKEN_EXPLICIT_ENV"; then
  fail "显式 GaussDB 环境文件 source 失败后仍被接受"
fi
pass "以数据库 OS 用户、空环境和硬超时加载 profile/MPP env，并只返回白名单"

for _ in 1 2 3 4 5; do
  GENERATED_PASSWORD="$(agent_generate_gaussdb_password)" || fail "随机密码生成失败"
  [ "${#GENERATED_PASSWORD}" -eq 32 ] || fail "随机密码不是 32 字符"
  agent_validate_gaussdb_password "$GENERATED_PASSWORD" || fail "随机密码不符合 GaussDB 复杂度"
done
agent_validate_gaussdb_password 'Ab1_short' || fail "合法显式密码被拒绝"
if agent_validate_gaussdb_password '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'; then
  fail "错误接受了 64 字符纯 hex 密码"
fi
if agent_validate_gaussdb_password 'abcdefgh12345678'; then fail "错误接受了只有两类字符的密码"; fi
if agent_validate_gaussdb_password 'Aa1 bad_password'; then fail "错误接受了带空白的密码"; fi
pass "监控密码固定不超过 32 字符且满足至少三类字符约束"

VALID_TUF_ROOT="$TEST_ROOT/valid-tuf-root.json"
INVALID_TUF_ROOT="$TEST_ROOT/invalid-tuf-root.json"
printf '%s\n' \
  '{"signed":{"_type":"root","version":1,"keys":{"k":{}},"roles":{"root":{}}},"signatures":[{"keyid":"k","sig":"s"}]}' \
  >"$VALID_TUF_ROOT"
printf '%s\n' '{"error":"not found"}' >"$INVALID_TUF_ROOT"
COMPACT_TUF_ROOT="$(bash -c '
  source "$1"
  trap - EXIT
  compact_tuf_root_file "$2"
' bash "$SCRIPTS_DIR/agent-install.sh" "$VALID_TUF_ROOT")" || fail "合法 TUF root 被拒绝"
case "$COMPACT_TUF_ROOT" in *'"_type":"root"'*'"signatures":['*) ;; *) fail "TUF root 压缩结果异常" ;; esac
if bash -c '
  source "$1"
  trap - EXIT
  compact_tuf_root_file "$2"
' bash "$SCRIPTS_DIR/agent-install.sh" "$INVALID_TUF_ROOT" >/dev/null 2>&1; then
  fail "错误响应对象被当作 Remote Config trust root 接受"
fi
pass "Remote Config bootstrap 只接受带签名且结构完整的 TUF root"

HBA_TEST_ROOT="$TEST_ROOT/hba"
mkdir -p "$HBA_TEST_ROOT"
printf '# base\nhost all all 127.0.0.1/32 md5\n' >"$HBA_TEST_ROOT/valid"
printf '# dbdog-release BEGIN: local Agent monitor\nhost all dbdog 127.0.0.1/32 md5\n' \
  >"$HBA_TEST_ROOT/broken"
printf '# original\n' >"$HBA_TEST_ROOT/before"
printf '# managed\n' >"$HBA_TEST_ROOT/applied"
cp "$HBA_TEST_ROOT/applied" "$HBA_TEST_ROOT/current"
bash -c '
  source "$1"
  trap - EXIT
  agent_validate_hba_markers "$2/valid"
  if agent_validate_hba_markers "$2/broken"; then exit 91; fi
  DB_HBA_PATHS=()
  DB_HBA_BACKUPS=()
  DB_HBA_APPLIED=()
  DB_HBA_PATHS[1]="$2/current"
  DB_HBA_BACKUPS[1]="$2/before"
  DB_HBA_APPLIED[1]="$2/applied"
  agent_gsql() { printf "t\n"; }
  agent_restore_hba_rules
  cmp -s "$2/current" "$2/before"
  [ -z "${DB_HBA_PATHS[1]:-}" ]
' bash "$SCRIPTS_DIR/agent-install.sh" "$HBA_TEST_ROOT" || \
  fail "HBA 标记校验或稀疏实例回滚合同失败"
grep -Fq 'legacy_trust' "$SCRIPTS_DIR/agent-install.sh" || fail "没有自动迁移旧本机 dbdog trust HBA"
grep -Fq 'install-hba-recovery.' "$SCRIPTS_DIR/agent-install.sh" || fail "HBA 恢复失败未持久化恢复材料"
pass "HBA 改写拒绝残缺标记、迁移旧 trust，并按真实实例下标可靠回滚"

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

INSTALL_SCRIPT="$SCRIPTS_DIR/agent-install.sh"
if grep -Fq 'SET password_encryption_type' "$INSTALL_SCRIPT"; then
  fail "安装器仍尝试在会话中修改 password_encryption_type"
fi
if grep -Eq 'host[[:space:]]+all[[:space:]]+dbdog.*[[:space:]]trust([[:space:]]|$)' "$INSTALL_SCRIPT"; then
  fail "安装器绝不能给 MONADMIN 安装 trust HBA"
fi
grep -Fq "SHOW password_encryption_type;" "$INSTALL_SCRIPT" || fail "没有预检认证模式"
grep -Fq 'host all dbdog 127.0.0.1/32 md5' "$INSTALL_SCRIPT" || fail "缺少受管本机 MD5 HBA"
grep -Fq 'ALTER USER dbdog WITH MONADMIN;' "$INSTALL_SCRIPT" || fail "升级仍会重复设置未变化密码"
grep -Fq 'install-configcheck.log' "$INSTALL_SCRIPT" || fail "configcheck 诊断没有持久化"
grep -Fq 'for ((i=1; i<=8; i++))' "$INSTALL_SCRIPT" || fail "configcheck 没有 readiness 重试"
if grep -Fq 'PGPASSWORD=' "$INSTALL_SCRIPT"; then fail "数据库密码仍暴露在子进程 argv 环境赋值中"; fi
grep -Fq 'error.sqlstate == "28P01"' "$INSTALL_SCRIPT" || fail "密码探测没有区分明确认证拒绝和基础设施错误"
MAIN_BODY="$(awk '/^main\(\)/ { scan=1 } scan { print }' "$INSTALL_SCRIPT")"
PREFLIGHT_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'preflight_gaussdb_clients' | head -1 | cut -d: -f1)"
CUTOVER_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n '^  cutover$' | head -1 | cut -d: -f1)"
BOOTSTRAP_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'bootstrap_gaussdb_monitoring' | head -1 | cut -d: -f1)"
[ "$PREFLIGHT_LINE" -lt "$CUTOVER_LINE" ] && [ "$CUTOVER_LINE" -lt "$BOOTSTRAP_LINE" ] || \
  fail "gsql 精确预检没有发生在文件/数据库 mutation 之前"
RECOVERY_BASE="$TEST_ROOT/recovery/etc/dbdog-agent"
mkdir -p "$RECOVERY_BASE.failed.20260727010101" "$RECOVERY_BASE.failed.20260727020202"
RECOVERED="$(PATH="$FAKE_BIN:$PATH" bash -c '
  source "$1"
  trap - EXIT
  AGENT_CONFIG_DIR="$2"
  latest_failed_agent_config
' bash "$INSTALL_SCRIPT" "$RECOVERY_BASE")" || fail "无法发现首装失败配置"
[ "$RECOVERED" = "$RECOVERY_BASE.failed.20260727020202" ] || fail "没有选择最新首装失败配置"
pass "认证模式 fail closed、禁止 trust、密码幂等与 configcheck 持久诊断均有流程门禁"

PREFLIGHT_ROOT="$TEST_ROOT/preflight"
mkdir -p "$PREFLIGHT_ROOT/bin" "$PREFLIGHT_ROOT/work"
cat >"$PREFLIGHT_ROOT/bin/ldd" <<'EOF'
#!/bin/sh
printf '\tlibc.so.6 => /lib/libc.so.6 (0x1)\n'
EOF
cat >"$PREFLIGHT_ROOT/bin/gsql" <<'EOF'
#!/bin/sh
root=${0%/*}
printf 'PGHOST=%s\nLD_LIBRARY_PATH=%s\nARGS=%s\n' \
  "${PGHOST:-}" "${LD_LIBRARY_PATH:-}" "$*" >>"$root/calls"
query=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) printf 'gsql test-version\n'; exit 0 ;;
    -c) shift; query=$1 ;;
  esac
  shift
done
case "$query" in
  'SELECT 1;') printf '1\n' ;;
  'SHOW password_encryption_type;') cat "$root/mode" ;;
  *pg_user*) cat "$root/exists" ;;
  '') cat >"$root/stdin.sql" ;;
  *) printf '1\n' ;;
esac
EOF
cat >"$PREFLIGHT_ROOT/bin/fake-python" <<'EOF'
#!/bin/sh
# agent_monitor_password_works 的合同替身：消费 stdin 中的 Python 程序并模拟成功登录。
cat >/dev/null
exit 0
EOF
chmod 0755 "$PREFLIGHT_ROOT/bin/ldd" "$PREFLIGHT_ROOT/bin/gsql" \
  "$PREFLIGHT_ROOT/bin/fake-python"
cp "$FAKE_BIN/timeout" "$PREFLIGHT_ROOT/bin/timeout"
printf '1\n' >"$PREFLIGHT_ROOT/bin/mode"
printf '1\n' >"$PREFLIGHT_ROOT/bin/exists"

run_fake_gauss_action() { # <preflight|set-password>
  PATH="$FAKE_BIN:$PATH" bash -c '
    source "$1"
    trap - EXIT
    WORK_DIR="$2/work"
    DBDOG_GAUSSDB_DBNAME=postgres
    DBDOG_GAUSSDB_MONITOR_PASSWORD=Aa1_valid_monitor_password
    DBDOG_AGENT_PYTHON="$2/bin/fake-python"
    PREVIOUS_DB_PASSWORD=""
    AGENT_GAUSS_PID_PORTS=(15432)
    AGENT_GAUSS_PID_HOMES=("$2")
    AGENT_GAUSS_PID_OWNERS=("$(id -un)")
    AGENT_GAUSS_PID_OWNER_HOMES=("$2")
    AGENT_GAUSS_PID_HOSTS=("$2/socket")
    AGENT_GAUSS_PID_LD_LIBRARY_PATHS=("$2/lib:$2/lib/libsimsearch")
    AGENT_GAUSS_PID_PATHS=("$2/bin:/usr/bin:/bin")
    AGENT_GAUSS_PID_GSQLS=("$2/bin/gsql")
    case "$3" in
      preflight)
        preflight_gaussdb_clients
        printf "RESULT=%s:%s\n" "${AGENT_GAUSS_PID_PASSWORD_MODES[0]}" \
          "${AGENT_GAUSS_PID_USER_EXISTS[0]}"
        ;;
      set-password)
        PREVIOUS_DB_PASSWORD=Aa1_valid_monitor_password
        agent_set_gaussdb_password "$PREVIOUS_DB_PASSWORD"
        ;;
    esac
  ' bash "$INSTALL_SCRIPT" "$PREFLIGHT_ROOT" "$1"
}

PREFLIGHT_OUTPUT="$(run_fake_gauss_action preflight)" || fail "模拟 gsql 精确预检失败"
[ "${PREFLIGHT_OUTPUT##*$'\n'}" = 'RESULT=1:1' ] || fail "预检没有记录认证模式和用户状态"
grep -Fq "PGHOST=$PREFLIGHT_ROOT/socket" "$PREFLIGHT_ROOT/bin/calls" || fail "gsql 未收到实例 PGHOST"
grep -Fq "LD_LIBRARY_PATH=$PREFLIGHT_ROOT/lib:$PREFLIGHT_ROOT/lib/libsimsearch" \
  "$PREFLIGHT_ROOT/bin/calls" || fail "gsql 未收到实例 LD_LIBRARY_PATH"
run_fake_gauss_action set-password >/dev/null || fail "未变化密码的幂等路径失败"
grep -Fqx 'ALTER USER dbdog WITH MONADMIN;' "$PREFLIGHT_ROOT/bin/stdin.sql" || \
  fail "升级仍然重置了未变化的 GaussDB 密码"
if grep -Fq PASSWORD "$PREFLIGHT_ROOT/bin/stdin.sql"; then fail "幂等升级 SQL 仍含 PASSWORD"; fi

printf '2\n' >"$PREFLIGHT_ROOT/bin/mode"
printf '0\n' >"$PREFLIGHT_ROOT/bin/exists"
if run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/mode2.out" 2>&1; then
  fail "需要创建/重置密码时错误接受了不兼容的认证模式"
fi
if ! grep -Fq 'password_encryption_type=2' "$PREFLIGHT_ROOT/mode2.out"; then
  sed -n '1,80p' "$PREFLIGHT_ROOT/mode2.out" >&2
  fail "认证不兼容没有给出清晰且非侵入式的错误"
fi
pass "真实命令形态完成 ldd/version/SELECT 预检、环境传递、幂等密码与认证 fail-closed"

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

printf 'ALL PASS: 12 agent install contract groups\n'
