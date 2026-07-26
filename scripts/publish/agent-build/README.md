# dbdog-agent build controls

This directory tracks the small, exact controls for the pinned Kylin V10
AArch64 build. It deliberately does not contain toolchains, source archives,
Go modules, Ruby gems, Bazel repositories, Omnibus downloads, or compiled
tools. Those persistent inputs remain under `/home/dbdog/cache/dbdog-agent`
and are verified by the v7 manifest, the active v10 control overlay, and the
post-build dependency seal.

The pinned source identities are:

- dbdog-agent: `4c39489b8c0b7fb7a46af88062fb9aadf2c08264`
- integrations-core: `7a4247599b029f1aca10d2cb63491d535fbd502f`
- platform: Kylin V10 AArch64
- base manifest: `manifests/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7`

## Canonical installation

Install the four files below `omnibus-kylin-platform-v10/` without changing
their bytes at:

`/home/dbdog/cache/dbdog-agent/control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v10/`

The directory is `root:root` mode `0555`; `run-agent-omnibus.sh` is mode
`0555`; the other three files are mode `0444`. `CONTROL.sha256` verifies the
three overlay files plus the external pinned patchelf binary at its
cache-relative path.

The v10 runner maps native Kylin to Omnibus's existing `health_check_ldd`
implementation by transforming only the attempt-local Bundler copy and proving
that the immutable package cache retained its original digest. It also has two
explicit build1-only transition entries: one can resume the exact v9 retry6
post-health tail from the preserved pristine pre-strip snapshot, and the other
can adopt the already completed post-health v2 state after verifying its log,
resume record, version manifest, 282 debug files, and staged SELinux policy.
The separate `omnibus-kylin-post-health-v1/` directory is retained as the exact
supplemental evidence used by that one transition; it is not added to the
active v10 overlay's four-file inventory.

The complete patchelf authority must be installed separately at:

`/home/dbdog/cache/dbdog-agent/tools/patchelf/0.18.0-aarch64-kylin10-v2/`

It has exactly five nodes: the root directory, `PATCHELF-INFO`, `SHA256SUMS`,
`bin`, and `bin/patchelf`. Both directories and the executable are
`root:root` mode `0555`; the two metadata files are `root:root` mode `0444`.
The executable reports exactly `patchelf 0.18.0` and is linked with static
libstdc++ and libgcc while retaining a Kylin-compatible dynamic glibc floor.

The tracked `patchelf-0.18.0-aarch64-kylin10-v2/` directory is metadata-only:
it records the source, build, binary, and inventory checksums but intentionally
does not put the compiled binary in this repository. It is not a replacement
for the complete immutable authority above.

Install these three controls as `root:root` mode `0555`:

- `finalize-agent-runtime-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/finalize-agent-runtime-v1.sh`
- `run-finalize-agent-runtime-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v1.sh`
- `seal-agent-build-dependencies-v1.sh` →
  `/home/dbdog/cache/dbdog-agent/controls/seal-agent-build-dependencies-v1.sh`

The streamed publish recipe never installs controls, edits sudoers, or performs
non-interactive privilege escalation. Do not grant the finalizer wrapper
`NOPASSWD`: the finalizer intentionally executes the completed embedded
runtime while validating it. An administrator must invoke the wrapper
explicitly as root. It accepts exactly one `7.81.1-dbdog.N` argument and
resets the finalizer environment. A later publish invocation verifies and
reuses the root-owned artifact and sidecar.

`/run/dbdog-agent-finalize` contains only the root-private build lock. Large
archive and extraction work is created below the root-owned mode `0700`
`/var/lib/dbdog-agent-finalize` tree. Before changing the installed runtime,
the finalizer checks available blocks and inodes with a 512 MiB reserve. It
deletes the second deterministic archive pass before extraction and deletes
the verified extraction before atomically publishing the first pass.

After a successful Omnibus build, run
`seal-agent-build-dependencies-v1.sh` as root. The control filename retains
its interface version, while its current seal format and canonical output are
`omnibus-cache-v2`:

`/home/dbdog/cache/dbdog-agent/seals/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7/omnibus-cache-v2`

The seal declares `partial-no-clean-host-offline-replay`. Moving these small
controls alone to another host is insufficient: migrate the complete cache
root, satisfy its recorded system references, and pass the seal's `VERIFY.sh`.
The v2 seal records four host-system references without copying their bytes:
the runuser shim/target plus exact `checkmodule`, `semodule_package`, and
`libsepol.so.1` paths. Replay verifies each recorded RPM identity, SHA-256,
size, mode, canonical path, and executable/readable contract.

