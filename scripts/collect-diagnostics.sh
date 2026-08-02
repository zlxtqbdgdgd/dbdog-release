#!/usr/bin/env bash
# 手工触发的 dbdog 全机诊断：自动识别 stack/agent，增量读取日志并原子保存游标。

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/agent-lib.sh"

usage() {
  cat <<'EOF'
用法: collect-diagnostics.sh

自动识别本机安装的 dbdog stack/Agent，生成：
  *.internal.txt   仅限内网分析的脱敏诊断报告（仍可能含主机/IP/SQL 业务字面）
  *.issue-card.txt 不含原始日志、主机名、IP 或 SQL 的安全提单摘要

Agent 主机建议用 sudo 执行，否则 journal/coredump 证据可能不完整，游标不会推进。
本命令不安装定时任务，也不读取或输出 env/YAML 原文。
EOF
}

case "${1:-}" in
  "") ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

DIAGNOSTICS_DIR="${DBDOG_DIAGNOSTICS_DIR:-$DBDOG_HOME/diagnostics}"
DBDOGCTL_PATH="${DBDOG_DIAGNOSTIC_DBDOGCTL:-$SCRIPT_DIR/dbdogctl}"
FIRST_LOOKBACK_SECONDS="${DBDOG_DIAGNOSTIC_FIRST_LOOKBACK_SECONDS:-86400}"
MAX_LOG_BYTES="${DBDOG_DIAGNOSTIC_MAX_LOG_BYTES:-1048576}"
PROC_ROOT="${DBDOG_DIAGNOSTIC_PROC_ROOT:-/proc}"
CURSOR_FILE="$DIAGNOSTICS_DIR/collect-diagnostics.cursor"
LOCK_DIR="$DIAGNOSTICS_DIR/.collect-diagnostics.lock"
WORK_DIR=""
REPORT_TMP=""
ISSUE_TMP=""
LOCK_HELD=0

for positive in "$FIRST_LOOKBACK_SECONDS" "$MAX_LOG_BYTES"; do
  case "$positive" in '' | 0 | *[!0-9]*) die "诊断回看/日志字节上限必须是正整数" ;; esac
