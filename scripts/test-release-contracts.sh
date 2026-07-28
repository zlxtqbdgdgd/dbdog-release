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

# shellcheck disable=SC2016
grep -Fq 'expected_rpath="/home/dbdog/work/dbdog-agent-62ad2979-build1/out/$BUILT_ARTIFACT"' \
  "$SCRIPTS_DIR/publish/publish.sh" || fail "Agent 发布器未钉住 seal 的 canonical out 路径"
# shellcheck disable=SC2016
grep -Fq 'expected_rpath="$BUILD_WORK/$m/out/$BUILT_ARTIFACT"' \
  "$SCRIPTS_DIR/publish/publish.sh" || fail "其他模块的通用 out 路径门禁被放宽"

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
grep -Fqx "DBDOG_RC_KEY_PATH=$DATA_DIR/remote-config.seed" "$ETC_DIR/dbdog-server.env" \
  || fail "server Remote Config seed 路径未自动生成"
[ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] || fail "Remote Config 配置缺失未标记 server 重启"
grep -Fqx 'DBDOG_OAUTH_ISSUER=http://dbdog.internal:3000' "$ETC_DIR/dbdog-mcp.env" \
  || fail "MCP OAuth issuer 缺失时未自动生成"
grep -Fqx 'DBDOG_APP_BASE_URL=http://dbdog.internal:3000' "$ETC_DIR/dbdog-mcp.env" \
  || fail "MCP app URL 缺失时未自动生成"
[ "$DBDOG_MCP_CONFIG_CHANGED" -eq 1 ] || fail "MCP 缺失配置未标记运行态重启"
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

legacy_mcp_env="$TEST_ROOT/legacy-mcp.env"
cat >"$legacy_mcp_env" <<'EOF'
DBDOG_OAUTH_ISSUER=http://legacy.example:25629
DBDOG_PUBLIC_MCP_URL=http://legacy.example:24267/mcp
DBDOG_APP_BASE_URL=http://legacy.example:25629
EOF
DBDOG_ADVERTISE_HOST=dbdog.internal migrate_legacy_mcp_public_urls "$legacy_mcp_env" >/dev/null
grep -Fqx 'DBDOG_OAUTH_ISSUER=http://dbdog.internal:3000' "$legacy_mcp_env" \
  || fail "旧 MCP OAuth issuer 未自动迁移"
grep -Fqx 'DBDOG_PUBLIC_MCP_URL=http://dbdog.internal:8090/mcp' "$legacy_mcp_env" \
  || fail "旧 MCP resource URL 未自动迁移"
grep -Fqx 'DBDOG_APP_BASE_URL=http://dbdog.internal:3000' "$legacy_mcp_env" \
  || fail "旧 MCP app URL 未自动迁移"
[ "$DBDOG_MCP_CONFIG_CHANGED" -eq 1 ] || fail "MCP 配置迁移未要求重启运行态"
grep -Fq 'remote_config_upgrade="$DBDOG_SERVER_CONFIG_CHANGED"' "$SCRIPTS_DIR/upgrade.sh" || \
  fail "Web/MCP 升级触发 server RC 校准后没有安排 Remote Config 验收"
pass "正常 Web/MCP 升级同步迁移 OAuth 三联 URL，并标记运行态重启"

custom_mcp_env="$TEST_ROOT/custom-mcp.env"
cat >"$custom_mcp_env" <<'EOF'
DBDOG_OAUTH_ISSUER=https://console.internal.example
DBDOG_PUBLIC_MCP_URL=https://mcp.internal.example/mcp
DBDOG_APP_BASE_URL=https://console.internal.example
EOF
DBDOG_MCP_CONFIG_CHANGED=0
DBDOG_ADVERTISE_HOST=dbdog.internal migrate_legacy_mcp_public_urls "$custom_mcp_env" >/dev/null
grep -Fqx 'DBDOG_OAUTH_ISSUER=https://console.internal.example' "$custom_mcp_env" \
  || fail "自定义 MCP OAuth issuer 被覆盖"
grep -Fqx 'DBDOG_PUBLIC_MCP_URL=https://mcp.internal.example/mcp' "$custom_mcp_env" \
  || fail "自定义 MCP resource URL 被覆盖"
[ "$DBDOG_MCP_CONFIG_CHANGED" -eq 0 ] || fail "自定义 MCP 配置被误判为旧模板"
pass "自定义 MCP 域名和反代地址保持不变"

# Web 已有真实反代地址、MCP 对应字段缺失时，Web 是授权服务器和页面入口，必须把
# 现有地址继承给 MCP，不能重新猜测部署机 IP。
custom_stack="$TEST_ROOT/custom-stack"
mkdir -p "$custom_stack"
cat >"$custom_stack/dbdog-server.env" <<'EOF'
PG_DSN=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
EOF
cat >"$custom_stack/dbdog-web.env" <<'EOF'
DATABASE_URL=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
DBDOG_OAUTH_JWT_SECRET=abcdef0123456789abcdef0123456789
PUBLIC_APP_URL=https://console.internal.example
PUBLIC_MCP_URL=https://mcp.internal.example/mcp
EOF
cat >"$custom_stack/dbdog-mcp.env" <<'EOF'
DBDOG_BASE_URL=http://127.0.0.1:8080
DBDOG_INTERNAL_TOKEN=0123456789abcdef0123456789abcdef
DBDOG_OAUTH_JWT_SECRET=abcdef0123456789abcdef0123456789
EOF
(
  ETC_DIR="$custom_stack"
  DBDOG_ADVERTISE_HOST=should-not-win.internal configure_ready_to_use_stack >/dev/null
) || fail "MCP 未能继承 Web 已有的自定义 OAuth 地址"
grep -Fqx 'DBDOG_OAUTH_ISSUER=https://console.internal.example' \
  "$custom_stack/dbdog-mcp.env" || fail "MCP issuer 没有继承 Web PUBLIC_APP_URL"
