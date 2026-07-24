#!/usr/bin/env bash
# 配方：goose（三方件，PG 迁移工具，单二进制）。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH（VERSION 忽略，自动探测）
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

WORK="$BUILD_WORK/$MODULE"
rm -rf "$WORK/pkg"; mkdir -p "$WORK/out"

GOOSE="$(command -v goose || true)"
if [ -z "$GOOSE" ]; then
  log "构建机无 goose，go install 一份"
  command -v go >/dev/null || die "构建机没有 go（TOOL_PATH 里加上）"
  GOBIN="$WORK/gobin" go install github.com/pressly/goose/v3/cmd/goose@latest >&2
  GOOSE="$WORK/gobin/goose"
fi
VER="$("$GOOSE" -version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
VER="${VER#v}"
[ -n "$VER" ] || die "无法解析 goose 版本"

PKG="$WORK/pkg/goose-$VER"; mkdir -p "$PKG/bin"
install -m 755 "$GOOSE" "$PKG/bin/goose"

ART="goose-$VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "goose-$VER"
log "打包完成 $ART"
printf '%s\t%s\n' "$VER" "$WORK/out/$ART"
