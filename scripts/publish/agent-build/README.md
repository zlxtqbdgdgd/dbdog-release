# dbdog-agent build controls

This directory tracks the exact Kylin V10 AArch64 controls, plus the anchor
preparer that derives each new generation from the previous one.

## 换锚 SOP

一次换锚要改动的东西全部由 `prepare-agent-anchor.sh` 生成——**不要手工逐处改**。
控制物（control overlay 的 runner/CONTROL-INFO、finalizer、它的 root 入口 wrapper）
都内嵌 release source SHA、integration core SHA 与含短 SHA 的构建目录路径；历史上每次
人肉换锚都漏过至少一处，而漏改要等几小时构建之后才暴露：

| 提交 | 漏掉的东西 | 暴露时机 |
|---|---|---|
| `8585423` | runner 与 CONTROL.sha256 自身哈希 | 构建启动即停 |
| `b6e9982` | relocated outputs manifest 哈希 | seed 阶段 |
| `7f8e53b` | seed success marker 哈希 | seed 阶段 |
| （一直没跟上） | finalizer/wrapper 的 `BUILD_DIR`/`AGENT_SHA`/`CORE_SHA` | finalize 阶段，构建已跑完 |
| （手工建目录） | v15 overlay 目录继承了父目录的 setgid，变成 `2555` | finalize 阶段 |

步骤：

1. **准备 GaussDB wheel**：按新的 core 提交从干净归档独立构建（`SOURCE_DATE_EPOCH`
   取该 commit 时间，两次独立构建必须字节一致），以 `root:root` `0444` 放到
   `/home/dbdog/cache/dbdog-agent/sources/python/gaussdb/<core_sha>/`。
2. **跑换锚准备器**（构建机上以 root）：

   ```bash
   ssh root@<build-host> 'bash -s -- \
       --from-agent-sha <旧40hex> --from-core-sha <旧40hex> --from-overlay-generation vN \
       --to-agent-sha <新40hex>   --to-core-sha <新40hex>   --to-overlay-generation vN+1 \
       --reason <单行下划线短语>' < scripts/publish/agent-build/prepare-agent-anchor.sh
   ```

   它由上一代机械改写出新一代的 overlay 与 finalizer/wrapper，重算全部哈希，落下
   `anchors/<新agent_sha>/ANCHOR-INFO`，并建好 pipeline lock 与 build attempt。
   上一代一字不动。任何一处旧 token 残留都会 fail closed。
3. **改基线**：`dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv` 的
   `agent_release_source_commit` 与 `integrations_core_release_source_commit`。
4. **发布**：`./scripts/publish/publish.sh publish dbdog-agent --bump patch --yes`。
   构建前的 preflight 会先把上面这些控制物查一遍，缺任何一项都在花掉构建时间之前停下。

配方本身**不含任何随锚变的字面量**——路径由传入的 `$SHA`/`$CORE_SHA` 派生，overlay 代号
与 finalizer/wrapper 哈希从 `ANCHOR-INFO` 读取。所以换锚不需要改 `recipes/dbdog-agent.sh`。

## 报错对照表

| 报错 | 含义 | 处置 |
|---|---|---|
| `缺少本次锚的 ANCHOR-INFO` | 没跑换锚准备器，或跑的是别的锚 | 按上面 SOP 第 2 步跑 `prepare-agent-anchor.sh` |
| `control overlay 自报的 release_agent_sha 不是新锚` | overlay 与基线对不上（拿了旧一代） | 核对 `--to-overlay-generation` 与基线是否同一锚 |
| `CONTROL.sha256 必须精确包含固定顺序的四行清单` | overlay 内容与清单不符，或锚无关的两行（platform patch / patchelf）被改动 | 别手改 overlay，重跑准备器 |
| `control overlay 目录必须是 root:root mode 0555` | 目录带了 setgid（父目录 `2755` 继承而来） | `chmod g-s <dir>`；注意这台 XFS 上 `chmod 0555` 不清该位 |
| `relocated release system-probe outputs manifest 不确定` | 同一次运行内两次生成结果不一致 | 检查 `BUILD_DIR` 是否被并发改动；不要手改 seed 产物 |
| `release fresh seed 完成标记与固定输入不一致` | seed marker 的六行常量变了（通常是锚或推导摘要变了） | 若确属换锚，删掉该 build attempt 重新 seed；否则先查为什么锚变了 |
| `构建机上的随锚控制物未就位或与基线不符` | publish preflight 拦下 | 看它打印的 `PREFLIGHT_FAIL` 行，按上表定位 |

