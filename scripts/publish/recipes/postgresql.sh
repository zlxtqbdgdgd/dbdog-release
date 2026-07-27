#!/usr/bin/env bash
# 配方：PostgreSQL（三方件）。复制独立前缀，并把非 glibc 运行库收进包内。
# 所有动态 ELF 使用相对 RUNPATH；数据目录不打包，由内网 initdb 创建。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH PG_PREFIX（VERSION 忽略，自动探测）
set -euo pipefail
export LC_ALL=C

log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"
for cmd in awk basename cp cut dirname du env find grep head install ldd ln \
  mkdir readelf readlink rm sha256sum sort tar; do
  require_cmd "$cmd"
done

if [ -n "${PG_PREFIX:-}" ]; then
  PGC="$PG_PREFIX/bin/pg_config"
else
  PGC="$(command -v pg_config || true)"
fi
[ -x "${PGC:-/nonexistent}" ] || \
  die "找不到 pg_config；在 publish.conf 里设 PG_PREFIX（源码安装的独立前缀，如 /usr/local/pgsql）"

UPSTREAM_VER="$("$PGC" --version | awk '{print $2}')"
[ "$UPSTREAM_VER" = "16.14" ] || \
  die "本配方只审过 PostgreSQL 16.14，实际是 $UPSTREAM_VER；升级上游版本前须重审运行 ABI"
PACKAGE_VER="$UPSTREAM_VER-dbdog.1"
PREFIX="$(dirname "$("$PGC" --bindir)")"
PREFIX="$(cd "$PREFIX" && pwd -P)"
case "$PREFIX" in
  /|/usr|/usr/local)
    die "PG 前缀是系统目录（${PREFIX}），不能整体打包；请源码安装到独立前缀后用 PG_PREFIX 指定"
    ;;
esac

case "$ARCH" in
  aarch64) ;;
  *) die "PostgreSQL 运行闭包目前只校验 aarch64，收到 ARCH=$ARCH" ;;
esac

# 优先使用 PATH 中的 patchelf；当前构建机复用 agent 已校验的固定 v2 工具。
PATCHELF="$(command -v patchelf || true)"
PINNED_PATCHELF="$HOME/cache/dbdog-agent/tools/patchelf/0.18.0-aarch64-kylin10-v2/bin/patchelf"
if [ -z "$PATCHELF" ] && [ -x "$PINNED_PATCHELF" ]; then
  PATCHELF="$PINNED_PATCHELF"
  PINNED_PATCHELF_SHA256="01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf"
  actual_patchelf_sha256="$(sha256sum "$PATCHELF" | awk '{print $1}')"
  [ "$actual_patchelf_sha256" = "$PINNED_PATCHELF_SHA256" ] || \
    die "固定 patchelf SHA-256 不匹配: $PATCHELF"
fi
[ -x "${PATCHELF:-/nonexistent}" ] || \
  die "找不到 patchelf；把它加入 TOOL_PATH，或准备固定工具 $PINNED_PATCHELF"
log "使用 $("$PATCHELF" --version | head -n1) ($PATCHELF)"

WORK="$BUILD_WORK/$MODULE"
PKG="$WORK/pkg/postgresql-$PACKAGE_VER"
DEPS_RAW="$WORK/runtime-deps.raw"
DEPS_SORTED="$WORK/runtime-deps.sorted"
NEEDED_RAW="$WORK/runtime-needed.raw"
NEEDED_SORTED="$WORK/runtime-needed.sorted"
SMOKE="$WORK/relocation-smoke"

rm -rf "$WORK/pkg" "$SMOKE"
mkdir -p "$WORK/pkg" "$WORK/out"
log "打包 $PREFIX (PostgreSQL $UPSTREAM_VER，包版本 $PACKAGE_VER)"
cp -a "$PREFIX" "$PKG"
[ -x "$PKG/bin/initdb" ] || \
  die "打包结果缺 bin/initdb（前缀推断有误: ${PREFIX}）"

is_dynamic_elf() {
  readelf -d "$1" 2>/dev/null | grep 'Dynamic section' >/dev/null
}

