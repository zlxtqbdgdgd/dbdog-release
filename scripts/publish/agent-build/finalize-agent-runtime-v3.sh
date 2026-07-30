#!/usr/bin/env bash
# Finalize an already-successful AArch64 Kylin Omnibus staging tree and create
# a byte-reproducible runtime archive. This script is intentionally strict: it
# only accepts the build/install layout produced by run-agent-omnibus.sh.
set -euo pipefail

umask 0022
export LC_ALL=C

readonly OFFICIAL_INSTALL_DIR=/opt/datadog-agent
readonly PRIVATE_INSTALL_DIR=/opt/dbdog-agent
readonly MAX_GLIBC_VERSION=2.28
readonly GAUSSDB_INTEGRATION_NAME=datadog-gaussdb
readonly EXPECTED_GAUSSDB_INTEGRATION_VERSION=1.0.1
readonly EXPECTED_INTEGRATION_CORE_SHA=612be7bea397c87df707489599c02ed623c29631
readonly OMNIBUS_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f
readonly GAUSSDB_WHEEL_REL=sources/python/gaussdb/612be7bea397c87df707489599c02ed623c29631/datadog_gaussdb-1.0.1-py3-none-any.whl
readonly GAUSSDB_WHEEL_SHA256=f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f
readonly ADP_SOFTWARE_NAME=datadog-agent-data-plane
readonly ADP_VERSION=1.2.2
readonly ADP_INPUT_REL=sources/agent-data-plane-1.2.2-linux-arm64.tar.gz
readonly ADP_INPUT_SHA256=f071bd14e06308754848140f7b5beac27b02e11105e0970b293417ab69037ca6
readonly AGENT_CACHE_ROOT=/home/dbdog/cache/dbdog-agent
readonly EXPECTED_RELEASE_AGENT_SHA=62ad29793b02139448b76bc85fc406491a08bf58
readonly GENERATED_OUTPUTS_ORIGIN_AGENT_SHA=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
readonly EXPECTED_MANIFEST_REL=manifests/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7
readonly EXPECTED_OMNIBUS_RUBY_SHA=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
readonly EXPECTED_CONTROL_OVERLAY_REL=control-overlays/62ad29793b02139448b76bc85fc406491a08bf58-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v14
readonly EXPECTED_CONTROL_OVERLAY_RUNNER_SHA256=6da7c38074a6c16a15a491a1358e8fc8c606bea1eaac81df10352e79737c8e4a
readonly EXPECTED_PLATFORM_PATCH_SHA256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe
readonly EXPECTED_CONTROL_INFO_SHA256=b5dcfa966d6ebe9bcb080c392b8544693ec3c3bf5c88e49275da7c093b427b50
readonly EXPECTED_CONTROL_MANIFEST_SHA256=359151228de51ed690c00caf6d22f42f8e7f0026d512e5c39962fc23f74c4e75
readonly EXPECTED_PATCHELF_TOOL_REL=tools/patchelf/0.18.0-aarch64-kylin10-v2
readonly EXPECTED_PATCHELF_REL=$EXPECTED_PATCHELF_TOOL_REL/bin/patchelf
readonly EXPECTED_PATCHELF_SHA256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf
readonly EXPECTED_PATCHELF_INFO_SHA256=a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7
readonly EXPECTED_PATCHELF_SUMS_SHA256=4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7
readonly EXPECTED_PATCHELF_VERSION=0.18.0
readonly EXPECTED_PATCHELF_REPORTED_VERSION='patchelf 0.18.0'
readonly EXPECTED_HOST_DISTRIBUTION=rhel
readonly GIT_RUNUSER=/usr/sbin/runuser
readonly EXPECTED_GIT_RUNUSER_SHA256=9d94f70381493ee8fd9ff6c390fcfb0c48020a9c7a3a6f7f73ea22dd4d12b06d
readonly SYSTEM_PYTHON=/usr/bin/python3
readonly EXPECTED_SYSTEM_PYTHON_REAL=/usr/bin/python3.7
readonly EXPECTED_SYSTEM_PYTHON_SHA256=f5b09249fb172b46ba1cd4f33bd4cfd894328cc695e7640c2ef083d0ccae0b19
readonly PUBLICATION_RECIPE=destination_local_copy_verify_sync_hardlink_noreplace_archive_then_sidecar_recover_archive_only

log() {
  printf '[finalize-agent-runtime] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: sudo env \
  BUILD_DIR=/home/dbdog/work/dbdog-agent-<sha>-build<N> \
  VERSION=<release-version> \
  AGENT_SHA=<40-hex-sha> \
  CORE_SHA=<40-hex-sha> \
  OUTPUT_DIR=/home/dbdog/work/dbdog-agent-<sha>-build<N>/out \
  /usr/bin/bash finalize-agent-runtime.sh

Optional environment:
  INSTALL_DIR=/opt/dbdog-agent
  ARCH=aarch64
  AGENT_SOURCE_DIR=$BUILD_DIR/src
  CORE_REPO=/home/dbdog/cache/dbdog-agent/git/dbdog-agent-core.git
  SOURCE_DATE_EPOCH=<non-negative Unix timestamp>
  BUILDER_IMAGE_DIGEST=sha256:<64 lowercase hex>
  BUILDER_IDENTITY=<explicit native-builder identity; alternative to image digest>

The script accepts no positional arguments. OUTPUT_DIR defaults to
$BUILD_DIR/out and must remain at or below that directory.
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool is missing: $1"
}

