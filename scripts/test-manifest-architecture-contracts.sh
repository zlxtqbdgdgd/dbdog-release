#!/usr/bin/env bash
# 本机可重复测试：manifest v2（九列，含 arch）的严格解析与按主机架构选择合同。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-manifest-arch.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-manifest-arch.??????) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/publish/publish.sh"

SHA_A=0000000000000000000000000000000000000000000000000000000000000001
SHA_B=0000000000000000000000000000000000000000000000000000000000000002
SHA_C=0000000000000000000000000000000000000000000000000000000000000003

# ---- normalize_arch：规范值与主机别名 ----
[ "$(normalize_arch aarch64)" = aarch64 ] || fail 'aarch64 未原样规范化'
[ "$(normalize_arch arm64)" = aarch64 ] || fail 'arm64 别名未规范化为 aarch64'
[ "$(normalize_arch x86_64)" = x86_64 ] || fail 'x86_64 未原样规范化'
[ "$(normalize_arch amd64)" = x86_64 ] || fail 'amd64 别名未规范化为 x86_64'
[ "$(normalize_arch noarch)" = noarch ] || fail 'noarch 未原样规范化'
if normalize_arch riscv64 >/dev/null 2>&1; then fail 'normalize_arch 接受了未知架构 riscv64'; fi
pass 'normalize_arch 只接受三个规范架构与两个主机输入别名'

# ---- host_arch：DBDOG_HOST_ARCH_OVERRIDE 注入与拒绝未知架构 ----
[ "$(DBDOG_HOST_ARCH_OVERRIDE=arm64 host_arch)" = aarch64 ] || fail 'host_arch 未规范化 arm64 override'
[ "$(DBDOG_HOST_ARCH_OVERRIDE=amd64 host_arch)" = x86_64 ] || fail 'host_arch 未规范化 amd64 override'
# host_arch 对未知架构用 die（直接 exit），必须用命令替换把它隔离在子 shell 里探测，
# 否则裸调用会把本测试脚本自己也一起杀掉。
if out="$(DBDOG_HOST_ARCH_OVERRIDE=riscv64 host_arch 2>&1)"; then
  fail "host_arch 接受了未知的 DBDOG_HOST_ARCH_OVERRIDE: $out"
fi
pass 'host_arch 用 DBDOG_HOST_ARCH_OVERRIDE 规范化主机架构，未知架构 fail closed'

# ---- 精确架构选择、noarch 回退、未知架构拒绝（计划给定用例）----
cat >"$TEST_ROOT/manifest.tsv" <<EOF
agent	first-party	dbhost	no	1.0.0	agent-aarch64.tar.gz	$SHA_A	a:1,c:1	aarch64
agent	first-party	dbhost	no	1.0.0	agent-x86_64.tar.gz	$SHA_B	a:1,c:1	x86_64
tool	third-party	stack	no	1.0.0	tool-noarch.tar.gz	$SHA_C	-	noarch
EOF
MANIFEST="$TEST_ROOT/manifest.tsv"
[ "$(manifest_get agent 6 x86_64)" = agent-x86_64.tar.gz ] || fail '精确架构行未优先选中'
pass 'exact arch wins'
[ "$(manifest_get tool 9 aarch64)" = noarch ] || fail 'noarch 未作为唯一回退'
pass 'explicit noarch fallback'
if manifest_get agent 6 riscv64 >/dev/null 2>&1; then fail '接受了未知架构'; fi
pass '未知架构在 manifest_get 中显式拒绝'

# ---- manifest_get 省略 [arch] 时默认用 host_arch ----
[ "$(DBDOG_HOST_ARCH_OVERRIDE=x86_64 MANIFEST="$TEST_ROOT/manifest.tsv" manifest_get agent 6)" \
  = agent-x86_64.tar.gz ] || fail 'manifest_get 省略 arch 时未默认使用 host_arch'
pass 'manifest_get 省略 [arch] 时按 host_arch 选择'

# manifest_all_rows 校验失败时用 die（直接 exit）。下面统一用命令替换隔离到子 shell
# 里探测，裸调用会把本测试脚本自己也一起杀掉（bash 的 exit 不认 if 条件位置）。

# ---- manifest_all_rows：恰好九列 ----
printf 'm\tfirst-party\tstack\tno\t1.0.0\tm-aarch64.tar.gz\t%s\ta:1\n' "$SHA_A" \
  >"$TEST_ROOT/eight-col.tsv"
if out="$(MANIFEST="$TEST_ROOT/eight-col.tsv" manifest_all_rows 2>&1)"; then
  fail "八列行未被拒绝: $out"
fi
pass '恰好九列 fail closed'

# ---- manifest_all_rows：架构合法性 ----
printf 'm\tfirst-party\tstack\tno\t1.0.0\tm-riscv64.tar.gz\t%s\ta:1\triscv64\n' "$SHA_A" \
  >"$TEST_ROOT/bad-arch.tsv"
if out="$(MANIFEST="$TEST_ROOT/bad-arch.tsv" manifest_all_rows 2>&1)"; then
  fail "未知架构值未被拒绝: $out"
fi
pass '未知架构值 fail closed'

