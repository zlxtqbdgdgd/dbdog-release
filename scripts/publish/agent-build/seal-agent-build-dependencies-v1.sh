#!/usr/bin/env bash
set -euo pipefail
umask 0022

pipeline_lock_held=0
if [[ ${1:-} == --dbdog-agent-pipeline-lock-held ]]; then
  pipeline_lock_held=1
  shift
fi

build_dir=${BUILD_DIR:-${1:-/home/dbdog/work/dbdog-agent-4c39489b-build1}}
build_dir=$(readlink -f -- "$build_dir")
case "$build_dir" in
  /home/dbdog/work/dbdog-agent-4c39489b-build*) ;;
  *)
    echo "unsafe build directory: $build_dir" >&2
    exit 1
    ;;
esac

cache_root=/home/dbdog/cache/dbdog-agent
agent_sha=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
core_sha=7a4247599b029f1aca10d2cb63491d535fbd502f
omnibus_ruby_sha=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
chef_sugar_sha=2078c030011838d2151268191004cc0a9263f6f4
bundle_lock_sha256=aac25290049ce954c2296f9e1c1694205eaa886c46c27f7d9a5b085ba9582d99
manifest_rel="manifests/$agent_sha-$core_sha-aarch64-kylin10-v7"
manifest_dir="$cache_root/$manifest_rel"
build_id=${manifest_rel##*/}
control_overlay_rel="control-overlays/$build_id-omnibus-kylin-platform-v10"
control_overlay_dir="$cache_root/$control_overlay_rel"
control_overlay_runner_sha256=abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812
platform_patch_sha256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
control_info_sha256=6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a
control_manifest_sha256=f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac
patchelf_tool_rel=tools/patchelf/0.18.0-aarch64-kylin10-v2
patchelf_rel="$patchelf_tool_rel/bin/patchelf"
patchelf_tool_dir="$cache_root/$patchelf_tool_rel"
patchelf_sha256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
patchelf_info_sha256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
patchelf_sums_sha256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
patchelf_version=0.18.0
patchelf_reported_stdout='patchelf 0.18.0'
host_distribution=rhel
seal_parent="$cache_root/seals/$build_id"
seal_name=omnibus-cache-v2
seal_dir="$seal_parent/$seal_name"
pipeline_lock_dir="$cache_root/locks"
pipeline_lock="$pipeline_lock_dir/dbdog-agent-4c39489b-aarch64-kylin10.pipeline.lock"
distdir_publish_lock_dir=/run/dbdog-distdir-publisher
distdir_publish_lock="$distdir_publish_lock_dir/publisher.lock"
src_dir="$build_dir/src"
agent_mirror="$cache_root/git/dbdog-agent.git"
core_mirror="$cache_root/git/dbdog-agent-core.git"
core_bundle_rel="sources/git/dbdog-agent-core-$core_sha.bundle"
core_bundle="$cache_root/$core_bundle_rel"
ruby_package_rel="bundle-package-cache/$bundle_lock_sha256"
ruby_package_cache="$cache_root/$ruby_package_rel"
dda_archive_rel=sources/dda/legacy/dda-0.37.0-legacy-ca70f3d1a63408de-py3.12.8-aarch64.tar.zst
dda_archive="$cache_root/$dda_archive_rel"
dda_inventory="$manifest_dir/DDA-LEGACY-VENV.sha256"
dda_symlinks="$manifest_dir/DDA-LEGACY-VENV.symlinks"
dda_freeze="$manifest_dir/DDA-LEGACY-VENV.freeze"
dda_info="$manifest_dir/DDA-LEGACY-VENV.info"
dda_archive_checksum="$manifest_dir/DDA-LEGACY-VENV.archive.sha256"
dda_hydrate_control="$manifest_dir/controls/hydrate-agent-dda-legacy.sh"
dda_verify_control="$manifest_dir/controls/verify-agent-dda-legacy.sh"
runuser_link=/home/dbdog/tools/bin/runuser
runuser_system_path=/usr/sbin/runuser
checkmodule_system_path=/usr/bin/checkmodule
checkmodule_package=checkpolicy-2.8-6.ky10.aarch64
checkmodule_sha256=b128531e2a54d0998e212eb81d142ce598627aa4fec95bddf97982755d83d6c7
checkmodule_bytes=462616
checkmodule_mode=755
semodule_package_system_path=/usr/bin/semodule_package
semodule_package_package=policycoreutils-2.8-14.2.p01.ky10.aarch64
semodule_package_sha256=9740fd6a91bf548d4a95394890b8494feabd1f2087e82a8866bf1038f61a102a
semodule_package_bytes=68320
semodule_package_mode=755
libsepol_system_path=/usr/lib64/libsepol.so.1
libsepol_package=libsepol-2.9-1.p01.ky10.aarch64
libsepol_sha256=ab0d1f6f003794273d2fd6b1dc5f16daead54eb55fd08b0f4ed9a367004031cb
libsepol_bytes=790336
libsepol_mode=755
system_reference_count=4
selinux_system_reference_count=3
rpm_bin=/usr/bin/rpm
system_probe_success="$build_dir/system-probe.success"
omnibus_success="$build_dir/omnibus.success"
assets_dir="$build_dir/exact-system-probe-assets"
create_agent_bundle=${DBDOG_SEAL_CREATE_AGENT_BUNDLE:-0}

if ((EUID != 0)); then
  echo "run the post-build dependency seal as root" >&2
  exit 1
fi
case "$create_agent_bundle" in
  0 | 1) ;;
  *)
    echo "DBDOG_SEAL_CREATE_AGENT_BUNDLE must be 0 or 1" >&2
    exit 1
    ;;
esac

fail() {
  echo "$*" >&2
  exit 1
}

atomic_rename_noreplace() {
  local source_path=$1 destination_path=$2

  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    /usr/bin/python3 -I - "$source_path" "$destination_path" <<'PYTHON'
import ctypes
import errno
import os
import sys

if len(sys.argv) != 3:
    raise SystemExit("renameat2 helper requires source and destination")

at_fdcwd = -100
rename_noreplace = 1
libc = ctypes.CDLL(None, use_errno=True)
try:
    renameat2 = libc.renameat2
except AttributeError:
    raise SystemExit("libc does not expose renameat2")

renameat2.argtypes = (
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
)
renameat2.restype = ctypes.c_int
source = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
if renameat2(at_fdcwd, source, at_fdcwd, destination, rename_noreplace) == 0:
    raise SystemExit(0)

error_number = ctypes.get_errno()
if error_number == errno.EEXIST:
    raise SystemExit(f"destination already exists: {sys.argv[2]}")
raise SystemExit(
    f"renameat2(RENAME_NOREPLACE) failed: {os.strerror(error_number)} "
    f"(errno={error_number})"
)
PYTHON
}

verify_omnibus_success_marker() {
  local marker=$1

  test -f "$marker" || fail "missing regular Omnibus success marker: $marker"
  test ! -L "$marker" || fail "Omnibus success marker is a symlink: $marker"
  cmp -s -- "$marker" <(
    printf '%s\n' \
      "manifest_rel=$manifest_rel" \
      "agent_sha=$agent_sha" \
      "core_sha=$core_sha" \
      "omnibus_ruby_sha=$omnibus_ruby_sha" \
      "control_overlay_rel=$control_overlay_rel" \
      "control_overlay_runner_sha256=$control_overlay_runner_sha256" \
      "platform_patch_sha256=$platform_patch_sha256" \
      "patchelf_rel=$patchelf_rel" \
      "patchelf_sha256=$patchelf_sha256" \
      "host_distribution=$host_distribution"
  ) || fail "Omnibus success marker does not match the exact Kylin v10 handoff: $marker"
}