require_path_within() {
  local label=$1
  local root=$2
  local path=$3
  local resolved

  [[ -e $path || -L $path ]] || die "$label is missing: $path"
  resolved=$(readlink -e -- "$path") || die "cannot resolve $label: $path"
  case "$resolved" in
    "$root" | "$root"/*) ;;
    *) die "$label resolves outside $root: $path -> $resolved" ;;
  esac
  printf '%s\n' "$resolved"
}

reject_control_characters() {
  local label=$1
  local value=$2
  case "$value" in
    *$'\n'* | *$'\r'* | *$'\t'*)
      die "$label contains a newline, carriage return, or tab"
      ;;
  esac
}

canonical_existing_dir() {
  local label=$1
  local value=$2
  local resolved

  [[ -n $value ]] || die "$label is empty"
  [[ $value == /* ]] || die "$label must be absolute: $value"
  reject_control_characters "$label" "$value"
  [[ -d $value && ! -L $value ]] || die "$label is not a real directory: $value"
  resolved=$(readlink -e -- "$value") || die "cannot resolve $label: $value"
  [[ -n $resolved && $resolved != / ]] || die "unsafe $label: $resolved"
  printf '%s\n' "$resolved"
}

git_in() {
  local repo=$1
  shift
  # Kylin's backported safe.directory check ignores command-scope and
  # environment-selected config when root opens a dbdog-owned repository.
  # Run these read-only Git queries as the repository owner instead of
  # weakening root's global Git trust configuration.
  /usr/bin/env -i \
    HOME=/home/dbdog \
    PATH=/usr/bin:/bin \
    LANG=C \
    LC_ALL=C \
    "$GIT_RUNUSER" -u dbdog -- /usr/bin/git -C "$repo" "$@"
}

verify_omnibus_success_marker() {
  local marker=$1

  [[ -f $marker && ! -L $marker ]] || die "missing regular Omnibus success marker"
  if ! cmp -s -- "$marker" <(
    printf '%s\n' \
      "manifest_rel=$EXPECTED_MANIFEST_REL" \
      "agent_sha=$agent_sha" \
      "generated_outputs_origin_agent_sha=$GENERATED_OUTPUTS_ORIGIN_AGENT_SHA" \
      "core_sha=$OMNIBUS_CORE_SHA" \
      "omnibus_ruby_sha=$EXPECTED_OMNIBUS_RUBY_SHA" \
      "control_overlay_rel=$EXPECTED_CONTROL_OVERLAY_REL" \
      "control_overlay_runner_sha256=$EXPECTED_CONTROL_OVERLAY_RUNNER_SHA256" \
      "platform_patch_sha256=$EXPECTED_PLATFORM_PATCH_SHA256" \
      "patchelf_rel=$EXPECTED_PATCHELF_REL" \
      "patchelf_sha256=$EXPECTED_PATCHELF_SHA256" \
      "host_distribution=$EXPECTED_HOST_DISTRIBUTION"
  ); then
    die "omnibus.success does not match the exact Kylin v14 control handoff"
  fi
}

verify_patchelf_tool_authority() {
  local cache_root=$1
  local tool_dir binary expected_inventory actual_inventory entry entry_path
  local expected_stat actual_stat resolved_path version_output

  tool_dir="$cache_root/$EXPECTED_PATCHELF_TOOL_REL"
  binary="$cache_root/$EXPECTED_PATCHELF_REL"
  expected_inventory=$'.\nPATCHELF-INFO\nSHA256SUMS\nbin\nbin/patchelf'

  [[ -d $tool_dir && ! -L $tool_dir ]] ||
    die "pinned v9 patchelf tool root must be a real directory: $tool_dir"
  [[ $(readlink -e -- "$tool_dir") == "$tool_dir" ]] ||
    die "pinned v9 patchelf tool root resolves through an unexpected path"
  actual_inventory=$(
    {
      printf '.\n'
      find "$tool_dir" -xdev -mindepth 1 -printf '%P\n'
    } | LC_ALL=C sort
  )
  [[ $actual_inventory == "$expected_inventory" ]] ||
    die "pinned v9 patchelf tool inventory differs from the exact five-node set"

  while IFS= read -r entry; do
    if [[ $entry == . ]]; then
      entry_path=$tool_dir
    else
      entry_path="$tool_dir/$entry"
    fi
    [[ ! -L $entry_path ]] ||
      die "pinned v9 patchelf tool entry must not be a symlink: $entry_path"
    resolved_path=$(readlink -e -- "$entry_path") ||
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
    actual_stat=$(stat -c '%u:%g:%a' -- "$entry_path")
    [[ $actual_stat == "$expected_stat" ]] ||
      die "pinned v9 patchelf tool owner/mode mismatch: $entry_path ($actual_stat)"
  done <<<"$expected_inventory"

  printf '%s  %s\n' "$EXPECTED_PATCHELF_SHA256" "$binary" |
    sha256sum -c - >/dev/null || die "pinned v9 patchelf binary digest changed"
  printf '%s  %s\n' "$EXPECTED_PATCHELF_INFO_SHA256" "$tool_dir/PATCHELF-INFO" |
    sha256sum -c - >/dev/null || die "pinned v9 PATCHELF-INFO digest changed"
  printf '%s  %s\n' "$EXPECTED_PATCHELF_SUMS_SHA256" "$tool_dir/SHA256SUMS" |
    sha256sum -c - >/dev/null || die "pinned v9 patchelf SHA256SUMS digest changed"
  (
    cd "$tool_dir"
    sha256sum -c SHA256SUMS
  ) >/dev/null || die "pinned v9 patchelf metadata checksum verification failed"

  version_output=$(
    env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "$binary" --version
  ) || die "pinned v9 patchelf version probe failed"
  [[ $version_output == "$EXPECTED_PATCHELF_REPORTED_VERSION" ]] ||
    die "pinned v9 patchelf reported an unexpected version: $version_output"
}

verify_omnibus_control_overlay() {
  local cache_root overlay_dir actual_inventory expected_inventory overlay_file

  cache_root=$(canonical_existing_dir AGENT_CACHE_ROOT "$AGENT_CACHE_ROOT")
  [[ $cache_root == "$AGENT_CACHE_ROOT" ]] ||
    die "agent cache root must resolve exactly to $AGENT_CACHE_ROOT"
  overlay_dir="$cache_root/$EXPECTED_CONTROL_OVERLAY_REL"
  [[ -d $overlay_dir && ! -L $overlay_dir ]] ||
    die "missing real Omnibus v14 control-overlay directory"
  [[ $(readlink -e -- "$overlay_dir") == "$overlay_dir" ]] ||
    die "Omnibus v14 control overlay resolves through an unexpected path"
  [[ $(stat -c '%u:%g:%a' -- "$overlay_dir") == 0:0:555 ]] ||
    die "Omnibus v14 control-overlay directory must be root:root mode 0555"

  expected_inventory=$'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh'
  actual_inventory=$(find "$overlay_dir" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  [[ $actual_inventory == "$expected_inventory" ]] ||
    die "Omnibus v14 control-overlay inventory differs from the exact four-file set"

  for overlay_file in CONTROL-INFO CONTROL.sha256 agent-build-kylin-platform.patch; do
    [[ -f $overlay_dir/$overlay_file && ! -L $overlay_dir/$overlay_file ]] ||
      die "Omnibus v14 control file is not a real regular file: $overlay_file"
    [[ $(stat -c '%u:%g:%a' -- "$overlay_dir/$overlay_file") == 0:0:444 ]] ||
      die "Omnibus v14 control file must be root:root mode 0444: $overlay_file"
  done
  [[ -f $overlay_dir/run-agent-omnibus.sh && ! -L $overlay_dir/run-agent-omnibus.sh ]] ||
    die "Omnibus v14 runner is not a real regular file"
  [[ $(stat -c '%u:%g:%a' -- "$overlay_dir/run-agent-omnibus.sh") == 0:0:555 ]] ||
    die "Omnibus v14 runner must be root:root mode 0555"

  if ! cmp -s -- "$overlay_dir/CONTROL.sha256" <(
    printf '%s  %s\n' \
      "$EXPECTED_CONTROL_OVERLAY_RUNNER_SHA256" \
      "$EXPECTED_CONTROL_OVERLAY_REL/run-agent-omnibus.sh" \
      "$EXPECTED_PLATFORM_PATCH_SHA256" \
      "$EXPECTED_CONTROL_OVERLAY_REL/agent-build-kylin-platform.patch" \
      "$EXPECTED_CONTROL_INFO_SHA256" \
      "$EXPECTED_CONTROL_OVERLAY_REL/CONTROL-INFO" \
      "$EXPECTED_PATCHELF_SHA256" \
      "$EXPECTED_PATCHELF_REL"
  ); then
    die "Omnibus v14 CONTROL.sha256 does not match the pinned four-entry manifest"
  fi
  printf '%s  %s\n' "$EXPECTED_CONTROL_MANIFEST_SHA256" \
    "$overlay_dir/CONTROL.sha256" | sha256sum -c - >/dev/null ||
    die "Omnibus v14 CONTROL.sha256 digest differs from the pinned value"
  (
    cd "$cache_root"
    sha256sum -c "$EXPECTED_CONTROL_OVERLAY_REL/CONTROL.sha256"
  ) >/dev/null || die "Omnibus v14 control-overlay checksum verification failed"

  verify_patchelf_tool_authority "$cache_root"
}

validate_tree_names_and_types() {
  local root=$1
  local path relative

  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    reject_control_characters "runtime path" "$relative"
    [[ $relative != *\\* ]] || die "runtime path contains a backslash: $relative"
  done < <(find "$root" -mindepth 1 -print0)

  while IFS= read -r -d '' path; do
    die "unsupported special file in runtime: ${path#"$root"/}"
  done < <(find "$root" -mindepth 1 \
    ! -type f ! -type d ! -type l -print0)
}

verify_runtime_exclusions() {
  local root=$1
  local state_dir leftover

  leftover=$(find "$root" -mindepth 1 \
    \( -name __pycache__ -o -name .debug -o -name '*.debug.zip' \
    -o -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*.debug' -o -name '.DS_Store' \
    -o -name 'schemas.py.pre-dbdog-schema-recommendation-fields' \) \) \
    -print -quit)
  [[ -z $leftover ]] || die "excluded build/runtime residue remains: ${leftover#"$root"/}"

  for state_dir in run log logs tmp; do
    [[ ! -d $root/$state_dir ]] && continue
    leftover=$(find "$root/$state_dir" -mindepth 1 -print -quit)
    [[ -z $leftover ]] || die "runtime-state directory is not empty: $state_dir"
  done
}

write_symlink_manifest() {
  local root=$1
  local output=$2
  local link relative target resolved mapped

  : >"$output"
  while IFS= read -r -d '' link; do
    relative=${link#"$root"/}
    target=$(readlink -- "$link") || die "cannot read symlink: $relative"
    reject_control_characters "symlink target for $relative" "$target"
    [[ $target != *\\* ]] || die "symlink target contains a backslash: $relative"

    case "$target" in
      "$OFFICIAL_INSTALL_DIR" | "$OFFICIAL_INSTALL_DIR"/*)
        die "symlink points at the official Agent runtime: $relative -> $target"
        ;;
      "$build_dir" | "$build_dir"/*)
        die "symlink points at the Omnibus attempt: $relative -> $target"
        ;;
    esac

    if [[ $target == /* ]]; then
      case "$target" in
        "$install_dir")
          mapped=$root
          ;;
        "$install_dir"/*)
          mapped="$root/${target#"$install_dir"/}"
          ;;
        *)
          die "absolute symlink escapes the private runtime: $relative -> $target"
          ;;
      esac
      resolved=$(readlink -m -- "$mapped")
    else
      resolved=$(readlink -m -- "$(dirname -- "$link")/$target")
    fi

    case "$resolved" in
      "$root" | "$root"/*) ;;
      *) die "symlink escapes the runtime: $relative -> $target" ;;
    esac
    [[ -e $resolved || -L $resolved ]] || die "dangling runtime symlink: $relative -> $target"
    printf './%s\t%s\n' "$relative" "$target" >>"$output"
  done < <(find "$root" -type l -print0 | sort -z)
}

write_regular_file_manifest() {
  local root=$1
  local output=$2
  local file relative

  : >"$output"
  while IFS= read -r -d '' file; do
    relative=${file#"$root"/}
    [[ $relative == provenance/runtime.sha256 ]] && continue
    (
      cd "$root"
      sha256sum -- "./$relative"
    ) >>"$output"
  done < <(find "$root" -type f -print0 | sort -z)
}

glibc_version_is_too_new() {
  local version=$1
  local greatest

  greatest=$(printf '%s\n%s\n' "$version" "$MAX_GLIBC_VERSION" | sort -V | tail -n 1)
  [[ $greatest == "$version" && $version != "$MAX_GLIBC_VERSION" ]]
}

write_glibc_report() {
  local root=$1
  local output=$2
  local file relative versions maximum

  printf 'path\tmax_glibc_required\n' >"$output"
  while IFS= read -r -d '' file; do
    if ! readelf --wide --file-header "$file" >/dev/null 2>&1; then
      continue
    fi
    relative=${file#"$root"/}
    versions=$(
      readelf --wide --version-info "$file" 2>/dev/null |
        grep -o 'GLIBC_[0-9][0-9.]*' |
        sed 's/^GLIBC_//' |
        sort -Vu || true
    )
    if [[ -z $versions ]]; then
      maximum=none
    else
      maximum=$(tail -n 1 <<<"$versions")
      if glibc_version_is_too_new "$maximum"; then
        die "$relative requires GLIBC_$maximum (maximum allowed is GLIBC_$MAX_GLIBC_VERSION)"
      fi
    fi
    printf './%s\t%s\n' "$relative" "$maximum" >>"$output"
  done < <(find "$root" -type f -print0 | sort -z)
}

verify_primary_binaries() {
  local root=$1
  local relative file
  local -a required_elf=(
    bin/agent/agent
    embedded/bin/trace-agent
    embedded/bin/process-agent
    embedded/bin/system-probe
    embedded/bin/security-agent
    embedded/bin/system-probe-lite
    embedded/bin/agent-data-plane
  )

  for relative in "${required_elf[@]}"; do
    file="$root/$relative"
    [[ -f $file && -x $file ]] || die "missing executable primary binary: $relative"
    readelf --wide --file-header "$file" 2>/dev/null |
      grep -Eq 'Machine:[[:space:]]+AArch64' ||
      die "primary binary is not AArch64 ELF: $relative"
  done

  relative=embedded/bin/trace-loader
  file="$root/$relative"
  [[ -f $file && -x $file ]] || die "missing executable primary entry: $relative"
  if readelf --wide --file-header "$file" >/dev/null 2>&1; then
    readelf --wide --file-header "$file" |
      grep -Eq 'Machine:[[:space:]]+AArch64' ||
      die "trace-loader is ELF but is not AArch64"
  elif [[ $(head -c 2 -- "$file") != '#!' ]]; then
    die "trace-loader is neither AArch64 ELF nor a shebang script"
  fi
}

is_baseline_system_library() {
  case "$1" in
    ld-linux-aarch64.so.1 | \
      libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | \
      libresolv.so.2 | libutil.so.1 | libanl.so.1 | libnsl.so.1 | libcrypt.so.1 | \
      libgcc_s.so.1 | libatomic.so.1 | libcap.so.2 | libselinux.so.1 | \
      libsystemd.so.0 | libudev.so.1 | libseccomp.so.2 | libelf.so.1 | \
      libz.so.1 | liblzma.so.5 | libzstd.so.1 | libnuma.so.1)
      return 0
      ;;
  esac
  return 1
}

write_primary_linkage_report() {
  local root=$1
  local output=$2
  local relative file dynamic program_headers interpreter search_fields search_field
  local entry expanded mapped resolved needed needed_fields private_match
  local search_summary needed_summary binary_dir
  local -a search_entries=()
  local -a resolved_search_dirs=()
  local -a primary_entries=(
    bin/agent/agent
    embedded/bin/trace-loader
    embedded/bin/trace-agent
    embedded/bin/process-agent
    embedded/bin/system-probe
    embedded/bin/security-agent
    embedded/bin/system-probe-lite
    embedded/bin/agent-data-plane
  )

  printf 'path\tinterpreter\trpath_or_runpath\tneeded\n' >"$output"
  for relative in "${primary_entries[@]}"; do
    file="$root/$relative"
    if ! readelf --wide --file-header "$file" >/dev/null 2>&1; then
      [[ $relative == embedded/bin/trace-loader && $(head -c 2 -- "$file") == '#!' ]] ||
        die "non-ELF primary entry is not the permitted trace-loader script: $relative"
      printf './%s\tscript\tnone\tnone\n' "$relative" >>"$output"
      continue
    fi

    dynamic=$(readelf --wide --dynamic "$file" 2>/dev/null) ||
      die "cannot read ELF dynamic section: $relative"
    program_headers=$(readelf --wide --program-headers "$file" 2>/dev/null) ||
      die "cannot read ELF program headers: $relative"
    interpreter=$(
      awk '/Requesting program interpreter/ {
        line = $0
        sub(/^.*Requesting program interpreter: /, "", line)
        sub(/\].*$/, "", line)
        sub(/^\[/, "", line)
        print line
      }' <<<"$program_headers"
    )
    [[ $interpreter != *$'\n'* ]] || die "multiple ELF interpreters found: $relative"
    if [[ -z $interpreter ]]; then
      interpreter=none
    else
      case "$interpreter" in
        /lib/ld-linux-aarch64.so.1 | /lib64/ld-linux-aarch64.so.1 | \
          /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1) ;;
        *) die "unexpected ELF interpreter for $relative: $interpreter" ;;
      esac
    fi

    search_fields=$(
      awk '/[(](RPATH|RUNPATH)[)]/ {
        line = $0
        sub(/^.*\[/, "", line)
        sub(/\].*$/, "", line)
        print line
      }' <<<"$dynamic"
    )
    search_summary=none
    resolved_search_dirs=()
    while IFS= read -r search_field; do
      [[ -n $search_field ]] || continue
      reject_control_characters "RPATH/RUNPATH for $relative" "$search_field"
      [[ :$search_field: != *::* ]] || die "empty RPATH/RUNPATH component in $relative"
      if [[ $search_summary == none ]]; then
        search_summary=$search_field
      else
        search_summary="$search_summary;$search_field"
      fi
      IFS=: read -r -a search_entries <<<"$search_field"
      for entry in "${search_entries[@]}"; do
        [[ -n $entry ]] || die "empty RPATH/RUNPATH component in $relative"
        expanded=${entry//\$\{ORIGIN\}/$root/$(dirname -- "$relative")}
        expanded=${expanded//\$ORIGIN/$root/$(dirname -- "$relative")}
        [[ $expanded != *'$'* ]] || die "unsupported dynamic-loader token in $relative: $entry"
        if [[ $expanded == /* ]]; then
          case "$expanded" in
            "$install_dir") mapped=$root ;;
            "$install_dir"/*) mapped="$root/${expanded#"$install_dir"/}" ;;
            "$root" | "$root"/*) mapped=$expanded ;;
            *) die "RPATH/RUNPATH escapes the private runtime in $relative: $entry" ;;
          esac
        else
          die "relative non-ORIGIN RPATH/RUNPATH in $relative: $entry"
        fi
        resolved=$(readlink -m -- "$mapped")
        case "$resolved" in
          "$root" | "$root"/*) ;;
          *) die "RPATH/RUNPATH resolves outside the private runtime in $relative: $entry" ;;
        esac
        [[ -d $resolved ]] || die "RPATH/RUNPATH directory is absent in $relative: $entry"
        resolved_search_dirs+=("$resolved")
      done
    done <<<"$search_fields"

    needed_fields=$(
      awk '/[(]NEEDED[)]/ {
        line = $0
        sub(/^.*\[/, "", line)
        sub(/\].*$/, "", line)
        print line
      }' <<<"$dynamic"
    )
    needed_summary=none
    while IFS= read -r needed; do
      [[ -n $needed ]] || continue
      reject_control_characters "DT_NEEDED for $relative" "$needed"
      if [[ $needed_summary == none ]]; then
        needed_summary=$needed
      else
        needed_summary="$needed_summary,$needed"
      fi

      private_match=false
      if [[ $needed == */* ]]; then
        case "$needed" in
          "$install_dir"/*)
            mapped="$root/${needed#"$install_dir"/}"
            [[ -e $mapped || -L $mapped ]] && private_match=true
            ;;
          *) die "DT_NEEDED contains an external path in $relative: $needed" ;;
        esac
      else
        for resolved in "${resolved_search_dirs[@]}"; do
          if [[ -e $resolved/$needed || -L $resolved/$needed ]]; then
            private_match=true
            break
          fi
        done
      fi
      if [[ $private_match != true ]] && ! is_baseline_system_library "$needed"; then
        die "non-system DT_NEEDED is not resolved inside runtime: $relative -> $needed"
      fi
    done <<<"$needed_fields"

    binary_dir=${file%/*}
    case "$binary_dir" in
      "$root" | "$root"/*) ;;
      *) die "primary ELF escaped runtime while checking linkage: $relative" ;;
    esac
    printf './%s\t%s\t%s\t%s\n' \
      "$relative" "$interpreter" "$search_summary" "$needed_summary" >>"$output"
  done
}

verify_no_path_leaks() {
  local root=$1
  local file relative needle
  # Vendor binaries, integration metadata, and bundled third-party libraries
  # legitimately retain Datadog's documented default prefix as inert text.
  # Active path surfaces are checked structurally elsewhere: symlink targets,
  # executable shebangs, and primary ELF interpreter/RPATH/DT_NEEDED entries
  # must all resolve inside the private runtime. This raw byte scan is therefore
  # reserved for host build paths, which must never ship in any payload file.
  local -a needles=(
    "$build_dir"
    /home/dbdog/work/dbdog-agent-
  )

  while IFS= read -r -d '' file; do
    relative=${file#"$root"/}
    for needle in "${needles[@]}"; do
      if grep -a -F -q -- "$needle" "$file"; then
        die "forbidden path '$needle' leaked into runtime file: $relative"
      fi
    done
  done < <(find "$root" -type f -print0 | sort -z)
}

rewrite_safe_python_shebangs() {
  local root=$1
  local report=$2
  local file relative first interpreter arguments basename replacement

  printf 'path\tfinal_shebang\n' >"$report"
  while IFS= read -r -d '' file; do
    # A shebang only controls kernel execution when the regular file has an
    # execute bit. Ignore package source files whose inert header may use CRLF,
    # and compare raw bytes without placing possible NULs in a shell variable.
    if ! head -c 2 -- "$file" | cmp -s - <(printf '#!'); then
      continue
    fi
    first=''
    if ! IFS= read -r -n 256 first <"$file"; then
      die "unterminated shebang: ${file#"$root"/}"
    fi
    ((${#first} < 256)) || die "shebang exceeds 255 bytes: ${file#"$root"/}"
    [[ $first == '#!'* ]] || die "shebang probe changed while reading: ${file#"$root"/}"
    reject_control_characters "shebang for ${file#"$root"/}" "$first"

    interpreter=${first#\#!}
    arguments=''
    if [[ $interpreter == *' '* ]]; then
      arguments=" ${interpreter#* }"
      interpreter=${interpreter%% *}
    fi
    basename=${interpreter##*/}
    case "$basename" in
      python | python3 | python3.13) ;;
      *) continue ;;
    esac

    replacement=''
    case "$interpreter" in
      "$OFFICIAL_INSTALL_DIR"/embedded/bin/python*)
        replacement="$install_dir/embedded/bin/$basename$arguments"
        ;;
      "$build_dir"/*/embedded/bin/python* | "$build_dir"/embedded/bin/python*)
        replacement="$install_dir/embedded/bin/$basename$arguments"
        ;;
    esac
    if [[ -n $replacement ]]; then
      "$embedded_python" -I -B - "$file" "#!$replacement" <<'PYEOF'
import os
import sys

path, replacement = sys.argv[1:]
with open(path, "r+b") as stream:
    data = stream.read()
    first, separator, rest = data.partition(b"\n")
    if not first.startswith(b"#!"):
        raise SystemExit(f"not a shebang file: {path}")
    encoded = replacement.encode("utf-8")
    stream.seek(0)
    stream.write(encoded + (separator + rest if separator else b""))
    stream.truncate()
    stream.flush()
    os.fsync(stream.fileno())
PYEOF
      first="#!$replacement"
      interpreter="$install_dir/embedded/bin/$basename"
    fi

    case "$interpreter" in
      "$install_dir"/embedded/bin/python*) ;;
      *) continue ;;
    esac
    relative=${file#"$root"/}
    printf './%s\t%s\n' "$relative" "$first" >>"$report"
  done < <(find "$root" -type f -perm /111 -print0 | sort -z)
}

verify_python_sources() {
  local health=$1
  local schemas=$2

  grep -Fq 'DBDOG_DISABLE_DBM_HEALTH' "$health" ||
    die "dbm-health patch marker is absent"
  grep -Fq 'SCHEMA_RECOMMENDATION_FIELDS_ENV' "$schemas" ||
    die "PostgreSQL schema recommendation patch marker is absent"
  "$embedded_python" -I -B - "$health" "$schemas" <<'PYEOF'
import ast
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as stream:
        ast.parse(stream.read(), filename=path)
PYEOF
}

install_pinned_gaussdb_integration() {
  local root=$1
  local python="$root/embedded/bin/python3"
  local cache_root wheel wheel_real version_source

  cache_root=$(canonical_existing_dir AGENT_CACHE_ROOT "$AGENT_CACHE_ROOT")
  [[ $cache_root == "$AGENT_CACHE_ROOT" ]] ||
    die "agent cache root moved unexpectedly while installing $GAUSSDB_INTEGRATION_NAME"
  wheel="$cache_root/$GAUSSDB_WHEEL_REL"
  [[ -f $wheel && ! -L $wheel ]] ||
    die "pinned $GAUSSDB_INTEGRATION_NAME wheel is missing or is a symlink: $wheel"
  wheel_real=$(require_path_within "pinned $GAUSSDB_INTEGRATION_NAME wheel" "$cache_root" "$wheel")
  [[ $wheel_real == "$wheel" ]] ||
    die "pinned $GAUSSDB_INTEGRATION_NAME wheel resolves through an unexpected path"
  [[ $(stat -c '%u:%g:%a' -- "$wheel") == 0:0:444 ]] ||
    die "pinned $GAUSSDB_INTEGRATION_NAME wheel must be root:root mode 0444"
  printf '%s  %s\n' "$GAUSSDB_WHEEL_SHA256" "$wheel" |
    sha256sum -c - >/dev/null || die "pinned $GAUSSDB_INTEGRATION_NAME wheel checksum mismatch"
  [[ -x $python ]] || die "embedded Python is missing while installing $GAUSSDB_INTEGRATION_NAME"

  env -i \
    HOME=/nonexistent \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/bin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    "$python" -I -B - \
      "$wheel" "$GAUSSDB_INTEGRATION_NAME" "$EXPECTED_GAUSSDB_INTEGRATION_VERSION" <<'PYEOF'
from email.parser import BytesParser
from pathlib import PurePosixPath
import sys
import zipfile

wheel_path, expected_name, expected_version = sys.argv[1:]
with zipfile.ZipFile(wheel_path) as archive:
    names = archive.namelist()
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name:
            raise SystemExit(f"unsafe wheel member: {name!r}")
        if name.lower().endswith((".so", ".dylib", ".dll", ".pyd")):
            raise SystemExit(f"wheel is not pure Python: {name!r}")
    metadata_names = [name for name in names if name.endswith(".dist-info/METADATA")]
    wheel_names = [name for name in names if name.endswith(".dist-info/WHEEL")]
    if len(metadata_names) != 1 or len(wheel_names) != 1:
        raise SystemExit("wheel must contain one METADATA and one WHEEL record")
    metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
    wheel_metadata = BytesParser().parsebytes(archive.read(wheel_names[0]))
    if metadata.get("Name") != expected_name or metadata.get("Version") != expected_version:
        raise SystemExit(
            f"wheel identity mismatch: {metadata.get('Name')!r} {metadata.get('Version')!r}"
        )
    if wheel_metadata.get("Root-Is-Purelib") != "true":
        raise SystemExit("wheel does not declare Root-Is-Purelib: true")
    if wheel_metadata.get_all("Tag", []) != ["py3-none-any"]:
        raise SystemExit("wheel does not have the exact py3-none-any tag")
PYEOF

  version_source=$(
    git_in "$core_repo" show "$core_sha:gaussdb/datadog_checks/gaussdb/__about__.py"
  ) || die "cannot read GaussDB integration version source at CORE_SHA"
  grep -Eq "^__version__[[:space:]]*=[[:space:]]*['\"]${EXPECTED_GAUSSDB_INTEGRATION_VERSION}['\"]$" \
    <<<"$version_source" ||
    die "CORE_SHA does not declare $GAUSSDB_INTEGRATION_NAME $EXPECTED_GAUSSDB_INTEGRATION_VERSION"

  log "installing pinned pure-Python $GAUSSDB_INTEGRATION_NAME wheel over the Omnibus integration"
  env -i \
    HOME=/nonexistent \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/bin:/bin \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$python" -I -B -m pip install \
      --no-index \
      --no-deps \
      --force-reinstall \
      --no-cache-dir \
      "$wheel" >/dev/null || die "offline $GAUSSDB_INTEGRATION_NAME wheel install failed"
}

verify_gaussdb() {
  local root=$1
  local python="$root/embedded/bin/python3"
  local output module_relative dist_relative imported_version dist_version

  [[ -x $python ]] || die "embedded Python is missing from $root"
  output=$(
    env -i \
      HOME=/nonexistent \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH=/usr/bin:/bin \
      PYTHONDONTWRITEBYTECODE=1 \
      "$python" -I -B - "$root" <<'PYEOF'
from importlib import metadata
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
import datadog_checks.gaussdb as gaussdb
from datadog_checks.gaussdb import GaussDb  # noqa: F401

module_path = Path(gaussdb.__file__).resolve()
normalize = lambda value: value.lower().replace("_", "-").replace(".", "-")
distributions = [
    distribution
    for distribution in metadata.distributions()
    if normalize(distribution.metadata.get("Name", "")) == "datadog-gaussdb"
]
if len(distributions) != 1:
    raise SystemExit(f"expected one datadog-gaussdb distribution, found {len(distributions)}")
distribution = distributions[0]
distribution_path = Path(distribution._path).resolve()
version = gaussdb.__version__
distribution_version = distribution.version

for label, path in (("module", module_path), ("distribution", distribution_path)):
    try:
        path.relative_to(root)
    except ValueError as error:
        raise SystemExit(f"gaussdb {label} resolved outside runtime: {path}") from error
if version != distribution_version:
    raise SystemExit(
        f"gaussdb package metadata mismatch: import={version}, metadata={distribution_version}"
    )
print(
    "\t".join(
        (
            module_path.relative_to(root).as_posix(),
            distribution_path.relative_to(root).as_posix(),
            version,
            distribution_version,
        )
    )
)
PYEOF
  ) || die "gaussdb import/version validation failed under $root"

  IFS=$'\t' read -r module_relative dist_relative imported_version dist_version <<<"$output"
  [[ -n $module_relative && -n $dist_relative ]] || die "gaussdb validation returned incomplete paths"
  [[ $imported_version == "$dist_version" ]] ||
    die "gaussdb import and distribution metadata versions differ"
  [[ $imported_version == "$EXPECTED_GAUSSDB_INTEGRATION_VERSION" ]] ||
    die "unexpected $GAUSSDB_INTEGRATION_NAME integration version: $imported_version (expected $EXPECTED_GAUSSDB_INTEGRATION_VERSION)"
  printf '%s\t%s\t%s\t%s\n' \
    "$module_relative" "$dist_relative" "$imported_version" "$dist_version"
}

write_gaussdb_provenance() {
  local root=$1 output=$2 information
  local module_relative dist_relative imported_version dist_version

  information=$(verify_gaussdb "$root")
  IFS=$'\t' read -r module_relative dist_relative imported_version dist_version <<<"$information"
  printf '%s\n' \
    "integration_name=$GAUSSDB_INTEGRATION_NAME" \
    "integration_version=$imported_version" \
    "integration_source_git_sha=$core_sha" \
    "wheel_rel=$GAUSSDB_WHEEL_REL" \
    "wheel_sha256=$GAUSSDB_WHEEL_SHA256" \
    "module_path=./$module_relative" \
    "distribution_path=./$dist_relative" \
    "import_version=$imported_version" \
    "distribution_version=$dist_version" \
    >"$output"
}

collect_agent_version_evidence() {
  local root=$1 expected=$2
  local agent_binary="$root/bin/agent/agent"
  local manifest_text="$root/version-manifest.txt"
  local manifest_json="$root/version-manifest.json"
  local version_output compiled_version expected_version_prefix
  local manifest_header_version manifest_component_version manifest_json_version
  local binary_sha256 version_output_sha256 manifest_text_sha256 manifest_json_sha256

  [[ -f $agent_binary && ! -L $agent_binary && -x $agent_binary ]] ||
    die "Agent version probe binary is missing, linked, or not executable under $root"
  [[ -f $manifest_text && ! -L $manifest_text ]] ||
    die "Omnibus version-manifest.txt is missing or is a symlink under $root"
  [[ -f $manifest_json && ! -L $manifest_json ]] ||
    die "Omnibus version-manifest.json is missing or is a symlink under $root"
  require_path_within 'Agent version probe binary' "$root" "$agent_binary" >/dev/null
  require_path_within 'Omnibus version-manifest.txt' "$root" "$manifest_text" >/dev/null
  require_path_within 'Omnibus version-manifest.json' "$root" "$manifest_json" >/dev/null
  (($(stat -c %s -- "$manifest_text") <= 16777216)) ||
    die "Omnibus version-manifest.txt is unexpectedly large"
  (($(stat -c %s -- "$manifest_json") <= 16777216)) ||
    die "Omnibus version-manifest.json is unexpectedly large"

  version_output=$(
    env -i \
      HOME=/nonexistent \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="$root/embedded/bin:/usr/bin:/bin" \
      "$agent_binary" version 2>&1
  ) || die "compiled Agent version probe failed under $root"
  reject_control_characters 'compiled Agent version output' "$version_output"
  case "$version_output" in
    'Agent '*) ;;
    *) die "compiled Agent version output has an unexpected format: $version_output" ;;
  esac
  compiled_version=${version_output#Agent }
  compiled_version=${compiled_version%% *}
  [[ $compiled_version == "$expected" ]] ||
    die "compiled Agent version is $compiled_version, expected release VERSION $expected"
  expected_version_prefix="Agent $expected - Commit: ${agent_sha:0:10} - Serialization version: "
  case "$version_output" in
    "$expected_version_prefix"*' - Go version: go'*) ;;
    *) die "compiled Agent version output does not bind the exact release VERSION: $version_output" ;;
  esac

  manifest_header_version=$(
    awk 'NR == 1 && NF == 2 && $1 == "agent" { print $2; found++ }
      END { exit(found == 1 ? 0 : 1) }' "$manifest_text"
  ) || die "version-manifest.txt lacks one exact agent header"
  manifest_component_version=$(
    awk '$1 == "datadog-agent" { if (NF < 2) exit 2; value=$2; found++ }
      END { if (found == 1) print value; else exit 1 }' "$manifest_text"
  ) || die "version-manifest.txt lacks one exact datadog-agent component row"
  [[ $manifest_header_version == "$expected" ]] ||
    die "version-manifest.txt agent header is $manifest_header_version, expected $expected"
  [[ $manifest_component_version == "$expected" ]] ||
    die "version-manifest.txt datadog-agent component is $manifest_component_version, expected $expected"

  manifest_json_version=$(env -i \
    HOME=/nonexistent \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/bin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    "$root/embedded/bin/python3" -I -B - "$manifest_json" "$expected" <<'PYEOF'
import json
from pathlib import Path
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


path = Path(sys.argv[1])
expected = sys.argv[2]
try:
    document = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid Omnibus version manifest: {error}") from error
if type(document) is not dict or document.get("manifest_format") != 2:
    raise SystemExit("Omnibus version manifest must be a format-2 object")
build_version = document.get("build_version")
if build_version != expected:
    raise SystemExit(
        f"Omnibus version manifest build_version is {build_version!r}, expected {expected!r}"
    )
software = document.get("software")
if type(software) is not dict:
    raise SystemExit("Omnibus version manifest software must be an object")
entry = software.get("datadog-agent")
if type(entry) is not dict or entry.get("source_type") != "path":
    raise SystemExit("Omnibus version manifest lacks the datadog-agent path entry")
locked_source = entry.get("locked_source")
if type(locked_source) is not dict or locked_source.get("path") != "..":
    raise SystemExit("Omnibus datadog-agent source path is not the expected project root")
print(build_version)
PYEOF
  ) || die "Omnibus version-manifest.json does not bind the exact release VERSION"
  [[ $manifest_json_version == "$expected" ]] ||
    die "version-manifest.json parser returned $manifest_json_version, expected $expected"

  binary_sha256=$(sha256sum -- "$agent_binary" | awk '{ print $1 }')
  version_output_sha256=$(printf '%s\n' "$version_output" | sha256sum | awk '{ print $1 }')
  manifest_text_sha256=$(sha256sum -- "$manifest_text" | awk '{ print $1 }')
  manifest_json_sha256=$(sha256sum -- "$manifest_json" | awk '{ print $1 }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$compiled_version" "$manifest_header_version" "$manifest_component_version" "$manifest_json_version" \
    "$binary_sha256" "$version_output_sha256" "$manifest_text_sha256" \
    "$manifest_json_sha256" "$version_output"
}

write_agent_version_provenance() {
  local root=$1 expected=$2 output=$3 information
  local compiled_version manifest_header_version manifest_component_version manifest_json_version
  local binary_sha256 version_output_sha256 manifest_text_sha256 manifest_json_sha256 version_output

  information=$(collect_agent_version_evidence "$root" "$expected")
  IFS=$'\t' read -r \
    compiled_version manifest_header_version manifest_component_version manifest_json_version \
    binary_sha256 version_output_sha256 manifest_text_sha256 manifest_json_sha256 version_output \
    <<<"$information"
  printf '%s\n' \
    "compiled_version=$compiled_version" \
    "manifest_header_version=$manifest_header_version" \
    "manifest_component_version=$manifest_component_version" \
    "manifest_json_version=$manifest_json_version" \
    'binary_path=./bin/agent/agent' \
    "binary_sha256=$binary_sha256" \
    "version_output=$version_output" \
    "version_output_sha256=$version_output_sha256" \
    'version_manifest_text_path=./version-manifest.txt' \
    "version_manifest_text_sha256=$manifest_text_sha256" \
    'version_manifest_json_path=./version-manifest.json' \
    "version_manifest_json_sha256=$manifest_json_sha256" \
    >"$output"
}

collect_system_probe_version_evidence() {
  local root=$1 expected=$2
  local system_probe_binary="$root/embedded/bin/system-probe"
  local version_output compiled_version expected_version_prefix
  local binary_sha256 version_output_sha256

  [[ -f $system_probe_binary && ! -L $system_probe_binary && -x $system_probe_binary ]] ||
    die "system-probe version probe binary is missing, linked, or not executable under $root"
  require_path_within 'system-probe version probe binary' "$root" "$system_probe_binary" >/dev/null

  version_output=$(
    env -i \
      HOME=/nonexistent \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="$root/embedded/bin:/usr/bin:/bin" \
      "$system_probe_binary" version 2>&1
  ) || die "compiled system-probe version probe failed under $root"
  reject_control_characters 'compiled system-probe version output' "$version_output"
  case "$version_output" in
    'System Probe '*) ;;
    *) die "compiled system-probe version output has an unexpected format: $version_output" ;;
  esac
  compiled_version=${version_output#System Probe }
  compiled_version=${compiled_version%% *}
  [[ $compiled_version == "$expected" ]] ||
    die "compiled system-probe version is $compiled_version, expected release VERSION $expected"
  expected_version_prefix="System Probe $expected - Commit: ${agent_sha:0:10} - Serialization version: "
  case "$version_output" in
    "$expected_version_prefix"*' - Go version: go'*) ;;
    *) die "compiled system-probe version output does not bind release VERSION and AGENT_SHA: $version_output" ;;
  esac

  binary_sha256=$(sha256sum -- "$system_probe_binary" | awk '{ print $1 }')
  version_output_sha256=$(printf '%s\n' "$version_output" | sha256sum | awk '{ print $1 }')
  printf '%s\t%s\t%s\t%s\n' \
    "$compiled_version" "$binary_sha256" "$version_output_sha256" "$version_output"
}

write_system_probe_version_provenance() {
  local root=$1 expected=$2 output=$3 information
  local compiled_version binary_sha256 version_output_sha256 version_output

  information=$(collect_system_probe_version_evidence "$root" "$expected")
  IFS=$'\t' read -r \
    compiled_version binary_sha256 version_output_sha256 version_output \
    <<<"$information"
  printf '%s\n' \
    "compiled_version=$compiled_version" \
    "compiled_commit=${agent_sha:0:10}" \
    "agent_git_sha=$agent_sha" \
    'binary_path=./embedded/bin/system-probe' \
    "binary_sha256=$binary_sha256" \
    "version_output=$version_output" \
    "version_output_sha256=$version_output_sha256" \
    >"$output"
}

verify_adp_version_manifest() {
  local root=$1
  local python="$root/embedded/bin/python3"
  local version_manifest="$root/version-manifest.json"
  local output parsed_version manifest_sha256

  [[ -x $python ]] || die "embedded Python is missing while validating ADP under $root"
  [[ -f $version_manifest && ! -L $version_manifest ]] ||
    die "Omnibus version-manifest.json is missing or is a symlink under $root"
  require_path_within 'Omnibus version-manifest.json' "$root" "$version_manifest" >/dev/null
  (($(stat -c %s -- "$version_manifest") <= 16777216)) ||
    die "Omnibus version-manifest.json is unexpectedly large"

  output=$(
    env -i \
      HOME=/nonexistent \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH=/usr/bin:/bin \
      PYTHONDONTWRITEBYTECODE=1 \
      "$python" -I -B - \
        "$version_manifest" "$ADP_SOFTWARE_NAME" "$ADP_VERSION" "$ADP_INPUT_SHA256" <<'PYEOF'
import hashlib
import json
from pathlib import Path
import sys

manifest_path = Path(sys.argv[1])
software_name = sys.argv[2]
expected_version = sys.argv[3]
expected_source_sha256 = sys.argv[4]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def reject_nonfinite_number(value):
    raise ValueError(f"non-finite JSON number: {value}")


payload = manifest_path.read_bytes()
try:
    document = json.loads(
        payload.decode("utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_nonfinite_number,
    )
except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid Omnibus version manifest: {error}") from error

if type(document) is not dict:
    raise SystemExit("Omnibus version manifest root must be an object")
manifest_format = document.get("manifest_format")
if type(manifest_format) is not int or manifest_format != 2:
    raise SystemExit("Omnibus version manifest manifest_format must be integer 2")
software = document.get("software")
if type(software) is not dict:
    raise SystemExit("Omnibus version manifest software must be an object")
entry = software.get(software_name)
if type(entry) is not dict:
    raise SystemExit(f"missing object software/{software_name}")
locked_version = entry.get("locked_version")
if type(locked_version) is not str:
    raise SystemExit(f"software/{software_name}/locked_version must be a string")
if locked_version != expected_version:
    raise SystemExit(
        f"software/{software_name}/locked_version is {locked_version!r}, "
        f"expected {expected_version!r}"
    )
if entry.get("source_type") != "url":
    raise SystemExit(f"software/{software_name}/source_type must be 'url'")
locked_source = entry.get("locked_source")
if type(locked_source) is not dict:
    raise SystemExit(f"software/{software_name}/locked_source must be an object")
source_sha256 = locked_source.get("sha256")
if type(source_sha256) is not str:
    raise SystemExit(f"software/{software_name}/locked_source/sha256 must be a string")
if source_sha256 != expected_source_sha256:
    raise SystemExit(
        f"software/{software_name}/locked_source/sha256 is {source_sha256!r}, "
        f"expected {expected_source_sha256!r}"
    )
print(f"{locked_version}\t{hashlib.sha256(payload).hexdigest()}")
PYEOF
  ) || die "ADP Omnibus version-manifest.json validation failed under $root"

  IFS=$'\t' read -r parsed_version manifest_sha256 <<<"$output"
  [[ $parsed_version == "$ADP_VERSION" ]] || die "ADP parser returned an unexpected version"
  [[ $manifest_sha256 =~ ^[0-9a-f]{64}$ ]] || die "ADP parser returned an invalid manifest SHA-256"
  printf '%s\t%s\n' "$parsed_version" "$manifest_sha256"
}

verify_adp_input_handoff() {
  local cache_root input_manifest input_tar resolved status

  cache_root=$(canonical_existing_dir AGENT_CACHE_ROOT /home/dbdog/cache/dbdog-agent)
  [[ $cache_root == /home/dbdog/cache/dbdog-agent ]] ||
    die "agent cache root must resolve exactly to /home/dbdog/cache/dbdog-agent"
  input_manifest="$cache_root/$manifest_rel/INPUTS.sha256"
  input_tar="$cache_root/$ADP_INPUT_REL"
  [[ -f $input_manifest && ! -L $input_manifest ]] || die "sealed v7 INPUTS.sha256 is missing"
  [[ -f $input_tar && ! -L $input_tar ]] || die "sealed ADP input tar is missing"
  require_path_within 'v7 INPUTS.sha256' "$cache_root" "$input_manifest" >/dev/null
  resolved=$(require_path_within 'ADP input tar' "$cache_root" "$input_tar")
  [[ $resolved == "$input_tar" ]] || die "ADP input tar resolves through an unexpected path"

  status=$(awk -v path="$ADP_INPUT_REL" -v hash="$ADP_INPUT_SHA256" '
    $2 == path {
      path_count++
      if ($1 == hash) {
        exact_count++
      }
    }
    END { printf "%d:%d", path_count + 0, exact_count + 0 }
  ' "$input_manifest")
  [[ $status == 1:1 ]] ||
    die "v7 INPUTS.sha256 does not uniquely bind $ADP_INPUT_REL to $ADP_INPUT_SHA256"
  (
    cd "$cache_root"
    printf '%s  %s\n' "$ADP_INPUT_SHA256" "$ADP_INPUT_REL" | sha256sum -c -
  ) >/dev/null
  sha256sum -- "$input_manifest" | awk '{ print $1 }'
}

write_adp_provenance() {
  local root=$1
  local output=$2
  local information parsed_version version_manifest_sha256 adp_binary adp_binary_sha256

  information=$(verify_adp_version_manifest "$root")
  IFS=$'\t' read -r parsed_version version_manifest_sha256 <<<"$information"
  adp_binary="$root/embedded/bin/agent-data-plane"
  [[ -f $adp_binary && -x $adp_binary ]] || die "ADP runtime binary is missing under $root"
  require_path_within 'ADP runtime binary' "$root" "$adp_binary" >/dev/null
  adp_binary_sha256=$(sha256sum -- "$adp_binary" | awk '{ print $1 }')
  printf '%s\n' \
    "software_name=$ADP_SOFTWARE_NAME" \
    "version=$parsed_version" \
    'binary_path=./embedded/bin/agent-data-plane' \
    "binary_sha256=$adp_binary_sha256" \
    "input_tar_rel=$ADP_INPUT_REL" \
    "input_tar_sha256=$ADP_INPUT_SHA256" \
    'version_manifest_path=./version-manifest.json' \
    "version_manifest_sha256=$version_manifest_sha256" \
    "v7_inputs_manifest_rel=$manifest_rel/INPUTS.sha256" \
    "v7_inputs_manifest_sha256=$adp_inputs_manifest_sha256" \
    >"$output"
}

clean_runtime_tree() {
  local state_dir

  find "$install_dir" -depth -type d \
    \( -name __pycache__ -o -name .debug \) \
    -exec rm -rf -- {} +
  find "$install_dir" -type f \
    \( -name '*.pyc' -o -name '*.pyo' -o -name '*.debug' -o -name '*.debug.zip' \
    -o -name '.DS_Store' \) \
    -delete
  rm -f -- \
    "$python_site/datadog_checks/postgres/schemas.py.pre-dbdog-schema-recommendation-fields"

  for state_dir in run log logs tmp; do
    if [[ -L $install_dir/$state_dir ]]; then
      die "runtime-state path is a symlink: $state_dir"
    fi
    if [[ -d $install_dir/$state_dir ]]; then
      find "$install_dir/$state_dir" -mindepth 1 -depth -delete
    fi
  done
}

create_archive() {
  local destination=$1

  tar \
    --sort=name \
    --format=gnu \
    --mtime="@$source_date_epoch" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --no-acls \
    --no-selinux \
    --no-xattrs \
    -C "$install_dir" \
    -cf - . |
    gzip -n -9 >"$destination"
}

verify_archive() {
  local archive=$1
  local verify_root=$2
  local list_file=$3
  local regular_manifest=$4
  local symlink_manifest=$5
  local glibc_report=$6
  local linkage_report=$7
  local adp_report=$8
  local agent_version_report=$9
  local system_probe_version_report=${10}
  local gaussdb_report=${11}
  local member

  tar --quoting-style=literal -tzf "$archive" >"$list_file"
  [[ -s $list_file ]] || die "archive is empty"
  while IFS= read -r member; do
    case "$member" in
      . | ./) ;;
      ./*)
        case "/${member#./}/" in
          */../*) die "archive contains a parent traversal: $member" ;;
        esac
        ;;
      *) die "archive member is not relative to the install root: $member" ;;
    esac
  done <"$list_file"
  grep -Fxq './.install_root' "$list_file" || die "archive lacks root-level .install_root"
  grep -Fxq './provenance/runtime.sha256' "$list_file" ||
    die "archive lacks the runtime SHA-256 manifest"
  if grep -Eq '^\./(opt/)?dbdog-agent/' "$list_file"; then
    die "archive has an unwanted dbdog-agent wrapper directory"
  fi

  mkdir -m 0700 "$verify_root"
  # The archive deliberately contains a `./` entry with the install root's
  # mode.  Preserve the pre-created root-private verification directory
  # instead of letting tar relax it to the packaged runtime mode.
  tar --no-same-owner --no-overwrite-dir -xzf "$archive" -C "$verify_root"
  require_root_private_dir \
    'archive verification root' "$verify_root" "$verify_root"
  validate_tree_names_and_types "$verify_root"
  verify_runtime_exclusions "$verify_root"
  [[ -f $verify_root/.install_root ]] || die "extracted archive lacks .install_root"

  (
    cd "$verify_root"
    sha256sum -c provenance/runtime.sha256
  ) >/dev/null
  write_regular_file_manifest "$verify_root" "$regular_manifest"
  cmp -s -- "$verify_root/provenance/runtime.sha256" "$regular_manifest" ||
    die "extracted regular-file inventory differs from packaged manifest"
  write_symlink_manifest "$verify_root" "$symlink_manifest"
  cmp -s -- "$verify_root/provenance/symlinks.tsv" "$symlink_manifest" ||
    die "extracted symlink inventory differs from packaged manifest"

  verify_primary_binaries "$verify_root"
  write_primary_linkage_report "$verify_root" "$linkage_report"
  cmp -s -- "$verify_root/provenance/primary-elf-linkage.tsv" "$linkage_report" ||
    die "extracted primary ELF linkage report differs from packaged report"
  write_adp_provenance "$verify_root" "$adp_report"
  cmp -s -- "$verify_root/provenance/agent-data-plane.txt" "$adp_report" ||
    die "extracted ADP evidence differs from packaged provenance"
  write_agent_version_provenance "$verify_root" "$version" "$agent_version_report"
  cmp -s -- "$verify_root/provenance/agent-version.txt" "$agent_version_report" ||
    die "extracted Agent version evidence differs from packaged provenance"
  write_system_probe_version_provenance "$verify_root" "$version" "$system_probe_version_report"
  cmp -s -- "$verify_root/provenance/system-probe-version.txt" "$system_probe_version_report" ||
    die "extracted system-probe version evidence differs from packaged provenance"
  write_gaussdb_provenance "$verify_root" "$gaussdb_report"
  cmp -s -- "$verify_root/provenance/gaussdb.txt" "$gaussdb_report" ||
    die "extracted GaussDB integration evidence differs from packaged provenance"
  write_glibc_report "$verify_root" "$glibc_report"
  cmp -s -- "$verify_root/provenance/glibc-requirements.tsv" "$glibc_report" ||
    die "extracted GLIBC report differs from packaged report"
  verify_no_path_leaks "$verify_root"
  grep -Fq 'DBDOG_DISABLE_DBM_HEALTH' \
    "$verify_root/embedded/lib/python3.13/site-packages/datadog_checks/base/utils/db/health.py" ||
    die "extracted dbm-health patch marker is absent"
  grep -Fq 'SCHEMA_RECOMMENDATION_FIELDS_ENV' \
    "$verify_root/embedded/lib/python3.13/site-packages/datadog_checks/postgres/schemas.py" ||
    die "extracted PostgreSQL patch marker is absent"
}

require_root_private_dir() {
  local label=$1 path=$2 expected=$3 resolved

  [[ -d $path && ! -L $path ]] || die "$label is not a real directory: $path"
  resolved=$(readlink -e -- "$path") || die "cannot resolve $label: $path"
  [[ $resolved == "$expected" ]] ||
    die "$label resolved unexpectedly: $path -> $resolved (expected $expected)"
  [[ $(stat -c '%u:%g:%a' -- "$path") == 0:0:700 ]] ||
    die "$label must be root:root mode 0700: $path"
}

remove_private_work_tree() {
  local label=$1 path=$2 parent=$3 expected_basename_regex=$4 resolved basename

  [[ $(dirname -- "$path") == "$parent" ]] ||
    die "refusing to remove $label outside its exact parent: $path"
  basename=${path##*/}
  [[ $basename =~ $expected_basename_regex ]] ||
    die "refusing to remove unexpected $label basename: $path"
  [[ -d $path && ! -L $path ]] || die "$label is not a real directory: $path"
  resolved=$(readlink -e -- "$path") || die "cannot resolve $label: $path"
  [[ $resolved == "$path" ]] || die "$label resolves unexpectedly: $path -> $resolved"
  [[ $(stat -c '%u:%g:%a' -- "$path") == 0:0:700 ]] ||
    die "$label must be root:root mode 0700 before removal: $path"
  [[ $(stat -c '%d' -- "$path") == "$(stat -c '%d' -- "$parent")" ]] ||
    die "$label is on an unexpected filesystem: $path"
  rm -rf --one-file-system -- "$path"
  [[ ! -e $path && ! -L $path ]] || die "could not remove $label: $path"
}

