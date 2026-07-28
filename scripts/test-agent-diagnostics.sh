#!/usr/bin/env bash
# Agent 诊断入口的本机合同：字段、限量、脱敏、命令路由与已知错误判定。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBDOGCTL="$SCRIPTS_DIR/dbdogctl"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-agent-diagnostic-test.XXXXXX")"
PASS_COUNT=0

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/dbdog-agent-diagnostic-test.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 缺少: $2"; }
assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then fail "$1 泄露/意外包含: $2"; fi
}

RUNTIME="$TEST_ROOT/runtime"
CONFIG="$TEST_ROOT/config"
LOG_DIR="$TEST_ROOT/log"
FAKE_BIN="$TEST_ROOT/bin"
TRACE="$TEST_ROOT/trace"
OS_RELEASE="$TEST_ROOT/os-release"
mkdir -p "$RUNTIME/bin/agent" "$CONFIG/conf.d/cpu.d" \
  "$CONFIG/conf.d/system_core.d" "$CONFIG/conf.d/process.d" \
  "$CONFIG/conf.d/gaussdb.d" "$LOG_DIR" "$FAKE_BIN" "$TRACE"
printf '7.81.0-dbdog.2\n' >"$RUNTIME/.dbdog-release-version"
printf '%064d\n' 1 >"$RUNTIME/.dbdog-artifact-sha256"
printf '%064d\n' 2 >"$RUNTIME/.dbdog-installer-contract-sha256"
printf '%s\n' \
  'normal agent log line' \
  "client_secret='log-secret'" \
  'postgres://dbdog:url-secret@127.0.0.1:5432/dbdog' \
  'gaussdb://dbdog:gauss-uri-secret@127.0.0.1:37000/postgres' >"$LOG_DIR/agent.log"
cat >"$OS_RELEASE" <<'EOF'
PRETTY_NAME="Kylin Linux Advanced Server V10"
ID=kylin
VERSION_ID="V10"
INTERNAL_TOKEN=os-release-secret
EOF
printf 'instances:\n  - min_collection_interval: 15\n' >"$CONFIG/conf.d/cpu.d/conf.yaml"
printf 'instances:\n  - min_collection_interval: 20\n' >"$CONFIG/conf.d/system_core.d/conf.yaml"
printf 'instances:\n  - min_collection_interval: 30\n' >"$CONFIG/conf.d/process.d/conf.yaml"
printf 'instances:\n  - min_collection_interval: 777\n    password: gauss-config-secret\n' \
  >"$CONFIG/conf.d/gaussdb.d/conf.yaml"

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_TRACE:?}/systemctl"
[ "${1:-}" = show ] || exit 64
unit="$2"
count_file="${FAKE_TRACE:?}/systemctl-show-count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
pid=4242
restarts=3
if [ "${FAKE_SYSTEMCTL_GROW:-0}" = 1 ] && [ "$count" -gt 4 ]; then
  pid=5252
  restarts=4
fi
cat <<OUT
Id=$unit
ActiveState=active
SubState=running
MainPID=$pid
NRestarts=$restarts
Result=success
ExecMainCode=0
ExecMainStatus=0
ExecMainStartTimestamp=Mon 2026-07-28 12:00:00 CST
ExecMainExitTimestamp=
OUT
EOF

cat >"$FAKE_BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_TRACE:?}/journalctl"
if [ "${FAKE_JOURNAL_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'journal unavailable' >&2
  exit 1
fi
if [ "${FAKE_JOURNAL_LONG_LINE:-0}" = 1 ]; then
  awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "x"; printf "\n" }'
  exit 0
fi
if [ "${FAKE_JOURNAL_OVERFLOW:-0}" = 1 ]; then
  for line in 1 2 3 4 5 6; do printf 'overflow-line-%s\n' "$line"; done
  exit 0
fi
since=""
until=""
kernel=0
previous=""
for argument in "$@"; do
  if [ "$previous" = since ]; then since="${argument#@}"; previous=""; continue; fi
  if [ "$previous" = until ]; then until="${argument#@}"; previous=""; continue; fi
  case "$argument" in
    --since) previous=since ;;
    --until) previous=until ;;
    -k) kernel=1 ;;
  esac
done
if [ -n "${FAKE_JOURNAL_LINES_PER_SECOND:-}" ] && [ "$kernel" -eq 0 ]; then
  case "$since:$until:${FAKE_JOURNAL_LINES_PER_SECOND}" in
    *[!0-9:]*) ;;
    *)
      for ((second=since; second<until; second++)); do
        for ((line=0; line<FAKE_JOURNAL_LINES_PER_SECOND; line++)); do
          printf 'agent-second-%s-line-%s\n' "$second" "$line"
        done
      done
      exit 0
      ;;
  esac
