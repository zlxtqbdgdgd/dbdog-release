#!/usr/bin/env bash
# Static and local-input contracts for the pinned Agent artifact finalizer.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
FINALIZER="$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v3.sh"
WRAPPER="$SCRIPTS_DIR/publish/agent-build/run-finalize-agent-runtime-v3.sh"
RUNNER="$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v14/run-agent-omnibus.sh"
RECIPE="$SCRIPTS_DIR/publish/recipes/dbdog-agent.sh"
CONTROL_README="$SCRIPTS_DIR/publish/agent-build/README.md"
CORE_DIR="$RELEASE_DIR/../dbdog-agent-core"
WHEEL="${DBDOG_GAUSSDB_WHEEL:-$CORE_DIR/gaussdb/dist/datadog_gaussdb-1.0.1-py3-none-any.whl}"
EXPECTED_WHEEL_SHA=f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f
PUBLICATION_RECIPE=destination_local_copy_verify_sync_hardlink_noreplace_archive_then_sidecar_recover_archive_only

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

stdin_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

recipe_readonly() {
  local name=$1
  sed -n "s/^readonly ${name}=//p" "$RECIPE"
}

bash -n "$FINALIZER"
bash -n "$WRAPPER"
bash -n "$RUNNER"
bash -n "$RECIPE"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v1.sh")" = \
  968bdc937041b2aacef7173afc4dbe0b68ab063a5374211b29f987c450438e82 ] ||
  fail "historical v1 finalizer bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/run-finalize-agent-runtime-v1.sh")" = \
  9d97177db1fe5ddf4ac2559eade9395c62408a169c69cd783fcd3bac6d967ac5 ] ||
  fail "historical v1 wrapper bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v2.sh")" = \
  5ba96a0b279e4ba4ce848fbcf5b62fa012d8ad349c91e61f9ad29201ae3d8b17 ] ||
  fail "historical v2 finalizer bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/run-finalize-agent-runtime-v2.sh")" = \
  a0e46466bd0727390a957139e08e282aca97e31d882fea9f97c348d5ac91eeda ] ||
  fail "historical v2 wrapper bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v12/run-agent-omnibus.sh")" = \
  82c0514179d586f569e7287cbad28893ac4b9009e5fc3b61300d33085d0fbcc6 ] ||
  fail "historical v12 runner bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v12/agent-build-kylin-platform.patch")" = \
  b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe ] ||
  fail "historical v12 platform patch bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v12/CONTROL-INFO")" = \
  3febbbe8331078aa8b9f12592ef95731b5913bc066faecc8bc8e786ba53ecc1a ] ||
  fail "historical v12 CONTROL-INFO bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v12/CONTROL.sha256")" = \
  0c01d4833beb9391fd411bcae4ca23208d6ad73e3e5935f549a9a3b5e24c2ff4 ] ||
  fail "historical v12 CONTROL.sha256 bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/run-agent-omnibus.sh")" = \
  c995773922ed242471e42e1e6e35460b48a7498bc531b7e028107d7b1321086d ] ||
  fail "historical v13 runner bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/agent-build-kylin-platform.patch")" = \
  b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe ] ||
  fail "historical v13 platform patch bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/CONTROL-INFO")" = \
  a06c295420edd7232438df2700c1a890c9b0bdd37269fd4cfd38fb4e2fb4e592 ] ||
  fail "historical v13 CONTROL-INFO bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/CONTROL.sha256")" = \
  5491492ab454603d92a6f4de31fd1c13f47e34362eedcdf2f47e3b58cbc5a4d0 ] ||
  fail "historical v13 CONTROL.sha256 bytes changed"
pass "historical v12/v1 and v13/v2 controls remain byte-identical"

actual_finalizer_sha=$(file_sha256 "$FINALIZER")
actual_wrapper_sha=$(file_sha256 "$WRAPPER")
actual_runner_sha=$(file_sha256 "$RUNNER")
grep -Fq "readonly FINALIZER_SHA256=$actual_finalizer_sha" "$WRAPPER" ||
  fail "v3 wrapper does not pin the actual v3 finalizer bytes"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v14/CONTROL-INFO")" = \
  b5dcfa966d6ebe9bcb080c392b8544693ec3c3bf5c88e49275da7c093b427b50 ] ||
  fail "historical v14 CONTROL-INFO bytes changed"
