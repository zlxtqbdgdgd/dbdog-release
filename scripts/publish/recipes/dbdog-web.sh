#!/usr/bin/env bash
# 配方：dbdog-web。构建时向临时检出注入 output:"standalone"（不侵入源仓），
# 只发编译产物（无 src/、无 sourcemap），附 drizzle 迁移与钩子。
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

log "注入 standalone 输出"
sed -i 's|const nextConfig: NextConfig = {|const nextConfig: NextConfig = {\n  output: "standalone",|' next.config.ts
grep -q '"standalone"' next.config.ts || die "next.config.ts 注入失败（源文件结构变了，更新本配方的 sed）"

log "npm ci + next build"
npm ci --no-audit --no-fund >&2
npm run build >&2

cp -a .next/standalone/. "$PKG/"
mkdir -p "$PKG/.next"
cp -a .next/static "$PKG/.next/static"
[ -d public ] && cp -a public "$PKG/public"
find "$PKG" -name '*.map' -delete
[ -f "$PKG/server.js" ] || die "standalone 输出缺 server.js"

# drizzle 迁移物料；standalone 的 node_modules 是按引用裁剪的，migrator 子路径
# 可能没被带上——整包补齐 drizzle-orm 与 postgres 兜底。
cp -a drizzle "$PKG/drizzle"
mkdir -p "$PKG/node_modules"
for p in drizzle-orm postgres; do
  [ -d "node_modules/$p" ] || die "缺 node_modules/$p"
  rm -rf "$PKG/node_modules/$p"; cp -a "node_modules/$p" "$PKG/node_modules/$p"
done

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
