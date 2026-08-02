#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="$SCRIPT_DIR/collect-diagnostics.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-diagnostics-collector-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
PASS_COUNT=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$*"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 缺少: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 泄露/误含: $2"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
result_value() { awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"; }

FAKE_BIN="$TEST_ROOT/bin"
REAL_DD="$(command -v dd)"
STACK_HOME="$TEST_ROOT/stack"
DIAG_DIR="$TEST_ROOT/diagnostics"
MANIFEST_FIXTURE="$TEST_ROOT/manifest.tsv"
PROC_FIXTURE="$TEST_ROOT/proc"
mkdir -p "$FAKE_BIN" "$STACK_HOME"/{modules,etc,data/pg,logs,run,cache} "$PROC_FIXTURE/$$"
printf '%s\n' '0.10 0.20 0.30 1/100 123' >"$PROC_FIXTURE/loadavg"
printf '%s\n' \
  'MemTotal:       1048576 kB' \
  'MemAvailable:    524288 kB' \
  'SwapTotal:       262144 kB' \
  'SwapFree:        262144 kB' >"$PROC_FIXTURE/meminfo"
printf '%s\n' "$$ (bash) S 1 1 1 0" >"$PROC_FIXTURE/$$/stat"
printf '%s\n' 'Name: bash' 'State: S (sleeping)' 'VmRSS: 1024 kB' 'Threads: 1' \
  >"$PROC_FIXTURE/$$/status"

cat >"$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'State Recv-Q Send-Q Local Address:Port Peer Address:Port' \
  'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:8123 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:9000 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:8770 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*' \
  'LISTEN 0 128 127.0.0.1:8090 0.0.0.0:*'
EOF
cat >"$FAKE_BIN/dd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=""
for argument in "$@"; do
  case "$argument" in if=*) input="${argument#if=}" ;; esac
done
if { [ -n "${FAKE_SHORT_READ_PATH:-}" ] && [ "$input" = "$FAKE_SHORT_READ_PATH" ]; } || \
   { [ -n "${FAKE_REWRITE_PATH:-}" ] && [ "$input" = "$FAKE_REWRITE_PATH" ]; }; then
  count=0
  if [ -f "${FAKE_DD_STATE:?}" ]; then IFS= read -r count <"$FAKE_DD_STATE" || true; fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_DD_STATE"
  if [ -n "${FAKE_SHORT_READ_PATH:-}" ] && [ "$input" = "$FAKE_SHORT_READ_PATH" ] && \
     [ "$count" -eq 3 ]; then
    # 模拟采集中 truncate：dd 自称成功，但没有提供请求字节。
    exit 0
  fi
  "${REAL_DD:?}" "$@"
  rc=$?
  if [ -n "${FAKE_REWRITE_PATH:-}" ] && [ "$input" = "$FAKE_REWRITE_PATH" ] && \
     [ "$count" -eq 3 ]; then
    cp "${FAKE_REWRITE_SOURCE:?}" "$input"
  fi
  exit "$rc"
fi
exec "${REAL_DD:?}" "$@"
EOF
chmod 0755 "$FAKE_BIN/timeout" "$FAKE_BIN/curl" "$FAKE_BIN/ss" "$FAKE_BIN/dd"

printf '# module\tkind\ttarget\tservice\tversion\tartifact\tsha256\tsource_sha\tarch\n' \
  >"$MANIFEST_FIXTURE"
for module in node goose postgresql clickhouse dbdog-server dbdog-web dbdog-mcp; do
  printf '%s\tfirst-party\tstack\t%s\t1.2.3\t%s-aarch64.tar.gz\t%s\t%s\taarch64\n' \
    "$module" "$module" "$module" \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >>"$MANIFEST_FIXTURE"
  mkdir -p "$STACK_HOME/modules/$module/$module-1.2.3"
  printf '1.2.3\n' >"$STACK_HOME/modules/$module/$module-1.2.3/.dbdog-manifest-version"
  printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    >"$STACK_HOME/modules/$module/$module-1.2.3/.dbdog-artifact-sha256"
  ln -s "$module-1.2.3" "$STACK_HOME/modules/$module/current"
done
mkdir -p "$STACK_HOME/modules/postgresql/postgresql-1.2.3/bin" \
  "$STACK_HOME/modules/clickhouse/clickhouse-1.2.3/bin"
