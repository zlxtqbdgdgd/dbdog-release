#!/usr/bin/env bash
# x86_64 Agent canonical build 合同：
#   1. recipe 精确选择——publish.sh 对 dbdog-agent/x86_64 必须精确选中
#      recipes/dbdog-agent-x86_64.sh，而不是回退到共享的 recipes/dbdog-agent.sh
#      （aarch64 因为没有 recipes/dbdog-agent-aarch64.sh，必须继续回退到后者，
#      回归测试见下方"回退到共享配方"场景）。
#   2. 两架构的 provenance/build.txt 必须共享同一份 agent_git_sha /
#      integrations_core_git_sha / version（同一 RELEASE-BASELINE.tsv 锚点、同一
#      dbdog 版本），但 architecture 字段（对应计划里的 builder_arch 语义）分别
#      不同——本文件全部走本地静态 fixture（跨文件常量比对 + bash -n 语法检查 +
#      源码 source 复用配方内部函数），不依赖任何真实 x86_64 builder。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
RECIPE_AARCH64="$SCRIPTS_DIR/publish/recipes/dbdog-agent.sh"
RECIPE_X86_64="$SCRIPTS_DIR/publish/recipes/dbdog-agent-x86_64.sh"
PUBLISH_SH="$SCRIPTS_DIR/publish/publish.sh"
X86_64_README="$SCRIPTS_DIR/publish/agent-build/x86_64/README.md"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

recipe_readonly() { # <recipe 文件> <常量名>
  sed -n "s/^readonly ${2}=//p" "$1"
}

[ -f "$RECIPE_X86_64" ] || fail "缺少 x86_64 配方: $RECIPE_X86_64"
bash -n "$RECIPE_X86_64" || fail "x86_64 配方语法错误"
bash -n "$RECIPE_AARCH64" || fail "aarch64 配方语法错误（回归）"
bash -n "$PUBLISH_SH" || fail "publish.sh 语法错误"
pass "x86_64 配方存在，且与 aarch64 配方、publish.sh 一样通过 bash -n"

# ---------------------------------------------------------------------------
# 场景 1：recipe 精确选择规则——存在 recipes/<module>-<arch>.sh 时精确选择，
# 否则回退到 recipes/<module>.sh。真实调用 publish.sh 里的 resolve_module_recipe，
# 不重新实现一遍选择逻辑。
# ---------------------------------------------------------------------------
grep -Fq 'resolve_module_recipe "$m" "$arch"' "$PUBLISH_SH" \
  || fail "build_one_arch 未接入架构感知的 recipe 精确选择"
if grep -Fq 'local recipe="$HERE/recipes/$m.sh"' "$PUBLISH_SH"; then
  fail "build_one_arch 仍然硬编码单架构 recipe 路径，未接入精确选择规则"
fi
pass "publish.sh 的 build_one_arch 已改为调用 resolve_module_recipe 精确选择配方"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-agent-x86-recipe-select.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-agent-x86-recipe-select.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

(
  RELEASE_DIR="$TEST_ROOT/release"
  DBDOG_HOME="$TEST_ROOT/home"
  mkdir -p "$RELEASE_DIR"
  git init -q "$RELEASE_DIR"
  git -C "$RELEASE_DIR" config user.name dbdog-contract-test
  git -C "$RELEASE_DIR" config user.email dbdog-contract-test@example.invalid
  : >"$RELEASE_DIR/manifest.tsv"
  git -C "$RELEASE_DIR" add manifest.tsv
  git -C "$RELEASE_DIR" commit -qm init
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export RELEASE_DIR DBDOG_HOME MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  resolve_module_recipe dbdog-agent x86_64
  [ "$RESOLVED_RECIPE" = "$RECIPE_X86_64" ] \
    || fail "dbdog-agent/x86_64 没有精确选中 recipes/dbdog-agent-x86_64.sh（实际: $RESOLVED_RECIPE）"

  resolve_module_recipe dbdog-agent aarch64
  [ "$RESOLVED_RECIPE" = "$RECIPE_AARCH64" ] \
    || fail "dbdog-agent/aarch64 未回退到共享的 recipes/dbdog-agent.sh（实际: $RESOLVED_RECIPE，不存在 dbdog-agent-aarch64.sh，必须回退）"

  resolve_module_recipe dbdog-agent noarch
  [ "$RESOLVED_RECIPE" = "$RECIPE_AARCH64" ] \
    || fail "dbdog-agent 的非 x86_64 架构不应该被精确选择规则误导向 x86_64 配方"

  resolve_module_recipe dbdog-web x86_64
  [ "$RESOLVED_RECIPE" = "$SCRIPTS_DIR/publish/recipes/dbdog-web.sh" ] \
    || fail "没有拆分按架构配方的模块（dbdog-web）也应该回退到共享配方，不受本次改动影响"
) || exit 1
pass "resolve_module_recipe 对 dbdog-agent/x86_64 精确选择新配方，其余架构/模块按既有共享配方回退"

