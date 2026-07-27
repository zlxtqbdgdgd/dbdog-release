# dbdog-agent build controls

This directory tracks the small, exact controls for the pinned Kylin V10
AArch64 build. The active control generation is v11, the active attempt is
`/home/dbdog/work/dbdog-agent-4c39489b-build2`, and the current release version
authority is exactly `7.81.1-dbdog.3`.

Toolchains, source archives, Go modules, Ruby gems, Bazel repositories,
Omnibus downloads, and compiled tools are not stored here. Persistent inputs
remain below `/home/dbdog/cache/dbdog-agent` and are verified by the v7 base
manifest, the active v11 control overlay, and the dependency seal.

## Pinned identities and their roles

- dbdog-agent source:
  `4c39489b8c0b7fb7a46af88062fb9aadf2c08264`
- Omnibus integrations-core source:
  `7a4247599b029f1aca10d2cb63491d535fbd502f`
- post-Omnibus GaussDB integration source:
  `662ad3974b950f67cf162fb273c180d08cc87a06`
- GaussDB integration package: `datadog-gaussdb` `1.0.0`
- release version: `7.81.1-dbdog.3`
- platform: Kylin V10 AArch64
- build attempt: `/home/dbdog/work/dbdog-agent-4c39489b-build2`
- base manifest:
  `manifests/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7`

The two integrations-core commits intentionally serve different purposes.
The v7 manifest and Omnibus dependency closure remain bound to `7a424759...`.
After Omnibus succeeds, the finalizer verifies that `662ad397...` exists in the
pinned core mirror and installs the separately pinned GaussDB wheel over the
Omnibus copy. The build provenance therefore records both
`omnibus_integrations_core_git_sha` and `integrations_core_git_sha`.

The integration version is the version of the packaged collector code. It is
not the version of a monitored GaussDB server. Target database version and
environment information are discovered at runtime.

## Active v11 overlay and explicit Agent version

Install the four files below `omnibus-kylin-platform-v11/` without changing
their bytes at:

`/home/dbdog/cache/dbdog-agent/control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v11/`

The directory is `root:root` mode `0555`; `run-agent-omnibus.sh` is mode
`0555`; the other three files are mode `0444`. `CONTROL.sha256` verifies the
three overlay files plus the external pinned patchelf binary at its
cache-relative path.

The v11 runner retains the v10 Kylin health-check and native-build controls,
but it no longer derives the package version from the build machine's
incomplete Git tag namespace. For the current build, the recipe passes
`DBDOG_PACKAGE_VERSION=7.81.1-dbdog.3`. The runner:

1. rejects a pre-existing `agent-version.cache`;
2. creates an attempt-local, exact version cache;
3. verifies `dda inv -- agent.version --url-safe` resolves to
   `7.81.1-dbdog.3`;
4. verifies the compiled Agent and Omnibus version manifest report the same
   version; and
5. removes the temporary cache on exit.

The finalizer independently requires agreement among the outer release
version, `agent version`, the `version-manifest.txt` header and component row,
and `version-manifest.json`'s `build_version`. The canonical artifact verifier
rechecks the resulting hashes and provenance before publication. A build that
internally reports `7.79.0` or any other version cannot be published as
`7.81.1-dbdog.3`.

## GaussDB integration wheel authority

The exact wheel must be installed as `root:root` mode `0444` at:

`/home/dbdog/cache/dbdog-agent/sources/python/datadog_gaussdb-1.0.0-py3-none-any.whl`

Its SHA-256 is:

`06fd5eea7acd51a0ebf519be58a2700f1ca4142a13b0668cb7f5e66ef022f7f6`

The finalizer verifies the canonical path, ownership, mode, checksum, package
name, package version, `Root-Is-Purelib: true`, and the exact
`py3-none-any` tag. It then installs the wheel with embedded pip using
`--no-index --no-deps --force-reinstall --no-cache-dir`. Import metadata and
distribution metadata must both report `1.0.0`, exactly one distribution may
be present, and the extracted archive is checked again. The artifact records
the source commit, wheel path and checksum, and `integration_version=1.0.0`.

## Canonical tools and root controls

The complete patchelf authority must be installed at:

`/home/dbdog/cache/dbdog-agent/tools/patchelf/0.18.0-aarch64-kylin10-v2/`

It has exactly five nodes: the root directory, `PATCHELF-INFO`, `SHA256SUMS`,
`bin`, and `bin/patchelf`. Both directories and the executable are
`root:root` mode `0555`; the two metadata files are `root:root` mode `0444`.
The executable reports exactly `patchelf 0.18.0` and is linked with static
libstdc++ and libgcc while retaining a Kylin-compatible dynamic glibc floor.

The tracked `patchelf-0.18.0-aarch64-kylin10-v2/` directory is metadata-only.
It does not replace the complete immutable authority above.

Install these controls as `root:root` mode `0555`:

- `finalize-agent-runtime-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/finalize-agent-runtime-v1.sh`
- `run-finalize-agent-runtime-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v1.sh`
- `seal-agent-build-dependencies-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/seal-agent-build-dependencies-v1.sh`

The current wrapper is pinned to build2, the v11 overlay, Omnibus core
`7a424759...`, post-Omnibus integration core `662ad397...`, and the current
finalizer checksum. After the Omnibus handoff and dependency-seal checks pass,
the current release is finalized interactively with:

