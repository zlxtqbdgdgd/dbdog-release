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

# ---- manifest_get：冲突的爆炸半径必须限定在被查询的模块，不能波及无关模块 ----
# alpha 干净（只有一行 aarch64），beta 与 alpha 无关且自己有 aarch64+noarch 冲突。
# 查 alpha 不该因为 beta 的冲突而失败；查 beta 失败时错误信息必须点名 beta，不能是 alpha。
{
  printf 'alpha\tfirst-party\tstack\tno\t1.0.0\talpha-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_A"
  printf 'beta\tthird-party\tstack\tno\t1.0.0\tbeta-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
  printf 'beta\tthird-party\tstack\tno\t1.0.0\tbeta-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_C"
} >"$TEST_ROOT/blast-radius.tsv"
# 必须同时检查退出码和值：manifest_selected_rows 按文件行序处理模块，alpha 排在 beta 前面时，
# 冲突前已经把 alpha 那一行流式 print 给了下游 awk，即使外层整体判定失败、返回值仍可能"碰巧"
# 是对的——只看 stdout 内容会漏掉「返回了失败状态」这个真正的 bug。
if out="$(MANIFEST="$TEST_ROOT/blast-radius.tsv" manifest_get alpha 6 aarch64)"; then
  [ "$out" = alpha-aarch64.tar.gz ] || fail "alpha 查询返回值错误: $out"
else
  fail '无关模块 beta 的精确/noarch 冲突波及了 alpha 的定向查询（exit 非 0）'
fi
pass 'manifest_get 冲突的爆炸半径限定在被查询的模块，不影响无关模块查询'
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
{
  printf 'multi\tfirst-party\tstack\tno\t1.0.0\tmulti-x86_64.tar.gz\t%s\t-\tx86_64\n' "$SHA_A"
  printf 'multi\tfirst-party\tstack\tno\t1.0.0\tmulti-aarch64.tar.gz\t%s\t-\taarch64\n' "$SHA_B"
  printf 'multi\tfirst-party\tstack\tno\t1.0.0\tmulti-noarch.tar.gz\t%s\t-\tnoarch\n' "$SHA_C"
} >"$TEST_ROOT/arches.tsv"
arches="$(MANIFEST="$TEST_ROOT/arches.tsv" manifest_arches multi | tr '\n' ' ')"
[ "$arches" = 'aarch64 x86_64 noarch ' ] || fail "manifest_arches 顺序错误: $arches"
pass 'manifest_arches 按 aarch64 x86_64 noarch 稳定顺序输出'

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

printf 'ALL PASS: 32 manifest architecture contract tests\n'
