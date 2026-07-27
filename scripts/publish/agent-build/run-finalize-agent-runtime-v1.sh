#!/usr/bin/bash
# Narrow root entry point for the pinned Kylin V11 AArch64 dbdog-agent
# finalizer. Install this file and the matching finalizer as root-owned,
# read-only controls. Do not grant this control NOPASSWD access: the finalizer
# deliberately executes binaries from the completed build tree and therefore
# requires an administrator's explicit root invocation.
set -euo pipefail

umask 0022
IFS=$' \t\n'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
unset BASH_ENV CDPATH ENV GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
  GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_WORK_TREE

readonly EXPECTED_SELF=/home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v1.sh
readonly FINALIZER=/home/dbdog/cache/dbdog-agent/controls/finalize-agent-runtime-v1.sh
readonly FINALIZER_SHA256=41e0c25a51672d01a687c431535c06772b48895b18b694c976b877f0cbe5ac07
readonly BUILD_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build2
readonly INSTALL_DIR=/opt/dbdog-agent
readonly OUTPUT_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build2/out
readonly CACHE_ROOT=/home/dbdog/cache/dbdog-agent
readonly AGENT_SHA=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
readonly OMNIBUS_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f
readonly CORE_SHA=662ad3974b950f67cf162fb273c180d08cc87a06
readonly MANIFEST_REL="manifests/$AGENT_SHA-$OMNIBUS_CORE_SHA-aarch64-kylin10-v7"
readonly OVERLAY_REL="control-overlays/$AGENT_SHA-$OMNIBUS_CORE_SHA-aarch64-kylin10-v7-omnibus-kylin-platform-v11"
readonly OVERLAY_DIR="$CACHE_ROOT/$OVERLAY_REL"
readonly RUNNER_SHA256=b28e75b7bc1318a82b5584e747e83b11d596ac7b403292162e8c7599c3f58184
readonly PLATFORM_PATCH_SHA256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
readonly CONTROL_INFO_SHA256=3c5af9befdf56c45ebfb14e366b3324f84aa9f0f81390e47a5357beca70a5647
readonly CONTROL_MANIFEST_SHA256=5bf2b308b3d3e936c95080b4577630c65f0606008ce652ae06b5c36b20551c81
readonly PATCHELF_TOOL_REL=tools/patchelf/0.18.0-aarch64-kylin10-v2
readonly PATCHELF_REL="$PATCHELF_TOOL_REL/bin/patchelf"
readonly PATCHELF_TOOL_DIR="$CACHE_ROOT/$PATCHELF_TOOL_REL"
readonly PATCHELF="$CACHE_ROOT/$PATCHELF_REL"
readonly PATCHELF_SHA256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
readonly PATCHELF_INFO_SHA256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
readonly PATCHELF_SUMS_SHA256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
readonly PATCHELF_VERSION=0.18.0
readonly PATCHELF_REPORTED_VERSION="patchelf $PATCHELF_VERSION"
readonly OMNIBUS_RUBY_SHA=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
readonly ARCH=aarch64
readonly BUILDER_IDENTITY=kylin-v10-tercel-native-aarch64-v7

die() {
  printf '[run-finalize-agent-runtime-v1] ERROR: %s\n' "$*" >&2
  exit 1
}

reject_control_characters() {
  local label=$1 value=$2
  case "$value" in
    *$'\n'* | *$'\r'* | *$'\t'*) die "$label contains a control separator" ;;
  esac
}