assert_aarch64_elf() {
  local elf="$1" machine
  machine="$(readelf -h "$elf" 2>/dev/null | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  [ "$machine" = "AArch64" ] || die "包内混入非 aarch64 ELF: ${elf#"$PKG/"} ($machine)"
}

is_base_runtime() {
  # 这些由目标 Kylin V10 的 glibc 提供；其余动态库必须收进本包。
  case "$1" in
    linux-vdso.so.1|ld-linux-aarch64.so.1|libc.so.6|libm.so.6|\
    libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2|\
    libutil.so.1|libanl.so.1)
      return 0
      ;;
    *) return 1 ;;
  esac
}

collect_resolved_dependencies() {
  local elf output
  : >"$DEPS_RAW"
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    assert_aarch64_elf "$elf"
    output="$(LD_LIBRARY_PATH="$PKG/lib:$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$elf" 2>&1)" || \
      die "ldd 失败: ${elf#"$PKG/"}: $output"
    if grep -Eq '=>[[:space:]]+not found' <<<"$output"; then
      die "动态库无法解析: ${elf#"$PKG/"}: $(grep -E '=>[[:space:]]+not found' <<<"$output" | awk '{$1=$1; print}')"
    fi
    awk '
      $2 == "=>" && $3 ~ /^\// { print $3; next }
      $1 ~ /^\// { print $1 }
    ' <<<"$output" >>"$DEPS_RAW"
  done < <(find "$PKG" -type f -print0)
  sort -u "$DEPS_RAW" >"$DEPS_SORTED"
}

copy_runtime_closure() {
  local round=0 added dep soname dest dep_sha dest_sha
  while :; do
    collect_resolved_dependencies
    added=0
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      soname="$(basename "$dep")"
      is_base_runtime "$soname" && continue
      case "$dep" in
        "$PREFIX"/*|"$PKG"/*) continue ;;
      esac
      [ -f "$dep" ] || die "解析到的动态库不是普通文件: $dep"
      is_dynamic_elf "$dep" || die "解析到的依赖不是动态 ELF: $dep"
      assert_aarch64_elf "$dep"
      dest="$PKG/lib/$soname"
      if [ -e "$dest" ]; then
        dep_sha="$(sha256sum "$dep" | awk '{print $1}')"
        dest_sha="$(sha256sum "$dest" | awk '{print $1}')"
        [ "$dep_sha" = "$dest_sha" ] || \
          die "同名动态库内容冲突: $soname ($dep 与 $dest)"
        continue
      fi
      install -m 0755 "$dep" "$dest"
      log "收录运行库 $soname（来自 $dep）"
      added=1
    done <"$DEPS_SORTED"
    [ "$added" -eq 1 ] || break
    round=$((round + 1))
    [ "$round" -le 32 ] || die "动态库闭包超过 32 轮，疑似依赖解析异常"
  done
}

collect_needed_sonames() {
  local elf
  : >"$NEEDED_RAW"
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    readelf -d "$elf" | awk '
      /\(NEEDED\)/ {
        sub(/^.*\[/, "")
        sub(/\].*$/, "")
        print
      }
    ' >>"$NEEDED_RAW"
  done < <(find "$PKG" -type f -print0)
  sort -u "$NEEDED_RAW" >"$NEEDED_SORTED"
}

assert_runtime_closed() {
  local soname resolved
  collect_needed_sonames
  while IFS= read -r soname; do
    [ -n "$soname" ] || continue
    case "$soname" in
      */*) die "ELF NEEDED 使用了绝对/相对路径: $soname" ;;
    esac
    is_base_runtime "$soname" && continue
    [ -e "$PKG/lib/$soname" ] || die "非基础依赖未收入包内: $soname"
    resolved="$(readlink -f "$PKG/lib/$soname")" || \
      die "无法解析包内动态库: $soname"
    case "$resolved" in
      "$PKG"/lib/*) ;;
      *) die "包内动态库链接逃出 lib 目录: $soname => $resolved" ;;
    esac
  done <"$NEEDED_SORTED"

  # 当前 PG 16.14 的明确 ABI 合约；变化时必须审查并显式更新配方。
  for soname in libssl.so.1.1 libcrypto.so.1.1 libicui18n.so.62 \
    libicuuc.so.62 libicudata.so.62 libreadline.so.8 libz.so.1; do
    grep -Fxq "$soname" "$NEEDED_SORTED" || \
      die "PG 运行 ABI 与已审合约不符，未发现依赖: $soname"
    [ -f "$PKG/lib/$soname" ] || die "已审运行库未收入包内: $soname"
  done
}

relative_lib_runpath() {
  local elf="$1" rel dir rpath i depth
  rel="${elf#"$PKG/"}"
  if [[ "$rel" == */* ]]; then
    dir="${rel%/*}"
    depth="$(awk -F/ '{print NF}' <<<"$dir")"
  else
    depth=0
  fi
  rpath="\$ORIGIN"
  for ((i = 0; i < depth; i++)); do
    rpath+='/..'
  done
  printf '%s/lib\n' "$rpath"
}

