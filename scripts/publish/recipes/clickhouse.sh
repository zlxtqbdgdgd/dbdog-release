#!/usr/bin/env bash
# 配方：ClickHouse（三方件）。只封装已完成离线内外层指令审计、并在鲲鹏 920
# 验收过的官方 aarch64v80compat 自解压文件，不追随 master 移动指针。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH CH_BIN（VERSION 忽略）
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

# builds.clickhouse.com/master/aarch64v80compat/clickhouse 是移动对象；URL 只作
# provenance，可信身份由下面不可从 publish.conf 覆盖的内容锁决定。换版本时先运行
# scripts/publish/verify-clickhouse-v80compat.sh，对自解压外壳和内层 ELF 的可执行节
# 重新做 RCpc load-acquire 指令审计，再连同全部锁值一起评审更新。
readonly PINNED_VERSION="26.8.1.184"
readonly PINNED_SOURCE_URL="https://builds.clickhouse.com/master/aarch64v80compat/clickhouse"
readonly PINNED_UPSTREAM_COMMIT="1d4408f794c389928bda6b52615aa612c12b938b"
readonly PINNED_PROFILE="aarch64v80compat"
readonly PINNED_SOURCE_SHA256="d44d8b56085a6aa0f787858a1abd4afb48f996f6d62ba0956146ae25e27efd39"
readonly PINNED_SOURCE_SIZE="161037456"
# 外层 SHA 覆盖压缩 payload、FileData 和 trailer，因此也内容寻址地绑定内层；
# 内层 SHA/大小记录的是独立解包审计结果，便于换版本时交叉复核。
readonly PINNED_INNER_SHA256="ad37b1e3111bb072e7e98b0a20bf301774084d8adbdf880afa9337c63f61130b"
readonly PINNED_INNER_SIZE="741851160"

[ "$ARCH" = "aarch64" ] || die "ClickHouse 内容锁只允许发布 aarch64，收到 ARCH=$ARCH"
for cmd in awk file grep install readlink sed sha256sum tail tr wc; do
  command -v "$cmd" >/dev/null 2>&1 || die "构建机缺少命令: $cmd"
done

BIN="${CH_BIN:-}"
[ -x "${BIN:-/nonexistent}" ] \
  || die "必须在 publish.conf 中把 CH_BIN 指向已审的原始 aarch64v80compat 自解压缓存"
BIN="$(readlink -f "$BIN")"

# 必须先验证字节身份，再执行输入文件。构建机 CPU 即使比鲲鹏规格高，也不能让普通
# arm64 构建仅凭 `--version` 成功而混入产物。
SOURCE_SHA256="$(sha256sum "$BIN" | awk '{print $1}')"
SOURCE_SIZE="$(wc -c <"$BIN" | tr -d '[:space:]')"
if [ "$SOURCE_SHA256" != "$PINNED_SOURCE_SHA256" ] || \
   [ "$SOURCE_SIZE" != "$PINNED_SOURCE_SIZE" ]; then
  die "CH_BIN 不是已审的官方 ${PINNED_PROFILE} 文件（sha256=${SOURCE_SHA256} size=${SOURCE_SIZE}）；拒绝执行。先离线审计内外层 ELF 并更新 ClickHouse recipe 内容锁"
fi

SOURCE_FILE_INFO="$(LC_ALL=C file -b "$BIN")"
case "$SOURCE_FILE_INFO" in
  *ELF*64-bit*LSB*ARM\ aarch64*) ;;
  *) die "已锁 ClickHouse 文件不是 Linux AArch64 ELF: $SOURCE_FILE_INFO" ;;
esac
tail -c 512 "$BIN" | grep -aFq 'clickhouse-stripped' \
  || die "已锁 ClickHouse 文件缺少自解压 clickhouse-stripped 尾标"

# 离线审计/测试入口：只执行上面的静态内容锁，不运行外来架构二进制或生成产物。
if [ "${CH_VERIFY_ONLY:-0}" = "1" ]; then
  log "内容锁通过: $PINNED_PROFILE sha256=$SOURCE_SHA256 size=$SOURCE_SIZE"
  exit 0
fi

VERSION_OUTPUT="$("$BIN" --version 2>&1)" \
  || die "已锁 ClickHouse 在构建机执行 --version 失败"
if ! VER="$(printf '%s\n' "$VERSION_OUTPUT" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p')"; then
  die "无法从已锁 ClickHouse 的 --version 输出解析版本"
fi
[ "$VER" = "$PINNED_VERSION" ] \
  || die "已锁 ClickHouse 版本不符合审计记录（期望 ${PINNED_VERSION}，实际 ${VER:-无法解析}）"
# 自解压入口当前不会改写自身；仍重新核对，避免运行时替换后打包了另一份文件。
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$PINNED_SOURCE_SHA256" ] \
  || die "ClickHouse --version 后输入文件内容发生变化，拒绝打包"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/clickhouse-$VER"
rm -rf "$WORK/pkg"
mkdir -p "$PKG/bin" "$WORK/out"
log "打包 $BIN (ClickHouse $VER)"
install -m 755 "$BIN" "$PKG/bin/clickhouse"
[ "$(sha256sum "$PKG/bin/clickhouse" | awk '{print $1}')" = "$PINNED_SOURCE_SHA256" ] \
  || die "打包副本与已审 ClickHouse 内容锁不一致"

mkdir -p "$PKG/provenance"
cat >"$PKG/provenance/clickhouse-build.txt" <<EOF
source_url=$PINNED_SOURCE_URL
source_url_is_moving_pointer=true
upstream_commit=$PINNED_UPSTREAM_COMMIT
official_profile=$PINNED_PROFILE
profile_cmake=-DNO_ARMV81_OR_HIGHER=1
compiler_baseline=-march=armv8+crc
version=$PINNED_VERSION
source_sha256=$PINNED_SOURCE_SHA256
source_size=$PINNED_SOURCE_SIZE
inner_sha256=$PINNED_INNER_SHA256
inner_size=$PINNED_INNER_SIZE
outer_rcpc_loads_in_executable_sections=0
inner_rcpc_loads_in_executable_sections=0
target_runtime_gate=upgrade.sh staging clickhouse --version before current switch
EOF

ART="clickhouse-$VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "clickhouse-$VER"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VER" "$WORK/out/$ART"
