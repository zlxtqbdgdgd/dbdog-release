#!/usr/bin/env bash
set -euo pipefail
umask 0002

# Establish a deterministic command/config environment before validating any
# mutable build-tree input. The outer launcher also uses env -i so BASH_ENV
# cannot affect this shell before the script starts.
export PATH=/usr/local/bin:/usr/bin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset \
  BASH_ENV ENV CDPATH \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_WORK_TREE
while IFS= read -r git_config_var; do
  unset "$git_config_var"
done < <(compgen -A variable GIT_CONFIG_)
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=dbdog-agent-build
export GIT_AUTHOR_EMAIL=dbdog-agent-build@localhost
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

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
src_dir="$build_dir/src"
install_dir=/opt/dbdog-agent
assets_dir="$build_dir/exact-system-probe-assets"
persistent_cache=/home/dbdog/cache/dbdog-agent
manifest_rel=manifests/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7
control_overlay_rel=control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v9
control_overlay_dir="$persistent_cache/$control_overlay_rel"
base_runner="$persistent_cache/$manifest_rel/controls/run-agent-omnibus.sh"
platform_patch="$control_overlay_dir/agent-build-kylin-platform.patch"
platform_patch_expected_sha256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
patchelf_tool_rel=tools/patchelf/0.18.0-aarch64-kylin10-v2
patchelf_rel="$patchelf_tool_rel/bin/patchelf"
patchelf_tool_dir="$persistent_cache/$patchelf_tool_rel"
patchelf_bin_dir="$patchelf_tool_dir/bin"
patchelf_binary="$persistent_cache/$patchelf_rel"
patchelf_sha256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
patchelf_info_sha256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
patchelf_sums_sha256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
patchelf_reported_version='patchelf 0.18.0'
rpm_binary=/usr/bin/rpm
file_binary=/usr/bin/file
env_binary=/usr/bin/env
checkmodule_binary=/usr/bin/checkmodule
checkmodule_package=checkpolicy-2.8-6.ky10.aarch64
checkmodule_sha256=b128531e2a54d0998e212eb81d142ce598627aa4fec95bddf97982755d83d6c7
checkmodule_bytes=462616
checkmodule_rpm_dump_record='/usr/bin/checkmodule 462616 1584114100 b128531e2a54d0998e212eb81d142ce598627aa4fec95bddf97982755d83d6c7 0100755 root root 0 0 0 X'
checkmodule_versions='Module versions 4-19'
semodule_package_binary=/usr/bin/semodule_package
semodule_package_package=policycoreutils-2.8-14.2.p01.ky10.aarch64
semodule_package_sha256=9740fd6a91bf548d4a95394890b8494feabd1f2087e82a8866bf1038f61a102a
semodule_package_bytes=68320
semodule_package_rpm_dump_record='/usr/bin/semodule_package 68320 1597159740 9740fd6a91bf548d4a95394890b8494feabd1f2087e82a8866bf1038f61a102a 0100755 root root 0 0 0 X'
libsepol_binary=/usr/lib64/libsepol.so.1
libsepol_package=libsepol-2.9-1.p01.ky10.aarch64
libsepol_sha256=ab0d1f6f003794273d2fd6b1dc5f16daead54eb55fd08b0f4ed9a367004031cb
libsepol_bytes=790336
libsepol_rpm_dump_record='/usr/lib64/libsepol.so.1 790336 1636364104 ab0d1f6f003794273d2fd6b1dc5f16daead54eb55fd08b0f4ed9a367004031cb 0100755 root root 0 0 0 X'
selinux_policy_te="$src_dir/cmd/agent/selinux/system_probe_policy.te"
selinux_policy_te_sha256=76eb12936aa75093cb8b9d13b9117eb2be3bd359eb19a12b17f79afac09b20d7
selinux_policy_pp="$install_dir/etc/datadog-agent/selinux/system_probe_policy.pp"
patched_selinux_sha256=d6720df78c68ac25e8ec854a48b47cf2cfdc79c09cbecfbbeb3d711d73e2efae
local_sources_dir="$persistent_cache/sources"
stage_config_dir="$build_dir/stage-config"
omnibus_base_dir="$build_dir/omnibus"
go_tmp_dir="$build_dir/tmp/go"
adp_tar="$local_sources_dir/agent-data-plane-1.2.2-linux-arm64.tar.gz"
adp_sha256=f071bd14e06308754848140f7b5beac27b02e11105e0970b293417ab69037ca6
adp_cache="$persistent_cache/omnibus/sources/datadog-agent-data-plane-agent-data-plane-1.2.2-linux-arm64.tar.gz"
success_file="$build_dir/omnibus.success"
system_probe_success_file="$build_dir/system-probe.success"
pipeline_lock_dir="$persistent_cache/locks"
pipeline_lock="$pipeline_lock_dir/dbdog-agent-4c39489b-aarch64-kylin10.pipeline.lock"
agent_sha=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
core_sha=7a4247599b029f1aca10d2cb63491d535fbd502f
omnibus_ruby_sha=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
bundle_lock_sha256=aac25290049ce954c2296f9e1c1694205eaa886c46c27f7d9a5b085ba9582d99
bundle_cache="$persistent_cache/bundle-package-cache/$bundle_lock_sha256"
bundle_work_cache="$build_dir/bundle-work-cache/$bundle_lock_sha256"
core_mirror="$persistent_cache/git/dbdog-agent-core.git"