verify_patchelf_tool_authority() {
  local expected_inventory actual_inventory entry entry_path
  local expected_stat actual_stat resolved_path version_output

  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'
  [[ -d $PATCHELF_TOOL_DIR && ! -L $PATCHELF_TOOL_DIR ]] ||
    die "pinned v9 patchelf tool root must be a real directory: $PATCHELF_TOOL_DIR"
  [[ $(/usr/bin/readlink -e -- "$PATCHELF_TOOL_DIR") == "$PATCHELF_TOOL_DIR" ]] ||
    die 'pinned v9 patchelf tool root resolves through an unexpected path'
  actual_inventory=$(
    {
      printf '.\n'
      /usr/bin/find "$PATCHELF_TOOL_DIR" -xdev -mindepth 1 -printf '%P\n'
    } | /usr/bin/sort
  )
  [[ $actual_inventory == "$expected_inventory" ]] ||
    die 'pinned v9 patchelf tool inventory differs from the exact five-node set'

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$PATCHELF_TOOL_DIR
    else
      entry_path="$PATCHELF_TOOL_DIR/$entry"
    fi
    [[ ! -L $entry_path ]] ||
      die "pinned v9 patchelf tool entry must not be a symlink: $entry_path"
    resolved_path=$(/usr/bin/readlink -e -- "$entry_path") ||
      die "cannot resolve pinned v9 patchelf tool entry: $entry_path"
    [[ $resolved_path == "$entry_path" ]] ||
      die "pinned v9 patchelf tool entry is not canonical: $entry_path"
    case "$entry" in
      . | bin)
        [[ -d $entry_path ]] ||
          die "pinned v9 patchelf tool entry must be a directory: $entry_path"
        expected_stat=0:0:555
        ;;
      PATCHELF-INFO | SHA256SUMS)
        [[ -f $entry_path ]] ||
          die "pinned v9 patchelf metadata entry must be a regular file: $entry_path"
        expected_stat=0:0:444
        ;;
      bin/patchelf)
        [[ -f $entry_path ]] ||
          die "pinned v9 patchelf binary must be a regular file: $entry_path"
        expected_stat=0:0:555
        ;;
      *)
        die "unexpected pinned v9 patchelf inventory entry: $entry"
        ;;
    esac
    actual_stat=$(/usr/bin/stat -c '%u:%g:%a' -- "$entry_path")
    [[ $actual_stat == "$expected_stat" ]] ||
      die "pinned v9 patchelf tool owner/mode mismatch: $entry_path ($actual_stat)"
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$PATCHELF_SHA256" "$PATCHELF" |
    /usr/bin/sha256sum -c - >/dev/null || die 'pinned v9 patchelf binary checksum mismatch'
  printf '%s  %s\n' "$PATCHELF_INFO_SHA256" "$PATCHELF_TOOL_DIR/PATCHELF-INFO" |
    /usr/bin/sha256sum -c - >/dev/null || die 'pinned v9 PATCHELF-INFO checksum mismatch'
  printf '%s  %s\n' "$PATCHELF_SUMS_SHA256" "$PATCHELF_TOOL_DIR/SHA256SUMS" |
    /usr/bin/sha256sum -c - >/dev/null || die 'pinned v9 patchelf SHA256SUMS checksum mismatch'
  (
    cd "$PATCHELF_TOOL_DIR"
    /usr/bin/sha256sum -c SHA256SUMS
  ) >/dev/null || die 'pinned v9 patchelf metadata checksum verification failed'

  version_output=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$PATCHELF" --version
  ) || die 'pinned v9 patchelf version probe failed'
  [[ $version_output == "$PATCHELF_REPORTED_VERSION" ]] ||
    die "pinned v9 patchelf reported an unexpected version: $version_output"
}

