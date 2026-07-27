#!/usr/bin/env bash
# Static and local-input contracts for the pinned Agent artifact finalizer.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
FINALIZER="$SCRIPTS_DIR/publish/agent-build/finalize-agent-runtime-v1.sh"
RECIPE="$SCRIPTS_DIR/publish/recipes/dbdog-agent.sh"
CORE_DIR="$RELEASE_DIR/../dbdog-agent-core"
WHEEL="$CORE_DIR/gaussdb/dist/datadog_gaussdb-1.0.0-py3-none-any.whl"
EXPECTED_WHEEL_SHA=06fd5eea7acd51a0ebf519be58a2700f1ca4142a13b0668cb7f5e66ef022f7f6

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

bash -n "$FINALIZER"
bash -n "$RECIPE"
if grep -Eq 'GAUSSDB_VERSION|DEFAULT_GAUSSDB_VERSION|gaussdb_version=' "$FINALIZER" "$RECIPE"; then
  fail "Agent artifact controls still overload a target GaussDB version variable"
fi
grep -Fq 'readonly EXPECTED_GAUSSDB_INTEGRATION_VERSION=1.0.0' "$FINALIZER" ||
  fail "finalizer does not pin the integration package version to 1.0.0"
grep -Fq 'integration_version=$gauss_import_version' "$FINALIZER" ||
  fail "build provenance does not derive integration_version from installed package evidence"
pass "GaussDB integration version is package-owned and is not a target database version"

grep -Fq 'readonly OMNIBUS_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f' "$FINALIZER" ||
  fail "finalizer lost the sealed Omnibus core identity"
grep -Fq 'readonly EXPECTED_INTEGRATION_CORE_SHA=662ad3974b950f67cf162fb273c180d08cc87a06' "$FINALIZER" ||
  fail "finalizer lost the post-Omnibus integration source identity"
grep -Fq 'core_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "Omnibus success marker no longer uses the sealed core identity"
grep -Fq 'omnibus_integrations_core_git_sha=$OMNIBUS_CORE_SHA' "$FINALIZER" ||
  fail "build provenance does not distinguish the Omnibus core"
grep -Fq 'integrations_core_git_sha=$core_sha' "$FINALIZER" ||
  fail "build provenance does not identify the integration source core"
pass "sealed Omnibus input and post-build integration source have separate identities"

grep -Fq 'omnibus-kylin-platform-v11' "$FINALIZER" || fail "finalizer is not pinned to v11"
grep -Fq 'BUILD_DIR=/home/dbdog/work/dbdog-agent-4c39489b-build2' "$RECIPE" ||
  fail "recipe is not pinned to the v11 build2 attempt"
grep -Fq 'DBDOG_PACKAGE_VERSION="$VERSION"' "$RECIPE" ||
  fail "recipe does not pass the explicit release VERSION authority into v11"
pass "v11/build2 receives an explicit package version authority"

for required in --no-index --no-deps --force-reinstall --no-cache-dir; do
  grep -Fq -- "$required" "$FINALIZER" || fail "offline wheel install lacks $required"
done
grep -Fq 'GAUSSDB_WHEEL_SHA256=06fd5eea7acd51a0ebf519be58a2700f1ca4142a13b0668cb7f5e66ef022f7f6' \
  "$FINALIZER" || fail "finalizer does not pin the exact GaussDB wheel"
grep -Fq 'Root-Is-Purelib' "$FINALIZER" || fail "finalizer does not verify a pure-Python wheel"
grep -Fq 'py3-none-any' "$FINALIZER" || fail "finalizer does not verify the wheel compatibility tag"
pass "post-Omnibus wheel replacement is offline, exact, and pure Python"

grep -Fq 'compiled Agent version is $compiled_version, expected release VERSION $expected' "$FINALIZER" ||
  fail "finalizer lacks the compiled Agent VERSION fail-closed gate"
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
assert metadata["Version"] == "1.0.0"
assert wheel["Root-Is-Purelib"] == "true"
assert wheel.get_all("Tag") == ["py3-none-any"]
PYEOF
  pass "local wheel bytes match the pinned 1.0.0 pure-Python artifact"
fi

printf 'ALL PASS: Agent artifact version/provenance contracts\n'
