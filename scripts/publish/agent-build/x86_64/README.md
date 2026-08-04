# dbdog-agent x86_64 canonical build

This directory documents the canonical native x86_64 build controls consumed
by `../../recipes/dbdog-agent-x86_64.sh`. It intentionally does **not** mirror
`../README.md` (the aarch64/Kylin V10 control chain) byte-for-byte: x86_64 has
no v1-v14 historical iteration to reconcile, no sealed dependency closure, and
no pinned custom-built `patchelf`. The recipe rebuilds Agent, Trace Agent,
Process Agent and System Probe from a fresh checkout on every run instead of
reusing any previously-installed tree — see `dbdog-agent/dbdog-deploy/build/x86_64/README.md`
in the Agent repo for the matching builder-side contract (inputs, verification
commands, output shape).

## Shared anchor with aarch64

Both architectures must come from the same `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`
Agent/Core source anchor and the same dbdog version (Global Constraint). The
x86_64 recipe pins the identical values as `../recipes/dbdog-agent.sh`:

- release Agent source: `62ad29793b02139448b76bc85fc406491a08bf58`
- post-Omnibus GaussDB integration source: `612be7bea397c87df707489599c02ed623c29631`
- GaussDB package: `datadog-gaussdb==1.0.1`
- GaussDB wheel SHA-256 (pure Python, architecture-independent):
  `f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f`
- install root: `/opt/dbdog-agent`
- dbdog version template: `7.81.0-dbdog.N` (`N` from 1)

`scripts/test-agent-x86_64-artifact-contracts.sh` cross-checks these constants
byte-for-byte between the two recipe files so they cannot silently drift apart.

## What is different from aarch64

- No pre-cached wheel blob is trusted. The recipe rebuilds the GaussDB wheel
  from the same `CORE_SHA` checkout on the build host
  (`python3 -m pip wheel --no-deps --no-build-isolation --no-index`) and
  requires the resulting SHA-256 to equal the pinned value above — a
  reproducibility proof rather than an assumption.
- `patchelf` is taken from the build host's own package manager (Omnibus's own
  build steps shell out to it while packaging, same as the aarch64 pipeline);
  it is not pinned by hash. This recipe's own post-build verification uses
  `readelf` instead — see "Linkage and path-leak gates" below.
- **Agent Data Plane (ADP)** (`embedded/bin/agent-data-plane`) is a separate
  precompiled binary Omnibus fetches via `source url:`/`sha256:`
  (`omnibus/config/software/datadog-agent-data-plane.rb`, driven by
  `AGENT_DATA_PLANE_VERSION`/`AGENT_DATA_PLANE_HASH_LINUX_AMD64` at Omnibus
  invocation time), not something built from `dbdog-agent` source. Both
  architectures pin the same `ADP_VERSION=1.2.2` identity. aarch64 additionally
  cross-checks against an independently pre-verified `ADP_INPUT_SHA256` for
  the `linux-arm64` input tarball (staged in its sealed cache). **This repo has
  never independently verified the equivalent `linux-amd64` value for x86_64**
  (it lives behind Datadog's internal `binaries.ddbuild.io`, not a public
  release we can fetch and hash here), so the x86_64 recipe does not fabricate
  a pinned value to match. Instead it reads `locked_source.sha256` for
  `software.datadog-agent-data-plane` straight out of Omnibus's own
  `version-manifest.json` after the build, records that measured value in
  `provenance/agent-data-plane.txt` as `input_source_sha256`, and tags it
  explicitly with `input_source_sha256_authority=measured_from_omnibus_version_manifest_not_independently_pinned`
  so no consumer can mistake it for an independently-verified pin. Establishing
  that pin for x86_64 is deferred to whoever provisions the first real x86_64
  builder (Task 7).
- Source and output paths follow the same `REPO_ROOT`/`BUILD_WORK` convention
  used by `dbdog-server.sh`/`dbdog-web.sh`, not a dedicated `CACHE_ROOT` tree.
  `REPO_ROOT` on the x86_64 build host must contain fetchable local clones of
  both `dbdog-agent` and `dbdog-agent-core`.
- Output lands at `$BUILD_WORK/dbdog-agent/out/dbdog-agent-<version>-x86_64.tar.gz`
  (the generic convention every other recipe uses), not a dedicated sealed
  attempt directory outside `BUILD_WORK`.

## Linkage and path-leak gates

Post-build verification is depth-matched to `finalize-agent-runtime-v3.sh`'s
`write_primary_linkage_report`/`verify_no_path_leaks` (not a shallow 4-prefix
`patchelf --print-rpath` blacklist): for every entry in `RUNTIME_BINARIES`
(`bin/agent/agent`, `embedded/bin/{system-probe,trace-agent,process-agent,agent-data-plane}`)
the recipe parses the real ELF interpreter, RPATH/RUNPATH and DT_NEEDED via
`readelf`, resolves every `$ORIGIN`-relative search-path token against the
install root (rejecting absolute escapes, unsupported loader tokens, and
missing directories), and requires every `DT_NEEDED` entry to resolve either
to a baseline system library or to a file that actually exists inside the
runtime's own search path — writing the result to
`provenance/primary-elf-linkage.tsv`. A separate full-tree byte-level scan
(`verify_no_path_leaks`) rejects any file that contains the build host's
private work directory as a literal substring, matching aarch64's dedicated
`verify_no_path_leaks` gate. Both gates are re-run against the *extracted*
tarball as part of artifact verification, and the regenerated linkage report
must be byte-identical to the one packaged inside the archive — a tamper-
evidence round trip identical in spirit to aarch64's own post-extraction
re-verification.

## Privilege split

Omnibus compilation runs as whatever account `publish.sh` connects to over
SSH (`BUILD_HOST_X86_64`). Producing the canonical artifact — offline GaussDB
wheel install, rpath/version/provenance gates, `chown root:root`, and the
deterministic tar — requires root, mirroring the recipe/finalizer split of
the aarch64 flow without carrying its historical two-file layout. The first
(non-root) invocation compiles everything and then exits non-zero asking an
administrator to re-run the same recipe as root with the identical
`MODULE`/`VERSION`/`SHA`/`CORE_SHA`/`ARCH`/`REPO_ROOT`/`BUILD_WORK`
environment. This root step must always prompt interactively; never grant it
unattended sudo.
Re-running `publish.sh` afterwards finds the already-verified artifact and
reuses it.

## Output contract

`dbdog-agent-<version>-x86_64.tar.gz` is structurally isomorphic to the
aarch64 artifact: same install-root-relative layout, same core
`provenance/*.txt` file set (`build.txt`, `omnibus.success`, `runtime.sha256`,
`glibc-requirements.tsv`, `agent-data-plane.txt`, `agent-version.txt`,
`system-probe-version.txt`, `gaussdb.txt`), plus `primary-elf-linkage.tsv`
(see "Linkage and path-leak gates" above; aarch64 also produces this file,
just not under `provenance/` in the older layout this doc doesn't otherwise
mirror). `provenance/build.txt` carries the same `agent_git_sha` /
`integrations_core_git_sha` / `version` as the aarch64 artifact built from the
same baseline, plus `agent_data_plane_binary_sha256` /
`agent_data_plane_version`, but `architecture=x86_64` (aarch64 records
`architecture=aarch64`) and a distinct `builder_identity`
(`native-x86_64-omnibus-v1`).

No x86_64 build has been produced against a real builder yet — this control
directory and the recipe are validated only against local static fixtures
(`scripts/test-agent-x86_64-artifact-contracts.sh`). Task 7 performs the first
real dual-architecture publish once a native x86_64 builder is registered.
