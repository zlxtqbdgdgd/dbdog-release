#!/usr/bin/env bash
# 配方：原生 x86_64 dbdog-agent Omnibus 运行时（canonical x86_64 build）。
# 输入 env（由 publish.sh 提供）：MODULE VERSION SHA CORE_SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH。
#
# 与 aarch64 配方（../recipes/dbdog-agent.sh）的关系——刻意区分共享与不共享，避免
# 无解释的整段复制：
#
#   共享（Global Constraint：两架构必须来自同一份 RELEASE-BASELINE.tsv 的 Agent/Core
#   源码锚和同一 dbdog 版本；见 scripts/test-agent-x86_64-artifact-contracts.sh 的
#   跨文件一致性断言）：
#     - PINNED_AGENT_SHA / PINNED_INTEGRATION_CORE_SHA / VERSION 前缀正则，逐字节
#       与 aarch64 配方相同。
#     - GaussDB 集成身份（datadog-gaussdb 1.0.1）与其 wheel 的确定性内容——纯
#       Python，架构无关。本配方不像 aarch64 那样信任一份预置 wheel blob，而是从
#       同一 CORE_SHA 现场重建 wheel 并核对其 sha256 与 aarch64 配方钉死的值完全
#       相同（build_gaussdb_wheel），把"同一 Core 源码"落到可验证的确定性证明上。
#     - INSTALL_DIR=/opt/dbdog-agent、provenance/ 文件集合与 aarch64 同构
#       （运行时消费者不需要按架构区分 provenance 解析逻辑）。
#
#   不共享（x86_64 没有 aarch64 那条 v3~v14 迭代出来的历史包袱，brief 明确要求
#   "不得把已安装目录反向打包成 release"，所以本配方每次都从 pinned SHA 全新
#   checkout、全新编译）：
#     - 不依赖任何预先封存的 Kylin V10 专属依赖闭包、专门编译的 patchelf 定制
#       版本、System Probe 输出复用种子。x86_64 build host 直接使用发行版自带
#       patchelf，只把其 --version 记入 provenance，不做字节级钉死。
#     - 与其它一方模块配方（dbdog-server.sh / dbdog-web.sh）一致，使用
#       REPO_ROOT/BUILD_WORK 通用约定组织源码与产物目录，不引入独立 CACHE_ROOT
#       目录树。
#
#   权限分工：Omnibus 编译在 build_one_arch 通过 ssh 以配置账户直接执行；把产物
#   固化为 root:root（匹配目标机以 root 安装的期望）需要提权。这与 aarch64 配方 +
#   finalize-agent-runtime-v3.sh 的 root 分离精神一致，但 x86_64 没有独立
#   finalizer 文件的历史包袱：两阶段合并进本文件，用 EUID 判定分支（见 main）。
#   第一次调用（非 root）完成编译后会 die，要求管理员以 root 重新执行同一份
#   配方（同一组 env）；不得为该操作配置 NOPASSWD sudo。
set -euo pipefail
export LC_ALL=C

log() { printf '[recipe:%s] %s\n' "${MODULE:-dbdog-agent-x86_64}" "$*" >&2; }
die() { printf '[recipe:%s] ERROR: %s\n' "${MODULE:-dbdog-agent-x86_64}" "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "构建机缺少命令: $1"; }

reject_control_characters() { # <label> <value>
  local label="$1" value="$2"
  case "$value" in *$'\n'* | *$'\r'* | *$'\t'*) die "$label 含换行或制表控制字符" ;; esac
}

require_exact_field() { # <file> <key> <expected>
  local file="$1" key="$2" expected="$3" count actual
  count="$(awk -F= -v key="$key" '$1 == key { c++ } END { print c + 0 }' "$file")"
  [ "$count" = 1 ] || die "$file 必须且只能包含一个 $key"
  actual="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' "$file")"
  [ "$actual" = "$expected" ] || die "$file 的 $key 不匹配（实际 $actual）"
}

read_exact_field() { # <file> <key>
  local file="$1" key="$2" count
  count="$(awk -F= -v key="$key" '$1 == key { c++ } END { print c + 0 }' "$file")"
  [ "$count" = 1 ] || die "$file 必须且只能包含一个 $key"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' "$file"
}

os_release_id() {
  [ -f /etc/os-release ] || { printf 'unknown\n'; return 0; }
  awk -F= '$1 == "ID" { v=$0; sub(/^[^=]*=/, "", v); gsub(/^"|"$/, "", v); print v; exit }' /etc/os-release
}

# ---- 与 aarch64 配方共享的固定锚点（不得脱离 recipes/dbdog-agent.sh 独立改动）----
readonly PINNED_AGENT_SHA=62ad29793b02139448b76bc85fc406491a08bf58
readonly PINNED_INTEGRATION_CORE_SHA=612be7bea397c87df707489599c02ed623c29631
readonly GAUSSDB_INTEGRATION_NAME=datadog-gaussdb
readonly GAUSSDB_INTEGRATION_VERSION=1.0.1
readonly GAUSSDB_WHEEL_REL="sources/python/gaussdb/${PINNED_INTEGRATION_CORE_SHA}/datadog_gaussdb-${GAUSSDB_INTEGRATION_VERSION}-py3-none-any.whl"
readonly GAUSSDB_WHEEL_SHA256=f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f
readonly INSTALL_DIR=/opt/dbdog-agent