verify_omnibus_control_overlay_tree() {
  local tree_root=$1 overlay_dir actual_inventory expected_inventory overlay_file

  overlay_dir="$tree_root/$control_overlay_rel"
  test -d "$overlay_dir" || fail "missing Omnibus v10 control-overlay directory: $overlay_dir"
  test ! -L "$overlay_dir" || fail "Omnibus v10 control-overlay directory is a symlink"
  test "$(readlink -e -- "$overlay_dir")" = "$overlay_dir" ||
    fail "Omnibus v10 control overlay resolves through an unexpected path"
  test "$(stat -c '%u:%g:%a' -- "$overlay_dir")" = 0:0:555 ||
    fail "Omnibus v10 control-overlay directory must be root:root mode 0555"

  expected_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
  actual_inventory=$(find "$overlay_dir" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  test "$actual_inventory" = "$expected_inventory" ||
    fail "Omnibus v10 control-overlay inventory differs from the exact four-file set"

  for overlay_file in CONTROL-INFO CONTROL.sha256 agent-build-kylin-platform.patch; do
    test -f "$overlay_dir/$overlay_file" ||
      fail "Omnibus v10 control file is not regular: $overlay_file"
    test ! -L "$overlay_dir/$overlay_file" ||
      fail "Omnibus v10 control file is a symlink: $overlay_file"
    test "$(stat -c '%u:%g:%a' -- "$overlay_dir/$overlay_file")" = 0:0:444 ||
      fail "Omnibus v10 control file must be root:root mode 0444: $overlay_file"
  done
  test -f "$overlay_dir/run-agent-omnibus.sh" || fail "Omnibus v9 runner is not regular"
  test ! -L "$overlay_dir/run-agent-omnibus.sh" || fail "Omnibus v9 runner is a symlink"
  test "$(stat -c '%u:%g:%a' -- "$overlay_dir/run-agent-omnibus.sh")" = 0:0:555 ||
    fail "Omnibus v9 runner must be root:root mode 0555"

  cmp -s -- "$overlay_dir/CONTROL.sha256" <(
    printf '%s  %s\n' \
      "$control_overlay_runner_sha256" \
      "$control_overlay_rel/run-agent-omnibus.sh" \
      "$platform_patch_sha256" \
      "$control_overlay_rel/agent-build-kylin-platform.patch" \
      "$control_info_sha256" \
      "$control_overlay_rel/CONTROL-INFO" \
      "$patchelf_sha256" \
      "$patchelf_rel"
  ) || fail "Omnibus v9 CONTROL.sha256 differs from the pinned four-line manifest"
  printf '%s  %s\n' "$control_manifest_sha256" "$overlay_dir/CONTROL.sha256" \
    | sha256sum -c - >/dev/null || fail "Omnibus v9 CONTROL.sha256 digest changed"
  (
    cd "$tree_root"
    sha256sum -c "$control_overlay_rel/CONTROL.sha256"
  ) >/dev/null || fail "Omnibus v10 control-overlay checksum verification failed"
}

verify_patchelf_tool_tree() {
  local tree_root=$1 tool_dir expected_inventory actual_inventory entry entry_path
  local expected_stat actual_stat resolved_path version_output

  tool_dir="$tree_root/$patchelf_tool_rel"
  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'
  test -d "$tool_dir" || fail "missing pinned v9 patchelf tool root: $tool_dir"
  test ! -L "$tool_dir" || fail "pinned v9 patchelf tool root is a symlink: $tool_dir"
  actual_inventory=$(
    {
      printf '.\n'
      find "$tool_dir" -xdev -mindepth 1 -printf '%P\n'
    } | LC_ALL=C sort
  )
  test "$actual_inventory" = "$expected_inventory" ||
    fail "pinned v9 patchelf tool differs from the exact five-node inventory: $tool_dir"

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$tool_dir
    else
      entry_path="$tool_dir/$entry"
    fi
    test ! -L "$entry_path" || fail "pinned v9 patchelf entry is a symlink: $entry_path"
    resolved_path=$(readlink -e -- "$entry_path" || :)
    test "$resolved_path" = "$entry_path" ||
      fail "pinned v9 patchelf entry is not canonical: $entry_path"
    case "$entry" in
      . | bin)
        test -d "$entry_path" || fail "pinned v9 patchelf entry is not a directory: $entry_path"
        expected_stat=0:0:555
        ;;
      PATCHELF-INFO | SHA256SUMS)
        test -f "$entry_path" || fail "pinned v9 patchelf metadata is not regular: $entry_path"
        expected_stat=0:0:444
        ;;
      bin/patchelf)
        test -f "$entry_path" || fail "pinned v9 patchelf binary is not regular: $entry_path"
        expected_stat=0:0:555
        ;;
      *) fail "unexpected pinned v9 patchelf inventory entry: $entry" ;;
    esac
    actual_stat=$(stat -c '%u:%g:%a' -- "$entry_path")
    test "$actual_stat" = "$expected_stat" ||
      fail "pinned v9 patchelf owner/mode mismatch: $entry_path ($actual_stat)"
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$patchelf_sha256" "$tool_dir/bin/patchelf" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf binary checksum changed"
  printf '%s  %s\n' "$patchelf_info_sha256" "$tool_dir/PATCHELF-INFO" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf info checksum changed"
  printf '%s  %s\n' "$patchelf_sums_sha256" "$tool_dir/SHA256SUMS" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf checksum manifest changed"
  (cd "$tool_dir" && sha256sum -c SHA256SUMS >/dev/null) ||
    fail "pinned v9 patchelf internal checksum verification failed"
  version_output=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$tool_dir/bin/patchelf" --version
  )
  test "$version_output" = "$patchelf_reported_stdout" ||
    fail "pinned v9 patchelf reported an unexpected version: $version_output"
}

