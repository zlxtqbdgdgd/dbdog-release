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
git -C "$REPO_ROOT/dbdog-mcp" fetch -q origin
git clone -q --shared "$REPO_ROOT/dbdog-mcp" "$WORK/src"
git -C "$WORK/src" checkout -q "$SHA"
cd "$WORK/src"

log "npm ci + gen-skills + esbuild bundle"
npm ci --no-audit --no-fund >&2
node scripts/gen-skills.mjs >&2
# banner 里补 createRequire：bundle 进来的 CJS 依赖在 ESM 输出下需要 require 可用
npx --yes esbuild src/index.ts --bundle --minify --platform=node --format=esm \
  --target=node20 --log-level=warning \
  --banner:js "import{createRequire}from'node:module';const require=createRequire(import.meta.url);" \
  --outfile="$PKG/index.js" >&2

mkdir -p "$PKG/etc"
cat >"$PKG/etc/dbdog-mcp.env.example" <<'EOF'
# [首跑校准] dbdog-mcp 环境变量（对照源仓 README 补齐）
DBDOG_BASE_URL=http://127.0.0.1:8080
EOF
echo "$VERSION" >"$PKG/VERSION"

ART="$MODULE-$VERSION-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "$MODULE-$VERSION"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$WORK/out/$ART"