# ---- x86_64 专属（没有 aarch64 那条历史迭代，允许与之不同）----
readonly BUILDER_IDENTITY=native-x86_64-omnibus-v1
readonly ARCHIVE_RECIPE=gnu_tar_find_sorted_fixed_mtime_root_owner_gzip_n_dual_build_compare
readonly PUBLICATION_RECIPE=destination_local_tmpfile_root_owned_atomic_rename_no_clobber
readonly REQUIRED_MIN_FREE_BYTES=$((20 * 1024 * 1024 * 1024))
readonly -a RUNTIME_BINARIES=(
  bin/agent/agent
  embedded/bin/system-probe
  embedded/bin/trace-agent
  embedded/bin/process-agent
)
readonly -a PROVENANCE_FILES=(
  build.txt
  omnibus.success
  runtime.sha256
  glibc-requirements.tsv
  agent-data-plane.txt
  agent-version.txt
  system-probe-version.txt
  gaussdb.txt
)

# 运行期由 main() 计算的“全局”（bash 函数默认写全局变量，供后续阶段函数复用；
# 一律在 main() 里显式赋值一次，不使用 local，避免调用链更深的函数看不到）。
WORK=""
ARTIFACT_NAME=""
ARTIFACT_PATH=""
SIDECAR_PATH=""
OMNIBUS_MARKER=""
PROVENANCE_DIR=""
GAUSSDB_WHEEL_PATH=""
AGENT_BINARY_SHA256=""
SYSTEM_PROBE_BINARY_SHA256=""

validate_inputs() {
  local input_name value
  for input_name in MODULE VERSION SHA CORE_SHA ARCH; do
    value="${!input_name-}"
    [ -n "$value" ] || die "缺少输入环境变量 $input_name"
    reject_control_characters "$input_name" "$value"
  done
  [ "$MODULE" = dbdog-agent ] || die "MODULE 必须是 dbdog-agent，实际为 $MODULE"
  [[ $VERSION =~ ^7[.]81[.]0-dbdog[.][1-9][0-9]*$ ]] || \
    die "VERSION 必须是 7.81.0-dbdog.N（N 从 1 开始），实际为 $VERSION"
  [[ $SHA =~ ^[0-9a-f]{40}$ ]] || die 'SHA 必须是完整的小写 40 位提交 SHA'
  [[ $CORE_SHA =~ ^[0-9a-f]{40}$ ]] || die 'CORE_SHA 必须是完整的小写 40 位提交 SHA'
  [ "$SHA" = "$PINNED_AGENT_SHA" ] || \
    die "SHA 必须是固定的 Agent release source $PINNED_AGENT_SHA（与 aarch64 配方共享同一锚点）"
  [ "$CORE_SHA" = "$PINNED_INTEGRATION_CORE_SHA" ] || \
    die "CORE_SHA 必须是固定的 GaussDB integration 源提交 $PINNED_INTEGRATION_CORE_SHA（与 aarch64 配方共享同一锚点）"
  [ "$ARCH" = x86_64 ] || die "本配方只构建 x86_64，收到 ARCH=$ARCH"
  [ "$(uname -m)" = x86_64 ] || \
    die "构建机不是原生 x86_64（本配方拒绝 QEMU/交叉构建产物冒充原生 release）"
  [ -n "${REPO_ROOT:-}" ] || die "缺少 REPO_ROOT"
  [ -n "${BUILD_WORK:-}" ] || die "缺少 BUILD_WORK"

  export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"
  local cmd
  for cmd in awk chmod cmp cp df file find git grep gzip id install mkdir mktemp mv \
    objdump patchelf python3 readlink rm sha256sum sort stat tar uname wc xargs; do
    require_cmd "$cmd"
  done
}

require_minimum_free_space() { # <目录> <说明>
  local dir="$1" label="$2" available
  available="$(df -B1 --output=avail -- "$dir" 2>/dev/null | awk 'NR==2{print $1}')"
  case "$available" in
    '' | *[!0-9]*) die "无法读取 $label 可用空间: $dir" ;;
  esac
  [ "$available" -ge "$REQUIRED_MIN_FREE_BYTES" ] || \
    die "$label 可用空间不足: $dir（需要至少 $((REQUIRED_MIN_FREE_BYTES / 1024 / 1024 / 1024)) GiB）"
}