verify_exact_system_reference() {
  local label=$1 path=$2 expected_package=$3 expected_sha256=$4
  local expected_bytes=$5 expected_mode=$6 require_executable=$7
  local resolved actual_package actual_sha256 actual_bytes actual_mode actual_owner

  [[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    fail "$label expected SHA-256 is not a full lowercase digest"
  [[ $expected_bytes =~ ^[1-9][0-9]*$ ]] ||
    fail "$label expected byte count is invalid"
  [[ $expected_mode =~ ^[0-7]{3,4}$ ]] ||
    fail "$label expected mode is invalid"
  [[ $require_executable == 0 || $require_executable == 1 ]] ||
    fail "$label executable policy is invalid"
  [[ -f $path && ! -L $path ]] ||
    fail "$label must be a real regular file: $path"
  resolved=$(readlink -e -- "$path") || fail "cannot resolve $label: $path"
  [[ $resolved == "$path" ]] || fail "$label path is not canonical: $path -> $resolved"
  actual_owner=$(stat -c '%u:%g' -- "$path")
  [[ $actual_owner == 0:0 ]] || fail "$label must be owned by root:root: $path ($actual_owner)"
  if [[ $require_executable == 1 ]]; then
    [[ -x $path ]] || fail "$label must be executable: $path"
  else
    [[ -r $path ]] || fail "$label must be readable: $path"
  fi

  actual_package=$(
    "$rpm_bin" -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$path"
  ) || fail "cannot query the RPM owner for $label: $path"
  [[ $actual_package == "$expected_package" ]] ||
    fail "$label RPM mismatch: expected $expected_package, found $actual_package"
  actual_sha256=$(sha256sum -- "$path" | awk '{print $1}')
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    fail "$label SHA-256 mismatch: expected $expected_sha256, found $actual_sha256"
  actual_bytes=$(stat -c '%s' -- "$path")
  [[ $actual_bytes == "$expected_bytes" ]] ||
    fail "$label byte count mismatch: expected $expected_bytes, found $actual_bytes"
  actual_mode=$(stat -c '%a' -- "$path")
  [[ $actual_mode == "$expected_mode" ]] ||
    fail "$label mode mismatch: expected $expected_mode, found $actual_mode"
}

required_tools=(
  awk bash cat chmod chown cmp cp date dirname env find flock git grep install
  ln mktemp mv readlink rm rmdir rsync sha256sum sort stat sync tar wc zstd
)
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || {
    echo "missing dependency-seal tool: $tool" >&2
    exit 1
  }
done
test -x "$rpm_bin" || fail "missing RPM package-query tool: $rpm_bin"
test -L "$runuser_link" || fail "expected runuser tool link: $runuser_link"
test "$(readlink -- "$runuser_link")" = "$runuser_system_path" || \
  fail "$runuser_link must point exactly to $runuser_system_path"
test "$(readlink -f -- "$runuser_link")" = "$runuser_system_path" || \
  fail "$runuser_link does not resolve to $runuser_system_path"
test -f "$runuser_system_path"
test ! -L "$runuser_system_path"
test -x "$runuser_system_path"
runuser_package=$(
  "$rpm_bin" -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    "$runuser_system_path"
)
[[ -n $runuser_package && $runuser_package != *$'\n'* && $runuser_package != *$'\t'* ]] || \
  fail "could not identify one RPM package for $runuser_system_path"
runuser_file_sha256=$(sha256sum "$runuser_system_path" | awk '{print $1}')
runuser_file_bytes=$(stat -c '%s' "$runuser_system_path")
runuser_file_mode=$(stat -c '%a' "$runuser_system_path")

verify_exact_system_reference \
  checkmodule "$checkmodule_system_path" "$checkmodule_package" \
  "$checkmodule_sha256" "$checkmodule_bytes" "$checkmodule_mode" 1
verify_exact_system_reference \
  semodule-package "$semodule_package_system_path" "$semodule_package_package" \
  "$semodule_package_sha256" "$semodule_package_bytes" \
  "$semodule_package_mode" 1
verify_exact_system_reference \
  libsepol-soname "$libsepol_system_path" "$libsepol_package" \
  "$libsepol_sha256" "$libsepol_bytes" "$libsepol_mode" 0

install -d -o dbdog -g dbdog -m 2775 "$pipeline_lock_dir"
if ((pipeline_lock_held == 0)); then
  exec /usr/bin/flock -n -E 75 -o "$pipeline_lock" \
    /usr/bin/bash "$0" --dbdog-agent-pipeline-lock-held "$build_dir"
fi
if [[ -e $distdir_publish_lock_dir || -L $distdir_publish_lock_dir ]]; then
  test -d "$distdir_publish_lock_dir" || fail "distdir publisher lock path is not a directory"
  test ! -L "$distdir_publish_lock_dir" || fail "distdir publisher lock directory is a symlink"
else
  install -d -o root -g root -m 0700 -- "$distdir_publish_lock_dir"
fi
test "$(readlink -e -- "$distdir_publish_lock_dir")" = "$distdir_publish_lock_dir" ||
  fail "distdir publisher lock directory is not canonical"
test "$(stat -c '%u:%g:%a' -- "$distdir_publish_lock_dir")" = 0:0:700 ||
  fail "distdir publisher lock directory must be root:root mode 0700"
if [[ -e $distdir_publish_lock || -L $distdir_publish_lock ]]; then
  test -f "$distdir_publish_lock" || fail "distdir publisher lock path is not a regular file"
  test ! -L "$distdir_publish_lock" || fail "distdir publisher lock path is a symlink"
fi
saved_umask=$(umask)
umask 0077
exec 8<>"$distdir_publish_lock"
umask "$saved_umask"
test -f /proc/self/fd/8 || fail "distdir publisher lock is not a regular file"
test "$(stat -Lc '%u:%g:%a' -- /proc/self/fd/8)" = 0:0:600 ||
  fail "distdir publisher lock must be root:root mode 0600"
flock -n 8 || fail "another distdir publisher is active"

git_safe() {
  local repository=$1 git_home
  shift

  # Kylin's Git 2.27 safe.directory backport ignores command-scope and
  # GIT_CONFIG_SYSTEM entries.  Give each root-owned Git invocation an
  # isolated, short-lived global config instead of changing root's real
  # ~/.gitconfig.  Running Git as root is intentional here: bundle creation
  # and verification also access the root-only seal staging directory.
  git_home=$(mktemp -d /run/dbdog-agent-seal-git.XXXXXX)
  chmod 0700 "$git_home"
  (
    cleanup_git_home() {
      rm -f -- "$git_home/.gitconfig"
      rmdir -- "$git_home" 2>/dev/null || :
    }
    trap cleanup_git_home EXIT
    /usr/bin/env -i \
      HOME="$git_home" \
      PATH=/usr/bin:/bin \
      LANG=C \
      LC_ALL=C \
      /usr/bin/git config --global safe.directory "$repository"
    chmod 0600 "$git_home/.gitconfig"
    /usr/bin/env -i \
      HOME="$git_home" \
      PATH=/usr/bin:/bin \
      LANG=C \
      LC_ALL=C \
      /usr/bin/git -C "$repository" "$@"
  )
}

test -d "$cache_root"
test -d "$manifest_dir"
test -d "$control_overlay_dir"
test -d "$patchelf_tool_dir"
test -f "$manifest_dir/INPUTS.sha256"
test -f "$manifest_dir/RUBY-BUNDLE-CACHE.sha256"
for dda_path in \
  "$dda_archive" \
  "$dda_inventory" \
  "$dda_symlinks" \
  "$dda_freeze" \
  "$dda_info" \
  "$dda_archive_checksum" \
  "$dda_hydrate_control" \
  "$dda_verify_control"
do
  test -f "$dda_path" || fail "missing sealed v7 DDA input: $dda_path"
done
test -f "$system_probe_success"
test -f "$omnibus_success"
test -d "$src_dir/.git"
test -d "$agent_mirror"
test -d "$core_mirror"
test -f "$core_bundle"
test -d "$ruby_package_cache"
test -d /opt/dbdog-agent
find /opt/dbdog-agent -mindepth 1 -print -quit | grep -q . || \
  fail "/opt/dbdog-agent is empty; Omnibus output is not complete"

verify_patchelf_tool_tree "$cache_root"
verify_omnibus_control_overlay_tree "$cache_root"
(cd "$cache_root" && sha256sum -c "$manifest_rel/INPUTS.sha256")
(cd "$cache_root" && sha256sum -c "$manifest_rel/RUBY-BUNDLE-CACHE.sha256")

require_v7_input() {
  local relative=$1
  awk -v expected="$relative" '
    $1 ~ /^[0-9a-f]{64}$/ && $2 == expected { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$manifest_dir/INPUTS.sha256" || \
    fail "v7 INPUTS.sha256 does not pin required input: $relative"
}

for dda_manifest_name in \
  DDA-LEGACY-VENV.sha256 \
  DDA-LEGACY-VENV.symlinks \
  DDA-LEGACY-VENV.freeze \
  DDA-LEGACY-VENV.info \
  DDA-LEGACY-VENV.archive.sha256 \
  controls/hydrate-agent-dda-legacy.sh \
  controls/verify-agent-dda-legacy.sh
do
  require_v7_input "$manifest_rel/$dda_manifest_name"
done
require_v7_input "$dda_archive_rel"

dda_archive_checksum_lines=$(wc -l <"$dda_archive_checksum")
test "$dda_archive_checksum_lines" -eq 1 || \
  fail "DDA archive checksum must contain exactly one entry"
read -r dda_archive_expected_sha256 dda_archive_checksum_path <"$dda_archive_checksum"
[[ $dda_archive_expected_sha256 =~ ^[0-9a-f]{64}$ ]] || \
  fail "DDA archive checksum is not a lowercase SHA-256 digest"
test "$dda_archive_checksum_path" = "$dda_archive_rel" || \
  fail "DDA archive checksum points at an unexpected path: $dda_archive_checksum_path"
test "$(sha256sum "$dda_archive" | awk '{print $1}')" = \
  "$dda_archive_expected_sha256" || fail "DDA legacy archive checksum mismatch"
grep -Fx "archive_rel=$dda_archive_rel" "$dda_info" >/dev/null || \
  fail "DDA info does not record the exact archive path"
grep -Fx "archive_sha256=$dda_archive_expected_sha256" "$dda_info" >/dev/null || \
  fail "DDA info does not record the exact archive checksum"
dda_inventory_file_count=$(wc -l <"$dda_inventory")
dda_symlink_count=$(wc -l <"$dda_symlinks")
dda_package_count=$(wc -l <"$dda_freeze")
grep -Fx "inventory_file_count=$dda_inventory_file_count" "$dda_info" >/dev/null || \
  fail "DDA info file count differs from the v7 inventory"
grep -Fx "symlink_count=$dda_symlink_count" "$dda_info" >/dev/null || \
  fail "DDA info symlink count differs from the v7 inventory"
grep -Fx "package_count=$dda_package_count" "$dda_info" >/dev/null || \
  fail "DDA info package count differs from the v7 freeze inventory"

# First validate the active environment with the v7 control, then prove that the
# immutable archive independently hydrates to the same file, symlink, and package
# inventories. The round trip is attempt-local and never enters the seal.
"$runuser_system_path" -u dbdog -- env HOME=/home/dbdog TMPDIR=/tmp \
  /usr/bin/bash "$dda_verify_control" "$manifest_dir"
verify_dda_archive_round_trip() (
  roundtrip_root=$(mktemp -d "$build_dir/.dda-seal-roundtrip.XXXXXX")
  case "$roundtrip_root" in
    "$build_dir"/.dda-seal-roundtrip.*) ;;
    *) fail "unsafe DDA round-trip directory: $roundtrip_root" ;;
  esac
  trap 'rm -rf -- "$roundtrip_root"' EXIT
  chown dbdog:dbdog "$roundtrip_root"
  chmod 0755 "$roundtrip_root"
  extract_dir="$roundtrip_root/extracted"
  hydrate_dir="$roundtrip_root/hydrated"
  install -d -o dbdog -g dbdog -m 0755 "$extract_dir" "$hydrate_dir"

  "$runuser_system_path" -u dbdog -- tar \
    --no-same-owner \
    --use-compress-program=zstd \
    -xf "$dda_archive" \
    -C "$extract_dir"
  "$runuser_system_path" -u dbdog -- rsync -rlptD \
    --checksum \
    --delete \
    --delete-excluded \
    --exclude='*.pyc' \
    --exclude='*/__pycache__' \
    --exclude='*/__pycache__/*' \
    "$extract_dir/" "$hydrate_dir/"

  actual_file_count=$(
    find "$hydrate_dir" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' \
      -print | wc -l
  )
  test "$actual_file_count" -eq "$dda_inventory_file_count" || \
    fail "hydrated DDA archive file count differs from its v7 inventory"
  (cd "$hydrate_dir" && sha256sum -c "$dda_inventory" >/dev/null)

  hydrated_symlinks="$roundtrip_root/symlinks"
  hydrated_freeze="$roundtrip_root/freeze"
  (
    cd "$hydrate_dir"
    find . -type l -printf '%P -> %l\n' | LC_ALL=C sort
  ) >"$hydrated_symlinks"
  cmp "$hydrated_symlinks" "$dda_symlinks" || \
    fail "hydrated DDA archive symlinks differ from the v7 inventory"
  test -x "$hydrate_dir/bin/python"
  test "$("$runuser_system_path" -u dbdog -- env HOME=/home/dbdog TMPDIR=/tmp \
    "$hydrate_dir/bin/python" -c 'import platform; print(platform.python_version())')" = \
    3.12.8
  test "$("$runuser_system_path" -u dbdog -- env HOME=/home/dbdog TMPDIR=/tmp \
    "$hydrate_dir/bin/python" -c 'import invoke; print(invoke.__version__)')" = \
    2.2.0
  "$runuser_system_path" -u dbdog -- env HOME=/home/dbdog TMPDIR=/tmp \
    "$hydrate_dir/bin/python" -m pip freeze --all \
    | LC_ALL=C sort >"$hydrated_freeze"
  cmp "$hydrated_freeze" "$dda_freeze" || \
    fail "hydrated DDA archive packages differ from the v7 freeze inventory"
)
verify_dda_archive_round_trip

assets_manifest_sha256=$(sha256sum "$assets_dir/SHA256SUMS" | awk '{print $1}')
outputs_manifest_sha256=$(
  sha256sum "$assets_dir/SYSTEM-PROBE-OUTPUTS.sha256" | awk '{print $1}'
)
cmp -s -- "$system_probe_success" <(
  printf '%s\n' \
    "manifest_rel=$manifest_rel" \
    "agent_sha=$agent_sha" \
    "core_sha=$core_sha" \
    "assets_manifest_sha256=$assets_manifest_sha256" \
    "outputs_manifest_sha256=$outputs_manifest_sha256"
) || fail "system-probe success marker does not match the sealed v7 inputs"
verify_omnibus_success_marker "$omnibus_success"

test "$(git_safe "$src_dir" rev-parse HEAD)" = "$agent_sha"
test "$(git_safe "$agent_mirror" rev-parse --is-bare-repository)" = true
git_safe "$agent_mirror" cat-file -e "$agent_sha^{commit}"
test "$(git_safe "$core_mirror" rev-parse --is-bare-repository)" = true
git_safe "$core_mirror" cat-file -e "$core_sha^{commit}"
git_safe "$core_mirror" bundle verify "$core_bundle" >/dev/null
git_safe "$core_mirror" bundle list-heads "$core_bundle" \
  | grep -Fx "$core_sha refs/dbdog-build-inputs/$core_sha" >/dev/null

ruby_cache_file_count=$(find "$ruby_package_cache" -type f -print | wc -l)
ruby_cache_symlink_count=$(find "$ruby_package_cache" -type l -print | wc -l)
test "$ruby_cache_file_count" -eq 336 || \
  fail "expected 336 Ruby package-cache files, found $ruby_cache_file_count"
test "$ruby_cache_symlink_count" -eq 0 || \
  fail "Ruby package cache unexpectedly contains symlinks"

install -d -o root -g root -m 0755 "$cache_root/seals" "$seal_parent"
if [[ -e "$seal_dir" ]]; then
  fail "dependency seal already exists and will not be overwritten: $seal_dir"
fi

stage=$(mktemp -d "$seal_parent/.${seal_name}.partial.XXXXXX")
cleanup_stage() {
  if [[ -n ${stage:-} && -e $stage ]]; then
    case "$stage" in
      "$seal_parent"/."$seal_name".partial.*) rm -rf -- "$stage" ;;
      *) echo "refusing to remove unexpected seal staging path: $stage" >&2 ;;
    esac
  fi
}
trap cleanup_stage EXIT

