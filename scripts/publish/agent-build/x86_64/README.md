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
- `patchelf` is taken from the build host's own package manager; only its
  `--version` output is logged to provenance, not pinned by hash.
- Source and output paths follow the same `REPO_ROOT`/`BUILD_WORK` convention
  used by `dbdog-server.sh`/`dbdog-web.sh`, not a dedicated `CACHE_ROOT` tree.
  `REPO_ROOT` on the x86_64 build host must contain fetchable local clones of
  both `dbdog-agent` and `dbdog-agent-core`.
- Output lands at `$BUILD_WORK/dbdog-agent/out/dbdog-agent-<version>-x86_64.tar.gz`
  (the generic convention every other recipe uses), not a dedicated sealed
  attempt directory outside `BUILD_WORK`.

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
aarch64 artifact: same install-root-relative layout, same
`provenance/*.txt` file set (`build.txt`, `omnibus.success`, `runtime.sha256`,
`glibc-requirements.tsv`, `agent-data-plane.txt`, `agent-version.txt`,
`system-probe-version.txt`, `gaussdb.txt`). `provenance/build.txt` carries the
same `agent_git_sha` / `integrations_core_git_sha` / `version` as the aarch64
artifact built from the same baseline, but `architecture=x86_64` (aarch64
records `architecture=aarch64`) and a distinct `builder_identity`
(`native-x86_64-omnibus-v1`).

No x86_64 build has been produced against a real builder yet — this control
directory and the recipe are validated only against local static fixtures
(`scripts/test-agent-x86_64-artifact-contracts.sh`). Task 7 performs the first
real dual-architecture publish once a native x86_64 builder is registered.
