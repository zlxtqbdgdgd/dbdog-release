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

FINGERPRINT_ROOT="$TEST_ROOT/installer-fingerprint"
mkdir -p "$FINGERPRINT_ROOT/agent"
printf 'shared-lib-v1\n' >"$FINGERPRINT_ROOT/lib.sh"
printf 'install-v1\n' >"$FINGERPRINT_ROOT/agent-install.sh"
printf 'lib-v1\n' >"$FINGERPRINT_ROOT/agent-lib.sh"
printf 'sql-v1\n' >"$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql"
printf 'perdb-tool-v1\n' >"$FINGERPRINT_ROOT/agent/init-dbdog-user-gaussdb-all-databases.sh"
printf 'pg-tool-v1\n' >"$FINGERPRINT_ROOT/agent/init-dbdog-user-pg-all-databases.sh"
printf 'pg-sql-v1\n' >"$FINGERPRINT_ROOT/agent/init-dbdog-user-pg-perdb.sql"
printf 'og-tool-v1\n' >"$FINGERPRINT_ROOT/agent/init-dbdog-user-opengauss-all-databases.sh"
printf 'og-sql-v1\n' >"$FINGERPRINT_ROOT/agent/init-dbdog-user-opengauss-perdb.sql"
FINGERPRINT_1="$(agent_installer_contract_fingerprint "$FINGERPRINT_ROOT")" || \
  fail "无法计算安装器合约指纹"
[ "${#FINGERPRINT_1}" -eq 64 ] || fail "安装器合约指纹不是 SHA-256"
printf 'unrelated\n' >"$FINGERPRINT_ROOT/README.md"
[ "$(agent_installer_contract_fingerprint "$FINGERPRINT_ROOT")" = "$FINGERPRINT_1" ] || \
  fail "无关文件错误改变了 Agent 安装器合约指纹"
mv "$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql" \
  "$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql.missing"
if agent_installer_contract_fingerprint "$FINGERPRINT_ROOT" \
  >"$TEST_ROOT/fingerprint-missing-sql.out" 2>"$TEST_ROOT/fingerprint-missing-sql.err"; then
  fail "安装器合约指纹错误接受了缺失的 GaussDB 初始化 SQL"
fi
grep -Fq "$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql" \
  "$TEST_ROOT/fingerprint-missing-sql.err" || \
  fail "初始化 SQL 缺失时 stderr 没有列出具体路径"
mv "$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql.missing" \
  "$FINGERPRINT_ROOT/agent/init-gaussdb-perdb.sql"
printf 'lib-v2\n' >"$FINGERPRINT_ROOT/agent-lib.sh"
FINGERPRINT_2="$(agent_installer_contract_fingerprint "$FINGERPRINT_ROOT")" || \
  fail "安装器合约变更后无法重新计算指纹"
[ "$FINGERPRINT_2" != "$FINGERPRINT_1" ] || fail "Agent 安装器逻辑变更没有改变合约指纹"
rm -f "$FINGERPRINT_ROOT/agent-install.sh"
ln -s /dev/null "$FINGERPRINT_ROOT/agent-install.sh"
if agent_installer_contract_fingerprint "$FINGERPRINT_ROOT" >/dev/null 2>&1; then
  fail "安装器合约指纹错误接受了符号链接"
fi
pass "Agent 专属安装逻辑使用独立内容指纹，且对缺失/符号链接 fail closed"

# 后面 GaussDB 密码复杂度断言块（"错误接受了只有两类字符的密码"）是已知基线失败，
# 命中即 fail() -> exit 1，会挡住它之后的全部断言。下面两组架构选择契约测试与
# GaussDB fixture 无关，故意放在那条已知失败之前，确保正常执行 `bash
# scripts/test-agent-install-contracts.sh` 时它们真的会被跑到，而不是变成只有绕过
# 已知失败才能触达的死代码。
INSTALL_SCRIPT="$SCRIPTS_DIR/agent-install.sh"

# ---- require_root_host 不再硬编码 AArch64-only 主机拒绝，改用 host_arch 统一解析 ----
REQUIRE_ROOT_HOST_BODY="$(awk '/^require_root_host\(\)/ { scan=1 } /^configure_agent_health_timeout\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'AGENT_HOST_ARCH="$(host_arch)"' <<<"$REQUIRE_ROOT_HOST_BODY" || \
  fail "require_root_host 没有调用 host_arch 并保存 AGENT_HOST_ARCH"
if grep -Fq '产物仅支持 aarch64' <<<"$REQUIRE_ROOT_HOST_BODY"; then
  fail "require_root_host 仍残留硬编码的 AArch64-only 主机拒绝"
fi
pass "require_root_host 改用 host_arch 统一解析主机架构，不再硬编码只接受 AArch64"

# ---- Step 1 TDD：manifest 出现 dbdog-agent 的 aarch64/x86_64 双行时，按 host_arch
# 精确选择要下载的产物；未知架构在触发任何下载前 fail closed。----
ARCH_SELECT_ROOT="$TEST_ROOT/arch-select"
mkdir -p "$ARCH_SELECT_ROOT"
ARCH_MANIFEST="$ARCH_SELECT_ROOT/manifest.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  dbdog-agent first-party dbhost no 9.9.9-dbdog.1 \
  dbdog-agent-9.9.9-dbdog.1-aarch64.tar.gz \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  agent:0000000,core:0000000 aarch64 \
  >"$ARCH_MANIFEST"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  dbdog-agent first-party dbhost no 9.9.9-dbdog.1 \
  dbdog-agent-9.9.9-dbdog.1-x86_64.tar.gz \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  agent:0000000,core:0000000 x86_64 \
  >>"$ARCH_MANIFEST"

run_arch_select() { # <DBDOG_HOST_ARCH_OVERRIDE> <输出文件>
  local override="$1" out="$2"
  # 复刻 main() 里选包并下载的三行 manifest_get + 一次 download_artifact；
  # download_artifact 被替换为记录调用参数的桩，不发真实网络请求。require_root_host
  # 的 root/systemd 前提在这个纯函数契约测试里无法满足，不在这里调用；它单独有上面
  # 的静态断言覆盖。
  MANIFEST="$ARCH_MANIFEST" DBDOG_HOST_ARCH_OVERRIDE="$override" \
    bash -c '
      source "$1"
      trap - EXIT
      download_artifact() {
        # 调用方用 package="$(download_artifact ...)" 捕获 stdout 作为本地路径；
        # 记录日志必须走 stderr，否则会被那次命令替换悄悄吞掉，测试看不到。
        printf "download_artifact_called artifact=%s sha256=%s\n" "$1" "$2" >&2
        printf "%s\n" "/nonexistent/$1"
      }
      version="$(manifest_get dbdog-agent 5)"
      artifact="$(manifest_get dbdog-agent 6)"
      sha256="$(manifest_get dbdog-agent 7)"
      package="$(download_artifact "$artifact" "$sha256")"
      printf "SELECTED_VERSION=%s\n" "$version"
      printf "SELECTED_ARTIFACT=%s\n" "$artifact"
    ' bash "$INSTALL_SCRIPT" >"$out" 2>&1
}

X86_64_OUT="$ARCH_SELECT_ROOT/x86_64.out"
run_arch_select x86_64 "$X86_64_OUT" || { cat "$X86_64_OUT" >&2; fail "x86_64 主机的合法双架构选择被拒绝"; }
grep -Fq 'SELECTED_ARTIFACT=dbdog-agent-9.9.9-dbdog.1-x86_64.tar.gz' "$X86_64_OUT" || \
  fail "DBDOG_HOST_ARCH_OVERRIDE=x86_64 没有选中 x86_64 产物"
grep -Fq 'download_artifact_called artifact=dbdog-agent-9.9.9-dbdog.1-x86_64.tar.gz' "$X86_64_OUT" || \
  fail "DBDOG_HOST_ARCH_OVERRIDE=x86_64 没有只下载 *-x86_64.tar.gz"
if grep -Fq 'aarch64.tar.gz' "$X86_64_OUT"; then
  fail "DBDOG_HOST_ARCH_OVERRIDE=x86_64 错误地混入了 aarch64 产物"
fi

RISCV64_OUT="$ARCH_SELECT_ROOT/riscv64.out"
if run_arch_select riscv64 "$RISCV64_OUT"; then
  cat "$RISCV64_OUT" >&2
  fail "DBDOG_HOST_ARCH_OVERRIDE=riscv64 错误地被接受"
fi
grep -Fq 'download_artifact_called' "$RISCV64_OUT" && \
  fail "riscv64 未支持的架构在 fail closed 前触发了下载"
grep -Fq '不支持的主机架构: riscv64' "$RISCV64_OUT" || \
  fail "riscv64 没有给出清晰的 fail-closed 诊断信息"
pass "manifest 双架构行按 DBDOG_HOST_ARCH_OVERRIDE/host_arch 精确选包下载，未知架构在下载前 fail closed"

# ---- DBDOG_AGENT_PREFLIGHT_ONLY：只跑 artifact 门禁，必须在 cutover/配置之前返回 ----
MAIN_BODY="$(awk '/^main\(\)/ { scan=1 } scan { print }' "$INSTALL_SCRIPT")"
grep -Fq 'DBDOG_AGENT_PREFLIGHT_ONLY' <<<"$MAIN_BODY" || \
  fail "main() 没有识别 DBDOG_AGENT_PREFLIGHT_ONLY"
grep -Fq 'agent_preflight_artifact_only' <<<"$MAIN_BODY" || \
  fail "main() 没有调用 agent_preflight_artifact_only"
PREFLIGHT_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'agent_preflight_artifact_only' | head -1 | cut -d: -f1)"
CUTOVER_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n '^[[:space:]]*cutover$' | head -1 | cut -d: -f1)"
[ -n "$PREFLIGHT_LINE" ] && [ -n "$CUTOVER_LINE" ] && [ "$PREFLIGHT_LINE" -lt "$CUTOVER_LINE" ] || \
  fail "PREFLIGHT_ONLY 路径没有排在 cutover 之前"
PREFLIGHT_FN="$(awk '/^agent_preflight_artifact_only\(\)/ { scan=1 } /^main\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
grep -Fq 'validate_archive_members' <<<"$PREFLIGHT_FN" || \
  fail "preflight 没有校验 archive 成员"
grep -Fq 'validate_runtime_tree' <<<"$PREFLIGHT_FN" || \
  fail "preflight 没有校验 runtime/provenance/ELF/version"
if grep -Eq 'cutover|resolve_inputs|render_install_state|bootstrap_gaussdb|start_and_verify' <<<"$PREFLIGHT_FN"; then
  fail "preflight 函数错误地包含了会改配置/停服务的步骤"
fi
pass "DBDOG_AGENT_PREFLIGHT_ONLY 只做 artifact 门禁，且排在 cutover 之前"

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
printf '#!/bin/sh\nexit 0\n' >"$GAUSSHOME/bin/gaussdb"
chmod 0755 "$GAUSSHOME/bin/gsql" "$GAUSSHOME/bin/gaussdb"
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
ln -s "$GAUSSHOME/bin/gaussdb" "$PROC/$PID/exe"
ln -s "$DATA" "$PROC/$PID/cwd"
# 覆盖真实 postmaster 行为：cmdline 保留启动时的相对 -D data，但进程已 chdir(PGDATA)。
# 不能再机械拼成 <PGDATA>/data，也不能按安装器当前目录猜测。
printf '%s\0-D\0data\0' "$GAUSSHOME/bin/gaussdb" >"$PROC/$PID/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGPORT=37001\0PGHOST=%s\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$SOCKET_DIR" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/$PID/environ"
printf 'Name:\tgaussdb\nState:\tS (sleeping)\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\n' \
  "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$PROC/$PID/status"
printf '4242\n%s\n0\n15432\n%s\n' "$DATA" "$SOCKET_DIR" >"$DATA/postmaster.pid"
# 模拟同实例的另一个 gaussdb backend；安装事实必须按 socket+端口去重。
mkdir -p "$PROC/4243"
printf 'gaussdb\n' >"$PROC/4243/comm"
ln -s "$GAUSSHOME/bin/gaussdb" "$PROC/4243/exe"
printf 'gaussdb: dbdog postgres 127.0.0.1\0' >"$PROC/4243/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGDATA=%s\0PGPORT=15432\0PGHOST=%s\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$DATA" "$SOCKET_DIR" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/4243/environ"
cp "$PROC/$PID/status" "$PROC/4243/status"

# 数字更小的 fenced/UDF 与辅助进程会先于主进程被扫描。它们即使 comm/exe
# 都是 gaussdb，也不能靠角色 cmdline 黑名单识别；必须因无法用 postmaster.pid
# 正向证明自己是实例主进程而被跳过。
FENCED_PID=4000
AUX_PID=4001
AUX_DATA="$TEST_ROOT/gauss/aux-data"
AUX_SOCKET="$TEST_ROOT/gauss/aux-socket"
AUX_LOG="$TEST_ROOT/gauss/aux-log"
mkdir -p "$PROC/$FENCED_PID" "$PROC/$AUX_PID" "$AUX_DATA" "$AUX_SOCKET" "$AUX_LOG"
for candidate in "$FENCED_PID" "$AUX_PID"; do
  printf 'gaussdb\n' >"$PROC/$candidate/comm"
  ln -s "$GAUSSHOME/bin/gaussdb" "$PROC/$candidate/exe"
  printf 'Name:\tgaussdb\nState:\tS (sleeping)\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' \
    "$PID" "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$PROC/$candidate/status"