# The cache hierarchy is intentionally setgid for shared build inputs.  GNU
# chmod preserves a directory's setgid bit unless it is cleared explicitly,
# so normalize this root before creating any immutable seal descendants.
chmod g-s -- "$stage"
chmod 0700 "$stage"
test "$(stat -c '%u:%g:%a' -- "$stage")" = 0:0:700 ||
  fail "dependency-seal staging root must be root:root mode 0700"

install -d -o root -g root -m 0755 \
  "$stage/objects/sha256" \
  "$stage/git-bundles" \
  "$stage/handoffs" \
  "$stage/snapshots" \
  "$stage/snapshots/cache-root/control-overlays" \
  "$stage/snapshots/cache-root/tools/patchelf"

copy_tree_hardlink_first() {
  local source=$1 destination=$2
  if cp -al -- "$source" "$destination" 2>/dev/null; then
    return
  fi
  case "$destination" in
    "$stage"/*) rm -rf -- "$destination" ;;
    *) fail "unsafe snapshot destination: $destination" ;;
  esac
  cp -a --reflink=auto -- "$source" "$destination"
}

copy_file_hardlink_first() {
  local source=$1 destination=$2
  if ln -- "$source" "$destination" 2>/dev/null; then
    return
  fi
  cp --reflink=auto --sparse=always -- "$source" "$destination"
}

# These small, already-immutable trees are kept in reusable layouts. The v9
# overlay and patchelf authority preserve their original cache-relative paths
# so CONTROL.sha256 remains directly verifiable during a replay. Patchelf is
# copied independently: a hardlink would let the seal's final chmod mutate the
# live executable that the build runner verifies.
copy_tree_hardlink_first "$manifest_dir" "$stage/snapshots/v7-manifest"
copy_tree_hardlink_first "$ruby_package_cache" \
  "$stage/snapshots/ruby-package-cache-$bundle_lock_sha256"
cp -a --reflink=auto -- "$control_overlay_dir" \
  "$stage/snapshots/cache-root/control-overlays/"
cp -a --reflink=auto -- "$patchelf_tool_dir" \
  "$stage/snapshots/cache-root/tools/patchelf/"
test "$(stat -c '%d:%i' -- "$patchelf_tool_dir/bin/patchelf")" != \
  "$(stat -c '%d:%i' -- "$stage/snapshots/cache-root/$patchelf_rel")" ||
  fail "sealed patchelf snapshot must not hardlink the live executable"
verify_patchelf_tool_tree "$stage/snapshots/cache-root"
verify_omnibus_control_overlay_tree "$stage/snapshots/cache-root"
copy_file_hardlink_first "$core_bundle" \
  "$stage/git-bundles/dbdog-agent-core-$core_sha.bundle"
install -o root -g root -m 0644 "$system_probe_success" \
  "$stage/handoffs/system-probe.success"
install -o root -g root -m 0644 "$omnibus_success" \
  "$stage/handoffs/omnibus.success"
verify_omnibus_success_marker "$stage/handoffs/omnibus.success"
install -o root -g root -m 0644 "$assets_dir/SHA256SUMS" \
  "$stage/handoffs/system-probe-assets.sha256"
install -o root -g root -m 0644 "$assets_dir/SYSTEM-PROBE-OUTPUTS.sha256" \
  "$stage/handoffs/system-probe-outputs.sha256"

# These four dependencies are deliberately host-system references rather than
# copied build inputs. Record the runuser shim plus each exact RPM-owned target
# so verification fails if a later host silently substitutes any of them.
printf '%s\n' \
  $'role\trequested_path\tresolved_target\trpm_package\tsha256\tbytes\tmode\tstorage' \
  "runuser"$'\t'"$runuser_link"$'\t'"$runuser_system_path"$'\t'"$runuser_package"$'\t'"$runuser_file_sha256"$'\t'"$runuser_file_bytes"$'\t'"$runuser_file_mode"$'\t'"system-reference" \
  "checkmodule"$'\t'"$checkmodule_system_path"$'\t'"$checkmodule_system_path"$'\t'"$checkmodule_package"$'\t'"$checkmodule_sha256"$'\t'"$checkmodule_bytes"$'\t'"$checkmodule_mode"$'\t'"system-reference" \
  "semodule-package"$'\t'"$semodule_package_system_path"$'\t'"$semodule_package_system_path"$'\t'"$semodule_package_package"$'\t'"$semodule_package_sha256"$'\t'"$semodule_package_bytes"$'\t'"$semodule_package_mode"$'\t'"system-reference" \
  "libsepol-soname"$'\t'"$libsepol_system_path"$'\t'"$libsepol_system_path"$'\t'"$libsepol_package"$'\t'"$libsepol_sha256"$'\t'"$libsepol_bytes"$'\t'"$libsepol_mode"$'\t'"system-reference" \
  >"$stage/SYSTEM-TOOLS.tsv"

printf '%s\n' \
  $'role\tcache_path\tsha256\tversion\treplay_authority' \
  "omnibus-runner"$'\t'"$control_overlay_rel/run-agent-omnibus.sh"$'\t'"$control_overlay_runner_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/run-agent-omnibus.sh" \
  "kylin-platform-patch"$'\t'"$control_overlay_rel/agent-build-kylin-platform.patch"$'\t'"$platform_patch_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/agent-build-kylin-platform.patch" \
  "control-info"$'\t'"$control_overlay_rel/CONTROL-INFO"$'\t'"$control_info_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/CONTROL-INFO" \
  "control-manifest"$'\t'"$control_overlay_rel/CONTROL.sha256"$'\t'"$control_manifest_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/CONTROL.sha256" \
  "patchelf-binary"$'\t'"$patchelf_rel"$'\t'"$patchelf_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_rel" \
  "patchelf-info"$'\t'"$patchelf_tool_rel/PATCHELF-INFO"$'\t'"$patchelf_info_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_tool_rel/PATCHELF-INFO" \
  "patchelf-manifest"$'\t'"$patchelf_tool_rel/SHA256SUMS"$'\t'"$patchelf_sums_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_tool_rel/SHA256SUMS" \
  >"$stage/BUILD-CONTROLS.tsv"

agent_bundle_rel=-
agent_bundle_sha256=-
if ((create_agent_bundle == 1)); then
  agent_bundle_rel="git-bundles/dbdog-agent-$agent_sha.bundle"
  git_safe "$src_dir" bundle create "$stage/$agent_bundle_rel" HEAD
  git_safe "$src_dir" bundle verify "$stage/$agent_bundle_rel" >/dev/null
  git_safe "$src_dir" bundle list-heads "$stage/$agent_bundle_rel" \
    | grep -Fx "$agent_sha HEAD" >/dev/null
  agent_bundle_sha256=$(sha256sum "$stage/$agent_bundle_rel" | awk '{print $1}')
fi

candidate_list="$stage/.candidates.tsv"
candidate_sorted="$stage/.candidates.sorted.tsv"
symlink_list="$stage/.symlinks.tsv"
: >"$candidate_list"
: >"$symlink_list"
declare -A candidate_seen=()
declare -A symlink_seen=()

validate_relative_name() {
  local relative_name=$1
  [[ -n $relative_name ]] || fail "empty cache-relative dependency path"
  case "$relative_name" in
    /* | ../* | */../* | *$'\n'* | *$'\r'* | *$'\t'* | *\\*)
      fail "unsupported cache-relative dependency path: $relative_name"
      ;;
  esac
}

add_candidate() {
  local category=$1 path=$2 policy=${3:-object} relative
  test -f "$path" || fail "missing authoritative dependency file: $path"
  test ! -L "$path" || fail "regular dependency unexpectedly resolves as a symlink: $path"
  case "$path" in
    "$cache_root"/*) relative=${path#"$cache_root/"} ;;
    *) fail "authoritative dependency escapes cache root: $path" ;;
  esac
  validate_relative_name "$relative"
  case "$policy" in
    object | reference) ;;
    *) fail "unknown dependency storage policy: $policy" ;;
  esac
  if [[ ${candidate_seen["$relative"]+present} ]]; then
    return
  fi
  candidate_seen["$relative"]=1
  printf '%s\t%s\t%s\n' "$category" "$relative" "$policy" >>"$candidate_list"
}

add_symlink() {
  local category=$1 path=$2 relative target
  test -L "$path" || fail "expected dependency symlink: $path"
  case "$path" in
    "$cache_root"/*) relative=${path#"$cache_root/"} ;;
    *) fail "dependency symlink escapes cache root: $path" ;;
  esac
  validate_relative_name "$relative"
  target=$(readlink -- "$path")
  case "$target" in
    *$'\n'* | *$'\r'* | *$'\t'*)
      fail "unsupported dependency symlink target: $path"
      ;;
  esac
  if [[ ${symlink_seen["$relative"]+present} ]]; then
    return
  fi
  symlink_seen["$relative"]=1
  printf '%s\t%s\t%s\n' "$category" "$relative" "$target" >>"$symlink_list"
}

is_transient_cache_file() {
  local name=${1##*/}
  case "$name" in
    *.lock | *.part | *.partial | *.tmp | *.temp | *.swp | *~ | .nfs*) return 0 ;;
    *) return 1 ;;
  esac
}

collect_regular_tree() {
  local category=$1 directory=$2 policy=${3:-object} path
  [[ -d $directory ]] || return 0
  while IFS= read -r -d '' path; do
    is_transient_cache_file "$path" && continue
    add_candidate "$category" "$path" "$policy"
  done < <(find "$directory" -type f -print0 | LC_ALL=C sort -z)
}

collect_symlink_tree() {
  local category=$1 directory=$2 path
  [[ -d $directory ]] || return 0
  while IFS= read -r -d '' path; do
    add_symlink "$category" "$path"
  done < <(find "$directory" -type l -print0 | LC_ALL=C sort -z)
}