## Persistent dependency and action-cache contract

The cache is a reusable build input, not disposable state for a single build.
Pinned archives, Git mirrors, the Bazel repository cache, `distdir`, manifests,
bundle packages, and other versioned dependency bytes remain under the cache
root. Their exact versions and checksums are selected by the manifest and
controls. A missing or changed dependency is an error: the publish recipe
stops instead of downloading a substitute or guessing a version.

`bazel/disk` is different. It is a reusable action-output cache that speeds up
later builds, but it is not source-dependency authority and is excluded from
the seal's authoritative objects. Its recursive sharing contract is group
`dbdog`, group-readable and group-writable files, and group `rwx` plus setgid
directories. Its `tmp` entry must be a real directory and pass an atomic
write/rename/delete probe as the `dbdog` user. Permission normalization is
limited to `bazel/disk`; it must not recursively mutate `bazel/repository`,
`distdir`, manifests, or the other immutable dependency authorities.

## Frozen SHA-256 values

```text
abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812  omnibus-kylin-platform-v10/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v10/agent-build-kylin-platform.patch
6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a  omnibus-kylin-platform-v10/CONTROL-INFO
f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac  omnibus-kylin-platform-v10/CONTROL.sha256
5c3df10e215042c80c46405bdeaf1e5531ab206817a2f48021e67d5d30266735  omnibus-kylin-post-health-v1/resume-agent-omnibus.rb
63fe0ba275c72239e3db22b6612a5d313fa5bc54ab101416e09a2a4d39605987  omnibus-kylin-post-health-v1/omnibus-healthcheck-kylin.patch
a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7  patchelf-0.18.0-aarch64-kylin10-v2/PATCHELF-INFO
4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7  patchelf-0.18.0-aarch64-kylin10-v2/SHA256SUMS
01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf  external tools/patchelf/0.18.0-aarch64-kylin10-v2/bin/patchelf
237f20579fbb1e9155183211d07cc5b6bbf45908d912021b21a87a17d7c9f79d  finalize-agent-runtime-v1.sh
b9f660d25db9c349f0affceb48c0274b23630e5c15174dd223b46bbe76ab8704  run-finalize-agent-runtime-v1.sh
ae4d099588ec5ae3181009bd49a3af1498755fd654673b73534498c55009b2c3  seal-agent-build-dependencies-v1.sh
b05db3ecafa89588248757a64acdf868664142b62318b66553b9db896e177a37  ../recipes/dbdog-agent.sh
```

## Historical overlays

`omnibus-kylin-platform-v3/`, `omnibus-kylin-platform-v4/`,
`omnibus-kylin-platform-v5/`, `omnibus-kylin-platform-v6/`,
`omnibus-kylin-platform-v7/`, `omnibus-kylin-platform-v8/`, and
`omnibus-kylin-platform-v9/` are retained
only as historical evidence. v4
reached the Python RPATH rewrite but failed because the automatically selected
patchelf toolchain had an empty executable path. v5 added the pinned external
patchelf authority and the reusable Bazel action-cache contract, then failed
during the agent Go compile because its filtered environment made Go use the
2 GiB tmpfs. v6 retained those fixes and forwarded a verified build-filesystem
Go temporary directory across the clean environment boundary and into nested
Go/cgo commands. Its retry2 then stopped when the upstream GLIBC_2.17
system-probe gate rejected symbols that are valid on the pinned Kylin V10
GLIBC_2.28 platform. v7 aligned that gate with the pinned platform ceiling.
The v8 controls additionally bound the exact SELinux compiler, packager, and
libsepol host dependencies into the dependency seal as verified system
references. Its preflight nevertheless produced a false positive when a
whole-package `rpm -V` could not read an unrelated `root:root` mode `0600`
file in the dbdog package. v9 instead checks the exact unique `rpm --dump`
record and actual owning-package identity for each of the three SELinux
targets. Its retry6 completed every software build and stopped only when old
Omnibus did not recognize the native Kylin platform during the final health
check. v10 adds the exact Kylin health mapping and controlled post-health
transition while retaining the v9 platform patch byte-for-byte. The active
recipe, finalizer, sealer, and root wrapper accept only v10.