done
printf '%s\0--worker-mode\0fenced-udf\0' "$GAUSSHOME/bin/gaussdb" \
  >"$PROC/$FENCED_PID/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGPORT=19999\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$AUX_LOG" "$GAUSSHOME" >"$PROC/$FENCED_PID/environ"
printf '%s\0-D\0%s\0--auxiliary\0' "$GAUSSHOME/bin/gaussdb" "$AUX_DATA" \
  >"$PROC/$AUX_PID/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGDATA=%s\0PGPORT=19998\0PGHOST=%s\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$AUX_LOG" "$AUX_DATA" "$AUX_SOCKET" "$GAUSSHOME" \
  >"$PROC/$AUX_PID/environ"
printf '9999\n%s\n0\n19998\n%s\n' "$AUX_DATA" "$AUX_SOCKET" \
  >"$AUX_DATA/postmaster.pid"

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
# 两种落盘布局各一条：多节点按节点名分子目录，集中式直接落 gs_log/ 下。
# 只给带子目录那条会让集中式实例一条日志都采不到（2026-08-05 x86-gaussdb-73 实证）。
[ "${AGENT_GAUSS_LOG_GLOBS[*]}" = "$GAUSSLOG/gs_log/*/gaussdb-*.log $GAUSSLOG/gs_log/gaussdb-*.log" ] || \
  fail "没有为两种 gs_log 落盘布局各生成一条日志 glob"
[ "$AGENT_GAUSS_DEPLOYMENT" = centralized ] || fail "单实例拓扑推断错误"
[ "${AGENT_GAUSS_PID_SOURCE_PIDS[*]}" = "$PID" ] || \
  fail "fenced/backend/辅助进程被错误当作 GaussDB 主实例"
pass "优先从目标机主进程发现 GaussDB 事实，并跳过 fenced/backend/辅助进程"

if (DBDOG_GAUSSDB_PID="$AUX_PID"; export DBDOG_GAUSSDB_PID; agent_detect_gaussdb) \
  >"$TEST_ROOT/explicit-aux-pid.out" 2>&1; then
  fail "显式指定的 GaussDB 辅助 PID 被错误接受为主实例"
fi
grep -Eq '主进程|主实例|postmaster\.pid' "$TEST_ROOT/explicit-aux-pid.out" || \
  fail "显式辅助 PID 被拒绝时没有说明主进程身份校验失败"
DBDOG_GAUSSDB_PID="$PID"
export DBDOG_GAUSSDB_PID
agent_detect_gaussdb || fail "显式指定真实 GaussDB 主 PID 失败"
unset DBDOG_GAUSSDB_PID
[ "${AGENT_GAUSS_PID_SOURCE_PIDS[*]}" = "$PID" ] || \
  fail "显式主 PID 没有形成唯一实例事实"
pass "显式 GaussDB PID 复用同一主进程身份合同"

# 安装期 gsql 必须使用目标实例管理 socket：运行进程中残留 TCP PGHOST 时
# 回退到 postmaster.pid；操作者也不能把这个管理通道误配成 TCP host。
cp "$PROC/$PID/environ" "$TEST_ROOT/main-environ"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGPORT=37001\0PGHOST=127.0.0.1\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/$PID/environ"
agent_detect_gaussdb
[ "${AGENT_GAUSS_PID_HOSTS[*]}" = "$SOCKET_DIR" ] || fail "TCP PGHOST 没有回退到运行态 Unix socket"
cp "$TEST_ROOT/main-environ" "$PROC/$PID/environ"
if (DBDOG_GAUSSDB_PGHOST=127.0.0.1; export DBDOG_GAUSSDB_PGHOST; agent_detect_gaussdb) \
  >"$TEST_ROOT/tcp-pghost.out" 2>&1; then
  fail "显式 TCP PGHOST 被错误接受"
fi
grep -Fq '必须是绝对 Unix socket 目录' "$TEST_ROOT/tcp-pghost.out" || \
  fail "显式 TCP PGHOST 没有给出清晰错误"
pass "安装期 gsql 自动恢复管理 socket，显式 TCP PGHOST fail closed"

# 管理面可按 socket+port 区分实例，但运行期固定 127.0.0.1:port；同端口
# 多实例无法形成唯一 TCP endpoint，必须拒绝而不是静默监控错实例。
DATA2="$TEST_ROOT/gauss/data2"
SOCKET_DIR2="$TEST_ROOT/gauss/socket2"
mkdir -p "$PROC/4244" "$DATA2" "$SOCKET_DIR2"
printf 'gaussdb\n' >"$PROC/4244/comm"
ln -s "$GAUSSHOME/bin/gaussdb" "$PROC/4244/exe"
printf '%s\0-D\0%s\0' "$GAUSSHOME/bin/gaussdb" "$DATA2" >"$PROC/4244/cmdline"
printf 'GAUSSHOME=%s\0GAUSSLOG=%s\0PGDATA=%s\0PGPORT=15432\0PGHOST=%s\0LD_LIBRARY_PATH=%s/lib:%s/lib/libsimsearch\0PATH=%s/bin:/usr/bin:/bin\0' \
  "$GAUSSHOME" "$GAUSSLOG" "$DATA2" "$SOCKET_DIR2" "$GAUSSHOME" "$GAUSSHOME" "$GAUSSHOME" \
  >"$PROC/4244/environ"
cp "$PROC/$PID/status" "$PROC/4244/status"
printf '4244\n%s\n0\n15432\n%s\n' "$DATA2" "$SOCKET_DIR2" >"$DATA2/postmaster.pid"
if (agent_detect_gaussdb) >"$TEST_ROOT/duplicate-tcp-endpoint.out" 2>&1; then
  fail "相同 TCP endpoint 的多个实例被错误接受"
fi
grep -Fq '127.0.0.1 TCP 监控无法唯一区分' "$TEST_ROOT/duplicate-tcp-endpoint.out" || \
  fail "重复 TCP endpoint 没有给出清晰错误"
mv "$PROC/4244" "$TEST_ROOT/ignored-proc-4244"
agent_detect_gaussdb
pass "安装期区分 socket，运行期重复 TCP endpoint fail closed"

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

INSTALL_SCRIPT="$SCRIPTS_DIR/agent-install.sh"
for forbidden in \
  agent_install_hba_rule \
  agent_restore_hba_rules \
  persist_hba_recovery_materials \
  pg_reload_conf \
  install-hba-recovery. \
  legacy_trust \
  managed_socket_trust \
  DB_HBA_PASSWORD_REFRESH; do
  if grep -Fq "$forbidden" "$INSTALL_SCRIPT"; then
    fail "安装器仍含 HBA 写入、回滚或旧 socket trust 迁移逻辑: $forbidden"
  fi
done
grep -Fq 'SHOW hba_file;' "$INSTALL_SCRIPT" || fail "安装器没有只读发现目标 HBA 文件"
grep -Fq 'host all dbdog 127.0.0.1/32 md5' "$INSTALL_SCRIPT" || \
  fail "安装器没有校验 DBA 预配置的精确 TCP MD5 规则"
pass "安装器只读校验 DBA 预配置的 HBA，不写入、回滚或迁移生产配置"

CONF="$TEST_ROOT/rendered"
UNITS="$TEST_ROOT/units"
mkdir -p "$CONF/conf.d"
agent_render_datadog_yaml "$CONF/datadog.yaml" 'http://dbdog.internal:8080' \
  'key_abc-123' 'gauss-node-01' '{"signed":{"version":1}}'
agent_render_system_probe_yaml "$CONF/system-probe.yaml"
# 渲染的引擎归属来自安装器的分类结果（gauss 检测 + gsql 版本分流 + pg 检测）；
# 这里直接给出分类后的事实，模拟三引擎同机：gauss:15432 / openGauss:15433 / PG:15434。
AGENT_GAUSSDB_RENDER_PORTS=("${AGENT_GAUSS_PORTS[@]}")
AGENT_OPENGAUSS_RENDER_PORTS=(15433)
AGENT_OPENGAUSS_LOG_GLOBS=("$TEST_ROOT/ogdata/pg_log/postgresql-*.log")
AGENT_PG_PORTS=(15434)
AGENT_PG_LOG_GLOBS=("$TEST_ROOT/pgdata/log/*.log")
# og/pg 凭证按实例（agent_assemble_engine_credentials 的产出形态）：多实例密码可各不相同。
AGENT_OPENGAUSS_RENDER_PASSWORDS=("og'pw")
AGENT_PG_RENDER_PASSWORDS=("pg'pw")
agent_render_checks "$CONF/conf.d" "pa'ss: #1" dbdog postgres prod
agent_render_units "$UNITS"
if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f) }' \
    "$CONF/datadog.yaml" "$CONF/system-probe.yaml" \
    "$CONF/conf.d/gaussdb.d/conf.yaml" \
    "$CONF/conf.d/opengauss.d/conf.yaml" \
    "$CONF/conf.d/postgres.d/conf.yaml" || fail "生成的 YAML 无法解析"
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
[ "$(grep -c 'enabled: false' "$CONF/datadog.yaml")" -ge 3 ] || \
  fail "私有部署没有显式关闭 Agent/APM 公网遥测"
grep -A1 '^agent_telemetry:' "$CONF/datadog.yaml" | grep -Fq 'enabled: false' || \
  fail "Agent instrumentation telemetry 仍会访问 Datadog 公网"
grep -A12 '^apm_config:' "$CONF/datadog.yaml" | grep -A1 'telemetry:' | \
  grep -Fq 'enabled: false' || fail "APM telemetry 仍会访问 Datadog 公网"
grep -Fq 'network_config:' "$CONF/system-probe.yaml" || fail "NPM 未启用"
grep -Fq 'service_monitoring_config:' "$CONF/system-probe.yaml" || fail "USM 未启用"
if grep -Eq '^[[:space:]]+enable_event_stream:[[:space:]]*false([[:space:]]|$)' \
  "$CONF/system-probe.yaml"; then
  fail "修复后的 Agent 仍被全局关闭 USM process event stream"
fi
if grep -Eq '^[[:space:]]+network_process:[[:space:]]*$' "$CONF/system-probe.yaml"; then
  fail "修复后的 Agent 仍被全局关闭 NPM process cache/container DNS"
fi
grep -Fq 'runtime_security_config:' "$CONF/system-probe.yaml" || \
  fail "没有显式关闭当前产品未启用的 CWS/FIM"
[ "$(grep -c 'enabled: true' "$CONF/system-probe.yaml")" -ge 3 ] || \
  fail "误关了 NPM/USM"

LEGACY_SYSTEM_PROBE="$TEST_ROOT/legacy-system-probe.yaml"
cat >"$LEGACY_SYSTEM_PROBE" <<'EOF'
service_monitoring_config:
  enable_event_stream: false
event_monitoring_config:
  network_process:
    enabled: false
EOF
agent_render_system_probe_yaml "$LEGACY_SYSTEM_PROBE"
if grep -Eq 'enable_event_stream:[[:space:]]*false|network_process:' \
  "$LEGACY_SYSTEM_PROBE"; then
  fail "配置刷新错误保留了旧版 EventMonitor 全局降级项"
fi
RENDER_STATE_BODY="$(awk '/^render_install_state\(\)/ { scan=1 } /^cutover\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
CUTOVER_CONFIG_BODY="$(awk '/^cutover\(\)/ { scan=1 } /^wait_active\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
ROLLBACK_CONFIG_BODY="$(awk '/^rollback_install\(\)/ { scan=1 } /^on_exit\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'agent_render_system_probe_yaml "$CONFIG_STAGE/system-probe.yaml"' \
  <<<"$RENDER_STATE_BODY" || fail "升级没有重新生成完整 system-probe 配置"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'mv -- "$CONFIG_STAGE" "$AGENT_CONFIG_DIR"' <<<"$CUTOVER_CONFIG_BODY" || \
  fail "成功升级没有用新生成的配置目录整体替换旧配置"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'mv -- "$OLD_CONFIG" "$AGENT_CONFIG_DIR"' <<<"$ROLLBACK_CONFIG_BODY" || \
  fail "失败回滚没有恢复与旧 runtime 配套的旧配置"
pass "成功升级会清除旧版 EventMonitor false；失败升级仍事务性恢复原配置"

grep -Fq 'dbm: true' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "GaussDB DBM 未启用"
grep -Fq 'collect_activity_metrics: true' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "activity 未启用"
grep -Fq "password: 'pa''ss: #1'" "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "密码 YAML 转义错误"
grep -Fq 'host: 127.0.0.1' "$CONF/conf.d/gaussdb.d/conf.yaml" || \
  fail "GaussDB integration 没有使用本机 TCP endpoint"