# The v7 manifest is the root of trust. Add both the manifest itself and every
# cache-relative path it already pins.
collect_regular_tree v7-manifest "$manifest_dir"
while IFS= read -r input_line; do
  if [[ ! $input_line =~ ^([0-9a-f]{64})[[:space:]][[:space:]](.+)$ ]]; then
    fail "unsupported line in v7 INPUTS.sha256: $input_line"
  fi
  expected_sha256=${BASH_REMATCH[1]}
  input_relative=${BASH_REMATCH[2]}
  validate_relative_name "$input_relative"
  input_path="$cache_root/$input_relative"
  actual_sha256=$(sha256sum "$input_path" | awk '{print $1}')
  test "$actual_sha256" = "$expected_sha256" || \
    fail "v7 input changed while sealing: $input_relative"
  add_candidate v7-input "$input_path"
done <"$manifest_dir/INPUTS.sha256"

# Portable source archives and bundles. Prepared/extracted toolchain trees are
# deliberately omitted because the v7 archives and their manifests recreate
# them without preserving a mutable build tree.
collect_regular_tree persistent-source "$cache_root/sources"
collect_regular_tree bazel-distdir "$cache_root/distdir"
collect_regular_tree persistent-toolchain-archive "$cache_root/toolchains"

# Bundler's versioned package cache is the authoritative Ruby input. Installed
# gems, compact-index metadata, the offline proof installation, and both
# attempt-local writable work caches are derived and are not included.
collect_regular_tree ruby-package-cache "$ruby_package_cache"

