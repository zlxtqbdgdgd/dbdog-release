#!/usr/bin/env bash
# 配方：dbdog-web。构建时向临时检出注入 standalone 和禁用图片优化
# （不侵入源仓），只发编译产物（无 src/、无 sourcemap），附 drizzle 迁移与钩子。
# 输入 env：MODULE VERSION SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/$MODULE-$VERSION"
rm -rf "$WORK/pkg" "$WORK/src"; mkdir -p "$PKG" "$WORK/out"

log "检出 $SHA"
git -C "$REPO_ROOT/dbdog-web" fetch -q origin 2>/dev/null || log "构建机对源仓无 fetch 凭据，用现有本地对象"
git clone -q --shared "$REPO_ROOT/dbdog-web" "$WORK/src"
git -C "$WORK/src" checkout -q "$SHA" || die "构建机仓库缺 ${SHA}（先在构建机上刷新该仓）"
cd "$WORK/src"

# 当前应用不使用 next/image 或 sharp。关闭 Next 图片优化后，运行时不需要 sharp；
# 不把 npm 的 @img/sharp-libvips-linux-arm64 可选预编译库带进产物，既减小体积，也减少
# 不必要的原生 CPU/运行库兼容面。未来若源码开始使用图片优化，此门禁会要求先明确
# 选择兼容的 libvips 方案，不能静默改变图片行为。
if git grep -n -E "(['\"]next/(legacy/)?image['\"]|['\"]sharp['\"])" -- \
    '*.js' '*.jsx' '*.mjs' '*.cjs' '*.ts' '*.tsx'; then
  die "源码开始使用 next/image 或 sharp；须先提供通用 ARMv8 libvips，不能继续无图片优化打包"
fi

log "注入 standalone 输出并禁用图片优化"
sed -i 's|const nextConfig: NextConfig = {|const nextConfig: NextConfig = {\n  output: "standalone",\n  images: { unoptimized: true },|' next.config.ts
if ! grep -q 'output: "standalone"' next.config.ts \
    || ! grep -q 'images: { unoptimized: true }' next.config.ts; then
  die "next.config.ts 注入失败（源文件结构变了，更新本配方的 sed）"
fi

log "npm ci + next build"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}"   # 小内存编译机防 OOM
npm ci --no-audit --no-fund >&2
npm run build >&2

cp -a .next/standalone/. "$PKG/"
mkdir -p "$PKG/.next"
cp -a .next/static "$PKG/.next/static"
[ -d public ] && cp -a public "$PKG/public"
[ -f "$PKG/server.js" ] || die "standalone 输出缺 server.js"

# Next 的文件追踪会把 optional sharp 全家桶带入 standalone，即使应用没有使用。
# 精确删除这些未使用原生包，并确保最终包不再携带 sharp/libvips 机器码。
find "$PKG" -type d \( \
    -path '*/node_modules/sharp' -o \
    -path '*/node_modules/@img/sharp-*' -o \
    -path '*/node_modules/@img/sharp-libvips-*' -o \
    -path '*/node_modules/@img/colour' \
  \) -prune -exec rm -rf -- {} +
if find "$PKG" -type f \( -name 'sharp*.node' -o -name 'libvips*.so*' \) \
    -print -quit | grep -q .; then
  die "standalone 清理后仍含 sharp/libvips 原生文件"
fi

# drizzle 迁移物料；standalone 的 node_modules 是按引用裁剪的，migrator 子路径
# 可能没被带上——整包补齐 drizzle-orm 与 postgres 兜底。
cp -a drizzle "$PKG/drizzle"
mkdir -p "$PKG/node_modules"
for p in drizzle-orm postgres; do
  [ -d "node_modules/$p" ] || die "缺 node_modules/$p"
  rm -rf "$PKG/node_modules/$p"; cp -a "node_modules/$p" "$PKG/node_modules/$p"
done
# 删 map 必须放在 node_modules 补齐之后（否则三方包又把 map 带回来）
find "$PKG" -name '*.map' -delete

mkdir -p "$PKG/etc"
if [ -f deploy/.env.example ]; then cp deploy/.env.example "$PKG/etc/dbdog-web.env.example"
elif [ -f .env.example ]; then cp .env.example "$PKG/etc/dbdog-web.env.example"
else
  cat >"$PKG/etc/dbdog-web.env.example" <<'EOF'
# [首跑校准] dbdog-web 环境变量
PORT=7000
HOSTNAME=127.0.0.1
DATABASE_URL=postgres://127.0.0.1:5432/ctl
EOF
fi

mkdir -p "$PKG/hooks"
cat >"$PKG/hooks/migrate.mjs" <<'EOF'
// drizzle 增量迁移（web 表）。用包内 node_modules 的 drizzle-orm/postgres 执行。
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
const url = process.env.DATABASE_URL;
if (!url) { console.log("[hook] DATABASE_URL 未设置，跳过 drizzle 迁移"); process.exit(0); }
const client = postgres(url, { max: 1 });
await migrate(drizzle(client), { migrationsFolder: new URL("../drizzle", import.meta.url).pathname });
await client.end();
console.log("[hook] drizzle 迁移完成");
EOF
cat >"$PKG/hooks/pre-switch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ETC_DIR/dbdog-web.env"
[ -f "$ENVF" ] || { echo "[hook] 无 ${ENVF}，跳过 drizzle 迁移（配置后 install.sh --finish 补跑）"; exit 0; }
set -a; source "$ENVF"; set +a
cd "$HERE" && "$MODULES_DIR/node/current/bin/node" hooks/migrate.mjs
EOF
chmod +x "$PKG/hooks/pre-switch.sh"
echo "$VERSION" >"$PKG/VERSION"

ART="$MODULE-$VERSION-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "$MODULE-$VERSION"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$WORK/out/$ART"
