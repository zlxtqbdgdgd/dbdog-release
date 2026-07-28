#!/usr/bin/env bash
# Static and local-input contracts for the pinned Agent artifact finalizer.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
FINALIZER="$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v2.sh"
WRAPPER="$SCRIPTS_DIR/publish/agent-build/run-finalize-agent-runtime-v2.sh"
RUNNER="$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/run-agent-omnibus.sh"
RECIPE="$SCRIPTS_DIR/publish/recipes/dbdog-agent.sh"
CORE_DIR="$RELEASE_DIR/../dbdog-agent-core"
WHEEL="${DBDOG_GAUSSDB_WHEEL:-$CORE_DIR/gaussdb/dist/datadog_gaussdb-1.0.1-py3-none-any.whl}"
EXPECTED_WHEEL_SHA=c7ee1aa1521e1715845423b8f61268e7765c41a0ee8fd5337e638ab7816a9e1f

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
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
pass "historical v12/v1 controls remain byte-identical"

actual_finalizer_sha=$(file_sha256 "$FINALIZER")
actual_wrapper_sha=$(file_sha256 "$WRAPPER")
actual_runner_sha=$(file_sha256 "$RUNNER")
actual_control_info_sha=$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/CONTROL-INFO")
actual_control_manifest_sha=$(file_sha256 "$SCRIPTS_DIR/publish/agent-build/omnibus-kylin-platform-v13/CONTROL.sha256")
grep -Fq "readonly FINALIZER_SHA256=$actual_finalizer_sha" "$WRAPPER" ||
  fail "v2 wrapper does not pin the actual v2 finalizer bytes"
grep -Fq "readonly FINALIZER_SHA256=$actual_finalizer_sha" "$RECIPE" ||
  fail "recipe does not pin the actual v2 finalizer bytes"
grep -Fq "readonly FINALIZER_WRAPPER_SHA256=$actual_wrapper_sha" "$RECIPE" ||
  fail "recipe does not pin the actual v2 wrapper bytes"
grep -Fq "readonly RUNNER_SHA256=$actual_runner_sha" "$RECIPE" ||
  fail "recipe does not pin the actual v13 runner bytes"
grep -Fq "readonly CONTROL_INFO_SHA256=$actual_control_info_sha" "$RECIPE" ||
  fail "recipe does not pin the actual v13 CONTROL-INFO bytes"
grep -Fq "readonly CONTROL_MANIFEST_SHA256=$actual_control_manifest_sha" "$RECIPE" ||
  fail "recipe does not pin the actual v13 CONTROL.sha256 bytes"
pass "v13/v2 control hashes form one closed static chain"

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
grep -Fq 'readonly EXPECTED_INTEGRATION_CORE_SHA=d725d9847379ff919b60a2f35e1f41af001e6054' "$FINALIZER" ||
  fail "finalizer lost the post-Omnibus integration source identity"
grep -Fq 'core_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "Omnibus success marker no longer uses the sealed core identity"
grep -Fq 'omnibus_integrations_core_git_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "build provenance does not distinguish the Omnibus core"
grep -Fq 'integrations_core_git_sha=$core_sha' "$FINALIZER" ||
  fail "build provenance does not identify the integration source core"
pass "sealed Omnibus input and post-build integration source have separate identities"

grep -Fq 'omnibus-kylin-platform-v13' "$FINALIZER" || fail "finalizer is not pinned to v13"
grep -Fq 'BUILD_DIR=/home/dbdog/work/dbdog-agent-62ad2979-build1' "$RECIPE" ||
  fail "recipe is not pinned to the isolated v13 release attempt"
grep -Fq 'DBDOG_PACKAGE_VERSION="$VERSION"' "$RECIPE" ||
  fail "recipe does not pass the explicit release VERSION authority into v13"
grep -Fq '^7[.]81[.]0-dbdog[.][1-9][0-9]*$' "$RECIPE" ||
  fail "recipe does not bind releases to the synchronized official 7.81.0 baseline"
if grep -Fq 'runner_mode=(--adopt-post-health-v2)' "$RECIPE" ||
   grep -Fq 'runner_mode=(--resume-v9-retry6-post-health)' "$RECIPE"; then
  fail "v13 recipe still guesses a legacy resume mode"
fi
grep -Fq 'v13 release attempt 只接受空的 /opt/dbdog-agent' "$RECIPE" ||
  fail "v13 recipe does not fail closed on a shared old install tree"
pass "v13 receives the explicit official-baseline package version authority"

grep -Fq 'SYSTEM_PROBE_SEED_BUILD_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build2' "$RECIPE" ||
  fail "recipe lost the exact validated system-probe seed attempt"
grep -Fq 'SEALED_SYSTEM_PROBE_OUTPUTS_SHA256=ae13f9dbc83fd4d219a883f029baa26073cf88b9510bde5f22bc1d84b3688f52' \
  "$RECIPE" || fail "recipe does not pin the sealed 69-output manifest"
grep -Fq 'RELEASE_SYSTEM_PROBE_OUTPUTS_SHA256=7ea1f502bfe9ed2c40089d1ecc3c554fe382e946f72029e9630b4943dceecc02' \
  "$RECIPE" || fail "recipe does not pin the release-relocated output manifest"