# ---------------------------------------------------------------------------
# 场景 2：Agent 产物固化目录不再对 x86_64 误用 aarch64 的封存路径。
# ---------------------------------------------------------------------------
grep -Fq 'if [ "$m" = dbdog-agent ] && [ "$arch" = aarch64 ]; then' "$PUBLISH_SH" \
  || fail "expected_rpath 的 aarch64 封存路径分支不是精确限定到 arch=aarch64"
grep -Fq 'expected_rpath="/home/dbdog/work/dbdog-agent-62ad2979-build2/out/$BUILT_ARTIFACT"' "$PUBLISH_SH" \
  || fail "aarch64 封存产物目录丢失（回归）"
pass "aarch64 封存产物目录仅在 arch=aarch64 时生效，x86_64 Agent 落在通用 BUILD_WORK/<module>/out 下"

# ---------------------------------------------------------------------------
# 场景 3：两架构共享同一 RELEASE-BASELINE.tsv 锚点（Global Constraint）——逐字节
# 比对两份配方里独立声明的固定常量，防止 x86_64 配方悄悄漂到不同的源码锚。
# ---------------------------------------------------------------------------
aarch64_agent_sha="$(recipe_readonly "$RECIPE_AARCH64" PINNED_AGENT_SHA)"
x86_64_agent_sha="$(recipe_readonly "$RECIPE_X86_64" PINNED_AGENT_SHA)"
[ -n "$aarch64_agent_sha" ] || fail "无法从 aarch64 配方读出 PINNED_AGENT_SHA"
[ "$aarch64_agent_sha" = "$x86_64_agent_sha" ] \
  || fail "两架构配方的 PINNED_AGENT_SHA 不一致（aarch64=$aarch64_agent_sha, x86_64=$x86_64_agent_sha）"

aarch64_core_sha="$(recipe_readonly "$RECIPE_AARCH64" PINNED_INTEGRATION_CORE_SHA)"
x86_64_core_sha="$(recipe_readonly "$RECIPE_X86_64" PINNED_INTEGRATION_CORE_SHA)"
[ -n "$aarch64_core_sha" ] || fail "无法从 aarch64 配方读出 PINNED_INTEGRATION_CORE_SHA"
[ "$aarch64_core_sha" = "$x86_64_core_sha" ] \
  || fail "两架构配方的 PINNED_INTEGRATION_CORE_SHA 不一致（aarch64=$aarch64_core_sha, x86_64=$x86_64_core_sha）"

aarch64_wheel_sha="$(recipe_readonly "$RECIPE_AARCH64" GAUSSDB_WHEEL_SHA256)"
x86_64_wheel_sha="$(recipe_readonly "$RECIPE_X86_64" GAUSSDB_WHEEL_SHA256)"
[ -n "$aarch64_wheel_sha" ] || fail "无法从 aarch64 配方读出 GAUSSDB_WHEEL_SHA256"
[ "$aarch64_wheel_sha" = "$x86_64_wheel_sha" ] \
  || fail "两架构配方消费的 GaussDB wheel sha256 不一致（纯 Python wheel 应与架构无关）"

aarch64_wheel_ver="$(recipe_readonly "$RECIPE_AARCH64" GAUSSDB_INTEGRATION_VERSION)"
x86_64_wheel_ver="$(recipe_readonly "$RECIPE_X86_64" GAUSSDB_INTEGRATION_VERSION)"
[ "$aarch64_wheel_ver" = "$x86_64_wheel_ver" ] \
  || fail "两架构配方的 GAUSSDB_INTEGRATION_VERSION 不一致"

aarch64_install_dir="$(recipe_readonly "$RECIPE_AARCH64" INSTALL_DIR)"
x86_64_install_dir="$(recipe_readonly "$RECIPE_X86_64" INSTALL_DIR)"
[ "$aarch64_install_dir" = /opt/dbdog-agent ] || fail "aarch64 配方 INSTALL_DIR 不是 /opt/dbdog-agent（回归）"
[ "$x86_64_install_dir" = /opt/dbdog-agent ] || fail "x86_64 配方 INSTALL_DIR 不是 /opt/dbdog-agent"
pass "两架构配方共享同一份 Agent/Core 源码锚、同一 GaussDB wheel 身份、同一 install root"

grep -Fq 'VERSION 必须是 7.81.0-dbdog.N（N 从 1 开始），实际为 $VERSION' "$RECIPE_AARCH64" \
  || fail "aarch64 配方版本前缀合约措辞发生变化（回归基线）"
grep -Fq '^7[.]81[.]0-dbdog[.][1-9][0-9]*$' "$RECIPE_AARCH64" \
  || fail "aarch64 配方丢失版本正则（回归）"
grep -Fq '^7[.]81[.]0-dbdog[.][1-9][0-9]*$' "$RECIPE_X86_64" \
  || fail "x86_64 配方的 VERSION 正则与 aarch64 配方不一致，两架构必须使用同一 dbdog 版本前缀合约"