# Only Go's immutable download protocol files are authoritative. Extracted
# modules, the VCS cache, @v/list, lock files, and the compiler cache are either
# reproducible from these files or mutable coordination state.
go_download_dir="$cache_root/go/mod/cache/download"
go_download_count=0
if [[ -d $go_download_dir ]]; then
  while IFS= read -r -d '' go_file; do
    go_relative=${go_file#"$go_download_dir/"}
    case "$go_relative" in
      */@v/list | */@v/*.lock | *.lock | *.tmp | *.partial) continue ;;
      */@v/*.info | */@v/*.mod | */@v/*.zip | */@v/*.ziphash | sumdb/*)
        add_candidate go-module-download "$go_file"
        go_download_count=$((go_download_count + 1))
        ;;
      *) ;;
    esac
  done < <(find "$go_download_dir" -type f -print0 | LC_ALL=C sort -z)
fi
((go_download_count > 0)) || fail "Go module download cache is empty"

# Omnibus's source cache contains downloaded source archives. Its Git cache is
# a tagged acceleration cache for completed software builds, so active pack and
# index files are explicitly excluded below.
omnibus_source_dir="$cache_root/omnibus/sources"
omnibus_source_count=0
if [[ -d $omnibus_source_dir ]]; then
  while IFS= read -r -d '' omnibus_file; do
    is_transient_cache_file "$omnibus_file" && continue
    add_candidate omnibus-downloaded-source "$omnibus_file"
    omnibus_source_count=$((omnibus_source_count + 1))
  done < <(find "$omnibus_source_dir" -type f -print0 | LC_ALL=C sort -z)
fi
((omnibus_source_count > 0)) || fail "Omnibus downloaded-source cache is empty"

# Bazel's content-addressable leaf files are immutable inputs and can be linked
# into the seal. Materialized repository trees preserve important executable
# modes, so they receive a complete content/mode/symlink manifest instead of
# hardlinks whose final 0444 mode would alter the active cache.
bazel_cas_dir="$cache_root/bazel/repository/content_addressable"
bazel_contents_dir="$cache_root/bazel/repository/contents"
bazel_cas_count=0
if [[ -d $bazel_cas_dir ]]; then
  while IFS= read -r -d '' bazel_file; do
    is_transient_cache_file "$bazel_file" && continue
    add_candidate bazel-repository-cas "$bazel_file"
    bazel_cas_count=$((bazel_cas_count + 1))
  done < <(find "$bazel_cas_dir" -type f -print0 | LC_ALL=C sort -z)
fi
((bazel_cas_count > 0)) || fail "Bazel content-addressable repository cache is empty"
collect_regular_tree bazel-repository-expanded "$bazel_contents_dir" reference
collect_symlink_tree bazel-repository-expanded "$bazel_contents_dir"
# Record any repository-cache metadata introduced by this Bazel version without
# guessing that it is a portable archive. Already-seen CAS/contents paths are
# de-duplicated by add_candidate/add_symlink.
collect_regular_tree bazel-repository-other "$cache_root/bazel/repository" reference
collect_symlink_tree bazel-repository-other "$cache_root/bazel/repository"

# Pip and uv contain opaque HTTP/index metadata as well as useful archives.
# Keep only directly reusable wheel/sdist archives; opaque entries are called
# out as a closure gap rather than being mislabeled as an offline wheelhouse.
python_archive_count=0
for python_cache in "$cache_root/pip" "$cache_root/uv"; do
  [[ -d $python_cache ]] || continue
  while IFS= read -r -d '' python_file; do
    case "$python_file" in
      *.whl | *.zip | *.tar.gz | *.tar.bz2 | *.tar.xz | *.tgz | *.egg)
        add_candidate python-wheel-or-source "$python_file"
        python_archive_count=$((python_archive_count + 1))
        ;;
      *) ;;
    esac
  done < <(find "$python_cache" -type f -print0 | LC_ALL=C sort -z)
done

LC_ALL=C sort -t $'\t' -k2,2 "$candidate_list" >"$candidate_sorted"
printf '%s\n' \
  $'category\tsha256\tbytes\trestore_mode\tstorage\tsealed_object\tcache_path' \
  >"$stage/AUTHORITATIVE-FILES.tsv"
: >"$stage/CACHE-REFERENCES.sha256"
printf '%s\n' $'restore_mode\tcache_path' >"$stage/REFERENCE-MODES.tsv"

hardlink_count=0
reference_only_count=0
while IFS=$'\t' read -r category relative policy; do
  source_path="$cache_root/$relative"
  source_sha256=$(sha256sum "$source_path" | awk '{print $1}')
  source_bytes=$(stat -c '%s' "$source_path")
  source_mode=$(stat -c '%a' "$source_path")
  object_relative="objects/sha256/${source_sha256:0:2}/$source_sha256"
  object_path="$stage/$object_relative"
  storage=sealed-object

  if [[ $policy == reference ]]; then
    storage=cache-reference
    object_relative=-
    reference_only_count=$((reference_only_count + 1))
    printf '%s\t%s\n' "$source_mode" "$relative" >>"$stage/REFERENCE-MODES.tsv"
  else
    install -d -o root -g root -m 0755 "${object_path%/*}"
    if [[ -e $object_path ]]; then
      test -f "$object_path"
      test "$(sha256sum "$object_path" | awk '{print $1}')" = "$source_sha256"
    elif ln -- "$source_path" "$object_path" 2>/dev/null; then
      hardlink_count=$((hardlink_count + 1))
      chown root:root "$object_path"
      chmod 0444 "$object_path"
    else
      # A cache subdirectory can be a separate mount even though it sits below
      # cache_root. Do not make an unbounded copy in that case: retain a fully
      # verified external reference and disclose that the seal is not portable.
      storage=cache-reference
      object_relative=-
      reference_only_count=$((reference_only_count + 1))
      printf '%s\t%s\n' "$source_mode" "$relative" >>"$stage/REFERENCE-MODES.tsv"
    fi
  fi

  printf '%s  %s\n' "$source_sha256" "$relative" \
    >>"$stage/CACHE-REFERENCES.sha256"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$category" "$source_sha256" "$source_bytes" "$source_mode" \
    "$storage" "$object_relative" "$relative" \
    >>"$stage/AUTHORITATIVE-FILES.tsv"
done <"$candidate_sorted"

printf '%s\n' $'category\tcache_path\ttarget' >"$stage/CACHE-SYMLINKS.tsv"
LC_ALL=C sort -t $'\t' -k2,2 "$symlink_list" \
  >>"$stage/CACHE-SYMLINKS.tsv"

category_summary_tmp="$stage/.category-summary.tsv"
awk -F '\t' '
  NR > 1 {
    count[$1] += 1
    bytes[$1] += $3
    if ($5 == "cache-reference") references[$1] += 1
  }
  END {
    for (category in count) {
      printf "%s\t%d\t%.0f\t%d\n", category, count[category], bytes[category], references[category]
    }
  }
' "$stage/AUTHORITATIVE-FILES.tsv" | LC_ALL=C sort >"$category_summary_tmp"
printf '%s\n' $'category\tfiles\tlogical_bytes\treference_only_files' \
  >"$stage/CATEGORY-SUMMARY.tsv"
cat "$category_summary_tmp" >>"$stage/CATEGORY-SUMMARY.tsv"

agent_tree=$(git_safe "$agent_mirror" rev-parse "$agent_sha^{tree}")
core_tree=$(git_safe "$core_mirror" rev-parse "$core_sha^{tree}")
core_bundle_snapshot="git-bundles/dbdog-agent-core-$core_sha.bundle"
core_bundle_sha256=$(sha256sum "$stage/$core_bundle_snapshot" | awk '{print $1}')
{
  printf '%s\n' $'role\tcommit\ttree\tevidence\tevidence_sha256'
  if ((create_agent_bundle == 1)); then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      dbdog-agent "$agent_sha" "$agent_tree" "$agent_bundle_rel" "$agent_bundle_sha256"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' \
      dbdog-agent "$agent_sha" "$agent_tree" \
      'exact-commit:git/dbdog-agent.git' -
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    integrations-core "$core_sha" "$core_tree" \
    "$core_bundle_snapshot" "$core_bundle_sha256"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    omnibus-ruby "$omnibus_ruby_sha" - \
    "snapshots/ruby-package-cache-$bundle_lock_sha256+v7-Gemfile.lock" -
  printf '%s\t%s\t%s\t%s\t%s\n' \
    chef-sugar "$chef_sugar_sha" - \
    "snapshots/ruby-package-cache-$bundle_lock_sha256+v7-Gemfile.lock" -
} >"$stage/GIT-INPUTS.tsv"

cat >"$stage/EXCLUDED-CACHES.tsv" <<EOF
path	classification	reason
bazel/disk	action-cache	Bazel action outputs; useful for speed but not source authority
go/build	compiler-cache	Go compiler action outputs
go/gopath	workspace-cache	GOPATH build/install state; GOMODCACHE is sealed separately
go/mod/cache/vcs	active-git-cache	mutable VCS acceleration; module download archives are sealed
go/mod/**/cache/download/**/@v/list	mutable-index	version listings are not needed for exact locked versions
xdg/root/bazel	bazel-output-base	per-user analysis, execution, and repository materialization state
xdg/user/bazel	bazel-output-base	per-user analysis, execution, and repository materialization state
omnibus/git	omnibus-build-cache	active tagged Git cache of derived component builds
bundle	installed-gems	derived from the versioned Bundler package cache
bundle-user-cache	bundler-index-cache	mutable compact-index and metadata cache
bundle-offline-proof	offline-proof	derived test installation, not an input
$build_dir/ruby-bundle-work-cache	attempt-local-ruby-cache	writable copy derived from the immutable package cache; never authoritative
$build_dir/bundle-work-cache	attempt-local-ruby-cache	writable Omnibus copy derived from the immutable package cache; never authoritative
pip-and-uv-opaque-entries	index-http-cache	not a directly reusable wheelhouse; only wheel/sdist archives are sealed
incomplete	partial-downloads	unfinished downloads must never enter an authoritative seal
$build_dir/omnibus	omnibus-work-tree	compiled build state and generated integration wheels
$build_dir/tmp	temporary-build-state	per-run temporary data
$build_dir/logs	logs	build evidence only, not dependency bytes
EOF

: >"$stage/CLOSURE-GAPS"
if ((create_agent_bundle == 0)); then
  printf '%s\n' \
    'dbdog-agent is pinned by exact commit/tree in the persistent bare mirror; set DBDOG_SEAL_CREATE_AGENT_BUNDLE=1 to spend disk on a portable full bundle.' \
    >>"$stage/CLOSURE-GAPS"
fi
if ((python_archive_count == 0)); then
  printf '%s\n' \
    'No directly reusable Python wheel/sdist archives were found under pip/ or uv/; generate an explicit hash-locked wheelhouse before claiming a network-free Python closure.' \
    >>"$stage/CLOSURE-GAPS"
else
  printf '%s\n' \
    'Python wheel/sdist archives were sealed, but opaque pip/uv HTTP cache entries were excluded; verify an explicit offline wheelhouse install before claiming full Python closure.' \
    >>"$stage/CLOSURE-GAPS"
fi
if ((reference_only_count > 0)); then
  printf 'There are %d manifest-only files (normally Bazel materialized repository inputs); the seal detects changes but those bytes still depend on cache_root.\n' \
    "$reference_only_count" >>"$stage/CLOSURE-GAPS"
fi
printf '%s\n' \
  'The DDA legacy archive passed an archive-to-temporary-hydration inventory proof for its fixed aarch64 path, but the DDA CLI under /home/dbdog/tools and any interpreter target outside the archived venv remain host-provisioned rather than portable sealed objects.' \
  'The recorded runuser shim plus the checkmodule, semodule_package, and libsepol RPM identities, paths, hashes, sizes, and modes are host-system references; this seal intentionally fails verification on a host with different system dependencies.' \
  'Go module download artifacts were inventoried, but no network-disabled replay of every configured module was captured; do not claim a complete portable Go closure from this seal alone.' \
  'The active Omnibus Git build cache is excluded. It accelerates rebuilds but is not a source dependency and its pack/index files are mutable.' \
  'A successful build plus cache inventories is not equivalent to a clean-host, network-disabled replay; portability remains explicitly partial until that replay is recorded.' \
  >>"$stage/CLOSURE-GAPS"

authoritative_file_count=$(($(wc -l <"$stage/AUTHORITATIVE-FILES.tsv") - 1))
unique_object_count=$(find "$stage/objects" -type f -print | wc -l)
symlink_count=$(($(wc -l <"$stage/CACHE-SYMLINKS.tsv") - 1))
if ((reference_only_count == 0 && create_agent_bundle == 1)); then
  portability=system-referenced
else
  portability=cache-root-and-system-referenced
fi
printf '%s\n' \
  'seal_format=omnibus-cache-v2' \
  "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "build_id=$build_id" \
  "build_dir=$build_dir" \
  "cache_root=$cache_root" \
  "manifest_rel=$manifest_rel" \
  "control_overlay_rel=$control_overlay_rel" \
  "control_overlay_runner_sha256=$control_overlay_runner_sha256" \
  "platform_patch_sha256=$platform_patch_sha256" \
  "control_info_sha256=$control_info_sha256" \
  "control_manifest_sha256=$control_manifest_sha256" \
  "patchelf_tool_rel=$patchelf_tool_rel" \
  "patchelf_rel=$patchelf_rel" \
  "patchelf_sha256=$patchelf_sha256" \
  "patchelf_info_sha256=$patchelf_info_sha256" \
  "patchelf_sums_sha256=$patchelf_sums_sha256" \
  "patchelf_version=$patchelf_version" \
  "patchelf_reported_stdout=$patchelf_reported_stdout" \
  "host_distribution=$host_distribution" \
  "dbdog_agent_commit=$agent_sha" \
  "integrations_core_commit=$core_sha" \
  "omnibus_ruby_commit=$omnibus_ruby_sha" \
  "chef_sugar_commit=$chef_sugar_sha" \
  "bundler_lock_sha256=$bundle_lock_sha256" \
  "dda_legacy_archive=$dda_archive_rel" \
  "dda_legacy_archive_sha256=$dda_archive_expected_sha256" \
  "dda_legacy_inventory_file_count=$dda_inventory_file_count" \
  "dda_legacy_symlink_count=$dda_symlink_count" \
  "dda_legacy_package_count=$dda_package_count" \
  'dda_legacy_archive_roundtrip=passed' \
  "authoritative_file_count=$authoritative_file_count" \
  "unique_sealed_object_count=$unique_object_count" \
  "new_hardlink_object_count=$hardlink_count" \
  "reference_only_file_count=$reference_only_count" \
  "cache_symlink_count=$symlink_count" \
  "python_archive_count=$python_archive_count" \
  "system_reference_count=$system_reference_count" \
  "selinux_system_reference_count=$selinux_system_reference_count" \
  "portability=$portability" \
  'closure_status=partial-no-clean-host-offline-replay' \
  "runuser_link=$runuser_link" \
  "runuser_target=$runuser_system_path" \
  "runuser_rpm_package=$runuser_package" \
  "runuser_sha256=$runuser_file_sha256" \
  "agent_bundle_created=$create_agent_bundle" \
  >"$stage/SEAL-INFO"

cat >"$stage/VERIFY.sh" <<'VERIFY_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/bin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset \
  BASH_ENV ENV CDPATH \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_WORK_TREE \
  GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM \
  GIT_CONFIG_SYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
  GIT_OPTIONAL_LOCKS

seal_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cache_root=${DBDOG_AGENT_CACHE_ROOT:-/home/dbdog/cache/dbdog-agent}
agent_sha=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
core_sha=7a4247599b029f1aca10d2cb63491d535fbd502f
manifest_rel=manifests/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7
omnibus_ruby_sha=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
agent_mirror="$cache_root/git/dbdog-agent.git"
core_mirror="$cache_root/git/dbdog-agent-core.git"
core_bundle="$seal_dir/git-bundles/dbdog-agent-core-$core_sha.bundle"
control_overlay_rel=control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v10
control_overlay_runner_sha256=abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812
platform_patch_sha256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
control_info_sha256=6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a
control_manifest_sha256=f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac
patchelf_tool_rel=tools/patchelf/0.18.0-aarch64-kylin10-v2
patchelf_rel="$patchelf_tool_rel/bin/patchelf"
patchelf_sha256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
patchelf_info_sha256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
patchelf_sums_sha256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
patchelf_version=0.18.0
patchelf_reported_stdout='patchelf 0.18.0'
host_distribution=rhel
snapshot_cache_root="$seal_dir/snapshots/cache-root"
omnibus_success="$seal_dir/handoffs/omnibus.success"
runuser_link=/home/dbdog/tools/bin/runuser
runuser_system_path=/usr/sbin/runuser
checkmodule_system_path=/usr/bin/checkmodule
checkmodule_package=checkpolicy-2.8-6.ky10.aarch64
checkmodule_sha256=b128531e2a54d0998e212eb81d142ce598627aa4fec95bddf97982755d83d6c7
checkmodule_bytes=462616
checkmodule_mode=755
semodule_package_system_path=/usr/bin/semodule_package
semodule_package_package=policycoreutils-2.8-14.2.p01.ky10.aarch64
semodule_package_sha256=9740fd6a91bf548d4a95394890b8494feabd1f2087e82a8866bf1038f61a102a
semodule_package_bytes=68320
semodule_package_mode=755
libsepol_system_path=/usr/lib64/libsepol.so.1
libsepol_package=libsepol-2.9-1.p01.ky10.aarch64
libsepol_sha256=ab0d1f6f003794273d2fd6b1dc5f16daead54eb55fd08b0f4ed9a367004031cb
libsepol_bytes=790336
libsepol_mode=755
system_reference_count=4
selinux_system_reference_count=3
rpm_bin=/usr/bin/rpm

fail() {
  echo "$*" >&2
  exit 1
}

verify_control_overlay_snapshot() {
  local overlay_parent overlay_dir actual_inventory expected_inventory overlay_file

  test -d "$snapshot_cache_root" || fail "sealed cache-root snapshot is missing"
  test ! -L "$snapshot_cache_root" || fail "sealed cache-root snapshot is a symlink"
  test "$(readlink -e -- "$snapshot_cache_root")" = "$snapshot_cache_root" ||
    fail "sealed cache-root snapshot resolves outside its canonical path"
  overlay_parent="$snapshot_cache_root/control-overlays"
  test -d "$overlay_parent" || fail "sealed control-overlays parent is missing"
  test ! -L "$overlay_parent" || fail "sealed control-overlays parent is a symlink"
  test "$(readlink -e -- "$overlay_parent")" = "$overlay_parent" ||
    fail "sealed control-overlays parent resolves outside its canonical path"
  overlay_dir="$snapshot_cache_root/$control_overlay_rel"
  test -d "$overlay_dir" || fail "sealed v10 control overlay is missing"
  test ! -L "$overlay_dir" || fail "sealed v10 control overlay is a symlink"
  test "$(readlink -e -- "$overlay_dir")" = "$overlay_dir" ||
    fail "sealed v10 control overlay resolves outside its canonical path"
  test "$(stat -c '%u:%g:%a' -- "$overlay_dir")" = 0:0:555 ||
    fail "sealed v10 control-overlay directory mode or owner changed"
  expected_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
  actual_inventory=$(find "$overlay_dir" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  test "$actual_inventory" = "$expected_inventory" ||
    fail "sealed v10 control-overlay inventory changed"
  for overlay_file in CONTROL-INFO CONTROL.sha256 agent-build-kylin-platform.patch; do
    test -f "$overlay_dir/$overlay_file"
    test ! -L "$overlay_dir/$overlay_file"
    test "$(stat -c '%u:%g:%a' -- "$overlay_dir/$overlay_file")" = 0:0:444 ||
      fail "sealed v10 control-file mode or owner changed: $overlay_file"
  done
  test -f "$overlay_dir/run-agent-omnibus.sh"
  test ! -L "$overlay_dir/run-agent-omnibus.sh"
  test "$(stat -c '%u:%g:%a' -- "$overlay_dir/run-agent-omnibus.sh")" = 0:0:555 ||
    fail "sealed v9 runner mode or owner changed"
  cmp -s -- "$overlay_dir/CONTROL.sha256" <(
    printf '%s  %s\n' \
      "$control_overlay_runner_sha256" \
      "$control_overlay_rel/run-agent-omnibus.sh" \
      "$platform_patch_sha256" \
      "$control_overlay_rel/agent-build-kylin-platform.patch" \
      "$control_info_sha256" \
      "$control_overlay_rel/CONTROL-INFO" \
      "$patchelf_sha256" \
      "$patchelf_rel"
  ) || fail "sealed v9 CONTROL.sha256 differs from the pinned four-line manifest"
  printf '%s  %s\n' "$control_manifest_sha256" "$overlay_dir/CONTROL.sha256" \
    | sha256sum -c - >/dev/null || fail "sealed v9 CONTROL.sha256 digest changed"
  (
    cd "$snapshot_cache_root"
    sha256sum -c "$control_overlay_rel/CONTROL.sha256"
  ) >/dev/null || fail "sealed v10 control-overlay checksum verification failed"
}

verify_patchelf_tool_tree() {
  local tree_root=$1 tool_dir expected_inventory actual_inventory entry entry_path
  local expected_stat actual_stat resolved_path version_output

  tool_dir="$tree_root/$patchelf_tool_rel"
  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'
  test -d "$tool_dir" || fail "missing pinned v9 patchelf tool root: $tool_dir"
  test ! -L "$tool_dir" || fail "pinned v9 patchelf tool root is a symlink: $tool_dir"
  actual_inventory=$(
    {
      printf '.\n'
      find "$tool_dir" -xdev -mindepth 1 -printf '%P\n'
    } | LC_ALL=C sort
  )
  test "$actual_inventory" = "$expected_inventory" ||
    fail "pinned v9 patchelf tool differs from the exact five-node inventory: $tool_dir"

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$tool_dir
    else
      entry_path="$tool_dir/$entry"
    fi
    test ! -L "$entry_path" || fail "pinned v9 patchelf entry is a symlink: $entry_path"
    resolved_path=$(readlink -e -- "$entry_path" || :)
    test "$resolved_path" = "$entry_path" ||
      fail "pinned v9 patchelf entry is not canonical: $entry_path"
    case "$entry" in
      . | bin)
        test -d "$entry_path" || fail "pinned v9 patchelf entry is not a directory: $entry_path"
        expected_stat=0:0:555
        ;;
      PATCHELF-INFO | SHA256SUMS)
        test -f "$entry_path" || fail "pinned v9 patchelf metadata is not regular: $entry_path"
        expected_stat=0:0:444
        ;;
      bin/patchelf)
        test -f "$entry_path" || fail "pinned v9 patchelf binary is not regular: $entry_path"
        expected_stat=0:0:555
        ;;
      *) fail "unexpected pinned v9 patchelf inventory entry: $entry" ;;
    esac
    actual_stat=$(stat -c '%u:%g:%a' -- "$entry_path")
    test "$actual_stat" = "$expected_stat" ||
      fail "pinned v9 patchelf owner/mode mismatch: $entry_path ($actual_stat)"
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$patchelf_sha256" "$tool_dir/bin/patchelf" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf binary checksum changed"
  printf '%s  %s\n' "$patchelf_info_sha256" "$tool_dir/PATCHELF-INFO" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf info checksum changed"
  printf '%s  %s\n' "$patchelf_sums_sha256" "$tool_dir/SHA256SUMS" \
    | sha256sum -c - >/dev/null || fail "pinned v9 patchelf checksum manifest changed"
  (cd "$tool_dir" && sha256sum -c SHA256SUMS >/dev/null) ||
    fail "pinned v9 patchelf internal checksum verification failed"
  version_output=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$tool_dir/bin/patchelf" --version
  )
  test "$version_output" = "$patchelf_reported_stdout" ||
    fail "pinned v9 patchelf reported an unexpected version: $version_output"
}

