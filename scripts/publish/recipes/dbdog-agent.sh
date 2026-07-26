#!/usr/bin/env bash
# 配方：固定输入的 Kylin V10 AArch64 dbdog-agent Omnibus 运行时。
# 输入 env（由 publish.sh 提供）：MODULE VERSION SHA CORE_SHA ARCH。
#
# 本配方消费已经持久化并校验过的 v7 manifest、v10 control overlay、固定
# patchelf 工具和 post-build dependency seal；不会重新解析版本或另建一次性
# 依赖目录。当前 seal
# 明确是 partial closure，不等于“任意新机器离线一键重放”。新构建机必须先迁移
# 完整 cache root、满足 seal 的系统引用并通过 VERIFY.sh；缺任何一项都会停止。
set -euo pipefail

umask 0022
IFS=$' \t\n'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
unset BASH_ENV CDPATH ENV GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
  GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_WORK_TREE

log() {
  printf '[recipe:%s] %s\n' "${MODULE:-dbdog-agent}" "$*" >&2
}

die() {
  printf '[recipe:%s] ERROR: %s\n' "${MODULE:-dbdog-agent}" "$*" >&2
  exit 1
}

reject_control_characters() {
  local label=$1 value=$2
  case "$value" in
    *$'\n'* | *$'\r'* | *$'\t'*) die "$label 含换行或制表控制字符" ;;
  esac
}

require_input() {
  local name=$1 value=${!1-}
  [[ -n $value ]] || die "缺少输入环境变量 $name"
  reject_control_characters "$name" "$value"
}

for input_name in MODULE VERSION SHA CORE_SHA ARCH; do
  require_input "$input_name"
done
readonly MODULE VERSION SHA CORE_SHA ARCH

readonly PINNED_AGENT_SHA=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
readonly PINNED_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f
readonly CACHE_ROOT=/home/dbdog/cache/dbdog-agent
readonly BUILD_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build1
readonly INSTALL_DIR=/opt/dbdog-agent
readonly OUTPUT_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build1/out
readonly MANIFEST_REL="manifests/$PINNED_AGENT_SHA-$PINNED_CORE_SHA-aarch64-kylin10-v7"
readonly MANIFEST_DIR="$CACHE_ROOT/$MANIFEST_REL"
readonly INPUTS_MANIFEST_SHA256=e050cda2067907527b5ff4d3991320d75a2cc8b1f68e078531c1b5fae502ef79
readonly RUBY_CACHE_MANIFEST_SHA256=29539b716e760e178b3a11ce07256e39438dbb5f1008898590ce355eda823c45
readonly OVERLAY_REL="control-overlays/$PINNED_AGENT_SHA-$PINNED_CORE_SHA-aarch64-kylin10-v7-omnibus-kylin-platform-v10"
readonly OVERLAY_DIR="$CACHE_ROOT/$OVERLAY_REL"
readonly RUNNER="$OVERLAY_DIR/run-agent-omnibus.sh"
readonly RUNNER_SHA256=abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812
readonly PLATFORM_PATCH_SHA256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
readonly CONTROL_INFO_SHA256=6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a
readonly CONTROL_MANIFEST_SHA256=f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac
readonly PATCHELF_TOOL_REL=tools/patchelf/0.18.0-aarch64-kylin10-v2
readonly PATCHELF_REL="$PATCHELF_TOOL_REL/bin/patchelf"
readonly PATCHELF_TOOL_DIR="$CACHE_ROOT/$PATCHELF_TOOL_REL"
readonly PATCHELF_BINARY="$CACHE_ROOT/$PATCHELF_REL"
readonly PATCHELF_VERSION=0.18.0
readonly PATCHELF_REPORTED_VERSION='patchelf 0.18.0'
readonly PATCHELF_SHA256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
readonly PATCHELF_INFO_SHA256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
readonly PATCHELF_SUMS_SHA256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
readonly SEAL_DIR="$CACHE_ROOT/seals/${MANIFEST_REL##*/}/omnibus-cache-v2"
# Documentation pointer for the tracked sealer; the published seal verifies
# itself through its own metadata and does not claim this as provenance.
# These hashes are frozen from the exact audited v10 controls.  The explicit
# gate below keeps future edits fail-closed if a maintainer resets one to the
# all-zero placeholder while preparing a new control generation.
readonly TRACKED_SEAL_CONTROL_SHA256=4700cd0c6a1cf4ba01323db50ed11415b4889d03114d2e88cb0d2d49fcda7d8f
readonly FINALIZER="$CACHE_ROOT/controls/finalize-agent-runtime-v1.sh"
readonly FINALIZER_SHA256=237f20579fbb1e9155183211d07cc5b6bbf45908d912021b21a87a17d7c9f79d
readonly FINALIZER_WRAPPER="$CACHE_ROOT/controls/run-finalize-agent-runtime-v1.sh"
readonly FINALIZER_WRAPPER_SHA256=b9f660d25db9c349f0affceb48c0274b23630e5c15174dd223b46bbe76ab8704
readonly BUILDER_IDENTITY=kylin-v10-tercel-native-aarch64-v7
readonly ARCHIVE_RECIPE=gnu_tar_sorted_fixed_mtime_root_owner_gzip_n_two_pass_delete_second_before_extract