if grep -Fq "host: '$SOCKET_DIR'" "$CONF/conf.d/gaussdb.d/conf.yaml"; then
  fail "安装期管理 socket 被错误写入运行期 GaussDB 配置"
fi
grep -Fq 'port: 15432' "$CONF/conf.d/gaussdb.d/conf.yaml" || fail "探测端口没有落入配置"
grep -Fq "$GAUSSLOG/gs_log/*/gaussdb-*.log" "$CONF/conf.d/gaussdb.d/conf.yaml" || \
  fail "探测日志路径没有落入配置"
grep -Fq "hostname: 'gauss-node-01'" "$CONF/datadog.yaml" || fail "没有使用目标机 hostname"
grep -Fq "dd_url: 'http://dbdog.internal:8080'" "$CONF/datadog.yaml" || fail "没有使用安装输入的 server"
pass "外网已验证功能集默认开启，机器事实与秘密在安装时渲染"

for check in cpu disk file_handle io load memory network process system_core uptime; do
  [ -f "$CONF/conf.d/$check.d/conf.yaml" ] || fail "缺少默认 check: $check"
  grep -Fq 'min_collection_interval: 15' "$CONF/conf.d/$check.d/conf.yaml" || \
    fail "默认 check 没有显式声明 15s Agent 采集 cadence: $check"
done
# DB 引擎模板对齐 dbdog-deploy 权威（84a58e3）：显式项只留必需 + 三个显式开关，
# 其余采集参数一律用 check 默认值——显式复述默认值曾造成部署漂移。
for retired in 'max_relations:' 'min_collection_interval:' 'collect_schemas:' \
  'collect_settings:' 'collect_database_size_metrics:' 'collect_wal_metrics:' \
  'collect_bloat_metrics:' 'collect_function_metrics:' 'collect_buffercache_metrics:' \
  'data_observability:' 'collection_interval:'; do
  if grep -Fq "$retired" "$CONF/conf.d/gaussdb.d/conf.yaml" \
      "$CONF/conf.d/opengauss.d/conf.yaml" "$CONF/conf.d/postgres.d/conf.yaml"; then
    fail "DB 引擎模板仍显式复述 check 默认值（应对齐 deploy 模板）: $retired"
  fi
done
for engine_conf in gaussdb opengauss postgres; do
  grep -Fq 'database_autodiscovery:' "$CONF/conf.d/$engine_conf.d/conf.yaml" || \
    fail "$engine_conf 模板缺少 database_autodiscovery（多库表级指标会静默缺失）"
  grep -Fq 'global_view_db: postgres' "$CONF/conf.d/$engine_conf.d/conf.yaml" || \
    fail "$engine_conf autodiscovery 缺少 cluster 级锚点 global_view_db"
  grep -Fq 'function_name: dbdog.column_statistics()' "$CONF/conf.d/$engine_conf.d/conf.yaml" || \
    fail "$engine_conf 列统计没有显式指向 dbdog schema 函数"
  grep -Fq 'collect_activity_metrics: true' "$CONF/conf.d/$engine_conf.d/conf.yaml" || \
    fail "$engine_conf activity 直发指标未显式开启"
done
grep -Fq "template: 'opengauss-\$resolved_hostname-\$port'" "$CONF/conf.d/opengauss.d/conf.yaml" || \
  fail "openGauss database_identifier 缺少 opengauss- 前缀（与历史 gaussdb wire 实例会混淆）"
grep -Fq 'explain_function: dbdog.explain_statement' "$CONF/conf.d/postgres.d/conf.yaml" || \
  fail "PostgreSQL explain 函数没有走 dbdog 命名"
grep -Fq 'explain_function: public.dbdog_explain_statement' "$CONF/conf.d/opengauss.d/conf.yaml" || \
  fail "openGauss explain 入口不在 public"
grep -Fq 'do_connection_port:15434' "$CONF/conf.d/postgres.d/conf.yaml" || \
  fail "PostgreSQL 缺少控制面 schema 资产映射 tag do_connection_port"
grep -Fq "password: 'og''pw'" "$CONF/conf.d/opengauss.d/conf.yaml" || \
  fail "openGauss 密码 YAML 转义错误"
grep -Fq "password: 'pg''pw'" "$CONF/conf.d/postgres.d/conf.yaml" || \
  fail "PostgreSQL 密码 YAML 转义错误"
if grep -R -Fq 'collect_core_metrics: false' "$CONF/conf.d"; then
  fail "没有运行时证据却擅自关闭了逐核 CPU 指标"
fi
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

if grep -Fq 'SET password_encryption_type' "$INSTALL_SCRIPT"; then
  fail "安装器仍尝试在会话中修改 password_encryption_type"
fi
grep -Fq "SHOW password_encryption_type;" "$INSTALL_SCRIPT" || fail "没有预检认证模式"
grep -Fq 'host all dbdog 127.0.0.1/32 md5' "$INSTALL_SCRIPT" || fail "缺少精确本机 MD5 HBA 合同"
for forbidden in \
  DB_PASSWORD_CHANGED \
  DB_PASSWORD_RESET_WITHOUT_ROLLBACK \
  "local password=\"\$1\" force=" \
  "agent_prepare_gaussdb_user \"\$PREVIOUS_DB_PASSWORD\" force"; do
  if grep -Fq "$forbidden" "$INSTALL_SCRIPT"; then
    fail "安装器仍含已有账号密码刷新或密码回滚逻辑: $forbidden"
  fi
done
grep -Fq 'ALTER USER dbdog WITH MONADMIN;' "$INSTALL_SCRIPT" || \
  fail "已有 dbdog 用户验证通过后没有幂等确保 MONADMIN"
grep -Fq 'install-configcheck.log' "$INSTALL_SCRIPT" || fail "configcheck 诊断没有持久化"
grep -Fq 'for ((i=1; i<=8; i++))' "$INSTALL_SCRIPT" || fail "configcheck 没有 readiness 重试"
if grep -Fq 'PGPASSWORD=' "$INSTALL_SCRIPT"; then fail "数据库密码仍暴露在子进程 argv 环境赋值中"; fi
grep -Fq 'error.sqlstate == "28P01"' "$INSTALL_SCRIPT" || fail "密码探测没有区分明确认证拒绝和基础设施错误"
ACTIVE_AUTH_BODY="$(awk '/^agent_active_auth_is_md5\(\)/ { scan=1 } /^agent_prepare_gaussdb_user\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
grep -Fq 'socket.create_connection(("127.0.0.1"' <<<"$ACTIVE_AUTH_BODY" || \
  fail "生效认证探测没有直接建立本机 TCP 连接"
grep -Fq 'struct.pack("!I", 196608)' <<<"$ACTIVE_AUTH_BODY" || \
  fail "生效认证探测没有发送最小 PostgreSQL v3 StartupMessage"
grep -Fq 'message_type != b"R"' <<<"$ACTIVE_AUTH_BODY" || \
  fail "生效认证探测没有要求 AuthenticationRequest"
grep -Fq 'authentication_code != 5' <<<"$ACTIVE_AUTH_BODY" || \
  fail "生效认证探测没有精确要求 MD5 AuthenticationRequest code=5"
if grep -Eqi 'psycopg|password' <<<"$ACTIVE_AUTH_BODY"; then
  fail "生效认证类型探测仍通过客户端驱动或错误密码推断"
fi
[ "$(grep -c 'connection.sendall' <<<"$ACTIVE_AUTH_BODY")" -eq 1 ] || \
  fail "生效认证类型探测在 StartupMessage 后仍可能提交额外认证消息"
PREPARE_USER_BODY="$(awk '/^agent_prepare_gaussdb_user\(\)/ { scan=1 } /^bootstrap_gaussdb_monitoring\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
grep -Fq "agent_monitor_password_works \"\$index\" \"\$password\"" <<<"$PREPARE_USER_BODY" || \
  fail "准备 dbdog 用户没有用真实正确密码做驱动登录探测"
grep -Fq "agent_active_auth_is_md5 \"\$index\"" <<<"$PREPARE_USER_BODY" || \
  fail "准备 dbdog 用户没有核对当前生效 MD5 认证"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
PREPARE_ACTIVE_LINE="$(grep -n -m1 'agent_active_auth_is_md5 "\$index"' \
  <<<"$PREPARE_USER_BODY" | cut -d: -f1)"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
PREPARE_PASSWORD_LINE="$(grep -n -m1 'agent_monitor_password_works "\$index" "\$password"' \
  <<<"$PREPARE_USER_BODY" | cut -d: -f1)"
[ -n "$PREPARE_ACTIVE_LINE" ] && [ -n "$PREPARE_PASSWORD_LINE" ] \
  && [ "$PREPARE_ACTIVE_LINE" -lt "$PREPARE_PASSWORD_LINE" ] || \
  fail "准备 dbdog 用户没有先确认生效认证为 MD5 code=5、再提交正确密码 probe"
MAIN_BODY="$(awk '/^main\(\)/ { scan=1 } scan { print }' "$INSTALL_SCRIPT")"
PREFLIGHT_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'preflight_gaussdb_clients' | head -1 | cut -d: -f1)"
CUTOVER_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n '^  cutover$' | head -1 | cut -d: -f1)"
BOOTSTRAP_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'bootstrap_gaussdb_monitoring' | head -1 | cut -d: -f1)"
VERIFY_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n '^  start_and_verify$' | head -1 | cut -d: -f1)"
CONTRACT_MARKER_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'write_installer_contract_marker' | head -1 | cut -d: -f1)"
# 取最后一处：DBDOG_AGENT_PREFLIGHT_ONLY 是 cutover 之前就返回的只读门禁分支，它自己那句
# INSTALL_SUCCEEDED=1 不是安装事务的提交点，拿 head -1 会把它误当成提交点。
SUCCESS_LINE="$(printf '%s\n' "$MAIN_BODY" | grep -n 'INSTALL_SUCCEEDED=1' | tail -1 | cut -d: -f1)"
[ "$PREFLIGHT_LINE" -lt "$CUTOVER_LINE" ] && [ "$CUTOVER_LINE" -lt "$BOOTSTRAP_LINE" ] || \
  fail "gsql 精确预检没有发生在文件/数据库 mutation 之前"
[ "$VERIFY_LINE" -lt "$CONTRACT_MARKER_LINE" ] && [ "$CONTRACT_MARKER_LINE" -lt "$SUCCESS_LINE" ] || \
  fail "安装器 marker 没有在完整验收后、成功提交前统一写入"
[ "$(printf '%s\n' "$MAIN_BODY" | grep -c 'write_installer_contract_marker')" -eq 1 ] || \
  fail "main 没有让新旧 runtime 共用唯一的验收后 marker 写入路径"
VERIFY_BODY="$(awk '/^start_and_verify\(\)/ { scan=1 } /^main\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
STABILITY_BODY="$(awk '/^verify_agent_stability_window\(\)/ { scan=1 } /^append_agent_validation_logs\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
STABILITY_COMPARE_BODY="$(awk '/^compare_agent_stability_snapshots\(\)/ { scan=1 } /^verify_agent_stability_window\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
SNAPSHOT_BODY="$(awk '/^capture_agent_unit_snapshot\(\)/ { scan=1 } /^compare_agent_stability_snapshots\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
READINESS_BODY="$(awk '/^wait_agent_readiness\(\)/ { scan=1 } /^capture_agent_unit_snapshot\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
VALIDATION_LOG_BODY="$(awk '/^append_agent_validation_logs\(\)/ { scan=1 } /^agent_validation_has_known_runtime_error\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
LOG_CURSOR_BODY="$(awk '/^agent_log_file_identity\(\)/ { scan=1 } /^append_agent_validation_logs\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'verify_agent_stability_window "$baseline_snapshot" "$active_snapshot" "$stability_out"' <<<"$VERIFY_BODY" || \
  fail "升级验收没有进入跨采集周期稳定窗口"
grep -Fq 'elapsed" -lt 35' <<<"$STABILITY_BODY" || \
  fail "稳定窗口没有覆盖至少两个完整 15s 采集周期并保留余量"
for field in MainPID NRestarts InvocationID require_generation; do
  grep -Fq "$field" <<<"$SNAPSHOT_BODY" || fail "unit snapshot 缺少字段: $field"
done
for field in baseline_pid active_pid after_pid baseline_restarts active_restarts \
  after_restarts startup_restarts window_restart_delta baseline_invocation \
  active_invocation after_invocation; do
  grep -Fq "$field" <<<"$STABILITY_COMPARE_BODY" || \
    fail "稳定窗口缺少新生命周期进程/重启证据字段: $field"
done
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'window_restart_delta=$((after_restarts - active_restarts))' \
  <<<"$STABILITY_COMPARE_BODY" || fail "稳定窗口没有在新服务生命周期内比较 NRestarts"