# ---- manifest_all_rows：artifact 后缀必须与架构一致 ----
printf 'm\tfirst-party\tstack\tno\t1.0.0\tm-x86_64.tar.gz\t%s\ta:1\taarch64\n' "$SHA_A" \
  >"$TEST_ROOT/bad-suffix.tsv"
if out="$(MANIFEST="$TEST_ROOT/bad-suffix.tsv" manifest_all_rows 2>&1)"; then
  fail "artifact 后缀与架构不一致未被拒绝: $out"
fi
pass 'artifact 后缀必须与架构一致'

# ---- manifest_all_rows：同一 (module, arch) 不重复 ----
{
  printf 'dup\tfirst-party\tstack\tno\t1.0.0\tdup-aarch64.tar.gz\t%s\ta:1\taarch64\n' "$SHA_A"
  printf 'dup\tfirst-party\tstack\tno\t1.0.0\tdup-aarch64.tar.gz\t%s\ta:1\taarch64\n' "$SHA_A"
} >"$TEST_ROOT/dup.tsv"
if out="$(MANIFEST="$TEST_ROOT/dup.tsv" manifest_all_rows 2>&1)"; then
  fail "重复的 (module, arch) 未被拒绝: $out"
fi
pass 'duplicates fail closed'

# ---- manifest_all_rows：同模块跨架构 version 必须一致 ----
{
  printf 'skew\tfirst-party\tstack\tno\t1.0.0\tskew-aarch64.tar.gz\t%s\ta:1\taarch64\n' "$SHA_A"
  printf 'skew\tfirst-party\tstack\tno\t1.0.1\tskew-x86_64.tar.gz\t%s\ta:1\tx86_64\n' "$SHA_B"
} >"$TEST_ROOT/version-skew.tsv"
if out="$(MANIFEST="$TEST_ROOT/version-skew.tsv" manifest_all_rows 2>&1)"; then
  fail "同模块 version 不一致未被拒绝: $out"
fi
pass '同模块跨架构 version 必须一致'

# ---- manifest_all_rows：同模块跨架构 source_sha 必须一致 ----
{
  printf 'skew2\tfirst-party\tstack\tno\t1.0.0\tskew2-aarch64.tar.gz\t%s\ta:1\taarch64\n' "$SHA_A"
  printf 'skew2\tfirst-party\tstack\tno\t1.0.0\tskew2-x86_64.tar.gz\t%s\ta:2\tx86_64\n' "$SHA_B"
} >"$TEST_ROOT/source-skew.tsv"
if out="$(MANIFEST="$TEST_ROOT/source-skew.tsv" manifest_all_rows 2>&1)"; then
  fail "同模块 source_sha 不一致未被拒绝: $out"
fi
pass '同模块跨架构 source_sha 必须一致'

# ---- manifest_all_rows：未发布声明行（新模块首发登记）----
# 新模块通过 register-module 登记时，在真正发布前 version/artifact/sha256/source_sha
# 全部写 "-"；manifest_all_rows 必须接受这种行，且跳过对 "-" 的 artifact 后缀校验。
printf 'newmod\tthird-party\tdbhost\tno\t-\t-\t-\t-\taarch64\n' >"$TEST_ROOT/declared.tsv"
out="$(MANIFEST="$TEST_ROOT/declared.tsv" manifest_all_rows)" \
  || fail "全 '-' 的未发布声明行被错误拒绝: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
  || fail "未发布声明行未原样透传: $out"
pass 'manifest_all_rows 接受 version/artifact/sha256/source_sha 全为 "-" 的未发布声明行'

{
  printf 'newmod2\tthird-party\tdbhost\tno\t-\t-\t-\t-\taarch64\n'
  printf 'newmod2\tthird-party\tdbhost\tno\t-\t-\t-\t-\tx86_64\n'
} >"$TEST_ROOT/declared-multi.tsv"
[ "$(MANIFEST="$TEST_ROOT/declared-multi.tsv" manifest_arches newmod2 | tr '\n' ' ')" \
  = 'aarch64 x86_64 ' ] \
  || fail 'manifest_arches 未能从未发布声明行读出目标架构'
pass '未发布声明行同样驱动 manifest_arches（发布事务从声明行读目标架构矩阵）'

# ---- manifest_all_rows：未发布声明行必须四列同时为 "-"，不接受半发布状态 ----
printf 'half1\tthird-party\tdbhost\tno\t-\thalf1-0.1.0-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A" \
  >"$TEST_ROOT/half-artifact.tsv"
if out="$(MANIFEST="$TEST_ROOT/half-artifact.tsv" manifest_all_rows 2>&1)"; then
  fail "version=- 但 artifact 是真实值的半发布行未被拒绝: $out"
fi
pass 'version="-" 但 artifact 不是 "-" 的半发布行 fail closed'

printf 'half2\tthird-party\tdbhost\tno\t-\t-\t%s\t-\taarch64\n' "$SHA_A" \
  >"$TEST_ROOT/half-sha.tsv"
if out="$(MANIFEST="$TEST_ROOT/half-sha.tsv" manifest_all_rows 2>&1)"; then
  fail "version=- 但 sha256 是真实值的半发布行未被拒绝: $out"
fi
pass 'version="-" 但 sha256 不是 "-" 的半发布行 fail closed'

printf 'half3\tthird-party\tdbhost\tno\t-\t-\t-\tdeadbee\taarch64\n' \
  >"$TEST_ROOT/half-srcsha.tsv"