readonly UNFROZEN_SHA256=0000000000000000000000000000000000000000000000000000000000000000
for frozen_sha_name in \
  TRACKED_SEAL_CONTROL_SHA256 FINALIZER_SHA256 FINALIZER_WRAPPER_SHA256; do
  frozen_sha=${!frozen_sha_name}
  [[ $frozen_sha =~ ^[0-9a-f]{64}$ && $frozen_sha != "$UNFROZEN_SHA256" ]] || \
    die "$frozen_sha_name 尚未冻结为 v10 控制文件的真实 SHA-256"
done
unset frozen_sha_name frozen_sha

[[ $MODULE == dbdog-agent ]] || die "MODULE 必须是 dbdog-agent，实际为 $MODULE"
[[ $VERSION =~ ^7[.]81[.]1-dbdog[.][1-9][0-9]*$ ]] || \
  die "VERSION 必须是 7.81.1-dbdog.N（N 从 1 开始），实际为 $VERSION"
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || die 'SHA 必须是完整的小写 40 位提交 SHA'
[[ $CORE_SHA =~ ^[0-9a-f]{40}$ ]] || die 'CORE_SHA 必须是完整的小写 40 位提交 SHA'
[[ $SHA == "$PINNED_AGENT_SHA" ]] || \
  die "SHA 不属于当前 v7 seal；需为新提交生成新的 manifest/overlay/seal/配方"
[[ $CORE_SHA == "$PINNED_CORE_SHA" ]] || \
  die "CORE_SHA 不属于当前 v7 seal；需为新提交生成新的 manifest/overlay/seal/配方"
[[ $ARCH == aarch64 ]] || die "ARCH 必须是 aarch64，实际为 $ARCH"

for required_tool in awk bash chmod cmp cp find grep id mktemp readlink rm rmdir sha256sum sort stat tar uname; do
  command -v "$required_tool" >/dev/null 2>&1 || die "构建机缺少工具: $required_tool"
done
[[ $(id -un) == dbdog ]] || die 'Omnibus 配方必须由 dbdog 构建用户运行'
[[ $(uname -m) == aarch64 ]] || die '构建机不是原生 AArch64'
[[ -f /etc/os-release && ! -L /etc/os-release ]] || die '缺少真实的 /etc/os-release'
[[ $(stat -c '%u:%g' -- /etc/os-release) == 0:0 ]] || die '/etc/os-release 必须由 root:root 持有'
[[ -z $(find /etc/os-release -maxdepth 0 -perm /022 -print -quit) ]] || \
  die '/etc/os-release 不得由 group/other 写入'
os_id=$(awk -F= '$1 == "ID" { value=$0; sub(/^[^=]*=/, "", value); gsub(/^"|"$/, "", value); print value; count++ } END { exit(count == 1 ? 0 : 1) }' /etc/os-release) || \
  die '无法唯一读取 /etc/os-release 的 ID'
