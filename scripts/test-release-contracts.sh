#!/usr/bin/env bash
# 本机可重复测试：升级依赖顺序与迁移 required 上下文。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-release-contracts.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-release-contracts.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

DBDOG_HOME="$TEST_ROOT/home"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
source "$SCRIPTS_DIR/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

canonicalize_upgrade_modules dbdog-mcp dbdog-web clickhouse dbdog-server goose node postgresql
actual="${ORDERED_UPGRADE_MODULES[*]}"
expected="node goose postgresql clickhouse dbdog-server dbdog-web dbdog-mcp"
[ "$actual" = "$expected" ] || fail "升级顺序错误: $actual"
pass "显式乱序参数被规范为基础运行时 → server → web → MCP"

if (canonicalize_upgrade_modules dbdog-server dbdog-server) >/dev/null 2>&1; then
  fail "重复模块未被拒绝"
fi
if (canonicalize_upgrade_modules '../dbdog-server') >/dev/null 2>&1; then
  fail "不安全模块名未被拒绝"
fi
pass "重复或不安全模块名 fail closed"

hook_root="$TEST_ROOT/module"
mkdir -p "$hook_root/hooks"
cat >"$hook_root/hooks/pre-switch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${DBDOG_MIGRATION_REQUIRED:-}" = 1 ]
[ -n "${DBDOG_HOME:-}" ]
[ -n "${ETC_DIR:-}" ]
[ -n "${MODULES_DIR:-}" ]
EOF
chmod 0755 "$hook_root/hooks/pre-switch.sh"
DBDOG_MIGRATION_REQUIRED=1 run_hook "$hook_root" pre-switch >/dev/null
pass "升级编排把 required=1 传入模块迁移钩子"

printf 'ALL PASS: 3 release contract tests\n'
