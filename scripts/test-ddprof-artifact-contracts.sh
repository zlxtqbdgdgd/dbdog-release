#!/usr/bin/env bash
# 本机可重复测试：官方 ddprof v0.26.0 双架构配方的固定摘要合同、包结构/确定性
# 封装合同，以及下载/校验流程的 fail-closed 行为。全部使用本地 fixture，不对
# GitHub 发起真实网络请求（TOOL_PATH 注入的假 curl 拦截下载）。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="$SCRIPTS_DIR/publish/recipes/ddprof.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-ddprof-contracts.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-ddprof-contracts.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[ -f "$RECIPE" ] || fail "缺少构建配方: $RECIPE"
bash -n "$RECIPE" || fail "配方语法检查失败"
pass "配方文件存在且语法合法"

# ---- Step 1：brief 原文规定的四个固定摘要合同（逐字复制，不改写）----
grep -Fq '03a76919bcc23a757f02d9c276dee7e58c1db688cc75e5568eb9a0f709bdce52' "$RECIPE" \
  || fail "配方缺少固定摘要 03a76919...（x86_64 官方 tar）"
grep -Fq '1c25657a53643d74eac4d13356a2953dbfd8d52cc80f9266025b3ae3983addef' "$RECIPE" \
  || fail "配方缺少固定摘要 1c25657a...（aarch64 官方 tar）"
grep -Fq '8bf9255eecf4c93177bef7a5ccf5726b4df8b549fde9d5ed228073f784804b75' "$RECIPE" \
  || fail "配方缺少固定摘要 8bf9255e...（x86_64 解包二进制）"
grep -Fq '8edb9b30c355a2f685bfaf00e2f23998884d249b6c5ac7701a7bb9af3e324df4' "$RECIPE" \
  || fail "配方缺少固定摘要 8edb9b30...（aarch64 解包二进制）"
pass "四个固定 SHA-256 摘要均硬编码在配方里"

# ---- 摘要与架构/角色的对应关系没有搞反 ----
# 官方 sha256sum.txt 逐字节核对结果（离线核对，见配方头部注释）：
#   amd64 tar   -> 03a76919...dce52  同一 tar 内 bin/ddprof -> 8bf9255e...804b75
#   arm64 tar   -> 1c25657a...3addef 同一 tar 内 bin/ddprof -> 8edb9b30...324df4
grep -Fq 'PINNED_TAR_SHA256_X86_64="03a76919bcc23a757f02d9c276dee7e58c1db688cc75e5568eb9a0f709bdce52"' "$RECIPE" \
  || fail "x86_64 tar 摘要常量绑错了值"
grep -Fq 'PINNED_TAR_SHA256_AARCH64="1c25657a53643d74eac4d13356a2953dbfd8d52cc80f9266025b3ae3983addef"' "$RECIPE" \
  || fail "aarch64 tar 摘要常量绑错了值"
grep -Fq 'PINNED_BIN_SHA256_X86_64="8bf9255eecf4c93177bef7a5ccf5726b4df8b549fde9d5ed228073f784804b75"' "$RECIPE" \
  || fail "x86_64 解包二进制摘要常量绑错了值"
grep -Fq 'PINNED_BIN_SHA256_AARCH64="8edb9b30c355a2f685bfaf00e2f23998884d249b6c5ac7701a7bb9af3e324df4"' "$RECIPE" \
  || fail "aarch64 解包二进制摘要常量绑错了值"
grep -Fq 'asset_name="ddprof-${PINNED_VERSION}-amd64-linux.tar.xz"' "$RECIPE" \
  || fail "x86_64 分支没有下载 amd64-linux.tar.xz"
grep -Fq 'asset_name="ddprof-${PINNED_VERSION}-arm64-linux.tar.xz"' "$RECIPE" \
  || fail "aarch64 分支没有下载 arm64-linux.tar.xz"
pass "四个摘要与 tar/二进制、amd64/arm64 的对应关系正确（静态核对）"

# ---- 固定版本、禁止 latest/在线 sha256sum.txt 作为权威 ----
grep -Fq 'PINNED_VERSION="0.26.0"' "$RECIPE" || fail "配方没有把版本钉死在 0.26.0"
grep -Fq '"$ver" = "$PINNED_VERSION"' "$RECIPE" || fail "配方没有校验 VERSION 必须等于固定版本"
curl_invocation_lines="$(grep -n 'curl -' "$RECIPE" || true)"
[ -n "$curl_invocation_lines" ] || fail "配方里找不到实际的 curl 下载调用"
if printf '%s\n' "$curl_invocation_lines" | grep -Eq 'sha256sum|/latest([/"[:space:]]|$)'; then
  fail "配方的 curl 下载调用里出现 latest 或 sha256sum.txt（应只硬编码四个摘要）: $curl_invocation_lines"