cat >"$STACK_HOME/modules/postgresql/postgresql-1.2.3/bin/pg_isready" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$STACK_HOME/modules/clickhouse/clickhouse-1.2.3/bin/clickhouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$STACK_HOME/modules/postgresql/postgresql-1.2.3/bin/pg_isready" \
  "$STACK_HOME/modules/clickhouse/clickhouse-1.2.3/bin/clickhouse"

printf '%s\n' "$$" >"$STACK_HOME/data/pg/postmaster.pid"
for service in clickhouse dbdog-server ddsql-server dbdog-web dbdog-mcp; do
  printf '%s\n' "$$" >"$STACK_HOME/run/$service.pid"
done
for log in postgresql.log clickhouse.log clickhouse.err.log dbdog-server.log \
  ddsql-server.log dbdog-web.log dbdog-mcp.log; do
  printf 'old-line-%s hostname=inside-host password=plain-secret\n' "$log" \
    >"$STACK_HOME/logs/$log"
done
printf '%s\n' 'gaussdb://monitor:gauss-uri-secret@10.44.136.163:37000/postgres' \
  >>"$STACK_HOME/logs/dbdog-server.log"

run_stack() { # <epoch> <stdout file>
  local epoch="$1" output="$2"
  env PATH="$FAKE_BIN:$PATH" \
    DBDOG_HOME="$STACK_HOME" \
    DBDOG_DIAGNOSTICS_DIR="$DIAG_DIR" \
    DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
    DBDOG_DIAGNOSTIC_NOW_EPOCH="$epoch" \
    REAL_DD="$REAL_DD" \
    FAKE_SHORT_READ_PATH="${FAKE_SHORT_READ_PATH:-}" \
    FAKE_REWRITE_PATH="${FAKE_REWRITE_PATH:-}" \
    FAKE_REWRITE_SOURCE="${FAKE_REWRITE_SOURCE:-}" \
    FAKE_DD_STATE="${FAKE_DD_STATE:-$TEST_ROOT/dd-state}" \
    DBDOG_DIAGNOSTIC_MAX_LOG_BYTES="${DBDOG_DIAGNOSTIC_MAX_LOG_BYTES:-1048576}" \
    MANIFEST="$MANIFEST_FIXTURE" \
    DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
    bash "$COLLECTOR" >"$output" 2>&1
}

FIRST_OUT="$TEST_ROOT/first.out"
run_stack 200000 "$FIRST_OUT" || { sed -n '1,300p' "$FIRST_OUT" >&2; fail '首次采集失败'; }
FIRST_REPORT="$(result_value "$FIRST_OUT" internal_report)"
FIRST_ISSUE="$(result_value "$FIRST_OUT" issue_card)"
CURSOR="$DIAG_DIR/collect-diagnostics.cursor"
assert_contains "$FIRST_REPORT" 'schema=dbdog-diagnostics/v1'
assert_contains "$FIRST_REPORT" 'host_role=stack'
assert_contains "$FIRST_REPORT" 'scan_from_epoch=113600'
assert_contains "$FIRST_REPORT" 'stack_coverage=postgresql,clickhouse,dbdog-server,ddsql-server,dbdog-web,dbdog-mcp'
assert_contains "$FIRST_REPORT" 'profiling_has_no_independent_process'
assert_contains "$FIRST_REPORT" 'release_checkout_commit='
assert_contains "$FIRST_REPORT" 'release_checkout_dirty='
assert_contains "$FIRST_REPORT" 'manifest_sha256='
assert_contains "$FIRST_REPORT" 'diagnostic_contract_sha256='
assert_contains "$FIRST_REPORT" 'host_arch=aarch64'
assert_contains "$FIRST_REPORT" 'manifest_arch=aarch64'
assert_contains "$FIRST_REPORT" 'artifact=dbdog-server-aarch64.tar.gz'
assert_contains "$FIRST_REPORT" 'old-line-dbdog-server.log'
assert_contains "$FIRST_REPORT" 'password=<redacted>'
assert_not_contains "$FIRST_REPORT" 'plain-secret'
assert_contains "$FIRST_REPORT" 'gaussdb://monitor:<redacted>@10.44.136.163:37000/postgres'
assert_not_contains "$FIRST_REPORT" 'gauss-uri-secret'
assert_not_contains "$FIRST_ISSUE" 'inside-host'
assert_not_contains "$FIRST_ISSUE" 'old-line-'
assert_contains "$FIRST_ISSUE" 'contains_raw_logs=false'
assert_contains "$FIRST_ISSUE" 'release_checkout_commit='
assert_contains "$FIRST_ISSUE" 'manifest_sha256='
assert_contains "$FIRST_ISSUE" 'diagnostic_contract_sha256='
[ "$(file_mode "$FIRST_REPORT")" = 600 ] || fail 'internal report 不是 0600'
[ "$(file_mode "$FIRST_ISSUE")" = 600 ] || fail 'issue-card 不是 0600'
[ "$(file_mode "$CURSOR")" = 600 ] || fail 'cursor 不是 0600'
assert_contains "$CURSOR" 'completed_until_epoch=200000'
pass '首次 24h 窗口、stack 角色、0600 与双层输出合同成立'
pass '内网报告遮盖凭证，issue-card 不含原始日志/主机字面'