## Historical v14/v3 authority

- release Agent source:
  `62ad29793b02139448b76bc85fc406491a08bf58`
- generated system-probe output origin:
  `4c39489b8c0b7fb7a46af88062fb9aadf2c08264`
- immutable Omnibus integrations-core source:
  `7a4247599b029f1aca10d2cb63491d535fbd502f`
- post-Omnibus GaussDB source:
  `612be7bea397c87df707489599c02ed623c29631`
- GaussDB package: `datadog-gaussdb==1.0.1`
- wheel SHA-256:
  `f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f`
- base manifest and dependency seal: the historical
  `4c39489b...-7a424759...-aarch64-kylin10-v7` authority, unchanged
- active overlay:
  `control-overlays/62ad29793b02139448b76bc85fc406491a08bf58-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v14`

The old v7 manifest, v10 seal, v12/v13 overlays, v1/v2 finalizers, and v1/v2
wrappers remain immutable historical controls. v14 records both
`agent_git_sha=62ad2979...` and
`generated_outputs_origin_agent_sha=4c39489b...`; it does not relabel the old
seal. Exactly 69 generated eBPF/Rust/bindata handoff files are copied
byte-for-byte from the sealed origin. The main
`embedded/bin/system-probe` is never reused: Omnibus removes any prior copy
and Go-builds it from the release Agent source. The v3 finalizer executes
`system-probe version`, requires `7.81.0-dbdog.4` plus the release commit,
records its binary/output hashes, and repeats that gate after archive
extraction.

The GaussDB wheel is built from a clean archive of the exact Core commit with
`SOURCE_DATE_EPOCH` set to that commit time. Two independent builds must be
byte-identical. The generated wheel is not committed to Core; provision it as
`root:root` mode `0444` at
`/home/dbdog/cache/dbdog-agent/sources/python/gaussdb/612be7bea397c87df707489599c02ed623c29631/datadog_gaussdb-1.0.1-py3-none-any.whl`.

Install each generation's overlay directory as `root:root` mode `0555`, its runner as
`0555`, and its three data files as `0444`. Install
`finalize-agent-runtime-v3.sh` and
`run-finalize-agent-runtime-v3.sh` as `root:root` mode `0555` under
`/home/dbdog/cache/dbdog-agent/controls/`. The new build directory is
`dbdog:dbdog` mode `0775`; `/opt/dbdog-agent` must be an empty canonical
`dbdog:dbdog` mode `0755` directory before the fresh runner starts. Create
`locks/dbdog-agent-62ad2979-aarch64-kylin10.pipeline.lock` as a regular
`root:dbdog` mode `0644` file.

The v3 destination-local publisher also pins the build host's system
Python before it opens `OUTPUT_DIR`: `/usr/bin/python3` must resolve exactly to
`/usr/bin/python3.7`; that target must be a non-symlink regular file owned by
`root:root` with mode `0755`, and its SHA-256 must be
`f5b09249fb172b46ba1cd4f33bd4cfd894328cc695e7640c2ef083d0ccae0b19`.
Any link target, owner, mode, or byte change fails before the helper runs.