if out="$(MANIFEST="$TEST_ROOT/half-srcsha.tsv" manifest_all_rows 2>&1)"; then
  fail "version=- 但 source_sha 是真实值的半发布行未被拒绝: $out"
fi
pass 'version="-" 但 source_sha 不是 "-" 的半发布行 fail closed'

# ---- manifest_all_rows：同模块不能一部分是声明行、一部分是真实行（首发事务是全架构原子替换）----
{
  printf 'mixed\tthird-party\tdbhost\tno\t-\t-\t-\t-\taarch64\n'
  printf 'mixed\tthird-party\tdbhost\tno\t1.0.0\tmixed-1.0.0-x86_64.tar.gz\t%s\t-\tx86_64\n' "$SHA_A"
} >"$TEST_ROOT/mixed.tsv"
if out="$(MANIFEST="$TEST_ROOT/mixed.tsv" manifest_all_rows 2>&1)"; then
  fail "同模块混合声明行与真实行未被拒绝: $out"
fi
pass '同模块混合未发布声明行与已发布真实行 fail closed（version 不一致校验天然覆盖）'

# ---- manifest_all_rows：同模块不能混用 noarch 与具体架构（评审 Important 3）----
# noarch 语义是"这个模块的产物不含机器码，任何架构都能用同一份"；一旦同一个模块
# 又出现具体架构（aarch64/x86_64）行，manifest_selected_rows 的精确/noarch 冲突
# 检测会直接把消费者读取该模块的每一次查询都拒绝掉——这种"能通过 manifest_all_rows
# 但打死所有消费者"的组合必须在写入时就被 manifest_all_rows 本身拒绝，让所有写入者
# （register-module、未来的其它路径）共享同一张网，而不是各自零散校验。
{
  printf 'noarchmix\tthird-party\tstack\tno\t1.0.0\tnoarchmix-1.0.0-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_A"
  printf 'noarchmix\tthird-party\tstack\tno\t1.0.0\tnoarchmix-1.0.0-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
} >"$TEST_ROOT/noarch-then-specific.tsv"
if out="$(MANIFEST="$TEST_ROOT/noarch-then-specific.tsv" manifest_all_rows 2>&1)"; then
  fail "先 noarch 后具体架构的同模块混合未被拒绝: $out"
fi
pass '同模块先出现 noarch 行、再出现具体架构行 fail closed'

{
  printf 'noarchmix2\tthird-party\tstack\tno\t1.0.0\tnoarchmix2-1.0.0-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  printf 'noarchmix2\tthird-party\tstack\tno\t1.0.0\tnoarchmix2-1.0.0-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_B"
} >"$TEST_ROOT/specific-then-noarch.tsv"
if out="$(MANIFEST="$TEST_ROOT/specific-then-noarch.tsv" manifest_all_rows 2>&1)"; then
  fail "先具体架构后 noarch 的同模块混合未被拒绝: $out"
fi
pass '同模块先出现具体架构行、再出现 noarch 行 fail closed（顺序无关，两个方向都拒绝）'

{
  printf 'noarchmix3\tthird-party\tdbhost\tno\t-\t-\t-\t-\taarch64\n'
  printf 'noarchmix3\tthird-party\tdbhost\tno\t-\t-\t-\t-\tnoarch\n'
} >"$TEST_ROOT/noarch-mix-declared.tsv"
if out="$(MANIFEST="$TEST_ROOT/noarch-mix-declared.tsv" manifest_all_rows 2>&1)"; then
  fail "同模块未发布声明行混用 aarch64 与 noarch 未被拒绝: $out"
fi
pass '未发布声明行同样受 noarch/具体架构互斥约束（register-module 混合登记会被同一张网拦住）'

# ---- manifest_all_rows：真实 manifest.tsv（7 个 aarch64 模块 + 1 个 noarch 模块，
# 分属不同模块）不受 noarch 互斥校验影响 ----
real_manifest="$RELEASE_DIR/manifest.tsv"
[ -f "$real_manifest" ] || fail "找不到真实 manifest.tsv: $real_manifest"
MANIFEST="$real_manifest" manifest_all_rows >/dev/null \
  || fail '真实 manifest.tsv 被新的 noarch 互斥校验意外拒绝'
pass '真实 manifest.tsv（各模块单一架构，noarch 与具体架构分属不同模块）通过新校验不受影响'

# ---- manifest_get / manifest_selected_rows：未发布声明行的字段原样可读（version="-"），
# 由调用方按既有的 "-" 语义决定跳过——这是 upgrade.sh/check-upgrade.sh/agent-install.sh
# 已经在用的既有约定，不是新协议。----
[ "$(MANIFEST="$TEST_ROOT/declared.tsv" manifest_get newmod 5 aarch64)" = '-' ] \
  || fail 'manifest_get 未如实返回未发布声明行的 version="-"'
[ "$(MANIFEST="$TEST_ROOT/declared.tsv" manifest_selected_rows '' aarch64 | cut -f5)" = '-' ] \
  || fail 'manifest_selected_rows 未如实返回未发布声明行的 version="-"'
pass 'manifest_get/manifest_selected_rows 如实透传未发布声明行，version="-" 供既有跳过逻辑判断'

