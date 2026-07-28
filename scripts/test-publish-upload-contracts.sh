#!/usr/bin/env bash
# 本机可重复测试：GitHub Release 大产物上传的超时、幂等核验与有限重试。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-publish-upload.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-publish-upload.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/home"
cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GH_STATE_DIR:?}"
: "${FAKE_GH_SCENARIO:?}"
: "${FAKE_ASSET_NAME:?}"
: "${FAKE_ASSET_SIZE:?}"
: "${FAKE_ASSET_SHA:?}"
: "${GH_HTTP_TIMEOUT:?}"

for arg in "$@"; do
  [ "$arg" != "--clobber" ] || {
    printf '%s\n' 'test fake: --clobber is forbidden' >&2
    exit 90
  }
done
printf '%s\n' "$GH_HTTP_TIMEOUT" >"$FAKE_GH_STATE_DIR/timeout"

increment() {
  local file="$1" value=0
  [ ! -f "$file" ] || value="$(<"$file")"
  value=$((value + 1))
  printf '%s\n' "$value" >"$file"
  printf '%s\n' "$value"
}

if [ "${1:-}" = "api" ]; then
  api_count="$(increment "$FAKE_GH_STATE_DIR/api-count")"
  if [ "$FAKE_GH_SCENARIO" = "preexisting-identical" ]; then
    printf '%s\t%s\tsha256:%s\n' \
      "$FAKE_ASSET_NAME" "$FAKE_ASSET_SIZE" "$FAKE_ASSET_SHA"
    exit 0
  fi
  # 第一次是上传前同名门禁，所有场景都必须显示不存在。
  [ "$api_count" -gt 1 ] || exit 0
  case "$FAKE_GH_SCENARIO" in
    absent-retry) exit 0 ;;
    remote-identical)
      printf '%s\t%s\tsha256:%s\n' \
        "$FAKE_ASSET_NAME" "$FAKE_ASSET_SIZE" "$FAKE_ASSET_SHA"
      ;;
    remote-conflict)
      printf '%s\t%s\tsha256:%064d\n' \
        "$FAKE_ASSET_NAME" "$FAKE_ASSET_SIZE" 0
      ;;
    *) printf 'unknown fake scenario: %s\n' "$FAKE_GH_SCENARIO" >&2; exit 91 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "release" ] && [ "${2:-}" = "upload" ]; then
  upload_count="$(increment "$FAKE_GH_STATE_DIR/upload-count")"
  case "$FAKE_GH_SCENARIO" in
    absent-retry)
      [ "$upload_count" -gt 1 ] && exit 0
      printf '%s\n' 'test fake: transient TLS failure' >&2
      exit 1
      ;;
    remote-identical | remote-conflict)
      printf '%s\n' 'test fake: response lost after request' >&2
      exit 1
      ;;
    preexisting-identical)
      printf '%s\n' 'test fake: pre-existing asset must not be uploaded' >&2
      exit 93
      ;;
    *) printf 'unknown fake scenario: %s\n' "$FAKE_GH_SCENARIO" >&2; exit 91 ;;
  esac
fi

printf 'unexpected fake gh call: %q ' "$@" >&2
printf '\n' >&2
exit 92
EOF
chmod 0755 "$TEST_ROOT/bin/gh"

artifact="$TEST_ROOT/dbdog-server-0.1.5-aarch64.tar.gz"
printf 'contract-test release artifact\n' >"$artifact"
asset_name="$(basename "$artifact")"
asset_size="$(wc -c <"$artifact" | tr -d '[:space:]')"
asset_sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"

unset GH_HTTP_TIMEOUT
export DBDOG_HOME="$TEST_ROOT/home"
export RELEASE_DIR="$RELEASE_ROOT"
export PUBLISH_UPLOAD_MAX_ATTEMPTS=3
export PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0
# shellcheck source-path=SCRIPTDIR
# shellcheck source=publish/publish.sh
source "$SCRIPTS_DIR/publish/publish.sh"