[ "$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v14/CONTROL.sha256")" = \
  359151228de51ed690c00caf6d22f42f8e7f0026d512e5c39962fc23f74c4e75 ] ||
  fail "historical v14 CONTROL.sha256 bytes changed"
[ "$actual_runner_sha" = 6da7c38074a6c16a15a491a1358e8fc8c606bea1eaac81df10352e79737c8e4a ] ||
  fail "historical v14 runner bytes changed"
pass "v14/v3 controls are frozen historical records"

# ---- 锚单源化 ----
# 每一代的 control overlay 与 finalizer/wrapper 都由 prepare-agent-anchor.sh 从上一代机械
# 改写而来，并落到构建机上 root:root 的 anchors/<sha>/；仓库里只跟踪「生成器 + 历史各代」。
# 因此这里不再断言配方钉住了某一代的哈希——那正是每次换锚都要人肉同步、且屡次漏改的东西
# （8585423 / b6e9982 / 7f8e53b，以及一直没跟上的 finalizer/wrapper）。改为断言配方**不含**
# 任何随锚变的字面量，且确实从 $SHA/$CORE_SHA 与 ANCHOR-INFO 派生。
ANCHOR_PREPARER="$SCRIPTS_DIR/publish/agent-build/prepare-agent-anchor.sh"
[ -f "$ANCHOR_PREPARER" ] && [ -x "$ANCHOR_PREPARER" ] ||
  fail "missing executable prepare-agent-anchor.sh"
bash -n "$ANCHOR_PREPARER"
# 改写规则必须是 POSIX BRE：`\b` 只有 GNU sed 认，用它会出现「本地干跑过、构建机漏改一处」。
if grep -E '^[[:space:]]*-e "s/' "$ANCHOR_PREPARER" | grep -Fq '\b'; then
  fail "anchor rewrite rules rely on the GNU-only \\b word boundary"
fi
grep -Fq 'die "改写后仍残留旧锚 token，请人工核对' "$ANCHOR_PREPARER" ||
  fail "anchor rewrite does not fail closed on leftover old anchor tokens"

# 允许留在配方里的裸 40 位 hex 只有真正与发布锚无关的冻结身份。
allowed_frozen_hex='4c39489b8c0b7fb7a46af88062fb9aadf2c08264|7a4247599b029f1aca10d2cb63491d535fbd502f|5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749'
stray_hex=$(grep -oE '\b[0-9a-f]{40}\b' "$RECIPE" | grep -vE "^($allowed_frozen_hex)$" || :)
[ -z "$stray_hex" ] ||
  fail "recipe restates anchor-bearing 40-hex literals: $(printf '%s' "$stray_hex" | tr '\n' ' ')"
stray_short=$(grep -oE 'dbdog-agent-[0-9a-f]{8}-' "$RECIPE" || :)
[ -z "$stray_short" ] ||
  fail "recipe hard-codes short-SHA build paths: $(printf '%s' "$stray_short" | tr '\n' ' ')"

grep -Fq 'readonly SHORT_SHA=${SHA:0:8}' "$RECIPE" ||
  fail "recipe does not derive the short SHA from the passed-in release anchor"
grep -Fq 'readonly BUILD_DIR="$WORK_ROOT/dbdog-agent-$SHORT_SHA-build2"' "$RECIPE" ||
  fail "recipe does not derive BUILD_DIR from the release anchor"
grep -Fq 'readonly OUTPUT_DIR="$BUILD_DIR/out"' "$RECIPE" ||
  fail "recipe does not derive OUTPUT_DIR from BUILD_DIR"
