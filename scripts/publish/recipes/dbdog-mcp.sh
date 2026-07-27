#!/usr/bin/env bash
# 配方：dbdog-mcp。发布构建走 esbuild 单文件 bundle+minify（替代日常的裸 tsc），
# 无 sourcemap / .d.ts —— 对应"防源码泄露"要求。
# 输入 env：MODULE VERSION SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/$MODULE-$VERSION"
rm -rf "$WORK/pkg" "$WORK/src"; mkdir -p "$PKG" "$WORK/out"

log "检出 $SHA"
git -C "$REPO_ROOT/dbdog-mcp" fetch -q origin 2>/dev/null || log "构建机对源仓无 fetch 凭据，用现有本地对象"
git clone -q --shared "$REPO_ROOT/dbdog-mcp" "$WORK/src"
git -C "$WORK/src" checkout -q "$SHA" || die "构建机仓库缺 ${SHA}（先在构建机上刷新该仓，如跑一次部署脚本的 fetch）"
cd "$WORK/src"

log "npm ci + gen-skills + esbuild bundle"
npm ci --no-audit --no-fund >&2
node scripts/gen-skills.mjs >&2
# banner 里补 createRequire：bundle 进来的 CJS 依赖在 ESM 输出下需要 require 可用
npx --yes esbuild src/index.ts --bundle --minify --platform=node --format=esm \
  --target=node20 --log-level=warning \
  "--banner:js=import{createRequire}from'node:module';const require=createRequire(import.meta.url);" \
  --outfile="$PKG/index.js" >&2

# index.js 是 ESM；Node 20 对没有 package scope 的 .js 默认按 CommonJS 加载。
# 只发布运行所需的最小元数据，避免把源码仓的构建脚本/依赖清单一并带入产物。
cat >"$PKG/package.json" <<EOF
{
  "name": "dbdog-mcp",
  "version": "$VERSION",
  "private": true,
  "type": "module"
}
EOF

mkdir -p "$PKG/etc"
cat >"$PKG/etc/dbdog-mcp.env.example" <<'EOF'
# [首跑校准] dbdog-mcp 完整环境合同；install/upgrade 会把 change-me 自动校准。
DBDOG_BASE_URL=http://127.0.0.1:8080
DBDOG_INTERNAL_TOKEN=change-me
DBDOG_OAUTH_JWT_SECRET=change-me
DBDOG_HTTP_HOST=0.0.0.0
DBDOG_HTTP_PORT=8090
DBDOG_OAUTH_ISSUER=change-me
DBDOG_PUBLIC_MCP_URL=change-me
DBDOG_APP_BASE_URL=change-me
EOF
for required_key in \
  DBDOG_BASE_URL DBDOG_INTERNAL_TOKEN DBDOG_OAUTH_JWT_SECRET \
  DBDOG_HTTP_HOST DBDOG_HTTP_PORT DBDOG_OAUTH_ISSUER \
  DBDOG_PUBLIC_MCP_URL DBDOG_APP_BASE_URL; do
  grep -q "^${required_key}=" "$PKG/etc/dbdog-mcp.env.example" \
    || die "MCP 环境模板缺少必需字段: $required_key"
done
echo "$VERSION" >"$PKG/VERSION"

# 纯 JS 单文件 bundle，不含原生模块——产物不分架构
ART="$MODULE-$VERSION-noarch.tar.gz"
ART_PATH="$WORK/out/$ART"
tar -czf "$ART_PATH" -C "$WORK/pkg" "$MODULE-$VERSION"

# 校验最终 tar（而非只校验打包前目录）：元数据必须把 index.js 明确定义为 ESM，
# 且实际入口必须能启动。用随机端口避免和构建机上已有服务冲突。
VERIFY_DIR="$WORK/verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
tar -xzf "$ART_PATH" -C "$VERIFY_DIR"
VERIFY_PKG="$VERIFY_DIR/$MODULE-$VERSION"
node --input-type=commonjs -e '
  const fs = require("node:fs");
  const [path, version] = process.argv.slice(1);
  const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
  if (pkg.name !== "dbdog-mcp" || pkg.version !== version || pkg.type !== "module") process.exit(1);
' "$VERIFY_PKG/package.json" "$VERSION" \
  || die "产物 package.json 缺少正确的 dbdog-mcp ESM 元数据"

SMOKE_LOG="$WORK/mcp-smoke.log"
env DBDOG_HTTP_HOST=127.0.0.1 DBDOG_HTTP_PORT=0 \
  node "$VERIFY_PKG/index.js" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
SMOKE_STARTED=0
for _ in {1..50}; do
  if grep -Fq '[dbdog-mcp] streamable-http' "$SMOKE_LOG"; then
    SMOKE_STARTED=1
    break
  fi
  kill -0 "$SMOKE_PID" 2>/dev/null || break
  sleep 0.1
done
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
if [ "$SMOKE_STARTED" -ne 1 ]; then
  cat "$SMOKE_LOG" >&2
  die "产物 ESM 入口启动校验失败"
fi

log "打包完成 $ART ($(du -h "$ART_PATH" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$ART_PATH"