verify_patchelf_tool_authority() {
  local expected_inventory actual_inventory entry entry_path
  local expected_stat actual_stat resolved_path

  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'
  if [[ ! -d $patchelf_tool_dir || -L $patchelf_tool_dir ]]; then
    echo "pinned v9 patchelf tool root must be a real directory: $patchelf_tool_dir" >&2
    exit 1
  fi
  actual_inventory=$(
    {
      printf '.\n'
      find "$patchelf_tool_dir" -xdev -mindepth 1 -printf '%P\n'
    } | LC_ALL=C sort
  )
  if [[ $actual_inventory != "$expected_inventory" ]]; then
    echo "pinned v9 patchelf tool inventory does not match its five-node contract" >&2
    printf '%s\n' "$actual_inventory" >&2
    exit 1
  fi

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$patchelf_tool_dir
    else
      entry_path="$patchelf_tool_dir/$entry"
    fi
    if [[ -L $entry_path ]]; then
      echo "pinned v9 patchelf tool entry must not be a symlink: $entry_path" >&2
      exit 1
    fi
    resolved_path=$(readlink -e -- "$entry_path" || :)
    if [[ $resolved_path != "$entry_path" ]]; then
      echo "pinned v9 patchelf tool entry is not canonical: $entry_path" >&2
      exit 1
    fi
    case $entry in
      . | bin)
        if [[ ! -d $entry_path ]]; then
          echo "pinned v9 patchelf tool entry must be a directory: $entry_path" >&2
          exit 1
        fi
        expected_stat=root:root:555
        ;;
      PATCHELF-INFO | SHA256SUMS)
        if [[ ! -f $entry_path ]]; then
          echo "pinned v9 patchelf metadata entry must be a regular file: $entry_path" >&2
          exit 1
        fi
        expected_stat=root:root:444
        ;;
      bin/patchelf)
        if [[ ! -f $entry_path ]]; then
          echo "pinned v9 patchelf binary must be a regular file: $entry_path" >&2
          exit 1
        fi
        expected_stat=root:root:555
        ;;
      *)
        echo "unexpected pinned v9 patchelf inventory entry: $entry" >&2
        exit 1
        ;;
    esac
    actual_stat=$(stat -c '%U:%G:%a' -- "$entry_path")
    if [[ $actual_stat != "$expected_stat" ]]; then
      echo "pinned v9 patchelf tool owner/mode mismatch: $entry_path ($actual_stat)" >&2
      exit 1
    fi
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$patchelf_sha256" "$patchelf_binary" | sha256sum -c -
  printf '%s  %s\n' "$patchelf_info_sha256" "$patchelf_tool_dir/PATCHELF-INFO" | sha256sum -c -
  printf '%s  %s\n' "$patchelf_sums_sha256" "$patchelf_tool_dir/SHA256SUMS" | sha256sum -c -
  (cd "$patchelf_tool_dir" && sha256sum -c SHA256SUMS)
}

verify_patchelf_path_selection() {
  local selected_patchelf

  if [[ ${PATH%%:*} != "$patchelf_bin_dir" ]]; then
    echo "pinned v9 patchelf bin directory is not first in PATH" >&2
    exit 1
  fi
  selected_patchelf=$(command -v patchelf || :)
  if [[ $selected_patchelf != "$patchelf_binary" ]]; then
    echo "command -v patchelf did not select the pinned v9 binary: $selected_patchelf" >&2
    exit 1
  fi
}

verify_patchelf_runtime() (
  local version_output smoke_dir smoke_elf smoke_rpath actual_rpath

  version_output=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$patchelf_binary" --version
  )
  if [[ $version_output != "$patchelf_reported_version" ]]; then
    echo "pinned v9 patchelf reported an unexpected version: $version_output" >&2
    exit 1
  fi

  smoke_dir=$(mktemp -d "$TMPDIR/.dbdog-patchelf-smoke.XXXXXX")
  case $smoke_dir in
    "$TMPDIR"/.dbdog-patchelf-smoke.*) ;;
    *)
      echo "unsafe pinned v9 patchelf smoke directory: $smoke_dir" >&2
      exit 1
      ;;
  esac
  smoke_elf="$smoke_dir/true"
  trap 'rm -f -- "$smoke_elf"; rmdir -- "$smoke_dir"' EXIT
  cp -- /usr/bin/true "$smoke_elf"
  chmod 0755 "$smoke_elf"
  smoke_rpath="\$ORIGIN/.dbdog-patchelf-smoke"
  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    "$patchelf_binary" --set-rpath "$smoke_rpath" "$smoke_elf"
  actual_rpath=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$patchelf_binary" --print-rpath "$smoke_elf"
  )
  if [[ $actual_rpath != "$smoke_rpath" ]]; then
    echo "pinned v9 patchelf RPATH smoke test failed: $actual_rpath" >&2
    exit 1
  fi
  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$smoke_elf"
  rm -f -- "$smoke_elf"
  rmdir -- "$smoke_dir"
  trap - EXIT
)

verify_rpm_target_dump_record() {
  local label=$1 path=$2 expected_package=$3 expected_dump_record=$4
  local dump_output matching_dump_record

  if ! dump_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$rpm_binary" -q --dump "$expected_package" 2>&1
  ); then
    echo "RPM dump failed for pinned Kylin v9 $label package: $expected_package" >&2
    printf '%s\n' "$dump_output" >&2
    exit 1
  fi
  if ! matching_dump_record=$(
    printf '%s\n' "$dump_output" |
      awk -v expected_path="$path" '
        $1 == expected_path {
          count++
          record = $0
        }
        END {
          if (count != 1) {
            exit 1
          }
          print record
        }
      '
  ); then
    echo "RPM dump must contain exactly one record for pinned Kylin v9 $label: $path" >&2
    exit 1
  fi
  if [[ $matching_dump_record != "$expected_dump_record" ]]; then
    echo "RPM dump record mismatch for pinned Kylin v9 $label" >&2
    printf 'expected: %s\nactual:   %s\n' "$expected_dump_record" "$matching_dump_record" >&2
    exit 1
  fi
}