grep -Fq 'readonly PIPELINE_LOCK="$CACHE_ROOT/locks/dbdog-agent-$SHORT_SHA-aarch64-kylin10.pipeline.lock"' \
  "$RECIPE" || fail "recipe does not derive the pipeline lock from the release anchor"
grep -Fq 'readonly GAUSSDB_WHEEL_REL="sources/python/gaussdb/$CORE_SHA/' "$RECIPE" ||
  fail "recipe does not derive the GaussDB wheel path from the integration core anchor"
grep -Fq 'OVERLAY_REL="control-overlays/$SHA-$PINNED_OMNIBUS_CORE_SHA-aarch64-kylin10-v7-omnibus-kylin-platform-$OVERLAY_GENERATION"' \
  "$RECIPE" || fail "recipe does not derive the control overlay path from the release anchor"
pass "recipe derives every anchor-bearing path from the passed-in SHA/CORE_SHA"

# ---- overlay 信任链 ----
grep -Fq 'require_exact_field "$ANCHOR_INFO" release_agent_sha "$SHA"' "$RECIPE" ||
  fail "recipe does not bind ANCHOR-INFO to the passed-in release anchor"
grep -Fq 'require_exact_field "$ANCHOR_INFO" integration_core_sha "$CORE_SHA"' "$RECIPE" ||
  fail "recipe does not bind ANCHOR-INFO to the passed-in integration core anchor"
grep -Fq 'OVERLAY_GENERATION=$(read_exact_field "$ANCHOR_INFO" control_overlay_generation)' "$RECIPE" ||
  fail "recipe does not read the overlay generation from ANCHOR-INFO"
grep -Fq 'FINALIZER_SHA256=$(read_exact_field "$ANCHOR_INFO" finalizer_sha256)' "$RECIPE" ||
  fail "recipe does not read the finalizer digest from ANCHOR-INFO"
grep -Fq 'require_exact_field "$OVERLAY_DIR/CONTROL-INFO" release_agent_sha "$SHA"' "$RECIPE" ||
  fail "recipe does not bind the control overlay to the passed-in release anchor"
grep -Fq '"omnibus-kylin-platform-$OVERLAY_GENERATION"' "$RECIPE" ||
  fail "recipe does not bind the control overlay to its own derived generation name"
grep -Fq 'require_exact_field "$OVERLAY_DIR/CONTROL-INFO" go_tmpdir "$BUILD_DIR/tmp/go"' "$RECIPE" ||
  fail "recipe does not bind the control overlay to this release attempt's build directory"
# 锚无关的两行必须继续钉死，否则 overlay 自证就退化成「自己说自己对」。
grep -Fq 'readonly PLATFORM_PATCH_SHA256=b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe' \
  "$RECIPE" || fail "recipe stopped pinning the anchor-independent platform patch"
grep -Fq 'readonly PATCHELF_SHA256=01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf' \
  "$RECIPE" || fail "recipe stopped pinning the anchor-independent patchelf binary"
grep -Fq 'CONTROL.sha256 必须精确包含固定顺序的四行清单' "$RECIPE" ||
  fail "recipe no longer rebuilds the exact four-line control manifest"
grep -Fq 'require_root_control '"'"'Omnibus runner'"'"' "$RUNNER" 555 "$RUNNER_SHA256"' "$RECIPE" ||
  fail "recipe no longer enforces root ownership and mode on the Omnibus runner"
pass "control overlay is trusted through root ownership, self-consistency, and anchor identity"

if grep -Eq 'GAUSSDB_VERSION|DEFAULT_GAUSSDB_VERSION|gaussdb_version=' "$FINALIZER" "$RECIPE"; then
  fail "Agent artifact controls still overload a target GaussDB version variable"
fi
grep -Fq 'readonly EXPECTED_GAUSSDB_INTEGRATION_VERSION=1.0.1' "$FINALIZER" ||
  fail "finalizer does not pin the integration package version to 1.0.1"
grep -Fq 'integration_version=$gauss_import_version' "$FINALIZER" ||
  fail "build provenance does not derive integration_version from installed package evidence"
pass "GaussDB integration version is package-owned and is not a target database version"