pass "两架构配方对 dbdog 版本前缀使用逐字节相同的正则合约"

# ---------------------------------------------------------------------------
# 场景 4：provenance/build.txt 的 architecture 字段（对应 builder_arch 语义）在
# 两架构配方里分别写死为各自架构，不能被共享成同一个值。
# ---------------------------------------------------------------------------
grep -Fq 'require_exact_field "$build_info" architecture aarch64' "$RECIPE_AARCH64" \
  || fail "aarch64 配方没有把 provenance 的 architecture 字段钉死为 aarch64（回归）"
grep -Fq 'require_exact_field "$build_info" architecture x86_64' "$RECIPE_X86_64" \
  || fail "x86_64 配方没有把 provenance 的 architecture 字段钉死为 x86_64"
if grep -Fq 'require_exact_field "$build_info" architecture x86_64' "$RECIPE_AARCH64"; then
  fail "aarch64 配方错误声明了 x86_64 的 architecture provenance"
fi
if grep -Fq 'require_exact_field "$build_info" architecture aarch64' "$RECIPE_X86_64"; then
  fail "x86_64 配方错误声明了 aarch64 的 architecture provenance"
fi
pass "两架构 provenance/build.txt 的 architecture 字段互不相同（builder_arch 语义）"

grep -Fq 'require_exact_field "$build_info" agent_git_sha "$PINNED_AGENT_SHA"' "$RECIPE_AARCH64" \
  || fail "aarch64 配方缺少 agent_git_sha provenance 门禁（回归）"
grep -Fq 'require_exact_field "$build_info" agent_git_sha "$PINNED_AGENT_SHA"' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少 agent_git_sha provenance 门禁"
grep -Fq 'require_exact_field "$build_info" integrations_core_git_sha "$PINNED_INTEGRATION_CORE_SHA"' "$RECIPE_AARCH64" \
  || fail "aarch64 配方缺少 integrations_core_git_sha provenance 门禁（回归）"
grep -Fq 'require_exact_field "$build_info" integrations_core_git_sha "$PINNED_INTEGRATION_CORE_SHA"' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少 integrations_core_git_sha provenance 门禁"
grep -Fq 'require_exact_field "$build_info" version "$VERSION"' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少 version provenance 门禁"
pass "两架构 provenance/build.txt 都把 agent_git_sha/integrations_core_git_sha/version 钉死为共享锚点（同 PINNED_AGENT_SHA/PINNED_INTEGRATION_CORE_SHA/VERSION 常量，见场景 3）"

# ---------------------------------------------------------------------------
# 场景 5：ARCH 输入门禁与原生主机门禁——x86_64 配方只接受 x86_64，且拒绝
# QEMU/交叉构建（要求构建机 uname -m 也是 x86_64），与 aarch64 配方的对称写法
# 一一对应但互不相同。
# ---------------------------------------------------------------------------
grep -Fq '[[ $ARCH == aarch64 ]] || die "ARCH 必须是 aarch64，实际为 $ARCH"' "$RECIPE_AARCH64" \
  || fail "aarch64 配方的 ARCH 门禁措辞发生变化（回归）"
grep -Fq '[ "$ARCH" = x86_64 ] || die "本配方只构建 x86_64，收到 ARCH=$ARCH"' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少 ARCH 门禁"
grep -Fq '[[ $(uname -m) == aarch64 ]] || die' "$RECIPE_AARCH64" \
  || fail "aarch64 配方缺少原生主机门禁（回归）"
grep -Fq '[ "$(uname -m)" = x86_64 ] ||' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少原生主机门禁"
grep -Fq 'QEMU' "$RECIPE_X86_64" \
  || fail "x86_64 配方没有显式拒绝 QEMU/交叉构建产物冒充原生 release"
pass "两架构配方各自拒绝错误 ARCH 输入，且都要求构建机是对应架构的原生主机（拒绝 QEMU）"

# ---------------------------------------------------------------------------
# 场景 6：不得把已安装目录反向打包成 release——x86_64 配方必须每次从固定 SHA
# 全新 checkout，并且有确定性打包自检（连续两次打包字节相同才允许发布）。
# ---------------------------------------------------------------------------
grep -Fq 'git clone -q --no-hardlinks "$source_repo" "$dest"' "$RECIPE_X86_64" \
  || fail "x86_64 配方不是从固定 SHA 做 fresh checkout"
grep -Fq 'git -C "$dest" checkout -q --detach "$sha"' "$RECIPE_X86_64" \
  || fail "x86_64 配方没有把 fresh checkout 精确 detach 到固定 SHA"
grep -Fq '确定性打包自检失败' "$RECIPE_X86_64" \
  || fail "x86_64 配方缺少确定性打包（连续两次打包字节一致）自检"
pass "x86_64 配方每次从固定 SHA 全新 checkout 并对确定性打包做双构建自检，不反向打包已安装目录"

