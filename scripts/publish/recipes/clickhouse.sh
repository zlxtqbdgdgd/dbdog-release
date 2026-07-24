#!/usr/bin/env bash
# 配方：ClickHouse（三方件）。clickhouse 是单个自包含大二进制，
# server/client 都是它的子命令，打包一个文件即可。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH CH_BIN（VERSION 忽略，自动探测）
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

BIN="${CH_BIN:-$(command -v clickhouse || true)}"
[ -x "${BIN:-/nonexistent}" ] || die "找不到 clickhouse 二进制；在 publish.conf 里设 CH_BIN"
BIN="$(readlink -f "$BIN")"
VER="$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$VER" ] || die "无法解析 clickhouse 版本（$BIN --version）"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/clickhouse-$VER"
rm -rf "$WORK/pkg"; mkdir -p "$PKG/bin" "$WORK/out"
log "打包 $BIN (ClickHouse $VER)"
install -m 755 "$BIN" "$PKG/bin/clickhouse"

ART="clickhouse-$VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "clickhouse-$VER"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VER" "$WORK/out/$ART"