grep -Fq 'readonly OMNIBUS_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f' "$FINALIZER" ||
  fail "finalizer lost the sealed Omnibus core identity"
grep -Fq 'readonly EXPECTED_INTEGRATION_CORE_SHA=612be7bea397c87df707489599c02ed623c29631' "$FINALIZER" ||
  fail "finalizer lost the post-Omnibus integration source identity"
grep -Fq 'core_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "Omnibus success marker no longer uses the sealed core identity"
grep -Fq 'omnibus_integrations_core_git_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "build provenance does not distinguish the Omnibus core"
grep -Fq 'integrations_core_git_sha=$core_sha' "$FINALIZER" ||
  fail "build provenance does not identify the integration source core"
pass "sealed Omnibus input and post-build integration source have separate identities"

grep -Fq 'DBDOG_PACKAGE_VERSION="$VERSION"' "$RECIPE" ||
  fail "recipe does not pass the explicit release VERSION authority into the runner"
grep -Fq '^7[.]81[.]0-dbdog[.][1-9][0-9]*$' "$RECIPE" ||
  fail "recipe does not bind releases to the synchronized official 7.81.0 baseline"
if grep -Fq 'runner_mode=(--adopt-post-health-v2)' "$RECIPE" ||
   grep -Fq 'runner_mode=(--resume-v9-retry6-post-health)' "$RECIPE"; then
  fail "recipe still guesses a legacy resume mode"
fi
grep -Fq 'release attempt 只接受空的 /opt/dbdog-agent' "$RECIPE" ||
  fail "recipe does not fail closed on a shared old install tree"
pass "recipe receives the explicit official-baseline package version authority"

grep -Fq 'readonly SYSTEM_PROBE_SEED_BUILD_DIR="$WORK_ROOT/dbdog-agent-$SEALED_ORIGIN_SHORT_SHA-build2"' \
  "$RECIPE" || fail "recipe lost the exact validated system-probe seed attempt"
grep -Fq 'SEALED_SYSTEM_PROBE_OUTPUTS_SHA256=ae13f9dbc83fd4d219a883f029baa26073cf88b9510bde5f22bc1d84b3688f52' \
  "$RECIPE" || fail "recipe does not pin the sealed 69-output manifest"
# 这两个摘要是锚无关根经确定性变换得出的，必须推导而不是钉死——钉死正是 b6e9982 与
# 7f8e53b 两个 fix 的来源。
for derived in RELEASE_SYSTEM_PROBE_OUTPUTS_SHA256 RELEASE_SYSTEM_PROBE_MARKER_SHA256; do
  if grep -Eq "^readonly $derived=[0-9a-f]{64}" "$RECIPE"; then
    fail "recipe pins $derived as a literal instead of deriving it"
  fi
done
grep -Fq 'derive_release_system_probe_digests' "$RECIPE" ||
  fail "recipe does not derive the release system-probe digests"
grep -Fq 'RELEASE_SYSTEM_PROBE_OUTPUTS_SHA256=${digest%% *}' "$RECIPE" ||
  fail "relocated outputs digest is not derived from the freshly written manifest"
grep -Fq 'RELEASE_SYSTEM_PROBE_MARKER_SHA256=${digest%% *}' "$RECIPE" ||
  fail "handoff marker digest is not derived from the freshly written marker"
# 推导之后每次生成仍要与推导值逐位相符，否则非确定性会静默溜过去。
grep -Fq "die 'relocated release system-probe outputs manifest 不确定'" "$RECIPE" ||
  fail "recipe stopped rechecking the relocated manifest against the derived digest"
grep -Fq 'generated_outputs_origin_agent_sha=$SEALED_ORIGIN_AGENT_SHA' "$RECIPE" ||
  fail "recipe does not distinguish generated-output origin from release Agent source"
grep -Fq 'git clone --local --no-hardlinks --no-checkout --no-tags' "$RECIPE" ||
  fail "fresh source is not recreated independently from the pinned Agent mirror"