# ---------------------------------------------------------------------------
# 场景 7：rpath / import / version 门禁齐备（brief Step 3 明确要求）。
# ---------------------------------------------------------------------------
grep -Fq 'verify_runtime_elf_arch' "$RECIPE_X86_64" || fail "x86_64 配方缺少 ELF 架构门禁"
grep -Fq 'write_primary_linkage_report' "$RECIPE_X86_64" || fail "x86_64 配方没有解析真实 RPATH/RUNPATH/DT_NEEDED（见场景 16 的深度断言）"
grep -Fq 'verify_no_path_leaks' "$RECIPE_X86_64" || fail "x86_64 配方没有做全树构建机路径泄漏扫描"
grep -Fq 'verify_gaussdb_import' "$RECIPE_X86_64" || fail "x86_64 配方缺少 GaussDB import 门禁"
grep -Fq 'import datadog_checks.gaussdb' "$RECIPE_X86_64" || fail "x86_64 配方没有真实 import GaussDB 集成模块"
grep -Fq 'verify_agent_version_and_provenance' "$RECIPE_X86_64" || fail "x86_64 配方缺少 Agent version 门禁"
grep -Fq 'verify_system_probe_version_and_provenance' "$RECIPE_X86_64" || fail "x86_64 配方缺少 system-probe version 门禁"
grep -Fq 'Agent $VERSION - Commit: ${SHA:0:10} - Serialization version: ' "$RECIPE_X86_64" \
  || fail "x86_64 配方的 Agent version 输出门禁没有绑定外层 VERSION/SHA"
grep -Fq 'System Probe $VERSION - Commit: ${SHA:0:10} - Serialization version: ' "$RECIPE_X86_64" \
  || fail "x86_64 配方的 system-probe version 输出门禁没有绑定外层 VERSION/SHA"
pass "x86_64 配方的 rpath/import/version/provenance 门禁齐备"

# ---------------------------------------------------------------------------
# 场景 8：dbdog-agent-x86_64.sh 里可复用的纯函数（require_exact_field /
# read_exact_field / verify_wheel_metadata 的 Python 元数据断言）与 aarch64
# 配方语义一致——通过 source 直接复用，不重新实现一遍断言逻辑。BASH_SOURCE 守卫
# 保证 source 不会触发 main()（不会因为没设置 MODULE/VERSION 而 die）。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"

  sample="$TEST_ROOT/sample.kv"
  printf 'key=value\nother=1\n' >"$sample"
  require_exact_field "$sample" key value \
    || fail "require_exact_field 未能确认存在的精确字段"
  if (require_exact_field "$sample" key wrong) 2>/dev/null; then
    fail "require_exact_field 没有拒绝不匹配的字段值"
  fi
  [ "$(read_exact_field "$sample" other)" = 1 ] \
    || fail "read_exact_field 未能读出唯一字段值"

  printf 'dup=1\ndup=2\n' >"$sample"
  if (require_exact_field "$sample" dup 1) 2>/dev/null; then
    fail "require_exact_field 没有拒绝重复键"
  fi
) || exit 1
pass "x86_64 配方的 require_exact_field/read_exact_field 复用自 aarch64 同名合约（唯一键、精确匹配、拒绝重复）"

# ---------------------------------------------------------------------------
# 场景 9：agent-build/x86_64/README.md 只记录输入 SHA、原生 x86_64、安装根、
# 验证命令和输出合同，不落地主机名/密码/一次性工作目录。
# ---------------------------------------------------------------------------
[ -f "$X86_64_README" ] || fail "缺少 scripts/publish/agent-build/x86_64/README.md"
grep -Fq "$aarch64_agent_sha" "$X86_64_README" \
  || fail "x86_64 README 没有记录固定的 Agent 源码锚"
grep -Fq "$aarch64_core_sha" "$X86_64_README" \
  || fail "x86_64 README 没有记录固定的 integrations-core 源码锚"
grep -Fq '/opt/dbdog-agent' "$X86_64_README" \
  || fail "x86_64 README 没有记录安装根"
# 只匹配凭证语境；bare "token" 会误伤 RPATH/$ORIGIN 的正当 ELF 术语
# "dynamic-loader token"（见下方"Linkage and path-leak gates"一节），因此收窄到
# 凭证型用法，不整体禁用这个词。
grep -Eiq 'password|passwd|secret|(access|auth|api|bearer)[ _-]?token|token[=:]' "$X86_64_README" \
  && fail "x86_64 README 疑似泄漏密码/密钥类字样"
grep -Eiq '[0-9]{1,3}(\.[0-9]{1,3}){3}' "$X86_64_README" \
  && fail "x86_64 README 疑似写入了具体主机 IP"
pass "agent-build/x86_64/README.md 记录固定 SHA/安装根，未落地主机名/密码/IP"