if grep -Fq 'after_restarts - baseline_restarts' <<<"$STABILITY_COMPARE_BODY"; then
  fail "稳定窗口仍跨新旧服务生命周期直接相减 NRestarts"
fi
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq '"$active_restarts" -ne 0' <<<"$STABILITY_COMPARE_BODY" || \
  fail "稳定窗口会漏掉 all-active 快照前的本次启动重启"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq '"$active_invocation" != "$after_invocation"' <<<"$STABILITY_COMPARE_BODY" || \
  fail "稳定窗口没有用 InvocationID 检测服务代际变化"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'start_seconds=$SECONDS' <<<"$READINESS_BODY" || \
  fail "Agent readiness 没有按真实墙钟截止时间等待"
grep -Fq 'readiness attempt' <<<"$READINESS_BODY" || \
  fail "Agent readiness 没有逐次保留时间、耗时和退出码"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'wait_agent_readiness "$health_out" "$AGENT_HEALTH_TIMEOUT_SECONDS"' \
  <<<"$VERIFY_BODY" || fail "安装验收没有使用可配置的真实 readiness 截止时间"
grep -Fq 'AGENT_HEALTH_TIMEOUT_SECONDS=90' "$INSTALL_SCRIPT" || \
  fail "Agent readiness 默认截止时间不是 90 秒"
grep -Fq 'DBDOG_AGENT_HEALTH_TIMEOUT 必须在 30–600 秒之间' "$INSTALL_SCRIPT" || \
  fail "Agent readiness 外部覆盖没有安全上下界"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'append_agent_validation_logs "$validation_start" "$agent_log_cursor" "$validation_out"' \
  <<<"$VERIFY_BODY" || fail "readiness 失败没有保留本次启动后的有界日志差量"
if grep -Fq 'for ((i=1; i<=10; i++))' <<<"$VERIFY_BODY"; then
  fail "安装验收仍用十次快速调用冒充 60 秒 readiness 等待"
fi
BASELINE_LINE="$(grep -n -m1 'capture_agent_unit_snapshot.*baseline_snapshot.* 0' <<<"$VERIFY_BODY" | cut -d: -f1)"
LOG_CURSOR_LINE="$(grep -n -m1 'capture_agent_log_cursor.*agent_log_cursor' <<<"$VERIFY_BODY" | cut -d: -f1)"
FIRST_START_LINE="$(grep -n -m1 'systemctl start dbdog-agent-sysprobe' <<<"$VERIFY_BODY" | cut -d: -f1)"
ACTIVE_LINE="$(grep -n -m1 'capture_agent_unit_snapshot.*active_snapshot.* 1' <<<"$VERIFY_BODY" | cut -d: -f1)"
CONFIGCHECK_LINE="$(grep -n -m1 'bin/agent/agent.*configcheck' <<<"$VERIFY_BODY" | cut -d: -f1)"
[ -n "$BASELINE_LINE" ] && [ "$BASELINE_LINE" -lt "$FIRST_START_LINE" ] || \
  fail "NRestarts baseline 没有在任一 Agent unit 启动前记录"
[ -n "$LOG_CURSOR_LINE" ] && [ "$LOG_CURSOR_LINE" -lt "$FIRST_START_LINE" ] || \
  fail "agent.log dev/inode/size 游标没有在任一 Agent unit 启动前记录"
[ -n "$ACTIVE_LINE" ] && [ "$ACTIVE_LINE" -lt "$CONFIGCHECK_LINE" ] || \
  fail "四 unit active 后 PID snapshot 没有覆盖后续全部验收"
# baseline_restarts 可以是 109 等任意历史值，但只能作为诊断字段。
if grep -Eq 'after_restarts[[:space:]]*-[[:space:]]*baseline_restarts' \
  <<<"$STABILITY_COMPARE_BODY"; then
  fail "稳定窗口错误地把升级前已有的历史 NRestarts 当成当前失败"
fi

HEALTH_TEST_ROOT="$TEST_ROOT/readiness-behavior"
HEALTH_FAKE_BIN="$HEALTH_TEST_ROOT/bin"
HEALTH_STATE_FILE="$HEALTH_TEST_ROOT/attempts"
HEALTH_DIAGNOSTIC="$HEALTH_TEST_ROOT/readiness.log"
mkdir -p "$HEALTH_FAKE_BIN" "$AGENT_RUNTIME_DIR/bin/agent" "$AGENT_CONFIG_DIR" \
  "$HEALTH_TEST_ROOT/work"
cat >"$HEALTH_FAKE_BIN/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
  is-active) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$AGENT_RUNTIME_DIR/bin/agent/agent" <<'EOF'