fi
case " $* " in
  *' -k '*) printf '%s\n' 'kernel: ordinary message' ;;
  *' -u dbdog-agent-sysprobe.service --since 24 hours ago '*)
    if [ "${FAKE_SYSPROBE_PANIC:-0}" = 1 ]; then
      printf '%s\n' \
        'system-probe[4242]: panic: runtime error: index out of range [65536] with length 28672' \
        'github.com/DataDog/datadog-agent/pkg/security/resolvers/dentry.(*Resolver).preventSegmentMajorPageFault' \
        'github.com/DataDog/datadog-agent/pkg/security/resolvers/dentry/resolver.go:432'
    else
      printf '%s\n' 'system-probe: ordinary message'
    fi
    ;;
  *)
    printf '%s\n' \
      'agent: ordinary message' \
      'password=journal-secret' \
      'Authorization: Bearer journal-bearer-secret' \
      'Authorization: Basic journal-basic-secret' \
      'Authorization: Digest username="journal-digest-user", response="journal-digest-response"' \
      "CREATE ROLE monitor LOGIN PASSWORD 'journal-ddl-password';" \
      "CREATE USER monitor IDENTIFIED BY 'journal-identified-password';"
    ;;
esac
EOF

cat >"$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF

cat >"$FAKE_BIN/coredumpctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_TRACE:?}/coredumpctl"
if [ "${FAKE_COREDUMP_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'Failed to connect to coredump journal' >&2
  exit 1
fi
if [ "${FAKE_COREDUMP_FALSE_NO_CORE:-0}" = 1 ]; then
  printf '%s\n' 'No coredumps found.'
  exit 1
fi
if [ "${FAKE_COREDUMP_LONG_LINE:-0}" = 1 ]; then
  awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "c"; printf "\n" }'
  exit 0
fi
if [ "${FAKE_COREDUMP_LIMIT_PLUS_ONE:-0}" = 1 ]; then
  # 测试用上限为 64：64 个字符加换行恰好 65 字节，producer 正常退出 0。
  printf '%064d\n' 0
  exit 0
fi
if [ "${FAKE_COREDUMP_OTHER:-0}" = 1 ]; then
  printf '%s\n' 'TIME PID UID GID SIG COREFILE EXE' \
    '2026-07-28 12:00:00 999 0 0 11 present /usr/bin/unrelated-worker'
  exit 0
fi
printf '%s\n' 'No coredumps found.'
EOF

cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_HOST_TOOLS_FAIL:-0}" -ne 1 ] || exit 127
case "${1:-}" in
  -a) printf '%s\n' 'Linux linux163 4.19.90-23.8.v2101.ky10.aarch64 #1 SMP aarch64 GNU/Linux' ;;
  -r) printf '%s\n' '4.19.90-23.8.v2101.ky10.aarch64' ;;
  -m) printf '%s\n' 'aarch64' ;;
  *) exit 64 ;;
esac
EOF

cat >"$FAKE_BIN/getconf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_HOST_TOOLS_FAIL:-0}" -ne 1 ] || exit 127
case "${1:-}" in
  PAGESIZE) printf '%s\n' '65536' ;;
  _NPROCESSORS_ONLN) printf '%s\n' '128' ;;
  *) exit 64 ;;
esac
EOF

cat >"$RUNTIME/bin/agent/agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_TRACE:?}/agent"
if [ "${FAKE_AGENT_LONG_OUTPUT:-0}" = 1 ]; then
  awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "s"; printf "\n" }'
  exit 0
fi
case "${1:-}" in
  status)
    if [ "${FAKE_AGENT_KILL_PARENT:-0}" = 1 ]; then
      kill -TERM "$PPID"
      sleep 2
      exit 143
    fi
    printf '%s\n' \
      'Agent status OK' \
      'cpu' \
      '  Average Execution Time: 12ms' \
      'system_core' \
      '  Last Execution Date: 2026-07-28 12:00:00 CST' \
      'gaussdb' \
      '  Total Runs: 3' \
      '  Errors: 0' \
      '{"password":"json-status-secret","token":"json-token-secret"}' \
      '--client-secret cli-status-secret' \
      'password: "status-secret"'
    ;;
  check)
    if [ "${FAKE_AGENT_KNOWN_ERROR:-0}" = 1 ]; then
      printf '%s\n' 'Function age(xid32) does not exist'
    else
      printf '%s\n' 'GaussDB check OK' 'DBDOG_API_KEY=check-secret'
    fi
    ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$FAKE_BIN/systemctl" "$FAKE_BIN/journalctl" "$FAKE_BIN/timeout" \
  "$FAKE_BIN/coredumpctl" "$FAKE_BIN/uname" "$FAKE_BIN/getconf" \
  "$RUNTIME/bin/agent/agent"

