#!/usr/bin/env bash
# 本机可重复测试：daemon 假成功、事务回滚及 install 的失败边界。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBDOGCTL="$SCRIPTS_DIR/dbdogctl"
INSTALL="$SCRIPTS_DIR/install.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-startup-test.XXXXXX")"
PASS_COUNT=0

cleanup() {
  local pidfile pid
  set +e
  while IFS= read -r pidfile; do
    IFS= read -r pid <"$pidfile" || continue
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done < <(find "$TEST_ROOT" -type f \( -name '*.pid' -o -name postmaster.pid \) -print)
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/dbdog-startup-test.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }

make_script() { # make_script <path>，脚本内容从 stdin 读取
  local path="$1"
  tee "$path" >/dev/null
  chmod 0755 "$path"
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq "$expected" "$file" || {
    printf '%s\n' "----- $file -----" >&2
    sed -n '1,240p' "$file" >&2
    fail "输出缺少: $expected"
  }
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    printf '%s\n' "----- $file -----" >&2
    sed -n '1,240p' "$file" >&2
    fail "输出不应包含: $unexpected"
  fi
}

expect_failure() { # expect_failure <output> <command...>
  local output="$1"; shift
  if "$@" >"$output" 2>&1; then
    printf '%s\n' "----- $output -----" >&2
    sed -n '1,240p' "$output" >&2
    fail "命令本应失败: $*"
  fi
}

assert_pid_running() {
  local pidfile="$1" pid
  [ -s "$pidfile" ] || fail "PID 文件不存在: $pidfile"
  IFS= read -r pid <"$pidfile"
  kill -0 "$pid" 2>/dev/null || fail "PID 未运行: $pid"
}

assert_pid_stopped() {
  local pidfile="$1" pid=""
  if [ -s "$pidfile" ]; then
    IFS= read -r pid <"$pidfile" || true
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      fail "PID 仍在运行: $pid"
    fi
  fi
}

setup_fixture() { # setup_fixture <DBDOG_HOME>
  local home="$1"
  mkdir -p "$home/modules/postgresql/current/bin" \
    "$home/modules/clickhouse/current/bin" \
    "$home/modules/dbdog-server/current/bin" \
    "$home/modules/dbdog-web/current" \
    "$home/modules/node/current/bin" \
    "$home/etc/clickhouse" "$home/test-markers" "$home/test-bin"

  make_script "$home/test-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  case "$arg" in http://*) url="$arg" ;; esac
done
case "$url" in
  *:8080/healthz) [ -e "${FAKE_MARK_DIR:?}/dbdog-server-ready" ] ;;
  *:8770/healthz) [ -e "${FAKE_MARK_DIR:?}/ddsql-server-ready" ] ;;
  *:3000/login) [ -e "${FAKE_MARK_DIR:?}/dbdog-web-ready" ] ;;
  *:8090/healthz) [ -e "${FAKE_MARK_DIR:?}/dbdog-mcp-ready" ] ;;
  *) exit 22 ;;
esac
EOF

  make_script "$home/modules/postgresql/current/bin/pg_ctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
data="" action=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) data="$2"; shift 2 ;;
    start | stop) action="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$data" ] && [ -n "$action" ]
case "$action" in
  start)
    mkdir -p "$data"
    nohup sleep 300 >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$data/postmaster.pid"
    ;;
  stop)
    if [ -s "$data/postmaster.pid" ]; then
      IFS= read -r pid <"$data/postmaster.pid"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$data/postmaster.pid"
    ;;
esac
EOF

  make_script "$home/modules/postgresql/current/bin/pg_isready" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_PG_READY_RC:-0}"
EOF

  make_script "$home/modules/postgresql/current/bin/initdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in -D) data="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$data" ]
mkdir -p "$data/base"
printf '16\n' >"$data/PG_VERSION"
: >"$data/postgresql.conf"
: >"$data/pg_hba.conf"
EOF

  make_script "$home/modules/postgresql/current/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${FAKE_MARK_DIR:?}/psql-called"
printf '%s' "${FAKE_CTL_EXISTS:-}"
EOF

  make_script "$home/modules/postgresql/current/bin/createdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${FAKE_MARK_DIR:?}/createdb-called"
EOF

  make_script "$home/modules/clickhouse/current/bin/clickhouse" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${FAKE_CH_MODE:-ready}"