#!/bin/sh
count=0
[ ! -f "$HEALTH_STATE_FILE" ] || count=$(cat "$HEALTH_STATE_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$HEALTH_STATE_FILE"
if [ "$count" -ge "$HEALTH_SUCCEED_AFTER" ]; then
  printf '%s\n' 'Agent health: PASS' '=== 16 healthy components ===' 'forwarder, healthcheck'
  exit 0
fi
printf '%s\n' 'Agent health: FAIL' '=== 2 healthy components ===' 'healthcheck, healthcheck' \
  '=== 14 unhealthy components ===' 'forwarder, aggregator'
exit 1
EOF
chmod 0755 "$HEALTH_FAKE_BIN/systemctl" "$AGENT_RUNTIME_DIR/bin/agent/agent"

run_readiness_behavior() { # <deadline> <success attempt> <result output>
  local deadline="$1" succeed_after="$2" result="$3"
  rm -f -- "$HEALTH_STATE_FILE" "$HEALTH_DIAGNOSTIC" "$result"
  set +e
  PATH="$HEALTH_FAKE_BIN:$FAKE_BIN:$PATH" \
    HEALTH_STATE_FILE="$HEALTH_STATE_FILE" HEALTH_SUCCEED_AFTER="$succeed_after" \
    bash -c '
      source "$1"
      trap - EXIT INT TERM HUP
      WORK_DIR="$2"
      AGENT_UNITS=(dbdog-agent.service)
      set +e
      wait_agent_readiness "$3" "$4"
      rc=$?
      set -e
      printf "rc=%s attempts=%s elapsed=%s reason=%s\n" "$rc" \
        "$AGENT_HEALTH_WAIT_ATTEMPTS" "$AGENT_HEALTH_WAIT_ELAPSED" \
        "$AGENT_HEALTH_WAIT_REASON"
      exit "$rc"
    ' bash "$INSTALL_SCRIPT" "$HEALTH_TEST_ROOT/work" "$HEALTH_DIAGNOSTIC" \
      "$deadline" >"$result" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

READY_RESULT="$HEALTH_TEST_ROOT/ready.result"
run_readiness_behavior 15 2 "$READY_RESULT" || fail "readiness 在截止时间内转绿仍被拒绝"
grep -Fq 'rc=0 attempts=2' "$READY_RESULT" || fail "readiness 没有保留真实尝试次数"
grep -Fq 'reason=ready' "$READY_RESULT" || fail "readiness 成功原因没有记录"
[ "$(grep -c '^===== readiness attempt' "$HEALTH_DIAGNOSTIC")" -eq 2 ] || \
  fail "readiness 诊断覆盖了前一次失败输出"
grep -Fq 'Agent health: FAIL' "$HEALTH_DIAGNOSTIC" || fail "readiness 缺失失败尝试"
grep -Fq 'Agent health: PASS' "$HEALTH_DIAGNOSTIC" || fail "readiness 缺失成功尝试"

DEADLINE_RESULT="$HEALTH_TEST_ROOT/deadline.result"
if run_readiness_behavior 1 99 "$DEADLINE_RESULT"; then
  fail "readiness 超过真实截止时间后仍被接受"
fi
grep -Fq 'rc=1 attempts=1' "$DEADLINE_RESULT" || fail "readiness 截止时间没有限制快速失败重试"
grep -Fq 'reason=deadline-exceeded' "$DEADLINE_RESULT" || fail "readiness 截止原因没有记录"
pass "readiness 使用真实截止时间并逐次保留失败到成功的完整证据"

STABILITY_TEST_ROOT="$TEST_ROOT/stability-generations"
mkdir -p "$STABILITY_TEST_ROOT"
printf 'dbdog-agent-sysprobe.service\t0\t32\t-\n' >"$STABILITY_TEST_ROOT/baseline"
printf 'dbdog-agent-sysprobe.service\t501235\t0\taaaa\n' >"$STABILITY_TEST_ROOT/active"
printf 'dbdog-agent-sysprobe.service\t501235\t0\taaaa\n' >"$STABILITY_TEST_ROOT/after"
run_stability_compare() { # <active> <after> <output>
  bash -c '
    source "$1"
    trap - EXIT INT TERM HUP
    compare_agent_stability_snapshots "$2" "$3" "$4" "$5"
  ' bash "$INSTALL_SCRIPT" "$STABILITY_TEST_ROOT/baseline" "$1" "$2" "$3"
}
STABLE_OUTPUT="$STABILITY_TEST_ROOT/stable.out"
: >"$STABLE_OUTPUT"
run_stability_compare "$STABILITY_TEST_ROOT/active" "$STABILITY_TEST_ROOT/after" \
  "$STABLE_OUTPUT" || fail "历史 NRestarts=32 错误污染了新生命周期稳定性"
grep -Fq 'baseline_restarts=32' "$STABLE_OUTPUT" || fail "稳定性诊断没有保留历史重启计数"
grep -Fq 'window_restart_delta=0' "$STABLE_OUTPUT" || fail "稳定性诊断没有记录新生命周期差值"

printf 'dbdog-agent-sysprobe.service\t501235\t1\tbbbb\n' >"$STABILITY_TEST_ROOT/active-restarted"
printf 'dbdog-agent-sysprobe.service\t501235\t1\tbbbb\n' >"$STABILITY_TEST_ROOT/after-restarted"
if run_stability_compare "$STABILITY_TEST_ROOT/active-restarted" \
  "$STABILITY_TEST_ROOT/after-restarted" "$STABILITY_TEST_ROOT/startup-restart.out"; then
  fail "all-active 快照前发生的本次启动重启被漏过"
fi
printf 'dbdog-agent-sysprobe.service\t501236\t1\tcccc\n' >"$STABILITY_TEST_ROOT/after-window-restart"
if run_stability_compare "$STABILITY_TEST_ROOT/active" \
  "$STABILITY_TEST_ROOT/after-window-restart" "$STABILITY_TEST_ROOT/window-restart.out"; then
  fail "稳定窗口内 PID/InvocationID/NRestarts 变化被漏过"
fi
pass "稳定性比较隔离历史计数，并拒绝新生命周期启动早期及窗口内重启"

# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq -- '--since "@$since"' <<<"$VALIDATION_LOG_BODY" || \
  fail "升级验收 journal 没有从本次启动时刻开始截取"
for field in old_dev old_inode old_size current_dev current_inode current_size; do
  grep -Fq "$field" <<<"$LOG_CURSOR_BODY" || fail "agent.log cursor 缺少身份字段: $field"
done
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'tail -c "+$start_byte"' <<<"$LOG_CURSOR_BODY" || \
  fail "升级验收 agent.log 没有按同一 inode 的启动前字节 offset 截取新增内容"
grep -Fq 'cursor_mode=rename_create' <<<"$LOG_CURSOR_BODY" || \
  fail "升级验收没有区分 rename/create 日志轮转"
grep -Fq 'cursor_mode=copytruncate' <<<"$LOG_CURSOR_BODY" || \
  fail "升级验收没有区分 copytruncate 日志轮转"
grep -Fq 'prefix_tail_signature' <<<"$LOG_CURSOR_BODY" || \
  fail "升级验收无法识别同 inode 截断后快速重长超过旧 offset"

LOG_CURSOR_ROOT="$TEST_ROOT/log-cursor"
mkdir -p "$LOG_CURSOR_ROOT/log"
# shellcheck disable=SC2016 # 子 shell 脚本中的变量由被测运行环境展开。
if ! env AGENT_LOG_DIR="$LOG_CURSOR_ROOT/log" bash -c '
  set -euo pipefail
  source "$1"
  trap - EXIT INT TERM HUP
  root="$2"
  log="$AGENT_LOG_DIR/agent.log"
  cursor="$root/cursor"

  printf "historic-normal\n" >"$log"
  capture_agent_log_cursor "$cursor"
  printf "normal-new\n" >>"$log"
  append_agent_log_from_cursor "$cursor" "$root/normal.out"
  grep -Fq "cursor_mode=same_inode_append" "$root/normal.out"
  grep -Fq "normal-new" "$root/normal.out"
  ! grep -Fq "historic-normal" "$root/normal.out"

  printf "historic-rotate\n" >"$log"
  capture_agent_log_cursor "$cursor"
  printf "old-inode-new\n" >>"$log"
  mv "$log" "$AGENT_LOG_DIR/agent.log.1"
  printf "replacement-new\n" >"$log"
  append_agent_log_from_cursor "$cursor" "$root/rename.out"
  grep -Fq "cursor_mode=rename_create" "$root/rename.out"
  grep -Fq "old-inode-new" "$root/rename.out"
  grep -Fq "replacement-new" "$root/rename.out"
  ! grep -Fq "historic-rotate" "$root/rename.out"

  printf "historic-copytruncate-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" >"$log"
  capture_agent_log_cursor "$cursor"
  printf "copytruncate-before-rotate\n" >>"$log"
  cp "$log" "$AGENT_LOG_DIR/agent.log.2"
  : >"$log"
  printf "copytruncate-after-rotate\n" >"$log"
  append_agent_log_from_cursor "$cursor" "$root/copytruncate.out"
  grep -Fq "cursor_mode=copytruncate" "$root/copytruncate.out"
  grep -Fq "copytruncate-before-rotate" "$root/copytruncate.out"
  grep -Fq "copytruncate-after-rotate" "$root/copytruncate.out"
  ! grep -Fq "historic-copytruncate" "$root/copytruncate.out"

  printf "historic-regrow\n" >"$log"
  capture_agent_log_cursor "$cursor"
  printf "regrown-before-rotate\n" >>"$log"
  cp "$log" "$AGENT_LOG_DIR/agent.log.3"
  : >"$log"
  printf "copytruncate-regrown-new-content-longer-than-before\n" >"$log"
  append_agent_log_from_cursor "$cursor" "$root/regrown.out"
  grep -Fq "cursor_mode=copytruncate_regrown" "$root/regrown.out"
  grep -Fq "regrown-before-rotate" "$root/regrown.out"
  grep -Fq "copytruncate-regrown-new-content" "$root/regrown.out"
  ! grep -Fq "historic-regrow" "$root/regrown.out"

  printf "historic-unprovable\n" >"$log"
  capture_agent_log_cursor "$cursor"
  : >"$log"
  printf "unprovable-current-new\n" >"$log"
  if append_agent_log_from_cursor "$cursor" "$root/unprovable.out"; then
    exit 91
  fi
  grep -Fq "unprovable-current-new" "$root/unprovable.out"
  grep -Fq "cursor_continuity=false" "$root/unprovable.out"

  printf "historic-ambiguous-copytruncate-xxxxxxxxxxxxxxxx\n" >"$log"
  capture_agent_log_cursor "$cursor"
  printf "ambiguous-before-rotate\n" >>"$log"
  cp "$log" "$AGENT_LOG_DIR/agent.log.ambiguous.1"
  cp "$log" "$AGENT_LOG_DIR/agent.log.ambiguous.2"
  : >"$log"
  printf "ambiguous-current\n" >"$log"
  if append_agent_log_from_cursor "$cursor" "$root/ambiguous.out"; then
    exit 92
  fi
  grep -Fq "copytruncate rotation candidate count=" "$root/ambiguous.out"
  grep -Fq "(required=1)" "$root/ambiguous.out"
' bash "$INSTALL_SCRIPT" "$LOG_CURSOR_ROOT"; then
  fail "agent.log dev/inode/size cursor 的追加/轮转合同失败"
fi
pass "agent.log 游标在 append、rename/create、copytruncate 与截断后重长场景均不漏读新日志"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq 'agent_validation_has_known_runtime_error "$check_out" "$validation_out"' <<<"$VERIFY_BODY" || \
  fail "升级验收没有同时扫描本次 check 输出和本次启动日志差量"
for pattern in 'Function age\(xid32\) does not exist' \
  'operator does not exist:' 'Unable to collect statement metrics due to an error' \
  'GaussDB query scope failed:' 'error:query-scope-' 'database-metadata' \
  'preventSegmentMajorPageFault'; do
  grep -Fq "$pattern" "$SCRIPTS_DIR/agent-lib.sh" || fail "已知运行错误合同缺少: $pattern"
done
KNOWN_PATTERN="$(agent_known_runtime_error_pattern)"
for category in undefined-function programming-error database-error; do
  printf 'GaussDB query scope failed: scope=replication category=%s query_sha256=%064d\n' \
    "$category" 0 | grep -Eq "$KNOWN_PATTERN" || \
    fail "升级验收不识别 Core 安全 query-scope 错误类别: $category"
  printf 'metric tag error:query-scope-%s,scope:replication\n' "$category" \
    | grep -Eq "$KNOWN_PATTERN" || fail "升级验收不识别 query-scope 指标 tag: $category"
done
if printf '%s\n' 'GaussDB query scope failed: scope=replication category=feature-not-supported' \
    | grep -Eq "$KNOWN_PATTERN"; then
  fail "升级验收错误地把可降级 feature-not-supported 当作致命 SQL 故障"
fi
grep -Fq -- '-n 1001' <<<"$VALIDATION_LOG_BODY" || \
  fail "升级验收 journal 没有用额外一行识别截断"
grep -Fq 'head -c 1048577' <<<"$VALIDATION_LOG_BODY" || \
  fail "升级验收 journal 没有字节硬上限"
grep -Fq 'journal_complete=false' <<<"$VALIDATION_LOG_BODY" || \
  fail "升级验收 journal 缺失/截断没有 fail closed"
grep -Fq 'dbdogctl diagnose dbdog-agent' <<<"$VERIFY_BODY" || \
  fail "升级验收失败没有给出正式 Agent 诊断入口"
# shellcheck disable=SC2016 # 静态匹配被测脚本中的字面量变量引用。
grep -Fq '一键诊断: sudo ${SCRIPT_DIR}/dbdogctl diagnose dbdog-agent' <<<"$MAIN_BODY" || \
  fail "升级成功输出没有给出正式 Agent 诊断入口"
pass "从启动前到跨两个采集周期结束核对 PID/NRestarts，并只扫描本次新增日志中的已知 SQL/metadata 错误"
PREPARE_BODY="$(awk '/^prepare_runtime\(\)/ { scan=1 } /^write_installer_contract_marker\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
# shellcheck disable=SC2016 # 静态检查安装脚本中的字面量变量引用。
if printf '%s\n' "$PREPARE_BODY" \
  | grep -Eq 'AGENT_INSTALLER_CONTRACT_MARKER|\.dbdog-installer-contract-sha256'; then
  fail "prepare_runtime/staging 仍会在完整验收前预置安装器 marker"
fi

ARCHIVE_ROOT="$TEST_ROOT/archive-contract/root"
ARCHIVE_WORK="$TEST_ROOT/archive-contract/work"
mkdir -p "$ARCHIVE_ROOT/provenance" "$ARCHIVE_ROOT/bin/agent" "$ARCHIVE_ROOT/embedded/bin" \
  "$ARCHIVE_WORK"
for required in \
  .install_root \
  provenance/build.txt \
  provenance/agent-version.txt \
  provenance/gaussdb.txt \
  version-manifest.txt \
  version-manifest.json \
  bin/agent/agent \
  embedded/bin/trace-loader \
  embedded/bin/trace-agent \
  embedded/bin/process-agent \
  embedded/bin/system-probe; do
  : >"$ARCHIVE_ROOT/$required"
done
tar -czf "$TEST_ROOT/archive-contract/clean.tar.gz" -C "$ARCHIVE_ROOT" .
run_archive_contract() { # <tarball>
  bash -c '
    source "$1"
    trap - EXIT
    WORK_DIR="$2"
    validate_archive_members "$3"
  ' bash "$INSTALL_SCRIPT" "$ARCHIVE_WORK" "$1"
}
run_archive_contract "$TEST_ROOT/archive-contract/clean.tar.gz" || \
  fail "不含 installer marker 的合法成员清单被拒绝"
printf '%064d\n' 0 >"$ARCHIVE_ROOT/$AGENT_INSTALLER_CONTRACT_MARKER"
tar -czf "$TEST_ROOT/archive-contract/forged-marker.tar.gz" -C "$ARCHIVE_ROOT" .
if run_archive_contract "$TEST_ROOT/archive-contract/forged-marker.tar.gz" \
  >"$TEST_ROOT/archive-contract/forged-marker.out" 2>&1; then
  fail "错误接受了预置 installer marker 的 Agent tarball"
fi
grep -Fq '不得预置安装器验收 marker' "$TEST_ROOT/archive-contract/forged-marker.out" || \
  fail "tarball 保留 marker 被拒绝时没有给出明确错误"
pass "tarball 与 staging 均不能预置 installer marker，所有 runtime 只在完整验收后统一写入"
RECOVERY_BASE="$TEST_ROOT/recovery/etc/dbdog-agent"
mkdir -p "$RECOVERY_BASE.failed.20260727010101" "$RECOVERY_BASE.failed.20260727020202"
RECOVERED="$(PATH="$FAKE_BIN:$PATH" bash -c '
  source "$1"
  trap - EXIT
  AGENT_CONFIG_DIR="$2"
  latest_failed_agent_config
' bash "$INSTALL_SCRIPT" "$RECOVERY_BASE")" || fail "无法发现首装失败配置"
[ "$RECOVERED" = "$RECOVERY_BASE.failed.20260727020202" ] || fail "没有选择最新首装失败配置"
pass "认证/HBA 前置条件只读 fail closed，已有账号不刷密码且诊断可追溯"

PREFLIGHT_ROOT="$TEST_ROOT/preflight"
mkdir -p "$PREFLIGHT_ROOT/bin" "$PREFLIGHT_ROOT/work"
printf '# DBA managed\nhost all dbdog 127.0.0.1/32 md5\n' >"$PREFLIGHT_ROOT/pg_hba.conf"
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
  'SHOW hba_file;') printf '%s\n' "${root%/bin}/pg_hba.conf" ;;
  *pg_user*) cat "$root/exists" ;;
  '')
    cat >"$root/stdin.sql"
    ;;
  *) printf '1\n' ;;
esac
EOF
cat >"$PREFLIGHT_ROOT/bin/fake-python" <<'EOF'
#!/bin/sh
root=$(dirname "$0")
program="$root/last-python-program"
cat >"$program"
printf 'python-args=%s\n' "$*" >>"$root/calls"
if grep -Fq 'authentication_code != 5' "$program"; then
  printf 'active-md5-probe\n' >>"$root/calls"
  [ ! -f "$root/reject-active-md5" ] || exit 91
  exit 0
fi
if grep -Fq 'psycopg.connect' "$program"; then
  printf 'correct-password-probe\n' >>"$root/calls"
  [ ! -f "$root/reject-password" ] || exit 42
  exit 0
fi
exit 96
EOF
chmod 0755 "$PREFLIGHT_ROOT/bin/ldd" "$PREFLIGHT_ROOT/bin/gsql" \
  "$PREFLIGHT_ROOT/bin/fake-python"
cp "$FAKE_BIN/timeout" "$PREFLIGHT_ROOT/bin/timeout"
printf '1\n' >"$PREFLIGHT_ROOT/bin/mode"
printf '1\n' >"$PREFLIGHT_ROOT/bin/exists"

run_fake_gauss_action() { # <preflight|active-auth|ensure-user>
  PATH="$FAKE_BIN:$PATH" bash -c '
    source "$1"
    trap - EXIT
    WORK_DIR="$2/work"
    DBDOG_GAUSSDB_DBNAME=postgres
    DBDOG_GAUSSDB_MONITOR_PASSWORD=Aa1_valid_monitor_password
    DBDOG_AGENT_PYTHON="$2/bin/fake-python"
    AGENT_GAUSS_PID_PORTS=(15432)
    AGENT_GAUSS_PID_DATA_DIRS=("$2")
    AGENT_GAUSS_PID_HOMES=("$2")
    AGENT_GAUSS_PID_OWNERS=("$(id -un)")
    AGENT_GAUSS_PID_OWNER_HOMES=("$2")
    AGENT_GAUSS_PID_HOSTS=("$2/socket")
    AGENT_GAUSS_PID_LD_LIBRARY_PATHS=("$2/lib:$2/lib/libsimsearch")
    AGENT_GAUSS_PID_PATHS=("$2/bin:/usr/bin:/bin")
    AGENT_GAUSS_PID_GSQLS=("$2/bin/gsql")
    # 分类事实：本夹具模拟的是真 GaussDB 实例（分类由 agent_classify_gauss_engines 产出）。
    AGENT_GAUSS_PID_ENGINES=(gaussdb)
    AGENT_GAUSSDB_RENDER_PORTS=(15432)
    case "$3" in
      preflight)
        preflight_gaussdb_clients
        printf "PREFLIGHT=ok\n"
        ;;
      active-auth)
        agent_active_auth_is_md5 0
        ;;
      ensure-user)
        agent_prepare_gaussdb_user "$DBDOG_GAUSSDB_MONITOR_PASSWORD"
        ;;
    esac
  ' bash "$INSTALL_SCRIPT" "$PREFLIGHT_ROOT" "$1"
}

assert_active_md5_precedes_password_probe() {
  local password_line active_line
  password_line="$(grep -n -m1 'correct-password-probe' "$PREFLIGHT_ROOT/bin/calls" | cut -d: -f1)"
  active_line="$(grep -n -m1 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls" | cut -d: -f1)"
  [ -n "$password_line" ] && [ -n "$active_line" ] && [ "$active_line" -lt "$password_line" ] || \
    fail "准备 dbdog 用户没有先验证当前生效 MD5 code=5、再提交真实正确密码"
}

