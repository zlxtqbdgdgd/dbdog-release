#!/usr/bin/env bash
# 配方：ddprof（三方件，dbhost 目标，Continuous Profiling 官方预编译二进制）。
# 固定 v0.26.0，不追随 latest，不重新编译或修改官方产物，也不解析在线
# sha256sum.txt 作为版本权威——四个内容锁（两个架构 × tar/解包二进制）已离线核对
# 官方发布的 https://github.com/DataDog/ddprof/releases/download/v0.26.0/sha256sum.txt
# 并硬编码在下面；换版本前必须重新离线核对并更新全部四个值。
# 输入 env：MODULE ARCH BUILD_WORK TOOL_PATH VERSION（只接受 0.26.0，其余值报错）
set -euo pipefail
export LC_ALL=C

log() { echo "[recipe:${MODULE:-ddprof}] $*" >&2; }
die() { echo "[recipe:${MODULE:-ddprof}] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "构建机缺少命令: $1"; }

export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

readonly PINNED_VERSION="0.26.0"
readonly PINNED_UPSTREAM_TAG="v0.26.0"
readonly PINNED_RELEASE_BASE_URL="https://github.com/DataDog/ddprof/releases/download/${PINNED_UPSTREAM_TAG}"

# 官方 sha256sum.txt（离线核对，不在运行时解析）：
#   03a76919bcc23a757f02d9c276dee7e58c1db688cc75e5568eb9a0f709bdce52  ddprof-0.26.0-amd64-linux.tar.xz
#   1c25657a53643d74eac4d13356a2953dbfd8d52cc80f9266025b3ae3983addef  ddprof-0.26.0-arm64-linux.tar.xz
#   8bf9255eecf4c93177bef7a5ccf5726b4df8b549fde9d5ed228073f784804b75  ddprof-amd64（tar 内 bin/ddprof 的内容与此逐字节相同）
#   8edb9b30c355a2f685bfaf00e2f23998884d249b6c5ac7701a7bb9af3e324df4  ddprof-arm64（tar 内 bin/ddprof 的内容与此逐字节相同）
readonly PINNED_TAR_SHA256_X86_64="03a76919bcc23a757f02d9c276dee7e58c1db688cc75e5568eb9a0f709bdce52"
readonly PINNED_TAR_SHA256_AARCH64="1c25657a53643d74eac4d13356a2953dbfd8d52cc80f9266025b3ae3983addef"
readonly PINNED_BIN_SHA256_X86_64="8bf9255eecf4c93177bef7a5ccf5726b4df8b549fde9d5ed228073f784804b75"
readonly PINNED_BIN_SHA256_AARCH64="8edb9b30c355a2f685bfaf00e2f23998884d249b6c5ac7701a7bb9af3e324df4"

# 确定性重新封装：把已核验的官方目录树（保留其内部 bin/ lib/ include/ licenses/
# version.txt 结构，不新增不删减）复制到固定顶层目录名下，再用 Python 的 tarfile/
# gzip 写出——固定 mtime=0、uid=gid=0、条目按路径排序、gzip 头不带文件名/时间戳，
# 输出与构建机的 GNU tar 版本、umask、时区都无关，多次打包字节相同。
package_ddprof_deterministic() { # <已验证的源目录> <顶层目录名> <目标 .tar.gz 路径>
  local src_dir="$1" topdir_name="$2" dest="$3" staging
  [ -d "$src_dir" ] || die "打包源目录不存在: $src_dir"
  staging="$(mktemp -d "${TMPDIR:-/tmp}/ddprof-pkg.XXXXXX")" || die "无法创建打包暂存目录"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$staging'" RETURN

  rm -rf -- "${staging:?}/$topdir_name"
  cp -a "$src_dir" "$staging/$topdir_name"
  [ -x "$staging/$topdir_name/bin/ddprof" ] || die "打包前缺少入口 bin/ddprof: $topdir_name"

  mkdir -p "$(dirname "$dest")"
  python3 - "$staging" "$topdir_name" "$dest" <<'PY'
import gzip
import os
import sys
import tarfile

staging, topdir, dest = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(staging, topdir)


def reset_identity(ti):
    ti.mtime = 0
    ti.uid = 0
    ti.gid = 0
    ti.uname = ""
    ti.gname = ""
    if ti.isfile() or ti.isdir():
        ti.mode = 0o755 if (ti.isdir() or (ti.mode & 0o111)) else 0o644
    return ti


def walk_sorted(path, arcroot):
    entries = []
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames.sort()
        rel = os.path.relpath(dirpath, path)
        arcdir = arcroot if rel == "." else arcroot + "/" + rel.replace(os.sep, "/")
        entries.append((dirpath, arcdir, True))
        for name in sorted(filenames):
            entries.append((os.path.join(dirpath, name), arcdir + "/" + name, False))
    entries.sort(key=lambda e: e[1])
    return entries


tmp_tar = dest + ".tmp-tar"
with tarfile.open(tmp_tar, mode="w", format=tarfile.GNU_FORMAT) as tar:
    for fs_path, arcname, is_dir in walk_sorted(root, topdir):
        ti = tar.gettarinfo(fs_path, arcname=arcname)
        ti = reset_identity(ti)
        if is_dir:
            tar.addfile(ti)
        else:
            with open(fs_path, "rb") as f:
                tar.addfile(ti, f)

with open(tmp_tar, "rb") as raw, open(dest, "wb") as out:
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.read())
os.remove(tmp_tar)
PY
  [ -s "$dest" ] || die "确定性打包未产生产物: $dest"
}