# ---- manifest_selected_rows / manifest_get：精确行与 noarch 行同时存在时拒绝猜测 ----
{
  printf 'both\tthird-party\tstack\tno\t1.0.0\tboth-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  printf 'both\tthird-party\tstack\tno\t1.0.0\tboth-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_B"
} >"$TEST_ROOT/conflict.tsv"
if MANIFEST="$TEST_ROOT/conflict.tsv" DBDOG_HOST_ARCH_OVERRIDE=aarch64 manifest_selected_rows \
  >/dev/null 2>&1; then
  fail '同时存在精确行和 noarch 行未报错'
fi
pass '精确行与 noarch 行同时存在时 fail closed，不猜测该选哪一行'
if MANIFEST="$TEST_ROOT/conflict.tsv" manifest_get both 6 aarch64 >/dev/null 2>&1; then
  fail 'manifest_get 未对精确/noarch 冲突报错'
fi
pass 'manifest_get 同样拒绝精确/noarch 冲突'

# ---- manifest_get：beta 自身 noarch+aarch64 冲突的错误信息必须精确点名 beta ----
# alpha 干净（只有一行 aarch64），beta 与 alpha 无关且自己有 aarch64+noarch 冲突。
#
# 注意（评审 Important 3 之后的行为变化）：beta 的 aarch64+noarch 混用现在会被
# manifest_all_rows 在写入侧就整体拒绝（见上面新增的"同模块不能混用 noarch 与
# 具体架构"用例）——manifest_get/manifest_selected_rows 都构建在 manifest_all_rows
# 之上，因此 beta 这一种冲突不再只影响 beta 自己的查询，查 alpha 现在也会因为整份
# manifest 被拒绝而失败。这是有意的：manifest_all_rows 是所有写入者共享的唯一校验
# 点，一旦某个模块的 noarch/具体架构混用能通过它，就说明它已经被 register-module
# 之外的手段写入了 manifest.tsv（违反"正式发布必须经 publish.sh"的项目规则）——
# 这种情况下让整份 manifest 立刻整体报错（而不是悄悄只影响 beta 一个模块），更符合
# 这个代码库一贯的"尽早、响亮地 fail closed"取向，也是评审明确要求的方案。
# manifest_get 自身对 has_exact && has_noarch 的两两冲突检测代码原样保留，作为
# manifest_all_rows 之外的第二道防线（防御性代码，正常路径下不会再被触发）。
{
  printf 'alpha\tfirst-party\tstack\tno\t1.0.0\talpha-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  printf 'beta\tthird-party\tstack\tno\t1.0.0\tbeta-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
  printf 'beta\tthird-party\tstack\tno\t1.0.0\tbeta-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_C"
} >"$TEST_ROOT/blast-radius.tsv"
if out="$(MANIFEST="$TEST_ROOT/blast-radius.tsv" manifest_get alpha 6 aarch64 2>&1)"; then
  fail "beta 的 noarch/具体架构混用现在应该让整份 manifest 被拒绝，查 alpha 也不该成功: $out"
fi
grep -Fq '模块 beta' <<<"$out" \
  || fail "alpha 查询失败时的报错信息应该点名真正有问题的模块 beta: $out"
pass 'manifest_all_rows 对 beta 的 noarch/具体架构混用整体拒绝，查无关模块 alpha 时报错信息仍精确点名 beta'
out="$(MANIFEST="$TEST_ROOT/blast-radius.tsv" manifest_get beta 6 aarch64 2>&1)" && \
  fail "manifest_get 未对 beta 自身的精确/noarch 冲突报错: $out"
case "$out" in
  *"模块 beta"*) ;;
  *) fail "manifest_get 冲突错误信息没有点名真正冲突的模块 beta: $out" ;;
esac
case "$out" in
  *alpha*) fail "manifest_get 冲突错误信息错误地牵连了无关模块 alpha: $out" ;;
esac
pass 'manifest_get 冲突错误信息精确指向真正冲突的模块'
# 批量遍历场景（Task 3 用 manifest_selected_rows "" "$arch"）保持全表 fail-closed 语义不变：
# 同一份 fixture 里 beta 的冲突仍然要让不带模块过滤的全表选择整体失败。
if MANIFEST="$TEST_ROOT/blast-radius.tsv" DBDOG_HOST_ARCH_OVERRIDE=aarch64 manifest_selected_rows \
  >/dev/null 2>&1; then
  fail 'manifest_selected_rows 批量遍历时未对 beta 的冲突整体 fail closed'
fi
pass 'manifest_selected_rows 批量遍历场景仍保持全表 fail-closed 语义'

# ---- manifest_selected_rows / manifest_get：目标架构完全缺失 ----
printf 'onlyx86\tthird-party\tstack\tno\t1.0.0\tonlyx86-x86_64.tar.gz\t%s\t-\tx86_64\n' "$SHA_A" \
  >"$TEST_ROOT/missing.tsv"
out="$(MANIFEST="$TEST_ROOT/missing.tsv" manifest_selected_rows "" aarch64)"
[ -z "$out" ] || fail '完全缺失的模块被错误输出'
pass '模块在目标架构完全缺失时 manifest_selected_rows 跳过，不报错也不输出'
if MANIFEST="$TEST_ROOT/missing.tsv" manifest_get onlyx86 6 aarch64 >/dev/null 2>&1; then
  fail 'manifest_get 对缺失架构的具名模块查询未报错'
