#!/usr/bin/env bash
# 配方：dbdog-server（Go，含 cgo）+ ddsql-server（Rust）+ migrations + goose 钩子。
# 输入 env：MODULE VERSION SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/$MODULE-$VERSION"
rm -rf "$WORK/pkg" "$WORK/src"; mkdir -p "$PKG/bin" "$WORK/out"

log "检出 $SHA"
git -C "$REPO_ROOT/dbdog-server" fetch -q origin
git clone -q --shared "$REPO_ROOT/dbdog-server" "$WORK/src"
git -C "$WORK/src" checkout -q "$SHA"
cd "$WORK/src"

log "Go 构建（CGO_CFLAGS=-DHAVE_STRCHRNUL，见源仓 Makefile 注释）"
CGO_ENABLED=1 CGO_CFLAGS="-DHAVE_STRCHRNUL" \
  go build -trimpath -ldflags "-s -w" -o "$PKG/bin/dbdog-server" ./cmd/dbdog-server

log "Rust 构建 ddsql-server（release）"
(cd ddsql && cargo build --release)
install -m 755 ddsql/target/release/ddsql-server "$PKG/bin/ddsql-server"

cp -a migrations "$PKG/migrations"

mkdir -p "$PKG/etc"
if [ -f deploy/.env.example ]; then
  cp deploy/.env.example "$PKG/etc/dbdog-server.env.example"
else
  printf '# [首跑校准] dbdog-server 环境变量（PG_DSN、CH_*、DBDOG_*）\n' >"$PKG/etc/dbdog-server.env.example"
fi
printf '# [首跑校准] ddsql-server 环境变量（如需）\n' >"$PKG/etc/ddsql-server.env.example"

mkdir -p "$PKG/hooks"
cat >"$PKG/hooks/pre-switch.sh" <<'EOF'
#!/usr/bin/env bash
# PG ctl 库增量迁移（goose up）。CH 租户表由 dbdog-server 启动时 blueprint 自动推进。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ETC_DIR/dbdog-server.env"
[ -f "$ENVF" ] || { echo "[hook] 无 $ENVF，跳过 goose 迁移（配置后 install.sh --finish 补跑）"; exit 0; }
set -a; source "$ENVF"; set +a
[ -n "${PG_DSN:-}" ] || { echo "[hook] PG_DSN 未设置，跳过 goose 迁移"; exit 0; }
"$MODULES_DIR/goose/current/bin/goose" -dir "$HERE/migrations" postgres "$PG_DSN" up
EOF
chmod +x "$PKG/hooks/pre-switch.sh"
echo "$VERSION" >"$PKG/VERSION"

ART="$MODULE-$VERSION-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "$MODULE-$VERSION"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$WORK/out/$ART"