case "${1:-}" in
  server)
    pidfile=""
    for arg in "$@"; do
      case "$arg" in --pid-file=*) pidfile="${arg#--pid-file=}" ;; esac
    done
    [ -n "$pidfile" ]
    case "$mode" in
      crash)
        nohup sleep 0.05 >/dev/null 2>&1 &
        ;;
      ready)
        nohup sleep 300 >/dev/null 2>&1 &
        ;;
      *) exit 64 ;;
    esac
    printf '%s\n' "$!" >"$pidfile"
    ;;
  client)
    [ "$mode" = "ready" ] || exit 1
    case "$*" in
      *'CREATE DATABASE IF NOT EXISTS obs'*) : >"${FAKE_MARK_DIR:?}/obs-created" ;;
    esac
    ;;
  *) exit 64 ;;
esac
EOF

  make_script "$home/modules/dbdog-server/current/bin/dbdog-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${FAKE_MARK_DIR:?}/dbdog-server-entered"
printf '%s\n' "${FAKE_APP_MODE:-unset}" >"$FAKE_MARK_DIR/dbdog-server-mode"
[ "${FAKE_APP_MODE:-ready}" = "ready" ] || exit 42
: >"$FAKE_MARK_DIR/dbdog-server-ready"
sleep 300 & child_pid="$!"
trap 'kill "$child_pid" 2>/dev/null || true; exit 0' TERM INT
wait "$child_pid"
EOF

  make_script "$home/modules/dbdog-server/current/bin/ddsql-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${FAKE_MARK_DIR:?}/ddsql-server-entered"
[ "${FAKE_APP_MODE:-ready}" = "ready" ] || exit 42
: >"$FAKE_MARK_DIR/ddsql-server-ready"
sleep 300 & child_pid="$!"
trap 'kill "$child_pid" 2>/dev/null || true; exit 0' TERM INT
wait "$child_pid"
EOF

  : >"$home/etc/clickhouse/config.xml"
}

ctl_env() { # ctl_env <home> <command...>
  local home="$1"; shift
  env PATH="$home/test-bin:$PATH" DBDOG_HOME="$home" \
    FAKE_MARK_DIR="$home/test-markers" DBDOG_STARTUP_ATTEMPTS=8 \
    DBDOG_STARTUP_INTERVAL=0.05 DBDOG_STARTUP_STABLE_SUCCESSES=2 "$@"
}

test_clickhouse_daemon_crash() {
  local home="$TEST_ROOT/ch-crash" output="$TEST_ROOT/ch-crash.out"
  setup_fixture "$home"
  expect_failure "$output" ctl_env "$home" env FAKE_CH_MODE=crash \
    "$DBDOGCTL" start clickhouse
  assert_contains "$output" "启动命令已返回，但进程未稳定就绪"
  assert_not_contains "$output" "clickhouse 已启动并通过启动检查"
  assert_pid_stopped "$home/run/clickhouse.pid"
  [ ! -e "$home/run/clickhouse.pid" ] || fail "失败启动留下 clickhouse.pid"
  pass "ClickHouse daemon 父进程返回 0、子进程退出时整体返回非零"
}

test_start_transaction_rolls_back_only_new_services() {
  local home="$TEST_ROOT/rollback" output="$TEST_ROOT/rollback.out" pgpid
  setup_fixture "$home"

  expect_failure "$output" ctl_env "$home" env FAKE_CH_MODE=crash \
    "$DBDOGCTL" start all
  assert_contains "$output" "回滚本次已启动服务: postgresql"
  assert_pid_stopped "$home/data/pg/postmaster.pid"
  [ ! -e "$home/test-markers/dbdog-server-entered" ] \
    || fail "ClickHouse 失败后仍启动了后续应用"

  ctl_env "$home" env FAKE_CH_MODE=crash "$DBDOGCTL" start postgresql >/dev/null
  assert_pid_running "$home/data/pg/postmaster.pid"
  IFS= read -r pgpid <"$home/data/pg/postmaster.pid"
  expect_failure "$output" ctl_env "$home" env FAKE_CH_MODE=crash \
    "$DBDOGCTL" start postgresql clickhouse
  assert_pid_running "$home/data/pg/postmaster.pid"
  [ "$(sed -n '1p' "$home/data/pg/postmaster.pid")" = "$pgpid" ] \
    || fail "原先运行的 PostgreSQL PID 被替换"
  assert_not_contains "$output" "回滚本次已启动服务: postgresql"
  ctl_env "$home" "$DBDOGCTL" stop postgresql >/dev/null
  pass "部分失败只回滚本次新启动服务，原先运行服务保持不动"
}