main() {
  local m="${MODULE:-}" arch="${ARCH:-}" ver="${VERSION:-}"
  [ -n "$m" ] || die "缺少 MODULE"
  for cmd in awk curl du sha256sum tar file python3 mkdir cp rm mktemp dirname; do
    require_cmd "$cmd"
  done

  # publish.sh 对三方件模块（kind != first-party）恒传空 VERSION（build_one_arch 的
  # $ver 只对 first-party 模块由发布计划算出，三方件的真实版本由配方自己探测/钉死；
  # 其余现有三方件配方头注释都写"VERSION 忽略/自动探测"）。ddprof 固定版本、拒绝
  # latest，但必须放行生产会真实传入的空串，否则 publish.sh publish ddprof 会在第
  # 一个架构就必死——空串和显式传入的 0.26.0 都视为"使用固定版本"，其余任何非空值
  # （latest、其它版本号）仍然 fail closed。
  [ -z "$ver" ] || [ "$ver" = "$PINNED_VERSION" ] || \
    die "本配方只接受空 VERSION（三方件生产调用形态）或 VERSION=$PINNED_VERSION（收到 VERSION=$ver）；ddprof 固定版本，换版本前须离线核对官方新 sha256sum.txt 并更新配方内四个内容锁，禁止解析 latest 或在线 sha256sum.txt 作为权威"

  local asset_name pinned_tar_sha256 pinned_bin_sha256
  case "$arch" in
    x86_64)
      asset_name="ddprof-${PINNED_VERSION}-amd64-linux.tar.xz"
      pinned_tar_sha256="$PINNED_TAR_SHA256_X86_64"
      pinned_bin_sha256="$PINNED_BIN_SHA256_X86_64"
      ;;
    aarch64)
      asset_name="ddprof-${PINNED_VERSION}-arm64-linux.tar.xz"
      pinned_tar_sha256="$PINNED_TAR_SHA256_AARCH64"
      pinned_bin_sha256="$PINNED_BIN_SHA256_AARCH64"
      ;;
    *) die "ddprof 官方产物只发布 x86_64 与 aarch64，收到 ARCH=$arch" ;;
  esac

  local work dl extract tarball download_url actual_tar_sha256 actual_bin_sha256
  local file_info version_output pkg art art_path
  work="${BUILD_WORK:?BUILD_WORK 未设置}/$m"
  dl="$work/download"
  extract="$dl/extract"
  rm -rf -- "$work/pkg" "$dl"
  mkdir -p "$dl" "$extract" "$work/out"

  tarball="$dl/$asset_name"
  download_url="$PINNED_RELEASE_BASE_URL/$asset_name"
  log "下载官方产物 $download_url"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 -o "$tarball" "$download_url" \
    || die "下载官方 ddprof 产物失败: $download_url"

  actual_tar_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
  [ "$actual_tar_sha256" = "$pinned_tar_sha256" ] || \
    die "官方产物 tar 摘要不匹配（期望 $pinned_tar_sha256，实际 $actual_tar_sha256），拒绝解包: $asset_name"
  log "tar 摘要核验通过: $asset_name"

  tar -xf "$tarball" -C "$extract" || die "解包官方产物失败: $asset_name"
  [ -x "$extract/ddprof/bin/ddprof" ] || die "官方产物解包后缺少入口 ddprof/bin/ddprof"

  actual_bin_sha256="$(sha256sum "$extract/ddprof/bin/ddprof" | awk '{print $1}')"
  [ "$actual_bin_sha256" = "$pinned_bin_sha256" ] || \
    die "解包后 ddprof 二进制摘要不匹配（期望 $pinned_bin_sha256，实际 $actual_bin_sha256），拒绝继续"
  log "解包二进制摘要核验通过: bin/ddprof"

  file_info="$(LC_ALL=C file -b "$extract/ddprof/bin/ddprof")"
  case "$arch" in
    x86_64)
      case "$file_info" in
        *ELF*64-bit*x86-64* | *ELF*64-bit*x86_64*) ;;
        *) die "解包二进制不是 Linux x86_64 ELF: $file_info" ;;
      esac
      ;;
    aarch64)
      case "$file_info" in
        *ELF*64-bit*ARM\ aarch64* | *ELF*64-bit*aarch64*) ;;
        *) die "解包二进制不是 Linux aarch64 ELF: $file_info" ;;
      esac
      ;;
  esac

  version_output="$("$extract/ddprof/bin/ddprof" --version 2>&1)" \
    || die "已核验的 ddprof 在构建机执行 --version 失败: $version_output"
  case "$version_output" in
    *"$PINNED_VERSION"*) ;;
    *) die "ddprof --version 输出不含固定版本号 $PINNED_VERSION: $version_output" ;;
  esac
  log "ddprof --version 通过: $version_output"

  # --version 执行后二次核对二进制内容未被替换（同 clickhouse 配方的防篡改模式）。
  [ "$(sha256sum "$extract/ddprof/bin/ddprof" | awk '{print $1}')" = "$pinned_bin_sha256" ] \
    || die "ddprof --version 执行后二进制内容发生变化，拒绝打包"

  pkg="ddprof-$PINNED_VERSION"
  art="ddprof-${PINNED_VERSION}-${arch}.tar.gz"
  art_path="$work/out/$art"
  package_ddprof_deterministic "$extract/ddprof" "$pkg" "$art_path"
  log "打包完成 $art ($(du -h "$art_path" | cut -f1))"

  printf '%s\t%s\n' "$PINNED_VERSION" "$art_path"
}

# 通过 `ssh ... bash -s <"$recipe"` 执行时（生产路径），stdin 脚本没有
# BASH_SOURCE 帧，下面条件恒真，main 照常运行；测试脚本改用 `source` 把本文件
# 载入自己的进程以复用 package_ddprof_deterministic 等函数时，BASH_SOURCE[0]
# 指向本文件而 $0 指向测试脚本本身，两者不等，main 不会自动执行、也就不会因为
# 测试环境没有设置 MODULE/VERSION/ARCH 而在 source 阶段就 die/exit 掉调用方。
if [ "${#BASH_SOURCE[@]}" -eq 0 ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