Before seed or Omnibus mutation, the recipe measures the successful historical
build3 and finalized-runtime trees, calculates conservative block and inode
requirements separately for the `/home/dbdog` build/output filesystem and the
root filesystem that contains `/opt/dbdog-agent` and `/var/lib` scratch. If
those paths share a device, it combines the budgets before checking that one
free-space pool. Both block and inode checks precede runtime mutation. The
recipe reuses the immutable cache in place and never deletes old attempts,
seals, or caches; failures list only exact current-v14 unpublished work or
stale v3 finalizer work as manual-review cleanup candidates.

The v3 finalizer keeps its two archive passes and extraction below the
root-private `/var/lib/dbdog-agent-finalize` tree. On a split filesystem it
copies the verified archive into a destination-local staging inode under
`OUTPUT_DIR`, rechecks size, SHA-256, and bytes, syncs it, and publishes the
archive and checksum with atomic no-clobber operations. A process death after
the archive publication but before the checksum publication is recoverable:
the next run verifies the existing archive and completes the sidecar without
overwriting different bytes. Provenance records
`publication_recipe=destination_local_copy_verify_sync_hardlink_noreplace_archive_then_sidecar_recover_archive_only`.

After the Omnibus handoff, finalize interactively:

```bash
sudo /home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v3.sh \
  7.81.0-dbdog.4
```

The canonical artifact is under
`/home/dbdog/work/dbdog-agent-62ad2979-build2/out/`.

## Historical v13 record

v13/v2 produced `7.81.0-dbdog.3` from the isolated fresh attempt
`/home/dbdog/work/dbdog-agent-62ad2979-build1`. It used Agent source
`62ad29793b02139448b76bc85fc406491a08bf58`, post-Omnibus Core source
`d725d9847379ff919b60a2f35e1f41af001e6054`, and the externally provisioned
`datadog-gaussdb==1.0.1` wheel whose SHA-256 was
`c7ee1aa1521e1715845423b8f61268e7765c41a0ee8fd5337e638ab7816a9e1f`.
Its active overlay was `omnibus-kylin-platform-v13`; its root controls were
`finalize-agent-runtime-v2.sh` and `run-finalize-agent-runtime-v2.sh`.

The exact v13 overlay hashes were runner
`c995773922ed242471e42e1e6e35460b48a7498bc531b7e028107d7b1321086d`,
platform patch
`b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe`,
`CONTROL-INFO`
`a06c295420edd7232438df2700c1a890c9b0bdd37269fd4cfd38fb4e2fb4e592`, and
`CONTROL.sha256`
`5491492ab454603d92a6f4de31fd1c13f47e34362eedcdf2f47e3b58cbc5a4d0`.
The v2 finalizer and wrapper hashes were respectively
`5ba96a0b279e4ba4ce848fbcf5b62fa012d8ad349c91e61f9ad29201ae3d8b17` and
`a0e46466bd0727390a957139e08e282aca97e31d882fea9f97c348d5ac91eeda`;
the v13 recipe hash was
`67aa7fae0d0df5820abbdb6eb0d1e7a08545d3c7a26144835412622d84693f93`.

## Historical v12 record

The following material is retained as the v12 build record. Any use of
“active” or “current” below refers to that historical generation, not v14.

## Pinned identities and their roles

- dbdog-agent source:
  `4c39489b8c0b7fb7a46af88062fb9aadf2c08264`
- Omnibus integrations-core source:
  `7a4247599b029f1aca10d2cb63491d535fbd502f`
- post-Omnibus GaussDB integration source:
  `662ad3974b950f67cf162fb273c180d08cc87a06`
- GaussDB integration package: `datadog-gaussdb` `1.0.0`
- official synchronized Agent tag: `7.81.0`
- release version: `7.81.0-dbdog.1`
- platform: Kylin V10 AArch64
- build attempt: `/home/dbdog/work/dbdog-agent-4c39489b-build3`
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