PREFLIGHT_OUTPUT="$(run_fake_gauss_action preflight)" || fail "模拟 gsql 精确预检失败"
printf '%s\n' "$PREFLIGHT_OUTPUT" | grep -Fqx 'PREFLIGHT=ok' || fail "合法认证/HBA 合同预检未完成"
grep -Fq "PGHOST=$PREFLIGHT_ROOT/socket" "$PREFLIGHT_ROOT/bin/calls" || fail "gsql 未收到实例 PGHOST"
grep -Fq "LD_LIBRARY_PATH=$PREFLIGHT_ROOT/lib:$PREFLIGHT_ROOT/lib/libsimsearch" \
  "$PREFLIGHT_ROOT/bin/calls" || fail "gsql 未收到实例 LD_LIBRARY_PATH"
grep -Fq 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "已有监控用户的 mutation 前预检没有验证当前生效 MD5 code=5"
if grep -Fq 'correct-password-probe' "$PREFLIGHT_ROOT/bin/calls"; then
  fail "只读预检错误提交了数据库密码"
fi

# 不存在的角色可能收到服务端防用户名枚举用的模拟 SASL challenge；新用户必须等
# mode=1 下创建出真实 verifier 后再判断 code=5，不能在只读预检阶段误拒。
printf '0\n' >"$PREFLIGHT_ROOT/bin/exists"
touch "$PREFLIGHT_ROOT/bin/reject-active-md5"
: >"$PREFLIGHT_ROOT/bin/calls"
run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/fresh-user-preflight.out" 2>&1 || \
  fail "全新监控用户被创建前的模拟认证 challenge 错误阻塞"
if grep -Fq 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls"; then
  fail "全新监控用户在 verifier 创建前被错误执行生效认证探测"
fi
rm -f -- "$PREFLIGHT_ROOT/bin/reject-active-md5"
printf '1\n' >"$PREFLIGHT_ROOT/bin/exists"
: >"$PREFLIGHT_ROOT/bin/calls"
run_fake_gauss_action active-auth >/dev/null || fail "AuthenticationRequest code=5 主动握手探测失败"
grep -Fq 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "agent_active_auth_is_md5 没有执行最小 StartupMessage 探测"
if grep -Fq 'correct-password-probe' "$PREFLIGHT_ROOT/bin/calls"; then
  fail "主动认证类型探测错误提交了数据库密码"
fi
touch "$PREFLIGHT_ROOT/bin/reject-active-md5"
if run_fake_gauss_action active-auth >"$PREFLIGHT_ROOT/active-auth-rejected.out" 2>&1; then
  fail "非 MD5 的生效认证握手被错误接受"
fi
grep -Fq '不是 MD5' "$PREFLIGHT_ROOT/active-auth-rejected.out" || \
  fail "非 MD5 认证失败没有明确指出生效认证类型不兼容"
if grep -Eq '密码|摘要' "$PREFLIGHT_ROOT/active-auth-rejected.out"; then
  fail "非 MD5 认证失败被错误归类为密码/摘要问题"
fi
rm -f -- "$PREFLIGHT_ROOT/bin/reject-active-md5"

rm -f -- "$PREFLIGHT_ROOT/bin/stdin.sql" "$PREFLIGHT_ROOT/bin/reject-password"
: >"$PREFLIGHT_ROOT/bin/calls"
run_fake_gauss_action ensure-user >/dev/null || fail "已有用户的保存密码真实 TCP 探测失败"
grep -Fq 'correct-password-probe' "$PREFLIGHT_ROOT/bin/calls" || fail "内嵌 psycopg 密码验收没有执行"
grep -Fq 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "已有用户密码探测前没有核对当前生效 MD5 认证"
assert_active_md5_precedes_password_probe
grep -Fq ' 15432 postgres' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "内嵌 psycopg 验收没有使用目标实例 TCP 端口"
grep -Fqx 'ALTER USER dbdog WITH MONADMIN;' "$PREFLIGHT_ROOT/bin/stdin.sql" || \
  fail "已有用户验证通过后没有幂等确保 MONADMIN"
if grep -Eq 'ALTER[[:space:]]+USER.*PASSWORD' "$PREFLIGHT_ROOT/bin/stdin.sql"; then
  fail "已有用户密码有效时安装器仍执行 ALTER PASSWORD"
fi

touch "$PREFLIGHT_ROOT/bin/reject-password"
rm -f -- "$PREFLIGHT_ROOT/bin/stdin.sql"
if run_fake_gauss_action ensure-user >"$PREFLIGHT_ROOT/existing-password-rejected.out" 2>&1; then
  fail "已有用户保存密码被拒绝时安装器没有 fail closed"
fi
grep -Eq '(code=5|生效 MD5 challenge).*(密码|摘要|verifier)|(密码|摘要|verifier).*(code=5|MD5 challenge)' \
  "$PREFLIGHT_ROOT/existing-password-rejected.out" || \
  fail "MD5 code=5 后的登录拒绝没有明确归类为密码/摘要问题"
if grep -Fq '不是 MD5' "$PREFLIGHT_ROOT/existing-password-rejected.out"; then
  fail "MD5 code=5 后的密码/摘要失败被错误归类为非 MD5"
fi
if [ -f "$PREFLIGHT_ROOT/bin/stdin.sql" ] \
  && grep -Eq 'ALTER[[:space:]]+USER.*PASSWORD' "$PREFLIGHT_ROOT/bin/stdin.sql"; then
  fail "已有用户保存密码被拒绝后安装器擅自 ALTER PASSWORD"
fi
rm -f -- "$PREFLIGHT_ROOT/bin/reject-password" "$PREFLIGHT_ROOT/bin/stdin.sql"

printf '0\n' >"$PREFLIGHT_ROOT/bin/exists"
: >"$PREFLIGHT_ROOT/bin/calls"
run_fake_gauss_action ensure-user >/dev/null || fail "缺少 dbdog 用户时无法首创并做 TCP 验收"
grep -Eq "^CREATE USER dbdog WITH MONADMIN PASSWORD '[^']+';$" \
  "$PREFLIGHT_ROOT/bin/stdin.sql" || fail "首装没有创建 dbdog MONADMIN 密码用户"
grep -Fq 'correct-password-probe' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "首创 dbdog 用户后没有执行真实 TCP 驱动探测"
grep -Fq 'active-md5-probe' "$PREFLIGHT_ROOT/bin/calls" || \
  fail "首创 dbdog 用户密码探测前没有核对当前生效 MD5 认证"
assert_active_md5_precedes_password_probe
printf '1\n' >"$PREFLIGHT_ROOT/bin/exists"

for rejected_mode in 0 2 3 4; do
  printf '%s\n' "$rejected_mode" >"$PREFLIGHT_ROOT/bin/mode"
  if run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/mode-$rejected_mode.out" 2>&1; then
    fail "认证合同错误接受 password_encryption_type=$rejected_mode（必须恰好为 1）"
  fi
  grep -Fq "当前为 $rejected_mode" \
    "$PREFLIGHT_ROOT/mode-$rejected_mode.out" || \
    fail "password_encryption_type=$rejected_mode 未给出清晰错误"
done
printf '1\n' >"$PREFLIGHT_ROOT/bin/mode"

printf '%s\n' \
  'host all dbdog 127.0.0.1/32 md5' \
  'local all dbdog trust' >"$PREFLIGHT_ROOT/pg_hba.conf"
run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/local-trust.out" 2>&1 || \
  fail "精确 TCP MD5 之后、与运行端点无关的 local trust 被错误拒绝"

printf '%s\n' \
  'host all dbdog 127.0.0.1/32 md5' \
  'host all dbdog 127.0.0.1/32 trust' >"$PREFLIGHT_ROOT/pg_hba.conf"
run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/host-trust.out" 2>&1 || \
  fail "精确 TCP MD5 之后不会生效的 host trust 被静态扫描错误拒绝"

printf '%s\n' \
  'host all dbdog 127.0.0.1/32 md5' \
  'host all all 127.0.0.1/32 trust' >"$PREFLIGHT_ROOT/pg_hba.conf"
run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/broad-trust-after.out" 2>&1 || \
  fail "精确 TCP MD5 之后不会生效的 all-user trust 被静态扫描错误拒绝"

# 静态文件中即使存在精确 MD5，前面的宽泛 trust 仍会先匹配；真实握手才是
# include/顺序解析后的最终事实。fake-python 的拒绝标记模拟服务端返回非 code=5。
printf '%s\n' \
  'host all all 127.0.0.1/32 trust' \
  'host all dbdog 127.0.0.1/32 md5' >"$PREFLIGHT_ROOT/pg_hba.conf"
touch "$PREFLIGHT_ROOT/bin/reject-active-md5"
if run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/broad-trust-before.out" 2>&1; then
  fail "预检错误接受了被前置宽泛规则覆盖的精确 MD5"
fi
rm -f -- "$PREFLIGHT_ROOT/bin/reject-active-md5"

printf '# missing exact dbdog rule\nhost all all 127.0.0.1/32 md5\n' \
  >"$PREFLIGHT_ROOT/pg_hba.conf"
if run_fake_gauss_action preflight >"$PREFLIGHT_ROOT/missing-md5.out" 2>&1; then
  fail "预检错误接受了缺少精确 dbdog TCP MD5 规则的 HBA"
fi
pass "先用最小 StartupMessage 验证 MD5 code=5，再提交正确密码并区分失败类型"

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

# 每库初始化工具必须随包落到 DB 主机固定路径：控制台「采集配置」页按该绝对路径给命令，
# 路径/文件名一变，页面上的命令就指向不存在的文件（dbdog-web DB_INIT_SCRIPT_DIR）。
for engine_assets in \
  'gaussdb:init-dbdog-user-gaussdb-all-databases.sh:init-gaussdb-perdb.sql:GAUSSDB' \
  'pg:init-dbdog-user-pg-all-databases.sh:init-dbdog-user-pg-perdb.sql:PG' \
  'opengauss:init-dbdog-user-opengauss-all-databases.sh:init-dbdog-user-opengauss-perdb.sql:OPENGAUSS'; do
  IFS=: read -r ENGINE PERDB_TOOL_NAME PERDB_SQL_NAME ENGINE_ENV <<<"$engine_assets"
  PERDB_TOOL="$SCRIPTS_DIR/agent/$PERDB_TOOL_NAME"
  [ -f "$PERDB_TOOL" ] || fail "发布包缺少 $ENGINE 每库 DBM 初始化脚本"
  [ -x "$PERDB_TOOL" ] || fail "$ENGINE 每库 DBM 初始化脚本不可执行"
  [ -f "$SCRIPTS_DIR/agent/$PERDB_SQL_NAME" ] || fail "发布包缺少 $ENGINE 每库对象 SQL"
  grep -Fq "PERDB_SQL=\${${ENGINE_ENV}_PERDB_SQL:-\$SCRIPT_DIR/$PERDB_SQL_NAME}" "$PERDB_TOOL" || \
    fail "$ENGINE 每库初始化脚本默认没有指向随包同目录的每库 SQL"
  grep -Fq "/opt/dbdog-agent/scripts/$PERDB_TOOL_NAME" "$PERDB_TOOL" || \
    fail "$ENGINE 每库初始化脚本的 usage 没有给出落盘绝对路径"
  grep -Fq -e '--check' "$PERDB_TOOL" || fail "$ENGINE 每库初始化脚本缺少只读验收开关"
  grep -Fq -e '--exclude' "$PERDB_TOOL" || fail "$ENGINE 每库初始化脚本缺少跳过指定库的开关"
  grep -Fq "$PERDB_TOOL_NAME:$PERDB_SQL_NAME" "$SCRIPTS_DIR/agent-install.sh" || \
    fail "安装器没有把 $ENGINE 那套列进随包安装清单"
done
# GaussDB/openGauss 的 canonical explain 入口在 public（SECURITY DEFINER 按函数所属 schema
# 解析未限定表名）；PostgreSQL 在 dbdog schema。验收断言必须各按各的，不许折叠。
grep -Fq "nspname = 'public' AND p.proname = 'dbdog_explain_statement'" \
  "$SCRIPTS_DIR/agent/init-dbdog-user-gaussdb-all-databases.sh" || \
  fail "GaussDB 每库初始化脚本的验收没有检查 public explain 入口"
grep -Fq "nspname = 'public' AND p.proname = 'dbdog_explain_statement'" \
  "$SCRIPTS_DIR/agent/init-dbdog-user-opengauss-all-databases.sh" || \
  fail "openGauss 每库初始化脚本的验收没有检查 public explain 入口"
grep -Fq "nspname = 'dbdog' AND p.proname = 'explain_statement'" \
  "$SCRIPTS_DIR/agent/init-dbdog-user-pg-all-databases.sh" || \
  fail "PostgreSQL 每库初始化脚本的验收没有检查 dbdog schema 的 explain 入口"