run_diagnostic() {
  rm -f -- "$TRACE/systemctl-show-count"
  env PATH="$FAKE_BIN:$PATH" \
    FAKE_TRACE="$TRACE" \
    FAKE_AGENT_KNOWN_ERROR="${FAKE_AGENT_KNOWN_ERROR:-0}" \
    FAKE_COREDUMP_FAIL="${FAKE_COREDUMP_FAIL:-0}" \
    FAKE_COREDUMP_FALSE_NO_CORE="${FAKE_COREDUMP_FALSE_NO_CORE:-0}" \
    FAKE_COREDUMP_OTHER="${FAKE_COREDUMP_OTHER:-0}" \
    FAKE_SYSTEMCTL_GROW="${FAKE_SYSTEMCTL_GROW:-0}" \
    FAKE_SYSPROBE_PANIC="${FAKE_SYSPROBE_PANIC:-0}" \
    FAKE_HOST_TOOLS_FAIL="${FAKE_HOST_TOOLS_FAIL:-0}" \
    FAKE_JOURNAL_OVERFLOW="${FAKE_JOURNAL_OVERFLOW:-0}" \
    FAKE_JOURNAL_FAIL="${FAKE_JOURNAL_FAIL:-0}" \
    FAKE_JOURNAL_LONG_LINE="${FAKE_JOURNAL_LONG_LINE:-0}" \
    FAKE_JOURNAL_LINES_PER_SECOND="${FAKE_JOURNAL_LINES_PER_SECOND:-}" \
    FAKE_COREDUMP_LONG_LINE="${FAKE_COREDUMP_LONG_LINE:-0}" \
    FAKE_COREDUMP_LIMIT_PLUS_ONE="${FAKE_COREDUMP_LIMIT_PLUS_ONE:-0}" \
    FAKE_AGENT_LONG_OUTPUT="${FAKE_AGENT_LONG_OUTPUT:-0}" \
    FAKE_AGENT_KILL_PARENT="${FAKE_AGENT_KILL_PARENT:-0}" \
    AGENT_RUNTIME_DIR="$RUNTIME" \
    AGENT_CONFIG_DIR="${TEST_AGENT_CONFIG_DIR:-$CONFIG}" \
    AGENT_LOG_DIR="$LOG_DIR" \
    AGENT_DIAGNOSTIC_OS_RELEASE_FILE="${AGENT_DIAGNOSTIC_OS_RELEASE_FILE:-$OS_RELEASE}" \
    AGENT_DIAGNOSTIC_SINCE_EPOCH="${AGENT_DIAGNOSTIC_SINCE_EPOCH:-}" \
    AGENT_DIAGNOSTIC_UNTIL_EPOCH="${AGENT_DIAGNOSTIC_UNTIL_EPOCH:-}" \
    AGENT_DIAGNOSTIC_RESULT_FILE="${AGENT_DIAGNOSTIC_RESULT_FILE:-}" \
    AGENT_DIAGNOSTIC_MAX_JOURNAL_LINES="${AGENT_DIAGNOSTIC_MAX_JOURNAL_LINES:-5000}" \
    AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES="${AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES:-262144}" \
    AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES="${AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES:-262144}" \
    AGENT_DIAGNOSTIC_MAX_TOTAL_BYTES="${AGENT_DIAGNOSTIC_MAX_TOTAL_BYTES:-8388608}" \
    TMPDIR="${AGENT_DIAGNOSTIC_TEST_TMPDIR:-${TMPDIR:-/tmp}}" \
    DBDOG_HOME="$TEST_ROOT/stack-layout-must-not-exist" \
    "$DBDOGCTL" diagnose dbdog-agent
}

prepare_machine_result() { # <path>
  rm -f -- "$1"
  (umask 077; : >"$1")
  chmod 0600 "$1"
}

HEALTHY_OUT="$TEST_ROOT/healthy.out"
run_diagnostic >"$HEALTHY_OUT" 2>&1 || {
  sed -n '1,320p' "$HEALTHY_OUT" >&2
  fail '健康诊断错误返回非零'
}
for expected in \
  'release_version=7.81.0-dbdog.2' \
  'artifact_sha256=' \
  'installer_contract_sha256=' \
  '===== host runtime =====' \
  'uname=Linux linux163 4.19.90-23.8.v2101.ky10.aarch64 #1 SMP aarch64 GNU/Linux' \
  'kernel_release=4.19.90-23.8.v2101.ky10.aarch64' \
  'machine_arch=aarch64' \
  'page_size_bytes=65536' \
  'online_cpu_count=128' \
  'os_pretty_name=Kylin Linux Advanced Server V10' \
  'os_id=kylin' \
  'os_version_id=V10' \
  'host_runtime_complete=true' \
  '===== collection intervals (safe subset) =====' \
  'cpu.min_collection_interval=15' \
  'system_core.min_collection_interval=20' \
  'process.min_collection_interval=30' \
  'collection_interval_summary_complete=true' \
  '--- dbdog-agent-sysprobe.service ---' \
  '--- dbdog-agent.service ---' \
  '--- dbdog-agent-trace.service ---' \
  '--- dbdog-agent-process.service ---' \
  'MainPID=4242' \
  'NRestarts=3' \
  'ExecMainStartTimestamp=' \
  'systemd restart delta during diagnostic' \
  'historical_nrestarts=3' \
  'restart_delta=0' \
  'restarted_during_diagnostic=false' \
  'recent agent journal (last 30 minutes, max 200 lines)' \
  'known system-probe panic summary' \
  'no known system-probe dentry page-size panic found' \
  'kernel OOM/segfault summary' \
  'recent coredumps (last 30 minutes, max 100 lines)' \
  'no coredumps found' \
  '===== agent status =====' \
  'agent status focused execution summary' \
  'Average Execution Time: 12ms' \
  'Last Execution Date: 2026-07-28 12:00:00 CST' \
  'Total Runs: 3' \
  'Errors: 0' \
  '===== agent check gaussdb =====' \
  'duration_seconds=' \
  'healthy=true' \
  'diagnostic_complete=true' \
  'historical_or_recent_evidence_findings=false' \
  '<redacted>'
do
  assert_contains "$HEALTHY_OUT" "$expected"