fresh_checkout() { # <目标目录> <源仓（REPO_ROOT 下的可 fetch 仓）> <sha>
  local dest="$1" source_repo="$2" sha="$3" head
  [ -d "$source_repo/.git" ] || \
    die "构建机源仓不存在: $source_repo（先在构建机准备 REPO_ROOT 下的镜像仓）"
  if [ -d "$dest/.git" ]; then
    head="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    if [ "$head" = "$sha" ] && git -C "$dest" diff --quiet HEAD -- . 2>/dev/null; then
      log "复用已存在的 fresh checkout: $dest @ ${sha:0:12}"
      return 0
    fi
    log "已存在的 checkout 不是干净的固定 SHA，重新准备: $dest"
    rm -rf -- "$dest"
  fi
  git -C "$source_repo" fetch -q origin 2>/dev/null || \
    log "构建机对源仓无 fetch 凭据，用现有本地对象: $source_repo"
  git clone -q --no-hardlinks "$source_repo" "$dest" || die "无法从 $source_repo 创建 fresh checkout"
  git -C "$dest" checkout -q --detach "$sha" || \
    die "构建机仓库缺 $sha（先在构建机刷新该仓）: $source_repo"
  [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ] || die "fresh checkout HEAD 与固定 SHA 不一致: $dest"
}

verify_wheel_metadata() { # <wheel 路径>
  python3 - "$1" "$GAUSSDB_INTEGRATION_VERSION" <<'PYEOF' || die "GaussDB wheel 元数据校验失败: $1"
from email.parser import BytesParser
import sys
import zipfile

wheel_path, expected_version = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(wheel_path) as archive:
    names = archive.namelist()
    metadata_name = next(n for n in names if n.endswith(".dist-info/METADATA"))
    wheel_name = next(n for n in names if n.endswith(".dist-info/WHEEL"))
    metadata = BytesParser().parsebytes(archive.read(metadata_name))
    wheel = BytesParser().parsebytes(archive.read(wheel_name))
assert metadata["Name"] == "datadog-gaussdb", metadata["Name"]
assert metadata["Version"] == expected_version, metadata["Version"]
assert wheel["Root-Is-Purelib"] == "true", wheel["Root-Is-Purelib"]
assert wheel.get_all("Tag") == ["py3-none-any"], wheel.get_all("Tag")
PYEOF
}

build_gaussdb_wheel() { # 依赖全局 WORK / CORE_SRC
  local dist_dir="$WORK/gaussdb-wheel-dist"
  local wheel_name="datadog_gaussdb-${GAUSSDB_INTEGRATION_VERSION}-py3-none-any.whl"
  GAUSSDB_WHEEL_PATH="$dist_dir/$wheel_name"

  if [ -f "$GAUSSDB_WHEEL_PATH" ]; then
    local existing_sha
    existing_sha="$(sha256sum "$GAUSSDB_WHEEL_PATH" | awk '{print $1}')"
    if [ "$existing_sha" = "$GAUSSDB_WHEEL_SHA256" ]; then
      log "复用已构建并核验的 GaussDB wheel: $GAUSSDB_WHEEL_PATH"
      return 0
    fi
    log "已存在的 wheel 摘要不匹配，重新构建: $GAUSSDB_WHEEL_PATH"
    rm -rf -- "$dist_dir"
  fi

  [ -d "$CORE_SRC/gaussdb" ] || die "Core 源码缺少 gaussdb 集成目录: $CORE_SRC/gaussdb"
  mkdir -p "$dist_dir"
  # --no-index --no-build-isolation：构建后端与依赖都必须已在构建机离线可用，
  # 不联网拉取；不解析任何在线版本权威。
  python3 -m pip wheel --no-deps --no-build-isolation --no-index \
    --wheel-dir "$dist_dir" "$CORE_SRC/gaussdb" \
    || die "从 Core 源码构建 GaussDB wheel 失败"
  [ -f "$GAUSSDB_WHEEL_PATH" ] || \
    die "构建产物没有落在预期文件名: $GAUSSDB_WHEEL_PATH（GaussDB 集成版本可能不是 $GAUSSDB_INTEGRATION_VERSION）"

  local actual_sha
  actual_sha="$(sha256sum "$GAUSSDB_WHEEL_PATH" | awk '{print $1}')"
  [ "$actual_sha" = "$GAUSSDB_WHEEL_SHA256" ] || \
    die "从 CORE_SHA $CORE_SHA 现场重建的 GaussDB wheel 摘要与 aarch64 配方钉死的值不一致（实际 $actual_sha，期望 $GAUSSDB_WHEEL_SHA256）——两架构必须消费同一份确定性 wheel，重建不可复现或 Core 源码已漂移"
  verify_wheel_metadata "$GAUSSDB_WHEEL_PATH"
  log "GaussDB wheel 已从同一 CORE_SHA 现场重建并核对通过（跨架构确定性证明）"
}

write_omnibus_marker() { # <目标文件>
  printf '%s\n' \
    'format=dbdog-agent-x86_64-omnibus-v1' \
    "agent_sha=$SHA" \
    "core_sha=$CORE_SHA" \
    "version=$VERSION" \
    "builder_identity=$BUILDER_IDENTITY" \
    >"$1"
}