# ===========================================================================
# 修复轮 1（评审 Important 1/2）：
#   Important 1 — provenance/agent-data-plane.txt 不能是两行静态占位内容；ADP
#     必须纳入 RUNTIME_BINARIES 与 ELF/rpath 门禁，且按 aarch64 语义生成
#     （binary 存在性 + Omnibus 自己的 version-manifest.json 交叉验证 +
#     binary sha256）。
#   Important 2 — rpath 门禁不能是 4 前缀黑名单；必须对齐
#     finalize-agent-runtime-v3.sh 的 write_primary_linkage_report（解析真实
#     RPATH/RUNPATH token、DT_NEEDED 闭包）与 verify_no_path_leaks（全树字节级
#     构建机路径泄漏扫描）。
#
# 下面的场景尽量真实执行配方里的纯函数（不需要 readelf/GNU readlink 的部分：
# is_baseline_system_library、resolve_rpath_search_dir 的拒绝路径、
# dt_needed_is_resolved_in_runtime、verify_no_path_leaks、
# read_adp_version_manifest_entry——后者通过把 embedded/bin/python3 软链接到
# 系统 python3 来复用真实的 JSON 解析/校验逻辑），而不是只 grep 注释或函数名。
# readelf 编排本身（write_primary_linkage_report 的主循环）和 GNU
# `readlink -m` 依赖的成功解析路径在本仓的 macOS 沙箱里无法真实执行（既没有
# readelf，BSD readlink 也没有 -m），只能用精确的代码结构断言覆盖——这与本文件
# 其余场景、以及 test-agent-artifact-contracts.sh 对 aarch64 配方的验证方式一致
# （aarch64 配方同样从未在本沙箱里真实跑过，只做静态语法/结构检查）。
# ===========================================================================

TEST_ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-agent-x86-linkage.XXXXXX")"
trap 'case "$TEST_ROOT2" in "${TMPDIR:-/tmp}"/dbdog-agent-x86-linkage.*) rm -rf -- "$TEST_ROOT2" ;; esac' EXIT

# ---------------------------------------------------------------------------
# 场景 10：RUNTIME_BINARIES 真的包含 agent-data-plane（不是靠 grep 猜测数组内容）。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  found=0
  for b in "${RUNTIME_BINARIES[@]}"; do
    [ "$b" = "embedded/bin/agent-data-plane" ] && found=1
  done
  [ "$found" = 1 ] || fail "RUNTIME_BINARIES 数组里没有 embedded/bin/agent-data-plane"
  [ "${#RUNTIME_BINARIES[@]}" -ge 5 ] || fail "RUNTIME_BINARIES 少于 5 项，ADP 未被真正纳入"
) || exit 1
pass "source 配方后确认 RUNTIME_BINARIES 真实包含 agent-data-plane（并入 ELF/rpath 门禁范围）"

# ---------------------------------------------------------------------------
# 场景 11：is_baseline_system_library 真实执行——正确识别基础系统库与非基础库。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  is_baseline_system_library libc.so.6 || fail "libc.so.6 应被识别为基础系统库"
  is_baseline_system_library ld-linux-x86-64.so.2 || fail "x86_64 动态加载器应被识别为基础系统库"
  if is_baseline_system_library libdatadog-totally-not-a-system-lib.so.1 2>/dev/null; then
    fail "非基础库被错误识别为基础系统库"
  fi
) || exit 1
pass "is_baseline_system_library 真实执行：正确区分基础系统库与非基础库"

# ---------------------------------------------------------------------------
# 场景 12：resolve_rpath_search_dir 真实执行——拒绝绝对路径逃逸、拒绝非 ORIGIN
# 相对路径、拒绝空 token（这三条判断都在触达 GNU `readlink -m` 之前完成，因此
# 在没有 GNU coreutils 的沙箱里也能真实验证）。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  fixture_root="$TEST_ROOT2/rpath-fixture"
  mkdir -p "$fixture_root"

  if (resolve_rpath_search_dir "$fixture_root" "embedded/bin/agent" "/etc") \
      2>"$TEST_ROOT2/escape.log"; then
    fail "resolve_rpath_search_dir 没有拒绝逃逸到私有 runtime 之外的绝对路径"
  fi
  grep -Fq 'escapes the private runtime' "$TEST_ROOT2/escape.log" \
    || fail "逃逸拒绝没有给出预期诊断信息"

  if (resolve_rpath_search_dir "$fixture_root" "embedded/bin/agent" "../lib") \
      2>"$TEST_ROOT2/relative.log"; then
    fail "resolve_rpath_search_dir 没有拒绝非 \$ORIGIN 相对路径"
  fi
  grep -Fq 'relative non-ORIGIN' "$TEST_ROOT2/relative.log" \
    || fail "非 ORIGIN 相对路径拒绝没有给出预期诊断信息"

  if (resolve_rpath_search_dir "$fixture_root" "embedded/bin/agent" "") \
      2>"$TEST_ROOT2/empty.log"; then
    fail "resolve_rpath_search_dir 没有拒绝空 RPATH/RUNPATH 分量"
  fi
  grep -Fq 'empty RPATH/RUNPATH component' "$TEST_ROOT2/empty.log" \
    || fail "空分量拒绝没有给出预期诊断信息"
) || exit 1
pass "resolve_rpath_search_dir 真实执行：拒绝绝对路径逃逸/非 ORIGIN 相对路径/空分量"