os_version=$(awk -F= '$1 == "VERSION_ID" { value=$0; sub(/^[^=]*=/, "", value); gsub(/^"|"$/, "", value); print value; count++ } END { exit(count == 1 ? 0 : 1) }' /etc/os-release) || \
  die '无法唯一读取 /etc/os-release 的 VERSION_ID'
[[ $os_id == kylin && $os_version == V10 ]] || \
  die "构建机必须是 Kylin V10，实际为 $os_id $os_version"

require_root_readonly_dir() {
  local label=$1 path=$2 resolved
  [[ -d $path && ! -L $path ]] || die "$label 不是实际目录: $path"
  resolved=$(readlink -e -- "$path") || die "无法解析 $label: $path"
  [[ $resolved == "$path" ]] || die "$label 经过了非预期路径解析: $path -> $resolved"
  [[ $(stat -c '%u:%g' -- "$path") == 0:0 ]] || die "$label 必须由 root:root 持有"
  [[ -z $(find "$path" -maxdepth 0 -perm /022 -print -quit) ]] || \
    die "$label 不得由 group/other 写入"
}

require_root_control() {
  local label=$1 path=$2 expected_mode=$3 expected_sha=$4
  [[ $expected_sha =~ ^[0-9a-f]{64}$ ]] || die "$label 的固定 SHA-256 尚未冻结"
  [[ -f $path && ! -L $path ]] || die "缺少真实的 $label: $path"
  [[ $(readlink -e -- "$path") == "$path" ]] || die "$label 经过了非预期路径解析"
  [[ $(stat -c '%u:%g:%a' -- "$path") == "0:0:$expected_mode" ]] || \
    die "$label 必须是 root:root mode 0$expected_mode"
  printf '%s  %s\n' "$expected_sha" "$path" | sha256sum -c - >/dev/null || \
    die "$label SHA-256 不匹配"
}

require_exact_field() {
  local file=$1 key=$2 expected=$3 count actual
  count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$file")
  [[ $count == 1 ]] || die "$file 必须且只能包含一个 $key"
  actual=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' "$file")
  [[ $actual == "$expected" ]] || die "$file 的 $key 不匹配（实际 $actual）"
}