fi
pass 'manifest_get 对具名模块缺失所选架构行时 fail closed'

# ---- manifest_selected_rows：target 过滤 ----
{
  printf 'stackmod\tfirst-party\tstack\tyes\t1.0.0\tstackmod-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  printf 'hostmod\tfirst-party\tdbhost\tno\t1.0.0\thostmod-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
} >"$TEST_ROOT/target.tsv"
out="$(MANIFEST="$TEST_ROOT/target.tsv" manifest_selected_rows stack aarch64 | cut -f1)"
[ "$out" = stackmod ] || fail 'target 过滤未生效'
pass 'manifest_selected_rows 按 target 过滤'

# ---- manifest_selected_rows：每个逻辑模块至多一行 ----
lines="$(MANIFEST="$TEST_ROOT/manifest.tsv" manifest_selected_rows "" x86_64 | wc -l | tr -d ' ')"
[ "$lines" = 2 ] || fail "manifest_selected_rows 输出行数不是每模块至多一行: $lines"
pass 'manifest_selected_rows 每个逻辑模块至多一行'

# ---- manifest_arches：固定顺序，不依赖文件中出现顺序 ----
# 注意（评审 Important 3 之后的行为变化）：noarch 不能再与具体架构混用（见上面
# 新增的互斥用例），所以这里不再用"一个模块同时有 x86_64/aarch64/noarch 三行"
# 的 fixture 验证 noarch 排序——那种组合现在会被 manifest_all_rows 直接拒绝。
# 拆成两个 fixture：multi 只用两个具体架构验证 aarch64 排在 x86_64 前面（文件里
# x86_64 先出现）；only-noarch 单独验证 noarch-only 模块的输出。
{
  printf 'multi\tfirst-party\tstack\tno\t1.0.0\tmulti-x86_64.tar.gz\t%s\t-\tx86_64\n' "$SHA_A"
  printf 'multi\tfirst-party\tstack\tno\t1.0.0\tmulti-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
} >"$TEST_ROOT/arches.tsv"
arches="$(MANIFEST="$TEST_ROOT/arches.tsv" manifest_arches multi | tr '\n' ' ')"
[ "$arches" = 'aarch64 x86_64 ' ] || fail "manifest_arches 顺序错误: $arches"
pass 'manifest_arches 按 aarch64 x86_64 稳定顺序输出（不依赖文件中出现顺序）'

printf 'only-noarch\tfirst-party\tstack\tno\t1.0.0\tonly-noarch-1.0.0-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_C" \
  >"$TEST_ROOT/only-noarch.tsv"
[ "$(MANIFEST="$TEST_ROOT/only-noarch.tsv" manifest_arches only-noarch | tr '\n' ' ')" = 'noarch ' ] \
  || fail 'manifest_arches 对 noarch-only 模块输出错误'
pass 'manifest_arches 对 noarch-only 模块（不与具体架构混用）正确输出 noarch'

# ---- publish_migrate_manifest_v2：三个确定后缀被迁移为对应第九列 arch（计划给定用例）----
legacy="$TEST_ROOT/legacy.tsv"
migrated="$TEST_ROOT/migrated.tsv"

for spec in aarch64 x86_64 noarch; do
  printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1-'"$spec"$'.tar.gz\t'"$SHA_A"$'\t-' >"$legacy"
  MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" \
    || fail "已知后缀 $spec 未被 publish_migrate_manifest_v2 接受"
  [ "$(awk -F'\t' '{print NF}' "$migrated")" = 9 ] || fail "迁移结果不是九列: $spec"
  [ "$(cut -f9 "$migrated")" = "$spec" ] || fail "已知后缀 $spec 未映射到第九列 arch=$spec"
done
pass '三个确定后缀（-aarch64/-x86_64/-noarch.tar.gz）被迁移为对应第九列 arch'

[ "$(MANIFEST="$migrated" manifest_all_rows | wc -l | tr -d ' ')" = 1 ] \
  || fail '迁移结果未通过 manifest_all_rows 的严格九列校验'
pass '迁移结果可直接通过 manifest_all_rows 严格校验'

# ---- publish_migrate_manifest_v2：未知后缀 fail closed（计划给定用例）----
printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1.tar.gz\t'"$SHA_A"$'\t-' >"$legacy"
if MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" >/dev/null 2>&1; then
  fail '接受了未知后缀'
fi
pass '未知 artifact 后缀被 publish_migrate_manifest_v2 拒绝（fail closed）'

# ---- publish_migrate_manifest_v2：只允许八列输入，九列或列数异常必须拒绝 ----
printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1-aarch64.tar.gz\t'"$SHA_A"$'\t-\taarch64' >"$legacy"
if MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" >/dev/null 2>&1; then
  fail '已经是九列的输入未被拒绝'
fi
pass '迁移函数拒绝已经是九列的输入'

printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1-aarch64.tar.gz\t'"$SHA_A" >"$legacy"
if MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" >/dev/null 2>&1; then
  fail '七列输入未被拒绝'
fi
pass '迁移函数拒绝列数异常（七列）的输入'

