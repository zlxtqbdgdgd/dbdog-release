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

log "npm ci + 生成运行时资产 + esbuild bundle"
npm ci --no-audit --no-fund >&2
# Skill manifest/正文/引用文件与 official Tool descriptor 由 gen:assets 内联进代码，产物
# 因此仍是纯代码单文件。开发、测试、发布走同一条读取路径——不存在「测试绿、产物空」的分叉。
npm run gen:assets >&2
EXPECTED_SKILLS=$(find src/skillsets -name skill.json | wc -l | tr -d ' ')
[ "$EXPECTED_SKILLS" -gt 0 ] || die "源码里没有任何 skill.json，拒绝出货"
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

# 只等一行启动日志是不够的：skills 是惰性加载，一个资产都没打进包时服务照样起得来、
# Resource 照样注册，客户端拿到的却是空 catalog。所以这里以真实客户端身份完成 MCP 握手，
# 读 dbdog://mcp/skillsets，并要求条目数与源码里的 skill.json 数量一致。
SMOKE_LOG="$WORK/mcp-smoke.log"
env DBDOG_HTTP_HOST=127.0.0.1 DBDOG_HTTP_PORT=0 \
  node "$VERIFY_PKG/index.js" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
SMOKE_URL=""
for _ in {1..100}; do
  SMOKE_URL=$(sed -n 's|.*streamable-http on \(http://[^ ]*\).*|\1|p' "$SMOKE_LOG" | head -1)
  [ -n "$SMOKE_URL" ] && break
  kill -0 "$SMOKE_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$SMOKE_URL" ]; then
  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
  cat "$SMOKE_LOG" >&2
  die "产物 ESM 入口启动校验失败"
fi

SMOKE_RESULT=$(SMOKE_URL="$SMOKE_URL" EXPECTED_SKILLS="$EXPECTED_SKILLS" node --input-type=module -e '
const url = process.env.SMOKE_URL;
const expected = Number(process.env.EXPECTED_SKILLS);
const headers = { "content-type": "application/json", accept: "application/json, text/event-stream" };
const rpc = async (body, sid) => {
  const res = await fetch(url, { method: "POST", headers: sid ? { ...headers, "mcp-session-id": sid } : headers, body: JSON.stringify(body) });
  const text = await res.text();
  return { res, text };
};
const init = await rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "release-smoke", version: "0" } } });
if (!init.res.ok) throw new Error("initialize failed: " + init.res.status);
const sid = init.res.headers.get("mcp-session-id");
if (!sid) throw new Error("server returned no mcp-session-id");
await rpc({ jsonrpc: "2.0", method: "notifications/initialized" }, sid);
const read = await rpc({ jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: "dbdog://mcp/skillsets" } }, sid);
if (!read.res.ok) throw new Error("resources/read failed: " + read.res.status);
const payload = JSON.parse(read.text.replace(/^data: /gm, "").split("\n").filter((line) => line.startsWith("{")).pop());
const contents = payload?.result?.contents;
if (!Array.isArray(contents) || contents.length === 0) throw new Error("skillsets resource returned no contents");
const catalog = JSON.parse(contents[0].text);
const skills = catalog?.skills;
if (!Array.isArray(skills)) throw new Error("skillsets catalog has no skills array");
if (skills.length !== expected) throw new Error(`skillsets catalog has ${skills.length} skill(s), source has ${expected}`);
console.log(String(skills.length));
' 2>&1) || SMOKE_RC=$?
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
if [ "${SMOKE_RC:-0}" -ne 0 ]; then
  printf '%s\n' "$SMOKE_RESULT" >&2
  cat "$SMOKE_LOG" >&2
  die "产物未能通过 dbdog://mcp/skillsets 校验（skills 可能没打进包）"
fi
log "冒烟通过：dbdog://mcp/skillsets 返回 $SMOKE_RESULT 个 skill，与源码一致"

log "打包完成 $ART ($(du -h "$ART_PATH" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$ART_PATH"