verify_omnibus_success_snapshot() {
  test -f "$omnibus_success" || fail "sealed Omnibus success handoff is missing"
  test ! -L "$omnibus_success" || fail "sealed Omnibus success handoff is a symlink"
  test "$(stat -c '%u:%g:%a' -- "$omnibus_success")" = 0:0:444 ||
    fail "sealed Omnibus success handoff must be root:root mode 0444"
  cmp -s -- "$omnibus_success" <(
    printf '%s\n' \
      "manifest_rel=$manifest_rel" \
      "agent_sha=$agent_sha" \
      "core_sha=$core_sha" \
      "omnibus_ruby_sha=$omnibus_ruby_sha" \
      "control_overlay_rel=$control_overlay_rel" \
      "control_overlay_runner_sha256=$control_overlay_runner_sha256" \
      "platform_patch_sha256=$platform_patch_sha256" \
      "patchelf_rel=$patchelf_rel" \
      "patchelf_sha256=$patchelf_sha256" \
      "host_distribution=$host_distribution"
  ) || fail "sealed Omnibus success handoff differs from the exact v9 marker"
}

(cd "$seal_dir" && sha256sum -c SEALED-OBJECTS.sha256)
(cd "$seal_dir" && sha256sum -c SEALED-METADATA.sha256)
(cd "$cache_root" && sha256sum -c "$seal_dir/CACHE-REFERENCES.sha256")
verify_patchelf_tool_tree "$cache_root"
verify_patchelf_tool_tree "$snapshot_cache_root"
test "$(stat -c '%d:%i' -- "$cache_root/$patchelf_rel")" != \
  "$(stat -c '%d:%i' -- "$snapshot_cache_root/$patchelf_rel")" ||
  fail "sealed patchelf snapshot unexpectedly hardlinks the live executable"
verify_control_overlay_snapshot
verify_omnibus_success_snapshot
cmp -s -- "$seal_dir/BUILD-CONTROLS.tsv" <(
  printf '%s\n' \
    $'role\tcache_path\tsha256\tversion\treplay_authority' \
    "omnibus-runner"$'\t'"$control_overlay_rel/run-agent-omnibus.sh"$'\t'"$control_overlay_runner_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/run-agent-omnibus.sh" \
    "kylin-platform-patch"$'\t'"$control_overlay_rel/agent-build-kylin-platform.patch"$'\t'"$platform_patch_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/agent-build-kylin-platform.patch" \
    "control-info"$'\t'"$control_overlay_rel/CONTROL-INFO"$'\t'"$control_info_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/CONTROL-INFO" \
    "control-manifest"$'\t'"$control_overlay_rel/CONTROL.sha256"$'\t'"$control_manifest_sha256"$'\t-\t'"snapshots/cache-root/$control_overlay_rel/CONTROL.sha256" \
    "patchelf-binary"$'\t'"$patchelf_rel"$'\t'"$patchelf_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_rel" \
    "patchelf-info"$'\t'"$patchelf_tool_rel/PATCHELF-INFO"$'\t'"$patchelf_info_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_tool_rel/PATCHELF-INFO" \
    "patchelf-manifest"$'\t'"$patchelf_tool_rel/SHA256SUMS"$'\t'"$patchelf_sums_sha256"$'\t'"$patchelf_version"$'\t'"snapshots/cache-root/$patchelf_tool_rel/SHA256SUMS"
) || fail "BUILD-CONTROLS.tsv differs from the pinned v10 replay authority"

grep -Fx 'seal_format=omnibus-cache-v2' "$seal_dir/SEAL-INFO" >/dev/null ||
  fail "SEAL-INFO does not identify the v2 seal format"
for expected_seal_info in \
  "patchelf_tool_rel=$patchelf_tool_rel" \
  "patchelf_rel=$patchelf_rel" \
  "patchelf_sha256=$patchelf_sha256" \
  "patchelf_info_sha256=$patchelf_info_sha256" \
  "patchelf_sums_sha256=$patchelf_sums_sha256" \
  "patchelf_version=$patchelf_version" \
  "patchelf_reported_stdout=$patchelf_reported_stdout" \
  "system_reference_count=$system_reference_count" \
  "selinux_system_reference_count=$selinux_system_reference_count"
do
  grep -Fx "$expected_seal_info" "$seal_dir/SEAL-INFO" >/dev/null ||
    fail "SEAL-INFO is missing pinned tool metadata: $expected_seal_info"
done

test -x "$rpm_bin"
system_tool_headers=0
system_tool_rows=0
runuser_rows=0
checkmodule_rows=0
semodule_package_rows=0
libsepol_rows=0
while IFS=$'\t' read -r role requested_path resolved_target rpm_package \
  expected_sha256 expected_bytes expected_mode storage