verify_pinned_selinux_system_file() {
  local label=$1 path=$2 expected_bytes=$3 expected_sha256=$4
  local expected_package=$5 expected_dump_record=$6
  local resolved_path actual_stat expected_stat actual_package

  if [[ ! -f $path || -L $path ]]; then
    echo "pinned Kylin v9 $label must be a real regular file: $path" >&2
    exit 1
  fi
  resolved_path=$(readlink -e -- "$path" || :)
  if [[ $resolved_path != "$path" ]]; then
    echo "pinned Kylin v9 $label is not canonical: $path -> $resolved_path" >&2
    exit 1
  fi
  expected_stat="0:0:755:$expected_bytes"
  actual_stat=$(stat -c '%u:%g:%a:%s' -- "$path")
  if [[ $actual_stat != "$expected_stat" ]]; then
    echo "pinned Kylin v9 $label owner/mode/size mismatch: $actual_stat" >&2
    exit 1
  fi
  printf '%s  %s\n' "$expected_sha256" "$path" | sha256sum -c -
  actual_package=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$rpm_binary" -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$path"
  )
  if [[ $actual_package != "$expected_package" ]]; then
    echo "pinned Kylin v9 $label RPM mismatch: $actual_package" >&2
    exit 1
  fi

  # Validate only the selected target. Package-wide rpm -V is intentionally
  # not used because an unprivileged build user cannot read unrelated root-only
  # files. The live file remains independently pinned by canonical path,
  # ownership, mode, size, and SHA-256 above.
  verify_rpm_target_dump_record \
    "$label" "$path" "$expected_package" "$expected_dump_record"
}

verify_selinux_tool_identity() {
  local version_output help_output help_status required_option

  if [[ ! -x $rpm_binary || -L $rpm_binary ]]; then
    echo "Kylin v9 requires the real RPM query tool: $rpm_binary" >&2
    exit 1
  fi
  if [[ ! -x $file_binary || -L $file_binary ]]; then
    echo "Kylin v9 requires the real file inspection tool: $file_binary" >&2
    exit 1
  fi

  verify_pinned_selinux_system_file \
    checkmodule "$checkmodule_binary" "$checkmodule_bytes" \
    "$checkmodule_sha256" "$checkmodule_package" \
    "$checkmodule_rpm_dump_record"
  verify_pinned_selinux_system_file \
    semodule_package "$semodule_package_binary" "$semodule_package_bytes" \
    "$semodule_package_sha256" "$semodule_package_package" \
    "$semodule_package_rpm_dump_record"
  verify_pinned_selinux_system_file \
    libsepol.so.1 "$libsepol_binary" "$libsepol_bytes" \
    "$libsepol_sha256" "$libsepol_package" \
    "$libsepol_rpm_dump_record"

  if ! version_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$checkmodule_binary" -V 2>&1
  ); then
    echo "pinned Kylin v9 checkmodule -V probe failed" >&2
    printf '%s\n' "$version_output" >&2
    exit 1
  fi
  if [[ $version_output != "$checkmodule_versions" ]]; then
    echo "pinned Kylin v9 checkmodule module-version range changed: $version_output" >&2
    exit 1
  fi

  help_status=0
  help_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$checkmodule_binary" -h 2>&1
  ) || help_status=$?
  case $help_status in
    0 | 1) ;;
    *)
      echo "pinned Kylin v9 checkmodule help probe failed with status $help_status" >&2
      printf '%s\n' "$help_output" >&2
      exit 1
      ;;
  esac
  for required_option in -h -V -b -C -U -m -M -o; do
    if ! printf '%s\n' "$help_output" | grep -F -- "$required_option" >/dev/null; then
      echo "pinned Kylin v9 checkmodule help omitted $required_option" >&2
      exit 1
    fi
  done
  if printf '%s\n' "$help_output" |
    grep -Eq -- '(^|[^[:alnum:]_])-c([^[:alnum:]_]|$)'; then
    echo "pinned Kylin v9 checkmodule unexpectedly advertises -c" >&2
    exit 1
  fi
}

verify_selinux_tool_path_selection() {
  local selected_checkmodule selected_semodule_package

  selected_checkmodule=$(command -v checkmodule || :)
  if [[ $selected_checkmodule != "$checkmodule_binary" ]]; then
    echo "PATH did not select pinned Kylin v9 checkmodule: $selected_checkmodule" >&2
    exit 1
  fi
  selected_semodule_package=$(command -v semodule_package || :)
  if [[ $selected_semodule_package != "$semodule_package_binary" ]]; then
    echo "PATH did not select pinned Kylin v9 semodule_package: $selected_semodule_package" >&2
    exit 1
  fi
}

