#!/usr/bin/env bash
# 配方：PostgreSQL（三方件）。打包构建机上独立前缀的 PG 安装（PG 可搬迁：
# 路径按二进制相对位置解析）。数据目录不打包——内网 initdb 自建。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH PG_PREFIX（VERSION 忽略，自动探测）
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

if [ -n "${PG_PREFIX:-}" ]; then
  PGC="$PG_PREFIX/bin/pg_config"
else
  PGC="$(command -v pg_config || true)"
fi
[ -x "${PGC:-/nonexistent}" ] || die "找不到 pg_config；在 publish.conf 里设 PG_PREFIX（源码安装的独立前缀，如 /usr/local/pgsql）"

VER="$("$PGC" --version | awk '{print $2}')"
PREFIX="$(dirname "$("$PGC" --bindir)")"
case "$PREFIX" in
  /|/usr|/usr/local) die "PG 前缀是系统目录（$PREFIX），不能整体打包；请源码安装到独立前缀后用 PG_PREFIX 指定" ;;
esac

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/postgresql-$VER"
rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg" "$WORK/out"
log "打包 $PREFIX (PostgreSQL $VER)"
cp -a "$PREFIX" "$PKG"
[ -x "$PKG/bin/initdb" ] || die "打包结果缺 bin/initdb（前缀推断有误: $PREFIX）"

ART="postgresql-$VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "postgresql-$VER"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VER" "$WORK/out/$ART"