grep -Fq 'relative=${source_path#"$SEALED_SYSTEM_PROBE_SOURCE_PREFIX"}' "$RECIPE" ||
  fail "system-probe outputs are not copied through a strict sealed-prefix mapping"
grep -Fq 'target_prefix="$BUILD_DIR/src/"' "$RECIPE" ||
  fail "sealed output manifest is not relocated to the v14 attempt"
grep -Fq 'mv -- "$FRESH_SEED_PROGRESS" "$FRESH_SEED_MARKER"' "$RECIPE" ||
  fail "fresh seed lacks an atomic complete-marker transition"
grep -Fq '"$RUNNER" --dbdog-agent-pipeline-lock-held "$BUILD_DIR" </dev/null >&2' "$RECIPE" ||
  fail "v14 runner can consume the remaining SSH-fed recipe or escape the shared pipeline lock"
grep -Fq 'exec {pipeline_lock_fd}<"$PIPELINE_LOCK"' "$RECIPE" ||
  fail "recipe does not open the root-owned pipeline lock read-only"
if grep -Fq 'exec {pipeline_lock_fd}>"$PIPELINE_LOCK"' "$RECIPE"; then
  fail "recipe tries to truncate the root-owned pipeline lock as dbdog"
fi
if grep -Eq 'mktemp "?\$BUILD_DIR/\.v14-(seed-index|seed-marker-verify|sealed-marker-verify)' "$RECIPE"; then
  fail "pre-seed validation temp files can poison an otherwise empty release attempt after interruption"
fi
if grep -Eq 'cp .*"?\$SYSTEM_PROBE_SEED_BUILD_DIR/src/?"?[[:space:]]' "$RECIPE" ||
   grep -Eq 'rsync .*SYSTEM_PROBE_SEED_BUILD_DIR' "$RECIPE"; then
  fail "recipe copies the mutable build2 source tree wholesale"
fi
for excluded in 'omnibus/pkg' bazel-bin bazel-out bazel-src bazel-testlogs; do
  grep -Fq "$excluded" "$RECIPE" || fail "fresh seed does not explicitly reject inherited $excluded"
done
pass "fresh v14 attempt is recreated from pinned Git plus an explicitly originated 69-output handoff"

for required in --no-index --no-deps --force-reinstall --no-cache-dir; do
  grep -Fq -- "$required" "$FINALIZER" || fail "offline wheel install lacks $required"
done
grep -Fq 'GAUSSDB_WHEEL_SHA256=f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f' \
  "$FINALIZER" || fail "finalizer does not pin the exact GaussDB wheel"
grep -Fq 'GAUSSDB_WHEEL_REL=sources/python/gaussdb/612be7bea397c87df707489599c02ed623c29631/datadog_gaussdb-1.0.1-py3-none-any.whl' \
  "$FINALIZER" || fail "active wheel cache path is not bound to the exact Core source"
grep -Fq 'Root-Is-Purelib' "$FINALIZER" || fail "finalizer does not verify a pure-Python wheel"
grep -Fq 'py3-none-any' "$FINALIZER" || fail "finalizer does not verify the wheel compatibility tag"
pass "post-Omnibus wheel replacement is offline, exact, and pure Python"

grep -Fq 'compiled Agent version is $compiled_version, expected release VERSION $expected' "$FINALIZER" ||
  fail "finalizer lacks the compiled Agent VERSION fail-closed gate"
grep -Fq 'expected_version_prefix="Agent $expected - Commit: ${agent_sha:0:10} - Serialization version: "' \
  "$FINALIZER" || fail "finalizer does not match the real Agent version output and pinned source commit"
grep -Fq '"$expected_version_prefix"*'"' - Go version: go'"'*' "$FINALIZER" ||
  fail "finalizer does not require the complete compiled Agent version output shape"
grep -Fq 'expected_agent_version_prefix="Agent $VERSION - Commit: ${SHA:0:10} - Serialization version: "' \
  "$RECIPE" || fail "recipe does not match the real Agent version output and pinned source commit"