remove_private_work_file() {
  local label=$1 path=$2 work_root=$3 resolved

  case "$path" in
    "$work_root"/*) ;;
    *) die "refusing to remove unexpected $label path: $path" ;;
  esac
  [[ -f $path && ! -L $path ]] || die "$label is not a real regular file: $path"
  resolved=$(readlink -e -- "$path") || die "cannot resolve $label: $path"
  [[ $resolved == "$path" ]] || die "$label resolves unexpectedly: $path -> $resolved"
  [[ $(stat -c '%u:%g' -- "$path") == 0:0 ]] ||
    die "$label must be root-owned before removal: $path"
  rm -f -- "$path"
  [[ ! -e $path && ! -L $path ]] || die "could not remove $label: $path"
}

publish_archive_and_sidecar_atomically() {
  local source_archive=$1 destination_dir=$2 destination_name=$3
  local expected_sha256=$4 expected_size=$5 expected_device=$6 result

  [[ $destination_name != */* && -n $destination_name ]] ||
    die "archive destination must be one basename: $destination_name"
  [[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    die "archive publication SHA-256 is invalid: $expected_sha256"
  [[ $expected_size =~ ^[1-9][0-9]*$ ]] ||
    die "archive publication size is invalid: $expected_size"
  [[ $expected_device =~ ^[0-9]+$ ]] ||
    die "archive publication destination device is invalid: $expected_device"

  result=$(
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      "$SYSTEM_PYTHON" -I -B - \
      "$source_archive" "$destination_dir" "$destination_name" \
      "$expected_sha256" "$expected_size" "$expected_device" <<'PYEOF'
import hashlib
import os
import re
import stat
import sys


def fail(message):
    raise SystemExit("atomic publication error: " + message)


def read_and_hash(fd):
    digest = hashlib.sha256()
    size = 0
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
        size += len(block)
    return size, digest.hexdigest()


def write_all(fd, data):
    offset = 0
    while offset < len(data):
        written = os.write(fd, data[offset:])
        if written <= 0:
            fail("short write while creating destination-local staging inode")
        offset += written


def open_existing(dir_fd, name):
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        return os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail("cannot safely open existing {!r}: {}".format(name, exc))


def verify_open_file(fd, name, expected_size, expected_sha256):
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode):
        fail("destination {!r} is not a regular file".format(name))
    if metadata.st_uid != 0 or metadata.st_gid != 0:
        fail("destination {!r} is not root:root".format(name))
    if stat.S_IMODE(metadata.st_mode) != 0o644:
        fail("destination {!r} is not mode 0644".format(name))
    if metadata.st_size != expected_size:
        fail("destination {!r} has unexpected size".format(name))
    os.lseek(fd, 0, os.SEEK_SET)
    actual_size, actual_sha256 = read_and_hash(fd)
    if actual_size != expected_size or actual_sha256 != expected_sha256:
        fail("destination {!r} has unexpected content".format(name))
    return metadata


def stage_name(prefix, attempt):
    entropy = hashlib.sha256(os.urandom(32) + str(attempt).encode("ascii")).hexdigest()[:12]
    return prefix + entropy


def safe_unlink_stage(dir_fd, name, identity):
    try:
        current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(current.st_mode):
        fail("staging entry {!r} changed type before cleanup".format(name))
    if current.st_uid != 0 or current.st_gid != 0:
        fail("staging entry {!r} changed owner before cleanup".format(name))
    if (current.st_dev, current.st_ino) != identity:
        fail("staging entry {!r} changed inode before cleanup".format(name))
    os.unlink(name, dir_fd=dir_fd)


def create_stage(dir_fd, prefix):
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    for attempt in range(128):
        name = stage_name(prefix, attempt)
        try:
            fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
            metadata = os.fstat(fd)
            return name, fd, (metadata.st_dev, metadata.st_ino)
        except FileExistsError:
            continue
    fail("cannot allocate a unique destination-local staging inode")


def publish_payload(dir_fd, name, prefix, expected_size, expected_sha256, writer):
    existing_fd = open_existing(dir_fd, name)
    if existing_fd is not None:
        try:
            verify_open_file(existing_fd, name, expected_size, expected_sha256)
        finally:
            os.close(existing_fd)
        return "reused"

    stage = None
    stage_fd = None
    stage_identity = None
    try:
        stage, stage_fd, stage_identity = create_stage(dir_fd, prefix)
        digest = hashlib.sha256()
        written = writer(stage_fd, digest)
        if written != expected_size or digest.hexdigest() != expected_sha256:
            fail("source bytes differ from the pinned publication authority")
        os.fchown(stage_fd, 0, 0)
        os.fchmod(stage_fd, 0o644)
        os.fsync(stage_fd)
        os.lseek(stage_fd, 0, os.SEEK_SET)
        verified_size, verified_sha256 = read_and_hash(stage_fd)
        if verified_size != expected_size or verified_sha256 != expected_sha256:
            fail("destination-local staging bytes changed after fsync")
        current = os.stat(stage, dir_fd=dir_fd, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode):
            fail("destination-local staging path changed type")
        if (current.st_dev, current.st_ino) != stage_identity:
            fail("destination-local staging path changed inode")
        if current.st_uid != 0 or current.st_gid != 0 or stat.S_IMODE(current.st_mode) != 0o644:
            fail("destination-local staging metadata changed")
        try:
            os.link(
                stage,
                name,
                src_dir_fd=dir_fd,
                dst_dir_fd=dir_fd,
                follow_symlinks=False,
            )
        except FileExistsError:
            existing_fd = open_existing(dir_fd, name)
            if existing_fd is None:
                fail("destination disappeared after a no-clobber link collision")
            try:
                final_metadata = verify_open_file(
                    existing_fd, name, expected_size, expected_sha256
                )
            finally:
                os.close(existing_fd)
            safe_unlink_stage(dir_fd, stage, stage_identity)
            stage = None
            os.fsync(dir_fd)
            return "reused"
        else:
            existing_fd = open_existing(dir_fd, name)
            if existing_fd is None:
                fail("destination disappeared after atomic no-clobber link")
            try:
                final_metadata = verify_open_file(
                    existing_fd, name, expected_size, expected_sha256
                )
            finally:
                os.close(existing_fd)
        if (final_metadata.st_dev, final_metadata.st_ino) != stage_identity:
            fail("published destination is not the verified staging inode")
        os.fsync(dir_fd)
        safe_unlink_stage(dir_fd, stage, stage_identity)
        stage = None
        os.fsync(dir_fd)
        return "published"
    finally:
        if stage_fd is not None:
            os.close(stage_fd)
        if stage is not None:
            safe_unlink_stage(dir_fd, stage, stage_identity)
            os.fsync(dir_fd)


def main():
    if len(sys.argv) != 7:
        fail("internal argument count mismatch")
    source_path, output_path, archive_name, archive_sha256, size_text, device_text = sys.argv[1:]
    if not archive_name or "/" in archive_name or "\\" in archive_name:
        fail("archive name is not one basename")
    if not re.fullmatch(r"[0-9a-f]{64}", archive_sha256):
        fail("archive SHA-256 is invalid")
    try:
        archive_size = int(size_text, 10)
    except ValueError:
        fail("archive size is not an integer")
    if archive_size <= 0 or str(archive_size) != size_text:
        fail("archive size is not canonical")
    try:
        expected_device = int(device_text, 10)
    except ValueError:
        fail("OUTPUT_DIR device is not an integer")
    if expected_device < 0 or str(expected_device) != device_text:
        fail("OUTPUT_DIR device is not canonical")

    source_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    source_fd = os.open(source_path, source_flags)
    try:
        source_metadata = os.fstat(source_fd)
        if not stat.S_ISREG(source_metadata.st_mode):
            fail("root-private archive source is not a regular file")
        if source_metadata.st_uid != 0 or source_metadata.st_gid != 0:
            fail("root-private archive source is not root:root")
        if stat.S_IMODE(source_metadata.st_mode) != 0o644:
            fail("root-private archive source is not mode 0644")
        if source_metadata.st_size != archive_size:
            fail("root-private archive source has unexpected size")

        dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        dir_fd = os.open(output_path, dir_flags)
        try:
            directory_metadata = os.fstat(dir_fd)
            if directory_metadata.st_uid != 0 or directory_metadata.st_gid != 0:
                fail("OUTPUT_DIR is not root:root")
            if stat.S_IMODE(directory_metadata.st_mode) != 0o755:
                fail("OUTPUT_DIR is not mode 0755")
            if directory_metadata.st_dev != expected_device:
                fail("OUTPUT_DIR moved to an unexpected filesystem")
            directory_identity = (directory_metadata.st_dev, directory_metadata.st_ino)

            archive_stage_prefix = ".{}.archive-stage.".format(archive_name)
            sidecar_name = archive_name + ".sha256"
            sidecar_stage_prefix = ".{}.sha256-stage.".format(archive_name)
            stage_pattern = re.compile(
                r"^(?:{}|{})[0-9a-f]{{12}}$".format(
                    re.escape(archive_stage_prefix), re.escape(sidecar_stage_prefix)
                )
            )
            allowed = {archive_name, sidecar_name}
            for entry in os.listdir(dir_fd):
                if entry in allowed:
                    continue
                if entry.startswith(archive_stage_prefix) or entry.startswith(sidecar_stage_prefix):
                    if not stage_pattern.fullmatch(entry):
                        fail("malformed stale staging entry: {!r}".format(entry))
                    stale_fd = open_existing(dir_fd, entry)
                    if stale_fd is None:
                        fail("stale staging entry disappeared during validation")
                    try:
                        stale_metadata = os.fstat(stale_fd)
                        if not stat.S_ISREG(stale_metadata.st_mode):
                            fail("stale staging entry is not a regular file")
                        if stale_metadata.st_uid != 0 or stale_metadata.st_gid != 0:
                            fail("stale staging entry is not root:root")
                        if stat.S_IMODE(stale_metadata.st_mode) not in (0o600, 0o644):
                            fail("stale staging entry has an unexpected mode")
                        stale_identity = (stale_metadata.st_dev, stale_metadata.st_ino)
                    finally:
                        os.close(stale_fd)
                    safe_unlink_stage(dir_fd, entry, stale_identity)
                    continue
                fail("unexpected OUTPUT_DIR entry: {!r}".format(entry))
            os.fsync(dir_fd)

            archive_fd = open_existing(dir_fd, archive_name)
            sidecar_fd = open_existing(dir_fd, sidecar_name)
            try:
                if archive_fd is None and sidecar_fd is not None:
                    fail("checksum exists without its canonical archive")
            finally:
                if archive_fd is not None:
                    os.close(archive_fd)
                if sidecar_fd is not None:
                    os.close(sidecar_fd)

            def archive_writer(stage_fd, digest):
                os.lseek(source_fd, 0, os.SEEK_SET)
                total = 0
                while True:
                    block = os.read(source_fd, 1024 * 1024)
                    if not block:
                        break
                    write_all(stage_fd, block)
                    digest.update(block)
                    total += len(block)
                return total

            archive_result = publish_payload(
                dir_fd,
                archive_name,
                archive_stage_prefix,
                archive_size,
                archive_sha256,
                archive_writer,
            )

            sidecar_bytes = (archive_sha256 + "  " + archive_name + "\n").encode("ascii")
            sidecar_sha256 = hashlib.sha256(sidecar_bytes).hexdigest()

            def sidecar_writer(stage_fd, digest):
                write_all(stage_fd, sidecar_bytes)
                digest.update(sidecar_bytes)
                return len(sidecar_bytes)

            sidecar_result = publish_payload(
                dir_fd,
                sidecar_name,
                sidecar_stage_prefix,
                len(sidecar_bytes),
                sidecar_sha256,
                sidecar_writer,
            )

            path_metadata = os.stat(output_path, follow_symlinks=False)
            if not stat.S_ISDIR(path_metadata.st_mode):
                fail("OUTPUT_DIR path changed type during publication")
            if (path_metadata.st_dev, path_metadata.st_ino) != directory_identity:
                fail("OUTPUT_DIR path changed inode during publication")
            print("archive={} sidecar={}".format(archive_result, sidecar_result))
        finally:
            os.close(dir_fd)
    finally:
        os.close(source_fd)


main()
PYEOF
  ) || die "destination-local archive publication failed"
  case "$result" in
    'archive=published sidecar=published' | \
    'archive=published sidecar=reused' | \
    'archive=reused sidecar=published' | \
    'archive=reused sidecar=reused')
      log "atomic publication completed: $result"
      ;;
    *) die "atomic publication helper returned unexpected output: $result" ;;
  esac
}