# ---------------------------------------------------------------------------
# 场景 13：dt_needed_is_resolved_in_runtime 真实执行——外部绝对路径 die，能在
# 已解析 search dir 里找到的 soname 判定为已解析，找不到的判定为未解析。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  fixture_root="$TEST_ROOT2/needed-fixture"
  mkdir -p "$fixture_root/embedded/lib"
  : >"$fixture_root/embedded/lib/libpresent.so"

  if (dt_needed_is_resolved_in_runtime "$fixture_root" "embedded/bin/agent" \
      "/usr/lib/libexternal.so" "") 2>"$TEST_ROOT2/external.log"; then
    fail "dt_needed_is_resolved_in_runtime 没有拒绝包含外部绝对路径的 DT_NEEDED"
  fi
  grep -Fq 'contains an external path' "$TEST_ROOT2/external.log" \
    || fail "外部绝对路径拒绝没有给出预期诊断信息"

  dt_needed_is_resolved_in_runtime "$fixture_root" "embedded/bin/agent" \
    "libpresent.so" "$fixture_root/embedded/lib" \
    || fail "存在于已解析 search dir 中的 soname 应判定为已解析"

  if dt_needed_is_resolved_in_runtime "$fixture_root" "embedded/bin/agent" \
      "libmissing.so" "$fixture_root/embedded/lib"; then
    fail "不存在于任何已解析 search dir 中的 soname 不应判定为已解析"
  fi
) || exit 1
pass "dt_needed_is_resolved_in_runtime 真实执行：外部绝对路径 fail closed，runtime 内闭包判定正确"

# ---------------------------------------------------------------------------
# 场景 14：verify_no_path_leaks 真实执行——整树字节级扫描抓到构建机私有路径
# 泄漏（含运行期 $WORK 与固定前缀两类 needle），干净树放行。
# ---------------------------------------------------------------------------
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  fixture_root="$TEST_ROOT2/leak-fixture"
  mkdir -p "$fixture_root/dir"
  WORK="/home/dbdog/work/dbdog-agent/some-unique-marker-$$"

  printf 'clean content, no leaks\n' >"$fixture_root/dir/clean.txt"
  if ! (verify_no_path_leaks "$fixture_root") 2>"$TEST_ROOT2/clean.log"; then
    fail "干净的树被 verify_no_path_leaks 错误拒绝: $(cat "$TEST_ROOT2/clean.log")"
  fi

  printf 'leaked build path: %s/scratch\n' "$WORK" >"$fixture_root/dir/leak-work.txt"
  if (verify_no_path_leaks "$fixture_root") 2>"$TEST_ROOT2/leak-work.log"; then
    fail "verify_no_path_leaks 没有抓到运行期 \$WORK 路径泄漏"
  fi
  grep -Fq "$WORK" "$TEST_ROOT2/leak-work.log" \
    || fail "\$WORK 泄漏诊断信息没有包含实际泄漏的路径"
  rm -f "$fixture_root/dir/leak-work.txt"

  printf 'leaked sealed-style path: /home/dbdog/work/dbdog-agent-anything/x\n' \
    >"$fixture_root/dir/leak-prefix.txt"
  if (verify_no_path_leaks "$fixture_root") 2>"$TEST_ROOT2/leak-prefix.log"; then
    fail "verify_no_path_leaks 没有抓到固定前缀 /home/dbdog/work/dbdog-agent- 的泄漏"
  fi
) || exit 1
pass "verify_no_path_leaks 真实执行：抓到 \$WORK 与固定前缀两类构建机路径泄漏，干净树放行"

# ---------------------------------------------------------------------------
# 场景 15：read_adp_version_manifest_entry 真实执行——把 fixture 的
# embedded/bin/python3 软链接到系统 python3，直接跑配方里内嵌的真实 JSON 解析/
# 校验逻辑（不是重新实现一份等价断言），覆盖合法记录、版本不匹配、记录缺失
# 三种场景。
# ---------------------------------------------------------------------------
SYSTEM_PYTHON3="$(command -v python3 || true)"
if [ -z "$SYSTEM_PYTHON3" ]; then
  fail "本机缺少 python3，无法验证 read_adp_version_manifest_entry（配方本身运行时依赖 embedded python3，逻辑等价）"