# ---- publish_migrate_manifest_v2：未发布行（artifact=-）必须明确报错，不猜测目标架构 ----
printf '%s\n' $'m\tthird-party\tstack\tno\t-\t-\t-\t-' >"$legacy"
if MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" >/dev/null 2>&1; then
  fail '未发布行（artifact=-）被错误迁移'
fi
pass '未发布行迁移时明确报错（当前未实现按模块目标架构声明生成），不留猜测路径'

# ---- publish_migrate_manifest_v2：注释与空行原样保留，只给数据行加第九列 ----
{
  printf '# header comment\n'
  printf '\n'
  printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1-aarch64.tar.gz\t'"$SHA_A"$'\t-'
} >"$legacy"
MANIFEST="$legacy" publish_migrate_manifest_v2 "$migrated" || fail '含注释/空行的迁移失败'
[ "$(sed -n '1p' "$migrated")" = '# header comment' ] || fail '注释行未原样保留'
[ "$(sed -n '2p' "$migrated")" = '' ] || fail '空行未原样保留'
[ "$(sed -n '3p' "$migrated" | cut -f9)" = aarch64 ] || fail '数据行第九列未正确追加'
pass '迁移只给数据行追加第九列，注释与空行原样保留'

# ---- regen_readme：迁移后 README 版本表新增“架构”列，数据来自 manifest 第九列 ----
readme_test_root="$TEST_ROOT/readme"
mkdir -p "$readme_test_root"
cat >"$readme_test_root/README.md" <<'EOF'
# stub

<!-- VERSION-TABLE:BEGIN -->
placeholder
<!-- VERSION-TABLE:END -->
EOF
printf 'm\tthird-party\tstack\tno\t1\tm-1-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A" \
  >"$readme_test_root/manifest.tsv"
(RELEASE_DIR="$readme_test_root" MANIFEST="$readme_test_root/manifest.tsv" regen_readme) \
  || fail 'regen_readme 执行失败'
grep -Fq '| 模块 | 类别 | 装在 | 版本 | 产物 | 架构 |' "$readme_test_root/README.md" \
  || fail 'README 版本表缺少架构列表头'
grep -Fq '| m | third-party | 全家桶机 | 1 | m-1-aarch64.tar.gz | aarch64 |' \
  "$readme_test_root/README.md" \
  || fail 'README 版本表架构列未正确填充'
pass 'regen_readme 生成的版本表新增架构列，数据取自 manifest 第九列'

# ---- 回归：changed_first_party/cmd_plan 用 8 个变量 read 九列 manifest_rows 时，
# 第 8(source_sha)、9(arch) 列会被 read 原样吞并进最后一个变量（含分隔 tab），
# 导致 source_sha 比较永远不相等、cmd_plan 表格里的记录列夹带内嵌 tab。----
plan_regress_root="$TEST_ROOT/plan-regress"
plan_repo="$plan_regress_root/src/plan-mod"
mkdir -p "$plan_repo"
git init -q "$plan_repo"
git -C "$plan_repo" config user.name dbdog-contract-test
git -C "$plan_repo" config user.email dbdog-contract-test@example.invalid
printf 'seed\n' >"$plan_repo/seed.txt"
git -C "$plan_repo" add -A
git -C "$plan_repo" commit -qm seed >/dev/null
plan_sha="$(git -C "$plan_repo" rev-parse --short=7 HEAD)"

plan_manifest="$plan_regress_root/manifest.tsv"
printf 'plan-mod\tfirst-party\tstack\tno\t1.0.0\tplan-mod-1.0.0-aarch64.tar.gz\t%s\t%s\taarch64\n' \
  "$SHA_A" "$plan_sha" >"$plan_manifest"

changed="$(SRC_ROOT="$plan_regress_root/src" MANIFEST="$plan_manifest" changed_first_party)"
[ -z "$changed" ] \
  || fail "source_sha 未变但 changed_first_party 误报变更（九列被 8 变量 read 吞并第 9 列）: $changed"
pass 'changed_first_party 对九列 manifest 正确解析纯 source_sha，未变更不误报'

# 源仓不存在时 cmd_plan 仍会打印 manifest 记录列（走"源仓缺失"分支），足以验证解析结果，
# 且不需要真实 origin/main 远端。
plan_out="$(SRC_ROOT="$plan_regress_root/does-not-exist" MANIFEST="$plan_manifest" cmd_plan 2>/dev/null)"
plan_line="$(printf '%s\n' "$plan_out" | grep '^plan-mod')"
[ -n "$plan_line" ] || fail "cmd_plan 未输出 plan-mod 这一行: $plan_out"
case "$plan_line" in
  *"$plan_sha"$'\t'*)
    fail "cmd_plan 的 manifest 记录列夹带了被吞并的内嵌 tab/架构值: $plan_line" ;;
esac
printf '%s\n' "$plan_line" | grep -Fq -- "$plan_sha" \
  || fail "cmd_plan 未显示纯净的 source_sha: $plan_line"
pass 'cmd_plan 的 manifest 记录列是纯 source_sha，无内嵌 tab 或被吞并的架构值'