done
case "$PROC_ROOT" in /*) ;; *) die "诊断 proc 根路径必须是绝对路径" ;; esac
[ -d "$PROC_ROOT" ] && [ ! -L "$PROC_ROOT" ] || \
  die "诊断 proc 根路径必须是实体目录且不能是符号链接: $PROC_ROOT"

# shellcheck disable=SC2329 # 由 EXIT/INT/TERM/HUP trap 间接调用。
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$WORK_DIR" ]; then
    case "$WORK_DIR" in
      "$DIAGNOSTICS_DIR"/.collect-work.*) rm -rf -- "$WORK_DIR" ;;
      *) warn "拒绝清理非诊断临时目录: $WORK_DIR" ;;
    esac
  fi
  if [ -n "$REPORT_TMP" ]; then
    case "$REPORT_TMP" in "$DIAGNOSTICS_DIR"/.report.*.tmp) rm -f -- "$REPORT_TMP" ;; esac
  fi
  if [ -n "$ISSUE_TMP" ]; then
    case "$ISSUE_TMP" in "$DIAGNOSTICS_DIR"/.issue-card.*.tmp) rm -f -- "$ISSUE_TMP" ;; esac
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

if [ -e "$DIAGNOSTICS_DIR" ] || [ -L "$DIAGNOSTICS_DIR" ]; then
  [ -d "$DIAGNOSTICS_DIR" ] && [ ! -L "$DIAGNOSTICS_DIR" ] || \
    die "诊断目录必须是实体目录且不能是符号链接: $DIAGNOSTICS_DIR"
else
  mkdir -p -- "$DIAGNOSTICS_DIR"
fi
chmod 0700 "$DIAGNOSTICS_DIR"
if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
  die "已有诊断采集正在运行，或上次异常退出遗留锁: $LOCK_DIR"
fi
LOCK_HELD=1
chmod 0700 "$LOCK_DIR"

WORK_DIR="$(mktemp -d "$DIAGNOSTICS_DIR/.collect-work.XXXXXX")"
chmod 0700 "$WORK_DIR"
RUN_ID="${WORK_DIR##*.}"
case "$RUN_ID" in '' | *[!A-Za-z0-9]*) die "mktemp 返回了非法诊断 run id" ;; esac
RAW_REPORT="$WORK_DIR/report.raw"
REPORT_TMP="$DIAGNOSTICS_DIR/.report.$RUN_ID.tmp"
ISSUE_TMP="$DIAGNOSTICS_DIR/.issue-card.$RUN_ID.tmp"
NEW_CURSOR="$WORK_DIR/cursor.new"
LOG_SNAPSHOT="$WORK_DIR/log-snapshot.tsv"
ROTATION_SNAPSHOT="$WORK_DIR/log-rotation-snapshot.tsv"
MODULE_SUMMARY="$WORK_DIR/module-summary.tsv"
: >"$RAW_REPORT"
: >"$LOG_SNAPSHOT"
: >"$ROTATION_SNAPSHOT"
: >"$MODULE_SUMMARY"
chmod 0600 "$RAW_REPORT" "$LOG_SNAPSHOT" "$ROTATION_SNAPSHOT" "$MODULE_SUMMARY"

now_epoch() {
  if [ -n "${DBDOG_DIAGNOSTIC_NOW_EPOCH:-}" ]; then
    case "$DBDOG_DIAGNOSTIC_NOW_EPOCH" in *[!0-9]* | "") return 1 ;; esac
    printf '%s\n' "$DBDOG_DIAGNOSTIC_NOW_EPOCH"
  else
    date +%s
  fi
}

epoch_iso() {
  local epoch="$1"
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    printf 'epoch:%s\n' "$epoch"
}

file_identity() {
  stat -Lc '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

file_size() {
  stat -Lc '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

file_mtime_key() {
  local file="$1" epoch stamp fraction
  if epoch="$(stat -Lc '%Y' "$file" 2>/dev/null)" && \
     stamp="$(stat -Lc '%y' "$file" 2>/dev/null)"; then
    fraction="${stamp#*.}"
    if [ "$fraction" = "$stamp" ]; then
      fraction=000000000
    else
      fraction="${fraction%% *}"
    fi
  else
    epoch="$(stat -f '%m' "$file" 2>/dev/null)" || return 1
    fraction=000000000
  fi
  case "$epoch:$fraction" in *[!0-9:]*) return 1 ;; esac
  [ "${#fraction}" -eq 9 ] || return 1
  printf '%s.%s\n' "$epoch" "$fraction"
}

sha256_file() {
  agent_sha256_file "$1"
}

section() {
  printf '\n===== %s =====\n' "$1" >>"$RAW_REPORT"
}

release_identity() {
  local payload="$WORK_DIR/diagnostic-contract.payload" relative digest
  RELEASE_COMMIT=unavailable
  RELEASE_DIRTY=unknown
  MANIFEST_SHA256=unavailable
  MANIFEST_TRUSTED=false
  DIAGNOSTIC_CONTRACT_SHA256=unavailable
  # shellcheck disable=SC2153 # RELEASE_DIR 由 source 的 lib.sh 提供。
  if command -v git >/dev/null 2>&1 && git -C "$RELEASE_DIR" rev-parse --is-inside-work-tree \
      >/dev/null 2>&1; then
    RELEASE_COMMIT="$(git -C "$RELEASE_DIR" rev-parse HEAD 2>/dev/null || true)"
    if git -C "$RELEASE_DIR" diff --quiet --ignore-submodules -- && \
       git -C "$RELEASE_DIR" diff --cached --quiet --ignore-submodules -- && \
       [ -z "$(git -C "$RELEASE_DIR" ls-files --others --exclude-standard | sed -n '1p')" ]; then
      RELEASE_DIRTY=false
    else
      RELEASE_DIRTY=true
    fi
    if [ "$MANIFEST" = "$RELEASE_DIR/manifest.tsv" ] && \
       git -C "$RELEASE_DIR" ls-files --error-unmatch manifest.tsv >/dev/null 2>&1 && \
       git -C "$RELEASE_DIR" diff --quiet -- manifest.tsv && \
       git -C "$RELEASE_DIR" diff --cached --quiet -- manifest.tsv; then
      MANIFEST_TRUSTED=true
    fi
  fi
  if [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] && [ -r "$MANIFEST" ]; then
    MANIFEST_SHA256="$(sha256_file "$MANIFEST" 2>/dev/null || printf unavailable)"
  fi
  : >"$payload"
  for relative in scripts/collect-diagnostics.sh scripts/dbdogctl scripts/agent-lib.sh \
    docs/internal-ai-diagnostics.md; do
    if [ ! -f "$RELEASE_DIR/$relative" ] || [ -L "$RELEASE_DIR/$relative" ] || \
       [ ! -r "$RELEASE_DIR/$relative" ]; then
      : >"$payload"
      return
    fi
    digest="$(sha256_file "$RELEASE_DIR/$relative")" || { : >"$payload"; return; }
    printf '%s:%s\n' "$relative" "$digest" >>"$payload"
  done
  DIAGNOSTIC_CONTRACT_SHA256="$(sha256_file "$payload" 2>/dev/null || printf unavailable)"
}

release_identity

STACK_ROLE=0
AGENT_ROLE=0
for role_module in postgresql clickhouse dbdog-server dbdog-web dbdog-mcp; do
  if [ -e "$MODULES_DIR/$role_module/current" ] || [ -L "$MODULES_DIR/$role_module/current" ]; then
    STACK_ROLE=1
    break
  fi
done
if [ -x "$AGENT_RUNTIME_DIR/bin/agent/agent" ] || \
   [ -e "$AGENT_RUNTIME_DIR/.dbdog-release-version" ] || \
   [ -d "$AGENT_CONFIG_DIR" ]; then
  AGENT_ROLE=1
fi
case "$STACK_ROLE:$AGENT_ROLE" in
  1:1) HOST_ROLE=stack+agent ;;
  1:0) HOST_ROLE=stack ;;
  0:1) HOST_ROLE=agent ;;
  *) HOST_ROLE=none ;;
esac

SCAN_UNTIL_EPOCH="$(now_epoch)" || die "无法取得诊断开始时间"
case "$SCAN_UNTIL_EPOCH" in '' | *[!0-9]*) die "诊断开始时间不是 Unix 秒整数" ;; esac
CURSOR_STATUS=first_run
CURSOR_VALID=0
LAST_COMPLETED_EPOCH=""
if [ -e "$CURSOR_FILE" ] || [ -L "$CURSOR_FILE" ]; then
  if [ -f "$CURSOR_FILE" ] && [ ! -L "$CURSOR_FILE" ] && [ -r "$CURSOR_FILE" ] && \
     [ "$(awk -F= '$1 == "schema" { print $2; exit }' "$CURSOR_FILE")" = \
       'dbdog-diagnostics-cursor/v2' ]; then
    LAST_COMPLETED_EPOCH="$(awk -F= '$1 == "completed_until_epoch" { print $2; exit }' \
      "$CURSOR_FILE")"
    case "$LAST_COMPLETED_EPOCH" in
      '' | *[!0-9]*) CURSOR_STATUS=invalid_fallback ;;
      *)
        if [ "$LAST_COMPLETED_EPOCH" -le "$SCAN_UNTIL_EPOCH" ]; then
          CURSOR_VALID=1
          CURSOR_STATUS=incremental
        else
          CURSOR_STATUS=future_cursor_fallback
        fi
        ;;
    esac
  else
    CURSOR_STATUS=invalid_fallback
  fi
fi
if [ "$CURSOR_VALID" -eq 1 ]; then
  SCAN_FROM_EPOCH="$LAST_COMPLETED_EPOCH"
else
  if [ "$SCAN_UNTIL_EPOCH" -gt "$FIRST_LOOKBACK_SECONDS" ]; then
    SCAN_FROM_EPOCH=$((SCAN_UNTIL_EPOCH - FIRST_LOOKBACK_SECONDS))
  else
    SCAN_FROM_EPOCH=0
  fi
fi

snapshot_rotation_candidates() { # <稳定 id> <当前日志路径>
  local id="$1" path="$2" candidate identity size mtime_key
  local -a candidates=()
  shopt -s nullglob
  candidates=("$path".* "$path"-*)
  shopt -u nullglob
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    case "$candidate" in *$'\t'* | *$'\n'* | *$'\r'*) continue ;; esac
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -r "$candidate" ] || continue
    identity="$(file_identity "$candidate" 2>/dev/null || true)"
    size="$(file_size "$candidate" 2>/dev/null || true)"
    mtime_key="$(file_mtime_key "$candidate" 2>/dev/null || true)"
    case "$identity:$size:$mtime_key" in *[!0-9:.]*) continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$candidate" "$identity" "$size" "$mtime_key" \
      >>"$ROTATION_SNAPSHOT"
  done
}

snapshot_log() { # <稳定 id> <路径>
  local id="$1" path="$2" identity size state
  case "$id:$path" in *$'\t'* | *$'\n'* | *$'\r'*) die "日志 id/path 含非法控制字符" ;; esac
  snapshot_rotation_candidates "$id" "$path"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\t%s\tmissing\t-\t0\n' "$id" "$path" >>"$LOG_SNAPSHOT"
    return
  fi
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ]; then
    printf '%s\t%s\tunavailable\t-\t0\n' "$id" "$path" >>"$LOG_SNAPSHOT"
    return
  fi
  if identity="$(file_identity "$path")" && size="$(file_size "$path")"; then
    case "$identity:$size" in *[!0-9:]*) state=unavailable ;; *) state=ready ;; esac
  else
    state=unavailable
    identity=-
    size=0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$path" "$state" "$identity" "$size" \
    >>"$LOG_SNAPSHOT"
}

# 普通日志的 inode/size 上界与 journal 的 until 一样，都在采集开始时冻结。
if [ "$STACK_ROLE" -eq 1 ]; then
  # shellcheck disable=SC2153 # LOGS_DIR 由 source 的 lib.sh 提供。
  snapshot_log stack.postgresql "$LOGS_DIR/postgresql.log"
  snapshot_log stack.clickhouse "$LOGS_DIR/clickhouse.log"
  snapshot_log stack.clickhouse_error "$LOGS_DIR/clickhouse.err.log"
  snapshot_log stack.server "$LOGS_DIR/dbdog-server.log"
  snapshot_log stack.ddsql "$LOGS_DIR/ddsql-server.log"
  snapshot_log stack.web "$LOGS_DIR/dbdog-web.log"
  snapshot_log stack.mcp "$LOGS_DIR/dbdog-mcp.log"
fi
if [ "$AGENT_ROLE" -eq 1 ]; then
  snapshot_log agent.core "$AGENT_LOG_DIR/agent.log"
  snapshot_log agent.trace "$AGENT_LOG_DIR/trace-agent.log"
  snapshot_log agent.process "$AGENT_LOG_DIR/process-agent.log"
  snapshot_log agent.sysprobe "$AGENT_LOG_DIR/system-probe.log"
fi

COLLECTION_COMPLETE=1
STACK_HEALTHY=not_applicable
AGENT_HEALTHY=not_applicable
STACK_RUNNING_COUNT=0
STACK_PROBE_OK_COUNT=0
LOG_FILES_SCANNED=0
LOG_BYTES_SCANNED=0
LOG_ROTATIONS=0
LOG_TRUNCATIONS=0
ERROR_GAUSS_XID32=0
ERROR_GAUSS_REPLAY_RECORD=0
ERROR_GAUSS_QUERY_SCOPE=0
ERROR_SYSPROBE_64K=0
ERROR_POSTGRES_CONNECT=0
ERROR_PANIC=0
ERROR_OOM=0
COMPLETED_UNTIL_EPOCH="$SCAN_UNTIL_EPOCH"
AGENT_PROCESSED_UNTIL_EPOCH=not_applicable
AGENT_WINDOW_COMPLETE=not_applicable
AGENT_BACKLOG_PENDING=not_applicable
AGENT_EVIDENCE_COMPLETE=not_applicable

cat >>"$RAW_REPORT" <<EOF
schema=dbdog-diagnostics/v1
internal_only=true
external_sharing=forbidden_use_issue_card_after_manual_review
generated_at=$(epoch_iso "$SCAN_UNTIL_EPOCH")
scan_from=$(epoch_iso "$SCAN_FROM_EPOCH")
scan_until=$(epoch_iso "$SCAN_UNTIL_EPOCH")
scan_from_epoch=$SCAN_FROM_EPOCH
scan_until_epoch=$SCAN_UNTIL_EPOCH
host_role=$HOST_ROLE
stack_coverage=postgresql,clickhouse,dbdog-server,ddsql-server,dbdog-web,dbdog-mcp
agent_coverage=core,trace,process,system-probe
profiling_coverage=profiling_has_no_independent_process_and_is_covered_by_agent_core_trace_and_backend_evidence
cursor_status=$CURSOR_STATUS
first_journal_lookback_seconds=$FIRST_LOOKBACK_SECONDS
plain_log_max_bytes_per_file_per_run=$MAX_LOG_BYTES
health_semantics=healthy_is_current_probe_state
completeness_semantics=collection_complete_means_all_applicable_evidence_collectors_finished
finding_semantics=historical_log_evidence_does_not_alone_prove_current_failure
privacy_notice=credential_patterns_are_redacted_but_hostname_ip_database_schema_table_and_sql_literals_may_remain
release_checkout_commit=$RELEASE_COMMIT
release_checkout_dirty=$RELEASE_DIRTY
manifest_sha256=$MANIFEST_SHA256
manifest_identity_trusted=$MANIFEST_TRUSTED
diagnostic_contract_sha256=$DIAGNOSTIC_CONTRACT_SHA256
EOF

if [ "$HOST_ROLE" = none ]; then
  section "role detection"
  printf 'no installed stack or Agent role detected\n' >>"$RAW_REPORT"
  COLLECTION_COMPLETE=0
fi

collect_modules() {
  local rows="$WORK_DIR/manifest-rows.tsv" module target desired installed installed_sha
  local manifest_artifact manifest_arch selected_host_arch
  section "stack module identity"
  if ! selected_host_arch="$(host_arch)"; then
    printf 'manifest_status=unavailable\n' >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  if ! manifest_selected_rows "" "$selected_host_arch" >"$rows"; then
    printf 'manifest_status=unavailable\n' >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  while IFS=$'\t' read -r module _kind target _service desired manifest_artifact _sha _source manifest_arch; do
    [ -n "$module" ] || continue
    [ "$target" = stack ] || continue
    case "$module" in
      node | goose | postgresql | clickhouse | dbdog-server | dbdog-web | dbdog-mcp) ;;
      *)
        printf 'module=invalid manifest_entry_rejected=true\n' >>"$RAW_REPORT"
        COLLECTION_COMPLETE=0
        continue
        ;;
    esac
    installed="$(installed_version "$module")"
    installed_sha="$(installed_artifact_sha256 "$module")"
    printf 'module=%s desired_version=%s installed_version=%s installed_artifact_sha256=%s host_arch=%s manifest_arch=%s artifact=%s\n' \
      "$module" "$desired" "$installed" "$installed_sha" \
      "$selected_host_arch" "$manifest_arch" "$manifest_artifact" >>"$RAW_REPORT"
    printf '%s\t%s\t%s\n' "$module" "$desired" "$installed" >>"$MODULE_SUMMARY"
  done <"$rows"
}

stack_pid() {
  local svc="$1" pid_file pid
  case "$svc" in
    postgresql) pid_file="$DATA_DIR/pg/postmaster.pid" ;;
    *) pid_file="$RUN_DIR/$svc.pid" ;;
  esac
  [ -f "$pid_file" ] && [ ! -L "$pid_file" ] && IFS= read -r pid <"$pid_file" || return 1
  case "$pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "$PROC_ROOT/$pid/stat" ]; then
    local process_stat state
    process_stat="$(<"$PROC_ROOT/$pid/stat")"
    process_stat="${process_stat##*) }"
    state="${process_stat%% *}"
    case "$state" in Z*) return 1 ;; esac
  fi
  printf '%s\n' "$pid"
}

collect_stack_processes() {
  local svc pid name state threads rss
  section "stack service processes"
  for svc in postgresql clickhouse dbdog-server ddsql-server dbdog-web dbdog-mcp; do
    if pid="$(stack_pid "$svc")"; then
      STACK_RUNNING_COUNT=$((STACK_RUNNING_COUNT + 1))
      name=unavailable; state=unavailable; threads=unavailable; rss=unavailable
      if [ -r "$PROC_ROOT/$pid/status" ]; then
        name="$(awk '$1 == "Name:" { print $2; exit }' "$PROC_ROOT/$pid/status")"
        state="$(awk '$1 == "State:" { print $2; exit }' "$PROC_ROOT/$pid/status")"
        threads="$(awk '$1 == "Threads:" { print $2; exit }' "$PROC_ROOT/$pid/status")"
        rss="$(awk '$1 == "VmRSS:" { print $2; exit }' "$PROC_ROOT/$pid/status")"
      fi
      printf 'service=%s running=true pid=%s process_name=%s state=%s threads=%s rss_kib=%s\n' \
        "$svc" "$pid" "${name:-unavailable}" "${state:-unavailable}" \
        "${threads:-unavailable}" "${rss:-unavailable}" >>"$RAW_REPORT"
    else
      printf 'service=%s running=false\n' "$svc" >>"$RAW_REPORT"
    fi
  done
}

run_probe() { # <service> <command...>
  local svc="$1" rc=0 started elapsed raw limited sanitized bytes truncated=false
  local -a probe_status=()
  shift
  started=$SECONDS
  if ! command -v timeout >/dev/null 2>&1; then
    printf 'service=%s probe=unavailable reason=timeout_command_missing\n' "$svc" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  raw="$WORK_DIR/probe-$svc.raw"
  limited="$WORK_DIR/probe-$svc.limited"
  sanitized="$WORK_DIR/probe-$svc.sanitized"
  set +o pipefail
  timeout 6 "$@" 2>&1 | head -c 65537 >"$raw"
  probe_status=("${PIPESTATUS[@]}")
  set -o pipefail
  rc="${probe_status[0]}"
  bytes="$(file_size "$raw" 2>/dev/null || printf 0)"
  if [ "$bytes" -gt 65536 ]; then
    head -c 65536 "$raw" >"$limited"
    mv -- "$limited" "$raw"
    truncated=true
  fi
  elapsed=$((SECONDS - started))
  if [ "$rc" -eq 0 ] && [ "$truncated" = false ]; then
    STACK_PROBE_OK_COUNT=$((STACK_PROBE_OK_COUNT + 1))
    printf 'service=%s probe_ok=true duration_seconds=%s\n' "$svc" "$elapsed" >>"$RAW_REPORT"
  else
    printf 'service=%s probe_ok=false exit_code=%s duration_seconds=%s output_truncated=%s\n' \
      "$svc" "$rc" "$elapsed" "$truncated" >>"$RAW_REPORT"
    LC_ALL=C tr '\000' '?' <"$raw" >"$sanitized"
    printf '%s\n' '[probe_error_begin]' >>"$RAW_REPORT"
    agent_redact_diagnostic_stream <"$sanitized" >>"$RAW_REPORT"
    printf '%s\n' '[probe_error_end]' >>"$RAW_REPORT"
  fi
  rm -f -- "$raw" "$limited" "$sanitized"
}

collect_stack_probes() {
  section "stack lightweight real probes"
  if [ -x "$MODULES_DIR/postgresql/current/bin/pg_isready" ]; then
    run_probe postgresql "$MODULES_DIR/postgresql/current/bin/pg_isready" \
      -h 127.0.0.1 -p 5432 -d postgres -t 2
  else
    printf 'service=postgresql probe_ok=false reason=executable_missing\n' >>"$RAW_REPORT"
  fi
  if [ -x "$MODULES_DIR/clickhouse/current/bin/clickhouse" ]; then
    run_probe clickhouse "$MODULES_DIR/clickhouse/current/bin/clickhouse" client \
      --host 127.0.0.1 --port 9000 --connect_timeout 2 --receive_timeout 2 \
      --query 'SELECT 1'
  else
    printf 'service=clickhouse probe_ok=false reason=executable_missing\n' >>"$RAW_REPORT"
  fi
  if command -v curl >/dev/null 2>&1; then
    run_probe dbdog-server curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
      -o /dev/null http://127.0.0.1:8080/healthz
    run_probe ddsql-server curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
      -o /dev/null http://127.0.0.1:8770/healthz
    run_probe dbdog-web curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
      -o /dev/null http://127.0.0.1:3000/login
    run_probe dbdog-mcp curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
      -o /dev/null http://127.0.0.1:8090/healthz
  else
    printf 'http_probes=unavailable reason=curl_missing\n' >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
  fi
}

collect_resources() {
  local value port listening resource_complete=true
  section "host resources and fixed stack ports"
  if [ -r "$PROC_ROOT/loadavg" ]; then
    value="$(awk '{ print $1 "," $2 "," $3 }' "$PROC_ROOT/loadavg")"
    printf 'load_average_1m_5m_15m=%s\n' "$value" >>"$RAW_REPORT"
  else
    printf 'load_average_1m_5m_15m=unavailable\n' >>"$RAW_REPORT"
    resource_complete=false
  fi
  if [ -r "$PROC_ROOT/meminfo" ]; then
    awk '$1 == "MemTotal:" { print "memory_total_kib=" $2 }
         $1 == "MemAvailable:" { print "memory_available_kib=" $2 }
         $1 == "SwapTotal:" { print "swap_total_kib=" $2 }
         $1 == "SwapFree:" { print "swap_free_kib=" $2 }' "$PROC_ROOT/meminfo" >>"$RAW_REPORT"
  else
    printf 'memory_summary=unavailable\n' >>"$RAW_REPORT"
    resource_complete=false
  fi
  if value="$(df -Pk "$DBDOG_HOME" 2>/dev/null | awk 'NR == 2 { print $2 "," $3 "," $4 "," $5 }')" && \
     [ -n "$value" ]; then
    printf 'dbdog_filesystem_kib_total_used_available_percent=%s\n' "$value" >>"$RAW_REPORT"
  else
    printf 'dbdog_filesystem=unavailable\n' >>"$RAW_REPORT"
    resource_complete=false
  fi
  if command -v ss >/dev/null 2>&1; then
    for port in 5432 8123 9000 8080 8770 3000 8090; do
      if ss -ltn 2>/dev/null | awk -v wanted="$port" '
          NR > 1 {
            address = $4
            sub(/^.*:/, "", address)
            if (address == wanted) found = 1
          }
          END { exit !found }
        '; then
        listening=true
      else
        listening=false
      fi
      printf 'tcp_port=%s listening=%s\n' "$port" "$listening" >>"$RAW_REPORT"
    done
  else
    printf 'tcp_listeners=unavailable reason=ss_missing\n' >>"$RAW_REPORT"
    resource_complete=false
  fi
  printf 'resource_snapshot_complete=%s\n' "$resource_complete" >>"$RAW_REPORT"
  if [ "$resource_complete" != true ]; then COLLECTION_COMPLETE=0; fi
}

copy_file_range() { # <file> <zero-based offset> <count> <destination>
  local file="$1" offset="$2" count="$3" dest="$4"
  local block_size=4096 block_skip prefix total block_count block_file trimmed actual
  block_skip=$((offset / block_size))
  prefix=$((offset % block_size))
  total=$((prefix + count))
  block_count=$(((total + block_size - 1) / block_size))
  block_file="$WORK_DIR/range-block.$$"
  trimmed="$WORK_DIR/range-trimmed.$$"
  if [ "$count" -eq 0 ]; then
    : >"$dest"
    return 0
  fi
  if ! dd if="$file" of="$block_file" bs="$block_size" skip="$block_skip" \
      count="$block_count" 2>/dev/null; then
    return 1
  fi
  if ! tail -c "+$((prefix + 1))" "$block_file" >"$trimmed" 2>/dev/null; then
    return 1
  fi
  if ! head -c "$count" "$trimmed" >"$dest" 2>/dev/null; then
    return 1
  fi
  actual="$(file_size "$dest")" || return 1
  [ "$actual" -eq "$count" ] || return 1
  rm -f -- "$block_file" "$trimmed"
}

cursor_log_record() { # <id>
  local id="$1"
  [ "$CURSOR_VALID" -eq 1 ] || return 1
  awk -F'\t' -v wanted="$id" '$1 == "log" && $2 == wanted { print; exit }' "$CURSOR_FILE"
}

continuity_fingerprint() { # <file> <offset>; 输出到 FP_* globals
  local file="$1" offset="$2" tmp
  FP_GUARD_LEN="$offset"
  [ "$FP_GUARD_LEN" -le 4096 ] || FP_GUARD_LEN=4096
  FP_PREFIX_LEN="$offset"
  [ "$FP_PREFIX_LEN" -le 4096 ] || FP_PREFIX_LEN=4096
  tmp="$WORK_DIR/fingerprint.$$"
  if ! copy_file_range "$file" "$((offset - FP_GUARD_LEN))" "$FP_GUARD_LEN" "$tmp"; then
    return 1
  fi
  FP_GUARD_SHA="$(sha256_file "$tmp")" || return 1
  if ! copy_file_range "$file" 0 "$FP_PREFIX_LEN" "$tmp"; then
    return 1
  fi
  FP_PREFIX_SHA="$(sha256_file "$tmp")" || return 1
  rm -f -- "$tmp"
  case "$FP_GUARD_SHA:$FP_PREFIX_SHA" in *[!0-9a-f:]*) return 1 ;; esac
  [ "${#FP_GUARD_SHA}" -eq 64 ] && [ "${#FP_PREFIX_SHA}" -eq 64 ]
}

continuity_matches() { # <file> <offset> <guard len> <guard sha> <prefix len> <prefix sha>
  local file="$1" offset="$2" guard_len="$3" guard_sha="$4"
  local prefix_len="$5" prefix_sha="$6"
  continuity_fingerprint "$file" "$offset" || return 1
  [ "$FP_GUARD_LEN" -eq "$guard_len" ] && [ "$FP_GUARD_SHA" = "$guard_sha" ] && \
    [ "$FP_PREFIX_LEN" -eq "$prefix_len" ] && [ "$FP_PREFIX_SHA" = "$prefix_sha" ]
}

write_log_cursor() { # <id> <identity> <offset> <source file>
  local id="$1" identity="$2" offset="$3" source="$4" current_identity
  if [ ! -f "$source" ] || [ -L "$source" ] || [ ! -r "$source" ]; then
    return 1
  fi
  current_identity="$(file_identity "$source" 2>/dev/null || true)"
  [ "$current_identity" = "$identity" ] || return 1
  continuity_fingerprint "$source" "$offset" || return 1
  printf 'log\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$identity" "$offset" "$FP_GUARD_LEN" "$FP_GUARD_SHA" \
    "$FP_PREFIX_LEN" "$FP_PREFIX_SHA" >>"$NEW_CURSOR"
}

select_rotation_candidate_by_identity() { # <id> <identity>
  local id="$1" wanted_identity="$2" matches="$WORK_DIR/rotation-matches.$$" count
  awk -F'\t' -v id="$id" -v identity="$wanted_identity" \
    '$1 == id && $3 == identity { print }' "$ROTATION_SNAPSHOT" >"$matches"
  count="$(awk 'END { print NR + 0 }' "$matches")"
  [ "$count" -eq 1 ] || return 1
  IFS=$'\t' read -r _ CANDIDATE_PATH CANDIDATE_IDENTITY CANDIDATE_SIZE \
    CANDIDATE_MTIME_KEY <"$matches"
  rm -f -- "$matches"
}

select_rotation_candidate_by_fingerprint() { # <id> <old cursor continuity fields>
  local id="$1" offset="$2" guard_len="$3" guard_sha="$4"
  local prefix_len="$5" prefix_sha="$6" candidate_id candidate_path candidate_identity
  local candidate_size candidate_mtime matches="$WORK_DIR/rotation-fingerprint-matches.$$" count
  : >"$matches"
  while IFS=$'\t' read -r candidate_id candidate_path candidate_identity candidate_size \
      candidate_mtime; do
    [ "$candidate_id" = "$id" ] || continue
    [ "$candidate_size" -ge "$offset" ] || continue
    [ -f "$candidate_path" ] && [ ! -L "$candidate_path" ] && [ -r "$candidate_path" ] || continue
    [ "$(file_identity "$candidate_path" 2>/dev/null || true)" = "$candidate_identity" ] || continue
    if continuity_matches "$candidate_path" "$offset" \
        "$guard_len" "$guard_sha" "$prefix_len" "$prefix_sha"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$candidate_id" "$candidate_path" \
        "$candidate_identity" "$candidate_size" "$candidate_mtime" >>"$matches"
    fi
  done <"$ROTATION_SNAPSHOT"
  count="$(awk 'END { print NR + 0 }' "$matches")"
  [ "$count" -eq 1 ] || return 1
  IFS=$'\t' read -r _ CANDIDATE_PATH CANDIDATE_IDENTITY CANDIDATE_SIZE \
    CANDIDATE_MTIME_KEY <"$matches"
  rm -f -- "$matches"
}

select_next_rotation_candidate() { # <id> <mtime key>; 0=唯一下一文件, 1=没有, 2=顺序不唯一
  local id="$1" after_key="$2" matches="$WORK_DIR/rotation-next-matches.$$"
  local earliest count
  awk -F'\t' -v id="$id" -v after="$after_key" \
    '$1 == id && $5 > after { print }' "$ROTATION_SNAPSHOT" \
    | LC_ALL=C sort -t $'\t' -k5,5 >"$matches"
  if [ ! -s "$matches" ]; then
    rm -f -- "$matches"
    return 1
  fi
  earliest="$(awk -F'\t' 'NR == 1 { print $5 }' "$matches")"
  count="$(awk -F'\t' -v earliest="$earliest" '$5 == earliest { n++ } END { print n + 0 }' \
    "$matches")"
  if [ "$count" -ne 1 ]; then
    rm -f -- "$matches"
    return 2
  fi
  IFS=$'\t' read -r _ CANDIDATE_PATH CANDIDATE_IDENTITY CANDIDATE_SIZE \
    CANDIDATE_MTIME_KEY <"$matches"
  rm -f -- "$matches"
}

classify_log_chunk() {
  local file="$1" count
  count="$(grep -Eic 'Function age\(xid32\) does not exist' "$file" || true)"
  ERROR_GAUSS_XID32=$((ERROR_GAUSS_XID32 + count))
  count="$(grep -Eic 'operator does not exist:[[:space:]]*text[[:space:]]*=[[:space:]]*record' \
    "$file" || true)"
  ERROR_GAUSS_REPLAY_RECORD=$((ERROR_GAUSS_REPLAY_RECORD + count))
  count="$(grep -Eic 'GaussDB query scope failed:.*category=(undefined-function|programming-error|database-error)([[:space:]]|$)|error:query-scope-(undefined-function|programming-error|database-error)([[:space:],]|$)' \
    "$file" || true)"
  ERROR_GAUSS_QUERY_SCOPE=$((ERROR_GAUSS_QUERY_SCOPE + count))
  count="$(grep -Eic 'index out of range \[65536\] with length 28672|preventSegmentMajorPageFault' \
    "$file" || true)"
  ERROR_SYSPROBE_64K=$((ERROR_SYSPROBE_64K + count))
  count="$(grep -Eic 'Cannot connect to PostgreSQL|connection refused' "$file" || true)"
  ERROR_POSTGRES_CONNECT=$((ERROR_POSTGRES_CONNECT + count))
  count="$(grep -Eic 'panic:|fatal error:' "$file" || true)"
  ERROR_PANIC=$((ERROR_PANIC + count))
  count="$(grep -Eic 'out of memory|oom-kill|killed process' "$file" || true)"
  ERROR_OOM=$((ERROR_OOM + count))
}

emit_log_range() { # <path> <identity> <snapshot size> <start> <limit> <reason> <source>
  local path="$1" identity="$2" snapshot_size="$3" start="$4" limit="$5"
  local reason="$6" source="$7" available count current_identity current_size
  local raw verify complete display last_hex complete_bytes consumed next_offset preceding="" boundary
  local raw_sha verify_sha oversized_fragment=false
  raw="$WORK_DIR/log-raw.$$"
  verify="$WORK_DIR/log-verify.$$"
  complete="$WORK_DIR/log-complete.$$"
  display="$WORK_DIR/log-display.$$"
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ] || \
     ! current_identity="$(file_identity "$path")" || [ "$current_identity" != "$identity" ]; then
    printf 'state=changed_during_collection source=%s expected_identity=%s\n' \
      "$source" "$identity" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  fi
  current_size="$(file_size "$path" 2>/dev/null || true)"
  case "$current_size" in '' | *[!0-9]*) COLLECTION_COMPLETE=0; return 1 ;; esac
  [ "$current_size" -ge "$snapshot_size" ] || {
    printf 'state=truncated_during_collection source=%s snapshot_size=%s current_size=%s\n' \
      "$source" "$snapshot_size" "$current_size" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  }
  available=$((snapshot_size - start))
  count="$available"
  [ "$count" -le "$limit" ] || count="$limit"
  if ! copy_file_range "$path" "$start" "$count" "$raw"; then
    printf 'state=read_failed source=%s start_offset=%s requested_bytes=%s snapshot_size=%s\n' \
      "$source" "$start" "$count" "$snapshot_size" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  fi
  current_identity="$(file_identity "$path" 2>/dev/null || true)"
  if [ "$current_identity" != "$identity" ]; then
    printf 'state=rotated_during_collection source=%s expected_identity=%s\n' \
      "$source" "$identity" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  fi
  if ! copy_file_range "$path" "$start" "$count" "$verify"; then
    printf 'state=verification_read_failed source=%s start_offset=%s requested_bytes=%s\n' \
      "$source" "$start" "$count" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  fi
  raw_sha="$(sha256_file "$raw" 2>/dev/null || true)"
  verify_sha="$(sha256_file "$verify" 2>/dev/null || true)"
  if [ -z "$raw_sha" ] || [ "$raw_sha" != "$verify_sha" ] || \
     [ "$(file_identity "$path" 2>/dev/null || true)" != "$identity" ] || \
     [ "$(file_size "$path" 2>/dev/null || printf 0)" -lt "$snapshot_size" ]; then
    printf 'state=content_changed_during_collection source=%s\n' "$source" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return 1
  fi
  boundary=true
  if [ "$start" -gt 0 ]; then
    preceding="$WORK_DIR/log-preceding.$$"
    if ! copy_file_range "$path" "$((start - 1))" 1 "$preceding"; then
      COLLECTION_COMPLETE=0
      printf 'state=boundary_check_failed source=%s\n' "$source" >>"$RAW_REPORT"
      return 1
    fi
    last_hex="$(od -An -tx1 "$preceding" | tr -d '[:space:]')"
    [ "$last_hex" = 0a ] || boundary=false
  fi
  consumed="$count"
  if [ "$count" -gt 0 ]; then
    last_hex="$(tail -c 1 "$raw" | od -An -tx1 | tr -d '[:space:]')"
    if [ "$last_hex" = 0a ]; then
      cp -- "$raw" "$complete"
    else
      sed '$d' "$raw" >"$complete"
      complete_bytes="$(file_size "$complete")" || {
        COLLECTION_COMPLETE=0
        return 1
      }
      if [ "$complete_bytes" -eq 0 ] && { [ "$count" -eq "$limit" ] || [ "$source" = rotated ]; }; then
        cp -- "$raw" "$complete"
        oversized_fragment=true
        printf 'oversized_unterminated_fragment_included=true sha256=%s terminal_rotated=%s\n' \
          "$raw_sha" "$([ "$source" = rotated ] && printf true || printf false)" >>"$RAW_REPORT"
      else
        consumed="$complete_bytes"
      fi
    fi
  else
    : >"$complete"
  fi
  next_offset=$((start + consumed))
  printf 'state=read source=%s reason=%s identity=%s snapshot_size=%s start_offset=%s next_offset=%s bytes_consumed=%s backlog_bytes=%s\n' \
    "$source" "$reason" "$identity" "$snapshot_size" "$start" "$next_offset" "$consumed" \
    "$((snapshot_size - next_offset))" >>"$RAW_REPORT"
  if [ -s "$complete" ]; then
    if [ "$boundary" = false ] && [ "$oversized_fragment" = false ] && \
       [ "$reason" = first_bounded_tail ]; then
      sed '1d' "$complete" >"$display"
      printf 'leading_partial_line_omitted=true\n' >>"$RAW_REPORT"
    else
      cp -- "$complete" "$display"
    fi
    if [ "$boundary" = false ] && [ "$reason" != first_bounded_tail ]; then
      # 已提交 cursor 只有在上一轮明确输出超长无换行片段时才会停在
      # 非换行边界；后续片段（包括最终遇到换行的尾段）必须继续保留。
      printf 'oversized_fragment_continuation=true\n' >>"$RAW_REPORT"
    fi
    if [ "$oversized_fragment" = true ]; then
      printf 'log_content_is_line_fragment=true\n' >>"$RAW_REPORT"
    fi
    classify_log_chunk "$display"
    {
      printf '%s\n' '[log_content_begin]'
      LC_ALL=C tr '\000' '?' <"$display"
      printf '%s\n' '[log_content_end]'
    } >>"$RAW_REPORT"
  else
    printf 'no_complete_new_log_lines=true\n' >>"$RAW_REPORT"
  fi
  LOG_BYTES_SCANNED=$((LOG_BYTES_SCANNED + consumed))
  RANGE_NEXT_OFFSET="$next_offset"
  RANGE_CONSUMED="$consumed"
  rm -f -- "$raw" "$verify" "$complete" "$display" "${preceding:-}"
}

scan_one_log() { # snapshot fields: id path state identity size
  local id="$1" path="$2" state="$3" identity="$4" snapshot_size="$5"
  local record="" tag record_id old_identity old_offset guard_len guard_sha prefix_len prefix_sha
  local expected_len start=0 reason=first_bounded_tail current_identity remaining
  local recovery_reason candidate_ok=0 next_rc
  printf -- '--- log_id=%s path=%s ---\n' "$id" "$path" >>"$RAW_REPORT"
  record="$(cursor_log_record "$id" 2>/dev/null || true)"
  case "$state" in
    missing)
      printf 'state=missing\n' >>"$RAW_REPORT"
      if [ -n "$record" ]; then COLLECTION_COMPLETE=0; fi
      return
      ;;
    unavailable)
      printf 'state=unavailable_or_unsafe\n' >>"$RAW_REPORT"
      COLLECTION_COMPLETE=0
      return
      ;;
  esac
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ] || \
     ! current_identity="$(file_identity "$path")" || [ "$current_identity" != "$identity" ]; then
    printf 'state=changed_during_collection expected_identity=%s\n' "$identity" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  if [ -n "$record" ]; then
    IFS=$'\t' read -r tag record_id old_identity old_offset guard_len guard_sha \
      prefix_len prefix_sha <<<"$record"
    case "$old_identity:$old_offset:$guard_len:$prefix_len" in
      *[!0-9:]*) printf 'state=cursor_record_invalid\n' >>"$RAW_REPORT"; COLLECTION_COMPLETE=0; return ;;
    esac
    [ "$tag" = log ] && [ "$record_id" = "$id" ] || {
      printf 'state=cursor_record_invalid\n' >>"$RAW_REPORT"
      COLLECTION_COMPLETE=0
      return
    }
    expected_len="$old_offset"; [ "$expected_len" -le 4096 ] || expected_len=4096
    if [ "$guard_len" -ne "$expected_len" ] || [ "$prefix_len" -ne "$expected_len" ] || \
       [ "${#guard_sha}" -ne 64 ] || [ "${#prefix_sha}" -ne 64 ]; then
      printf 'state=cursor_record_invalid\n' >>"$RAW_REPORT"
      COLLECTION_COMPLETE=0
      return
    fi
    case "$guard_sha:$prefix_sha" in
      *[!0-9a-f:]*) printf 'state=cursor_record_invalid\n' >>"$RAW_REPORT"; COLLECTION_COMPLETE=0; return ;;
    esac
    if [ "$old_identity" = "$identity" ] && [ "$old_offset" -le "$snapshot_size" ] && \
       continuity_matches "$path" "$old_offset" \
         "$guard_len" "$guard_sha" "$prefix_len" "$prefix_sha"; then
      start="$old_offset"
      reason=incremental
    else
      if [ "$old_identity" = "$identity" ]; then
        recovery_reason=copytruncate_or_rewrite
        LOG_TRUNCATIONS=$((LOG_TRUNCATIONS + 1))
      else
        recovery_reason=rotated
        LOG_ROTATIONS=$((LOG_ROTATIONS + 1))
      fi
      if [ "$old_identity" != "$identity" ] && \
         select_rotation_candidate_by_identity "$id" "$old_identity" && \
         [ "$CANDIDATE_SIZE" -ge "$old_offset" ] && \
         continuity_matches "$CANDIDATE_PATH" "$old_offset" \
           "$guard_len" "$guard_sha" "$prefix_len" "$prefix_sha"; then
        candidate_ok=1
      elif select_rotation_candidate_by_fingerprint "$id" "$old_offset" \
          "$guard_len" "$guard_sha" "$prefix_len" "$prefix_sha"; then
        candidate_ok=1
      fi
      if [ "$candidate_ok" -ne 1 ]; then
        printf 'state=continuity_gap reason=%s rotation_candidate_found=false\n' \
          "$recovery_reason" >>"$RAW_REPORT"
        COLLECTION_COMPLETE=0
        return
      fi
      printf 'continuity_recovered=true reason=%s rotated_path=%s\n' \
        "$recovery_reason" "$CANDIDATE_PATH" >>"$RAW_REPORT"
      remaining="$MAX_LOG_BYTES"
      while :; do
        if ! emit_log_range "$CANDIDATE_PATH" "$CANDIDATE_IDENTITY" "$CANDIDATE_SIZE" \
            "$old_offset" "$remaining" "$recovery_reason-carryover" rotated; then
          return
        fi
        remaining=$((remaining - RANGE_CONSUMED))
        if [ "$RANGE_NEXT_OFFSET" -lt "$CANDIDATE_SIZE" ] || [ "$remaining" -eq 0 ]; then
          if ! write_log_cursor "$id" "$CANDIDATE_IDENTITY" "$RANGE_NEXT_OFFSET" \
              "$CANDIDATE_PATH"; then
            printf 'state=cursor_fingerprint_failed source=rotated\n' >>"$RAW_REPORT"
            COLLECTION_COMPLETE=0
            return
          fi
          printf 'current_file_deferred_until_rotated_backlog_drained=true\n' >>"$RAW_REPORT"
          LOG_FILES_SCANNED=$((LOG_FILES_SCANNED + 1))
          return
        fi
        if select_next_rotation_candidate "$id" "$CANDIDATE_MTIME_KEY"; then
          old_offset=0
          recovery_reason=multi-rotation
          LOG_ROTATIONS=$((LOG_ROTATIONS + 1))
          printf 'rotation_chain_continues=true next_rotated_path=%s\n' \
            "$CANDIDATE_PATH" >>"$RAW_REPORT"
          continue
        else
          next_rc=$?
        fi
        if [ "$next_rc" -eq 2 ]; then
          printf 'state=rotation_order_ambiguous after_mtime=%s\n' \
            "$CANDIDATE_MTIME_KEY" >>"$RAW_REPORT"
          COLLECTION_COMPLETE=0
          return
        fi
        break
      done
      if ! emit_log_range "$path" "$identity" "$snapshot_size" 0 "$remaining" \
          "$recovery_reason-new-current" current; then
        return
      fi
      if ! write_log_cursor "$id" "$identity" "$RANGE_NEXT_OFFSET" "$path"; then
        printf 'state=cursor_fingerprint_failed source=current\n' >>"$RAW_REPORT"
        COLLECTION_COMPLETE=0
        return
      fi
      LOG_FILES_SCANNED=$((LOG_FILES_SCANNED + 1))
      return
    fi
  elif [ "$snapshot_size" -gt "$MAX_LOG_BYTES" ]; then
    start=$((snapshot_size - MAX_LOG_BYTES))
  fi
  if ! emit_log_range "$path" "$identity" "$snapshot_size" "$start" \
      "$MAX_LOG_BYTES" "$reason" current; then
    return
  fi
  if [ "$reason" = incremental ] && \
     ! continuity_matches "$path" "$start" \
       "$guard_len" "$guard_sha" "$prefix_len" "$prefix_sha"; then
    printf 'state=cursor_boundary_changed_during_collection source=current\n' >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  if ! write_log_cursor "$id" "$identity" "$RANGE_NEXT_OFFSET" "$path"; then
    printf 'state=cursor_fingerprint_failed source=current\n' >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  LOG_FILES_SCANNED=$((LOG_FILES_SCANNED + 1))
}

collect_logs() {
  local id path state identity size
  section "incremental plain logs"
  while IFS=$'\t' read -r id path state identity size; do
    scan_one_log "$id" "$path" "$state" "$identity" "$size"
  done <"$LOG_SNAPSHOT"
}

diagnostic_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

diagnostic_file_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

parse_agent_result_file() { # <machine-result>; populates AGENT_RESULT_* globals
  local file="$1" parsed mode uid
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  mode="$(diagnostic_file_mode "$file")" || return 1
  uid="$(diagnostic_file_uid "$file")" || return 1
  [ "$mode" = 600 ] && [ "$uid" = "$EUID" ] || return 1
  parsed="$(awk '
    BEGIN {
      allowed["schema"] = 1
      allowed["requested_from_epoch"] = 1
      allowed["requested_until_epoch"] = 1
      allowed["processed_until_epoch"] = 1
      allowed["window_complete"] = 1
      allowed["evidence_complete"] = 1
      allowed["healthy"] = 1
    }
    {
      separator = index($0, "=")
      if (separator == 0 || $0 ~ /[[:cntrl:]]/) { bad = 1; next }
      key = substr($0, 1, separator - 1)
      value = substr($0, separator + 1)
      if (!(key in allowed) || ++seen[key] != 1) { bad = 1; next }
      result[key] = value
      count++
    }
    END {
      if (bad || count != 7) exit 1
      for (key in allowed) if (seen[key] != 1) exit 1
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        result["schema"], result["requested_from_epoch"], \
        result["requested_until_epoch"], result["processed_until_epoch"], \
        result["window_complete"], result["evidence_complete"], result["healthy"]
    }
  ' "$file")" || return 1
  IFS=$'\t' read -r AGENT_RESULT_SCHEMA AGENT_RESULT_FROM AGENT_RESULT_UNTIL \
    AGENT_RESULT_PROCESSED AGENT_RESULT_WINDOW_COMPLETE \
    AGENT_RESULT_EVIDENCE_COMPLETE AGENT_RESULT_HEALTHY <<<"$parsed"
  [ "$AGENT_RESULT_SCHEMA" = dbdog-agent-diagnostic-result/v1 ] || return 1
  [ "$AGENT_RESULT_FROM" = "$SCAN_FROM_EPOCH" ] && \
    [ "$AGENT_RESULT_UNTIL" = "$SCAN_UNTIL_EPOCH" ] || return 1
  case "$AGENT_RESULT_PROCESSED" in '' | *[!0-9]*) return 1 ;; esac
  [ "$AGENT_RESULT_PROCESSED" -ge "$SCAN_FROM_EPOCH" ] && \
    [ "$AGENT_RESULT_PROCESSED" -le "$SCAN_UNTIL_EPOCH" ] || return 1
  case "$AGENT_RESULT_WINDOW_COMPLETE:$AGENT_RESULT_EVIDENCE_COMPLETE:$AGENT_RESULT_HEALTHY" in
    true:true:true | true:true:false | true:false:true | true:false:false | \
      false:true:true | false:true:false | false:false:true | false:false:false) ;;
    *) return 1 ;;
  esac
  if [ "$AGENT_RESULT_WINDOW_COMPLETE" = true ]; then
    [ "$AGENT_RESULT_PROCESSED" -eq "$SCAN_UNTIL_EPOCH" ] || return 1
  else
    [ "$AGENT_RESULT_PROCESSED" -lt "$SCAN_UNTIL_EPOCH" ] || return 1
  fi
  if [ "$AGENT_RESULT_EVIDENCE_COMPLETE" = true ]; then
    if [ "$AGENT_RESULT_WINDOW_COMPLETE" = false ]; then
      [ "$AGENT_RESULT_PROCESSED" -gt "$SCAN_FROM_EPOCH" ] || return 1
    fi
  else
    [ "$AGENT_RESULT_PROCESSED" -eq "$SCAN_FROM_EPOCH" ] || return 1
  fi
}

collect_agent() {
  local output="$WORK_DIR/agent-diagnose.raw" result="$WORK_DIR/agent-diagnose.result"
  local rc=0 expected_rc desired version artifact contract
  section "Agent diagnostic"
  desired="$(awk -F'\t' '$1 == "dbdog-agent" { print $5; exit }' "$MANIFEST" 2>/dev/null || true)"
  [ -n "$desired" ] || desired=unavailable
  version="$(agent_marker_value "$AGENT_RUNTIME_DIR/.dbdog-release-version" "$AGENT_RUNTIME_DIR")"
  artifact="$(agent_marker_value "$AGENT_RUNTIME_DIR/.dbdog-artifact-sha256" "$AGENT_RUNTIME_DIR")"
  contract="$(agent_marker_value \
    "$AGENT_RUNTIME_DIR/$AGENT_INSTALLER_CONTRACT_MARKER" "$AGENT_RUNTIME_DIR")"
  printf 'desired_version=%s installed_version=%s artifact_sha256=%s installer_contract_sha256=%s\n' \
    "$desired" "$version" "$artifact" "$contract" >>"$RAW_REPORT"
  printf 'dbdog-agent\t%s\t%s\n' "$desired" "$version" >>"$MODULE_SUMMARY"
  if [ "$EUID" -ne 0 ]; then
    printf 'privilege=root_required_for_complete_journal_and_coredump_evidence current=root_false\n' \
      >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
  else
    printf 'privilege=root_true\n' >>"$RAW_REPORT"
  fi
  if [ ! -x "$DBDOGCTL_PATH" ]; then
    printf 'agent_diagnostic=unavailable dbdogctl=%s\n' "$DBDOGCTL_PATH" >>"$RAW_REPORT"
    AGENT_HEALTHY=false
    COLLECTION_COMPLETE=0
    return
  fi
  : >"$result"
  chmod 0600 "$result"
  if TMPDIR="$WORK_DIR" \
      AGENT_DIAGNOSTIC_SINCE_EPOCH="$SCAN_FROM_EPOCH" \
      AGENT_DIAGNOSTIC_UNTIL_EPOCH="$SCAN_UNTIL_EPOCH" \
      AGENT_DIAGNOSTIC_RESULT_FILE="$result" \
      "$DBDOGCTL_PATH" diagnose dbdog-agent >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf 'dbdogctl_exit_code=%s\n' "$rc" >>"$RAW_REPORT"
  cat "$output" >>"$RAW_REPORT"
  classify_log_chunk "$output"
  if ! parse_agent_result_file "$result"; then
    printf 'agent_machine_result_valid=false\n' >>"$RAW_REPORT"
    AGENT_HEALTHY=unknown
    AGENT_EVIDENCE_COMPLETE=false
    COLLECTION_COMPLETE=0
    return
  fi
  AGENT_HEALTHY="$AGENT_RESULT_HEALTHY"
  AGENT_EVIDENCE_COMPLETE="$AGENT_RESULT_EVIDENCE_COMPLETE"
  AGENT_WINDOW_COMPLETE="$AGENT_RESULT_WINDOW_COMPLETE"
  AGENT_PROCESSED_UNTIL_EPOCH="$AGENT_RESULT_PROCESSED"
  [ "$AGENT_WINDOW_COMPLETE" = true ] && AGENT_BACKLOG_PENDING=false || \
    AGENT_BACKLOG_PENDING=true
  printf '%s\n' \
    'agent_machine_result_valid=true' \
    "agent_evidence_complete=$AGENT_EVIDENCE_COMPLETE" \
    "agent_window_complete=$AGENT_WINDOW_COMPLETE" \
    "agent_backlog_pending=$AGENT_BACKLOG_PENDING" \
    "agent_processed_until_epoch=$AGENT_PROCESSED_UNTIL_EPOCH" >>"$RAW_REPORT"
  if [ "$AGENT_HEALTHY" = false ]; then
    expected_rc=1
  elif [ "$AGENT_EVIDENCE_COMPLETE" = false ]; then
    expected_rc=2
  else
    expected_rc=0
  fi
  if [ "$rc" -ne "$expected_rc" ]; then
    printf 'agent_machine_result_exit_contract_valid=false expected_exit_code=%s\n' \
      "$expected_rc" >>"$RAW_REPORT"
    COLLECTION_COMPLETE=0
    return
  fi
  printf 'agent_machine_result_exit_contract_valid=true\n' >>"$RAW_REPORT"
  if [ "$AGENT_EVIDENCE_COMPLETE" != true ]; then
    COLLECTION_COMPLETE=0
    return
  fi
  if [ "$EUID" -ne 0 ]; then
    # journalctl 对非 root 可能成功却只返回当前用户可见子集，不能据此越过时间水位。
    COLLECTION_COMPLETE=0
    return
  fi
  COMPLETED_UNTIL_EPOCH="$AGENT_PROCESSED_UNTIL_EPOCH"
}

if [ "$STACK_ROLE" -eq 1 ]; then
  collect_modules
  collect_stack_processes
  collect_stack_probes
  collect_resources
  if [ "$STACK_RUNNING_COUNT" -eq 6 ] && [ "$STACK_PROBE_OK_COUNT" -eq 6 ]; then
    STACK_HEALTHY=true
  else
    STACK_HEALTHY=false
  fi
fi
if [ "$AGENT_ROLE" -eq 1 ]; then collect_agent; fi
printf 'schema=dbdog-diagnostics-cursor/v2\ncompleted_until_epoch=%s\n' \
  "$COMPLETED_UNTIL_EPOCH" >"$NEW_CURSOR"
chmod 0600 "$NEW_CURSOR"
collect_logs

case "$HOST_ROLE" in
  stack) OVERALL_HEALTHY="$STACK_HEALTHY" ;;
  agent) OVERALL_HEALTHY="$AGENT_HEALTHY" ;;
  stack+agent)
    if [ "$STACK_HEALTHY" = false ] || [ "$AGENT_HEALTHY" = false ]; then
      OVERALL_HEALTHY=false
    elif [ "$STACK_HEALTHY" = true ] && [ "$AGENT_HEALTHY" = true ]; then
      OVERALL_HEALTHY=true
    else
      OVERALL_HEALTHY=unknown
    fi
    ;;
  *) OVERALL_HEALTHY=false ;;
esac

section "diagnostic result"
cat >>"$RAW_REPORT" <<EOF
stack_healthy=$STACK_HEALTHY
agent_healthy=$AGENT_HEALTHY
overall_healthy=$OVERALL_HEALTHY
collection_complete=$([ "$COLLECTION_COMPLETE" -eq 1 ] && printf true || printf false)
cursor_eligible_to_advance=$([ "$COLLECTION_COMPLETE" -eq 1 ] && printf true || printf false)
processed_until_epoch=$COMPLETED_UNTIL_EPOCH
agent_processed_until_epoch=$AGENT_PROCESSED_UNTIL_EPOCH
agent_window_complete=$AGENT_WINDOW_COMPLETE
agent_backlog_pending=$AGENT_BACKLOG_PENDING
agent_evidence_complete=$AGENT_EVIDENCE_COMPLETE
stack_services_running=$STACK_RUNNING_COUNT/6
stack_probes_ok=$STACK_PROBE_OK_COUNT/6
plain_log_files_scanned=$LOG_FILES_SCANNED
plain_log_bytes_scanned=$LOG_BYTES_SCANNED
plain_log_rotations_detected=$LOG_ROTATIONS
plain_log_truncations_detected=$LOG_TRUNCATIONS
error_class.gauss_xid32_sql=$ERROR_GAUSS_XID32
error_class.gauss_replay_record_sql=$ERROR_GAUSS_REPLAY_RECORD
error_class.gauss_query_scope_failure=$ERROR_GAUSS_QUERY_SCOPE
error_class.system_probe_64k_panic=$ERROR_SYSPROBE_64K
error_class.postgres_connect=$ERROR_POSTGRES_CONNECT
error_class.panic=$ERROR_PANIC
error_class.oom=$ERROR_OOM
EOF

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
REPORT_FILE="$DIAGNOSTICS_DIR/dbdog-diagnostics-$STAMP-$RUN_ID.internal.txt"
ISSUE_FILE="$DIAGNOSTICS_DIR/dbdog-diagnostics-$STAMP-$RUN_ID.issue-card.txt"
[ ! -e "$REPORT_FILE" ] && [ ! -L "$REPORT_FILE" ] && \
  [ ! -e "$ISSUE_FILE" ] && [ ! -L "$ISSUE_FILE" ] || \
  die "诊断报告目标已存在，拒绝覆盖"
chmod 0600 "$RAW_REPORT"
if ! agent_redact_diagnostic_stream <"$RAW_REPORT" >"$REPORT_TMP"; then
  die "诊断报告脱敏失败；游标未推进"
fi
chmod 0600 "$REPORT_TMP"
mv -- "$REPORT_TMP" "$REPORT_FILE"
REPORT_SHA256="$(sha256_file "$REPORT_FILE")" || die "无法计算诊断报告 SHA-256；游标未推进"

issue_safe_desired_version() {
  local value="$1" digest
  if [ "$MANIFEST_TRUSTED" != true ]; then
    digest="$(printf '%s' "$value" | agent_sha256_stdin)" || {
      printf '%s\n' untrusted_unavailable
      return
    }
    printf 'untrusted_sha256_%s\n' "${digest:0:16}"
    return
  fi
  if [ "${#value}" -le 80 ]; then
    case "$value" in
      '' | *[!A-Za-z0-9._:+?-]*) printf '%s\n' invalid ;;
      *) printf '%s\n' "$value" ;;
    esac
  else
    printf '%s\n' invalid
  fi
}

issue_safe_installed_version() { # <trusted desired> <untrusted marker>
  local desired="$1" installed="$2" digest
  case "$installed" in
    - | \? | unavailable) printf '%s\n' "$installed"; return ;;
  esac
  if [ "$installed" = "$desired" ] && [ "$(issue_safe_desired_version "$desired")" != invalid ]; then
    printf '%s\n' "$installed"
    return
  fi
  digest="$(printf '%s' "$installed" | agent_sha256_stdin)" || {
    printf '%s\n' different_unavailable
    return
  }
  printf 'different_sha256_%s\n' "${digest:0:16}"
}

issue_safe_hash() { # <value> <required length>
  local value="$1" length="$2"
  if [ "${#value}" -eq "$length" ]; then
    case "$value" in *[!0-9a-f]*) printf '%s\n' unavailable ;; *) printf '%s\n' "$value" ;; esac
  else
    printf '%s\n' unavailable
  fi
}

case "$RELEASE_COMMIT" in
  *[!0-9a-f]*) ISSUE_RELEASE_COMMIT=unavailable ;;
  *)
    case "${#RELEASE_COMMIT}" in 40 | 64) ISSUE_RELEASE_COMMIT="$RELEASE_COMMIT" ;; *) ISSUE_RELEASE_COMMIT=unavailable ;; esac
    ;;
esac
case "$RELEASE_DIRTY" in true | false) ISSUE_RELEASE_DIRTY="$RELEASE_DIRTY" ;; *) ISSUE_RELEASE_DIRTY=unknown ;; esac
ISSUE_MANIFEST_SHA256="$(issue_safe_hash "$MANIFEST_SHA256" 64)"
ISSUE_DIAGNOSTIC_CONTRACT_SHA256="$(issue_safe_hash "$DIAGNOSTIC_CONTRACT_SHA256" 64)"

{
  printf '%s\n' \
    'schema=dbdog-diagnostics-issue-card/v1' \
    'contains_raw_logs=false' \
    'contains_hostname_or_ip=false' \
    'contains_sql_or_business_literals=false'
  printf 'source_internal_report_sha256=%s\n' "$REPORT_SHA256"
  printf 'release_checkout_commit=%s\nrelease_checkout_dirty=%s\n' \
    "$ISSUE_RELEASE_COMMIT" "$ISSUE_RELEASE_DIRTY"
  printf 'manifest_sha256=%s\ndiagnostic_contract_sha256=%s\n' \
    "$ISSUE_MANIFEST_SHA256" "$ISSUE_DIAGNOSTIC_CONTRACT_SHA256"
  printf 'manifest_identity_trusted=%s\n' "$MANIFEST_TRUSTED"
  printf 'scan_from_epoch=%s\nscan_until_epoch=%s\nprocessed_until_epoch=%s\nhost_role=%s\n' \
    "$SCAN_FROM_EPOCH" "$SCAN_UNTIL_EPOCH" "$COMPLETED_UNTIL_EPOCH" "$HOST_ROLE"
  printf 'collection_complete=%s\noverall_healthy=%s\n' \
    "$([ "$COLLECTION_COMPLETE" -eq 1 ] && printf true || printf false)" "$OVERALL_HEALTHY"
  printf 'stack_healthy=%s\nagent_healthy=%s\n' "$STACK_HEALTHY" "$AGENT_HEALTHY"
  printf 'agent_evidence_complete=%s\nagent_window_complete=%s\nagent_backlog_pending=%s\n' \
    "$AGENT_EVIDENCE_COMPLETE" "$AGENT_WINDOW_COMPLETE" "$AGENT_BACKLOG_PENDING"
  printf 'stack_services_running=%s\nstack_probes_ok=%s\n' \
    "$STACK_RUNNING_COUNT/6" "$STACK_PROBE_OK_COUNT/6"
  while IFS=$'\t' read -r module desired installed; do
    case "$module" in
      node | goose | postgresql | clickhouse | dbdog-server | dbdog-web | dbdog-mcp | dbdog-agent) ;;
      *) continue ;;
    esac
    desired="$(issue_safe_desired_version "$desired")"
    installed="$(issue_safe_installed_version "$desired" "$installed")"
    printf 'module_version.%s.desired=%s\nmodule_version.%s.installed=%s\n' \
      "$module" "$desired" "$module" "$installed"
  done <"$MODULE_SUMMARY"
  printf 'plain_log_files_scanned=%s\nplain_log_bytes_scanned=%s\n' \
    "$LOG_FILES_SCANNED" "$LOG_BYTES_SCANNED"
  printf 'plain_log_rotations_detected=%s\nplain_log_truncations_detected=%s\n' \
    "$LOG_ROTATIONS" "$LOG_TRUNCATIONS"
  printf 'error_class.gauss_xid32_sql=%s\n' "$ERROR_GAUSS_XID32"
  printf 'error_class.gauss_replay_record_sql=%s\n' "$ERROR_GAUSS_REPLAY_RECORD"
  printf 'error_class.gauss_query_scope_failure=%s\n' "$ERROR_GAUSS_QUERY_SCOPE"
  printf 'error_class.system_probe_64k_panic=%s\n' "$ERROR_SYSPROBE_64K"
  printf 'error_class.postgres_connect=%s\n' "$ERROR_POSTGRES_CONNECT"
  printf 'error_class.panic=%s\nerror_class.oom=%s\n' "$ERROR_PANIC" "$ERROR_OOM"
} >"$ISSUE_TMP"
chmod 0600 "$ISSUE_TMP"
mv -- "$ISSUE_TMP" "$ISSUE_FILE"

if [ "$COLLECTION_COMPLETE" -eq 1 ]; then
  chmod 0600 "$NEW_CURSOR"
  mv -- "$NEW_CURSOR" "$CURSOR_FILE"
  chmod 0600 "$CURSOR_FILE"
else
  warn "报告已落盘但证据不完整，增量游标保持不变"
fi

printf 'internal_report=%s\n' "$REPORT_FILE"
printf 'issue_card=%s\n' "$ISSUE_FILE"
printf 'collection_complete=%s\n' \
  "$([ "$COLLECTION_COMPLETE" -eq 1 ] && printf true || printf false)"
printf 'overall_healthy=%s\n' "$OVERALL_HEALTHY"
printf '%s\n' '注意：*.internal.txt 只能留在内网；外部反馈仅使用人工复核后的 *.issue-card.txt。'

[ "$COLLECTION_COMPLETE" -eq 1 ] || exit 2
exit 0