grep -Fq '"$expected_agent_version_prefix"*'"' - Go version: go'"'*' "$RECIPE" ||
  fail "recipe does not require the complete compiled Agent version output shape"
grep -Fq 'version-manifest.txt agent header is $manifest_header_version, expected $expected' "$FINALIZER" ||
  fail "finalizer lacks the version-manifest header gate"
grep -Fq 'version-manifest.txt datadog-agent component is $manifest_component_version, expected $expected' \
  "$FINALIZER" || fail "finalizer lacks the version-manifest component gate"
grep -Fq 'document.get("build_version")' "$FINALIZER" ||
  fail "finalizer lacks the JSON version-manifest build_version gate"
grep -Fq 'require_exact_field "$build_info" compiled_agent_version "$VERSION"' "$RECIPE" ||
  fail "canonical artifact verifier does not enforce compiled_agent_version"
grep -Fq 'require_exact_field "$agent_version_info" manifest_component_version "$VERSION"' "$RECIPE" ||
  fail "canonical artifact verifier does not enforce version-manifest evidence"
pass "compiled binary, Omnibus text manifest, and outer release VERSION must agree"

grep -Fq 'expected_version_prefix="System Probe $expected - Commit: ${agent_sha:0:10} - Serialization version: "' \
  "$FINALIZER" || fail "finalizer does not hard-gate system-probe VERSION and Agent commit"
grep -Fq 'write_system_probe_version_provenance "$verify_root" "$version"' "$FINALIZER" ||
  fail "archive re-verification does not execute the extracted system-probe version gate"
grep -Fq 'require_exact_field "$system_probe_version_info" agent_git_sha "$SHA"' \
  "$RECIPE" || fail "canonical artifact verifier does not bind system-probe provenance to full Agent SHA"
grep -Fq 'require_exact_field "$build_info" system_probe_binary_sha256 "$system_probe_binary_sha"' \
  "$RECIPE" || fail "canonical artifact verifier does not bind system-probe binary SHA-256"
grep -Fq 'require_exact_field "$build_info" generated_outputs_origin_agent_sha "$SEALED_ORIGIN_AGENT_SHA"' \
  "$RECIPE" || fail "canonical artifact verifier lost split generated-output provenance"
pass "main system-probe is freshly version-gated while reused generated outputs retain their origin"

grep -Fq 'preflight_fresh_build_capacity' "$RECIPE" ||
  fail "recipe lacks a pre-build blocks/inodes capacity gate"
grep -Fq 'report_reclaimable_non_authority' "$RECIPE" ||
  fail "capacity failure does not report exact non-authoritative cleanup candidates"
grep -Fq '本配方不会自动删除任何历史 attempt、seal 或 cache' "$RECIPE" ||
  fail "capacity gate does not preserve historical attempts and immutable cache"
grep -Fq 'home_required_blocks=$((build_bound + archive_bound + reserve))' "$RECIPE" ||
  fail "fresh-build capacity gate does not budget build plus final archive on the data filesystem"
grep -Fq 'root_required_blocks=$((runtime_payload + finalizer_peak + reserve))' "$RECIPE" ||
  fail "fresh-build capacity gate does not budget runtime plus finalizer peak on the root filesystem"
grep -Fq 'if [[ $build_device == "$root_device" ]]; then' "$RECIPE" ||
  fail "fresh-build capacity gate can double-count one free-space pool on a single-filesystem host"
grep -Fq 'capacity=$(read_filesystem_capacity "$BUILD_DIR")' "$RECIPE" ||
  fail "fresh-build capacity gate does not inspect the build/output filesystem"
grep -Fq 'capacity=$(read_filesystem_capacity "$INSTALL_DIR")' "$RECIPE" ||
  fail "fresh-build capacity gate does not inspect the install/finalizer filesystem"
grep -Fq '[[ $runtime_device == "$scratch_device" ]]' "$FINALIZER" ||
  fail "finalizer does not bind INSTALL_DIR and root-private scratch to one capacity pool"
grep -Fq '[[ $destination_device == "$build_device" ]]' "$FINALIZER" ||
  fail "finalizer does not bind OUTPUT_DIR to the sealed build filesystem"