done
for secret in log-secret url-secret gauss-uri-secret journal-secret journal-bearer-secret \
  journal-basic-secret journal-digest-user journal-digest-response journal-ddl-password \
  journal-identified-password status-secret check-secret json-status-secret json-token-secret \
  cli-status-secret os-release-secret gauss-config-secret; do
  assert_not_contains "$HEALTHY_OUT" "$secret"
done
assert_not_contains "$HEALTHY_OUT" 'min_collection_interval=777'
[ ! -e "$TEST_ROOT/stack-layout-must-not-exist" ] || \
  fail 'diagnose dbdog-agent 错误创建了 stack 布局'
assert_contains "$TRACE/agent" "status -c $CONFIG"
assert_contains "$TRACE/agent" "check gaussdb -c $CONFIG"
for unit in dbdog-agent-sysprobe.service dbdog-agent.service \
  dbdog-agent-trace.service dbdog-agent-process.service; do
  assert_contains "$TRACE/journalctl" "-u $unit"
done
assert_contains "$TRACE/journalctl" '-n 200'
assert_contains "$TRACE/coredumpctl" "list --since 30 minutes ago --no-pager"
pass '诊断入口输出完整运行证据，限量且不创建 stack 布局'
pass 'journal、Agent log、status/check 中的常见凭证均被脱敏'

: >"$TRACE/journalctl"
: >"$TRACE/coredumpctl"
WINDOW_OUT="$TEST_ROOT/window.out"
WINDOW_RESULT="$TEST_ROOT/window.result"
prepare_machine_result "$WINDOW_RESULT"
AGENT_DIAGNOSTIC_SINCE_EPOCH=100000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=100900 \
  AGENT_DIAGNOSTIC_RESULT_FILE="$WINDOW_RESULT" \
  run_diagnostic >"$WINDOW_OUT" 2>&1 || fail '显式增量窗口诊断失败'
assert_contains "$WINDOW_OUT" 'scan_from_epoch=100000'
assert_contains "$WINDOW_OUT" 'scan_until_epoch=100900'
assert_contains "$WINDOW_OUT" 'processed_until_epoch=100900'
assert_contains "$WINDOW_OUT" 'window_complete=true'
assert_contains "$WINDOW_OUT" 'backlog_pending=false'
assert_contains "$WINDOW_OUT" 'incremental agent journal (bounded by scan window'
assert_contains "$WINDOW_OUT" 'incremental coredumps (bounded by scan window'
assert_contains "$WINDOW_OUT" 'delegated_to=collect-diagnostics.sh (inode/offset bounded scan)'
assert_not_contains "$WINDOW_OUT" 'agent.log tail'
assert_contains "$TRACE/journalctl" '--since @100000 --until @100900'
assert_contains "$TRACE/coredumpctl" 'list --since @100000 --until @100900 --no-pager'
assert_contains "$TRACE/journalctl" '-n 5001'
for expected in \
  'schema=dbdog-agent-diagnostic-result/v1' \
  'requested_from_epoch=100000' \
  'requested_until_epoch=100900' \
  'processed_until_epoch=100900' \
  'window_complete=true' \
  'evidence_complete=true' \
  'healthy=true'; do
  assert_contains "$WINDOW_RESULT" "$expected"
done
pass 'Agent journal/kernel/coredump 接受冻结窗口；文件日志交给 inode/offset collector'

OVERFLOW_OUT="$TEST_ROOT/window-overflow.out"
OVERFLOW_RESULT="$TEST_ROOT/window-overflow.result"
prepare_machine_result "$OVERFLOW_RESULT"
if FAKE_JOURNAL_OVERFLOW=1 AGENT_DIAGNOSTIC_MAX_JOURNAL_LINES=5 \
    AGENT_DIAGNOSTIC_SINCE_EPOCH=100000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=100900 \
    AGENT_DIAGNOSTIC_RESULT_FILE="$OVERFLOW_RESULT" \
    run_diagnostic >"$OVERFLOW_OUT" 2>&1; then
  fail 'journal 窗口超过资源上限仍误报完整'
fi
assert_contains "$OVERFLOW_OUT" 'window_limit_exceeded=true collector=agent-journal limit_kind=lines max_lines=5'
assert_contains "$OVERFLOW_OUT" 'processed_until_epoch=100000'
assert_contains "$OVERFLOW_OUT" 'diagnostic_complete=false'
assert_contains "$OVERFLOW_OUT" '这本身不等于 Agent 不健康'
assert_contains "$OVERFLOW_RESULT" 'processed_until_epoch=100000'
assert_contains "$OVERFLOW_RESULT" 'window_complete=false'
assert_contains "$OVERFLOW_RESULT" 'evidence_complete=false'
pass '单个最小时间片仍超限时 fail closed，不静默推进时间游标'