printf 'new-only-line token=second-secret\n' >>"$STACK_HOME/logs/dbdog-server.log"
SECOND_OUT="$TEST_ROOT/second.out"
run_stack 200100 "$SECOND_OUT" || fail '增量采集失败'
SECOND_REPORT="$(result_value "$SECOND_OUT" internal_report)"
assert_contains "$SECOND_REPORT" 'cursor_status=incremental'
assert_contains "$SECOND_REPORT" 'scan_from_epoch=200000'
assert_contains "$SECOND_REPORT" 'new-only-line token=<redacted>'
assert_not_contains "$SECOND_REPORT" 'old-line-dbdog-server.log'
assert_not_contains "$SECOND_REPORT" 'second-secret'
assert_contains "$CURSOR" 'completed_until_epoch=200100'
pass '后续采集从上次成功时间与 inode/offset 增量继续'

printf 'rename-carryover token=rename-secret\n' >>"$STACK_HOME/logs/dbdog-server.log"
mv "$STACK_HOME/logs/dbdog-server.log" "$STACK_HOME/logs/dbdog-server.log.1"
printf 'after-rotation password=rotation-secret\n' >"$STACK_HOME/logs/dbdog-server.log"
ROTATE_OUT="$TEST_ROOT/rotate.out"
run_stack 200200 "$ROTATE_OUT" || fail '轮转后采集失败'
ROTATE_REPORT="$(result_value "$ROTATE_OUT" internal_report)"
assert_contains "$ROTATE_REPORT" 'reason=rotated'
assert_contains "$ROTATE_REPORT" 'plain_log_rotations_detected=1'
assert_contains "$ROTATE_REPORT" 'rename-carryover token=<redacted>'
assert_contains "$ROTATE_REPORT" 'after-rotation password=<redacted>'
assert_not_contains "$ROTATE_REPORT" 'rotation-secret'
assert_not_contains "$ROTATE_REPORT" 'rename-secret'
assert_contains "$CURSOR" 'completed_until_epoch=200200'
pass 'rename/create 轮转先补读旧 inode 余量，再从新文件开头继续'

touch -t 202501010101.01 "$STACK_HOME/logs/dbdog-server.log.1"
printf 'multi-rotation-old-carryover\n' >>"$STACK_HOME/logs/dbdog-server.log"
mv "$STACK_HOME/logs/dbdog-server.log" "$STACK_HOME/logs/dbdog-server.log.multi.2"
touch -t 202601010101.01 "$STACK_HOME/logs/dbdog-server.log.multi.2"
printf 'multi-rotation-middle\n' >"$STACK_HOME/logs/dbdog-server.log"
mv "$STACK_HOME/logs/dbdog-server.log" "$STACK_HOME/logs/dbdog-server.log.multi.1"
touch -t 202601010101.02 "$STACK_HOME/logs/dbdog-server.log.multi.1"
printf 'multi-rotation-current\n' >"$STACK_HOME/logs/dbdog-server.log"
MULTI_ROTATE_OUT="$TEST_ROOT/multi-rotate.out"
run_stack 200225 "$MULTI_ROTATE_OUT" || fail '两级轮转后采集失败'
MULTI_ROTATE_REPORT="$(result_value "$MULTI_ROTATE_OUT" internal_report)"
assert_contains "$MULTI_ROTATE_REPORT" 'multi-rotation-old-carryover'
assert_contains "$MULTI_ROTATE_REPORT" 'multi-rotation-middle'
assert_contains "$MULTI_ROTATE_REPORT" 'multi-rotation-current'
assert_contains "$MULTI_ROTATE_REPORT" 'rotation_chain_continues=true'
assert_contains "$CURSOR" 'completed_until_epoch=200225'
pass '两次手工采集之间发生多级轮转时逐个补读中间文件，不直跳 current'