grep -Fq 'if [[ $destination_device != "$scratch_device" ]]; then' "$FINALIZER" ||
  fail "finalizer lacks the split-filesystem destination capacity branch"
grep -Fq 'destination_required_blocks=$((archive_bound + reserve))' "$FINALIZER" ||
  fail "finalizer does not reserve one archive copy on a separate OUTPUT_DIR filesystem"
preflight_line=$(grep -nF 'preflight_bulk_workspace "$install_dir" "$bulk_build_scratch" "$output_dir"' \
  "$FINALIZER" | awk -F: 'NR == 1 { print $1 }' || :)
mutation_line=$(grep -nF 'log "running private-runtime patches from exact agent source $agent_sha"' \
  "$FINALIZER" | awk -F: 'NR == 1 { print $1 }' || :)
[[ $preflight_line =~ ^[0-9]+$ && $mutation_line =~ ^[0-9]+$ && $preflight_line -lt $mutation_line ]] ||
  fail "split-filesystem capacity gates do not precede the first runtime mutation"
pass "fresh build and finalizer account for split or shared filesystems before mutation"

grep -Fq "readonly PUBLICATION_RECIPE=$PUBLICATION_RECIPE" "$FINALIZER" ||
  fail "finalizer does not pin the exact destination-local publication recipe"
grep -Fq 'publication_recipe=$PUBLICATION_RECIPE' "$FINALIZER" ||
  fail "build provenance does not emit the pinned destination-local publication recipe"
grep -Fq 'require_exact_field "$build_info" publication_recipe "$PUBLICATION_RECIPE"' "$RECIPE" ||
  fail "canonical artifact verifier does not enforce the publication recipe"
grep -Fq 'readonly SYSTEM_PYTHON=/usr/bin/python3' "$FINALIZER" ||
  fail "destination-local publisher does not pin the system Python entry point"
grep -Fq 'readonly EXPECTED_SYSTEM_PYTHON_REAL=/usr/bin/python3.7' "$FINALIZER" ||
  fail "destination-local publisher does not pin the resolved Kylin Python file"
grep -Fq 'readonly EXPECTED_SYSTEM_PYTHON_SHA256=f5b09249fb172b46ba1cd4f33bd4cfd894328cc695e7640c2ef083d0ccae0b19' \
  "$FINALIZER" || fail "destination-local publisher does not pin the system Python bytes"
grep -Fq 'O_NOFOLLOW' "$FINALIZER" ||
  fail "destination-local publication does not reject symlink traversal at open"
grep -Fq 'O_EXCL' "$FINALIZER" ||
  fail "destination-local publication does not create staging files exclusively"
grep -Fq 'dir_fd=' "$FINALIZER" ||
  fail "destination-local publication does not hold and use the OUTPUT_DIR descriptor"
grep -Fq 'os.fsync' "$FINALIZER" ||
  fail "destination-local publication does not fsync staged data and directory metadata"
if grep -Fq 'ln -T -- "$archive_pass1" "$archive_path"' "$FINALIZER"; then
  fail "finalizer still hard-links root-filesystem scratch directly into OUTPUT_DIR"
fi
if grep -Fq 'mv -f -T -- "$sidecar_tmp" "$archive_path.sha256"' "$FINALIZER"; then
  fail "finalizer still uses cross-filesystem clobbering sidecar publication"
fi
grep -Fq 'archive_only' "$FINALIZER" ||
  fail "destination-local publisher does not expose archive-only recovery semantics"
grep -Fq 'archive_only' "$RECIPE" ||
  fail "streamed recipe does not admit the finalizer's archive-only recovery state"
pass "archive and sidecar use descriptor-relative atomic no-clobber publication with recovery"

grep -Fq 'require_exact_field "$gaussdb_info" integration_version "$GAUSSDB_INTEGRATION_VERSION"' "$RECIPE" ||
  fail "canonical artifact verifier does not enforce GaussDB integration provenance"
