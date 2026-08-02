#!/usr/bin/env bash
# 本机可重复测试：check-upgrade 对 Agent 安装器合约 marker 的完整状态判定。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-agent-marker.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-agent-marker.??????) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

CHECKER="$SCRIPTS_DIR/check-upgrade.sh"
RUNTIME="$TEST_ROOT/runtime"
MANIFEST_FIXTURE="$TEST_ROOT/manifest.tsv"
VERSION=7.81.0-dbdog.2
ARTIFACT_SHA256=921686a1e507d231dad57157bbe9b826fa81494d05be2588f31be2e9db8b107c
mkdir -p "$RUNTIME"

# shellcheck disable=SC2016
grep -Fq 'source "$SCRIPTS_DIR/agent-lib.sh"' "$CHECKER" \
  || fail 'check-upgrade 没有加载 Agent 安装器合约函数'
# shellcheck disable=SC2016
grep -Fq '"$AGENT_RUNTIME_DIR/.dbdog-release-version"' "$CHECKER" \
  || fail 'check-upgrade 仍硬编码 /opt/dbdog-agent，无法安全 fixture'
grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$CHECKER" \
  || fail '安装器合约变化没有指向正常 Agent 升级入口'
grep -Fq 'DBDOG_CHECK_UPGRADE_REEXEC=1' "$CHECKER" \
  || fail 'check-upgrade --pull 更新脚本后没有重新执行最新逻辑'
pass 'checker 加载独立合约逻辑、尊重 runtime 覆盖且只提示正常升级入口'

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/agent-lib.sh"
EXPECTED_CONTRACT="$(agent_installer_contract_fingerprint "$SCRIPTS_DIR")" \
  || fail '无法计算测试所需的安装器合约指纹'
[[ "$EXPECTED_CONTRACT" =~ ^[0-9a-f]{64}$ ]] \
  || fail "安装器合约指纹不是 64 位小写 SHA-256: $EXPECTED_CONTRACT"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  dbdog-agent first-party dbhost no "$VERSION" \
  "dbdog-agent-$VERSION-aarch64.tar.gz" "$ARTIFACT_SHA256" agent:test,core:test aarch64 \
  >"$MANIFEST_FIXTURE"
printf '%s\n' "$VERSION" >"$RUNTIME/.dbdog-release-version"
printf '%s\n' "$ARTIFACT_SHA256" >"$RUNTIME/.dbdog-artifact-sha256"

run_checker() { # <case> <expected rc>
  local name="$1" expected_rc="$2" rc=0 out
  out="$TEST_ROOT/$name.out"
  AGENT_RUNTIME_DIR="$RUNTIME" MANIFEST="$MANIFEST_FIXTURE" \
    DBDOG_HOME="$TEST_ROOT/home" DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
    bash "$CHECKER" >"$out" 2>&1 || rc=$?
  [ "$rc" -eq "$expected_rc" ] || {
    sed -n '1,160p' "$out" >&2
    fail "$name: check-upgrade exit=$rc，期望 $expected_rc"
  }
  printf '%s\n' "$out"
}

printf '%s\n' "$EXPECTED_CONTRACT" >"$RUNTIME/$AGENT_INSTALLER_CONTRACT_MARKER"
out="$(run_checker matching 0)"
grep -Eq 'dbdog-agent.*一致' "$out" || fail '合约一致没有报告一致'
if grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$out"; then
  fail '合约一致仍提示升级 Agent'
fi
pass '版本、产物及安装器合约均一致时 checker 返回 0'

rm -f -- "$RUNTIME/$AGENT_INSTALLER_CONTRACT_MARKER"
out="$(run_checker missing 10)"
grep -Fq '安装器合约 marker 缺失 ←' "$out" || fail '旧安装缺 marker 未被识别'
grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$out" || fail '缺 marker 未提示正常 Agent 升级'
pass '旧安装缺合约 marker 时返回 10 并提示正常升级'

printf '%064d\n' 0 | tr 0 A >"$RUNTIME/$AGENT_INSTALLER_CONTRACT_MARKER"
out="$(run_checker damaged 10)"
grep -Fq '安装器合约 marker 损坏 ←' "$out" || fail '非法 marker 未被识别为损坏'
grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$out" || fail 'marker 损坏未提示正常 Agent 升级'
pass '非小写 SHA-256 marker 即使长度为 64 也被判为损坏'

different_contract="$(printf '%064d' 0)"
[ "$different_contract" != "$EXPECTED_CONTRACT" ] || fail '测试用不同指纹意外等于当前指纹'
printf '%s\n' "$different_contract" >"$RUNTIME/$AGENT_INSTALLER_CONTRACT_MARKER"
out="$(run_checker changed 10)"
grep -Fq '安装器合约不同 ←' "$out" || fail '有效但过期的 marker 未被识别'
grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$out" || fail '合约不同未提示正常 Agent 升级'
pass '有效但不同的合约 marker 触发正常 Agent 升级'

# 合约 marker 只有在版本和产物身份均一致后才有意义，旧 runtime 应优先报告
# 原有身份问题，避免把真正的二进制升级误写成仅刷新安装器。
printf '%s\n' 7.80.0-dbdog.9 >"$RUNTIME/.dbdog-release-version"
printf '%s\n' INVALID >"$RUNTIME/$AGENT_INSTALLER_CONTRACT_MARKER"
out="$(run_checker version-first 10)"
grep -Fq '版本不同 ←' "$out" || fail '版本差异未优先于安装器 marker'
if grep -Fq '安装器合约 marker 损坏 ←' "$out"; then
  fail '版本不同时仍比较了安装器 marker'
fi
printf '%s\n' "$VERSION" >"$RUNTIME/.dbdog-release-version"
printf '%064d\n' 0 >"$RUNTIME/.dbdog-artifact-sha256"
out="$(run_checker artifact-first 10)"
grep -Fq '产物 SHA 不同 ←' "$out" || fail '产物差异未优先于安装器 marker'
if grep -Fq '安装器合约 marker 损坏 ←' "$out"; then
  fail '产物不同时仍比较了安装器 marker'
fi
pass '版本或产物不一致时沿用原有优先状态，不提前比较安装器 marker'

printf 'ALL PASS: 6 Agent installer marker contract groups\n'
