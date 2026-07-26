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
control_overlay_rel=control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v4
control_overlay_dir="$persistent_cache/$control_overlay_rel"
base_runner="$persistent_cache/$manifest_rel/controls/run-agent-omnibus.sh"
platform_patch="$control_overlay_dir/agent-build-kylin-platform.patch"
local_sources_dir="$persistent_cache/sources"
stage_config_dir="$build_dir/stage-config"
omnibus_base_dir="$build_dir/omnibus"
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
  echo "OMNIBUS_RUBY_VERSION does not match the v7 build input" >&2
  exit 1
fi
export OMNIBUS_RUBY_VERSION="$omnibus_ruby_sha"

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
  echo "Omnibus control overlay inventory does not match the pinned v4 inventory" >&2
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
    echo "Kylin platform patch is neither cleanly applicable nor already applied" >&2
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

export HOME=/home/dbdog
export XDG_CACHE_HOME="$persistent_cache/xdg/user"
export TMPDIR="$build_dir/tmp/user"
export BAZELISK_HOME=/home/dbdog/.cache/bazelisk
export DBDOG_BAZEL_DISK_CACHE="$persistent_cache/bazel/disk"
export PATH=/home/dbdog/tools/dda-venv/bin:/home/dbdog/tools/ruby27/bin:/home/dbdog/tools/python312/bin:/home/dbdog/tools/go/bin:/home/dbdog/tools/bin:/home/dbdog/tools/node/bin:/home/dbdog/.cargo/bin:/usr/local/bin:/usr/bin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

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
  'host_distribution=rhel' \
  >"$success_tmp"
chmod 0644 "$success_tmp"
mv -f -- "$success_tmp" "$success_file"