patch_and_verify_runpaths() {
  local elf expected actual dynamic
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    expected="$(relative_lib_runpath "$elf")"
    "$PATCHELF" --set-rpath "$expected" "$elf" || \
      die "写入 RUNPATH 失败: ${elf#"$PKG/"}"
    dynamic="$(readelf -d "$elf")"
    actual="$(awk '
      /\(RUNPATH\)/ {
        sub(/^.*\[/, "")
        sub(/\].*$/, "")
        print
      }
    ' <<<"$dynamic")"
    [ "$actual" = "$expected" ] || \
      die "RUNPATH 校验失败: ${elf#"$PKG/"}（期望 $expected，实际 $actual）"
    ! grep -Fq "$PREFIX" <<<"$dynamic" || \
      die "ELF 动态段仍引用构建前缀: ${elf#"$PKG/"}"
  done < <(find "$PKG" -type f -print0)
}

verify_packaged_resolution() {
  local elf output soname resolved resolved_real
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    output="$(env -u LD_LIBRARY_PATH ldd "$elf" 2>&1)" || \
      die "封包后 ldd 失败: ${elf#"$PKG/"}: $output"
    if grep -Eq '=>[[:space:]]+not found' <<<"$output"; then
      die "封包后仍有动态库缺失: ${elf#"$PKG/"}: $(grep -E '=>[[:space:]]+not found' <<<"$output" | awk '{$1=$1; print}')"
    fi
    while IFS=$'\t' read -r soname resolved; do
      [ -n "$soname" ] || continue
      is_base_runtime "$soname" && continue
      resolved_real="$(readlink -f "$resolved")" || \
        die "无法规范化动态库路径: ${elf#"$PKG/"}: $soname => $resolved"
      case "$resolved_real" in
        "$PKG"/lib/*) ;;
        *) die "非基础依赖未从包内加载: ${elf#"$PKG/"}: $soname => $resolved_real" ;;
      esac
    done < <(awk '$2 == "=>" && $3 ~ /^\// { print $1 "\t" $3 }' <<<"$output")
  done < <(find "$PKG" -type f -print0)
}

copy_runtime_closure
assert_runtime_closed
patch_and_verify_runpaths
verify_packaged_resolution

mkdir -p "$SMOKE"
mkdir -p "$SMOKE/modules/postgresql"
ln -s "$PKG" "$SMOKE/modules/postgresql/current"
SMOKE_CURRENT="$SMOKE/modules/postgresql/current"
env -u LD_LIBRARY_PATH "$SMOKE_CURRENT/bin/postgres" --version >/dev/null
env -u LD_LIBRARY_PATH "$SMOKE_CURRENT/bin/psql" --version >/dev/null
env -u LD_LIBRARY_PATH "$SMOKE_CURRENT/bin/initdb" \
  --no-locale --auth=trust -D "$SMOKE/data" >/dev/null
rm -rf "$SMOKE"

runtime_libs="$(while IFS= read -r soname; do
  is_base_runtime "$soname" || printf '%s ' "$soname"
done <"$NEEDED_SORTED")"
log "非基础运行库闭包: ${runtime_libs% }"

ART="postgresql-$PACKAGE_VER-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "postgresql-$PACKAGE_VER"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$PACKAGE_VER" "$WORK/out/$ART"