[[ ${EUID:-$(/usr/bin/id -u)} == 0 ]] || die 'this control must run as root'
(($# == 1)) || die 'usage: run-finalize-agent-runtime-v1.sh <7.81.1-dbdog.N>'
readonly VERSION=$1
reject_control_characters VERSION "$VERSION"
[[ $VERSION =~ ^7[.]81[.]1-dbdog[.][1-9][0-9]*$ ]] || \
  die "unsupported release version: $VERSION"

if [[ -n ${SUDO_USER:-} ]]; then
  [[ $SUDO_USER == dbdog ]] || die "unexpected sudo caller: $SUDO_USER"
  [[ ${SUDO_UID:-} == "$(/usr/bin/id -u dbdog)" ]] || \
    die 'SUDO_UID does not identify the dbdog build user'
fi

self=$(/usr/bin/readlink -e -- "$0") || die 'cannot resolve this control'
[[ $self == "$EXPECTED_SELF" ]] || die "control must run from $EXPECTED_SELF"
[[ -f $self && ! -L $self ]] || die 'root control is not a regular file'
[[ $(/usr/bin/stat -c '%u:%g:%a' -- "$self") == 0:0:555 ]] || \
  die 'root control must be root:root mode 0555'

[[ $FINALIZER_SHA256 =~ ^[0-9a-f]{64}$ ]] || \
  die 'finalizer SHA-256 has not been frozen in this tracked control'
[[ -f $FINALIZER && ! -L $FINALIZER ]] || \
  die "missing canonical finalizer: $FINALIZER"
[[ $(/usr/bin/readlink -e -- "$FINALIZER") == "$FINALIZER" ]] || \
  die 'canonical finalizer resolves through an unexpected path'
[[ $(/usr/bin/stat -c '%u:%g:%a' -- "$FINALIZER") == 0:0:555 ]] || \
  die 'canonical finalizer must be root:root mode 0555'
printf '%s  %s\n' "$FINALIZER_SHA256" "$FINALIZER" | \
  /usr/bin/sha256sum -c - >/dev/null || die 'canonical finalizer checksum mismatch'

[[ $(/usr/bin/readlink -e -- "$BUILD_DIR") == "$BUILD_DIR" ]] || \
  die "missing or non-canonical build directory: $BUILD_DIR"
[[ $(/usr/bin/readlink -e -- "$INSTALL_DIR") == "$INSTALL_DIR" ]] || \
  die "missing or non-canonical install directory: $INSTALL_DIR"
if [[ -e $OUTPUT_DIR || -L $OUTPUT_DIR ]]; then
  [[ -d $OUTPUT_DIR && ! -L $OUTPUT_DIR ]] || die "output path is not a real directory: $OUTPUT_DIR"
  [[ $(/usr/bin/readlink -e -- "$OUTPUT_DIR") == "$OUTPUT_DIR" ]] || \
    die "non-canonical output directory: $OUTPUT_DIR"
fi

[[ -f /etc/os-release && ! -L /etc/os-release ]] || die 'missing real /etc/os-release'
[[ $(/usr/bin/stat -c '%u:%g' -- /etc/os-release) == 0:0 ]] || \
  die '/etc/os-release must be owned by root:root'
[[ -z $(/usr/bin/find /etc/os-release -maxdepth 0 -perm /022 -print -quit) ]] || \
  die '/etc/os-release must not be writable by group or other users'
os_id=$(/usr/bin/awk -F= '$1 == "ID" { value=$0; sub(/^[^=]*=/, "", value); gsub(/^"|"$/, "", value); print value; count++ } END { exit(count == 1 ? 0 : 1) }' /etc/os-release) || \
  die 'cannot read one OS ID'
os_version=$(/usr/bin/awk -F= '$1 == "VERSION_ID" { value=$0; sub(/^[^=]*=/, "", value); gsub(/^"|"$/, "", value); print value; count++ } END { exit(count == 1 ? 0 : 1) }' /etc/os-release) || \
  die 'cannot read one OS VERSION_ID'
[[ $os_id == kylin && $os_version == V10 ]] || \
  die "root finalizer requires Kylin V10, found $os_id $os_version"

[[ -d $OVERLAY_DIR && ! -L $OVERLAY_DIR ]] || die "missing v11 control overlay: $OVERLAY_DIR"
[[ $(/usr/bin/readlink -e -- "$OVERLAY_DIR") == "$OVERLAY_DIR" ]] || \
  die 'v11 control overlay resolves through an unexpected path'
[[ $(/usr/bin/stat -c '%u:%g:%a' -- "$OVERLAY_DIR") == 0:0:555 ]] || \
  die 'v11 control overlay must be root:root mode 0555'
overlay_inventory=$(/usr/bin/find "$OVERLAY_DIR" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | /usr/bin/sort)
expected_overlay_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
[[ $overlay_inventory == "$expected_overlay_inventory" ]] || \
  die 'v11 control-overlay inventory differs from the pinned four-file set'
for overlay_data in CONTROL-INFO CONTROL.sha256 agent-build-kylin-platform.patch; do
  [[ -f $OVERLAY_DIR/$overlay_data && ! -L $OVERLAY_DIR/$overlay_data ]] || \
    die "v11 control is not a regular file: $overlay_data"
  [[ $(/usr/bin/stat -c '%u:%g:%a' -- "$OVERLAY_DIR/$overlay_data") == 0:0:444 ]] || \
    die "v11 control must be root:root mode 0444: $overlay_data"
done
[[ -f $OVERLAY_DIR/run-agent-omnibus.sh && ! -L $OVERLAY_DIR/run-agent-omnibus.sh ]] || \
  die 'v11 runner is not a regular file'
[[ $(/usr/bin/stat -c '%u:%g:%a' -- "$OVERLAY_DIR/run-agent-omnibus.sh") == 0:0:555 ]] || \
  die 'v11 runner must be root:root mode 0555'
if ! /usr/bin/cmp -s -- "$OVERLAY_DIR/CONTROL.sha256" <(
  printf '%s  %s\n' \
    "$RUNNER_SHA256" \
    "$OVERLAY_REL/run-agent-omnibus.sh" \
    "$PLATFORM_PATCH_SHA256" \
    "$OVERLAY_REL/agent-build-kylin-platform.patch" \
    "$CONTROL_INFO_SHA256" \
    "$OVERLAY_REL/CONTROL-INFO" \
    "$PATCHELF_SHA256" \
    "$PATCHELF_REL"
); then
  die 'v11 CONTROL.sha256 differs from the pinned four-entry manifest'
fi
printf '%s  %s\n' "$CONTROL_MANIFEST_SHA256" "$OVERLAY_DIR/CONTROL.sha256" | \
  /usr/bin/sha256sum -c - >/dev/null || die 'v11 CONTROL.sha256 checksum mismatch'
(cd "$CACHE_ROOT" && /usr/bin/sha256sum -c "$OVERLAY_REL/CONTROL.sha256" >/dev/null) || \
  die 'v11 control-overlay content checksum mismatch'
printf '%s  %s\n' "$RUNNER_SHA256" "$OVERLAY_DIR/run-agent-omnibus.sh" | \
  /usr/bin/sha256sum -c - >/dev/null || die 'v11 runner checksum mismatch'
printf '%s  %s\n' "$PLATFORM_PATCH_SHA256" "$OVERLAY_DIR/agent-build-kylin-platform.patch" | \
  /usr/bin/sha256sum -c - >/dev/null || die 'v11 platform patch checksum mismatch'
printf '%s  %s\n' "$CONTROL_INFO_SHA256" "$OVERLAY_DIR/CONTROL-INFO" | \
  /usr/bin/sha256sum -c - >/dev/null || die 'v11 CONTROL-INFO checksum mismatch'
verify_patchelf_tool_authority

readonly OMNIBUS_SUCCESS="$BUILD_DIR/omnibus.success"
[[ -f $OMNIBUS_SUCCESS && ! -L $OMNIBUS_SUCCESS ]] || die 'missing Omnibus success handoff'
if ! /usr/bin/cmp -s -- "$OMNIBUS_SUCCESS" <(
  printf '%s\n' \
    "manifest_rel=$MANIFEST_REL" \
    "agent_sha=$AGENT_SHA" \
    "core_sha=$OMNIBUS_CORE_SHA" \
    "omnibus_ruby_sha=$OMNIBUS_RUBY_SHA" \
    "control_overlay_rel=$OVERLAY_REL" \
    "control_overlay_runner_sha256=$RUNNER_SHA256" \
    "platform_patch_sha256=$PLATFORM_PATCH_SHA256" \
    "patchelf_rel=$PATCHELF_REL" \
    "patchelf_sha256=$PATCHELF_SHA256" \
    'host_distribution=rhel'
); then
  die 'Omnibus success handoff does not match the exact v7/v11 controls'
fi

exec /usr/bin/env -i \
  HOME=/root \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  BUILD_DIR="$BUILD_DIR" \
  INSTALL_DIR="$INSTALL_DIR" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  VERSION="$VERSION" \
  AGENT_SHA="$AGENT_SHA" \
  CORE_SHA="$CORE_SHA" \
  ARCH="$ARCH" \
  BUILDER_IDENTITY="$BUILDER_IDENTITY" \
  /usr/bin/bash "$FINALIZER"