The official baseline and the two actual release-source commits are read from
`dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`. The three-segment prefix must
equal the last fully merged official Agent tag. `-dbdog.N` is the local release
revision: it increases within one official baseline and resets to 1 when that
baseline changes. Upstream `release.json.current_milestone` is not a release
version authority.

## Active v12 overlay and explicit Agent version

Install the four files below `omnibus-kylin-platform-v12/` without changing
their bytes at:

`/home/dbdog/cache/dbdog-agent/control-overlays/4c39489b8c0b7fb7a46af88062fb9aadf2c08264-7a4247599b029f1aca10d2cb63491d535fbd502f-aarch64-kylin10-v7-omnibus-kylin-platform-v12/`

The directory is `root:root` mode `0555`; `run-agent-omnibus.sh` is mode
`0555`; the other three files are mode `0444`. `CONTROL.sha256` verifies the
three overlay files plus the external pinned patchelf binary at its
cache-relative path.

The v12 runner retains the v10 Kylin health-check and native-build controls,
but it no longer derives the package version from the build machine's
incomplete Git tag namespace. For the current build, the recipe passes
`DBDOG_PACKAGE_VERSION=7.81.0-dbdog.1`. The runner:

1. rejects a pre-existing `agent-version.cache`;
2. creates an attempt-local, exact version cache;
3. verifies `dda inv -- agent.version --url-safe` resolves to
   `7.81.0-dbdog.1`;
4. verifies the compiled Agent and Omnibus version manifest report the same
   version; and
5. removes the temporary cache on exit.

build3 is always a fresh attempt. Historical `--resume`/`--adopt` modes remain
evidence for build1 only and the active recipe never infers them from the
shared install prefix. The old runtime is preserved as
`/home/dbdog/work/dbdog-agent-4c39489b-build2/finalized-runtime-7.81.1-dbdog.3`
and `/opt/dbdog-agent` is an empty, canonical `dbdog:dbdog` mode `0755`
directory. Dependency manifests, seals, mirrors, downloads, and build caches
below `/home/dbdog/cache/dbdog-agent` are retained unchanged.

The normal publish invocation now prepares the build3 pre-Omnibus handoff
automatically under the same pipeline lock as the runner. It creates a fresh,
no-hardlink checkout of `4c39489...` from the pinned Agent mirror, applies the
six immutable v7 base patches and the v12 platform patch, and restores the
four checksum-pinned preparation files. From build2 it copies only the three
sealed system-probe tool assets and the 69 generated output files, validating
every byte against the root-owned dependency-seal handoff. It does not copy
build2's Omnibus work, package output, Bazel convenience symlinks, logs,
runtime, stage config, temporary directories, or output directory.

The sealed output manifest originally named build1 absolute paths. The recipe
requires its exact `ae13f9...` checksum, strictly relocates all 69 entries to
build3, and requires the deterministic relocated checksum
`8b67ad9503d58431d46e058b9b15f8e5477a02a7c9c764524e77fcd0fd24437f`.
The rebuilt `system-probe.success` marker is pinned to
`04e6ea2758be07035dd35cc42457941c9c861739d51ad946609e63a4db1d588e`.
The runner therefore validates build3 itself and no longer succeeds merely
because build1 still exists. An atomic in-progress/complete marker permits
safe restart of an interrupted seed while unknown or partial runner state
still fails closed. Build2 is required only until that complete marker is
created; later build3 or canonical-artifact reuse depends on the immutable
seal and verified build3 bytes, not on retaining a mutable historical attempt.

The finalizer independently requires agreement among the outer release
version, `agent version`, the `version-manifest.txt` header and component row,
and `version-manifest.json`'s `build_version`. The canonical artifact verifier
rechecks the resulting hashes and provenance before publication. A build that
internally reports `7.79.0` or any other version cannot be published as
`7.81.0-dbdog.1`.

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

The current wrapper is pinned to build3, the v12 overlay, Omnibus core
`7a424759...`, post-Omnibus integration core `662ad397...`, and the current
finalizer checksum. After the Omnibus handoff and dependency-seal checks pass,
the current release is finalized interactively with:

```bash
sudo /home/dbdog/cache/dbdog-agent/controls/run-finalize-agent-runtime-v1.sh \
  7.81.0-dbdog.1
```

Do not grant this command `NOPASSWD`: the finalizer deliberately executes the
completed embedded runtime while validating it. The streamed publish recipe
does not install controls, edit sudoers, or perform non-interactive privilege
escalation. A later publish invocation verifies and reuses the root-owned
artifact and sidecar under:

`/home/dbdog/work/dbdog-agent-4c39489b-build3/out/`

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
intentionally retains that identity. v12 corrects only the explicit Agent
version authority; it does not change the source, compiler, dependency, or
platform-patch closure. The active recipe therefore verifies two separate
control layers: `SEAL_*` pins must match the existing v10 seal, while the live
Omnibus handoff must match the v12 runner. The tracked
`seal-agent-build-dependencies-v1.sh` is the expected generator for that v10
seal and no v12 relabeling or seal regeneration is required.

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

## Historical v14/v3 SHA-256 values

```text
6da7c38074a6c16a15a491a1358e8fc8c606bea1eaac81df10352e79737c8e4a  omnibus-kylin-platform-v14/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v14/agent-build-kylin-platform.patch
b5dcfa966d6ebe9bcb080c392b8544693ec3c3bf5c88e49275da7c093b427b50  omnibus-kylin-platform-v14/CONTROL-INFO
359151228de51ed690c00caf6d22f42f8e7f0026d512e5c39962fc23f74c4e75  omnibus-kylin-platform-v14/CONTROL.sha256
f696515133a97de9784b86c91324f2447f11022e7da90d823d3348a645c2208f  external sources/python/gaussdb/612be7bea397c87df707489599c02ed623c29631/datadog_gaussdb-1.0.1-py3-none-any.whl
4c050fe90b1a0306afbec43e6a2fcd5c9d3151a8dfc33175cfe7a5a7c772b8be  finalize-agent-runtime-v3.sh
4b5fdce057bacca6dfde0d5352255cf8760ab57458aae29024dd2f917036ad77  run-finalize-agent-runtime-v3.sh
82935b65a102f7b6bf386861e38e28961cb6139e727a96ae5039b3d6f8765dcb  ../recipes/dbdog-agent.sh
```

## Historical v10-v13 SHA-256 values

The first four v10 entries identify the dependency seal. The v11, v12, and v13
entries are immutable history; none of them identifies the active v14 handoff.