printf 'copytruncate-carryover token=copy-secret\n' >>"$STACK_HOME/logs/dbdog-server.log"
cp "$STACK_HOME/logs/dbdog-server.log" "$STACK_HOME/logs/dbdog-server.log.2"
: >"$STACK_HOME/logs/dbdog-server.log"
printf '%s\n' \
  'after-copytruncate-000000000000000000000000000000000000000000000000000000000000000000000000' \
  >>"$STACK_HOME/logs/dbdog-server.log"
COPYTRUNCATE_OUT="$TEST_ROOT/copytruncate.out"
run_stack 200250 "$COPYTRUNCATE_OUT" || fail 'copytruncate 后采集失败'
COPYTRUNCATE_REPORT="$(result_value "$COPYTRUNCATE_OUT" internal_report)"
assert_contains "$COPYTRUNCATE_REPORT" 'continuity_recovered=true reason=copytruncate_or_rewrite'
assert_contains "$COPYTRUNCATE_REPORT" 'copytruncate-carryover token=<redacted>'
assert_contains "$COPYTRUNCATE_REPORT" 'after-copytruncate-'
assert_not_contains "$COPYTRUNCATE_REPORT" 'copy-secret'
assert_contains "$CURSOR" 'completed_until_epoch=200250'
assert_contains "$CURSOR" 'schema=dbdog-diagnostics-cursor/v2'
pass '同 inode copytruncate 重长超过旧 offset 仍由前缀/边界指纹检出并补读轮转副本'

printf 'generation-old-must-not-be-lost\n' >>"$STACK_HOME/logs/dbdog-server.log"
REWRITE_SOURCE="$TEST_ROOT/rewrite-source.log"
sed 's/generation-old/generation-new/' "$STACK_HOME/logs/dbdog-server.log" >"$REWRITE_SOURCE"
CURSOR_REWRITE_BEFORE="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
REWRITE_OUT="$TEST_ROOT/rewrite.out"
rm -f "$TEST_ROOT/dd-state"
if FAKE_REWRITE_PATH="$STACK_HOME/logs/dbdog-server.log" \
    FAKE_REWRITE_SOURCE="$REWRITE_SOURCE" FAKE_DD_STATE="$TEST_ROOT/dd-state" \
    run_stack 200260 "$REWRITE_OUT"; then
  fail '采集中同 inode 截断并回长未使采集事务失败'
fi
REWRITE_REPORT="$(result_value "$REWRITE_OUT" internal_report)"
assert_contains "$REWRITE_REPORT" 'state=content_changed_during_collection source=current'
CURSOR_REWRITE_AFTER="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
[ "$CURSOR_REWRITE_BEFORE" = "$CURSOR_REWRITE_AFTER" ] || fail '代际变化错误推进了 cursor'
pass '同 inode 日志在采集两次读之间截断回长会被内容哈希发现且不推进'

printf 'short-read-must-remain-pending\n' >>"$STACK_HOME/logs/dbdog-server.log"
CURSOR_SHORT_BEFORE="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
SHORT_OUT="$TEST_ROOT/short.out"
rm -f "$TEST_ROOT/dd-state"
if FAKE_SHORT_READ_PATH="$STACK_HOME/logs/dbdog-server.log" \
    FAKE_DD_STATE="$TEST_ROOT/dd-state" run_stack 200275 "$SHORT_OUT"; then
  fail 'dd 短读未使采集事务失败'
