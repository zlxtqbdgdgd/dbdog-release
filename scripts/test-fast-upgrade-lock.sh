#!/usr/bin/env bash
# fast-upgrade.sh 的 with_module_lock 守门。
#
# 背景：构建目录按模块固定在 $BUILD_WORK/<模块>，配方开头统一 `rm -rf src pkg` 再重新
# clone。2026-08-16 一天里三个会话独立撞到同一件事——两个人同时部署同一模块，后到者的
# rm -rf 把先到者的检出删了，报出来的全是「文件凭空消失」（package.json ENOENT、
# required-server-files.json ENOENT、rm 报 Directory not empty、esbuild ENOENT）。
#
# 所以这里钉的是五条硬约束，而不是「日志里有没有打出等待字样」：
#   1. 同模块必须串行（两段临界区不得交叠）——根因就在这条
#   2. 撞锁时是**等**，等到了照常成功，而不是报错退出
#   3. 等不到（超时）必须失败退出，不许硬闯
#   4. 临界区里失败退出不许漏锁，下一次要能立刻拿到
#   5. 临界区里拉起的常驻进程（部署收尾会起服务）不得把锁带走
# 外加一条反向约束：不同模块**不能**被误锁在一起（否则等于把并行能力砍掉）。
#
# 只能在 Linux 上跑（flock(1)；fast-upgrade.sh 本身也依赖 runuser，同样是 Linux-only）。
# 跑法：bash scripts/test-fast-upgrade-lock.sh
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v flock >/dev/null || { echo "SKIP 本机没有 flock(1)，此用例只在构建机（Linux）跑"; exit 0; }

fail=0
ok()  { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# 把被测函数从 fast-upgrade.sh 里原样取出来跑——不复制一份实现来测（复制品测了不算数）。
FN="$(awk '/^with_module_lock\(\)/,/^}$/' "$SCRIPTS_DIR/fast-upgrade.sh")"
[ -n "$FN" ] || { echo "FAIL 没能从 fast-upgrade.sh 取到 with_module_lock"; exit 1; }

TMP="$(mktemp -d /tmp/test-fu-lock.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# 在子 shell 里跑一段用到 with_module_lock 的代码：注入被测函数 + 最小桩。
# as_stack_user 在测试里不切用户（本用例不验身份，验的是互斥语义）。
in_harness() { # <bash 代码>
  bash -c '
    set -uo pipefail
    log()  { printf "[log] %s\n" "$*" >&2; }
    die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }
    as_stack_user() { "$@"; }
    BUILD_WORK="'"$TMP"'"
    LOCK_WAIT="${LOCK_WAIT:-20}"
    '"$FN"'
    '"$1"'
  '
}

# 临界区：进出各打一条带模块名的记录，用于判交叠。
critical() { # <模块> <标记> <占用秒数> → 供 in_harness 使用的代码串
  printf 'with_module_lock %s bash -c "echo %s-in >>%s/trace; sleep %s; echo %s-out >>%s/trace"' \
    "$1" "$2" "$TMP" "$3" "$2" "$TMP"
}

echo "== 1) 同模块串行：两段临界区不得交叠 =="
: >"$TMP/trace"
in_harness "$(critical dbdog-web A 2)" >/dev/null 2>&1 &
p1=$!
in_harness "$(critical dbdog-web B 2)" >/dev/null 2>&1 &
p2=$!
wait $p1; wait $p2
seq1="$(tr '\n' ' ' <"$TMP/trace")"
case "$seq1" in
  "A-in A-out B-in B-out "* | "B-in B-out A-in A-out "*) ok "同模块串行（$seq1）" ;;
  *) bad "同模块临界区交叠了——正是 08-16 那批 ENOENT 的成因（实际：$seq1）" ;;
esac

