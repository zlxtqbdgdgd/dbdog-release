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
grep -Fq 'verify_native_x86_64_elf' "$RECIPE_X86_64" || fail "x86_64 配方缺少 rpath/ELF 架构门禁"
grep -Fq 'patchelf --print-rpath' "$RECIPE_X86_64" || fail "x86_64 配方没有读取 RPATH"
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
grep -Eiq 'password|passwd|secret|token' "$X86_64_README" \
  && fail "x86_64 README 疑似泄漏密码/密钥类字样"
grep -Eiq '[0-9]{1,3}(\.[0-9]{1,3}){3}' "$X86_64_README" \
  && fail "x86_64 README 疑似写入了具体主机 IP"
pass "agent-build/x86_64/README.md 记录固定 SHA/安装根，未落地主机名/密码/IP"

printf 'ALL PASS: Agent x86_64 canonical build contracts\n'