verify_persistent_controls() {
  local overlay_inventory expected_inventory

  require_root_readonly_dir 'v7 manifest' "$MANIFEST_DIR"
  printf '%s  %s\n' "$INPUTS_MANIFEST_SHA256" "$MANIFEST_DIR/INPUTS.sha256" | \
    sha256sum -c - >/dev/null || die 'v7 INPUTS.sha256 自身不匹配'
  printf '%s  %s\n' "$RUBY_CACHE_MANIFEST_SHA256" "$MANIFEST_DIR/RUBY-BUNDLE-CACHE.sha256" | \
    sha256sum -c - >/dev/null || die 'v7 Ruby cache manifest 自身不匹配'
  (cd "$CACHE_ROOT" && sha256sum -c "$MANIFEST_REL/INPUTS.sha256" >/dev/null) || \
    die 'v7 持久化输入校验失败'
  (cd "$CACHE_ROOT" && sha256sum -c "$MANIFEST_REL/RUBY-BUNDLE-CACHE.sha256" >/dev/null) || \
    die 'v7 Ruby 持久化缓存校验失败'

  require_root_readonly_dir 'v10 control overlay' "$OVERLAY_DIR"
  expected_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
  overlay_inventory=$(find "$OVERLAY_DIR" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  [[ $overlay_inventory == "$expected_inventory" ]] || die 'v10 control overlay 文件集合不匹配'
  printf '%s  %s\n' "$CONTROL_MANIFEST_SHA256" "$OVERLAY_DIR/CONTROL.sha256" | \
    sha256sum -c - >/dev/null || die 'v10 CONTROL.sha256 自身不匹配'
  cmp -s -- "$OVERLAY_DIR/CONTROL.sha256" <(
    printf '%s  %s\n' \
      "$RUNNER_SHA256" "$OVERLAY_REL/run-agent-omnibus.sh" \
      "$PLATFORM_PATCH_SHA256" "$OVERLAY_REL/agent-build-kylin-platform.patch" \
      "$CONTROL_INFO_SHA256" "$OVERLAY_REL/CONTROL-INFO" \
      "$PATCHELF_SHA256" "$PATCHELF_REL"
  ) || die 'v10 CONTROL.sha256 必须精确包含固定顺序的四行清单'
  (cd "$CACHE_ROOT" && sha256sum -c "$OVERLAY_REL/CONTROL.sha256" >/dev/null) || \
    die 'v10 control overlay 或固定 patchelf 内容校验失败'
  require_root_control 'v10 Omnibus runner' "$RUNNER" 555 "$RUNNER_SHA256"
}

verify_patchelf_tool() (
  local expected_inventory actual_inventory entry entry_path expected_stat actual_stat
  local version_output smoke_dir smoke_elf smoke_rpath actual_rpath

  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'
  require_root_readonly_dir 'v9 patchelf tool root' "$PATCHELF_TOOL_DIR"
  actual_inventory=$(
    {
      printf '.\n'
      find "$PATCHELF_TOOL_DIR" -xdev -mindepth 1 -printf '%P\n'
    } | LC_ALL=C sort
  )
  [[ $actual_inventory == "$expected_inventory" ]] || \
    die 'v9 patchelf 工具目录不符合固定五节点清单'

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$PATCHELF_TOOL_DIR
    else
      entry_path="$PATCHELF_TOOL_DIR/$entry"
    fi
    [[ ! -L $entry_path && $(readlink -e -- "$entry_path") == "$entry_path" ]] || \
      die "v9 patchelf 工具节点不是无符号链接的 canonical 路径: $entry_path"
    case $entry in
      . | bin)
        [[ -d $entry_path ]] || die "v9 patchelf 工具节点不是目录: $entry_path"
        expected_stat=0:0:555
        ;;
      PATCHELF-INFO | SHA256SUMS)
        [[ -f $entry_path ]] || die "v9 patchelf 元数据节点不是普通文件: $entry_path"
        expected_stat=0:0:444
        ;;
      bin/patchelf)
        [[ -f $entry_path ]] || die "v9 patchelf binary 不是普通文件: $entry_path"
        expected_stat=0:0:555
        ;;
      *) die "v9 patchelf 工具出现非预期节点: $entry" ;;
    esac
    actual_stat=$(stat -c '%u:%g:%a' -- "$entry_path")
    [[ $actual_stat == "$expected_stat" ]] || \
      die "v9 patchelf 工具节点 owner/mode 不匹配: $entry_path ($actual_stat)"
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$PATCHELF_SHA256" "$PATCHELF_BINARY" | \
    sha256sum -c - >/dev/null || die 'v9 patchelf binary SHA-256 不匹配'
  printf '%s  %s\n' "$PATCHELF_INFO_SHA256" "$PATCHELF_TOOL_DIR/PATCHELF-INFO" | \
    sha256sum -c - >/dev/null || die 'v9 PATCHELF-INFO SHA-256 不匹配'
  printf '%s  %s\n' "$PATCHELF_SUMS_SHA256" "$PATCHELF_TOOL_DIR/SHA256SUMS" | \
    sha256sum -c - >/dev/null || die 'v9 patchelf SHA256SUMS 自身不匹配'
  cmp -s -- "$PATCHELF_TOOL_DIR/SHA256SUMS" <(
    printf '%s  %s\n' \
      "$PATCHELF_INFO_SHA256" PATCHELF-INFO \
      "$PATCHELF_SHA256" bin/patchelf
  ) || die 'v9 patchelf SHA256SUMS 不是固定的两行清单'
  (cd "$PATCHELF_TOOL_DIR" && sha256sum -c SHA256SUMS >/dev/null) || \
    die 'v9 patchelf 工具内容校验失败'
  require_exact_field "$PATCHELF_TOOL_DIR/PATCHELF-INFO" format dbdog-patchelf-tool-v2
  require_exact_field "$PATCHELF_TOOL_DIR/PATCHELF-INFO" version "$PATCHELF_VERSION"
  require_exact_field "$PATCHELF_TOOL_DIR/PATCHELF-INFO" binary_rel bin/patchelf
  require_exact_field "$PATCHELF_TOOL_DIR/PATCHELF-INFO" binary_sha256 "$PATCHELF_SHA256"
  require_exact_field "$PATCHELF_TOOL_DIR/PATCHELF-INFO" reported_version "$PATCHELF_REPORTED_VERSION"

  version_output=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$PATCHELF_BINARY" --version
  ) || die '固定 v9 patchelf 无法执行 --version'
  [[ $version_output == "$PATCHELF_REPORTED_VERSION" ]] || \
    die "固定 v9 patchelf 版本输出不匹配（实际 $version_output）"

  smoke_dir=$(mktemp -d /tmp/.dbdog-recipe-patchelf.XXXXXX)
  smoke_elf=$smoke_dir/true
  trap 'rm -f -- "$smoke_elf"; rmdir -- "$smoke_dir"' EXIT
  cp -- /usr/bin/true "$smoke_elf"
  chmod 0755 "$smoke_elf"
  smoke_rpath="\$ORIGIN/.dbdog-recipe-patchelf-smoke"
  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    "$PATCHELF_BINARY" --set-rpath "$smoke_rpath" "$smoke_elf" || \
    die '固定 v9 patchelf RPATH 写入 smoke test 失败'
  actual_rpath=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$PATCHELF_BINARY" --print-rpath "$smoke_elf"
  ) || die '固定 v9 patchelf RPATH 读取 smoke test 失败'
  [[ $actual_rpath == "$smoke_rpath" ]] || \
    die "固定 v9 patchelf RPATH smoke test 结果不匹配（实际 $actual_rpath）"
  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$smoke_elf" || \
    die '固定 v9 patchelf 修改后的 ELF 无法执行'
  rm -f -- "$smoke_elf"
  rmdir -- "$smoke_dir"
  trap - EXIT
)