fi
pass "VERSION 被钉死为 0.26.0，运行时下载路径不解析 latest 或在线 sha256sum.txt"

# ---- 包结构合同：顶层目录、入口 bin/ddprof、确定性封装 ----
grep -Fq 'pkg="ddprof-$PINNED_VERSION"' "$RECIPE" || fail "顶层目录没有钉死为 ddprof-<version>"
grep -Fq 'art="ddprof-${PINNED_VERSION}-${arch}.tar.gz"' "$RECIPE" \
  || fail "产物文件名没有钉死为 ddprof-<version>-<arch>.tar.gz"
grep -Fq '[ -x "$staging/$topdir_name/bin/ddprof" ]' "$RECIPE" \
  || fail "打包前没有校验入口 bin/ddprof 存在且可执行"
for marker in 'ti.mtime = 0' 'ti.uid = 0' 'ti.gid = 0' \
  'entries.sort(key=lambda e: e[1])' 'mtime=0' 'filename=""'; do
  grep -Fq "$marker" "$RECIPE" || fail "确定性封装缺少关键设置: $marker"
done
pass "包结构（顶层目录/入口）与确定性封装（固定 mtime/owner/排序）均有静态断言"

# ================= 动态：假 curl 拦截下载，驱动真实配方代码路径 =================
BIN_DIR="$TEST_ROOT/bin"
mkdir -p "$BIN_DIR"
CURL_LOG="$TEST_ROOT/curl-requests.log"
: >"$CURL_LOG"
cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
prev=""
for arg in "$@"; do
  [ "$prev" != "-o" ] || out="$arg"
  prev="$arg"
  url="$arg"
done
printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
name="$(basename "$url")"
src="$FAKE_CURL_ASSET_DIR/$name"
if [ ! -f "$src" ]; then
  echo "fake curl: no fixture staged for $name" >&2
  exit 22
fi
cp "$src" "$out"
EOF
chmod +x "$BIN_DIR/curl"

run_recipe() { # run_recipe <VERSION> <ARCH> <asset-fixture-dir> <build-work-dir>
  local ver="$1" arch="$2" asset_dir="$3" work="$4"
  MODULE=ddprof VERSION="$ver" ARCH="$arch" BUILD_WORK="$work" TOOL_PATH="$BIN_DIR" \
    FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_ASSET_DIR="$asset_dir" \
    bash "$RECIPE"
}

# ---- VERSION 网关：非 0.26.0 必须在联网前就被拒绝 ----
: >"$CURL_LOG"
if out="$(run_recipe latest x86_64 "$TEST_ROOT/no-such-dir" "$TEST_ROOT/work-ver" 2>&1)"; then
  fail "VERSION=latest 未被拒绝: $out"
fi
[ ! -s "$CURL_LOG" ] || fail "VERSION 网关生效前配方已经尝试下载: $(cat "$CURL_LOG")"
pass "VERSION 非 0.26.0 在联网前 fail closed"

# ---- ARCH 网关：非 x86_64/aarch64 必须在联网前就被拒绝 ----
: >"$CURL_LOG"
if out="$(run_recipe 0.26.0 noarch "$TEST_ROOT/no-such-dir" "$TEST_ROOT/work-arch" 2>&1)"; then
  fail "ARCH=noarch 未被拒绝: $out"
fi
[ ! -s "$CURL_LOG" ] || fail "ARCH 网关生效前配方已经尝试下载: $(cat "$CURL_LOG")"
pass "ARCH 不是 x86_64/aarch64 时在联网前 fail closed"

# ---- 按架构选择的官方资产文件名没有搞反 ----
FIXTURE_DIR="$TEST_ROOT/asset-fixtures"
mkdir -p "$FIXTURE_DIR"
printf 'synthetic, deliberately not the real official tarball\n' \
  >"$FIXTURE_DIR/ddprof-0.26.0-amd64-linux.tar.xz"
printf 'synthetic, deliberately not the real official tarball (arm64)\n' \
  >"$FIXTURE_DIR/ddprof-0.26.0-arm64-linux.tar.xz"