BACKLOG_UNTIL=200012
BACKLOG_FROM=200000
BACKLOG_EXPECTED=(200005 200010 200012)
for expected_until in "${BACKLOG_EXPECTED[@]}"; do
  BACKLOG_OUT="$TEST_ROOT/backlog-$BACKLOG_FROM.out"
  BACKLOG_RESULT="$TEST_ROOT/backlog-$BACKLOG_FROM.result"
  prepare_machine_result "$BACKLOG_RESULT"
  FAKE_JOURNAL_LINES_PER_SECOND=1 AGENT_DIAGNOSTIC_MAX_JOURNAL_LINES=5 \
    AGENT_DIAGNOSTIC_SINCE_EPOCH="$BACKLOG_FROM" \
    AGENT_DIAGNOSTIC_UNTIL_EPOCH="$BACKLOG_UNTIL" \
    AGENT_DIAGNOSTIC_RESULT_FILE="$BACKLOG_RESULT" \
    run_diagnostic >"$BACKLOG_OUT" 2>&1 || {
      sed -n '1,260p' "$BACKLOG_OUT" >&2
      fail '可安全推进的 journal backlog 错误返回失败'
    }
  assert_contains "$BACKLOG_RESULT" "processed_until_epoch=$expected_until"
  assert_contains "$BACKLOG_RESULT" 'evidence_complete=true'
  assert_contains "$BACKLOG_OUT" 'diagnostic_complete=true'
  BACKLOG_FROM="$expected_until"
done
assert_contains "$TEST_ROOT/backlog-200000.result" 'window_complete=false'
assert_contains "$TEST_ROOT/backlog-200005.result" 'window_complete=false'
assert_contains "$TEST_ROOT/backlog-200010.result" 'window_complete=true'
[ "$BACKLOG_FROM" -eq "$BACKLOG_UNTIL" ] || fail '多轮 journal backlog 未最终排空'
pass '超限 backlog 通过有界安全子窗口多轮推进并最终排空'

LOW_BUDGET_OUT="$TEST_ROOT/low-budget-bisection.out"
LOW_BUDGET_RESULT="$TEST_ROOT/low-budget-bisection.result"
prepare_machine_result "$LOW_BUDGET_RESULT"
FAKE_JOURNAL_LINES_PER_SECOND=1 AGENT_DIAGNOSTIC_MAX_JOURNAL_LINES=50 \
  AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES=4096 AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES=512 \
  AGENT_DIAGNOSTIC_MAX_TOTAL_BYTES=8192 \
  AGENT_DIAGNOSTIC_SINCE_EPOCH=500000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=501000 \
  AGENT_DIAGNOSTIC_RESULT_FILE="$LOW_BUDGET_RESULT" \
  run_diagnostic >"$LOW_BUDGET_OUT" 2>&1 || {
    sed -n '1,300p' "$LOW_BUDGET_OUT" >&2
    fail '丢弃的二分 attempts 错误耗尽总预算'
  }
assert_contains "$LOW_BUDGET_RESULT" 'processed_until_epoch=500050'
assert_contains "$LOW_BUDGET_RESULT" 'window_complete=false'
assert_contains "$LOW_BUDGET_RESULT" 'evidence_complete=true'
assert_contains "$LOW_BUDGET_OUT" 'diagnostic_complete=true'
assert_not_contains "$LOW_BUDGET_OUT" 'collector=agent-status max_bytes=512'
assert_not_contains "$LOW_BUDGET_OUT" 'collector=agent-check-gaussdb max_bytes=512'
pass '低总预算下丢弃的二分 attempts 不累计，仅最终 safe 三文件占用预算'

LONG_WINDOW_OUT="$TEST_ROOT/long-window.out"
LONG_WINDOW_RESULT="$TEST_ROOT/long-window.result"
prepare_machine_result "$LONG_WINDOW_RESULT"
if FAKE_JOURNAL_LONG_LINE=1 AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES=64 \
    AGENT_DIAGNOSTIC_SINCE_EPOCH=300000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=300001 \
    AGENT_DIAGNOSTIC_RESULT_FILE="$LONG_WINDOW_RESULT" \
    run_diagnostic >"$LONG_WINDOW_OUT" 2>&1; then
  fail '单秒内单行超出字节上限仍误报完整'
fi
assert_contains "$LONG_WINDOW_OUT" \
  'window_limit_exceeded=true collector=agent-journal limit_kind=bytes max_lines=5000 max_bytes=64'
assert_contains "$LONG_WINDOW_RESULT" 'processed_until_epoch=300000'
assert_contains "$LONG_WINDOW_RESULT" 'evidence_complete=false'
[ "$(wc -c <"$LONG_WINDOW_OUT" | tr -d '[:space:]')" -lt 20000 ] || \
  fail '超长单行导致诊断输出失去字节边界'
pass '单秒超长 journal 行受硬字节上限保护且不推进游标'

BOUNDED_OUT="$TEST_ROOT/all-captures-bounded.out"
if FAKE_JOURNAL_LONG_LINE=1 FAKE_COREDUMP_LONG_LINE=1 FAKE_AGENT_LONG_OUTPUT=1 \
    AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES=64 AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES=64 \
    AGENT_DIAGNOSTIC_MAX_TOTAL_BYTES=2048 \
    run_diagnostic >"$BOUNDED_OUT" 2>&1; then
  fail 'status/check/journal/coredump 超长输出仍误报诊断完整'
fi
for expected in \
  'capture_limit_exceeded=true collector=agent-journal max_bytes=64' \
  'capture_limit_exceeded=true collector=system-probe-journal max_bytes=64' \
  'capture_limit_exceeded=true collector=kernel-journal max_bytes=64' \
  'capture_limit_exceeded=true collector=coredump-list max_bytes=64' \
  'capture_limit_exceeded=true collector=agent-status max_bytes=64' \
  'capture_limit_exceeded=true collector=agent-check-gaussdb max_bytes=64' \
  'diagnostic_complete=false'; do
  assert_contains "$BOUNDED_OUT" "$expected"