grep -Fq 'install_dbm_init_scripts' "$SCRIPTS_DIR/agent-install.sh" || \
  fail "安装器没有安装每库 DBM 初始化工具"
grep -Fq 'local target="$AGENT_RUNTIME_DIR/scripts"' "$SCRIPTS_DIR/agent-install.sh" || \
  fail "每库初始化工具没有落到 runtime 树下的 scripts 目录"
awk '/^main\(\) \{/,/^\}/' "$SCRIPTS_DIR/agent-install.sh" \
  | grep -Fq 'install_dbm_init_scripts' || \
  fail "安装主流程没有调用 install_dbm_init_scripts"
awk '/^main\(\) \{/,/^\}/' "$SCRIPTS_DIR/agent-install.sh" \
  | grep -n 'cutover\|install_dbm_init_scripts' \
  | awk -F: 'NR==1 && $2 !~ /cutover/ { exit 1 }' || \
  fail "每库初始化工具必须在 cutover 之后安装（整树替换会覆盖）"

# per-db SQL 的源在 dbdog-agent（那边的 docker harness sandbox-test.sh 和 wire 契约测试直接
# 消费），本仓存的是随包镜像。镜像与源必须逐字节一致，否则「DB 主机上跑的 DDL」会和研发仓
# 里改的那份悄悄分家——GaussDB 那对已经这样漂过（见下面登记的例外）。
DEPLOY_SCRIPTS="$RELEASE_DIR/../dbdog-agent/dbdog-deploy/scripts"
if [ -d "$DEPLOY_SCRIPTS" ]; then
  for mirrored in init-dbdog-user-pg-perdb.sql init-dbdog-user-opengauss-perdb.sql; do
    [ -f "$DEPLOY_SCRIPTS/$mirrored" ] || fail "dbdog-agent 侧缺少每库 SQL 源: $mirrored"
    cmp -s "$DEPLOY_SCRIPTS/$mirrored" "$SCRIPTS_DIR/agent/$mirrored" || \
      fail "随包镜像与 dbdog-agent 源不一致: $mirrored（改了源就要同步本仓镜像）"
  done
  # 登记的已知例外：init-gaussdb-perdb.sql 与 dbdog-agent 的
  # init-dbdog-user-gaussdb-perdb.sql 已漂移（本仓仍建 statements/activity 兼容视图、缺
  # GRANT USAGE ON SCHEMA public）。合并方向取决于现网 runtime 是否已含内联 collector，
  # 未实证前不动；本行即差异登记，收敛后一并纳入上面的逐字节校验。
  pass "每库 SQL 随包镜像与 dbdog-agent 源逐字节一致（GaussDB 那对为已登记的待收敛差异）"
else
  printf 'NOTE: 未检出兄弟目录 dbdog-agent，跳过每库 SQL 镜像一致性校验\n' >&2
fi
CURRENT_AGENT_ARTIFACT="$(manifest_get dbdog-agent 6)"
CURRENT_AGENT_VERSION="$(manifest_get dbdog-agent 5)"
if [ -f "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" ]; then
  tar -tzf "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" \
    | grep -Eq '^\./(embedded/)?bin/(gsql|gaussdb)$' && \
    fail "Agent 产物错误打包了目标 GaussDB 的 gsql/gaussdb"
  tar -tzf "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" \
    | grep -Fqx "./$AGENT_INSTALLER_CONTRACT_MARKER" && \
    fail "Agent 当前产物错误预置了安装器验收 marker"
  tar -xOf "$RELEASE_DIR/scratch/$CURRENT_AGENT_ARTIFACT" ./provenance/build.txt \
    | grep -Fqx "version=$CURRENT_AGENT_VERSION" || \
    fail "Agent 当前产物 provenance 版本与 manifest 不一致"
fi
pass "安装器要求预编译 GaussDB integration + psycopg/libpq，运行期不走 gsql 短连接"

VERSION_RUNTIME="$TEST_ROOT/version-runtime"
VERSION_FAKE_BIN="$TEST_ROOT/version-fake-bin"
VERSION_WORK="$TEST_ROOT/version-work"
VERSION_EXPECTED=7.81.0-dbdog.1
VERSION_ARTIFACT_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
VERSION_OUTPUT="Agent $VERSION_EXPECTED - Commit: 4c39489b8c - Serialization version: v5.0.198 - Go version: go1.26.4"
mkdir -p "$VERSION_RUNTIME/bin/agent" "$VERSION_RUNTIME/embedded/bin" \
  "$VERSION_RUNTIME/embedded/lib/python3.13/site-packages/datadog_checks/gaussdb" \
  "$VERSION_RUNTIME/embedded/lib/python3.13/site-packages/datadog_gaussdb-1.0.0.dist-info" \
  "$VERSION_RUNTIME/embedded/lib/python3.13/site-packages/psycopg_c.libs" \
  "$VERSION_RUNTIME/provenance" "$VERSION_FAKE_BIN" "$VERSION_WORK"
: >"$VERSION_RUNTIME/.install_root"
: >"$VERSION_RUNTIME/embedded/lib/python3.13/site-packages/datadog_checks/gaussdb/__init__.py"
: >"$VERSION_RUNTIME/embedded/lib/python3.13/site-packages/psycopg_c.libs/libpq-test.so"

cat >"$VERSION_FAKE_BIN/file" <<'EOF'
#!/bin/sh
printf '%s: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked\n' "$1"
EOF
chmod 0755 "$VERSION_FAKE_BIN/file"

write_fake_agent_version() { # <binary 自报版本>
  cat >"$VERSION_RUNTIME/bin/agent/agent" <<EOF
#!/bin/sh
[ "\${1:-}" = version ] || exit 64
runtime_tree="\${0%/bin/agent/agent}"
expected_ld="\$runtime_tree/embedded/lib"
[ ! -d "\$runtime_tree/embedded/lib64" ] || expected_ld="\$expected_ld:\$runtime_tree/embedded/lib64"
if [ "\${LD_LIBRARY_PATH-}" != "\$expected_ld" ]; then
  printf 'unexpected runtime LD_LIBRARY_PATH: expected=%s actual=%s\n' \
    "\$expected_ld" "\${LD_LIBRARY_PATH-<unset>}" >&2
  exit 65
fi
printf '%s\n' 'Agent $1 - Commit: 4c39489b8c - Serialization version: v5.0.198 - Go version: go1.26.4'
EOF
  chmod 0755 "$VERSION_RUNTIME/bin/agent/agent"
}

for binary in trace-loader trace-agent process-agent system-probe; do
  printf '#!/bin/sh\nexit 0\n' >"$VERSION_RUNTIME/embedded/bin/$binary"
  chmod 0755 "$VERSION_RUNTIME/embedded/bin/$binary"
done
write_fake_agent_version "$VERSION_EXPECTED"

cat >"$VERSION_RUNTIME/provenance/gaussdb.txt" <<'EOF'
module_path=./embedded/lib/python3.13/site-packages/datadog_checks/gaussdb/__init__.py
distribution_path=./embedded/lib/python3.13/site-packages/datadog_gaussdb-1.0.0.dist-info
EOF
cat >"$VERSION_RUNTIME/version-manifest.txt" <<EOF
agent $VERSION_EXPECTED
datadog-agent $VERSION_EXPECTED
EOF
printf '{"build_version":"%s"}\n' "$VERSION_EXPECTED" >"$VERSION_RUNTIME/version-manifest.json"

fixture_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

VERSION_BINARY_SHA="$(fixture_sha256 "$VERSION_RUNTIME/bin/agent/agent")"
VERSION_TEXT_SHA="$(fixture_sha256 "$VERSION_RUNTIME/version-manifest.txt")"
VERSION_JSON_SHA="$(fixture_sha256 "$VERSION_RUNTIME/version-manifest.json")"
printf '%s\n' "$VERSION_OUTPUT" >"$VERSION_WORK/version-output"
VERSION_OUTPUT_SHA="$(fixture_sha256 "$VERSION_WORK/version-output")"
cat >"$VERSION_RUNTIME/provenance/build.txt" <<EOF
product=dbdog-agent
version=$VERSION_EXPECTED
compiled_agent_version=$VERSION_EXPECTED
architecture=aarch64
install_prefix=$VERSION_RUNTIME
agent_binary_sha256=$VERSION_BINARY_SHA
agent_version_output_sha256=$VERSION_OUTPUT_SHA
agent_version_manifest_text_sha256=$VERSION_TEXT_SHA
agent_version_manifest_json_sha256=$VERSION_JSON_SHA
EOF
cat >"$VERSION_RUNTIME/provenance/agent-version.txt" <<EOF
compiled_version=$VERSION_EXPECTED
manifest_header_version=$VERSION_EXPECTED
manifest_component_version=$VERSION_EXPECTED
manifest_json_version=$VERSION_EXPECTED
binary_path=./bin/agent/agent
binary_sha256=$VERSION_BINARY_SHA
version_output=$VERSION_OUTPUT
version_output_sha256=$VERSION_OUTPUT_SHA
version_manifest_text_path=./version-manifest.txt
version_manifest_text_sha256=$VERSION_TEXT_SHA
version_manifest_json_path=./version-manifest.json
version_manifest_json_sha256=$VERSION_JSON_SHA
EOF
printf '%s\n' "$VERSION_EXPECTED" >"$VERSION_RUNTIME/.dbdog-release-version"
printf '%s\n' "$VERSION_ARTIFACT_SHA" >"$VERSION_RUNTIME/.dbdog-artifact-sha256"

run_version_contract() { # <validate|prepare>
  LD_LIBRARY_PATH=/evil AGENT_RUNTIME_DIR="$VERSION_RUNTIME" AGENT_RUN_DIR="$VERSION_RUNTIME/run" \
    DBDOG_TIMEOUT_BIN="$FAKE_BIN/timeout" PATH="$VERSION_FAKE_BIN:$PATH" \
    bash -c '
      source "$1"
      trap - EXIT
      WORK_DIR="$2"
      # require_root_host 在真实流程里调用 host_arch 并落 AGENT_HOST_ARCH；这里
      # 只单独测 validate_runtime_tree/prepare_runtime，绕开 root/systemd 前提，
      # 直接按 fixture 的 provenance architecture=aarch64 设定同一个全局。
      AGENT_HOST_ARCH=aarch64
      case "$3" in
        validate) validate_runtime_tree "$AGENT_RUNTIME_DIR" "$4" ;;
        prepare)
          prepare_runtime "$2/not-used.tar.gz" "$4" "$5"
          printf "RUNTIME_CHANGED=%s\n" "$RUNTIME_CHANGED"
          ;;
        *) exit 97 ;;
      esac
    ' bash "$INSTALL_SCRIPT" "$VERSION_WORK" "$1" "$VERSION_EXPECTED" "$VERSION_ARTIFACT_SHA"
}

expect_version_contract_failure() { # <说明> <validate|prepare>
  local label="$1" action="$2"
  if run_version_contract "$action" >"$VERSION_WORK/failure.out" 2>&1; then
    fail "$label"
  fi
}

run_version_contract validate || fail "合法 Agent runtime 版本合同被拒绝或继承了宿主动态库路径"
mkdir -p "$VERSION_RUNTIME/embedded/lib64"
run_version_contract validate || \
  fail "Agent version 最小环境没有在存在时追加候选 runtime 的 embedded/lib64"
SKIP_OUTPUT="$(run_version_contract prepare)" || fail "SHA 一致的合法 runtime 无法安全跳过"
case "$SKIP_OUTPUT" in *'RUNTIME_CHANGED=0'*) ;; *) fail "合法 SHA-skip 没有保留 runtime" ;; esac

write_fake_agent_version 7.79.0
expect_version_contract_failure "staging 错误接受了 binary 7.79.0" validate
expect_version_contract_failure "SHA-skip 错误接受了 binary 7.79.0" prepare
write_fake_agent_version 7.81.0-dbdog.10
expect_version_contract_failure "binary version 使用前缀伪装通过了精确 token 校验" validate
write_fake_agent_version "$VERSION_EXPECTED"

cp "$VERSION_RUNTIME/.dbdog-release-version" "$VERSION_WORK/release-version.good"
printf '7.81.0-dbdog.2\n' >"$VERSION_RUNTIME/.dbdog-release-version"
expect_version_contract_failure "SHA-skip 没有校验 release-version marker" prepare
mv "$VERSION_WORK/release-version.good" "$VERSION_RUNTIME/.dbdog-release-version"

cp "$VERSION_RUNTIME/provenance/build.txt" "$VERSION_WORK/build.good"
sed "s/^compiled_agent_version=.*/compiled_agent_version=7.79.0/" \
  "$VERSION_WORK/build.good" >"$VERSION_RUNTIME/provenance/build.txt"
expect_version_contract_failure "错误接受了 build provenance 的 compiled_agent_version 漂移" validate
mv "$VERSION_WORK/build.good" "$VERSION_RUNTIME/provenance/build.txt"