test_running_but_unready_is_not_stopped() {
  local home="$TEST_ROOT/unready" output="$TEST_ROOT/unready.out" pgpid
  setup_fixture "$home"
  ctl_env "$home" "$DBDOGCTL" start postgresql >/dev/null
  IFS= read -r pgpid <"$home/data/pg/postmaster.pid"

  expect_failure "$output" ctl_env "$home" env FAKE_PG_READY_RC=1 \
    "$DBDOGCTL" start postgresql
  assert_contains "$output" "进程存在但未通过启动检查"
  assert_pid_running "$home/data/pg/postmaster.pid"
  [ "$(sed -n '1p' "$home/data/pg/postmaster.pid")" = "$pgpid" ] \
    || fail "未就绪的原有进程不应被替换"
  ctl_env "$home" "$DBDOGCTL" stop postgresql >/dev/null
  pass "已运行但未就绪返回非零，且不停止调用前已有进程"
}

test_background_app_crash() {
  local home="$TEST_ROOT/app-crash" output="$TEST_ROOT/app-crash.out" iteration
  setup_fixture "$home"
  for ((iteration=1; iteration<=40; iteration++)); do
    rm -f "$home/test-markers/dbdog-server-ready" \
      "$home/test-markers/dbdog-server-entered" \
      "$home/test-markers/dbdog-server-mode"
    expect_failure "$output" ctl_env "$home" env FAKE_APP_MODE=crash \
      "$DBDOGCTL" start dbdog-server
    [ ! -e "$home/run/dbdog-server.pid" ] \
      || fail "第 $iteration 次失败启动留下应用 PID 文件"
  done
  assert_contains "$output" "启动命令已返回，但进程未稳定就绪"
  assert_not_contains "$output" "dbdog-server 已启动并通过启动检查"

  if ! ctl_env "$home" env FAKE_APP_MODE=ready \
      "$DBDOGCTL" start dbdog-server >"$output" 2>&1; then
    sed -n '1,160p' "$output" >&2
    sed -n '1,160p' "$home/logs/dbdog-server.log" >&2 || true
    fail "健康应用未通过 exec/health 握手"
  fi
  assert_contains "$output" "dbdog-server 已启动并通过启动检查"
  ctl_env "$home" "$DBDOGCTL" stop dbdog-server >/dev/null
  pass "后台应用经过 exec/health 握手；即时退出压力循环 40 次无误报"
}

test_ready_clickhouse() {
  local home="$TEST_ROOT/ch-ready" output="$TEST_ROOT/ch-ready.out"
  setup_fixture "$home"
  ctl_env "$home" env FAKE_CH_MODE=ready "$DBDOGCTL" start clickhouse >"$output" 2>&1
  assert_contains "$output" "clickhouse 已启动并通过启动检查"
  assert_pid_running "$home/run/clickhouse.pid"
  ctl_env "$home" "$DBDOGCTL" stop clickhouse >/dev/null
  pass "ClickHouse PID 与 SQL 探测连续成功后才报告启动"
}

test_install_stops_before_logical_database_init() {
  local home="$TEST_ROOT/install-failure" output="$TEST_ROOT/install-failure.out"
  local fake_path="$TEST_ROOT/fake-path"
  setup_fixture "$home"
  rm -f "$home/etc/clickhouse/config.xml"
  mkdir -p "$fake_path"

  make_script "$fake_path/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then printf 'aarch64\n'; else /usr/bin/uname "$@"; fi
EOF
  make_script "$fake_path/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-un" ]; then printf 'dbdog\n'; else /usr/bin/id "$@"; fi
EOF
  make_script "$fake_path/ldd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  expect_failure "$output" env PATH="$fake_path:$PATH" DBDOG_HOME="$home" \
    FAKE_MARK_DIR="$home/test-markers" FAKE_CH_MODE=crash \
    DBDOG_STARTUP_ATTEMPTS=8 DBDOG_STARTUP_INTERVAL=0.05 \
    DBDOG_STARTUP_STABLE_SUCCESSES=2 "$INSTALL" --init-db-only

  assert_contains "$output" "未继续创建 ctl/obs"
  [ -s "$home/data/pg/PG_VERSION" ] && [ -d "$home/data/pg/base" ] \
    || fail "成功的物理 initdb 应保留，供安全重跑"
  assert_pid_stopped "$home/data/pg/postmaster.pid"
  for marker in psql-called createdb-called obs-created; do
    [ ! -e "$home/test-markers/$marker" ] \
      || fail "数据库未全部就绪却发生逻辑初始化: $marker"
  done
  pass "install 在两库全部就绪前原子失败，不创建 ctl/obs"
}

test_clickhouse_daemon_crash
test_start_transaction_rolls_back_only_new_services
test_running_but_unready_is_not_stopped
test_background_app_crash
test_ready_clickhouse
test_install_stops_before_logical_database_init

printf 'ALL PASS: %s startup failure tests\n' "$PASS_COUNT"