verify_dependency_seal() {
  [[ -d $SEAL_DIR ]] || die "缺少依赖 seal: $SEAL_DIR。该配方不会在新机器临时下载或猜依赖；请先用 tracked seal control（文件 SHA-256 $TRACKED_SEAL_CONTROL_SHA256，仅用于定位配方）在原构建机封存，再迁移完整 cache root 并完成受控 replay/bootstrap"
  require_root_readonly_dir 'post-build dependency seal' "$SEAL_DIR"
  [[ -f $SEAL_DIR/VERIFY.sh && ! -L $SEAL_DIR/VERIFY.sh ]] || \
    die "依赖 seal 缺少 VERIFY.sh: $SEAL_DIR"
  [[ $(stat -c '%u:%g:%a' -- "$SEAL_DIR/VERIFY.sh") == 0:0:444 ]] || \
    die '依赖 seal 的 VERIFY.sh 必须是 root:root mode 0444'
}

verify_dependency_seal_metadata() {
  [[ -f $SEAL_DIR/SEAL-INFO && ! -L $SEAL_DIR/SEAL-INFO ]] || die '依赖 seal 缺少 SEAL-INFO'
  require_exact_field "$SEAL_DIR/SEAL-INFO" seal_format omnibus-cache-v2
  require_exact_field "$SEAL_DIR/SEAL-INFO" build_id "${MANIFEST_REL##*/}"
  require_exact_field "$SEAL_DIR/SEAL-INFO" manifest_rel "$MANIFEST_REL"
  require_exact_field "$SEAL_DIR/SEAL-INFO" control_overlay_rel "$OVERLAY_REL"
  require_exact_field "$SEAL_DIR/SEAL-INFO" control_overlay_runner_sha256 "$RUNNER_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" platform_patch_sha256 "$PLATFORM_PATCH_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" control_info_sha256 "$CONTROL_INFO_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" control_manifest_sha256 "$CONTROL_MANIFEST_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" dbdog_agent_commit "$PINNED_AGENT_SHA"
  require_exact_field "$SEAL_DIR/SEAL-INFO" integrations_core_commit "$PINNED_CORE_SHA"
  require_exact_field "$SEAL_DIR/SEAL-INFO" patchelf_version "$PATCHELF_VERSION"
  require_exact_field "$SEAL_DIR/SEAL-INFO" patchelf_rel "$PATCHELF_REL"
  require_exact_field "$SEAL_DIR/SEAL-INFO" patchelf_sha256 "$PATCHELF_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" patchelf_info_sha256 "$PATCHELF_INFO_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" patchelf_sums_sha256 "$PATCHELF_SUMS_SHA256"
  require_exact_field "$SEAL_DIR/SEAL-INFO" system_reference_count 4
  require_exact_field "$SEAL_DIR/SEAL-INFO" selinux_system_reference_count 3
  require_exact_field "$SEAL_DIR/SEAL-INFO" closure_status partial-no-clean-host-offline-replay
  /usr/bin/env -i \
    HOME=/home/dbdog \
    PATH=/usr/bin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DBDOG_AGENT_CACHE_ROOT="$CACHE_ROOT" \
    /usr/bin/bash "$SEAL_DIR/VERIFY.sh" >&2 || \
    die '依赖 seal 或它引用的持久 cache 校验失败；不允许回退到重新下载'
  log '依赖 seal 校验通过（其 portability 声明仍为 partial，不冒充 clean-host 离线闭包）'
}