fi
SHORT_REPORT="$(result_value "$SHORT_OUT" internal_report)"
assert_contains "$SHORT_REPORT" 'state=read_failed source=current'
assert_contains "$SHORT_REPORT" 'collection_complete=false'
CURSOR_SHORT_AFTER="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
[ "$CURSOR_SHORT_BEFORE" = "$CURSOR_SHORT_AFTER" ] || fail '短读错误推进了 cursor'
pass '采集中短读即使 dd 返回 0 也由实际字节数检出且不推进游标'

CATCHUP_OUT="$TEST_ROOT/catchup.out"
run_stack 200280 "$CATCHUP_OUT" || fail '短读后的正常补采失败'
printf 'panic: oversized-fragment-%0130doversized-final-marker' 0 \
  >>"$STACK_HOME/logs/dbdog-server.log"
OVERSIZED_OUT="$TEST_ROOT/oversized.out"
DBDOG_DIAGNOSTIC_MAX_LOG_BYTES=64 run_stack 200290 "$OVERSIZED_OUT" || \
  fail '超长无换行日志片段采集失败'
OVERSIZED_REPORT="$(result_value "$OVERSIZED_OUT" internal_report)"
OVERSIZED_ISSUE="$(result_value "$OVERSIZED_OUT" issue_card)"
assert_contains "$OVERSIZED_REPORT" 'oversized_unterminated_fragment_included=true'
assert_contains "$OVERSIZED_REPORT" 'log_content_is_line_fragment=true'
assert_contains "$OVERSIZED_REPORT" 'panic: oversized-fragment-'
assert_contains "$OVERSIZED_ISSUE" 'error_class.panic=1'
assert_contains "$CURSOR" 'completed_until_epoch=200290'
printf '\n' >>"$STACK_HOME/logs/dbdog-server.log"
OVERSIZED_CONTINUE_OUT="$TEST_ROOT/oversized-continue.out"
DBDOG_DIAGNOSTIC_MAX_LOG_BYTES=64 run_stack 200291 "$OVERSIZED_CONTINUE_OUT" || \
  fail '超长无换行日志第二片采集失败'
OVERSIZED_CONTINUE_REPORT="$(result_value "$OVERSIZED_CONTINUE_OUT" internal_report)"
assert_contains "$OVERSIZED_CONTINUE_REPORT" 'oversized_fragment_continuation=true'
OVERSIZED_FINAL_OUT="$TEST_ROOT/oversized-final.out"
DBDOG_DIAGNOSTIC_MAX_LOG_BYTES=64 run_stack 200292 "$OVERSIZED_FINAL_OUT" || \
  fail '超长无换行日志最终片采集失败'
OVERSIZED_FINAL_REPORT="$(result_value "$OVERSIZED_FINAL_OUT" internal_report)"
assert_contains "$OVERSIZED_FINAL_REPORT" 'oversized_fragment_continuation=true'
assert_contains "$OVERSIZED_FINAL_REPORT" 'oversized-final-marker'
assert_not_contains "$OVERSIZED_FINAL_REPORT" 'leading_partial_line_omitted=true'
assert_contains "$CURSOR" 'completed_until_epoch=200292'
pass '超长无换行日志跨多轮按有界片段输出，最终尾段遇到换行也不丢失'

CURSOR_BEFORE="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
rm -f "$STACK_HOME/logs/dbdog-mcp.log"
ln -s "$STACK_HOME/logs/dbdog-server.log" "$STACK_HOME/logs/dbdog-mcp.log"
INCOMPLETE_OUT="$TEST_ROOT/incomplete.out"
if run_stack 200300 "$INCOMPLETE_OUT"; then fail '不安全日志符号链接未使采集不完整'; fi
INCOMPLETE_REPORT="$(result_value "$INCOMPLETE_OUT" internal_report)"
assert_contains "$INCOMPLETE_REPORT" 'state=unavailable_or_unsafe'
assert_contains "$INCOMPLETE_REPORT" 'collection_complete=false'
assert_contains "$INCOMPLETE_OUT" '增量游标保持不变'
CURSOR_AFTER="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CURSOR" | awk '{print $1}'; else shasum -a 256 "$CURSOR" | awk '{print $1}'; fi)"
[ "$CURSOR_BEFORE" = "$CURSOR_AFTER" ] || fail '失败采集推进了 cursor'
assert_contains "$CURSOR" 'completed_until_epoch=200292'
pass '证据读取失败仍落报告但不推进游标'

