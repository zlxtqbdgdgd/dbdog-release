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
# 只对「构建追踪抢跑」这一种已知偶发重试一次；其余失败照常炸（判定与次数见 lib 的注释，
# 契约由 scripts/test-publish-web-build-retry.sh 钉住）。
# 配方经 stdin 送到构建机，source 同目录文件在对端不成立；由 publish.sh 内联展开。
# @include lib-next-build-retry.sh
run_next_build_with_one_retry "$WORK/out/next-build.log" npm run build \
  || die "next build 失败（详见上方日志）"

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
[ -z "$(find "$PKG/drizzle" -type l -print -quit)" ] \
  || die "drizzle migrations 不允许包含软链"
mkdir -p "$PKG/node_modules"
for p in drizzle-orm postgres; do
  [ -d "node_modules/$p" ] || die "缺 node_modules/$p"
  rm -rf "$PKG/node_modules/$p"; cp -a "node_modules/$p" "$PKG/node_modules/$p"
done
[ -f "$PKG/node_modules/@node-rs/argon2/index.js" ] \
  || die "standalone 输出缺 @node-rs/argon2，无法初始化管理员"
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
# 源仓模板可能带外网验收机 URL；发布物不能把某台公网机器当内网默认配置。
# DATABASE_URL 使用 release 首次安装的本机 PG 约定，PUBLIC_* 由 install.sh 根据
# DBDOG_ADVERTISE_HOST/默认路由生成。
sed -i \
  -e 's|^DATABASE_URL=.*|DATABASE_URL=postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable|' \
  -e 's|^PUBLIC_APP_URL=.*|PUBLIC_APP_URL=change-me|' \
  -e 's|^PUBLIC_INGEST_URL=.*|PUBLIC_INGEST_URL=change-me|' \
  -e 's|^PUBLIC_MCP_URL=.*|PUBLIC_MCP_URL=change-me|' \
  "$PKG/etc/dbdog-web.env.example"
for public_key in PUBLIC_APP_URL PUBLIC_INGEST_URL PUBLIC_MCP_URL; do
  grep -Fqx "$public_key=change-me" "$PKG/etc/dbdog-web.env.example" \
    || die "发布 env 模板的 $public_key 未净化为 change-me"
done

mkdir -p "$PKG/hooks"
(
  cd "$PKG"
  find drizzle -type f -print | LC_ALL=C sort | while IFS= read -r migration; do
    sha256sum "$migration"
  done
) >"$PKG/hooks/postgres-migrations.sha256"
[ -s "$PKG/hooks/postgres-migrations.sha256" ] || die "Drizzle migrations 校验清单为空"
cat >"$PKG/hooks/migrate.mjs" <<'EOF'
// drizzle 增量迁移（web 表）。用包内 node_modules 的 drizzle-orm/postgres 执行。
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
const url = process.env.DATABASE_URL;
if (!url) throw new Error("DATABASE_URL 未设置");
const client = postgres(url, { max: 1 });
await migrate(drizzle(client), { migrationsFolder: new URL("../drizzle", import.meta.url).pathname });
await client.end();
console.log("[hook] drizzle 迁移完成");
EOF
cat >"$PKG/hooks/bootstrap-admin.mjs" <<'EOF'
// 仅在指定邮箱尚不存在时创建首个管理员；升级重跑不会改密码或提权既有用户。
import { randomBytes } from "node:crypto";
import { hash } from "@node-rs/argon2";
import postgres from "postgres";

const url = process.env.DATABASE_URL;
if (!url) throw new Error("DATABASE_URL 未设置");
const email = (process.env.SEED_EMAIL || "admin@dbdog.local").trim().toLowerCase();
const password = `${randomBytes(18).toString("base64url")}aA1!`;
const passwordHash = await hash(password, {
  memoryCost: 65536,
  timeCost: 3,
  parallelism: 4,
});
const sql = postgres(url, { max: 1 });
try {
  const result = await sql.begin(async (tx) => {
    const [org] = await tx`SELECT id FROM orgs WHERE public_id = 'default' LIMIT 1`;
    if (!org) throw new Error("default org 不存在；drizzle 迁移可能未完成");
    let [user] = await tx`SELECT id, role FROM users WHERE lower(email) = ${email} LIMIT 1`;
    let created = false;
    if (!user) {
      [user] = await tx`
        INSERT INTO users (email, name, role, password_hash)
        VALUES (${email}, 'Admin', 'admin', ${passwordHash})
        ON CONFLICT (email) DO NOTHING
        RETURNING id, role
      `;
      if (!user) [user] = await tx`SELECT id, role FROM users WHERE lower(email) = ${email} LIMIT 1`;
      else created = true;
    }
    if (!user) throw new Error(`无法读取或创建管理员 ${email}`);
    await tx`
      INSERT INTO org_members (org_id, user_id, role)
      VALUES (${org.id}, ${user.id}, ${user.role === "admin" ? "admin" : "member"})
      ON CONFLICT (org_id, user_id) DO NOTHING
    `;
    return created;
  });
  if (result) {
    console.log("[hook] 首个管理员已创建（请立即保存；密码只显示本次）：");
    console.log(`[hook]   邮箱: ${email}`);
    console.log(`[hook]   密码: ${password}`);
  } else {
    console.log(`[hook] 管理员初始化已存在: ${email}（未修改密码）`);
  }
} finally {
  await sql.end();
}
EOF
cat >"$PKG/hooks/pre-switch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ETC_DIR/dbdog-web.env"
REQUIRED="${DBDOG_MIGRATION_REQUIRED:-0}"
case "$REQUIRED" in 0 | 1) ;; *) echo "[hook] 非法 DBDOG_MIGRATION_REQUIRED=$REQUIRED" >&2; exit 1 ;; esac
if [ ! -f "$ENVF" ]; then
  [ "$REQUIRED" = 0 ] && { echo "[hook] 无 ${ENVF}，首次落包暂不迁移（install.sh 收尾阶段自动补跑）"; exit 0; }
  echo "[hook] 缺少 ${ENVF}，拒绝在未迁移数据库时升级 dbdog-web" >&2
  exit 1
fi
set -a; source "$ENVF"; set +a
[ -n "${DATABASE_URL:-}" ] || {
  [ "$REQUIRED" = 0 ] && { echo "[hook] DATABASE_URL 未设置，首次落包暂不迁移"; exit 0; }
  echo "[hook] DATABASE_URL 未设置，拒绝在未迁移数据库时升级 dbdog-web" >&2
  exit 1
}
cd "$HERE"
sha256sum -c hooks/postgres-migrations.sha256 >/dev/null \
  || { echo "[hook] dbdog-web 迁移文件完整性校验失败" >&2; exit 1; }
"$MODULES_DIR/node/current/bin/node" hooks/migrate.mjs
"$MODULES_DIR/node/current/bin/node" hooks/bootstrap-admin.mjs
EOF
chmod +x "$PKG/hooks/pre-switch.sh"
echo "$VERSION" >"$PKG/VERSION"

ART="$MODULE-$VERSION-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "$MODULE-$VERSION"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$WORK/out/$ART"