done
[ "$(wc -c <"$BOUNDED_OUT" | tr -d '[:space:]')" -lt 20000 ] || \
  fail '并发高输出诊断报告超过合理有界大小'
pass 'status/check/journal/kernel/coredump 的单行和高速输出均受总字节预算保护'

COREDUMP_PLUS_ONE_OUT="$TEST_ROOT/coredump-limit-plus-one.out"
if FAKE_COREDUMP_LIMIT_PLUS_ONE=1 AGENT_DIAGNOSTIC_MAX_JOURNAL_BYTES=64 \
    run_diagnostic >"$COREDUMP_PLUS_ONE_OUT" 2>&1; then
  fail 'coredumpctl 正常退出但输出 limit+1 字节仍误报完整'
fi
assert_contains "$COREDUMP_PLUS_ONE_OUT" \
  'capture_limit_exceeded=true collector=coredump-list max_bytes=64'
assert_contains "$COREDUMP_PLUS_ONE_OUT" 'exit_code=0'
assert_contains "$COREDUMP_PLUS_ONE_OUT" 'diagnostic_complete=false'
assert_contains "$COREDUMP_PLUS_ONE_OUT" 'healthy=true'
pass 'coredumpctl producer rc=0 时 limit+1 字节仍使证据不完整且不误判健康'

COREDUMP_FALSE_SUCCESS_OUT="$TEST_ROOT/coredump-false-success.out"
if FAKE_COREDUMP_FALSE_NO_CORE=1 run_diagnostic >"$COREDUMP_FALSE_SUCCESS_OUT" 2>&1; then
  fail 'coredumpctl 非零退出却输出 No coredumps found 时误报完整'
fi
assert_contains "$COREDUMP_FALSE_SUCCESS_OUT" 'No coredumps found.'
assert_contains "$COREDUMP_FALSE_SUCCESS_OUT" 'exit_code=1'
assert_contains "$COREDUMP_FALSE_SUCCESS_OUT" 'diagnostic_complete=false'
assert_contains "$COREDUMP_FALSE_SUCCESS_OUT" 'healthy=true'
pass 'No coredumps found 仅在 coredumpctl 成功退出时可视为完整证据'

LATE_FAILURE_OUT="$TEST_ROOT/custom-window-late-failure.out"
LATE_FAILURE_RESULT="$TEST_ROOT/custom-window-late-failure.result"
prepare_machine_result "$LATE_FAILURE_RESULT"
if FAKE_AGENT_LONG_OUTPUT=1 AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES=64 \
    AGENT_DIAGNOSTIC_SINCE_EPOCH=600000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=600100 \
    AGENT_DIAGNOSTIC_RESULT_FILE="$LATE_FAILURE_RESULT" \
    run_diagnostic >"$LATE_FAILURE_OUT" 2>&1; then
  fail '完整 journal 窗口后的 status 输出超限没有回退机器水位'
fi
for expected in \
  'requested_from_epoch=600000' \
  'requested_until_epoch=600100' \
  'processed_until_epoch=600000' \
  'window_complete=false' \
  'evidence_complete=false'; do
  assert_contains "$LATE_FAILURE_RESULT" "$expected"
done
grep -Eq '^healthy=(true|false)$' "$LATE_FAILURE_RESULT" || \
  fail '回退机器结果缺少独立 healthy 布尔字段'
assert_contains "$LATE_FAILURE_OUT" 'negotiated_window_complete=true'
assert_contains "$LATE_FAILURE_OUT" 'processed_until_epoch=600000'
assert_contains "$LATE_FAILURE_OUT" 'diagnostic_complete=false'
pass 'journal 协商成功后其它证据失败仍统一回退到调用前时间水位'

EMPTY_LATE_FAILURE_OUT="$TEST_ROOT/custom-empty-window-late-failure.out"
EMPTY_LATE_FAILURE_RESULT="$TEST_ROOT/custom-empty-window-late-failure.result"
prepare_machine_result "$EMPTY_LATE_FAILURE_RESULT"
if FAKE_AGENT_LONG_OUTPUT=1 AGENT_DIAGNOSTIC_MAX_COMMAND_BYTES=64 \
    AGENT_DIAGNOSTIC_SINCE_EPOCH=700000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=700000 \
    AGENT_DIAGNOSTIC_RESULT_FILE="$EMPTY_LATE_FAILURE_RESULT" \
    run_diagnostic >"$EMPTY_LATE_FAILURE_OUT" 2>&1; then
  fail '空 journal 窗口后的 status 输出超限错误返回成功'
fi
for expected in \
  'processed_until_epoch=700000' \
  'window_complete=true' \
  'evidence_complete=false'; do
  assert_contains "$EMPTY_LATE_FAILURE_RESULT" "$expected"
done
assert_contains "$EMPTY_LATE_FAILURE_OUT" 'backlog_pending=false'
assert_contains "$EMPTY_LATE_FAILURE_OUT" 'diagnostic_complete=false'
pass '同秒空时间窗保持 window complete，后续证据失败仍不推进且不制造 backlog'