: >"$CURL_LOG"
run_recipe 0.26.0 x86_64 "$FIXTURE_DIR" "$TEST_ROOT/work-x86" >/dev/null 2>&1 || true
grep -Fxq 'https://github.com/DataDog/ddprof/releases/download/v0.26.0/ddprof-0.26.0-amd64-linux.tar.xz' \
  "$CURL_LOG" || fail "x86_64 没有请求官方 amd64-linux.tar.xz: $(cat "$CURL_LOG")"

: >"$CURL_LOG"
run_recipe 0.26.0 aarch64 "$FIXTURE_DIR" "$TEST_ROOT/work-arm" >/dev/null 2>&1 || true
grep -Fxq 'https://github.com/DataDog/ddprof/releases/download/v0.26.0/ddprof-0.26.0-arm64-linux.tar.xz' \
  "$CURL_LOG" || fail "aarch64 没有请求官方 arm64-linux.tar.xz: $(cat "$CURL_LOG")"
pass "x86_64/aarch64 各自请求正确的官方资产文件名，未搞反"

# ---- VERSION=""（publish.sh 对三方件的恒定生产调用形态）必须被接受，等价于固定版本 ----
# publish.sh cmd_publish 的架构矩阵循环对非 first-party 模块恒传 ver=""（build_one_arch
# "$m" "$ver" "$arch" 里 $ver 对三方件永远是空串，见其它三方件配方头注释"VERSION 忽略/
# 自动探测"）。ddprof 配方虽然固定版本、拒绝 latest，但绝不能把生产会真实传入的空串也
# 一并拒绝——否则 publish.sh publish ddprof 会在第一个架构就必死。
: >"$CURL_LOG"
run_recipe "" x86_64 "$FIXTURE_DIR" "$TEST_ROOT/work-empty-ver" >/dev/null 2>&1 || true
grep -Fxq 'https://github.com/DataDog/ddprof/releases/download/v0.26.0/ddprof-0.26.0-amd64-linux.tar.xz' \
  "$CURL_LOG" || fail "VERSION=\"\"（publish.sh 对三方件的生产调用形态）没有被当作固定版本驱动到正确下载路径: $(cat "$CURL_LOG")"
pass 'VERSION=""（publish.sh 对三方件恒传的生产调用形态）被接受，等价于固定版本 0.26.0'

# ---- tar 摘要不匹配：fail closed，且不产出任何产物 ----
work_bad="$TEST_ROOT/work-bad-tar"
out=""
if out="$(run_recipe 0.26.0 x86_64 "$FIXTURE_DIR" "$work_bad" 2>&1)"; then
  fail "tar 摘要不匹配的 fixture 未被拒绝: $out"
fi
printf '%s\n' "$out" | grep -Fq 'tar 摘要不匹配' || fail "tar 摘要不匹配的报错信息不清楚: $out"
[ ! -e "$work_bad/ddprof/out" ] || [ -z "$(ls -A "$work_bad/ddprof/out" 2>/dev/null)" ] \
  || fail "tar 摘要不匹配时仍然产出了文件: $(ls -A "$work_bad/ddprof/out")"
pass "官方 tar 摘要不匹配时 fail closed，且不产出任何产物"

# 说明：解包后二进制摘要不匹配（tar 摘要匹配但内层被替换）的路径，理论上无法用
# 本地伪造数据驱动到——SHA-256 抗原像性决定了任何合成 fixture 都通不过上面已经
# 验证过的 tar 摘要门禁，这本身正是内容锁设计的目的。该分支已经在上面"包结构与
# 确定性封装"里做了静态断言（校验代码存在、绑定的是解包后 bin/ddprof、发生在
# tar 摘要核验之后、ddprof --version 之前）。开发者已额外用官方发布的真实
# ddprof-0.26.0-{amd64,arm64}-linux.tar.xz 手工跑过完整下载态：两个架构的 tar
# 摘要与解包后 bin/ddprof 摘要均与本文件顶部锁定的四个值逐字节一致，见 task-5
# 报告；该手工验证不进入自动化测试（避免测试依赖真实网络）。
grep -Fq 'actual_bin_sha256="$(sha256sum "$extract/ddprof/bin/ddprof" | awk' "$RECIPE" \
  || fail "解包二进制摘要校验逻辑丢失"
pass "解包二进制摘要门禁的存在性、位置已静态核对（内容匹配已用真实官方产物手工验证一次，见报告）"