fi
(
  # shellcheck source=publish/recipes/dbdog-agent-x86_64.sh
  source "$RECIPE_X86_64"
  fixture_root="$TEST_ROOT2/adp-manifest-fixture"
  mkdir -p "$fixture_root/embedded/bin"
  ln -s "$SYSTEM_PYTHON3" "$fixture_root/embedded/bin/python3"

  sha_a64="$(printf 'a%.0s' $(seq 1 64))"
  cat >"$fixture_root/version-manifest.json" <<JSON
{
  "manifest_format": 2,
  "software": {
    "datadog-agent-data-plane": {
      "locked_version": "$ADP_VERSION",
      "source_type": "url",
      "locked_source": {"sha256": "$sha_a64"}
    }
  }
}
JSON
  info="$(read_adp_version_manifest_entry "$fixture_root")" \
    || fail "合法 version-manifest.json 应该通过 ADP 记录校验"
  parsed_version="${info%%$'\t'*}"
  [ "$parsed_version" = "$ADP_VERSION" ] || fail "解析出的 ADP 版本与 ADP_VERSION 不一致"
  case "$info" in *"$sha_a64"*) ;; *) fail "解析结果没有包含 locked_source.sha256" ;; esac

  cat >"$fixture_root/version-manifest.json" <<JSON
{"manifest_format": 2, "software": {"datadog-agent-data-plane": {"locked_version": "9.9.9", "source_type": "url", "locked_source": {"sha256": "$sha_a64"}}}}
JSON
  if (read_adp_version_manifest_entry "$fixture_root") 2>"$TEST_ROOT2/wrong-version.log"; then
    fail "version-manifest.json 里 ADP 版本与 ADP_VERSION 不一致时应该拒绝"
  fi

  cat >"$fixture_root/version-manifest.json" <<'JSON'
{"manifest_format": 2, "software": {}}
JSON
  if (read_adp_version_manifest_entry "$fixture_root") 2>"$TEST_ROOT2/missing-entry.log"; then
    fail "version-manifest.json 缺少 datadog-agent-data-plane 记录时应该拒绝"
  fi
) || exit 1
pass "read_adp_version_manifest_entry 真实执行：合法记录通过、版本不匹配/记录缺失均 fail closed"

# ---------------------------------------------------------------------------
# 场景 16：write_primary_linkage_report 的编排代码真实调用了上面这几个纯函数
# 和 x86_64 专属的解释器白名单（不是留了个空壳）——readelf 本身在本沙箱不可用，
# 断言精确到具体调用点，而不是泛泛 grep 函数名或注释。
# ---------------------------------------------------------------------------
grep -Fq 'resolved_search_dirs+=("$(resolve_rpath_search_dir "$root" "$relative" "$entry")")' "$RECIPE_X86_64" \
  || fail "write_primary_linkage_report 没有把每个 RPATH/RUNPATH token 交给 resolve_rpath_search_dir 解析"
grep -Fq 'if dt_needed_is_resolved_in_runtime "$root" "$relative" "$needed"' "$RECIPE_X86_64" \
  || fail "write_primary_linkage_report 没有把每条 DT_NEEDED 交给 dt_needed_is_resolved_in_runtime 判定"
grep -Fq '! is_baseline_system_library "$needed"' "$RECIPE_X86_64" \
  || fail "write_primary_linkage_report 没有对非 runtime-resolved 的 DT_NEEDED 做基础系统库放行判断"
grep -Fq '/lib64/ld-linux-x86-64.so.2 | /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2' "$RECIPE_X86_64" \
  || fail "write_primary_linkage_report 缺少 x86_64 专属的 ELF 解释器白名单"
grep -Fq 'unexpected ELF interpreter for $relative' "$RECIPE_X86_64" \
  || fail "write_primary_linkage_report 没有对不在白名单内的解释器 fail closed"
pass "write_primary_linkage_report 的编排代码真实调用 resolve_rpath_search_dir/dt_needed_is_resolved_in_runtime/is_baseline_system_library，且带 x86_64 专属解释器白名单"

# ---------------------------------------------------------------------------
# 场景 17：verify_canonical_artifact 要求 primary-elf-linkage.tsv 是产物成员，
# 并对整包做往返复验（解包到临时目录、重新生成 linkage report、逐字节 cmp、
# 重新跑一遍 verify_no_path_leaks）——不是只在打包前检查一次。
# ---------------------------------------------------------------------------
grep -Fq './provenance/primary-elf-linkage.tsv' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 的必需成员清单缺少 primary-elf-linkage.tsv"
grep -Fq 'tar -xzf "$artifact" -C "$extract_root"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有把整个产物解包用于往返复验"
grep -Fq 'write_primary_linkage_report "$extract_root" "$regenerated_report"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有对解包后的树重新生成 linkage report"
grep -Fq 'cmp -s -- "$regenerated_report" "$packaged_report"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有把重新生成的 linkage report 与打包进产物的版本逐字节比对"
grep -Fq 'verify_no_path_leaks "$extract_root"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有对解包后的树重新跑一遍路径泄漏扫描"
pass "verify_canonical_artifact 对 primary-elf-linkage.tsv 和路径泄漏扫描做解包后往返复验"