echo "== 2) 撞锁时等待，等到了照常成功（不是报错退出） =="
: >"$TMP/trace"
in_harness "$(critical dbdog-web C 2)" >/dev/null 2>&1 &
p1=$!
sleep 0.4                       # 确保 C 先拿到锁，D 必然走等待分支
out2="$(in_harness "$(critical dbdog-web D 1)" 2>&1)"; rc2=$?
wait $p1
[ "$rc2" -eq 0 ] && ok "等待方最终成功退出（rc=0）" || bad "等待方不该失败（rc=$rc2）：$out2"
printf '%s' "$out2" | grep -q '另一部署正在进行中' \
  && ok "打出了「另一部署正在进行中，等待…」" \
  || bad "撞锁时没有提示等待，操作者会以为卡死：$out2"
grep -q 'D-in' "$TMP/trace" && ok "等待方拿到锁后确实进了临界区" || bad "等待方没进临界区"

echo "== 3) 等不到就失败退出，不许硬闯 =="
flock -x "$TMP/dbdog-mcp.lock" -c 'sleep 6' &
holder=$!
sleep 0.4
out3="$(LOCK_WAIT=1 in_harness 'with_module_lock dbdog-mcp true' 2>&1)"; rc3=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc3" -ne 0 ] && ok "超时后非零退出（rc=$rc3）" || bad "超时竟然继续跑了——等于硬闯"
printf '%s' "$out3" | grep -q '等锁超时' && ok "超时原因说清楚了" || bad "超时信息不明确：$out3"

echo "== 4) 临界区里失败退出不漏锁 =="
LOCK_WAIT=3 in_harness 'set -e; with_module_lock dbdog-server false' >/dev/null 2>&1
t0=$SECONDS
LOCK_WAIT=3 in_harness 'with_module_lock dbdog-server true' >/dev/null 2>&1; rc4=$?
took=$((SECONDS - t0))
[ "$rc4" -eq 0 ] && [ "$took" -lt 3 ] \
  && ok "上一次 die 之后锁立刻可用（${took}s）" \
  || bad "锁没被释放：rc=$rc4 耗时 ${took}s（fd 应随进程退出由内核释放）"

echo "== 5) 临界区里拉起的常驻进程不得继承锁 =="
# 这条是首版实现真正栽的地方，且**只有跑真部署才暴露**：快升级收尾要起 web 服务，
# 服务进程继承了锁 fd 就跟着常驻，锁再也回不来——第一次部署正常，第二次卡满超时。
# 所以断言写成「常驻子进程还活着时，锁必须已经能拿到」。
pgrep -f 'sleep 47' >/dev/null && pkill -f 'sleep 47'
in_harness 'with_module_lock dbdog-mcp bash -c "setsid sleep 47 </dev/null >/dev/null 2>&1 &"' >/dev/null 2>&1
sleep 0.5
if ! pgrep -f 'sleep 47' >/dev/null; then
  bad "常驻子进程没起来，本用例失去意义（测试自身的问题）"
else
  t0=$SECONDS
  LOCK_WAIT=3 in_harness 'with_module_lock dbdog-mcp true' >/dev/null 2>&1; rc6=$?
  took=$((SECONDS - t0))
  [ "$rc6" -eq 0 ] && [ "$took" -lt 3 ] \
    && ok "临界区结束即释放锁，常驻子进程没把锁带走（${took}s）" \
    || bad "锁被临界区拉起的常驻进程带走了：rc=$rc6 耗时 ${took}s——临界区需要 9>&-"
  pkill -f 'sleep 47'
fi

echo "== 6) 反向约束：不同模块不得被误锁在一起 =="
: >"$TMP/trace"
in_harness "$(critical dbdog-web E 2)" >/dev/null 2>&1 &
p1=$!
in_harness "$(critical dbdog-server F 2)" >/dev/null 2>&1 &
p2=$!
wait $p1; wait $p2
seq5="$(tr '\n' ' ' <"$TMP/trace")"
case "$seq5" in
  "E-in F-in "* | "F-in E-in "*) ok "不同模块并行如常（$seq5）" ;;
  *) bad "不同模块被串行化了，白白砍掉并行能力（实际：$seq5）" ;;
esac

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有用例失败"
exit "$fail"
