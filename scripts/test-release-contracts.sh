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

env_file="$TEST_ROOT/service.env"
cat >"$env_file" <<'EOF'
PG_DSN=postgres://user:pass@127.0.0.1:5432/ctl
DATABASE_URL=postgres://custom@db.internal:5432/ctl
EOF
ensure_env_default "$env_file" PG_DSN \
  'postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable' user:pass
ensure_env_default "$env_file" DATABASE_URL \
  'postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable' user:pass
ensure_env_default "$env_file" CH_DATABASE obs user:pass
grep -Fqx 'PG_DSN=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable' "$env_file" \
  || fail "PG 占位 DSN 未校准"
grep -Fqx 'DATABASE_URL=postgres://custom@db.internal:5432/ctl' "$env_file" \
  || fail "已有真实 DSN 被覆盖"
grep -Fqx 'CH_DATABASE=obs' "$env_file" || fail "缺失 env 默认值未追加"
[ "$(stat -f '%Lp' "$env_file" 2>/dev/null || stat -c '%a' "$env_file")" = 600 ] \
  || fail "env 更新后权限不是 0600"
pass "首次安装校准占位 DSN，但保留已有真实配置"

cat >>"$env_file" <<'EOF'
EMPTY_WITH_COMMENT=                            # placeholder
EOF
ensure_env_default "$env_file" EMPTY_WITH_COMMENT generated change-me
grep -Fqx 'EMPTY_WITH_COMMENT=generated' "$env_file" \
  || fail "带注释的空 env 值未被识别为占位"
[ "$(env_literal_value "$env_file" DATABASE_URL)" = \
    'postgres://custom@db.internal:5432/ctl' ] \
  || fail "env literal 读取错误"
pass "env 默认值更新不执行配置文件，且能识别行尾注释"

mkdir -p "$ETC_DIR"
cat >"$ETC_DIR/dbdog-server.env" <<'EOF'
PG_DSN=postgres://user:pass@127.0.0.1:5432/ctl
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
DBDOG_PUBLIC_BASE_URL=
EOF
cat >"$ETC_DIR/ddsql-server.env" <<'EOF'
DBDOG_PG_SCHEMA=t_1
CH_DATABASE=obs_t_1
EOF
cat >"$ETC_DIR/dbdog-web.env" <<'EOF'
DATABASE_URL=postgres://user:pass@127.0.0.1:5432/ctl
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
DBDOG_OAUTH_JWT_SECRET=abcdef0123456789abcdef0123456789
PUBLIC_APP_URL=change-me
PUBLIC_INGEST_URL=change-me
PUBLIC_MCP_URL=change-me
EOF
cat >"$ETC_DIR/dbdog-mcp.env" <<'EOF'
DBDOG_BASE_URL=http://127.0.0.1:8080
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
DBDOG_OAUTH_JWT_SECRET=abcdef0123456789abcdef0123456789
EOF
# source 只加载函数；main guard 保证测试不会执行安装。
source "$SCRIPTS_DIR/install.sh"
DBDOG_ADVERTISE_HOST=dbdog.internal configure_ready_to_use_stack >/dev/null \
  || fail "一键默认配置生成失败"
grep -Fqx 'PG_DSN=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable' \
  "$ETC_DIR/dbdog-server.env" || fail "server 本机 DSN 未生成"
grep -Fqx 'DATABASE_URL=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable' \
  "$ETC_DIR/dbdog-web.env" || fail "web 本机 DSN 未生成"
grep -Fqx 'DBDOG_PG_SCHEMA=t_1' "$ETC_DIR/ddsql-server.env" \
  || fail "DDSQL 未钉住 default org PG schema"
grep -Fqx 'CH_DATABASE=obs_t_1' "$ETC_DIR/ddsql-server.env" \
  || fail "DDSQL 未钉住 default org CH database"
grep -Fqx 'PUBLIC_APP_URL=http://dbdog.internal:3000' "$ETC_DIR/dbdog-web.env" \
  || fail "web 默认访问 URL 未生成"
grep -Fqx 'DBDOG_PUBLIC_MCP_URL=http://dbdog.internal:8090/mcp' "$ETC_DIR/dbdog-mcp.env" \
  || fail "MCP 默认访问 URL 未生成"
[ "$(env_literal_value "$ETC_DIR/dbdog-server.env" DBDOG_INTERNAL_TOKEN)" = \
  "$(env_literal_value "$ETC_DIR/dbdog-web.env" DBDOG_INTERNAL_TOKEN)" ] \
  || fail "server/web 内部 token 不一致"
[ "$(env_literal_value "$ETC_DIR/dbdog-web.env" DBDOG_OAUTH_JWT_SECRET)" = \
  "$(env_literal_value "$ETC_DIR/dbdog-mcp.env" DBDOG_OAUTH_JWT_SECRET)" ] \
  || fail "web/MCP OAuth secret 不一致"
pass "一键安装自动生成一致的 server/web/MCP 可用配置"

legacy_web_env="$TEST_ROOT/legacy-web.env"
cat >"$legacy_web_env" <<'EOF'
PUBLIC_APP_URL=http://legacy.example:25629
PUBLIC_INGEST_URL=http://legacy.example:21753
PUBLIC_MCP_URL=http://legacy.example:24267/mcp
EOF
DBDOG_ADVERTISE_HOST=dbdog.internal migrate_legacy_web_public_urls "$legacy_web_env" >/dev/null
grep -Fqx 'PUBLIC_APP_URL=http://dbdog.internal:3000' "$legacy_web_env" \
  || fail "旧 Web PUBLIC_APP_URL 未自动迁移"
grep -Fqx 'PUBLIC_INGEST_URL=http://dbdog.internal:8080' "$legacy_web_env" \
  || fail "旧 Web PUBLIC_INGEST_URL 未自动迁移"
grep -Fqx 'PUBLIC_MCP_URL=http://dbdog.internal:8090/mcp' "$legacy_web_env" \
  || fail "旧 Web PUBLIC_MCP_URL 未自动迁移"
pass "正常 Web 升级自动迁移旧验收模板 URL，且无需记录旧域名"

printf 'ALL PASS: 7 release contract tests\n'