```bash
sudo /home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v1.sh \
  7.81.1-dbdog.3
```

Do not grant this command `NOPASSWD`: the finalizer deliberately executes the
completed embedded runtime while validating it. The streamed publish recipe
does not install controls, edit sudoers, or perform non-interactive privilege
escalation. A later publish invocation verifies and reuses the root-owned
artifact and sidecar under:

`/home/dbdog/work/dbdog-agent-4c39489b-build2/out/`

`/run/dbdog-agent-finalize` contains only the root-private build lock. Large
archive and extraction work is created below the root-owned mode `0700`
`/var/lib/dbdog-agent-finalize` tree. The finalizer checks blocks and inodes
with a 512 MiB reserve, proves two deterministic archive passes are identical,
removes the second pass before extraction, verifies the extracted runtime,
and atomically publishes the first pass.

## Dependency seal and persistent cache

The base dependency identity remains:

`/home/dbdog/cache/dbdog-agent/seals/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7/omnibus-cache-v2`

The seal declares `partial-no-clean-host-offline-replay`. Moving only the
small tracked controls to another host is insufficient: migrate the complete
cache root, satisfy its recorded system references, and pass `VERIFY.sh`.
The seal records the runuser shim/target and the exact `checkmodule`,
`semodule_package`, and `libsepol.so.1` host references, including RPM
identity, SHA-256, size, mode, canonical path, and execution/read contracts.

The dependency seal was generated from the build1/v10 dependency closure and
intentionally retains that identity. v11 changes only the explicit Agent
version authority; it does not change the source, compiler, dependency, or
platform-patch closure. The active recipe therefore verifies two separate
control layers: `SEAL_*` pins must match the existing v10 seal, while the live
Omnibus handoff must match the v11 runner. The tracked
`seal-agent-build-dependencies-v1.sh` is the expected generator for that v10
seal and no v11 relabeling or seal regeneration is required.

The cache is a reusable build input, not disposable state. Pinned archives,
Git mirrors, the Bazel repository cache, `distdir`, manifests, bundles, and
other versioned dependency bytes remain under the cache root. Missing or
changed authority is an error; the recipe does not download a substitute or
guess a version.

`bazel/disk` is only a reusable action-output cache. It is excluded from the
seal's authoritative objects. Its sharing contract is group `dbdog`,
group-readable and group-writable files, and group `rwx` plus setgid
directories. Permission normalization is limited to `bazel/disk` and must not
mutate the immutable dependency authorities.

## Current SHA-256 values

The first four v10 entries identify the dependency seal; the following v11
entries identify the active live build handoff.

```text
abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812  omnibus-kylin-platform-v10/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v10/agent-build-kylin-platform.patch
6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a  omnibus-kylin-platform-v10/CONTROL-INFO
f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac  omnibus-kylin-platform-v10/CONTROL.sha256
b28e75b7bc1318a82b5584e747e83b11d596ac7b403292162e8c7599c3f58184  omnibus-kylin-platform-v11/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v11/agent-build-kylin-platform.patch
3c5af9befdf56c45ebfb14e366b3324f84aa9f0f81390e47a5357beca70a5647  omnibus-kylin-platform-v11/CONTROL-INFO
5bf2b308b3d3e936c95080b4577630c65f0606008ce652ae06b5c36b20551c81  omnibus-kylin-platform-v11/CONTROL.sha256
a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7  patchelf-0.18.0-aarch64-kylin10-v2/PATCHELF-INFO
4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7  patchelf-0.18.0-aarch64-kylin10-v2/SHA256SUMS
01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf  external tools/patchelf/0.18.0-aarch64-kylin10-v2/bin/patchelf
06fd5eea7acd51a0ebf519be58a2700f1ca4142a13b0668cb7f5e66ef022f7f6  external sources/python/datadog_gaussdb-1.0.0-py3-none-any.whl
5f0e666753426540c5767e96eeadd8b83c51db461fbb73dfa1c00867e4d2e400  finalize-agent-runtime-v1.sh
2a59314b66e295e00bb13c7409b445f7c795c74f7d4eccab8bae3811424f58df  run-finalize-agent-runtime-v1.sh
ae4d099588ec5ae3181009bd49a3af1498755fd654673b73534498c55009b2c3  seal-agent-build-dependencies-v1.sh
94440a6382cc629897f87cf957d4928fa9916ea1e0bfd5ed787bb62c34c48860  ../recipes/dbdog-agent.sh
```

## Historical overlays

`omnibus-kylin-platform-v3/` through `omnibus-kylin-platform-v9/` are retained
as historical evidence. v4 reached the Python RPATH rewrite but failed because
the selected patchelf executable path was empty. v5 added the pinned patchelf
authority and reusable Bazel action cache, then exhausted the 2 GiB tmpfs
during Go compilation. v6 moved Go temporary work to the build filesystem. v7
aligned the system-probe GLIBC gate with Kylin V10's GLIBC 2.28. v8 and v9
tightened SELinux system-reference checks. v10 added the exact Kylin health
mapping and controlled post-health transition. It remains the dependency-seal
authority, but its ambient incomplete Git tag namespace produced a compiled
Agent version of `7.79.0` while the outer artifact was named
`7.81.1-dbdog.2`.

v11 retains the established Kylin build and dependency contract and adds the
explicit release-version authority and post-build version gates described
above. The active recipe, finalizer, and root wrapper accept only the v11
handoff and build2 paths.