rm -f "$STACK_HOME/logs/dbdog-mcp.log"
printf 'recovered\n' >"$STACK_HOME/logs/dbdog-mcp.log"
mkdir "$DIAG_DIR/.collect-diagnostics.lock"
LOCK_OUT="$TEST_ROOT/lock.out"
if run_stack 200400 "$LOCK_OUT"; then fail '并发锁未 fail closed'; fi
assert_contains "$LOCK_OUT" '已有诊断采集正在运行'
assert_contains "$CURSOR" 'completed_until_epoch=200292'
rmdir "$DIAG_DIR/.collect-diagnostics.lock"
pass '并发采集 fail closed 且不碰游标'

printf '%s\n' '10.44.136.163 SELECT secret_table' \
  >"$STACK_HOME/modules/dbdog-web/dbdog-web-1.2.3/.dbdog-manifest-version"
MARKER_OUT="$TEST_ROOT/marker.out"
env PATH="$FAKE_BIN:$PATH" \
  DBDOG_HOME="$STACK_HOME" \
  DBDOG_DIAGNOSTICS_DIR="$TEST_ROOT/marker-diagnostics" \
  DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
  DBDOG_DIAGNOSTIC_NOW_EPOCH=200500 \
  REAL_DD="$REAL_DD" \
  MANIFEST="$MANIFEST_FIXTURE" \
  DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$COLLECTOR" >"$MARKER_OUT" 2>&1 || fail '损坏 marker 场景采集失败'
MARKER_ISSUE="$(result_value "$MARKER_OUT" issue_card)"
assert_contains "$MARKER_ISSUE" 'module_version.dbdog-web.installed=different_sha256_'
assert_not_contains "$MARKER_ISSUE" '10.44.136.163'
assert_not_contains "$MARKER_ISSUE" 'SELECT'
assert_not_contains "$MARKER_ISSUE" 'secret_table'
pass 'issue-card 对不可信版本 marker 只输出差异哈希，不泄露主机/IP/SQL 字面'

AGENT_HOME="$TEST_ROOT/agent-home"
AGENT_RUNTIME="$TEST_ROOT/agent-runtime"
AGENT_CONFIG="$TEST_ROOT/agent-config"
AGENT_LOG="$TEST_ROOT/agent-log"
AGENT_DIAG="$TEST_ROOT/agent-diagnostics"
TRACE="$TEST_ROOT/agent-window.tsv"
mkdir -p "$AGENT_HOME" "$AGENT_RUNTIME/bin/agent" "$AGENT_CONFIG" "$AGENT_LOG"
cat >"$AGENT_RUNTIME/bin/agent/agent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TEST_ROOT/fake-dbdogctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${AGENT_DIAGNOSTIC_SINCE_EPOCH:?}" \
  "${AGENT_DIAGNOSTIC_UNTIL_EPOCH:?}" >"${FAKE_AGENT_WINDOW_TRACE:?}"
processed="${FAKE_AGENT_PROCESSED_UNTIL:-$AGENT_DIAGNOSTIC_UNTIL_EPOCH}"
window_complete="${FAKE_AGENT_WINDOW_COMPLETE:-true}"
evidence_complete="${FAKE_AGENT_EVIDENCE_COMPLETE:-true}"
healthy="${FAKE_AGENT_HEALTHY:-true}"
printf '%s\n' \
  'schema=dbdog-agent-diagnostic-result/v1' \
  "requested_from_epoch=$AGENT_DIAGNOSTIC_SINCE_EPOCH" \
  "requested_until_epoch=$AGENT_DIAGNOSTIC_UNTIL_EPOCH" \
  "processed_until_epoch=$processed" \
  "window_complete=$window_complete" \
  "evidence_complete=$evidence_complete" \
  "healthy=$healthy" >"${AGENT_DIAGNOSTIC_RESULT_FILE:?}"
if [ "${FAKE_AGENT_RESULT_DUPLICATE:-0}" -eq 1 ]; then
  printf 'healthy=true\n' >>"$AGENT_DIAGNOSTIC_RESULT_FILE"
