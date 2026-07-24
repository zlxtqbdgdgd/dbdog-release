#!/usr/bin/env bash
# 配方：Node.js 运行时（三方件）。不去官网下——官方 arm 包要求 glibc ≥ 2.28，
# EulerOS 未必满足；打包构建机上"实际能跑"的那份 node。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH（VERSION 忽略，自动探测）
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || die "构建机 PATH 里找不到 node（在 publish.conf 的 TOOL_PATH 加上 node 的 bin 目录）"
NODE_BIN="$(readlink -f "$NODE_BIN")"
VER="$("$NODE_BIN" -v)"; VER="${VER#v}"
PREFIX="$(cd "$(dirname "$NODE_BIN")/.." && pwd)"
case "$PREFIX" in
  /|/usr|/usr/local) die "node 前缀是系统目录（$PREFIX），不能整体打包；请改用独立目录安装的 node（如 nvm/n 或解压的官方 tar 目录）" ;;
esac

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/node-$VER"
rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg" "$WORK/out"
log "打包 $PREFIX (node v$VER)"
cp -a "$PREFIX" "$PKG"
[ -x "$PKG/bin/node" ] || die "打包结果缺 bin/node（前缀推断有误: $PREFIX）"

ART="node-$VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "node-$VER"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VER" "$WORK/out/$ART"