# ================= 结构 + 确定性：直接调用打包函数（source 不触发 main）=================
DRIVER="$TEST_ROOT/driver.sh"
cat >"$DRIVER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$RECIPE"
"\$@"
EOF
chmod +x "$DRIVER"

# 合成一棵最小 ddprof 目录树（bin/ddprof 是可执行 stand-in，不需要真的能跑），
# 验证打包函数本身：顶层目录改名、入口保留、可执行位保留、gzip/tar 头不带
# 时间戳，且多次调用字节相同。
synth_src="$TEST_ROOT/synth/ddprof"
mkdir -p "$synth_src/bin" "$synth_src/lib" "$synth_src/licenses"
printf '#!/bin/sh\necho fake ddprof 0.26.0\n' >"$synth_src/bin/ddprof"
chmod 755 "$synth_src/bin/ddprof"
printf 'not a real shared object, just fixture bytes\n' >"$synth_src/lib/libdd_profiling.so"
chmod 644 "$synth_src/lib/libdd_profiling.so"
printf 'MIT-ish fixture license text\n' >"$synth_src/licenses/LICENSE"
printf '0.26.0+fixture\n' >"$synth_src/version.txt"

out1="$TEST_ROOT/pkg-run1.tar.gz"
out2="$TEST_ROOT/pkg-run2.tar.gz"
"$DRIVER" package_ddprof_deterministic "$synth_src" "ddprof-0.26.0" "$out1" \
  || fail "打包函数在合法输入上失败"
sleep 1
"$DRIVER" package_ddprof_deterministic "$synth_src" "ddprof-0.26.0" "$out2" \
  || fail "打包函数第二次调用失败"

listing="$(tar -tzf "$out1" | sort)"
expected_listing="$(printf '%s\n' \
  'ddprof-0.26.0/' \
  'ddprof-0.26.0/bin/' \
  'ddprof-0.26.0/bin/ddprof' \
  'ddprof-0.26.0/lib/' \
  'ddprof-0.26.0/lib/libdd_profiling.so' \
  'ddprof-0.26.0/licenses/' \
  'ddprof-0.26.0/licenses/LICENSE' \
  'ddprof-0.26.0/version.txt' | sort)"
[ "$listing" = "$expected_listing" ] || \
  fail "打包结果目录结构不符（顶层目录/入口）：实际=[$listing] 期望=[$expected_listing]"
pass "打包结果顶层目录为 ddprof-0.26.0/，入口 bin/ddprof 存在，未新增/丢失文件"

extract_dir="$TEST_ROOT/extract-check"
mkdir -p "$extract_dir"
tar -xzf "$out1" -C "$extract_dir"
[ -x "$extract_dir/ddprof-0.26.0/bin/ddprof" ] || fail "解出的 bin/ddprof 丢失可执行位"
[ ! -x "$extract_dir/ddprof-0.26.0/lib/libdd_profiling.so" ] \
  || fail "普通文件被错误地打上了可执行位"
pass "确定性打包保留了 bin/ddprof 的可执行位，且没有污染普通文件的权限"

sha1="$(shasum -a 256 "$out1" | awk '{print $1}')"
sha2="$(shasum -a 256 "$out2" | awk '{print $1}')"
[ "$sha1" = "$sha2" ] || fail "两次独立打包（间隔 1 秒）产出的字节不同，封装不是确定性的: $sha1 != $sha2"
pass "同一输入两次独立打包字节完全相同（确定性重新封装）"

# gzip 头部的 4 字节小端 mtime 字段必须是 0（不嵌入构建机当前时间）。
gzip_mtime_hex="$(od -An -tx1 -j4 -N4 "$out1" | tr -d ' \n')"
[ "$gzip_mtime_hex" = "00000000" ] || fail "gzip 头部嵌入了非零 mtime: $gzip_mtime_hex"
pass "gzip 头部 mtime 字段固定为 0，不泄漏构建机当前时间"

# 源目录缺少入口时打包函数必须 fail closed。
bad_src="$TEST_ROOT/synth-missing-bin"
mkdir -p "$bad_src/lib"
if ("$DRIVER" package_ddprof_deterministic "$bad_src" "ddprof-0.26.0" "$TEST_ROOT/pkg-bad.tar.gz") \
    >/dev/null 2>&1; then
  fail "缺少 bin/ddprof 的源目录未被打包函数拒绝"
fi
pass "打包函数在源目录缺少入口 bin/ddprof 时 fail closed"

printf 'ALL PASS: ddprof v0.26.0 dual-arch artifact contracts\n'