# ---- 消费者跳过未发布模块：check-upgrade.sh 的枚举表把 version="-" 的模块显示为
# "未发布"，且不计入需要升级的数量；upgrade.sh 对未发布模块（无论是默认无参枚举，
# 还是显式点名）都优雅跳过，不尝试下载 "-"。这是 upgrade.sh/check-upgrade.sh 里
# 原本就有的既有约定——manifest_all_rows 在 Task 5 之前会直接拒绝 artifact="-" 的行，
# 这里锁定"声明行一旦能通过 manifest_all_rows，既有的跳过逻辑立即生效"。----
consumer_root="$TEST_ROOT/consumer-skip"
mkdir -p "$consumer_root/home"
consumer_manifest="$consumer_root/manifest.tsv"
{
  # 已发布的 stack 模块，混在一起证明未发布模块不会连累无关模块的正常枚举。
  printf 'published-mod\tthird-party\tstack\tno\t1.0.0\tpublished-mod-1.0.0-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  # 未发布的新模块声明行（对应 register-module 首发登记后、真正发布前的状态）。
  printf 'unpublished-mod\tthird-party\tstack\tno\t-\t-\t-\t-\taarch64\n'
} >"$consumer_manifest"
# published-mod 装的是旧版本（0.9.0 != manifest 的 1.0.0），确保它会被 check-upgrade.sh
# 标记为"需要处理"（带 ←），这样才能和 unpublished-mod 的"未发布"（不带 ←）形成对照——
# "未安装"本身不计入 updates，不足以证明 unpublished-mod 是因为"未发布"才被跳过。
mkdir -p "$consumer_root/home/modules/published-mod/published-mod-0.9.0"
printf '0.9.0\n' >"$consumer_root/home/modules/published-mod/published-mod-0.9.0/.dbdog-manifest-version"
ln -s published-mod-0.9.0 "$consumer_root/home/modules/published-mod/current"

checker_out="$TEST_ROOT/check-upgrade.out"
checker_rc=0
MANIFEST="$consumer_manifest" DBDOG_HOME="$consumer_root/home" DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$SCRIPTS_DIR/check-upgrade.sh" >"$checker_out" 2>&1 || checker_rc=$?
[ "$checker_rc" -eq 10 ] \
  || { sed -n '1,80p' "$checker_out" >&2; fail "check-upgrade.sh 期望因 published-mod 版本不同而以 10 退出，实际 rc=$checker_rc"; }
grep -Eq '^unpublished-mod .*未发布' "$checker_out" \
  || { sed -n '1,80p' "$checker_out" >&2; fail 'check-upgrade.sh 没有把未发布模块显示为"未发布"'; }
if grep -E '^unpublished-mod .*←' "$checker_out" >/dev/null; then
  sed -n '1,80p' "$checker_out" >&2
  fail 'check-upgrade.sh 把未发布模块误标记为需要处理（不应带 ← 标记）'
fi
grep -Eq '^published-mod .*←' "$checker_out" \
  || { sed -n '1,80p' "$checker_out" >&2; fail 'check-upgrade.sh 应该仍然把已发布但版本不同的模块标记为需要处理'; }
pass 'check-upgrade.sh 把 version="-" 的未发布模块显示为"未发布"且不计入需要升级的数量'

# upgrade.sh 显式点名未发布模块：必须优雅跳过（exit 0、明确警告、不下载、不建目录），
# 不打真实网络（不 fake curl——如果代码路径意外走到下载，测试会因为 curl 访问真实网络
# 失败/挂起而暴露问题，而不是静默通过）。
upgrade_named_out="$TEST_ROOT/upgrade-named.out"
MANIFEST="$consumer_manifest" DBDOG_HOME="$consumer_root/home" DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$SCRIPTS_DIR/upgrade.sh" unpublished-mod >"$upgrade_named_out" 2>&1 \
  || { sed -n '1,80p' "$upgrade_named_out" >&2; fail 'upgrade.sh 显式点名未发布模块本应优雅跳过（exit 0）却失败了'; }
grep -Fq 'unpublished-mod 尚未发布，跳过' "$upgrade_named_out" \
  || { sed -n '1,80p' "$upgrade_named_out" >&2; fail 'upgrade.sh 没有对未发布模块给出跳过提示'; }
[ ! -e "$consumer_root/home/modules/unpublished-mod" ] \
  || fail 'upgrade.sh 为未发布模块创建了模块目录，说明尝试了实际安装'
pass 'upgrade.sh 显式点名未发布模块时优雅跳过，不下载、不建目录'

# upgrade.sh 默认无参枚举：未发布模块即使在 manifest 里也绝不出现在升级计划里
# （current 软链不存在，天然不会被无参默认枚举选中——这里额外断言日志没有提到它，
# 锁定"未发布模块不会被默认枚举误当成目标"这条不变式）。
upgrade_default_out="$TEST_ROOT/upgrade-default.out"
MANIFEST="$consumer_manifest" DBDOG_HOME="$consumer_root/home-default" DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$SCRIPTS_DIR/upgrade.sh" >"$upgrade_default_out" 2>&1 || true
if grep -Fq 'unpublished-mod' "$upgrade_default_out"; then
  sed -n '1,80p' "$upgrade_default_out" >&2
  fail 'upgrade.sh 默认无参枚举提到了未发布模块，本应完全跳过'
fi
pass 'upgrade.sh 默认无参枚举完全不涉及未发布模块（未安装且未发布，不会被选中）'