do
  if [[ $role == role ]]; then
    test "$requested_path" = requested_path
    test "$resolved_target" = resolved_target
    test "$rpm_package" = rpm_package
    test "$expected_sha256" = sha256
    test "$expected_bytes" = bytes
    test "$expected_mode" = mode
    test "$storage" = storage
    system_tool_headers=$((system_tool_headers + 1))
    continue
  fi

  case "$role" in
    runuser)
      test "$runuser_rows" -eq 0 || fail "duplicate runuser system-reference record"
      runuser_rows=1
      expected_requested_path=$runuser_link
      expected_resolved_target=$runuser_system_path
      pinned_rpm_package=$rpm_package
      pinned_sha256=$expected_sha256
      pinned_bytes=$expected_bytes
      pinned_mode=$expected_mode
      path_kind=shim
      require_executable=1
      ;;
    checkmodule)
      test "$checkmodule_rows" -eq 0 || fail "duplicate checkmodule system-reference record"
      checkmodule_rows=1
      expected_requested_path=$checkmodule_system_path
      expected_resolved_target=$checkmodule_system_path
      pinned_rpm_package=$checkmodule_package
      pinned_sha256=$checkmodule_sha256
      pinned_bytes=$checkmodule_bytes
      pinned_mode=$checkmodule_mode
      path_kind=real
      require_executable=1
      ;;
    semodule-package)
      test "$semodule_package_rows" -eq 0 ||
        fail "duplicate semodule-package system-reference record"
      semodule_package_rows=1
      expected_requested_path=$semodule_package_system_path
      expected_resolved_target=$semodule_package_system_path
      pinned_rpm_package=$semodule_package_package
      pinned_sha256=$semodule_package_sha256
      pinned_bytes=$semodule_package_bytes
      pinned_mode=$semodule_package_mode
      path_kind=real
      require_executable=1
      ;;
    libsepol-soname)
      test "$libsepol_rows" -eq 0 || fail "duplicate libsepol system-reference record"
      libsepol_rows=1
      expected_requested_path=$libsepol_system_path
      expected_resolved_target=$libsepol_system_path
      pinned_rpm_package=$libsepol_package
      pinned_sha256=$libsepol_sha256
      pinned_bytes=$libsepol_bytes
      pinned_mode=$libsepol_mode
      path_kind=real
      require_executable=0
      ;;
    *) fail "unexpected system-reference role: $role" ;;
  esac

  test "$requested_path" = "$expected_requested_path"
  test "$resolved_target" = "$expected_resolved_target"
  test "$rpm_package" = "$pinned_rpm_package"
  test "$expected_sha256" = "$pinned_sha256"
  test "$expected_bytes" = "$pinned_bytes"
  test "$expected_mode" = "$pinned_mode"
  test "$storage" = system-reference
  test "$expected_sha256" != ''
  test "$expected_bytes" -gt 0
  case "$path_kind" in
    shim)
      test -L "$requested_path"
      test "$(readlink -- "$requested_path")" = "$resolved_target"
      test "$(readlink -f -- "$requested_path")" = "$resolved_target"
      ;;
    real)
      test -f "$requested_path"
      test ! -L "$requested_path"
      test "$(readlink -e -- "$requested_path")" = "$requested_path"
      ;;
    *) fail "unexpected system-reference path kind: $path_kind" ;;
  esac
  test -f "$resolved_target"
  test ! -L "$resolved_target"
  test "$(readlink -e -- "$resolved_target")" = "$resolved_target"
  test "$(stat -c '%u:%g' -- "$resolved_target")" = 0:0
  if [[ $require_executable == 1 ]]; then
    test -x "$resolved_target"
  else
    test -r "$resolved_target"
  fi
  actual_rpm_package=$(
    "$rpm_bin" -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
      "$resolved_target"
  )
  test "$actual_rpm_package" = "$rpm_package"
  test "$(sha256sum "$resolved_target" | awk '{print $1}')" = \
    "$expected_sha256"
  test "$(stat -c '%s' "$resolved_target")" = "$expected_bytes"
  test "$(stat -c '%a' "$resolved_target")" = "$expected_mode"
  system_tool_rows=$((system_tool_rows + 1))
done <"$seal_dir/SYSTEM-TOOLS.tsv"
test "$system_tool_headers" -eq 1 || fail "expected exactly one system-tool header"
test "$system_tool_rows" -eq "$system_reference_count" ||
  fail "expected exactly $system_reference_count system-reference records"
test "$runuser_rows" -eq 1 || fail "missing runuser system-reference record"
test "$checkmodule_rows" -eq 1 || fail "missing checkmodule system-reference record"
test "$semodule_package_rows" -eq 1 ||
  fail "missing semodule-package system-reference record"
test "$libsepol_rows" -eq 1 || fail "missing libsepol system-reference record"
test "$((checkmodule_rows + semodule_package_rows + libsepol_rows))" -eq \
  "$selinux_system_reference_count" ||
  fail "SELinux system-reference count does not match SEAL-INFO"

while IFS=$'\t' read -r expected_mode relative; do
  [[ $expected_mode == restore_mode ]] && continue
  test -f "$cache_root/$relative"
  test "$(stat -c '%a' "$cache_root/$relative")" = "$expected_mode"
done <"$seal_dir/REFERENCE-MODES.tsv"

while IFS=$'\t' read -r category relative expected_target; do
  [[ $category == category ]] && continue
  test -L "$cache_root/$relative"
  test "$(readlink -- "$cache_root/$relative")" = "$expected_target"
done <"$seal_dir/CACHE-SYMLINKS.tsv"

test "$(git -C "$agent_mirror" rev-parse --is-bare-repository)" = true
git -C "$agent_mirror" cat-file -e "$agent_sha^{commit}"
test "$(git -C "$core_mirror" rev-parse --is-bare-repository)" = true
git -C "$core_mirror" cat-file -e "$core_sha^{commit}"
git -C "$core_mirror" bundle verify "$core_bundle" >/dev/null
git -C "$core_mirror" bundle list-heads "$core_bundle" \
  | grep -Fx "$core_sha refs/dbdog-build-inputs/$core_sha" >/dev/null

printf 'Dependency seal verified: %s\n' "$seal_dir"
VERIFY_SCRIPT

# Work files are intentionally absent from the published seal.
rm -f -- \
  "$candidate_list" \
  "$candidate_sorted" \
  "$symlink_list" \
  "$category_summary_tmp"

(
  cd "$stage"
  find objects -type f -print0 \
    | LC_ALL=C sort -z \
    | while IFS= read -r -d '' object_file; do
        sha256sum "$object_file"
      done \
    >SEALED-OBJECTS.sha256
  find . -type f \
    ! -path './objects/*' \
    ! -path './SEALED-METADATA.sha256' \
    -print0 \
    | LC_ALL=C sort -z \
    | while IFS= read -r -d '' metadata_file; do
        sha256sum "$metadata_file"
      done \
    >SEALED-METADATA.sha256
  sha256sum -c SEALED-OBJECTS.sha256
  sha256sum -c SEALED-METADATA.sha256
)
(cd "$cache_root" && sha256sum -c "$stage/CACHE-REFERENCES.sha256")

while IFS=$'\t' read -r expected_mode relative; do
  [[ $expected_mode == restore_mode ]] && continue
  test "$(stat -c '%a' "$cache_root/$relative")" = "$expected_mode"
done <"$stage/REFERENCE-MODES.tsv"
while IFS=$'\t' read -r category relative expected_target; do
  [[ $category == category ]] && continue
  test -L "$cache_root/$relative"
  test "$(readlink -- "$cache_root/$relative")" = "$expected_target"
done <"$stage/CACHE-SYMLINKS.tsv"

git_safe "$core_mirror" bundle verify \
  "$stage/git-bundles/dbdog-agent-core-$core_sha.bundle" >/dev/null
git_safe "$core_mirror" bundle list-heads \
  "$stage/git-bundles/dbdog-agent-core-$core_sha.bundle" \
  | grep -Fx "$core_sha refs/dbdog-build-inputs/$core_sha" >/dev/null

# Every published inode is root-owned and immutable to the build user. Files
# are data-only except for the replay-authority runner and patchelf binary,
# whose original 0555 modes are part of the v10 control contract. VERIFY.sh is
# invoked with bash.
chown -R root:root "$stage"
find "$stage" -type f -exec chmod 0444 {} +
find "$stage" -type d -exec chmod g-s {} +
find "$stage" -type d -exec chmod 0555 {} +
test -z "$(find "$stage" -type d ! -perm 0555 -print -quit)" ||
  fail "published dependency-seal directories must all be exact mode 0555"
chmod 0555 "$stage/snapshots/cache-root/$control_overlay_rel/run-agent-omnibus.sh"
chmod 0555 "$stage/snapshots/cache-root/$patchelf_rel"

"$runuser_system_path" -u dbdog -- /usr/bin/env -i \
  HOME=/home/dbdog \
  PATH=/usr/bin:/bin \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  DBDOG_AGENT_CACHE_ROOT="$cache_root" \
  /usr/bin/bash "$stage/VERIFY.sh"

if [[ -e $seal_dir ]]; then
  fail "dependency seal appeared during publication and will not be overwritten: $seal_dir"
fi
test -x /usr/bin/python3 || fail "missing executable system Python for atomic seal publication"
test "$(stat -c '%d' -- "$stage")" = "$(stat -c '%d' -- "$seal_parent")" ||
  fail "seal staging and publication directories are on different filesystems"
sync -f -- "$stage"
atomic_rename_noreplace "$stage" "$seal_dir" ||
  fail "atomic no-clobber publication refused dependency seal: $seal_dir"
test ! -e "$stage" || fail "seal staging directory remained after atomic publication"
test -d "$seal_dir" || fail "published dependency seal is not a directory: $seal_dir"
test ! -L "$seal_dir" || fail "published dependency seal is a symlink: $seal_dir"
test "$(readlink -e -- "$seal_dir")" = "$seal_dir" ||
  fail "published dependency seal is not canonical: $seal_dir"
test "$(stat -c '%u:%g:%a' -- "$seal_dir")" = 0:0:555 ||
  fail "published dependency seal must be root:root mode 0555"
sync -f -- "$seal_dir"
sync -f -- "$seal_parent"
trap - EXIT

printf 'Dependency seal published: %s\n' "$seal_dir"
printf 'Verify as dbdog with: bash %s/VERIFY.sh\n' "$seal_dir"