DIAG_TMP_PARENT="$TEST_ROOT/diagnostic-tmp"
mkdir -m 0700 "$DIAG_TMP_PARENT"
FAILED_CLEANUP_OUT="$TEST_ROOT/failed-cleanup.out"
if FAKE_COREDUMP_FAIL=1 AGENT_DIAGNOSTIC_TEST_TMPDIR="$DIAG_TMP_PARENT" \
    run_diagnostic >"$FAILED_CLEANUP_OUT" 2>&1; then
  fail '模拟采集失败错误返回成功'
fi
if find "$DIAG_TMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  find "$DIAG_TMP_PARENT" -mindepth 1 -maxdepth 2 -print >&2
  fail '失败路径遗留诊断 raw/limited 临时文件'
fi
pass '采集异常返回会由 trap 清理全部 0700/0600 临时证据'

SIGNAL_CLEANUP_OUT="$TEST_ROOT/signal-cleanup.out"
if FAKE_AGENT_KILL_PARENT=1 AGENT_DIAGNOSTIC_TEST_TMPDIR="$DIAG_TMP_PARENT" \
    run_diagnostic >"$SIGNAL_CLEANUP_OUT" 2>&1; then
  fail '模拟 TERM 中断错误返回成功'
fi
if find "$DIAG_TMP_PARENT" -mindepth 1 -print -quit | grep -q .; then
  find "$DIAG_TMP_PARENT" -mindepth 1 -maxdepth 2 -print >&2
  fail 'TERM 中断路径遗留诊断临时文件'
fi
pass 'TERM 中断路径同样由 EXIT trap 清理全部临时证据'

MISSING_RESULT_OUT="$TEST_ROOT/missing-result.out"
if AGENT_DIAGNOSTIC_SINCE_EPOCH=400000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=400001 \
    run_diagnostic >"$MISSING_RESULT_OUT" 2>&1; then
  fail '显式时间窗错误接受缺失的 machine-result 文件'
fi
assert_contains "$MISSING_RESULT_OUT" '必须提供 AGENT_DIAGNOSTIC_RESULT_FILE'
UNSAFE_RESULT="$TEST_ROOT/unsafe-result"
: >"$UNSAFE_RESULT"
chmod 0644 "$UNSAFE_RESULT"
UNSAFE_RESULT_OUT="$TEST_ROOT/unsafe-result.out"
if AGENT_DIAGNOSTIC_SINCE_EPOCH=400000 AGENT_DIAGNOSTIC_UNTIL_EPOCH=400001 \
    AGENT_DIAGNOSTIC_RESULT_FILE="$UNSAFE_RESULT" \
    run_diagnostic >"$UNSAFE_RESULT_OUT" 2>&1; then
  fail 'machine-result 错误接受非 0600 文件'
fi
assert_contains "$UNSAFE_RESULT_OUT" '权限必须是 0600'
pass 'machine-result 必须由 caller 在私有目录预创建，拒绝缺失或宽权限文件'

MISSING_CONFIG="$TEST_ROOT/missing-config"
MISSING_OS_RELEASE="$TEST_ROOT/missing-os-release"
mkdir -p "$MISSING_CONFIG/conf.d/system_core.d" "$MISSING_CONFIG/conf.d/process.d"
printf 'instances:\n  - {}\n' >"$MISSING_CONFIG/conf.d/system_core.d/conf.yaml"
printf 'instances:\n  - min_collection_interval: interval-field-secret\n' \
  >"$MISSING_CONFIG/conf.d/process.d/conf.yaml"
printf 'ID=kylin\n' >"$MISSING_OS_RELEASE"
MISSING_HOST_OUT="$TEST_ROOT/missing-host.out"
FAKE_HOST_TOOLS_FAIL=1 TEST_AGENT_CONFIG_DIR="$MISSING_CONFIG" \
  AGENT_DIAGNOSTIC_OS_RELEASE_FILE="$MISSING_OS_RELEASE" \
  run_diagnostic >"$MISSING_HOST_OUT" 2>&1 || {
    sed -n '1,260p' "$MISSING_HOST_OUT" >&2
    fail '可选宿主工具/字段缺失错误改变了 Agent 健康结果'
  }
for expected in \
  'uname=unavailable' \
  'kernel_release=unavailable' \
  'machine_arch=unavailable' \
  'page_size_bytes=unavailable' \
  'online_cpu_count=unavailable' \
  'os_pretty_name=unavailable' \
  'os_id=kylin' \
  'os_version_id=unavailable' \
  'host_runtime_complete=false (best_effort_only=true)' \
  'cpu.min_collection_interval=config_unavailable' \
  'system_core.min_collection_interval=not_configured' \
  'process.min_collection_interval=invalid' \
  'collection_interval_summary_complete=false (best_effort_only=true)' \
  'healthy=true' \
  'diagnostic_complete=true'; do
  assert_contains "$MISSING_HOST_OUT" "$expected"
done
assert_not_contains "$MISSING_HOST_OUT" 'interval-field-secret'
HOST_RUNTIME_BODY="$(awk '/^agent_diagnostic_host_runtime\(\)/ { scan=1 } /^agent_diagnostic_interval_value\(\)/ { scan=0 } scan { print }' "$DBDOGCTL")"
INTERVAL_BODY="$(awk '/^agent_diagnostic_collection_intervals\(\)/ { scan=1 } /^agent_diagnostic_run_timed\(\)/ { scan=0 } scan { print }' "$DBDOGCTL")"
grep -Fq 'command -v uname' <<<"$HOST_RUNTIME_BODY" || \
  fail '宿主摘要没有把 uname 当作可选工具'