grep -Fq 'RELEASE_SYSTEM_PROBE_MARKER_SHA256=bc45c1f60977b7dff248494af7fb6607011aed837372819b5bab8f0c438e457f' \
  "$RECIPE" || fail "recipe does not pin the release handoff marker"
grep -Fq 'generated_outputs_origin_agent_sha=$SEALED_ORIGIN_AGENT_SHA' "$RECIPE" ||
  fail "recipe does not distinguish generated-output origin from release Agent source"
grep -Fq 'git clone --local --no-hardlinks --no-checkout --no-tags' "$RECIPE" ||
  fail "fresh source is not recreated independently from the pinned Agent mirror"
grep -Fq 'relative=${source_path#"$SEALED_SYSTEM_PROBE_SOURCE_PREFIX"}' "$RECIPE" ||
  fail "system-probe outputs are not copied through a strict sealed-prefix mapping"
grep -Fq 'target_prefix="$BUILD_DIR/src/"' "$RECIPE" ||
  fail "sealed output manifest is not relocated to the v13 attempt"
grep -Fq 'mv -- "$FRESH_SEED_PROGRESS" "$FRESH_SEED_MARKER"' "$RECIPE" ||
  fail "fresh seed lacks an atomic complete-marker transition"
grep -Fq '"$RUNNER" --dbdog-agent-pipeline-lock-held "$BUILD_DIR" </dev/null >&2' "$RECIPE" ||
  fail "v13 runner can consume the remaining SSH-fed recipe or escape the shared pipeline lock"
grep -Fq 'exec {pipeline_lock_fd}<"$PIPELINE_LOCK"' "$RECIPE" ||
  fail "recipe does not open the root-owned pipeline lock read-only"
if grep -Fq 'exec {pipeline_lock_fd}>"$PIPELINE_LOCK"' "$RECIPE"; then
  fail "recipe tries to truncate the root-owned pipeline lock as dbdog"
fi
if grep -Eq 'mktemp "?\$BUILD_DIR/\.v13-(seed-index|seed-marker-verify|sealed-marker-verify)' "$RECIPE"; then
  fail "pre-seed validation temp files can poison an otherwise empty release attempt after interruption"
fi
if grep -Eq 'cp .*"?\$SYSTEM_PROBE_SEED_BUILD_DIR/src/?"?[[:space:]]' "$RECIPE" ||
   grep -Eq 'rsync .*SYSTEM_PROBE_SEED_BUILD_DIR' "$RECIPE"; then
  fail "recipe copies the mutable build2 source tree wholesale"
fi
for excluded in 'omnibus/pkg' bazel-bin bazel-out bazel-src bazel-testlogs; do
  grep -Fq "$excluded" "$RECIPE" || fail "fresh seed does not explicitly reject inherited $excluded"
done
pass "fresh v13 attempt is recreated from pinned Git plus an explicitly originated 69-output handoff"

for required in --no-index --no-deps --force-reinstall --no-cache-dir; do
  grep -Fq -- "$required" "$FINALIZER" || fail "offline wheel install lacks $required"
done
grep -Fq 'GAUSSDB_WHEEL_SHA256=c7ee1aa1521e1715845423b8f61268e7765c41a0ee8fd5337e638ab7816a9e1f' \
  "$FINALIZER" || fail "finalizer does not pin the exact GaussDB wheel"
grep -Fq 'Root-Is-Purelib' "$FINALIZER" || fail "finalizer does not verify a pure-Python wheel"
grep -Fq 'py3-none-any' "$FINALIZER" || fail "finalizer does not verify the wheel compatibility tag"
pass "post-Omnibus wheel replacement is offline, exact, and pure Python"

grep -Fq 'compiled Agent version is $compiled_version, expected release VERSION $expected' "$FINALIZER" ||
  fail "finalizer lacks the compiled Agent VERSION fail-closed gate"
grep -Fq 'expected_version_prefix="Agent $expected - Commit: ${agent_sha:0:10} - Serialization version: "' \
  "$FINALIZER" || fail "finalizer does not match the real Agent version output and pinned source commit"
grep -Fq '"$expected_version_prefix"*'"' - Go version: go'"'*' "$FINALIZER" ||
  fail "finalizer does not require the complete compiled Agent version output shape"
grep -Fq 'expected_agent_version_prefix="Agent $VERSION - Commit: ${PINNED_AGENT_SHA:0:10} - Serialization version: "' \
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
grep -Fq 'require_exact_field "$system_probe_version_info" agent_git_sha "$PINNED_AGENT_SHA"' \
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
pass "fresh build preflights blocks/inodes and never auto-deletes historical authority"

grep -Fq 'require_exact_field "$gaussdb_info" integration_version "$GAUSSDB_INTEGRATION_VERSION"' "$RECIPE" ||
  fail "canonical artifact verifier does not enforce GaussDB integration provenance"
grep -Fq 'require_exact_field "$build_info" omnibus_integrations_core_git_sha "$PINNED_OMNIBUS_CORE_SHA"' \
  "$RECIPE" || fail "canonical artifact verifier lost the Omnibus core provenance gate"
grep -Fq 'require_exact_field "$build_info" integrations_core_git_sha "$PINNED_INTEGRATION_CORE_SHA"' \
  "$RECIPE" || fail "canonical artifact verifier lost the integration core provenance gate"
pass "canonical tarball verifier rechecks integration and split-core provenance"

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