write_expected_omnibus_marker() {
  local destination=$1
  printf '%s\n' \
    "manifest_rel=$MANIFEST_REL" \
    "agent_sha=$PINNED_AGENT_SHA" \
    "core_sha=$PINNED_CORE_SHA" \
    'omnibus_ruby_sha=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749' \
    "control_overlay_rel=$OVERLAY_REL" \
    "control_overlay_runner_sha256=$RUNNER_SHA256" \
    "platform_patch_sha256=$PLATFORM_PATCH_SHA256" \
    "patchelf_rel=$PATCHELF_REL" \
    "patchelf_sha256=$PATCHELF_SHA256" \
    'host_distribution=rhel' \
    >"$destination"
}

verify_live_omnibus_handoff() {
  local expected
  [[ -f $BUILD_DIR/omnibus.success && ! -L $BUILD_DIR/omnibus.success ]] || \
    die 'Omnibus runner 未生成真实的 omnibus.success'
  expected=$(mktemp "$BUILD_DIR/.recipe-omnibus-success.XXXXXX")
  write_expected_omnibus_marker "$expected"
  if ! cmp -s -- "$expected" "$BUILD_DIR/omnibus.success"; then
    rm -f -- "$expected"
    die 'omnibus.success 与固定 v7/v10 handoff 不匹配'
  fi
  rm -f -- "$expected"
}

require_archive_member() {
  local list=$1 member=$2 count
  count=$(grep -Fxc -- "$member" "$list" || true)
  [[ $count == 1 ]] || die "产物必须且只能包含一个 $member"
}