read_filesystem_capacity() {
  local path=$1 output available_blocks available_inodes

  output=$(df -B1 --output=avail,iavail -- "$path" | awk '
    NR == 2 { print $1, $2; rows++ }
    END { exit(rows == 1 ? 0 : 1) }
  ') || die "cannot read filesystem capacity for $path"
  read -r available_blocks available_inodes <<<"$output"
  [[ $available_blocks =~ ^[0-9]+$ && $available_inodes =~ ^[0-9]+$ ]] ||
    die "filesystem capacity is not numeric for $path: $output"
  printf '%s\t%s\n' "$available_blocks" "$available_inodes"
}

preflight_bulk_workspace() {
  local runtime=$1 scratch=$2 destination=$3
  local allocated apparent inode_count payload archive_bound extract_bound peak
  local reserve required_blocks required_inodes available_blocks available_inodes
  local capacity available_mib required_mib runtime_device scratch_device destination_device build_device
  local destination_required_blocks destination_required_inodes

  runtime_device=$(stat -c '%d' -- "$runtime")
  scratch_device=$(stat -c '%d' -- "$scratch")
  destination_device=$(stat -c '%d' -- "$destination")
  build_device=$(stat -c '%d' -- "$build_dir")
  [[ $runtime_device == "$scratch_device" ]] ||
    die "INSTALL_DIR and root-private bulk scratch must share a filesystem: $runtime vs $scratch"
  [[ $destination_device == "$build_device" ]] ||
    die "OUTPUT_DIR and BUILD_DIR must share a filesystem: $destination vs $build_dir"

  allocated=$(du -sxB1 -- "$runtime" | awk 'NR == 1 { print $1; rows++ } END { exit(rows == 1 ? 0 : 1) }') ||
    die "cannot measure allocated runtime bytes: $runtime"
  apparent=$(du --apparent-size -sxB1 -- "$runtime" |
    awk 'NR == 1 { print $1; rows++ } END { exit(rows == 1 ? 0 : 1) }') ||
    die "cannot measure apparent runtime bytes: $runtime"
  inode_count=$(find "$runtime" -xdev -mindepth 1 -printf '1\n' |
    awk 'END { print NR + 0 }')
  [[ $allocated =~ ^[0-9]+$ && $apparent =~ ^[0-9]+$ && $inode_count =~ ^[0-9]+$ ]] ||
    die "runtime size preflight returned non-numeric data"
  ((inode_count > 0)) || die "runtime tree is empty during bulk-space preflight: $runtime"

  if ((apparent > allocated)); then
    payload=$apparent
  else
    payload=$allocated
  fi
  # A gzip stream can be slightly larger than its tar input.  The per-node and
  # fixed allowances cover tar headers, gzip overhead, filesystem metadata, and
  # the small reports written beside the bulk data.
  archive_bound=$((payload + inode_count * 1024 + 64 * 1024 * 1024))
  # payload is at least du's allocated-byte total, which already includes the
  # filesystem block cost of the current small-file population.  Inodes are
  # budgeted independently below, so do not double-count one block per node.
  extract_bound=$((payload + 64 * 1024 * 1024))
  if ((2 * archive_bound > archive_bound + extract_bound)); then
    peak=$((2 * archive_bound))
  else
    peak=$((archive_bound + extract_bound))
  fi
  reserve=$((512 * 1024 * 1024))
  required_blocks=$((peak + reserve))
  required_inodes=$((inode_count + 4096))
  capacity=$(read_filesystem_capacity "$scratch")
  IFS=$'\t' read -r available_blocks available_inodes <<<"$capacity"
  available_mib=$((available_blocks / 1024 / 1024))
  required_mib=$((required_blocks / 1024 / 1024))
  ((available_blocks >= required_blocks)) ||
    die "insufficient persistent bulk workspace before runtime mutation: available=${available_blocks}B (${available_mib}MiB), conservative_required=${required_blocks}B (${required_mib}MiB), runtime_payload=${payload}B, runtime_nodes=$inode_count, reserve=${reserve}B"
  ((available_inodes >= required_inodes)) ||
    die "insufficient persistent bulk-workspace inodes before runtime mutation: available=$available_inodes required=$required_inodes runtime_nodes=$inode_count"

  if [[ $destination_device != "$scratch_device" ]]; then
    destination_required_blocks=$((archive_bound + reserve))
    destination_required_inodes=4096
    capacity=$(read_filesystem_capacity "$destination")
    IFS=$'\t' read -r available_blocks available_inodes <<<"$capacity"
    available_mib=$((available_blocks / 1024 / 1024))
    required_mib=$((destination_required_blocks / 1024 / 1024))
    ((available_blocks >= destination_required_blocks)) ||
      die "insufficient OUTPUT_DIR space before runtime mutation: available=${available_blocks}B (${available_mib}MiB), conservative_required=${destination_required_blocks}B (${required_mib}MiB), archive_bound=${archive_bound}B, reserve=${reserve}B"
    ((available_inodes >= destination_required_inodes)) ||
      die "insufficient OUTPUT_DIR inodes before runtime mutation: available=$available_inodes required=$destination_required_inodes"
    log "OUTPUT_DIR preflight passed: available=${available_mib}MiB required=${required_mib}MiB"
  fi

  bulk_runtime_inode_count=$inode_count
  bulk_archive_bound_bytes=$archive_bound
  bulk_extract_bound_bytes=$extract_bound
  bulk_reserve_bytes=$reserve
  log "root-private bulk workspace preflight passed: required_blocks=${required_blocks}B runtime_nodes=$inode_count"
}

preflight_extraction_space() {
  local scratch=$1 capacity available_blocks available_inodes required_blocks
  local available_mib required_mib required_inodes

  required_blocks=$((bulk_extract_bound_bytes + bulk_reserve_bytes))
  required_inodes=$((bulk_runtime_inode_count + 4096))
  capacity=$(read_filesystem_capacity "$scratch")
  IFS=$'\t' read -r available_blocks available_inodes <<<"$capacity"
  available_mib=$((available_blocks / 1024 / 1024))
  required_mib=$((required_blocks / 1024 / 1024))
  ((available_blocks >= required_blocks)) ||
    die "persistent bulk workspace became too full before archive extraction: available=${available_blocks}B (${available_mib}MiB), required=${required_blocks}B (${required_mib}MiB), reserve=${bulk_reserve_bytes}B"
  ((available_inodes >= required_inodes)) ||
    die "persistent bulk workspace lacks inodes before archive extraction: available=$available_inodes required=$required_inodes"
}

if (($# != 0)); then
  usage
  die "positional arguments are not accepted"
fi

for tool in \
  awk bash basename cat chmod chown cmp df dirname du env find flock git grep gzip head id \
  install ln mkdir mktemp mv readelf readlink rm runuser sed sha256sum sort stat sync tail \
  tar uname; do
  require_tool "$tool"
done
[[ -f $GIT_RUNUSER && ! -L $GIT_RUNUSER && -x $GIT_RUNUSER ]] ||
  die "pinned runuser is not a real executable: $GIT_RUNUSER"
[[ $(readlink -e -- "$GIT_RUNUSER") == "$GIT_RUNUSER" ]] ||
  die "pinned runuser resolves through an unexpected path"
[[ $(stat -c '%u:%g:%a' -- "$GIT_RUNUSER") == 0:0:755 ]] ||
  die "pinned runuser must be root:root mode 0755"
printf '%s  %s\n' "$EXPECTED_GIT_RUNUSER_SHA256" "$GIT_RUNUSER" |
  sha256sum -c - >/dev/null || die "pinned runuser checksum changed"
[[ $(readlink -e -- "$SYSTEM_PYTHON") == "$EXPECTED_SYSTEM_PYTHON_REAL" ]] ||
  die "pinned system Python resolves unexpectedly: $SYSTEM_PYTHON"
[[ -f $EXPECTED_SYSTEM_PYTHON_REAL && ! -L $EXPECTED_SYSTEM_PYTHON_REAL && \
   $(stat -c '%u:%g:%a' -- "$EXPECTED_SYSTEM_PYTHON_REAL") == 0:0:755 ]] ||
  die "pinned system Python must be a root:root mode 0755 regular file"
printf '%s  %s\n' "$EXPECTED_SYSTEM_PYTHON_SHA256" "$EXPECTED_SYSTEM_PYTHON_REAL" |
  sha256sum -c - >/dev/null || die "pinned system Python checksum changed"
tar --version | head -n 1 | grep -Fq 'GNU tar' || die "GNU tar is required"
[[ ${EUID:-$(id -u)} == 0 ]] || die "run this finalization step as root"
[[ $(uname -m) == aarch64 ]] || die "this finalizer must run natively on AArch64"

build_dir_input=${BUILD_DIR:-}
install_dir_input=${INSTALL_DIR:-$PRIVATE_INSTALL_DIR}
version=${VERSION:-}
arch=${ARCH:-aarch64}
agent_sha=${AGENT_SHA:-}
core_sha=${CORE_SHA:-}
builder_image_digest=${BUILDER_IMAGE_DIGEST:-}
builder_identity=${BUILDER_IDENTITY:-}

build_dir=$(canonical_existing_dir BUILD_DIR "$build_dir_input")
[[ $(dirname -- "$build_dir") == /home/dbdog/work ]] ||
  die "BUILD_DIR must be an immediate child of /home/dbdog/work"
[[ $(basename -- "$build_dir") =~ ^dbdog-agent-[0-9a-f]{8,40}-build[0-9]+$ ]] ||
  die "BUILD_DIR does not match the sealed Omnibus attempt layout: $build_dir"

install_dir=$(canonical_existing_dir INSTALL_DIR "$install_dir_input")
[[ $install_dir == "$PRIVATE_INSTALL_DIR" ]] ||
  die "INSTALL_DIR must resolve exactly to $PRIVATE_INSTALL_DIR"
[[ -f $install_dir/.install_root && ! -L $install_dir/.install_root ]] ||
  die "$install_dir lacks a regular Omnibus .install_root"

agent_source_input=${AGENT_SOURCE_DIR:-$build_dir/src}
agent_source_dir=$(canonical_existing_dir AGENT_SOURCE_DIR "$agent_source_input")
[[ $agent_source_dir == "$build_dir/src" ]] ||
  die "AGENT_SOURCE_DIR must resolve exactly to $build_dir/src"

core_repo_input=${CORE_REPO:-/home/dbdog/cache/dbdog-agent/git/dbdog-agent-core.git}
core_repo=$(canonical_existing_dir CORE_REPO "$core_repo_input")
case "$core_repo" in
  /home/dbdog/cache/dbdog-agent/git/*) ;;
  *) die "CORE_REPO is outside the sealed dbdog-agent Git cache: $core_repo" ;;
esac

output_dir_input=${OUTPUT_DIR:-$build_dir/out}
[[ -n $output_dir_input && $output_dir_input == /* ]] || die "OUTPUT_DIR must be a non-empty absolute path"
reject_control_characters OUTPUT_DIR "$output_dir_input"
output_dir=$(readlink -m -- "$output_dir_input")
case "$output_dir" in
  "$build_dir"/out | "$build_dir"/out/*) ;;
  *) die "OUTPUT_DIR must remain at or below $build_dir/out" ;;
esac
[[ $output_dir != "$install_dir" && $output_dir != "$agent_source_dir" ]] ||
  die "OUTPUT_DIR overlaps an input tree"

[[ -n $version ]] || die "VERSION is required"
reject_control_characters VERSION "$version"
[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "unsafe VERSION: $version"
[[ $arch == aarch64 ]] || die "ARCH must be aarch64 for this build"
[[ $agent_sha =~ ^[0-9a-f]{40}$ ]] || die "AGENT_SHA must be a full lowercase 40-hex commit"
[[ $core_sha =~ ^[0-9a-f]{40}$ ]] || die "CORE_SHA must be a full lowercase 40-hex commit"
[[ $agent_sha == "$EXPECTED_RELEASE_AGENT_SHA" ]] ||
  die "AGENT_SHA must be the pinned release source $EXPECTED_RELEASE_AGENT_SHA"
[[ $core_sha == "$EXPECTED_INTEGRATION_CORE_SHA" ]] ||
  die "CORE_SHA must be the pinned post-Omnibus integration source $EXPECTED_INTEGRATION_CORE_SHA"
reject_control_characters BUILDER_IMAGE_DIGEST "$builder_image_digest"
reject_control_characters BUILDER_IDENTITY "$builder_identity"
if [[ -n $builder_image_digest ]]; then
  [[ $builder_image_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "BUILDER_IMAGE_DIGEST must be sha256:<64 lowercase hex>"
fi
if [[ -n $builder_identity ]]; then
  [[ $builder_identity =~ ^[A-Za-z0-9][A-Za-z0-9._:+@/-]*$ ]] ||
    die "unsafe BUILDER_IDENTITY: $builder_identity"
fi
[[ -n $builder_image_digest || -n $builder_identity ]] ||
  die "record BUILDER_IMAGE_DIGEST or an explicit native BUILDER_IDENTITY"

success_marker="$build_dir/omnibus.success"
[[ $EXPECTED_MANIFEST_REL == "manifests/$GENERATED_OUTPUTS_ORIGIN_AGENT_SHA-$OMNIBUS_CORE_SHA-aarch64-kylin10-v7" ]] ||
  die "generated-output origin or OMNIBUS_CORE_SHA differs from the immutable Kylin v7 authority"
verify_omnibus_success_marker "$success_marker"
verify_omnibus_control_overlay
manifest_rel=$EXPECTED_MANIFEST_REL
omnibus_ruby_sha=$EXPECTED_OMNIBUS_RUBY_SHA
adp_inputs_manifest_sha256=$(verify_adp_input_handoff)
[[ $adp_inputs_manifest_sha256 =~ ^[0-9a-f]{64}$ ]] ||
  die "invalid v7 INPUTS.sha256 digest"

[[ $(git_in "$agent_source_dir" rev-parse HEAD) == "$agent_sha" ]] ||
  die "agent source HEAD differs from AGENT_SHA"
git_in "$core_repo" cat-file -e "$core_sha^{commit}" ||
  die "post-Omnibus integration CORE_SHA is absent from CORE_REPO"

patch_disable_rel=dbdog-deploy/scripts/patch-disable-dbmhealth.sh
patch_schema_rel=dbdog-deploy/scripts/patch-postgres-schema-recommendation-fields.sh
patch_disable="$agent_source_dir/$patch_disable_rel"
patch_schema="$agent_source_dir/$patch_schema_rel"
for patch_rel in "$patch_disable_rel" "$patch_schema_rel"; do
  git_in "$agent_source_dir" ls-files --error-unmatch "$patch_rel" >/dev/null ||
    die "patch script is not tracked at AGENT_SHA: $patch_rel"
  git_in "$agent_source_dir" diff --quiet "$agent_sha" -- "$patch_rel" ||
    die "patch script differs from exact AGENT_SHA source: $patch_rel"
done
[[ -f $patch_disable && -f $patch_schema ]] || die "source patch scripts are missing"

source_date_epoch=${SOURCE_DATE_EPOCH:-}
if [[ -z $source_date_epoch ]]; then
  source_date_epoch=$(git_in "$agent_source_dir" show -s --format=%ct "$agent_sha")
fi
[[ $source_date_epoch =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be a non-negative integer"

python_site="$install_dir/embedded/lib/python3.13/site-packages"
embedded_python="$install_dir/embedded/bin/python3"
health_py="$python_site/datadog_checks/base/utils/db/health.py"
schemas_py="$python_site/datadog_checks/postgres/schemas.py"
[[ -d $python_site && -x $embedded_python ]] || die "expected embedded Python 3.13 runtime is absent"
embedded_python_real=$(require_path_within 'embedded Python' "$install_dir" "$embedded_python")
[[ -x $embedded_python_real ]] || die "resolved embedded Python is not executable"
[[ -f $health_py && ! -L $health_py && -f $schemas_py && ! -L $schemas_py ]] ||
  die "patch targets must be regular, non-symlink embedded Python files"
require_path_within 'dbm-health patch target' "$install_dir" "$health_py" >/dev/null
require_path_within 'PostgreSQL schema patch target' "$install_dir" "$schemas_py" >/dev/null

if [[ -e $output_dir || -L $output_dir ]]; then
  [[ -d $output_dir && ! -L $output_dir ]] ||
    die "OUTPUT_DIR is not a real directory: $output_dir"
else
  mkdir -- "$output_dir" || die "could not create root-owned OUTPUT_DIR: $output_dir"
fi
output_dir=$(canonical_existing_dir OUTPUT_DIR "$output_dir")
case "$output_dir" in
  "$build_dir"/out | "$build_dir"/out/*) ;;
  *) die "resolved OUTPUT_DIR escaped $build_dir/out" ;;
esac
[[ $(stat -c '%u:%g:%a' -- "$output_dir") == 0:0:755 ]] ||
  die "OUTPUT_DIR must be root:root mode 0755: $output_dir"
output_device=$(stat -c '%d' -- "$output_dir")
[[ $output_device =~ ^[0-9]+$ && $output_device == "$(stat -c '%d' -- "$build_dir")" ]] ||
  die "OUTPUT_DIR must remain on the BUILD_DIR filesystem"
archive_name="dbdog-agent-$version-$arch.tar.gz"
archive_path="$output_dir/$archive_name"

runtime_root=$(canonical_existing_dir RUNTIME_ROOT /run)
[[ $runtime_root == /run ]] || die "RUNTIME_ROOT must resolve exactly to /run"
[[ $(stat -c %u -- "$runtime_root") == 0 ]] || die "/run is not owned by root"
[[ -z $(find "$runtime_root" -maxdepth 0 -perm /022 -print -quit) ]] ||
  die "/run is writable by group or other users"
runtime_lock_dir=/run/dbdog-agent-finalize
if [[ -e $runtime_lock_dir || -L $runtime_lock_dir ]]; then
  [[ -d $runtime_lock_dir && ! -L $runtime_lock_dir ]] ||
    die "runtime lock directory is not a real directory: $runtime_lock_dir"
else
  install -d -o root -g root -m 0700 "$runtime_lock_dir"
fi
runtime_lock_dir=$(canonical_existing_dir RUNTIME_LOCK_DIR "$runtime_lock_dir")
[[ $runtime_lock_dir == /run/dbdog-agent-finalize ]] || die "runtime lock directory moved unexpectedly"
[[ $(stat -c '%u:%g:%a' -- "$runtime_lock_dir") == 0:0:700 ]] ||
  die "runtime lock directory must be root:root mode 0700"
lock_file="$runtime_lock_dir/$(basename -- "$build_dir").$agent_sha.lock"
[[ ! -L $lock_file ]] || die "runtime lock file is a symlink: $lock_file"
exec 9>>"$lock_file"
flock -n 9 || die "another finalization process holds the build lock"
[[ -f $lock_file && ! -L $lock_file ]] || die "runtime lock is not a regular file: $lock_file"
[[ $(readlink -e -- "$lock_file") == "$lock_file" ]] ||
  die "runtime lock resolves unexpectedly: $lock_file"
[[ $(stat -c '%u:%g' -- "$lock_file") == 0:0 ]] ||
  die "runtime lock must be root-owned: $lock_file"
[[ -z $(find "$lock_file" -maxdepth 0 -perm /022 -print -quit) ]] ||
  die "runtime lock must not be writable by group or other users: $lock_file"

# Older finalizers placed bulk work below the lock directory.  Once this build
# lock is held, remove only an abandoned root-private directory for the exact
# pinned commit.  New work is never created below /run.
while IFS= read -r -d '' legacy_work_dir; do
  remove_private_work_tree \
    'legacy /run finalizer work directory' \
    "$legacy_work_dir" \
    "$runtime_lock_dir" \
    "^work[.]${agent_sha}[.][A-Za-z0-9]{6}$"
done < <(
  find "$runtime_lock_dir" -xdev -mindepth 1 -maxdepth 1 \
    -name "work.$agent_sha.*" -print0
)

bulk_scratch_root=/var/lib/dbdog-agent-finalize
if [[ -e $bulk_scratch_root || -L $bulk_scratch_root ]]; then
  [[ -d $bulk_scratch_root && ! -L $bulk_scratch_root ]] ||
    die "persistent bulk scratch root is not a real directory: $bulk_scratch_root"
else
  install -d -o root -g root -m 0700 "$bulk_scratch_root"
fi
require_root_private_dir \
  'persistent bulk scratch root' "$bulk_scratch_root" /var/lib/dbdog-agent-finalize

bulk_build_scratch="$bulk_scratch_root/$(basename -- "$build_dir").$agent_sha"
if [[ -e $bulk_build_scratch || -L $bulk_build_scratch ]]; then
  [[ -d $bulk_build_scratch && ! -L $bulk_build_scratch ]] ||
    die "build-specific bulk scratch is not a real directory: $bulk_build_scratch"
else
  install -d -o root -g root -m 0700 "$bulk_build_scratch"
fi
require_root_private_dir \
  'build-specific bulk scratch' "$bulk_build_scratch" "$bulk_build_scratch"

# The parent is root-only and this process holds the exact build lock.  Remove
# only abandoned mktemp directories for this pinned commit; any other entry is
# treated as an unsafe or unexplained condition instead of being guessed away.
while IFS= read -r -d '' stale_work_dir; do
  remove_private_work_tree \
    'stale finalizer work directory' \
    "$stale_work_dir" \
    "$bulk_build_scratch" \
    "^work[.]${agent_sha}[.][A-Za-z0-9]{6}$"
done < <(find "$bulk_build_scratch" -xdev -mindepth 1 -maxdepth 1 -print0)

work_dir=$(mktemp -d "$bulk_build_scratch/work.$agent_sha.XXXXXX")
require_root_private_dir 'current finalizer work directory' "$work_dir" "$work_dir"
cleanup() {
  local status=$?
  trap - EXIT
  case "${work_dir:-}" in
    "$bulk_build_scratch"/work."$agent_sha".??????)
      if [[ -e $work_dir || -L $work_dir ]]; then
        remove_private_work_tree \
          'current finalizer work directory' \
          "$work_dir" \
          "$bulk_build_scratch" \
          "^work[.]${agent_sha}[.][A-Za-z0-9]{6}$"
      fi
      ;;
    '') ;;
    *)
      log "refusing to clean unexpected work directory: $work_dir"
      status=1
      ;;
  esac
  exit "$status"
}
trap cleanup EXIT

# This check intentionally precedes every patch, cleanup, shebang rewrite, and
# provenance mutation under /opt/dbdog-agent.  A small or inode-starved root
# filesystem therefore fails with a capacity report while the runtime remains
# untouched.  /run contains only the lock and never receives bulk data.
preflight_bulk_workspace "$install_dir" "$bulk_build_scratch" "$output_dir"

# Promote the user-owned handoff into the root-only finalizer workspace, then
# validate the promoted bytes again. All later provenance uses this snapshot.
success_marker_snapshot="$work_dir/omnibus.success"
install -o root -g root -m 0400 "$success_marker" "$success_marker_snapshot"
verify_omnibus_success_marker "$success_marker_snapshot"
success_marker=$success_marker_snapshot

log "running private-runtime patches from exact agent source $agent_sha"
env -i \
  HOME=/root \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  PATH="$install_dir/embedded/bin:/usr/bin:/bin" \
  PY="$python_site" \
  /usr/bin/bash "$patch_disable"
env -i \
  HOME=/root \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  PATH="$install_dir/embedded/bin:/usr/bin:/bin" \
  PY="$python_site" \
  TARGET="$schemas_py" \
  DBDOG_AGENT_BIN="$install_dir/bin/agent/agent" \
  PATCH_ONLY=true \
  /usr/bin/bash "$patch_schema"
verify_python_sources "$health_py" "$schemas_py"
install_pinned_gaussdb_integration "$install_dir"

clean_runtime_tree
shebang_report="$work_dir/shebang-rewrites.tsv"
rewrite_safe_python_shebangs "$install_dir" "$shebang_report"
validate_tree_names_and_types "$install_dir"
verify_runtime_exclusions "$install_dir"
verify_primary_binaries "$install_dir"
linkage_report="$work_dir/primary-elf-linkage.tsv"
write_primary_linkage_report "$install_dir" "$linkage_report"
adp_report="$work_dir/agent-data-plane.txt"
write_adp_provenance "$install_dir" "$adp_report"
agent_version_report="$work_dir/agent-version.txt"
write_agent_version_provenance "$install_dir" "$version" "$agent_version_report"
system_probe_version_report="$work_dir/system-probe-version.txt"
write_system_probe_version_provenance "$install_dir" "$version" "$system_probe_version_report"
gaussdb_report="$work_dir/gaussdb.txt"
write_gaussdb_provenance "$install_dir" "$gaussdb_report"
env -i \
  HOME=/nonexistent \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  PATH=/usr/bin:/bin \
  PYTHONDONTWRITEBYTECODE=1 \
  "$embedded_python" -I -B -m pip check >/dev/null
clean_runtime_tree

glibc_report="$work_dir/glibc-requirements.tsv"
write_glibc_report "$install_dir" "$glibc_report"
symlink_report="$work_dir/symlinks.tsv"
write_symlink_manifest "$install_dir" "$symlink_report"

provenance_dir="$install_dir/provenance"
if [[ -L $provenance_dir ]]; then
  die "provenance path is a symlink"
fi
if [[ -e $provenance_dir ]]; then
  rm -rf -- "$provenance_dir"
fi
install -d -m 0755 "$provenance_dir"
install -m 0644 "$success_marker" "$provenance_dir/omnibus.success"
install -m 0644 "$glibc_report" "$provenance_dir/glibc-requirements.tsv"
install -m 0644 "$linkage_report" "$provenance_dir/primary-elf-linkage.tsv"
install -m 0644 "$adp_report" "$provenance_dir/agent-data-plane.txt"
install -m 0644 "$agent_version_report" "$provenance_dir/agent-version.txt"
install -m 0644 "$system_probe_version_report" "$provenance_dir/system-probe-version.txt"
install -m 0644 "$gaussdb_report" "$provenance_dir/gaussdb.txt"
install -m 0644 "$symlink_report" "$provenance_dir/symlinks.tsv"
install -m 0644 "$shebang_report" "$provenance_dir/shebang-rewrites.tsv"

gauss_import_version=$(awk -F= '$1 == "integration_version" { print $2; found++ }
  END { exit(found == 1 ? 0 : 1) }' "$gaussdb_report") ||
  die "GaussDB integration provenance lacks one integration_version"

finalizer_sha256=$(sha256sum -- "$(readlink -e -- "$0")" | awk '{ print $1 }')
patch_disable_sha256=$(sha256sum -- "$patch_disable" | awk '{ print $1 }')
patch_schema_sha256=$(sha256sum -- "$patch_schema" | awk '{ print $1 }')
omnibus_success_sha256=$(sha256sum -- "$success_marker" | awk '{ print $1 }')
agent_binary_sha256=$(awk -F= '$1 == "binary_sha256" { print $2 }' "$agent_version_report")
agent_version_output_sha256=$(awk -F= '$1 == "version_output_sha256" { print $2 }' "$agent_version_report")
agent_version_manifest_text_sha256=$(awk -F= '$1 == "version_manifest_text_sha256" { print $2 }' "$agent_version_report")
agent_version_manifest_json_sha256=$(awk -F= '$1 == "version_manifest_json_sha256" { print $2 }' "$agent_version_report")
system_probe_binary_sha256=$(awk -F= '$1 == "binary_sha256" { print $2 }' "$system_probe_version_report")
system_probe_version_output_sha256=$(awk -F= '$1 == "version_output_sha256" { print $2 }' "$system_probe_version_report")
cat >"$provenance_dir/build.txt" <<EOF
format_version=2
product=dbdog-agent
version=$version
compiled_agent_version=$version
architecture=$arch
install_prefix=$install_dir
agent_git_sha=$agent_sha
generated_outputs_origin_agent_sha=$GENERATED_OUTPUTS_ORIGIN_AGENT_SHA
omnibus_integrations_core_git_sha=$OMNIBUS_CORE_SHA
integrations_core_git_sha=$core_sha
omnibus_ruby_git_sha=$omnibus_ruby_sha
manifest_rel=$manifest_rel
control_overlay_rel=$EXPECTED_CONTROL_OVERLAY_REL
control_overlay_runner_sha256=$EXPECTED_CONTROL_OVERLAY_RUNNER_SHA256
platform_patch_sha256=$EXPECTED_PLATFORM_PATCH_SHA256
control_info_sha256=$EXPECTED_CONTROL_INFO_SHA256
control_manifest_sha256=$EXPECTED_CONTROL_MANIFEST_SHA256
patchelf_version=$EXPECTED_PATCHELF_VERSION
patchelf_rel=$EXPECTED_PATCHELF_REL
patchelf_sha256=$EXPECTED_PATCHELF_SHA256
patchelf_info_sha256=$EXPECTED_PATCHELF_INFO_SHA256
patchelf_sums_sha256=$EXPECTED_PATCHELF_SUMS_SHA256
host_distribution=$EXPECTED_HOST_DISTRIBUTION
integration_name=$GAUSSDB_INTEGRATION_NAME
integration_version=$gauss_import_version
integration_wheel_rel=$GAUSSDB_WHEEL_REL
integration_wheel_sha256=$GAUSSDB_WHEEL_SHA256
agent_binary_sha256=$agent_binary_sha256
agent_version_output_sha256=$agent_version_output_sha256
agent_version_manifest_text_sha256=$agent_version_manifest_text_sha256
agent_version_manifest_json_sha256=$agent_version_manifest_json_sha256
system_probe_binary_sha256=$system_probe_binary_sha256
system_probe_version_output_sha256=$system_probe_version_output_sha256
agent_data_plane_version=$ADP_VERSION
agent_data_plane_input_sha256=$ADP_INPUT_SHA256
source_date_epoch=$source_date_epoch
builder_image_digest=${builder_image_digest:-none}
builder_identity=${builder_identity:-none}
finalizer_sha256=$finalizer_sha256
patch_disable_dbmhealth_sha256=$patch_disable_sha256
patch_postgres_schema_sha256=$patch_schema_sha256
omnibus_success_sha256=$omnibus_success_sha256
glibc_maximum=$MAX_GLIBC_VERSION
runtime_manifest_scope=all_regular_files_except_./provenance/runtime.sha256
archive_recipe=gnu_tar_sorted_fixed_mtime_root_owner_gzip_n_two_pass_delete_second_before_extract
publication_recipe=$PUBLICATION_RECIPE
EOF
chmod 0644 "$provenance_dir/build.txt"

verify_no_path_leaks "$install_dir"
runtime_manifest_tmp="$work_dir/runtime.sha256"
write_regular_file_manifest "$install_dir" "$runtime_manifest_tmp"
install -m 0644 "$runtime_manifest_tmp" "$provenance_dir/runtime.sha256"

# Re-run the inventory checks after provenance and its SHA manifest are present.
validate_tree_names_and_types "$install_dir"
symlink_report_after="$work_dir/symlinks-after.tsv"
write_symlink_manifest "$install_dir" "$symlink_report_after"
cmp -s -- "$provenance_dir/symlinks.tsv" "$symlink_report_after" ||
  die "runtime symlinks changed while provenance was generated"
verify_no_path_leaks "$install_dir"

archive_pass1="$work_dir/$archive_name.pass1"
archive_pass2="$work_dir/$archive_name.pass2"

log "creating two independent deterministic archive passes"
create_archive "$archive_pass1"
create_archive "$archive_pass2"
archive_sha256=$(sha256sum -- "$archive_pass1" | awk '{ print $1 }')
archive_sha256_second=$(sha256sum -- "$archive_pass2" | awk '{ print $1 }')
[[ $archive_sha256 == "$archive_sha256_second" ]] ||
  die "two archive passes are not byte-identical"
cmp -s -- "$archive_pass1" "$archive_pass2" || die "archive hashes matched but bytes differ"
archive_bytes=$(stat -c '%s' -- "$archive_pass1")
((archive_bytes <= bulk_archive_bound_bytes)) ||
  die "archive exceeded the conservative preflight bound: actual=${archive_bytes}B bound=${bulk_archive_bound_bytes}B"

# Reproducibility is now proven.  Do not carry the second compressed copy into
# extraction, where it would unnecessarily raise the peak from C+R to 2C+R.
remove_private_work_file 'second deterministic archive pass' "$archive_pass2" "$work_dir"
preflight_extraction_space "$bulk_build_scratch"

verify_root="$work_dir/extracted"
verify_archive \
  "$archive_pass1" \
  "$verify_root" \
  "$work_dir/archive.list" \
  "$work_dir/extracted-runtime.sha256" \
  "$work_dir/extracted-symlinks.tsv" \
  "$work_dir/extracted-glibc.tsv" \
  "$work_dir/extracted-linkage.tsv" \
  "$work_dir/extracted-agent-data-plane.txt" \
  "$work_dir/extracted-agent-version.txt" \
  "$work_dir/extracted-system-probe-version.txt" \
  "$work_dir/extracted-gaussdb.txt"

# Verification has consumed every byte it needs from the extracted copy.
# Remove it before publishing the archive so publication cannot recreate a
# 2C+R peak on the already-tight persistent filesystem.
remove_private_work_tree \
  'verified extracted runtime' "$verify_root" "$work_dir" '^extracted$'

publish_archive_and_sidecar_atomically \
  "$archive_pass1" "$output_dir" "$archive_name" "$archive_sha256" "$archive_bytes" \
  "$output_device"
[[ -f $archive_path && ! -L $archive_path && \
   $(readlink -e -- "$archive_path") == "$archive_path" && \
   $(stat -c '%u:%g:%a' -- "$archive_path") == 0:0:644 ]] ||
  die "published archive failed its final path and metadata check: $archive_path"
[[ $(sha256sum -- "$archive_path" | awk '{ print $1 }') == "$archive_sha256" ]] ||
  die "published archive failed its final SHA-256 check: $archive_path"
[[ -f $archive_path.sha256 && ! -L $archive_path.sha256 && \
   $(readlink -e -- "$archive_path.sha256") == "$archive_path.sha256" && \
   $(stat -c '%u:%g:%a' -- "$archive_path.sha256") == 0:0:644 ]] ||
  die "published archive sidecar failed its final path and metadata check"
printf '%s  %s\n' "$archive_sha256" "$archive_name" |
  cmp -s - "$archive_path.sha256" || die "published archive sidecar content differs"
remove_private_work_file 'verified root-private archive pass' "$archive_pass1" "$work_dir"
printf 'FINAL_ARCHIVE=%s\nFINAL_ARCHIVE_SHA256=%s\n' "$archive_path" "$archive_sha256"