# ---------------------------------------------------------------------------
# 场景 18：agent-data-plane 的 binary sha256/version 被交叉记入 build.txt 并在
# verify_canonical_artifact 里重新核对——不是孤立地只存在于 agent-data-plane.txt。
# ---------------------------------------------------------------------------
grep -Fq 'agent_data_plane_binary_sha256=%s' "$RECIPE_X86_64" \
  || fail "write_build_provenance 没有把 ADP binary sha256 写入 build.txt"
grep -Fq '"$AGENT_DATA_PLANE_BINARY_SHA256"' "$RECIPE_X86_64" \
  || fail "write_build_provenance 没有引用 AGENT_DATA_PLANE_BINARY_SHA256 全局变量"
grep -Fq 'require_exact_field "$build_info" agent_data_plane_binary_sha256 "$adp_binary_sha"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有交叉核对 build.txt 与 agent-data-plane.txt 的 binary sha256"
grep -Fq 'require_exact_field "$build_info" agent_data_plane_version "$ADP_VERSION"' "$RECIPE_X86_64" \
  || fail "verify_canonical_artifact 没有核对 build.txt 的 agent_data_plane_version"
pass "agent-data-plane 的 binary sha256/version 交叉记入 build.txt 并在产物复验时重新核对"

# ---------------------------------------------------------------------------
# 场景 19：ADP 身份（ADP_VERSION）在两架构间共享，但输入摘要的信任模型显式不同
# ——不是同名字段静默换了语义却假装一致（评审用语：不许静默同名异义）。
# ---------------------------------------------------------------------------
aarch64_adp_version="$(recipe_readonly "$RECIPE_AARCH64" ADP_VERSION 2>/dev/null || true)"
if [ -z "$aarch64_adp_version" ]; then
  aarch64_adp_version="$(sed -n "s/^readonly ADP_VERSION=//p" "$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v3.sh")"
fi
x86_64_adp_version="$(recipe_readonly "$RECIPE_X86_64" ADP_VERSION)"
[ -n "$aarch64_adp_version" ] || fail "无法从 aarch64 侧（finalize-agent-runtime-v3.sh）读出 ADP_VERSION"
[ "$aarch64_adp_version" = "$x86_64_adp_version" ] \
  || fail "两架构的 ADP_VERSION 不一致（aarch64=$aarch64_adp_version, x86_64=$x86_64_adp_version）"
grep -Fq 'input_source_sha256_authority=measured_from_omnibus_version_manifest_not_independently_pinned' "$RECIPE_X86_64" \
  || fail "x86_64 配方没有显式标注 ADP 输入摘要不是独立验证过的 pin（不许静默同名异义）"
if grep -Fq 'ADP_INPUT_SHA256' "$RECIPE_X86_64"; then
  fail "x86_64 配方不应该编造一个自称已核验的 ADP_INPUT_SHA256（本仓从未为 x86_64 独立验证过该值）"
fi
pass "两架构共享同一 ADP_VERSION 身份；x86_64 显式标注其输入摘要信任模型与 aarch64 不同，不假装同名同义"

# ---------------------------------------------------------------------------
# 场景 20：两仓 README 的同构声明与实际差异保持一致——必须明确提到 ADP 的信任
# 模型差异与 rpath/DT_NEEDED 门禁的深度对齐，不能只字未提。
# ---------------------------------------------------------------------------
DBDOG_AGENT_X86_64_README="$RELEASE_DIR/../dbdog-agent/dbdog-deploy/build/x86_64/README.md"
grep -Fq 'agent-data-plane' "$X86_64_README" \
  || fail "release 仓 x86_64 README 没有提到 agent-data-plane"
grep -Fq 'primary-elf-linkage' "$X86_64_README" \
  || fail "release 仓 x86_64 README 没有提到 primary-elf-linkage 报告"
grep -Eiq 'measured_from_omnibus_version_manifest_not_independently_pinned|从未独立验证|never independently verified' "$X86_64_README" \
  || fail "release 仓 x86_64 README 没有显式说明 ADP 输入摘要的信任模型差异"
if [ -f "$DBDOG_AGENT_X86_64_README" ]; then
  grep -Fq 'agent-data-plane' "$DBDOG_AGENT_X86_64_README" \
    || fail "dbdog-agent 仓 x86_64 README 没有提到 agent-data-plane"
  grep -Fq 'primary-elf-linkage' "$DBDOG_AGENT_X86_64_README" \
    || fail "dbdog-agent 仓 x86_64 README 没有提到 primary-elf-linkage 报告"
  grep -Fq '从未' "$DBDOG_AGENT_X86_64_README" \
    || fail "dbdog-agent 仓 x86_64 README 没有显式说明 ADP 输入摘要的信任模型差异"
  pass "两仓 x86_64 README 都显式记录了 ADP 信任模型差异与 rpath/DT_NEEDED 门禁深度"
else
  pass "release 仓 x86_64 README 显式记录了 ADP 信任模型差异与 rpath/DT_NEEDED 门禁深度（dbdog-agent 仓 README 不在本仓工作树内，另行核对）"
fi

printf 'ALL PASS: Agent x86_64 canonical build contracts\n'