omnibus_marker_matches() { # <标记文件>
  local expected
  expected="$(mktemp "$WORK/.omnibus-marker-expected.XXXXXX")"
  write_omnibus_marker "$expected"
  if cmp -s -- "$expected" "$1"; then
    rm -f -- "$expected"
    return 0
  fi
  rm -f -- "$expected"
  return 1
}

verify_omnibus_version_manifest() {
  [ -f "$INSTALL_DIR/version-manifest.txt" ] || die "缺少 version-manifest.txt"
  [ -f "$INSTALL_DIR/version-manifest.json" ] || die "缺少 version-manifest.json"
  grep -Eq "^agent[[:space:]]+$VERSION\$" "$INSTALL_DIR/version-manifest.txt" || \
    die "version-manifest.txt 的 agent header 未绑定外层 VERSION $VERSION"
}

run_omnibus_build() { # 依赖全局 WORK / AGENT_SRC
  OMNIBUS_MARKER="$WORK/omnibus.success"
  if [ -f "$OMNIBUS_MARKER" ]; then
    if omnibus_marker_matches "$OMNIBUS_MARKER"; then
      log "复用已完成的 Omnibus 构建: $OMNIBUS_MARKER"
      return 0
    fi
    log "已存在的 Omnibus 完成标记不属于当前输入，重新构建"
    rm -f -- "$OMNIBUS_MARKER"
  fi

  [ -f "$AGENT_SRC/omnibus/config/projects/agent.rb" ] || \
    die "Agent 源码缺少 omnibus/config/projects/agent.rb（fresh checkout 不完整）"

  log "运行 Omnibus（inv omnibus.build --release-version=$VERSION）"
  (
    cd "$AGENT_SRC" || exit 1
    env -u LD_LIBRARY_PATH \
      RELEASE_VERSION="$VERSION" \
      DD_AGENT_VERSION="$VERSION" \
      inv omnibus.build --release-version="$VERSION" --base-dir="$WORK/omnibus-base" \
        --skip-sign --log-level=info
  ) || die "Omnibus 构建失败（inv omnibus.build），见上方日志"

  [ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ] || \
    die "Omnibus 完成后未在约定 install root 落地: $INSTALL_DIR"
  local relbin
  for relbin in "${RUNTIME_BINARIES[@]}"; do
    [ -f "$INSTALL_DIR/$relbin" ] && [ ! -L "$INSTALL_DIR/$relbin" ] || \
      die "Omnibus 完成后缺少预期二进制: $INSTALL_DIR/$relbin"
  done
  verify_omnibus_version_manifest

  write_omnibus_marker "$OMNIBUS_MARKER"
  log "Omnibus 构建完成并生成完成标记: $OMNIBUS_MARKER"
}

install_gaussdb_wheel_offline() {
  local python_bin="$INSTALL_DIR/embedded/bin/python3"
  [ -x "$python_bin" ] || die "Omnibus 安装根缺少 embedded python3: $python_bin"
  "$python_bin" -m pip install --no-index --no-deps --force-reinstall --no-cache-dir \
    "$GAUSSDB_WHEEL_PATH" || die "离线安装 GaussDB wheel 失败: $GAUSSDB_WHEEL_PATH"
  log "已离线安装 $GAUSSDB_INTEGRATION_NAME $GAUSSDB_INTEGRATION_VERSION（wheel sha256 $GAUSSDB_WHEEL_SHA256）"
}