verify_selinux_policy_toolchain_smoke() (
  local smoke_dir smoke_mod smoke_pp cleanup_command
  local compile_output package_output file_output

  if [[ ! -f $selinux_policy_te || -L $selinux_policy_te ]]; then
    echo "pinned system-probe SELinux source must be a real file: $selinux_policy_te" >&2
    exit 1
  fi
  if [[ $(readlink -e -- "$selinux_policy_te" || :) != "$selinux_policy_te" ]]; then
    echo "pinned system-probe SELinux source is not canonical: $selinux_policy_te" >&2
    exit 1
  fi
  printf '%s  %s\n' "$selinux_policy_te_sha256" "$selinux_policy_te" | sha256sum -c -

  smoke_dir=$(mktemp -d "$TMPDIR/.dbdog-selinux-smoke.XXXXXX")
  case $smoke_dir in
    "$TMPDIR"/.dbdog-selinux-smoke.*) ;;
    *)
      echo "unsafe Kylin v9 SELinux smoke directory: $smoke_dir" >&2
      exit 1
      ;;
  esac
  smoke_mod="$smoke_dir/system_probe_policy.mod"
  smoke_pp="$smoke_dir/system_probe_policy.pp"
  printf -v cleanup_command 'rm -f -- %q %q; rmdir -- %q' \
    "$smoke_mod" "$smoke_pp" "$smoke_dir"
  # Expand the three already-validated paths now so EXIT cleanup does not
  # depend on function-local variables after an error unwinds the function.
  # shellcheck disable=SC2064
  trap "$cleanup_command" EXIT

  if ! compile_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C TMPDIR="$TMPDIR" \
      "$checkmodule_binary" -M -m -o "$smoke_mod" "$selinux_policy_te" 2>&1
  ); then
    echo "pinned Kylin v9 checkmodule policy smoke failed" >&2
    printf '%s\n' "$compile_output" >&2
    exit 1
  fi
  printf '%s\n' "$compile_output"
  if ! printf '%s\n' "$compile_output" |
    grep -F -- 'writing binary representation (version 19)' >/dev/null; then
    echo "pinned Kylin v9 checkmodule did not prove modular policy version 19" >&2
    exit 1
  fi
  if [[ ! -s $smoke_mod || -L $smoke_mod ]]; then
    echo "pinned Kylin v9 checkmodule produced no real nonempty module" >&2
    exit 1
  fi

  if ! package_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C TMPDIR="$TMPDIR" \
      "$semodule_package_binary" -o "$smoke_pp" -m "$smoke_mod" 2>&1
  ); then
    echo "pinned Kylin v9 semodule_package smoke failed" >&2
    printf '%s\n' "$package_output" >&2
    exit 1
  fi
  if [[ -n $package_output ]]; then
    printf '%s\n' "$package_output"
  fi
  if [[ ! -s $smoke_pp || -L $smoke_pp ]]; then
    echo "pinned Kylin v9 semodule_package produced no real nonempty package" >&2
    exit 1
  fi
  if ! file_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$file_binary" -b -- "$smoke_pp" 2>&1
  ); then
    echo "pinned Kylin v9 file probe could not inspect the smoke policy package" >&2
    printf '%s\n' "$file_output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$file_output" | grep -F -- 'mod version 19' >/dev/null; then
    echo "pinned Kylin v9 smoke package is not modular policy version 19: $file_output" >&2
    exit 1
  fi
  printf 'Kylin v9 SELinux smoke package: %s\n' "$file_output"

  rm -f -- "$smoke_mod" "$smoke_pp"
  rmdir -- "$smoke_dir"
  trap - EXIT
)

verify_built_selinux_policy() {
  local resolved_policy file_output

  if [[ ! -s $selinux_policy_pp || -L $selinux_policy_pp ]]; then
    echo "Omnibus did not produce a real nonempty SELinux policy package: $selinux_policy_pp" >&2
    exit 1
  fi
  resolved_policy=$(readlink -e -- "$selinux_policy_pp" || :)
  if [[ $resolved_policy != "$selinux_policy_pp" ]]; then
    echo "Omnibus SELinux policy package is not canonical: $resolved_policy" >&2
    exit 1
  fi
  if ! file_output=$(
    "$env_binary" -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$file_binary" -b -- "$selinux_policy_pp" 2>&1
  ); then
    echo "unable to inspect Omnibus SELinux policy package" >&2
    printf '%s\n' "$file_output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$file_output" | grep -F -- 'mod version 19' >/dev/null; then
    echo "Omnibus SELinux policy package is not modular policy version 19: $file_output" >&2
    exit 1
  fi
  printf 'Omnibus SELinux policy package: %s\n' "$file_output"
}


dbdog_uid=$(id -u dbdog)
if ((EUID != dbdog_uid)); then
  echo "run Omnibus stage as the dbdog user, not as root" >&2
  exit 1
fi
mkdir -p "$pipeline_lock_dir"
if ((pipeline_lock_held == 0)); then
  exec /usr/bin/flock -n -E 75 -o "$pipeline_lock" \
    /usr/bin/bash "$0" --dbdog-agent-pipeline-lock-held "$@"
fi

rm -f -- "$success_file"

# Do not let a caller silently switch this staging build into package/repackage,
# CI/S3 cache, signing, or an alternate compiler mode.
unset \
  AGENT_FLAVOR \
  AGENT_DATA_PLANE_HASH_DARWIN_AMD64 \
  AGENT_DATA_PLANE_HASH_DARWIN_ARM64 \
  AGENT_DATA_PLANE_HASH_FIPS_LINUX_AMD64 \
  AGENT_DATA_PLANE_HASH_FIPS_LINUX_ARM64 \
  AGENT_DATA_PLANE_HASH_LINUX_AMD64 \
  AGENT_DATA_PLANE_HASH_LINUX_ARM64 \
  AGENT_DATA_PLANE_VERSION \
  BUNDLE_DEPLOYMENT BUNDLE_FROZEN BUNDLE_GEMFILE BUNDLE_PATH \
  CC CXX DD_CC DD_CXX \
  CI CI_JOB_ID CI_JOB_NAME_SLUG CI_PIPELINE_ID \
  DDA_NO_DYNAMIC_DEPS DEPLOY_AGENT E2E_COVERAGE_PIPELINE \
  FORCED_PACKAGE_COMPRESSION_LEVEL \
  GEM_HOME GEM_PATH \
  INTEGRATION_WHEELS_CACHE_BUCKET INTEGRATION_WHEELS_SKIP_CACHE_UPLOAD \
  INTEGRATIONS_CORE_VERSION INTEGRATIONS_WHEELS_STORAGE \
  JMXFETCH_HASH JMXFETCH_VERSION \
  LD_PRELOAD \
  OMNIBUS_FORCE_PACKAGES OMNIBUS_PACKAGE_ARTIFACT_DIR \
  PACKAGE_ARCH PKG_CONFIG_LIBDIR PKG_CONFIG_PATH \
  PYTHONHOME PYTHONPATH RUBYOPT \
  SECURITY_AGENT_POLICIES_SHA256 SECURITY_AGENT_POLICIES_VERSION \
  S3_OMNIBUS_CACHE_ANONYMOUS_ACCESS S3_OMNIBUS_CACHE_BUCKET