fi
# stdout 中故意放入看似可信的汇总；collector 必须只信上面的私有机器结果文件。
printf '%s\n' \
  'dbdog-agent diagnostic' \
  'healthy=true' \
  'diagnostic_complete=true' \
  'password=agent-diagnostic-secret'
[ "$healthy" = true ] || exit 1
[ "$evidence_complete" = true ] || exit 2
EOF
chmod 0755 "$AGENT_RUNTIME/bin/agent/agent" "$TEST_ROOT/fake-dbdogctl"
for log in agent.log trace-agent.log process-agent.log system-probe.log; do
  printf 'agent-%s password=agent-log-secret\n' "$log" >"$AGENT_LOG/$log"
done
AGENT_OUT="$TEST_ROOT/agent.out"
env PATH="$FAKE_BIN:$PATH" \
  DBDOG_HOME="$AGENT_HOME" \
  DBDOG_DIAGNOSTICS_DIR="$AGENT_DIAG" \
  DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
  DBDOG_DIAGNOSTIC_NOW_EPOCH=300000 \
  DBDOG_DIAGNOSTIC_DBDOGCTL="$TEST_ROOT/fake-dbdogctl" \
  FAKE_AGENT_WINDOW_TRACE="$TRACE" \
  REAL_DD="$REAL_DD" \
  AGENT_RUNTIME_DIR="$AGENT_RUNTIME" \
  AGENT_CONFIG_DIR="$AGENT_CONFIG" \
  AGENT_LOG_DIR="$AGENT_LOG" \
  MANIFEST="$MANIFEST_FIXTURE" \
  DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$COLLECTOR" >"$AGENT_OUT" 2>&1 && AGENT_RC=0 || AGENT_RC=$?
AGENT_REPORT="$(result_value "$AGENT_OUT" internal_report)"
assert_contains "$AGENT_REPORT" 'host_role=agent'
assert_contains "$AGENT_REPORT" 'agent_coverage=core,trace,process,system-probe'
assert_contains "$AGENT_REPORT" 'privilege=root_required_for_complete_journal_and_coredump_evidence'
assert_contains "$AGENT_REPORT" 'agent_machine_result_valid=true'
assert_contains "$AGENT_REPORT" 'agent_evidence_complete=true'
assert_contains "$AGENT_REPORT" 'agent_window_complete=true'
assert_contains "$AGENT_REPORT" 'agent_processed_until_epoch=300000'
assert_not_contains "$AGENT_REPORT" 'agent-diagnostic-secret'
assert_not_contains "$AGENT_REPORT" 'agent-log-secret'
grep -Fqx $'213600\t300000' "$TRACE" || fail 'Agent diagnose 未收到冻结的增量窗口'
if [ "$EUID" -eq 0 ]; then
  [ "$AGENT_RC" -eq 0 ] || fail 'root Agent 角色完整采集失败'
  assert_contains "$AGENT_DIAG/collect-diagnostics.cursor" 'completed_until_epoch=300000'
else
  [ "$AGENT_RC" -eq 2 ] || fail '非 root Agent 角色没有 fail closed'
  [ ! -e "$AGENT_DIAG/collect-diagnostics.cursor" ] || fail '非 root Agent 采集错误推进了 cursor'
fi
pass 'Agent 角色复用 diagnose 和机器结果，并对非 root journal 可见性 fail closed'

POLLUTED_OUT="$TEST_ROOT/agent-polluted.out"
env PATH="$FAKE_BIN:$PATH" \
  DBDOG_HOME="$AGENT_HOME" \
  DBDOG_DIAGNOSTICS_DIR="$TEST_ROOT/agent-polluted-diagnostics" \
  DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
  DBDOG_DIAGNOSTIC_NOW_EPOCH=300100 \
  DBDOG_DIAGNOSTIC_DBDOGCTL="$TEST_ROOT/fake-dbdogctl" \
  FAKE_AGENT_WINDOW_TRACE="$TRACE" \
  FAKE_AGENT_HEALTHY=false \
  REAL_DD="$REAL_DD" \
  AGENT_RUNTIME_DIR="$AGENT_RUNTIME" \
  AGENT_CONFIG_DIR="$AGENT_CONFIG" \
  AGENT_LOG_DIR="$AGENT_LOG" \
  MANIFEST="$MANIFEST_FIXTURE" \
  DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$COLLECTOR" >"$POLLUTED_OUT" 2>&1 && POLLUTED_RC=0 || POLLUTED_RC=$?