# ---- 评审 Important 4：check-upgrade.sh 不能把 Agent runtime marker 当成所有
# target=dbhost 模块的已装版本——ddprof 等非 Agent 的 dbhost 模块必须借用 stack
# 模块同一套已装状态源（MODULES_DIR/<模块>/current），而不是 Agent 的
# .dbdog-release-version；否则 ddprof 发布后，DB 主机会永远把 Agent 的版本号当成
# ddprof 的"已装"版本，显示"版本不同 ←"、纳入 exit 10，且提示"升级 Agent"这个和
# ddprof 完全无关的操作，永不自愈。----
agent_mix_root="$TEST_ROOT/agent-target-mix"
agent_runtime="$agent_mix_root/agent-runtime"
mkdir -p "$agent_runtime"
agent_mix_manifest="$agent_mix_root/manifest.tsv"
AGENT_MARKER_VERSION="9.99.0-dbdog.1"
AGENT_MANIFEST_VERSION="7.81.0-dbdog.4"
DDPROF_SHA="$(printf 'f%.0s' $(seq 1 64))"
{
  printf 'dbdog-agent\tfirst-party\tdbhost\tno\t%s\tdbdog-agent-%s-aarch64.tar.gz\t%s\tagent:1,core:1\taarch64\n' \
    "$AGENT_MANIFEST_VERSION" "$AGENT_MANIFEST_VERSION" "$SHA_A"
  printf 'ddprof\tthird-party\tdbhost\tno\t0.26.0\tddprof-0.26.0-aarch64.tar.gz\t%s\t-\taarch64\n' \
    "$DDPROF_SHA"
} >"$agent_mix_manifest"
# Agent 的 runtime marker 存在（版本号故意和 dbdog-agent 的 manifest 行、ddprof 的
# manifest 行都不同，这样一旦 ddprof 误借用它就会立刻在"已装"列露出破绽）。
printf '%s\n' "$AGENT_MARKER_VERSION" >"$agent_runtime/.dbdog-release-version"
printf '%s\n' "$SHA_B" >"$agent_runtime/.dbdog-artifact-sha256"

agent_mix_out="$TEST_ROOT/agent-target-mix.out"
agent_mix_rc=0
AGENT_RUNTIME_DIR="$agent_runtime" MANIFEST="$agent_mix_manifest" \
  DBDOG_HOME="$agent_mix_root/home" DBDOG_HOST_ARCH_OVERRIDE=aarch64 \
  bash "$SCRIPTS_DIR/check-upgrade.sh" >"$agent_mix_out" 2>&1 || agent_mix_rc=$?
[ "$agent_mix_rc" -eq 10 ] \
  || { sed -n '1,80p' "$agent_mix_out" >&2; fail "check-upgrade.sh 期望因 Agent 版本不同而以 10 退出，实际 rc=$agent_mix_rc"; }

ddprof_line="$(grep '^ddprof ' "$agent_mix_out" || true)"
[ -n "$ddprof_line" ] || { sed -n '1,80p' "$agent_mix_out" >&2; fail "输出里找不到 ddprof 这一行"; }
case "$ddprof_line" in
  *"$AGENT_MARKER_VERSION"*)
    fail "ddprof 的已装列借用了 Agent runtime marker 的版本号: $ddprof_line" ;;
esac
case "$ddprof_line" in
  *'←'*)
    fail "ddprof 被误标记为需要处理（不应该借 Agent 版本号触发「版本不同」）: $ddprof_line" ;;
esac
printf '%s\n' "$ddprof_line" | grep -Fq '未安装/由专属流程管理' \
  || { sed -n '1,80p' "$agent_mix_out" >&2; fail "ddprof（非 Agent 的 dbhost 模块，没有 MODULES_DIR/current）应该显示未安装/由专属流程管理: $ddprof_line"; }
pass "ddprof（target=dbhost 但不是 dbdog-agent）不借用 Agent runtime marker，未安装时显示专属提示，不被误判为「版本不同」"

agent_line="$(grep '^dbdog-agent ' "$agent_mix_out" || true)"
[ -n "$agent_line" ] || { sed -n '1,80p' "$agent_mix_out" >&2; fail "输出里找不到 dbdog-agent 这一行"; }
printf '%s\n' "$agent_line" | grep -Fq "$AGENT_MARKER_VERSION" \
  || { sed -n '1,80p' "$agent_mix_out" >&2; fail "dbdog-agent 自己的已装列应该仍然读取 Agent runtime marker: $agent_line"; }
printf '%s\n' "$agent_line" | grep -Fq '版本不同' \
  || { sed -n '1,80p' "$agent_mix_out" >&2; fail "dbdog-agent 自己的版本不同判定不应该受影响: $agent_line"; }
grep -Fq 'sudo scripts/upgrade.sh dbdog-agent' "$agent_mix_out" \
  || { sed -n '1,80p' "$agent_mix_out" >&2; fail "dbdog-agent 真的版本不同时，仍应该提示升级 Agent"; }
pass "dbdog-agent 自身仍然正确读取 Agent runtime marker、版本不同时仍计入 agent_updates 并提示升级 Agent（本次修复未改变 Agent 自己的行为）"

printf 'ALL PASS: 44 manifest architecture contract tests\n'