if [[ ${OMNIBUS_RUBY_VERSION:-$omnibus_ruby_sha} != "$omnibus_ruby_sha" ]]; then
  echo "OMNIBUS_RUBY_VERSION does not match the v9 build input" >&2
  exit 1
fi
export OMNIBUS_RUBY_VERSION="$omnibus_ruby_sha"

host_glibc=$(LC_ALL=C getconf GNU_LIBC_VERSION) || {
  echo "unable to determine the native GNU libc version with getconf" >&2
  exit 1
}
if [[ $host_glibc != 'glibc 2.28' ]]; then
  echo "Kylin v9 requires native glibc 2.28, found: $host_glibc" >&2
  exit 1
fi
test -f "$system_probe_success_file"
test -f "$assets_dir/SHA256SUMS"
test -f "$assets_dir/SYSTEM-PROBE-OUTPUTS.sha256"
test -f "$adp_tar"
(cd "$persistent_cache" && sha256sum -c "$manifest_rel/INPUTS.sha256")
(cd "$persistent_cache" && sha256sum -c "$manifest_rel/RUBY-BUNDLE-CACHE.sha256")
git -C "$core_mirror" rev-parse --is-bare-repository | grep -qx true
git -C "$core_mirror" cat-file -e "$core_sha^{commit}"
test "$(readlink -f -- "$0")" = "$control_overlay_dir/run-agent-omnibus.sh"
test ! -L "$control_overlay_dir"
test "$(stat -c '%U:%G:%a' "$control_overlay_dir")" = root:root:555
expected_overlay_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
actual_overlay_inventory=$(find "$control_overlay_dir" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
if [[ "$actual_overlay_inventory" != "$expected_overlay_inventory" ]]; then
  echo "Omnibus control overlay inventory does not match the pinned v9 inventory" >&2
  printf '%s\n' "$actual_overlay_inventory" >&2
  exit 1
fi
for overlay_file in CONTROL-INFO CONTROL.sha256 agent-build-kylin-platform.patch; do
  overlay_path="$control_overlay_dir/$overlay_file"
  test -f "$overlay_path"
  test ! -L "$overlay_path"
  test "$(stat -c '%U:%G:%a' "$overlay_path")" = root:root:444
done
test -f "$control_overlay_dir/run-agent-omnibus.sh"
test ! -L "$control_overlay_dir/run-agent-omnibus.sh"
test "$(stat -c '%U:%G:%a' "$control_overlay_dir/run-agent-omnibus.sh")" = root:root:555
(cd "$persistent_cache" && sha256sum -c "$control_overlay_rel/CONTROL.sha256")
printf '%s  %s\n' \
  8dca261db73f4fbb299e26580c3254ecd2c25d31a88b79f849efd3736458541b \
  "$base_runner" | sha256sum -c -
control_overlay_runner_sha256=$(sha256sum "$0" | awk '{print $1}')
platform_patch_sha256=$(sha256sum "$platform_patch" | awk '{print $1}')
if [[ $platform_patch_sha256 != "$platform_patch_expected_sha256" ]]; then
  echo "Kylin v9 combined patch does not match its pinned SHA-256" >&2
  exit 1
fi
verify_patchelf_tool_authority
base_patch_names=(
  agent-build-staging-only.patch \
  agent-build-resource.patch \
  agent-build-old-glibc.patch \
  agent-build-llvm-kylin.patch \
  agent-build-clang-runtime.patch \
  agent-build-omnibus-repro.patch
)
for patch_name in "${base_patch_names[@]}"; do
  cmp \
    "$build_dir/$patch_name" \
    "$persistent_cache/$manifest_rel/controls/$patch_name"
done

verify_patch_stack() (
  patch_index=$(mktemp "$TMPDIR/agent-patch-index.XXXXXX")
  rm -f -- "$patch_index"
  trap 'rm -f -- "$patch_index"' EXIT
  export GIT_INDEX_FILE="$patch_index"
  git read-tree HEAD
  for patch_name in "${base_patch_names[@]}"; do
    git apply --cached "$persistent_cache/$manifest_rel/controls/$patch_name"
  done
  git apply --cached "$platform_patch"
  git diff --quiet
)

ensure_platform_patch_applied() {
  if git apply --check "$platform_patch" >/dev/null 2>&1; then
    git apply "$platform_patch"
  elif git apply --reverse --check "$platform_patch" >/dev/null 2>&1; then
    :
  else
    echo "Kylin v9 platform/toolchain patch is neither cleanly applicable nor already applied" >&2
    exit 1
  fi
}

verify_system_probe_handoff() {
  (cd "$assets_dir" && sha256sum -c SHA256SUMS)
  sha256sum -c "$assets_dir/SYSTEM-PROBE-OUTPUTS.sha256"

  assets_manifest_sha256=$(sha256sum "$assets_dir/SHA256SUMS" | awk '{print $1}')
  outputs_manifest_sha256=$(sha256sum "$assets_dir/SYSTEM-PROBE-OUTPUTS.sha256" | awk '{print $1}')
  if ! cmp -s -- "$system_probe_success_file" <(
    printf '%s\n' \
      "manifest_rel=$manifest_rel" \
      "agent_sha=$agent_sha" \
      "core_sha=$core_sha" \
      "assets_manifest_sha256=$assets_manifest_sha256" \
      "outputs_manifest_sha256=$outputs_manifest_sha256"
  ); then
    echo "system-probe success marker does not match the verified handoff" >&2
    exit 1
  fi
}

prefetch_go_modules() (
  status_before=$(mktemp "$TMPDIR/go-source-status.before.XXXXXX")
  status_after=$(mktemp "$TMPDIR/go-source-status.after.XXXXXX")
  module_list=$(mktemp "$TMPDIR/go-module-paths.XXXXXX")
  trap 'rm -f -- "$status_before" "$status_after" "$module_list"' EXIT

  LC_ALL=C git status --porcelain=v1 -z --untracked-files=all >"$status_before"
  LC_ALL=C awk '
    /^modules:[[:space:]]*$/ {
      in_modules = 1
      next
    }
    in_modules && /^[^[:space:]#]/ {
      exit
    }
    in_modules && /^  [^[:space:]#][^:]*:/ {
      entry = $0
      sub(/^  /, "", entry)
      if (entry ~ /:[[:space:]]*ignored[[:space:]]*$/) {
        next
      }
      sub(/:.*/, "", entry)
      print entry
    }
  ' modules.yml | LC_ALL=C sort -u >"$module_list"
  test -s "$module_list"
  module_count=$(wc -l <"$module_list")
  if ((module_count != 190)); then
    echo "expected 190 configured Go modules, found $module_count" >&2
    exit 1
  fi

  while IFS= read -r module_rel; do
    module_dir=$(readlink -f -- "$src_dir/$module_rel")
    case "$module_dir" in
      "$src_dir" | "$src_dir"/*) ;;
      *)
        echo "Go module escapes source tree: $module_rel" >&2
        exit 1
        ;;
    esac
    test -f "$module_dir/go.mod"
    printf 'Prefetching Go module: %s\n' "$module_dir"
    (cd "$module_dir" && go mod download)
  done <"$module_list"

  if ! verify_patch_stack; then
    echo "go mod download unexpectedly changed the pinned patch stack" >&2
    git status --short --untracked-files=all >&2
    exit 1
  fi
  git diff --check
  LC_ALL=C git status --porcelain=v1 -z --untracked-files=all >"$status_after"
  if ! cmp -s -- "$status_before" "$status_after"; then
    echo "go mod download unexpectedly changed source-tree status" >&2
    git status --short --untracked-files=all >&2
    exit 1
  fi
)

test -d "$install_dir"
test -w "$install_dir"
printf '%s  %s\n' "$adp_sha256" "$adp_tar" | sha256sum -c -
if find "$install_dir" -mindepth 1 -print -quit | grep -q .; then
  echo "$install_dir is not empty; refusing to overwrite it" >&2
  exit 1
fi
if [[ -d "$stage_config_dir" ]] && find "$stage_config_dir" -mindepth 1 -print -quit | grep -q .; then
  echo "$stage_config_dir is not empty; refusing to mix staged files from another run" >&2
  exit 1
fi
if [[ -d "$omnibus_base_dir" ]] && find "$omnibus_base_dir" -mindepth 1 -print -quit | grep -q .; then
  echo "$omnibus_base_dir is not empty; refusing to reuse a partial Omnibus attempt" >&2
  exit 1
fi

require_file() {
  if [[ ! -s "$1" ]]; then
    echo "missing required system-probe output: $1" >&2
    exit 1
  fi
}

require_glob() {
  if ! compgen -G "$1" >/dev/null; then
    echo "missing required system-probe outputs: $1" >&2
    exit 1
  fi
}

require_glob "$src_dir/pkg/ebpf/bytecode/build/arm64/*.o"
require_glob "$src_dir/pkg/ebpf/bytecode/build/arm64/co-re/*.o"
require_glob "$src_dir/pkg/ebpf/bytecode/build/runtime/*.c"
for generated_go in \
  conntrack gpu offsetguess-test oom-kill runtime-security \
  shared-libraries tcp-queue-length tracer usm
do
  require_file "$src_dir/pkg/ebpf/bytecode/runtime/$generated_go.go"
done
require_file "$src_dir/pkg/discovery/module/rust/embedded/bin/system-probe-lite"
require_file "$src_dir/pkg/discovery/module/rust/libdd_discovery.a"

verify_bazel_action_cache_contract() {
  local action_cache=$1 cache_tmp unexpected

  if [[ $action_cache != "$persistent_cache/bazel/disk" ]]; then
    echo "unexpected Bazel action-cache path: $action_cache" >&2
    exit 1
  fi
  if [[ ! -d $action_cache || -L $action_cache ]] || \
    [[ $(readlink -e -- "$action_cache") != "$action_cache" ]]; then
    echo "Bazel action cache must be a real directory: $action_cache" >&2
    exit 1
  fi

  unexpected=$(find "$action_cache" -xdev -mindepth 1 \
    ! -type d ! -type f -print -quit)
  if [[ -n $unexpected ]]; then
    echo "unsupported entry in Bazel action cache: $unexpected" >&2
    exit 1
  fi
  unexpected=$(find "$action_cache" -xdev \
    \( -type d -o -type f \) ! -group dbdog -print -quit)
  if [[ -n $unexpected ]]; then
    echo "Bazel action-cache entry is not in group dbdog: $unexpected" >&2
    exit 1
  fi
  unexpected=$(find "$action_cache" -xdev -type d \
    \( ! -perm -g+rwx -o ! -perm -2000 \) -print -quit)
  if [[ -n $unexpected ]]; then
    echo "Bazel action-cache directory lacks group rwx/setgid: $unexpected" >&2
    exit 1
  fi
  unexpected=$(find "$action_cache" -xdev -type f \
    ! -perm -g+rw -print -quit)
  if [[ -n $unexpected ]]; then
    echo "Bazel action-cache file lacks group read/write: $unexpected" >&2
    exit 1
  fi

  cache_tmp="$action_cache/tmp"
  if [[ ! -d $cache_tmp || -L $cache_tmp ]] || \
    [[ $(readlink -e -- "$cache_tmp") != "$cache_tmp" ]]; then
    echo "Bazel action-cache tmp must be a real directory: $cache_tmp" >&2
    exit 1
  fi
}

probe_bazel_action_cache_tmp() (
  local cache_tmp="$1/tmp" probe_dir probe_source probe_target

  probe_dir=$(mktemp -d "$cache_tmp/.dbdog-action-cache-probe.XXXXXX")
  case "$probe_dir" in
    "$cache_tmp"/.dbdog-action-cache-probe.*) ;;
    *)
      echo "unsafe Bazel action-cache probe path: $probe_dir" >&2
      exit 1
      ;;
  esac
  trap 'rm -rf -- "$probe_dir"' EXIT

  probe_source="$probe_dir/write-test"
  probe_target="$probe_dir/rename-test"
  printf '%s\n' dbdog-action-cache-probe >"$probe_source"
  test -s "$probe_source"
  mv -- "$probe_source" "$probe_target"
  test -f "$probe_target"
  rm -f -- "$probe_target"
  rmdir -- "$probe_dir"
  trap - EXIT
)

verify_go_tmpdir_contract() (
  local tmp_parent="$build_dir/tmp" path probe_file actual_go_tmpdir

  if [[ $TMPDIR != "$go_tmp_dir" || $GOTMPDIR != "$go_tmp_dir" ]]; then
    echo "TMPDIR and GOTMPDIR must both select the pinned Go temporary directory" >&2
    exit 1
  fi
  for path in "$tmp_parent" "$go_tmp_dir"; do
    if [[ ! -d $path || -L $path ]]; then
      echo "pinned Go temporary path must be a real directory: $path" >&2
      exit 1
    fi
    if [[ $(readlink -e -- "$path") != "$path" ]]; then
      echo "pinned Go temporary path is not canonical: $path" >&2
      exit 1
    fi
    if [[ $(stat -c '%u' -- "$path") != "$dbdog_uid" ]]; then
      echo "pinned Go temporary path is not owned by dbdog: $path" >&2
      exit 1
    fi
    if [[ ! -w $path || ! -x $path ]]; then
      echo "pinned Go temporary path is not writable/searchable by dbdog: $path" >&2
      exit 1
    fi
  done
  if [[ $(stat -c '%d' -- "$go_tmp_dir") != $(stat -c '%d' -- "$build_dir") ]]; then
    echo "pinned Go temporary directory is not on the build/root filesystem" >&2
    exit 1
  fi

  probe_file=$(mktemp "$go_tmp_dir/.dbdog-go-tmp-probe.XXXXXX")
  case $probe_file in
    "$go_tmp_dir"/.dbdog-go-tmp-probe.*) ;;
    *)
      echo "unsafe pinned Go temporary probe path: $probe_file" >&2
      exit 1
      ;;
  esac
  trap 'rm -f -- "$probe_file"' EXIT
  printf '%s\n' dbdog-go-tmp-probe >"$probe_file"
  test -s "$probe_file"
  rm -f -- "$probe_file"
  trap - EXIT

  actual_go_tmpdir=$(go env GOTMPDIR)
  if [[ $actual_go_tmpdir != "$go_tmp_dir" ]]; then
    echo "go env GOTMPDIR did not select the pinned Go temporary directory: $actual_go_tmpdir" >&2
    exit 1
  fi
)

export HOME=/home/dbdog
export XDG_CACHE_HOME="$persistent_cache/xdg/user"
export TMPDIR="$go_tmp_dir"
export GOTMPDIR="$go_tmp_dir"
export BAZELISK_HOME=/home/dbdog/.cache/bazelisk
export DBDOG_BAZEL_DISK_CACHE="$persistent_cache/bazel/disk"
export PATH="$patchelf_bin_dir":/home/dbdog/tools/dda-venv/bin:/home/dbdog/tools/ruby27/bin:/home/dbdog/tools/python312/bin:/home/dbdog/tools/go/bin:/home/dbdog/tools/bin:/home/dbdog/tools/node/bin:/home/dbdog/.cargo/bin:/usr/local/bin:/usr/bin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
verify_patchelf_path_selection

export INSTALL_DIR="$install_dir"
export INTEGRATIONS_CORE_VERSION="$core_sha"
export AGENT_DATA_PLANE_VERSION=1.2.2
export AGENT_DATA_PLANE_HASH_LINUX_ARM64="$adp_sha256"
export OMNIBUS_WORKERS_OVERRIDE=1
export OMNIBUS_GIT_CACHE_DIR="$persistent_cache/omnibus/git"
# Keep DDA_NO_DYNAMIC_DEPS unset. DDA then uses its persistent, lock-driven
# legacy environment; setting it would incorrectly select DDA's own Python,
# where the complete legacy-tasks dependency group is not installed.
export SKIP_PKG_COMPRESSION=true
export RUBY_VERSION=2.7.8
export MY_RUBY_HOME=/home/dbdog/tools/ruby27
export GOPATH="$persistent_cache/go/gopath"
export GOMODCACHE="$persistent_cache/go/mod"
export GOCACHE="$persistent_cache/go/build"
export GOMAXPROCS=1
export GOFLAGS=-p=1
export GOENV=off
export GOWORK="$src_dir/go.work"
export GOTOOLCHAIN=local
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=sum.golang.google.cn
export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
export PIP_CACHE_DIR="$persistent_cache/pip"
export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
export UV_CACHE_DIR="$persistent_cache/uv"
export UV_CONCURRENT_DOWNLOADS=2
export UV_CONCURRENT_BUILDS=1
export BUNDLE_USER_CONFIG="$persistent_cache/$manifest_rel/controls/bundle-config"
export BUNDLE_USER_CACHE="$persistent_cache/bundle-user-cache"
export BUNDLE_CACHE_PATH="$bundle_work_cache"
export BUNDLE_CACHE_ALL=true
export BUNDLE_CACHE_ALL_PLATFORMS=true
export BUNDLE_FROZEN=true

mkdir -p \
  "$XDG_CACHE_HOME" \
  "$DBDOG_BAZEL_DISK_CACHE" \
  "$DBDOG_BAZEL_DISK_CACHE/tmp" \
  "$TMPDIR" \
  "$persistent_cache/bundle" \
  "$persistent_cache/bundle-user-cache" \
  "$bundle_work_cache" \
  "$GOPATH" \
  "$GOMODCACHE" \
  "$GOCACHE" \
  "$persistent_cache/pip" \
  "$persistent_cache/uv" \
  "$persistent_cache/omnibus/sources" \
  "$persistent_cache/omnibus/git" \
  "$stage_config_dir"

for writable_dir in \
  "$XDG_CACHE_HOME" \
  "$DBDOG_BAZEL_DISK_CACHE" \
  "$TMPDIR" \
  "$persistent_cache/bundle" \
  "$persistent_cache/bundle-user-cache" \
  "$bundle_work_cache" \
  "$GOPATH" \
  "$GOMODCACHE" \
  "$GOCACHE" \
  "$persistent_cache/pip" \
  "$persistent_cache/uv" \
  "$persistent_cache/omnibus/sources" \
  "$persistent_cache/omnibus/git" \
  "$stage_config_dir"
do
  if [[ ! -w "$writable_dir" ]]; then
    echo "persistent build directory is not writable by dbdog: $writable_dir" >&2
    exit 1
  fi
done

verify_go_tmpdir_contract

# The repository cache, distdir, and manifests are immutable dependency
# authority. This recursive contract deliberately covers only bazel/disk,
# which contains derived action outputs, then proves Bazel's real tmp workflow
# (create, write, same-filesystem rename, and delete) under the pipeline lock.
verify_bazel_action_cache_contract "$DBDOG_BAZEL_DISK_CACHE"
probe_bazel_action_cache_tmp "$DBDOG_BAZEL_DISK_CACHE"
verify_patchelf_runtime
verify_selinux_tool_identity
verify_selinux_tool_path_selection
verify_selinux_policy_toolchain_smoke

/usr/bin/bash "$persistent_cache/$manifest_rel/controls/hydrate-agent-dda-legacy.sh" \
  "$persistent_cache/$manifest_rel"
/usr/bin/bash "$persistent_cache/$manifest_rel/controls/verify-agent-dda-legacy.sh" \
  "$persistent_cache/$manifest_rel"

# Bundler adjusts executable modes inside cached Git gems during installation.
# Keep the sealed package cache immutable and give Bundler an exact writable
# attempt-local copy instead.
rsync -rlptD --checksum --delete \
  --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
  "$bundle_cache/" "$bundle_work_cache/"

if ! printf '%s  %s\n' "$adp_sha256" "$adp_cache" | sha256sum -c - >/dev/null 2>&1; then
  install -m 0644 "$adp_tar" "$adp_cache"
fi
printf '%s  %s\n' "$adp_sha256" "$adp_cache" | sha256sum -c -

cd "$src_dir"
test "$(git rev-parse HEAD)" = "$agent_sha"
ensure_platform_patch_applied
printf '%s  %s\n' "$patched_selinux_sha256" "$src_dir/tasks/selinux.py" | sha256sum -c -
printf '%s  %s\n' \
  5c848f37c71b14adc81b4a49ac34ae429ba55bbfd0aca95c253127699c64055e \
  "$src_dir/user.bazelrc" | sha256sum -c -
printf '%s  %s\n' "$bundle_lock_sha256" "$src_dir/omnibus/Gemfile.lock" | sha256sum -c -
verify_patch_stack
git diff --check
verify_system_probe_handoff

date --iso-8601=seconds
ruby --version
bundle --version
python3 --version
go version
test "$(ruby -e 'print RUBY_VERSION')" = 2.7.8
test "$(bundle --version)" = 'Bundler version 2.4.20'
test "$(python3 -c 'import platform; print(platform.python_version())')" = 3.12.8
test "$(go env GOVERSION)" = go1.26.4
dda inv -- check-go-version
prefetch_go_modules
verify_patchelf_path_selection
verify_selinux_tool_identity
verify_selinux_tool_path_selection
dda inv -- -e omnibus.build \
  --skip-deps \
  --host-distribution=rhel \
  --base-dir="$omnibus_base_dir" \
  --cache-dir="$persistent_cache/omnibus/sources" \
  --gem-path="$persistent_cache/bundle" \
  --go-mod-cache="$GOMODCACHE" \
  --system-probe-bin="$assets_dir" \
  --python-mirror=https://pypi.tuna.tsinghua.edu.cn/simple \
  --pip-config-file="$TMPDIR/pip.conf" \
  --install-directory="$install_dir" \
  --config-directory="$stage_config_dir"
verify_selinux_tool_identity
verify_selinux_tool_path_selection
verify_built_selinux_policy
verify_patch_stack
git diff --check
/usr/bin/bash "$persistent_cache/$manifest_rel/controls/verify-agent-dda-legacy.sh" \
  "$persistent_cache/$manifest_rel"
date --iso-8601=seconds
success_tmp=$(mktemp "$build_dir/.omnibus.success.XXXXXX")
printf '%s\n' \
  "manifest_rel=$manifest_rel" \
  "agent_sha=$agent_sha" \
  "core_sha=$core_sha" \
  "omnibus_ruby_sha=$OMNIBUS_RUBY_VERSION" \
  "control_overlay_rel=$control_overlay_rel" \
  "control_overlay_runner_sha256=$control_overlay_runner_sha256" \
  "platform_patch_sha256=$platform_patch_sha256" \
  "patchelf_rel=$patchelf_rel" \
  "patchelf_sha256=$patchelf_sha256" \
  'host_distribution=rhel' \
  >"$success_tmp"
chmod 0644 "$success_tmp"
mv -f -- "$success_tmp" "$success_file"