grep -Fq 'require_exact_field "$build_info" omnibus_integrations_core_git_sha "$PINNED_OMNIBUS_CORE_SHA"' \
  "$RECIPE" || fail "canonical artifact verifier lost the Omnibus core provenance gate"
grep -Fq 'require_exact_field "$build_info" integrations_core_git_sha "$CORE_SHA"' \
  "$RECIPE" || fail "canonical artifact verifier lost the integration core provenance gate"
pass "canonical tarball verifier rechecks integration and split-core provenance"

# publish.sh 按 arch 选配方，并把 aarch64 的受封存 attempt 路径限定在 arch=aarch64。
# x86_64 专属配方已于 2026-08-05 删除（GitHub 只出 arm），但这两条边界仍要守：
# aarch64 sealed 路径常量必须逐字节存活，且不得悄悄套用到其它架构上。
PUBLISH_SH="$SCRIPTS_DIR/publish/publish.sh"
bash -n "$PUBLISH_SH"
grep -Fq 'resolve_module_recipe "$m" "$arch"' "$PUBLISH_SH" ||
  fail "build_one_arch no longer resolves the Agent recipe through the architecture-aware selector"
grep -Fq 'if [ "$m" = dbdog-agent ] && [ "$arch" = aarch64 ]; then' "$PUBLISH_SH" ||
  fail "the aarch64 sealed attempt directory is no longer scoped precisely to arch=aarch64"
grep -Fq 'expected_rpath="/home/dbdog/work/dbdog-agent-${sha:0:8}-build2/out/$BUILT_ARTIFACT"' "$PUBLISH_SH" ||
  fail "the aarch64 sealed attempt path is no longer derived from the release anchor"
stray_publish_hex=$(grep -oE 'dbdog-agent-[0-9a-f]{8}-build' "$PUBLISH_SH" || :)
[ -z "$stray_publish_hex" ] ||
  fail "publish.sh hard-codes a short-SHA build path: $(printf '%s' "$stray_publish_hex" | tr '\n' ' ')"
# 构建要跑几小时，随锚控制物必须在花掉这些时间之前查一遍，而不是等 finalize 才暴露。
grep -Fq 'agent_preflight_anchor_controls "$BUILD_HOST" "$sha" "$core"' "$PUBLISH_SH" ||
  fail "publish.sh does not preflight the anchor-bearing controls before the Agent build"
grep -Fq 'PREFLIGHT_FAIL' "$PUBLISH_SH" ||
  fail "anchor preflight does not report actionable remote failures"
grep -Fq 'prepare-agent-anchor.sh' "$PUBLISH_SH" ||
  fail "anchor preflight failure does not point at the anchor preparer"
pass "publish.sh derives the aarch64 attempt path and preflights the anchor controls"

if [ -f "$WHEEL" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    actual_wheel_sha=$(sha256sum "$WHEEL" | awk '{ print $1 }')
  else
    actual_wheel_sha=$(shasum -a 256 "$WHEEL" | awk '{ print $1 }')
  fi
  [ "$actual_wheel_sha" = "$EXPECTED_WHEEL_SHA" ] ||
    fail "local GaussDB wheel SHA-256 differs from the pinned authority"
  python3 - "$WHEEL" <<'PYEOF'
from email.parser import BytesParser
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    metadata_name = next(name for name in archive.namelist() if name.endswith(".dist-info/METADATA"))
    wheel_name = next(name for name in archive.namelist() if name.endswith(".dist-info/WHEEL"))
    metadata = BytesParser().parsebytes(archive.read(metadata_name))
    wheel = BytesParser().parsebytes(archive.read(wheel_name))
assert metadata["Name"] == "datadog-gaussdb"
assert metadata["Version"] == "1.0.1"
assert wheel["Root-Is-Purelib"] == "true"
assert wheel.get_all("Tag") == ["py3-none-any"]
PYEOF
  pass "local wheel bytes match the pinned 1.0.1 pure-Python artifact"
fi

printf 'ALL PASS: Agent artifact version/provenance contracts\n'