verify_native_x86_64_elf() {
  local relbin file_info rpath
  for relbin in "${RUNTIME_BINARIES[@]}"; do
    file_info="$(LC_ALL=C file -b "$INSTALL_DIR/$relbin")"
    case "$file_info" in
      *ELF*64-bit*x86-64* | *ELF*64-bit*x86_64*) ;;
      *) die "$relbin 不是 x86_64 ELF: $file_info" ;;
    esac
    rpath="$(patchelf --print-rpath "$INSTALL_DIR/$relbin" 2>/dev/null || true)"
    case "$rpath" in
      /home/* | /root/* | /tmp/* | "$WORK"*) die "$relbin 的 RPATH 泄漏构建机私有路径: $rpath" ;;
    esac
  done
  log "已核验 ${#RUNTIME_BINARIES[@]} 个核心二进制均为原生 x86_64 ELF，RPATH 未泄漏构建机路径（patchelf: $(patchelf --version 2>&1))"
}

verify_agent_version_and_provenance() {
  local binary="$INSTALL_DIR/bin/agent/agent" output expected_prefix binary_sha output_sha
  output="$("$binary" version 2>&1)" || die "无法执行 agent version: $output"
  expected_prefix="Agent $VERSION - Commit: ${SHA:0:10} - Serialization version: "
  case "$output" in
    "$expected_prefix"*' - Go version: go'*) ;;
    *) die "编译后的 Agent version 输出未绑定外层 VERSION/SHA: $output" ;;
  esac
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  output_sha="$(printf '%s\n' "$output" | sha256sum | awk '{print $1}')"
  {
    printf 'compiled_version=%s\n' "$VERSION"
    printf 'agent_git_sha=%s\n' "$SHA"
    printf 'binary_path=./bin/agent/agent\n'
    printf 'binary_sha256=%s\n' "$binary_sha"
    printf 'version_output=%s\n' "$output"
    printf 'version_output_sha256=%s\n' "$output_sha"
  } >"$PROVENANCE_DIR/agent-version.txt"
  AGENT_BINARY_SHA256="$binary_sha"
}

verify_system_probe_version_and_provenance() {
  local binary="$INSTALL_DIR/embedded/bin/system-probe" output expected_prefix binary_sha output_sha
  output="$("$binary" version 2>&1)" || die "无法执行 system-probe version: $output"
  expected_prefix="System Probe $VERSION - Commit: ${SHA:0:10} - Serialization version: "
  case "$output" in
    "$expected_prefix"*' - Go version: go'*) ;;
    *) die "编译后的 system-probe version 输出未绑定外层 VERSION/SHA: $output" ;;
  esac
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  output_sha="$(printf '%s\n' "$output" | sha256sum | awk '{print $1}')"
  {
    printf 'compiled_version=%s\n' "$VERSION"
    printf 'agent_git_sha=%s\n' "$SHA"
    printf 'binary_path=./embedded/bin/system-probe\n'
    printf 'binary_sha256=%s\n' "$binary_sha"
    printf 'version_output=%s\n' "$output"
    printf 'version_output_sha256=%s\n' "$output_sha"
  } >"$PROVENANCE_DIR/system-probe-version.txt"
  SYSTEM_PROBE_BINARY_SHA256="$binary_sha"
}

verify_gaussdb_import() {
  local python_bin="$INSTALL_DIR/embedded/bin/python3" output
  output="$("$python_bin" -c '
import importlib.metadata as m
import datadog_checks.gaussdb  # noqa: F401
print(m.version("datadog-gaussdb"))
' 2>&1)" || die "GaussDB 集成 import 失败: $output"
  [ "$output" = "$GAUSSDB_INTEGRATION_VERSION" ] || \
    die "GaussDB 集成已安装版本与固定值不符（实际 $output，期望 $GAUSSDB_INTEGRATION_VERSION）"
  {
    printf 'integration_name=%s\n' "$GAUSSDB_INTEGRATION_NAME"
    printf 'integration_version=%s\n' "$GAUSSDB_INTEGRATION_VERSION"
    printf 'integration_source_git_sha=%s\n' "$CORE_SHA"
    printf 'wheel_rel=%s\n' "$GAUSSDB_WHEEL_REL"
    printf 'wheel_sha256=%s\n' "$GAUSSDB_WHEEL_SHA256"
    printf 'import_version=%s\n' "$output"
  } >"$PROVENANCE_DIR/gaussdb.txt"
}

write_glibc_requirements() {
  local relbin
  {
    for relbin in "${RUNTIME_BINARIES[@]}"; do
      LC_ALL=C objdump -T "$INSTALL_DIR/$relbin" 2>/dev/null | \
        awk -v b="./$relbin" '$0 ~ /GLIBC_/ { match($0, /GLIBC_[0-9.]+/); print b "\t" substr($0, RSTART, RLENGTH) }'
    done
  } | LC_ALL=C sort -u >"$PROVENANCE_DIR/glibc-requirements.tsv"
  [ -s "$PROVENANCE_DIR/glibc-requirements.tsv" ] || die "未能采集任何 glibc 符号版本要求"
}

write_runtime_manifest() {
  ( cd "$INSTALL_DIR" && find . -type f -print | LC_ALL=C sort | xargs sha256sum ) \
    >"$PROVENANCE_DIR/runtime.sha256"
  [ -s "$PROVENANCE_DIR/runtime.sha256" ] || die "runtime.sha256 为空"
}

write_agent_data_plane_provenance() {
  {
    printf 'component=trace-agent\tpath=./embedded/bin/trace-agent\n'
    printf 'component=process-agent\tpath=./embedded/bin/process-agent\n'
  } >"$PROVENANCE_DIR/agent-data-plane.txt"
}

write_build_provenance() {
  {
    printf 'format_version=2\n'
    printf 'product=dbdog-agent\n'
    printf 'version=%s\n' "$VERSION"
    printf 'compiled_agent_version=%s\n' "$VERSION"
    printf 'architecture=x86_64\n'
    printf 'install_prefix=%s\n' "$INSTALL_DIR"
    printf 'agent_git_sha=%s\n' "$SHA"
    printf 'integrations_core_git_sha=%s\n' "$CORE_SHA"
    printf 'integration_name=%s\n' "$GAUSSDB_INTEGRATION_NAME"
    printf 'integration_version=%s\n' "$GAUSSDB_INTEGRATION_VERSION"
    printf 'integration_wheel_rel=%s\n' "$GAUSSDB_WHEEL_REL"
    printf 'integration_wheel_sha256=%s\n' "$GAUSSDB_WHEEL_SHA256"
    printf 'agent_binary_sha256=%s\n' "$AGENT_BINARY_SHA256"
    printf 'system_probe_binary_sha256=%s\n' "$SYSTEM_PROBE_BINARY_SHA256"
    printf 'builder_identity=%s\n' "$BUILDER_IDENTITY"
    printf 'builder_image_digest=none\n'
    printf 'host_distribution=%s\n' "$(os_release_id)"
    printf 'archive_recipe=%s\n' "$ARCHIVE_RECIPE"
    printf 'publication_recipe=%s\n' "$PUBLICATION_RECIPE"
  } >"$PROVENANCE_DIR/build.txt"
}

write_provenance_files() {
  PROVENANCE_DIR="$WORK/provenance-stage"
  rm -rf -- "$PROVENANCE_DIR"
  mkdir -p "$PROVENANCE_DIR"

  verify_agent_version_and_provenance
  verify_system_probe_version_and_provenance
  verify_gaussdb_import
  write_glibc_requirements
  write_runtime_manifest
  write_agent_data_plane_provenance
  cp -- "$OMNIBUS_MARKER" "$PROVENANCE_DIR/omnibus.success"
  write_build_provenance

  local f
  for f in "${PROVENANCE_FILES[@]}"; do
    [ -f "$PROVENANCE_DIR/$f" ] || die "provenance 暂存目录缺少 $f"
  done
}

copy_provenance_into_install_root() {
  rm -rf -- "$INSTALL_DIR/provenance"
  mkdir -p "$INSTALL_DIR/provenance"
  local f
  for f in "${PROVENANCE_FILES[@]}"; do
    cp -- "$PROVENANCE_DIR/$f" "$INSTALL_DIR/provenance/$f"
  done
  : >"$INSTALL_DIR/.install_root"
}

pack_deterministic_tar() { # <目标 .tar.gz 路径>
  local dest="$1" filelist
  filelist="$(mktemp "$WORK/.pack-filelist.XXXXXX")"
  ( cd "$INSTALL_DIR" && find . -mindepth 0 -print ) | LC_ALL=C sort >"$filelist"
  tar --directory="$INSTALL_DIR" --files-from="$filelist" --no-recursion \
    --owner=0 --group=0 --numeric-owner --mtime='@0' --format=gnu -cf - | \
    gzip -n -9 >"$dest"
  rm -f -- "$filelist"
  [ -s "$dest" ] || die "确定性打包未产生产物: $dest"
}

stage_and_pack_deterministic_tar() {
  copy_provenance_into_install_root

  local build1="$WORK/.pack-attempt-1.tar.gz" build2="$WORK/.pack-attempt-2.tar.gz"
  pack_deterministic_tar "$build1"
  pack_deterministic_tar "$build2"
  local sha1 sha2
  sha1="$(sha256sum "$build1" | awk '{print $1}')"
  sha2="$(sha256sum "$build2" | awk '{print $1}')"
  rm -f -- "$build2"
  [ "$sha1" = "$sha2" ] || \
    die "确定性打包自检失败：连续两次打包 sha256 不一致（$sha1 vs $sha2）"

  chown 0:0 "$build1"
  chmod 0644 "$build1"
  local tmp_artifact="$ARTIFACT_PATH.tmp.$$"
  mv -f -- "$build1" "$tmp_artifact"
  mv -f -- "$tmp_artifact" "$ARTIFACT_PATH"

  local tmp_sidecar="$SIDECAR_PATH.tmp.$$"
  printf '%s  %s\n' "$sha1" "$ARTIFACT_NAME" >"$tmp_sidecar"
  chown 0:0 "$tmp_sidecar"
  chmod 0644 "$tmp_sidecar"
  mv -f -- "$tmp_sidecar" "$SIDECAR_PATH"
  log "确定性打包完成并通过双构建自检: $ARTIFACT_PATH"

  # provenance 只属于本次发布产物；从 install root 移除，避免污染下一次 finalize，
  # 也避免 /opt/dbdog-agent 长期携带非 runtime 的发布元数据。
  rm -rf -- "$INSTALL_DIR/provenance" "$INSTALL_DIR/.install_root"
}

finalize_as_root() {
  [ "$(id -u)" = 0 ] || die "finalize_as_root 必须以 root 执行"
  [ -n "$OMNIBUS_MARKER" ] && [ -f "$OMNIBUS_MARKER" ] || die "缺少 Omnibus 完成标记，无法固化"
  omnibus_marker_matches "$OMNIBUS_MARKER" || die "Omnibus 完成标记与当前输入不一致，拒绝固化"

  install_gaussdb_wheel_offline
  verify_native_x86_64_elf
  write_provenance_files
  stage_and_pack_deterministic_tar
}

verify_canonical_artifact() { # <artifact> <sidecar>
  local artifact="$1" sidecar="$2" work list actual_sha member duplicate
  local build_info gaussdb_info agent_version_info system_probe_version_info

  [ -f "$artifact" ] && [ ! -L "$artifact" ] || die "canonical 产物不是实际文件: $artifact"
  [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || die "canonical 产物缺少实际 sidecar: $sidecar"
  [ "$(stat -c '%u:%g:%a' -- "$artifact")" = 0:0:644 ] || die 'canonical 产物必须是 root:root mode 0644'
  [ "$(stat -c '%u:%g:%a' -- "$sidecar")" = 0:0:644 ] || die 'canonical sidecar 必须是 root:root mode 0644'
  actual_sha="$(sha256sum -- "$artifact" | awk '{print $1}')"
  printf '%s  %s\n' "$actual_sha" "$(basename -- "$artifact")" | cmp -s - "$sidecar" || \
    die 'canonical sidecar 与产物 SHA-256 不匹配'

  work="$(mktemp -d "$WORK/.verify-artifact.XXXXXX")"
  trap 'rm -rf -- "$work"' RETURN
  list="$work/list"
  tar --quoting-style=literal -tzf "$artifact" >"$list" || die '无法读取 canonical tarball'
  [ -s "$list" ] || die 'canonical tarball 为空'
  if grep -Eq '(^|/)dbdog-agent/' "$list"; then
    die 'tarball 错误包含 dbdog-agent wrapper 目录'
  fi
  duplicate="$(LC_ALL=C sort "$list" | awk 'p==$0{print;exit} {p=$0}')"
  [ -z "$duplicate" ] || die "archive member 重复: $duplicate"
  for member in ./provenance/build.txt ./provenance/omnibus.success ./provenance/runtime.sha256 \
    ./provenance/glibc-requirements.tsv ./provenance/agent-data-plane.txt \
    ./provenance/agent-version.txt ./provenance/system-probe-version.txt ./provenance/gaussdb.txt \
    ./bin/agent/agent ./embedded/bin/system-probe ./version-manifest.txt ./version-manifest.json; do
    grep -Fxq -- "$member" "$list" || die "产物必须且只能包含一个 $member"
  done

  build_info="$work/build.txt"
  gaussdb_info="$work/gaussdb.txt"
  agent_version_info="$work/agent-version.txt"
  system_probe_version_info="$work/system-probe-version.txt"
  tar -xOzf "$artifact" ./provenance/build.txt >"$build_info" || die '无法读取产物 build provenance'
  tar -xOzf "$artifact" ./provenance/gaussdb.txt >"$gaussdb_info" || die '无法读取 GaussDB provenance'
  tar -xOzf "$artifact" ./provenance/agent-version.txt >"$agent_version_info" || \
    die '无法读取 Agent version provenance'
  tar -xOzf "$artifact" ./provenance/system-probe-version.txt >"$system_probe_version_info" || \
    die '无法读取 system-probe version provenance'

  require_exact_field "$build_info" format_version 2
  require_exact_field "$build_info" product dbdog-agent
  require_exact_field "$build_info" version "$VERSION"
  require_exact_field "$build_info" compiled_agent_version "$VERSION"
  require_exact_field "$build_info" architecture x86_64
  require_exact_field "$build_info" install_prefix "$INSTALL_DIR"
  require_exact_field "$build_info" agent_git_sha "$PINNED_AGENT_SHA"
  require_exact_field "$build_info" integrations_core_git_sha "$PINNED_INTEGRATION_CORE_SHA"
  require_exact_field "$build_info" integration_name "$GAUSSDB_INTEGRATION_NAME"
  require_exact_field "$build_info" integration_version "$GAUSSDB_INTEGRATION_VERSION"
  require_exact_field "$build_info" integration_wheel_rel "$GAUSSDB_WHEEL_REL"
  require_exact_field "$build_info" integration_wheel_sha256 "$GAUSSDB_WHEEL_SHA256"
  require_exact_field "$build_info" builder_identity "$BUILDER_IDENTITY"
  require_exact_field "$build_info" builder_image_digest none
  require_exact_field "$build_info" archive_recipe "$ARCHIVE_RECIPE"
  require_exact_field "$build_info" publication_recipe "$PUBLICATION_RECIPE"

  require_exact_field "$gaussdb_info" integration_name "$GAUSSDB_INTEGRATION_NAME"
  require_exact_field "$gaussdb_info" integration_version "$GAUSSDB_INTEGRATION_VERSION"
  require_exact_field "$gaussdb_info" integration_source_git_sha "$PINNED_INTEGRATION_CORE_SHA"
  require_exact_field "$gaussdb_info" wheel_sha256 "$GAUSSDB_WHEEL_SHA256"
  require_exact_field "$gaussdb_info" import_version "$GAUSSDB_INTEGRATION_VERSION"

  require_exact_field "$agent_version_info" compiled_version "$VERSION"
  local agent_output expected_agent_prefix agent_binary_sha
  agent_output="$(read_exact_field "$agent_version_info" version_output)"
  expected_agent_prefix="Agent $VERSION - Commit: ${PINNED_AGENT_SHA:0:10} - Serialization version: "
  case "$agent_output" in
    "$expected_agent_prefix"*' - Go version: go'*) ;;
    *) die "产物 Agent version 输出没有绑定外层 VERSION: $agent_output" ;;
  esac
  agent_binary_sha="$(read_exact_field "$agent_version_info" binary_sha256)"
  [ "$(tar -xOzf "$artifact" ./bin/agent/agent | sha256sum | awk '{print $1}')" = "$agent_binary_sha" ] || \
    die 'Agent binary SHA-256 与 version provenance 不一致'
  require_exact_field "$build_info" agent_binary_sha256 "$agent_binary_sha"

  require_exact_field "$system_probe_version_info" compiled_version "$VERSION"
  require_exact_field "$system_probe_version_info" agent_git_sha "$PINNED_AGENT_SHA"
  local sp_output expected_sp_prefix sp_binary_sha
  sp_output="$(read_exact_field "$system_probe_version_info" version_output)"
  expected_sp_prefix="System Probe $VERSION - Commit: ${PINNED_AGENT_SHA:0:10} - Serialization version: "
  case "$sp_output" in
    "$expected_sp_prefix"*' - Go version: go'*) ;;
    *) die "产物 system-probe version 输出没有绑定外层 VERSION/SHA: $sp_output" ;;
  esac
  sp_binary_sha="$(read_exact_field "$system_probe_version_info" binary_sha256)"
  [ "$(tar -xOzf "$artifact" ./embedded/bin/system-probe | sha256sum | awk '{print $1}')" = "$sp_binary_sha" ] || \
    die 'system-probe binary SHA-256 与 version provenance 不一致'
  require_exact_field "$build_info" system_probe_binary_sha256 "$sp_binary_sha"
}

main() {
  validate_inputs

  WORK="$BUILD_WORK/$MODULE"
  AGENT_SRC="$WORK/src/dbdog-agent"
  CORE_SRC="$WORK/src/dbdog-agent-core"
  local out_dir="$WORK/out"
  ARTIFACT_NAME="dbdog-agent-$VERSION-x86_64.tar.gz"
  ARTIFACT_PATH="$out_dir/$ARTIFACT_NAME"
  SIDECAR_PATH="$ARTIFACT_PATH.sha256"

  if [ -f "$ARTIFACT_PATH" ] && [ ! -L "$ARTIFACT_PATH" ] && \
     [ -f "$SIDECAR_PATH" ] && [ ! -L "$SIDECAR_PATH" ]; then
    verify_canonical_artifact "$ARTIFACT_PATH" "$SIDECAR_PATH"
    log "复用已验证的 canonical 产物: $ARTIFACT_PATH"
    printf '%s\t%s\n' "$VERSION" "$ARTIFACT_PATH"
    return 0
  fi
  [ ! -e "$SIDECAR_PATH" ] || die 'canonical sidecar 单独存在，无法证明它对应哪个完整产物，拒绝覆盖'

  mkdir -p "$out_dir"
  require_minimum_free_space "$BUILD_WORK" 'BUILD_WORK'

  fresh_checkout "$AGENT_SRC" "$REPO_ROOT/dbdog-agent" "$SHA"
  fresh_checkout "$CORE_SRC" "$REPO_ROOT/dbdog-agent-core" "$CORE_SHA"
  build_gaussdb_wheel
  run_omnibus_build

  if [ "$(id -u)" != 0 ]; then
    die "Omnibus 构建已完成并通过校验，但产物固化（chown root:root、离线安装 GaussDB wheel、rpath/version/provenance 门禁、确定性打包）需要 root 权限。请管理员在本机以 root 重新执行本配方（同一组 MODULE/VERSION/SHA/CORE_SHA/ARCH/REPO_ROOT/BUILD_WORK 环境变量），不要为此配置 NOPASSWD sudo。完成后重新运行 publish，本配方将验证并复用 canonical 产物"
  fi

  finalize_as_root
  verify_canonical_artifact "$ARTIFACT_PATH" "$SIDECAR_PATH"
  printf '%s\t%s\n' "$VERSION" "$ARTIFACT_PATH"
}

# 通过 `ssh ... bash -s <"$recipe"` 执行时（生产路径），stdin 脚本没有 BASH_SOURCE
# 帧，下面条件恒真，main 照常运行；合同测试改用 `source` 把本文件载入自己的进程，
# 复用 require_exact_field / verify_canonical_artifact 等函数时，BASH_SOURCE[0]
# 指向本文件而 $0 指向测试脚本本身，两者不等，main 不会自动执行，也就不会因为
# 测试环境没有设置 MODULE/VERSION/ARCH 而在 source 阶段就 die/exit 掉调用方。
if [ "${#BASH_SOURCE[@]}" -eq 0 ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