grep -Fqx 'DBDOG_APP_BASE_URL=https://console.internal.example' \
  "$custom_stack/dbdog-mcp.env" || fail "MCP app URL 没有继承 Web PUBLIC_APP_URL"
grep -Fqx 'DBDOG_PUBLIC_MCP_URL=https://mcp.internal.example/mcp' \
  "$custom_stack/dbdog-mcp.env" || fail "MCP resource 没有继承 Web PUBLIC_MCP_URL"
pass "已有 Web 自定义域名作为权威配置自动同步给缺失的 MCP 字段"

custom_rc_stack="$TEST_ROOT/custom-rc-stack"
mkdir -p "$custom_rc_stack"
cp "$ETC_DIR/dbdog-server.env" "$custom_rc_stack/dbdog-server.env"
cp "$ETC_DIR/dbdog-web.env" "$custom_rc_stack/dbdog-web.env"
cp "$ETC_DIR/dbdog-mcp.env" "$custom_rc_stack/dbdog-mcp.env"
# 替换前面生成的默认值，模拟真实部署中已有自定义路径。
awk '/^DBDOG_RC_KEY_PATH=/{print "DBDOG_RC_KEY_PATH=/srv/dbdog/keys/custom.seed"; next} {print}' \
  "$custom_rc_stack/dbdog-server.env" \
  >"$custom_rc_stack/dbdog-server.env.tmp"
mv "$custom_rc_stack/dbdog-server.env.tmp" "$custom_rc_stack/dbdog-server.env"
chmod 0600 "$custom_rc_stack/dbdog-server.env"
(
  ETC_DIR="$custom_rc_stack"
  DBDOG_ADVERTISE_HOST=dbdog.internal configure_ready_to_use_stack >/dev/null
) || fail "已有 Remote Config seed 路径的配置校准失败"
grep -Fqx 'DBDOG_RC_KEY_PATH=/srv/dbdog/keys/custom.seed' \
  "$custom_rc_stack/dbdog-server.env" || fail "已有 Remote Config seed 路径被覆盖"
pass "升级保留已有 Remote Config signing seed 路径"

# 用本机 Node + 假 PG/HTTP 响应跑完整的 OAuth 专项验收，保证 JSON 字段、发现链和
# WWW-Authenticate 解析不是只写了代码却从未执行。
mkdir -p "$MODULES_DIR/node/current/bin" "$MODULES_DIR/postgresql/current/bin"
ln -s "$(command -v node)" "$MODULES_DIR/node/current/bin/node"
cat >"$MODULES_DIR/postgresql/current/bin/psql" <<'EOF'
#!/usr/bin/env bash
printf 't\n'
EOF
chmod 0755 "$MODULES_DIR/postgresql/current/bin/psql"
# source 只加载函数；main guard 保证测试不会执行真实验收。
source "$SCRIPTS_DIR/verify.sh"
retry_http() {
  case "$1" in
    *:8080/api/v0.1/configuration-root)
      [ "${2:-}" = -H ] || return 1
      case "${3:-}" in @*) rc_header_file="${3#@}" ;; *) return 1 ;; esac
      grep -Fqx \
        'Authorization: Bearer 0123456789abcdef0123456789abcdef' \
        "$rc_header_file" || return 1
      printf '%s\n' "$rc_header_file" >"$TEST_ROOT/rc-auth-header-path"
      printf '%s\n' '{"signed":{"_type":"root","version":1,"keys":{"k":{}},"roles":{"root":{}}},"signatures":[{"keyid":"k","sig":"s"}]}'
      ;;
    *:3000/.well-known/oauth-authorization-server)
      printf '%s\n' '{"issuer":"http://dbdog.internal:3000","authorization_endpoint":"http://dbdog.internal:3000/oauth/authorize","token_endpoint":"http://dbdog.internal:3000/oauth/token","registration_endpoint":"http://dbdog.internal:3000/oauth/register","code_challenge_methods_supported":["S256"]}'
      ;;
    *:8090/.well-known/oauth-protected-resource)
      printf '%s\n' '{"resource":"http://dbdog.internal:8090/mcp","authorization_servers":["http://dbdog.internal:3000"],"bearer_methods_supported":["header"]}'
      ;;
    *) return 1 ;;
  esac
}
curl() {
  printf 'HTTP/1.1 401 Unauthorized\r\n'
  printf 'www-authenticate: Bearer resource_metadata="http://dbdog.internal:8090/.well-known/oauth-protected-resource"\r\n\r\n'
}
oauth_main >/dev/null || fail "OAuth 专项升级验收未通过完整执行"
pass "OAuth 专项验收覆盖表结构、发现元数据与 401 challenge"

mkdir -p "$DATA_DIR"
install -m 0600 /dev/null "$DATA_DIR/remote-config.seed"
remote_config_main >/dev/null || fail "Remote Config 专项升级验收未通过完整执行"
[ -s "$TEST_ROOT/rc-auth-header-path" ] || fail "Remote Config 验收未携带内部凭证"
rc_auth_header="$(cat "$TEST_ROOT/rc-auth-header-path")"
[ ! -e "$rc_auth_header" ] || fail "Remote Config 验收遗留了含内部凭证的临时文件"
pass "Remote Config 验收覆盖内部认证、seed 权限与 TUF root 结构"

printf 'ALL PASS: 13 release contract tests\n'
