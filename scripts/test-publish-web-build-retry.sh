#!/usr/bin/env bash
# 本机可重复测试：dbdog-web 出包对 next build「构建追踪抢跑」的有限重试。
#
# 要点是**别重试过头**：只有那一种并行抢跑签名才重试，其余失败必须照常炸——
# 否则一个每次都失败的构建会被当成抖动反复重跑，把真问题拖成谜案。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-web-build-retry.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-web-build-retry.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# shellcheck source=publish/recipes/lib-next-build-retry.sh
source "$SCRIPTS_DIR/publish/recipes/lib-next-build-retry.sh"

# 夹具取 2026-08-10 构建机上抓到的**原样报文**，不手搓同形串（家族军规 1）。
REAL_TRACE_RACE_LOG="$TEST_ROOT/trace-race.log"
cat >"$REAL_TRACE_RACE_LOG" <<'EOF'
✓ Generating static pages using 15 workers (47/47) in 386ms
  Finalizing page optimization ...
  Collecting build traces ...
Error: ENOENT: no such file or directory, open '/home/dbdog/dbdog-release-build/dbdog-web/src/.next/server/app/_not-found/page.js.nft.json'
    at ignore-listed frames {
  errno: -2,
  code: 'ENOENT',
  syscall: 'open',
  path: '/home/dbdog/dbdog-release-build/dbdog-web/src/.next/server/app/_not-found/page.js.nft.json'
}

> Build error occurred
Error: ENOENT: no such file or directory, open '/home/dbdog/dbdog-release-build/dbdog-web/src/.next/server/app/_not-found/page.js.nft.json'
EOF

# 真失败：类型错。跟上面同样是「构建失败」，但绝不能重试。
REAL_TYPE_ERROR_LOG="$TEST_ROOT/type-error.log"
cat >"$REAL_TYPE_ERROR_LOG" <<'EOF'
  Creating an optimized production build ...
✓ Compiled successfully in 18.4s
  Running TypeScript ...
Failed to compile.

./src/lib/example.ts:12:3
Type error: Property 'nope' does not exist on type 'Dataset'.
EOF

# 另一种真失败：磁盘满。同样带 ENOENT 字样，但不是 .nft.json——签名不能宽到认它。
REAL_ENOSPC_LOG="$TEST_ROOT/enospc.log"
cat >"$REAL_ENOSPC_LOG" <<'EOF'
  Collecting build traces ...
Error: ENOENT: no such file or directory, open '/home/dbdog/dbdog-release-build/dbdog-web/src/.next/cache/webpack/x.pack'
> Build error occurred
EOF

is_retryable_next_build_failure "$REAL_TRACE_RACE_LOG" \
  || fail "真实抢跑日志应判为可重试"
pass "抢跑签名命中"

! is_retryable_next_build_failure "$REAL_TYPE_ERROR_LOG" \
  || fail "类型错被误判为可重试——重试只会把真失败重跑一遍"
pass "类型错不重试"

! is_retryable_next_build_failure "$REAL_ENOSPC_LOG" \
  || fail "非 .nft.json 的 ENOENT 被误判为可重试——签名过宽"
pass "别的 ENOENT 不重试"

! is_retryable_next_build_failure "$TEST_ROOT/不存在的日志" \
  || fail "日志文件不存在时不该判为可重试"
pass "无日志不重试"

# ── 重试执行：次数必须正好，多一次少一次都是 bug ──────────────────────────────
mkdir -p "$TEST_ROOT/run"
COUNTER="$TEST_ROOT/run/attempts"

make_build() { # <场景>：写一个假构建命令，按场景决定第几次成功
  cat >"$TEST_ROOT/run/build.sh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$COUNTER"
case "$1" in
  race-then-ok)
    if [ "\$n" -eq 1 ]; then cat "$REAL_TRACE_RACE_LOG"; exit 1; fi
    echo "build ok"; exit 0 ;;
  race-always)  cat "$REAL_TRACE_RACE_LOG"; exit 1 ;;
  type-error)   cat "$REAL_TYPE_ERROR_LOG"; exit 1 ;;
  ok)           echo "build ok"; exit 0 ;;
esac
EOF
  chmod +x "$TEST_ROOT/run/build.sh"
  : >"$COUNTER"
}

attempts() { cat "$COUNTER" 2>/dev/null || echo 0; }

make_build ok
run_next_build_with_one_retry "$TEST_ROOT/run/out.log" "$TEST_ROOT/run/build.sh" >/dev/null 2>&1 \
  || fail "构建成功时不该报错"
[ "$(attempts)" = "1" ] || fail "构建一次就成功时不该重跑（实跑 $(attempts) 次）"
pass "成功不重试（跑 1 次）"

make_build race-then-ok
run_next_build_with_one_retry "$TEST_ROOT/run/out.log" "$TEST_ROOT/run/build.sh" >/dev/null 2>&1 \
  || fail "抢跑后重试应成功"
[ "$(attempts)" = "2" ] || fail "抢跑应正好重试一次（实跑 $(attempts) 次）"
pass "抢跑重试一次即过（跑 2 次）"

make_build race-always
if run_next_build_with_one_retry "$TEST_ROOT/run/out.log" "$TEST_ROOT/run/build.sh" >/dev/null 2>&1; then
  fail "连续两次抢跑应最终失败，不能无限重试"
fi
[ "$(attempts)" = "2" ] || fail "最多重试一次（实跑 $(attempts) 次）"
pass "连续抢跑只重试一次后放弃（跑 2 次）"

make_build type-error
if run_next_build_with_one_retry "$TEST_ROOT/run/out.log" "$TEST_ROOT/run/build.sh" >/dev/null 2>&1; then
  fail "类型错应直接失败"
fi
[ "$(attempts)" = "1" ] || fail "类型错一次都不该重试（实跑 $(attempts) 次）"
pass "类型错不重跑（跑 1 次）"

printf '\n全部通过：%s\n' "$(basename "${BASH_SOURCE[0]}")"