grep -Fq 'command -v getconf' <<<"$HOST_RUNTIME_BODY" || \
  fail '宿主摘要没有把 getconf 当作可选工具'
if grep -Fqi 'gaussdb' <<<"$INTERVAL_BODY"; then
  fail '采集间隔摘要越权读取了 GaussDB 配置'
fi
pass '宿主工具/字段或安全配置字段缺失时降级输出，不影响健康且不读取 GaussDB 配置'

UNRELATED_CORE_OUT="$TEST_ROOT/unrelated-core.out"
FAKE_COREDUMP_OTHER=1 run_diagnostic >"$UNRELATED_CORE_OUT" 2>&1 || \
  fail '其它进程的 coredump 不应判当前 Agent 不健康'
assert_contains "$UNRELATED_CORE_OUT" 'agent_related_coredump_findings=false'
assert_contains "$UNRELATED_CORE_OUT" 'historical_or_recent_evidence_findings=false'
assert_contains "$UNRELATED_CORE_OUT" 'healthy=true'
pass '其它进程的 kernel/coredump 证据不会误归因给 Agent'

PANIC_OUT="$TEST_ROOT/sysprobe-panic.out"
FAKE_SYSPROBE_PANIC=1 run_diagnostic >"$PANIC_OUT" 2>&1 || \
  fail '历史 sysprobe panic 线索不应在当前无重启时冒充实时失败'
assert_contains "$PANIC_OUT" 'classification=known_system_probe_dentry_64k_page_panic'
assert_contains "$PANIC_OUT" 'bounds-safe dentry eRPC fix; keep NPM/USM process event streams enabled'
assert_contains "$PANIC_OUT" 'preventSegmentMajorPageFault'
assert_contains "$PANIC_OUT" 'historical_or_recent_evidence_findings=true'
assert_contains "$PANIC_OUT" 'restart_delta=0'
assert_contains "$PANIC_OUT" 'healthy=true'
pass '64 KiB 页 EventMonitor dentry panic 被明确分类且与当前 restart delta 分离'

printf '%s\n' 'Function age(xid32) does not exist' >>"$LOG_DIR/agent.log"
HISTORICAL_OUT="$TEST_ROOT/historical-error.out"
run_diagnostic >"$HISTORICAL_OUT" 2>&1 || \
  fail '仅 agent.log tail 含历史错误时不应判当前 Agent 不健康'
assert_contains "$HISTORICAL_OUT" 'known_runtime_error_in_agent_log_tail=true'
assert_contains "$HISTORICAL_OUT" 'historical_or_recent_evidence_findings=true'
assert_contains "$HISTORICAL_OUT" 'healthy=true'
assert_contains "$HISTORICAL_OUT" 'diagnostic_complete=true'
pass '历史日志线索与当前健康结论分离'

INCOMPLETE_OUT="$TEST_ROOT/incomplete.out"
if FAKE_COREDUMP_FAIL=1 run_diagnostic >"$INCOMPLETE_OUT" 2>&1; then
  fail 'coredump 证据缺失时诊断不应返回成功'
fi
assert_contains "$INCOMPLETE_OUT" 'healthy=true'
assert_contains "$INCOMPLETE_OUT" 'diagnostic_complete=false'
assert_contains "$INCOMPLETE_OUT" '这本身不等于 Agent 不健康'
pass '证据不完整与 Agent unhealthy 分离'

RESTART_OUT="$TEST_ROOT/restart.out"
if FAKE_SYSTEMCTL_GROW=1 run_diagnostic >"$RESTART_OUT" 2>&1; then
  fail '诊断期间 PID/NRestarts 增长未使当前健康检查失败'
fi
assert_contains "$RESTART_OUT" 'historical_nrestarts=3'
assert_contains "$RESTART_OUT" 'restart_delta=1'
assert_contains "$RESTART_OUT" 'restarted_during_diagnostic=true'
assert_contains "$RESTART_OUT" 'healthy=false'
pass '仅比较诊断起止增量，历史 NRestarts 不误判且当前重启可检出'

KNOWN_OUT="$TEST_ROOT/known-error.out"
if FAKE_AGENT_KNOWN_ERROR=1 run_diagnostic >"$KNOWN_OUT" 2>&1; then
  fail '已知 GaussDB SQL 错误未使诊断返回非零'
fi
assert_contains "$KNOWN_OUT" 'Function age(xid32) does not exist'
assert_contains "$KNOWN_OUT" 'known_runtime_error=true'
assert_contains "$KNOWN_OUT" 'healthy=false'
assert_contains "$KNOWN_OUT" '不要在监控库手工建兼容函数'
pass '已知 GaussDB 方言错误会显式标红诊断'

BAD_OUT="$TEST_ROOT/bad-usage.out"
if env DBDOG_HOME="$TEST_ROOT/unused" "$DBDOGCTL" diagnose postgresql >"$BAD_OUT" 2>&1; then
  fail 'diagnose 错误接受非 Agent 目标'
fi
assert_contains "$BAD_OUT" '用法: sudo dbdogctl diagnose dbdog-agent'
pass '诊断命令只接受精确 dbdog-agent 目标'

printf 'ALL PASS: %s agent diagnostic contract groups\n' "$PASS_COUNT"