verify_canonical_artifact() (
  local artifact=$1 sidecar=$2 artifact_name member duplicate actual_sha work list build_info marker expected_marker
  artifact_name=${artifact##*/}
  [[ -f $artifact && ! -L $artifact ]] || die "canonical 产物不是实际文件: $artifact"
  [[ -f $sidecar && ! -L $sidecar ]] || die "canonical 产物缺少实际 sidecar: $sidecar"
  [[ $(readlink -e -- "$artifact") == "$artifact" ]] || die 'canonical 产物路径发生解析'
  [[ $(readlink -e -- "$sidecar") == "$sidecar" ]] || die 'canonical sidecar 路径发生解析'
  [[ $(stat -c '%u:%g:%a' -- "$artifact") == 0:0:644 ]] || \
    die 'canonical 产物必须是 root:root mode 0644'
  [[ $(stat -c '%u:%g:%a' -- "$sidecar") == 0:0:644 ]] || \
    die 'canonical sidecar 必须是 root:root mode 0644'
  actual_sha=$(sha256sum -- "$artifact" | awk '{ print $1 }')
  printf '%s  %s\n' "$actual_sha" "$artifact_name" | cmp -s - "$sidecar" || \
    die 'canonical sidecar 与产物 SHA-256 不匹配'

  work=$(mktemp -d "$BUILD_DIR/.recipe-artifact-verify.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  list=$work/archive.list
  tar --quoting-style=literal -tzf "$artifact" >"$list" || die '无法读取 canonical tarball'
  [[ -s $list ]] || die 'canonical tarball 为空'
  while IFS= read -r member; do
    reject_control_characters 'archive member' "$member"
    [[ $member != *\\* ]] || die "archive member 含反斜线: $member"
    case "$member" in
      . | ./) ;;
      ./*)
        case "/${member#./}/" in */../*) die "archive member 越过父目录: $member" ;; esac
        ;;
      *) die "archive member 不是 install-root 相对路径: $member" ;;
    esac
  done <"$list"
  duplicate=$(LC_ALL=C sort "$list" | awk 'previous == $0 { print; exit } { previous=$0 }')
  [[ -z $duplicate ]] || die "archive member 重复: $duplicate"
  if grep -Eq '^\./(opt/)?dbdog-agent/' "$list"; then
    die 'tarball 错误包含 dbdog-agent wrapper 目录'
  fi
  require_archive_member "$list" './.install_root'
  require_archive_member "$list" './provenance/build.txt'
  require_archive_member "$list" './provenance/omnibus.success'
  require_archive_member "$list" './provenance/runtime.sha256'
  require_archive_member "$list" './provenance/glibc-requirements.tsv'
  require_archive_member "$list" './provenance/agent-data-plane.txt'
  require_archive_member "$list" './provenance/gaussdb.txt'

  build_info=$work/build.txt
  marker=$work/omnibus.success
  tar -xOzf "$artifact" ./provenance/build.txt >"$build_info" || die '无法读取产物 build provenance'
  tar -xOzf "$artifact" ./provenance/omnibus.success >"$marker" || die '无法读取产物 Omnibus provenance'
  require_exact_field "$build_info" format_version 1
  require_exact_field "$build_info" product dbdog-agent
  require_exact_field "$build_info" version "$VERSION"
  require_exact_field "$build_info" architecture aarch64
  require_exact_field "$build_info" install_prefix "$INSTALL_DIR"
  require_exact_field "$build_info" agent_git_sha "$PINNED_AGENT_SHA"
  require_exact_field "$build_info" integrations_core_git_sha "$PINNED_CORE_SHA"
  require_exact_field "$build_info" manifest_rel "$MANIFEST_REL"
  require_exact_field "$build_info" control_overlay_rel "$OVERLAY_REL"
  require_exact_field "$build_info" control_overlay_runner_sha256 "$RUNNER_SHA256"
  require_exact_field "$build_info" platform_patch_sha256 "$PLATFORM_PATCH_SHA256"
  require_exact_field "$build_info" control_info_sha256 "$CONTROL_INFO_SHA256"
  require_exact_field "$build_info" control_manifest_sha256 "$CONTROL_MANIFEST_SHA256"
  require_exact_field "$build_info" patchelf_version "$PATCHELF_VERSION"
  require_exact_field "$build_info" patchelf_rel "$PATCHELF_REL"
  require_exact_field "$build_info" patchelf_sha256 "$PATCHELF_SHA256"
  require_exact_field "$build_info" patchelf_info_sha256 "$PATCHELF_INFO_SHA256"
  require_exact_field "$build_info" patchelf_sums_sha256 "$PATCHELF_SUMS_SHA256"
  require_exact_field "$build_info" host_distribution rhel
  require_exact_field "$build_info" builder_image_digest none
  require_exact_field "$build_info" builder_identity "$BUILDER_IDENTITY"
  require_exact_field "$build_info" finalizer_sha256 "$FINALIZER_SHA256"
  require_exact_field "$build_info" glibc_maximum 2.28
  require_exact_field "$build_info" archive_recipe "$ARCHIVE_RECIPE"
  expected_marker=$work/expected-omnibus.success
  write_expected_omnibus_marker "$expected_marker"
  cmp -s -- "$expected_marker" "$marker" || die '产物内 Omnibus provenance 与固定 handoff 不匹配'
)

verify_persistent_controls
verify_patchelf_tool
verify_dependency_seal
verify_dependency_seal_metadata

[[ -d $BUILD_DIR && ! -L $BUILD_DIR ]] || die "缺少固定 build attempt: $BUILD_DIR"
[[ $(readlink -e -- "$BUILD_DIR") == "$BUILD_DIR" ]] || die '固定 build attempt 路径发生解析'
if [[ -e $OUTPUT_DIR || -L $OUTPUT_DIR ]]; then
  [[ -d $OUTPUT_DIR && ! -L $OUTPUT_DIR ]] || die "固定输出路径不是实际目录: $OUTPUT_DIR"
  [[ $(readlink -e -- "$OUTPUT_DIR") == "$OUTPUT_DIR" ]] || die '固定输出目录路径发生解析'
fi

readonly ARTIFACT="$OUTPUT_DIR/dbdog-agent-$VERSION-$ARCH.tar.gz"
readonly SIDECAR="$ARTIFACT.sha256"
if [[ -e $ARTIFACT || -L $ARTIFACT || -e $SIDECAR || -L $SIDECAR ]]; then
  [[ -e $ARTIFACT && -e $SIDECAR ]] || die 'canonical 产物与 sidecar 只存在其一，拒绝覆盖'
  verify_canonical_artifact "$ARTIFACT" "$SIDECAR"
  log "复用已验证的 canonical 产物: $ARTIFACT"
  printf '%s\t%s\n' "$VERSION" "$ARTIFACT"
  exit 0
fi

runner_executed=0
if [[ ! -e $BUILD_DIR/omnibus.success && ! -L $BUILD_DIR/omnibus.success ]]; then
  runner_mode=()
  if [[ -e $BUILD_DIR/omnibus-post-health-v2.log || -L $BUILD_DIR/omnibus-post-health-v2.log || \
        -e $BUILD_DIR/src/omnibus/pkg/post-health-resume.json || -L $BUILD_DIR/src/omnibus/pkg/post-health-resume.json || \
        -e $INSTALL_DIR/.debug || -L $INSTALL_DIR/.debug ]]; then
    runner_mode=(--adopt-post-health-v2)
    log '未发现成功 handoff，但发现 post-health v2 完成态；调用固定 v10 adoption 入口'
  elif [[ -e $BUILD_DIR/omnibus-v9-retry6.log && -d /opt/.dbdog-agent-prestrip-post-health-v2-20260727 ]] && \
       find "$INSTALL_DIR" -mindepth 1 -print -quit | grep -q .; then
    runner_mode=(--resume-v9-retry6-post-health)
    log '未发现成功 handoff；调用固定 v10 retry6 post-health resume 入口'
  else
    log '未发现成功 handoff；调用固定 v10 fresh runner（依赖和 patchelf 从已验证的持久 cache 复用）'
  fi
  /usr/bin/env -i \
    HOME=/home/dbdog \
    USER=dbdog \
    LOGNAME=dbdog \
    SHELL=/bin/bash \
    PATH=/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    "$RUNNER" "${runner_mode[@]}" "$BUILD_DIR" >&2 || die '固定 v10 Omnibus runner 失败'
  runner_executed=1
fi
verify_live_omnibus_handoff
if ((runner_executed == 1)); then
  log 'runner 完成后重新验证 dependency seal 与持久 cache'
  verify_dependency_seal_metadata
fi

require_root_control 'canonical finalizer' "$FINALIZER" 555 "$FINALIZER_SHA256"
require_root_control 'narrow root finalizer wrapper' "$FINALIZER_WRAPPER" 555 "$FINALIZER_WRAPPER_SHA256"
die "Omnibus handoff 已验证，但缺少 root 最终化产物。请管理员交互式执行：sudo $FINALIZER_WRAPPER $VERSION；不要为该命令配置 NOPASSWD。完成后重新运行 publish，配方将验证并复用 canonical 产物"