```text
abc76d6a8546c17dd90a24f7eacf982339104fc44e0da87bb8462fc73780a812  omnibus-kylin-platform-v10/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v10/agent-build-kylin-platform.patch
6f9cbfd956792d68c2b512159d6cdb19df07a5d0433e682e06e6bf7e3c95264a  omnibus-kylin-platform-v10/CONTROL-INFO
f1cefa64ce393e7025c1b8822899e3ea856a000bba5372ad1ffd0b910886e7ac  omnibus-kylin-platform-v10/CONTROL.sha256
b28e75b7bc1318a82b5584e747e83b11d596ac7b403292162e8c7599c3f58184  omnibus-kylin-platform-v11/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v11/agent-build-kylin-platform.patch
3c5af9befdf56c45ebfb14e366b3324f84aa9f0f81390e47a5357beca70a5647  omnibus-kylin-platform-v11/CONTROL-INFO
5bf2b308b3d3e936c95080b4577630c65f0606008ce652ae06b5c36b20551c81  omnibus-kylin-platform-v11/CONTROL.sha256
82c0514179d586f569e7287cbad28893ac4b9009e5fc3b61300d33085d0fbcc6  omnibus-kylin-platform-v12/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v12/agent-build-kylin-platform.patch
3febbbe8331078aa8b9f12592ef95731b5913bc066faecc8bc8e786ba53ecc1a  omnibus-kylin-platform-v12/CONTROL-INFO
0c01d4833beb9391fd411bcae4ca23208d6ad73e3e5935f549a9a3b5e24c2ff4  omnibus-kylin-platform-v12/CONTROL.sha256
c995773922ed242471e42e1e6e35460b48a7498bc531b7e028107d7b1321086d  omnibus-kylin-platform-v13/run-agent-omnibus.sh
b4a5516b11029d2e225a02664b10677bb43a8dd8abd1afad587ee56ec93bccbe  omnibus-kylin-platform-v13/agent-build-kylin-platform.patch
a06c295420edd7232438df2700c1a890c9b0bdd37269fd4cfd38fb4e2fb4e592  omnibus-kylin-platform-v13/CONTROL-INFO
5491492ab454603d92a6f4de31fd1c13f47e34362eedcdf2f47e3b58cbc5a4d0  omnibus-kylin-platform-v13/CONTROL.sha256
a9a043a7975a7b4b1f43de46cdcaca292adc51799aa281cb9b47a276134871b7  patchelf-0.18.0-aarch64-kylin10-v2/PATCHELF-INFO
4d49826b6fcfdd770c1c5e36182d4f5dc103e333a420a71e8d6d04ea867147d7  patchelf-0.18.0-aarch64-kylin10-v2/SHA256SUMS
01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf  external tools/patchelf/0.18.0-aarch64-kylin10-v2/bin/patchelf
06fd5eea7acd51a0ebf519be58a2700f1ca4142a13b0668cb7f5e66ef022f7f6  external sources/python/datadog_gaussdb-1.0.0-py3-none-any.whl
968bdc937041b2aacef7173afc4dbe0b68ab063a5374211b29f987c450438e82  finalize-agent-runtime-v1.sh
9d97177db1fe5ddf4ac2559eade9395c62408a169c69cd783fcd3bac6d967ac5  run-finalize-agent-runtime-v1.sh
ae4d099588ec5ae3181009bd49a3af1498755fd654673b73534498c55009b2c3  seal-agent-build-dependencies-v1.sh
733389f2ce21b83a7b40983c3b61126e0689810f579abf5c5e11c8cef9d9c2e3  ../recipes/dbdog-agent.sh (v12 snapshot)
c7ee1aa1521e1715845423b8f61268e7765c41a0ee8fd5337e638ab7816a9e1f  external sources/python/datadog_gaussdb-1.0.1-py3-none-any.whl
5ba96a0b279e4ba4ce848fbcf5b62fa012d8ad349c91e61f9ad29201ae3d8b17  finalize-agent-runtime-v2.sh
a0e46466bd0727390a957139e08e282aca97e31d882fea9f97c348d5ac91eeda  run-finalize-agent-runtime-v2.sh
67aa7fae0d0df5820abbdb6eb0d1e7a08545d3c7a26144835412622d84693f93  ../recipes/dbdog-agent.sh (v13 snapshot)
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

v11 retained the established Kylin build and dependency contract and added
the explicit release-version authority and post-build version gates. It built
and finalized `7.81.1-dbdog.3` consistently, but that three-segment prefix came
from upstream `current_milestone`, not the last fully merged official tag.

v12 keeps those gates, binds the prefix to official tag `7.81.0`, resets the
local revision to `dbdog.1`, and uses the isolated build3 path. Its historical
recipe, finalizer, and root wrapper accept only that v12/build3 handoff.

v13 moves the release Agent source to `62ad2979...`, builds
`7.81.0-dbdog.3` in build1, and installs the `d725d984...` GaussDB integration
with the immutable v2 finalizer/wrapper pair. v14 retains the sealed Omnibus
inputs and Agent source, moves to build2, installs the `612be7be...` integration,
and adds the split-filesystem capacity and recoverable destination-local
publication contracts in v3.