[ "$GH_HTTP_TIMEOUT" = 120 ] || fail "默认 GH_HTTP_TIMEOUT 不是 120 秒: $GH_HTTP_TIMEOUT"
# shellcheck disable=SC2016 # 这段脚本由子 bash 展开 GH_HTTP_TIMEOUT。
override_timeout="$(env GH_HTTP_TIMEOUT=77 DBDOG_HOME="$TEST_ROOT/override-home" \
  RELEASE_DIR="$RELEASE_ROOT" bash -c 'source "$1"; printf "%s" "$GH_HTTP_TIMEOUT"' \
  _ "$SCRIPTS_DIR/publish/publish.sh")"
[ "$override_timeout" = 77 ] || fail "调用者不能覆盖 GH_HTTP_TIMEOUT: $override_timeout"
pass "gh HTTP 超时默认 120 秒且允许调用者覆盖"

run_case() { # <scenario>
  local scenario="$1" state_dir
  state_dir="$TEST_ROOT/state/$scenario"
  mkdir -p "$state_dir"
  export FAKE_GH_STATE_DIR="$state_dir"
  export FAKE_GH_SCENARIO="$scenario"
  export FAKE_ASSET_NAME="$asset_name"
  export FAKE_ASSET_SIZE="$asset_size"
  export FAKE_ASSET_SHA="$asset_sha"
  PATH="$TEST_ROOT/bin:$PATH" upload_release_asset \
    dbdog-server "$artifact" "$asset_name" "$asset_sha"
}

if (run_case preexisting-identical) >"$TEST_ROOT/preexisting-identical.log" 2>&1; then
  fail "发布开始前已有同名资产时仍被当成幂等成功"
fi
[ ! -e "$TEST_ROOT/state/preexisting-identical/upload-count" ] \
  || fail "发布开始前已有同名资产时仍发起了上传"
grep -Fq '产物桶已存在同名文件，拒绝覆盖' "$TEST_ROOT/preexisting-identical.log" \
  || fail "发布开始前的同名冲突没有明确拒绝原因"
pass "发布开始前已有同名资产时保持版本冲突语义且零上传"

(run_case absent-retry) >"$TEST_ROOT/absent-retry.log" 2>&1 \
  || fail "远端不存在时没有在同一次 publish 内重试"
[ "$(<"$TEST_ROOT/state/absent-retry/upload-count")" = 2 ] \
  || fail "远端不存在场景的上传次数不是 2"
[ "$(<"$TEST_ROOT/state/absent-retry/api-count")" = 2 ] \
  || fail "失败后没有恰好核验一次远端状态"
[ "$(<"$TEST_ROOT/state/absent-retry/timeout")" = 120 ] \
  || fail "GH_HTTP_TIMEOUT 没有导出给 gh 子进程"
pass "首次上传瞬时失败且远端不存在时，只重试上传并成功"

(run_case remote-identical) >"$TEST_ROOT/remote-identical.log" 2>&1 \
  || {
    sed -n '1,120p' "$TEST_ROOT/remote-identical.log" >&2
    fail "失败响应后远端已有正确资产时没有按成功继续"
  }
[ "$(<"$TEST_ROOT/state/remote-identical/upload-count")" = 1 ] \
  || fail "已存在正确远端资产时仍重复上传"
grep -Fq '远端 size/SHA-256 与本地一致' "$TEST_ROOT/remote-identical.log" \
  || fail "正确远端资产没有留下明确的幂等成功日志"
pass "上传响应失败但远端 size/SHA-256 完全一致时幂等成功"

if (run_case remote-conflict) >"$TEST_ROOT/remote-conflict.log" 2>&1; then
  fail "同名远端资产 digest 错误时仍继续发布"
fi
[ "$(<"$TEST_ROOT/state/remote-conflict/upload-count")" = 1 ] \
  || fail "发现同名冲突后仍发起了第二次上传"
grep -Fq '同名资产不一致，拒绝覆盖' "$TEST_ROOT/remote-conflict.log" \
  || fail "同名冲突没有明确 fail closed 原因"
pass "同名远端资产 size/digest 不一致时拒绝覆盖且不重试"

printf 'ALL PASS: 5 publish upload contract tests\n'