POLLUTED_REPORT="$(result_value "$POLLUTED_OUT" internal_report)"
assert_contains "$POLLUTED_REPORT" 'agent_machine_result_valid=true'
assert_contains "$POLLUTED_REPORT" 'agent_healthy=false'
assert_contains "$POLLUTED_REPORT" 'overall_healthy=false'
case "$POLLUTED_RC" in 0 | 2) ;; *) fail '机器结果为 unhealthy 时 collector 返回码异常' ;; esac
pass '原始日志中的伪 healthy=true 不能污染机器结果判定'

INVALID_RESULT_OUT="$TEST_ROOT/agent-invalid-result.out"
env PATH="$FAKE_BIN:$PATH" \
  DBDOG_HOME="$AGENT_HOME" \
  DBDOG_DIAGNOSTICS_DIR="$TEST_ROOT/agent-invalid-result-diagnostics" \
  DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
  DBDOG_DIAGNOSTIC_NOW_EPOCH=300200 \
  DBDOG_DIAGNOSTIC_DBDOGCTL="$TEST_ROOT/fake-dbdogctl" \
  FAKE_AGENT_WINDOW_TRACE="$TRACE" \
  FAKE_AGENT_RESULT_DUPLICATE=1 \
  REAL_DD="$REAL_DD" \
  AGENT_RUNTIME_DIR="$AGENT_RUNTIME" \
  AGENT_CONFIG_DIR="$AGENT_CONFIG" \
  AGENT_LOG_DIR="$AGENT_LOG" \
  MANIFEST="$MANIFEST_FIXTURE" \
  DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$COLLECTOR" >"$INVALID_RESULT_OUT" 2>&1 && \
    fail '重复 machine-result 字段没有 fail closed' || INVALID_RESULT_RC=$?
[ "$INVALID_RESULT_RC" -eq 2 ] || fail '非法 machine-result 没有返回证据不完整'
INVALID_RESULT_REPORT="$(result_value "$INVALID_RESULT_OUT" internal_report)"
assert_contains "$INVALID_RESULT_REPORT" 'agent_machine_result_valid=false'
[ ! -e "$TEST_ROOT/agent-invalid-result-diagnostics/collect-diagnostics.cursor" ] || \
  fail '非法 machine-result 错误推进了 cursor'
pass '机器结果字段缺失、重复或不一致时不信任 stdout 且不推进游标'

COMBINED_OUT="$TEST_ROOT/combined.out"
env PATH="$FAKE_BIN:$PATH" \
  DBDOG_HOME="$STACK_HOME" \
  DBDOG_DIAGNOSTICS_DIR="$TEST_ROOT/combined-diagnostics" \
  DBDOG_DIAGNOSTIC_PROC_ROOT="$PROC_FIXTURE" \
  DBDOG_DIAGNOSTIC_NOW_EPOCH=400000 \
  DBDOG_DIAGNOSTIC_DBDOGCTL="$TEST_ROOT/fake-dbdogctl" \
  FAKE_AGENT_WINDOW_TRACE="$TRACE" \
  REAL_DD="$REAL_DD" \
  AGENT_RUNTIME_DIR="$AGENT_RUNTIME" \
  AGENT_CONFIG_DIR="$AGENT_CONFIG" \
  AGENT_LOG_DIR="$AGENT_LOG" \
  MANIFEST="$MANIFEST_FIXTURE" \
  DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$COLLECTOR" >"$COMBINED_OUT" 2>&1 && COMBINED_RC=0 || COMBINED_RC=$?
COMBINED_REPORT="$(result_value "$COMBINED_OUT" internal_report)"
assert_contains "$COMBINED_REPORT" 'host_role=stack+agent'
if [ "$EUID" -eq 0 ]; then
  [ "$COMBINED_RC" -eq 0 ] || fail 'root 组合角色采集失败'
else
  [ "$COMBINED_RC" -eq 2 ] || fail '非 root 组合角色没有 fail closed'
fi
pass '同机 stack+agent 角色自动合并，不遗漏任一模块族'

printf 'ALL PASS: %s diagnostics collector contract groups\n' "$PASS_COUNT"