cp "$VERSION_RUNTIME/provenance/agent-version.txt" "$VERSION_WORK/agent-version.good"
sed "s/^compiled_version=.*/compiled_version=7.79.0/" \
  "$VERSION_WORK/agent-version.good" >"$VERSION_RUNTIME/provenance/agent-version.txt"
expect_version_contract_failure "错误接受了 agent-version.txt 的 compiled_version 漂移" validate
mv "$VERSION_WORK/agent-version.good" "$VERSION_RUNTIME/provenance/agent-version.txt"

cp "$VERSION_RUNTIME/version-manifest.txt" "$VERSION_WORK/version-manifest.good"
sed "s/^agent .*/agent 7.79.0/" "$VERSION_WORK/version-manifest.good" \
  >"$VERSION_RUNTIME/version-manifest.txt"
expect_version_contract_failure "错误接受了 version-manifest.txt 版本漂移" validate
mv "$VERSION_WORK/version-manifest.good" "$VERSION_RUNTIME/version-manifest.txt"

cp "$VERSION_RUNTIME/version-manifest.json" "$VERSION_WORK/version-manifest-json.good"
printf '%s\n' '{"build_version":"7.79.0"}' >"$VERSION_RUNTIME/version-manifest.json"
expect_version_contract_failure "错误接受了 version-manifest.json build_version 漂移" validate
mv "$VERSION_WORK/version-manifest-json.good" "$VERSION_RUNTIME/version-manifest.json"

PREPARE_BODY="$(awk '/^prepare_runtime\(\)/ { scan=1 } /^render_install_state\(\)/ { scan=0 } scan { print }' "$INSTALL_SCRIPT")"
[ "$(printf '%s\n' "$PREPARE_BODY" | grep -c 'validate_runtime_tree')" -eq 2 ] || \
  fail "staging 与 SHA-skip 没有共用两次 runtime 版本校验入口"
pass "staging 与 SHA-skip 精确绑定版本身份，且 Agent version 只加载候选 runtime 私有库"

# ---- GaussDB 采集质量 GUC 的 warn 校验 ----
# 这两条只影响采集质量、不影响能否装成，所以必须 warn 而不是 die：装不上是硬失败，采不全
# 可以先上线再让 DBA 调。log_line_prefix 尤其隐蔽——不符时 Agent 侧一切正常，只有日志检索里
# 悄悄没有字段，本轮就是靠实例上抓到的两种前缀混用才定位到。
GUC_PROBE="$TEST_ROOT/guc-probe.sh"
{
  printf '%s\n' 'warn() { printf "WARN: %s\n" "$*" >&2; }'
  sed -n '/^readonly AGENT_GAUSSDB_EXPECTED_LOG_LINE_PREFIX=/p' "$SCRIPTS_DIR/agent-install.sh"
  sed -n '/^readonly AGENT_GAUSSDB_MIN_TRACK_ACTIVITY_QUERY_SIZE=/p' "$SCRIPTS_DIR/agent-install.sh"
  printf '%s\n' 'FAKE_PREFIX="" FAKE_SIZE=""'
  printf '%s\n' 'agent_show_guc_raw() { case "$2" in log_line_prefix) printf "%s" "$FAKE_PREFIX";; track_activity_query_size) printf "%s" "$FAKE_SIZE";; esac; }'
  printf '%s\n' 'agent_show_guc() { local v; v="$(agent_show_guc_raw "$@")"; printf "%s" "${v#"${v%%[![:space:]]*}"}" | sed "s/[[:space:]]*$//"; }'
  sed -n '/^agent_warn_gaussdb_collection_gucs()/,/^}/p' "$SCRIPTS_DIR/agent-install.sh"
  printf '%s\n' 'FAKE_PREFIX="$1" FAKE_SIZE="$2"; agent_warn_gaussdb_collection_gucs 0'
} >"$GUC_PROBE"

guc_warns() { bash "$GUC_PROBE" "$1" "$2" 2>&1; }

# 目标实例（146.56.217.73）的真实取值不得触发任何告警——误报会让真问题淹没在噪声里。
[ -z "$(guc_warns '%m %n %u %d %h %p %S %x %a ' 16384)" ] ||
  fail "GaussDB 真实合规取值被误报为不合规: $(guc_warns '%m %n %u %d %h %p %S %x %a ' 16384)"
# 结尾空格是 %a 与 query_id 的分隔符，属于取值的一部分，不得被 trim 掉。
case "$(guc_warns '%m %n %u %d %h %p %S %x %a' 16384)" in
  *'log_line_prefix 与 dbdog 解析契约不一致'*) ;;
  *) fail "log_line_prefix 缺少结尾空格时未告警（读取路径可能把它 trim 掉了）" ;;
esac
# openGauss 的前缀套到 GaussDB 上正是本轮定位到的整条失配成因。
case "$(guc_warns '%m %u %d %h %p %S ' 16384)" in
  *'log_line_prefix 与 dbdog 解析契约不一致'*) ;;
  *) fail "openGauss 前缀用在 GaussDB 上时未告警" ;;
esac
case "$(guc_warns '%m %n %u %d %h %p %S %x %a ' 1024)" in
  *'track_activity_query_size=1024 低于推荐值 4096'*) ;;
  *) fail "track_activity_query_size 低于 4096 时未告警" ;;
esac
[ -z "$(guc_warns '%m %n %u %d %h %p %S %x %a ' 4096)" ] ||
  fail "track_activity_query_size 恰为推荐值时不应告警"
case "$(guc_warns '' '')" in
  *'无法读取 log_line_prefix'*) ;;
  *) fail "读不到 log_line_prefix 时未告警" ;;
esac
# 这两条永远不能升级成 die：安装器要能在 GUC 不理想时照常装完。
grep -q 'agent_warn_gaussdb_collection_gucs "$index"' "$SCRIPTS_DIR/agent-install.sh" ||
  fail "预检未调用 GaussDB 采集质量 GUC 校验"
if sed -n '/^agent_warn_gaussdb_collection_gucs()/,/^}/p' "$SCRIPTS_DIR/agent-install.sh" | grep -q '\bdie\b'; then
  fail "采集质量 GUC 校验不得 die；它只应 warn"
fi
pass "GaussDB 采集质量 GUC 以 warn 方式校验，且真实合规取值不误报"

# DBDOG_DISABLE_DBM_HEALTH 已彻底废除，单元里不得再出现——连 =false 也不行。
# 它是「server 没有 dbmhealth 端点」年代的停采补丁，server 0.1.12 起已落库采集配置快照，
# 存在理由消失；而它的失效完全静默（Python 层 return None，无日志、计数器为 0），
# 2026-08-07 黄区为此查了三轮。留着 =false 等于把这个静默陷阱继续摆在那里等人写反。
# 定则：停发某类数据是产品决策，必须显式上升，不能由安装脚本默默决定。
# 注意用 if 而非 `grep && fail`：本文件 set -e，grep 未命中时返回 1 会直接终止整个测试。
if grep -q 'DISABLE_DBM_HEALTH' "$SCRIPTS_DIR/agent-lib.sh"; then
  fail "agent-lib.sh 仍出现 DISABLE_DBM_HEALTH——该开关已废除，不应以任何取值复活"
fi
pass "dbm-health 停摆开关已从 systemd 单元彻底移除"

# SCHEMA 推荐字段的 env 开关是过渡遗留：≤dbdog.6 的补丁版产物靠它，≥.7 源码版无人读。
# 用 manifest 版本钉住删除时机——manifest 一升到 .7+，这行 env 不删测试就红，
# 免得又出一个「没人知道要跟着翻」的两仓脱节（dbm-health 开关就是那么烂掉的）。
manifest_agent_ver="$(awk -F'\t' '$1 == "dbdog-agent" { print $5 }' "$RELEASE_DIR/manifest.tsv")"
schema_env_count="$(grep -c '^Environment=DBDOG_SCHEMA_RECOMMENDATION_FIELDS=' "$SCRIPTS_DIR/agent-lib.sh" || true)"
case "$manifest_agent_ver" in
  7.81.0-dbdog.[1-6])
    [ "$schema_env_count" -eq 1 ] || \
      fail "manifest 还在 $manifest_agent_ver（补丁版产物），SCHEMA env 行必须保留恰好一次（实为 $schema_env_count）"
    pass "SCHEMA env 过渡行与补丁版产物 $manifest_agent_ver 匹配"
    ;;
  *)
    [ "$schema_env_count" -eq 0 ] || \
      fail "manifest 已是 $manifest_agent_ver（源码版产物），agent-lib.sh 的 SCHEMA env 过渡行必须删除"
    pass "SCHEMA env 过渡行已随源码版产物移除"
    ;;
esac

# ---- host-only 模式（通用主机 agent）----

# 27. host-only 渲染：清空引擎事实后渲染成功，产出纯主机基线。
HOSTONLY_CONF="$TEST_ROOT/hostonly-conf"
mkdir -p "$HOSTONLY_CONF/conf.d"
AGENT_HOST_ONLY=1
agent_clear_engine_facts
agent_render_checks "$HOSTONLY_CONF/conf.d" "" dbdog postgres prod
AGENT_HOST_ONLY=0
for sys_check in cpu disk file_handle io load memory network system_core uptime; do
  [ -f "$HOSTONLY_CONF/conf.d/$sys_check.d/conf.yaml" ] || \
    fail "host-only 缺系统 check: $sys_check"
done
[ -f "$HOSTONLY_CONF/conf.d/process.d/conf.yaml" ] || fail "host-only 缺 process.d"
grep -q 'search_string' "$HOSTONLY_CONF/conf.d/process.d/conf.yaml" && \
  fail "host-only 的 process.d 不应包含引擎进程条目"
for engine_dir in gaussdb opengauss postgres; do
  [ ! -e "$HOSTONLY_CONF/conf.d/$engine_dir.d" ] || \
    fail "host-only 不应渲染引擎目录: $engine_dir"
done
pass "host-only 渲染产出九项系统 check + 无引擎条目的 process.d，无引擎 conf"

# 28. 默认模式 fail closed：无引擎事实且未设 host-only 必须拒绝渲染。
# 注：die() 是 exit 1，会终止本测试进程，必须在子 shell 里跑。
if (AGENT_HOST_ONLY=0 agent_render_checks "$TEST_ROOT/hostonly-refuse/conf.d" "" dbdog postgres prod \
    >"$TEST_ROOT/hostonly-refuse.out" 2>"$TEST_ROOT/hostonly-refuse.err"); then
  fail "无引擎事实且未设 AGENT_HOST_ONLY 时渲染不应成功"
fi
grep -Fq "没有可渲染的数据库实例" "$TEST_ROOT/hostonly-refuse.err" || \
  fail "默认模式拒绝文案缺「没有可渲染的数据库实例」"
pass "默认模式无引擎事实仍 fail closed"

# 29. 清单同步：agent-lib 的 CONTRACT_FILES 与 server 配方 staging 清单必须同源同刻。
RECIPE="$SCRIPTS_DIR/publish/recipes/dbdog-server.sh"
recipe_stage_pattern="$(grep -c 'AGENT_INSTALLER_CONTRACT_FILES' "$RECIPE" || true)"
[ "$recipe_stage_pattern" -ge 2 ] || \
  fail "server 配方未通过 AGENT_INSTALLER_CONTRACT_FILES 消费同一份清单（staging+指纹两处）"
grep -Fq 'bootstrap.sh' "$RECIPE" || fail "server 配方未 staging bootstrap.sh"
pass "server 配方从 AGENT_INSTALLER_CONTRACT_FILES 单源 staging 且包含 bootstrap.sh"

# 30. bootstrap 契约：先验后执行、key 预验、host-only 转调、清单解析不硬编码。
BOOTSTRAP="$SCRIPTS_DIR/bootstrap.sh"
[ -f "$BOOTSTRAP" ] || fail "缺 bootstrap.sh"
grep -q 'sha256sum -c' "$BOOTSTRAP" || fail "bootstrap 缺指纹校验（sha256sum -c）"
grep -Fq '/api/v1/validate' "$BOOTSTRAP" || fail "bootstrap 缺 key 预验"
grep -Fq -- '--host-only' "$BOOTSTRAP" || fail "bootstrap 未转调 agent-install.sh --host-only"
grep -q "awk '{print \$2}'" "$BOOTSTRAP" || \
  fail "bootstrap 文件清单必须从 sha256s 解析而非硬编码"
grep -Eq 'sudo -E env' "$BOOTSTRAP" || fail "bootstrap 缺非 root 自提升（显式 env 传递）"
pass "bootstrap 先验后执行 + key 预验 + 清单单源 + root 自提升齐备"

# 31. upgrade.sh 透传：仅允许附加 --host-only，其余多参拒绝。
grep -Fq 'exec "$SCRIPTS_DIR/agent-install.sh" ${2:+--host-only}' "$SCRIPTS_DIR/upgrade.sh" || \
  fail "upgrade.sh 缺 --host-only 透传"
pass "upgrade.sh dbdog-agent --host-only 透传正确"

printf 'ALL PASS: 31 agent install contract groups\n'
