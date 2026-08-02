# 多架构发布基础 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 release manifest、发布器和目标机升级器升级为可原子发布并按本机选择 `aarch64`、`x86_64`、`noarch` 产物，同时正式接入固定版本的官方 ddprof。

**Architecture:** `manifest.tsv` 保留现有八列并追加 `arch`，逻辑主键变为 `(module, arch)`；所有安装侧查询都通过统一选择函数得到“精确架构优先、仅显式 `noarch` 回退”的唯一行。发布侧先为一个模块完成全部目标架构的构建、验证和上传，再一次更新全部 manifest 行并提交，使用本地事务记录恢复上传响应丢失场景。

**Tech Stack:** Bash 4+、TSV、Git/GitHub CLI、SSH、GNU tar、`file`、`objdump`、Omnibus、官方 ddprof v0.26.0。

## Global Constraints

- 正式发布必须使用 `scripts/publish/publish.sh`，禁止手改 `manifest.tsv`、README 版本表或 GitHub assets。
- 正式模块发布串行执行；manifest、README、GitHub `artifacts` release 和 `origin/main` 是一个发布事务。
- 构建使用 dbdog 管理的原生 builder，不使用 `dbdog-build-old`；现有 `dbdog-build` 继续作为其真实架构的兼容别名，新增架构必须配置独立原生执行器。产物从构建机直接上传，开发机不转存大二进制。
- Agent 两个架构必须来自同一份 `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv` 的 Agent/Core 源码锚和同一个 dbdog 版本。
- ddprof 固定为 v0.26.0；不使用 `latest`，不重新编译或修改官方二进制。
- 目标架构只允许 `aarch64`、`x86_64`、`noarch`；`arm64` 仅作为主机输入别名规范化为 `aarch64`，`amd64` 仅规范化为 `x86_64`。
- `x86_64` Agent 正式发布前必须有原生 x86_64 构建执行器；不得用 QEMU 产物冒充原生 release。
- 所有源码仓的出货提交先进入各自 `origin/main`；实现阶段在隔离 worktree 中完成。

---

## 文件结构

### dbdog-release

- Modify: `manifest.tsv` — v2 九列 manifest；同一模块允许多个架构行。
- Modify: `scripts/lib.sh` — manifest 校验、主机架构规范化和唯一行选择的单一实现。
- Modify: `scripts/upgrade.sh` — stack 模块按本机架构选择并验证 runtime。
- Modify: `scripts/check-upgrade.sh` — 只比较本机选中的模块行。
- Modify: `scripts/fingerprint.sh` — 去重逻辑模块并显示已选架构。
- Modify: `scripts/collect-diagnostics.sh` — 诊断输出记录 host arch 与 selected artifact。
- Modify: `scripts/dbdogctl` — Agent 诊断读取本机选中的 manifest 行。
- Modify: `scripts/agent-install.sh` — Agent 下载使用本机选中的 manifest 行，去掉 AArch64-only 拒绝。
- Modify: `scripts/publish/publish.sh` — 架构矩阵、事务日志、原子 manifest 更新和恢复。
- Modify: `scripts/publish/publish.conf.example` — 构建执行器合同，不保存凭证。
- Modify: `scripts/publish/verify-artifact-arch.sh` — 增加 x86_64 ELF/静态库门禁。
- Create: `scripts/publish/recipes/ddprof.sh` — 下载、校验、封装官方 ddprof。
- Create: `scripts/test-manifest-architecture-contracts.sh` — manifest 选择与迁移合同。
- Create: `scripts/test-publish-architecture-transaction.sh` — 多架构发布原子性与恢复合同。
- Create: `scripts/test-ddprof-artifact-contracts.sh` — 两架构官方 digest、包结构和 ELF 合同。
- Modify: `scripts/test-release-contracts.sh`
- Modify: `scripts/test-publish-upload-contracts.sh`
- Modify: `scripts/test-agent-install-contracts.sh`
- Modify: `scripts/test-agent-artifact-contracts.sh`
- Modify: `README.md` — 由发布器生成带架构列的版本表。

### dbdog-agent

- Create: `dbdog-deploy/build/x86_64/README.md` — x86_64 canonical build 的输入、builder identity 和验收入口。
- Modify: `dbdog-deploy/RELEASE-BASELINE.tsv` — 仅当本阶段需要前移真实出货源码锚时更新；不因文档变化生成 runtime。

## Task 1: manifest v2 解析和选择合同

**Files:**
- Modify: `scripts/lib.sh`
- Create: `scripts/test-manifest-architecture-contracts.sh`
- Modify: `scripts/test-release-contracts.sh`

**Interfaces:**
- Produces: `normalize_arch <raw>` → `aarch64|x86_64|noarch`。
- Produces: `host_arch` → 规范化后的当前主机架构。
- Produces: `manifest_all_rows` → 严格九列的全部非注释行。
- Produces: `manifest_selected_rows [target] [arch]` → 每个逻辑模块至多一行。
- Produces: `manifest_get <module> <column> [arch]` → 精确架构行优先，之后只回退到 `noarch`。
- Produces: `manifest_arches <module>` → 按 `aarch64 x86_64 noarch` 稳定顺序输出。

- [ ] **Step 1: 写失败测试覆盖精确选择、noarch 回退和冲突拒绝**

```bash
cat >"$TEST_ROOT/manifest.tsv" <<'EOF'
agent	first-party	dbhost	no	1.0.0	agent-aarch64.tar.gz	0000000000000000000000000000000000000000000000000000000000000001	a:1,c:1	aarch64
agent	first-party	dbhost	no	1.0.0	agent-x86_64.tar.gz	0000000000000000000000000000000000000000000000000000000000000002	a:1,c:1	x86_64
tool	third-party	stack	no	1.0.0	tool-noarch.tar.gz	0000000000000000000000000000000000000000000000000000000000000003	-	noarch
EOF
MANIFEST="$TEST_ROOT/manifest.tsv"
[ "$(manifest_get agent 6 x86_64)" = agent-x86_64.tar.gz ]
[ "$(manifest_get tool 9 aarch64)" = noarch ]
if manifest_get agent 6 riscv64 >/dev/null 2>&1; then fail '接受了未知架构'; fi
```

- [ ] **Step 2: 运行测试并确认旧实现失败**

Run: `bash scripts/test-manifest-architecture-contracts.sh`

Expected: FAIL，原因是 `manifest_get` 仍只按模块名选择且没有第九列合同。

- [ ] **Step 3: 在 `scripts/lib.sh` 实现严格选择函数**

```bash
normalize_arch() {
  case "$1" in
    aarch64|arm64) printf '%s\n' aarch64 ;;
    x86_64|amd64) printf '%s\n' x86_64 ;;
    noarch) printf '%s\n' noarch ;;
    *) return 1 ;;
  esac
}

host_arch() {
  normalize_arch "${DBDOG_HOST_ARCH_OVERRIDE:-$(uname -m)}" ||
    die "不支持的主机架构: ${DBDOG_HOST_ARCH_OVERRIDE:-$(uname -m)}"
}
```

`manifest_all_rows` 必须用 awk 验证：恰好九列、arch 合法、artifact 后缀与 arch 一致、同一 `(module, arch)` 不重复、同模块 version/source_sha 相同。`manifest_selected_rows` 对每个模块先找精确 arch，再找 `noarch`；同时存在两个候选或完全缺失时分别报错和跳过，不允许输出多行。

- [ ] **Step 4: 运行定向合同测试**

Run: `bash scripts/test-manifest-architecture-contracts.sh`

Expected: PASS，输出 `PASS: exact arch wins`、`PASS: explicit noarch fallback`、`PASS: duplicates fail closed`。

- [ ] **Step 5: 回归现有 release 合同**

Run: `bash scripts/test-release-contracts.sh`

Expected: PASS；若 fixture 仍为八列，只修改 fixture，不给生产解析器保留宽松分支。

- [ ] **Step 6: 提交解析合同**

```bash
git add scripts/lib.sh scripts/test-manifest-architecture-contracts.sh scripts/test-release-contracts.sh
git commit -m "feat: add architecture-aware manifest contract"
```

## Task 2: 用发布器完成 manifest v2 一次性迁移

**Files:**
- Modify: `scripts/publish/publish.sh`
- Modify: `manifest.tsv`
- Modify: `README.md`
- Test: `scripts/test-manifest-architecture-contracts.sh`

**Interfaces:**
- Consumes: `normalize_arch`、`manifest_all_rows`。
- Produces: `publish.sh migrate-manifest-v2 --write`，只允许八列输入，按 artifact 后缀写入第九列并重建 README。

- [ ] **Step 1: 写失败测试，证明迁移只认三个确定后缀**

```bash
printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1-aarch64.tar.gz\t'"$SHA"$'\t-' >"$legacy"
MANIFEST="$legacy" publish_migrate_manifest_v2 "$output"
[ "$(cut -f9 "$output")" = aarch64 ]
printf '%s\n' $'m\tthird-party\tstack\tno\t1\tm-1.tar.gz\t'"$SHA"$'\t-' >"$legacy"
if MANIFEST="$legacy" publish_migrate_manifest_v2 "$output"; then fail '接受了未知后缀'; fi
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash scripts/test-manifest-architecture-contracts.sh`

Expected: FAIL，原因是迁移函数不存在。

- [ ] **Step 3: 实现迁移子命令**

迁移规则固定为：`*-aarch64.tar.gz → aarch64`、`*-x86_64.tar.gz → x86_64`、`*-noarch.tar.gz → noarch`；`version/artifact/sha256` 为 `-` 的未发布行必须由模块的目标架构声明生成，当前 manifest 没有此类行。命令先写临时文件、调用新 `manifest_all_rows` 验证，再原子替换 manifest 并执行 `regen_readme`。

- [ ] **Step 4: 用发布器生成真实 v2 文件**

Run: `bash scripts/publish/publish.sh migrate-manifest-v2 --write`

Expected: manifest 每个数据行九列；README 版本表新增“架构”；现有资产名、版本、SHA 和 source SHA 字节不变。

- [ ] **Step 5: 验证真实 manifest 与 README**

Run: `bash scripts/test-manifest-architecture-contracts.sh && bash scripts/test-release-contracts.sh && git diff --check`

Expected: 全部 PASS；`git diff -- manifest.tsv` 只增加第九列。

- [ ] **Step 6: 提交迁移结果**

```bash
git add scripts/publish/publish.sh manifest.tsv README.md scripts/test-manifest-architecture-contracts.sh
git commit -m "build: migrate release manifest to architecture v2"
```

## Task 3: 改造全部安装、升级和诊断消费者

**Files:**
- Modify: `scripts/upgrade.sh`
- Modify: `scripts/check-upgrade.sh`
- Modify: `scripts/fingerprint.sh`
- Modify: `scripts/collect-diagnostics.sh`
- Modify: `scripts/dbdogctl`
- Modify: `scripts/agent-install.sh`
- Modify: `scripts/publish/verify-artifact-arch.sh`
- Modify: `scripts/test-agent-install-contracts.sh`
- Modify: `scripts/test-diagnostics-collector.sh`

**Interfaces:**
- Consumes: `host_arch`、`manifest_selected_rows`、`manifest_get`。
- Produces: `artifact_arch_from_name` 支持 `x86_64`；`validate_module_runtime` 接受三个规范架构。

- [ ] **Step 1: 加入 x86_64 与 noarch 选择失败测试**

在 Agent 安装 fixture 中同时放两条 `dbdog-agent` 行，设置 `DBDOG_HOST_ARCH_OVERRIDE=x86_64`，断言只下载 `*-x86_64.tar.gz`；设置 `riscv64` 断言下载前失败。

- [ ] **Step 2: 运行定向测试确认失败**

Run: `bash scripts/test-agent-install-contracts.sh`

Expected: FAIL，当前 `require_root_host` 仍拒绝 x86_64 或读取第一条模块行。

- [ ] **Step 3: 替换所有裸 `manifest_rows` 消费**

目标机脚本遍历本机模块时统一改为：

```bash
selected_arch="$(host_arch)"
while IFS=$'\t' read -r m kind target service version artifact sha source arch; do
  # 原有逻辑
done < <(manifest_selected_rows "" "$selected_arch")
```

发布器和 prune 需要查看全部架构时继续显式使用 `manifest_all_rows`，不能依赖函数名含糊的旧行为。

- [ ] **Step 4: 扩展 ELF 门禁**

`verify-artifact-arch.sh` 对 x86_64 只接受 `ELF ... x86-64` 和 `objdump` 的 `i386:x86-64`；保留 Agent eBPF/PE 精确白名单。`upgrade.sh` 的目标机 `file`/`ldd` 门禁使用相同语义。

- [ ] **Step 5: 移除 Agent 的 AArch64-only 主机拒绝**

`require_root_host` 改为调用 `host_arch` 并保存 `AGENT_HOST_ARCH`；runtime 校验、下载和 marker 比较都取该架构的 manifest 行。

- [ ] **Step 6: 运行消费者回归**

Run: `bash scripts/test-agent-install-contracts.sh && bash scripts/test-diagnostics-collector.sh && bash scripts/test-release-contracts.sh`

Expected: 全部 PASS；诊断报告含 `host_arch=`、`manifest_arch=`、`artifact=`。

- [ ] **Step 7: 提交消费者改造**

```bash
git add scripts/upgrade.sh scripts/check-upgrade.sh scripts/fingerprint.sh scripts/collect-diagnostics.sh scripts/dbdogctl scripts/agent-install.sh scripts/publish/verify-artifact-arch.sh scripts/test-agent-install-contracts.sh scripts/test-diagnostics-collector.sh
git commit -m "feat: select release artifacts by host architecture"
```

## Task 4: 多架构发布事务

**Files:**
- Modify: `scripts/publish/publish.sh`
- Modify: `scripts/publish/publish.conf.example`
- Create: `scripts/test-publish-architecture-transaction.sh`
- Modify: `scripts/test-publish-upload-contracts.sh`

**Interfaces:**
- Produces: `publish_arches_for_module <module>` → 该模块 manifest 中的目标架构。
- Produces: `build_one_arch <module> <version> <arch>` → 向事务 TSV 追加 `module,arch,version,path,size,sha,source_sha`，不上传、不改 manifest。
- Produces: `publish_commit_arch_matrix <txn.tsv>` → 校验完整矩阵、上传/恢复、一次更新全部行。
- Produces: 私有配置 `BUILD_HOST_AARCH64`、`BUILD_HOST_X86_64`；旧 `BUILD_HOST=dbdog-build` 只在 `uname -m` 与请求架构一致时作为兼容回退。

- [ ] **Step 1: 写失败测试覆盖“第二架构失败时 manifest 不变”**

测试 fake builder 为 aarch64 成功、x86_64 失败，执行后比较 `sha256sum manifest.tsv README.md` 与执行前完全相同，并断言没有 git commit/push。

- [ ] **Step 2: 写失败测试覆盖上传响应丢失恢复**

第一次执行让 aarch64 上传成功后中断；第二次执行用事务记录和 GitHub size/digest 认领相同 asset，不覆盖、不重复上传，随后完成 x86_64 并只产生一个发布提交。

- [ ] **Step 3: 运行测试确认当前逐模块立即上传模型失败**

Run: `bash scripts/test-publish-architecture-transaction.sh`

Expected: FAIL，当前 `build_one` 每构建一个产物就上传并改 manifest。

- [ ] **Step 4: 实现事务目录和不可伪造恢复键**

事务目录固定在 gitignored `scratch/publish-txn/<module>-<version>-<release-head>/`，mode 0700；记录包含 release HEAD、module、version、source SHA、arch、远端绝对路径、size、sha。恢复时这七项必须完全一致，且 manifest 仍指向旧版本；不一致就停止，不删除资产。

`publish.conf.example` 同时声明两个原生 builder SSH alias；发布前在各 builder 执行 `uname -m` 并经 `normalize_arch` 精确匹配。没有对应 builder 时整个架构矩阵在任何构建/上传前失败，不能用 QEMU 或把目标 VM 当作未登记 builder。

- [ ] **Step 5: 拆分 build、upload、manifest commit 三阶段**

构建矩阵全部通过 `verify_remote_artifact_arch` 后才开始上传。所有目标资产已确认存在且 digest 正确后，使用 awk 对 `(module, arch)` 精确更新，再验证同模块 version/source 相同，最后 `regen_readme`、commit、push、prune。

- [ ] **Step 6: 运行事务和既有上传合同**

Run: `bash scripts/test-publish-architecture-transaction.sh && bash scripts/test-publish-upload-contracts.sh`

Expected: 两套测试全部 PASS，测试 fake 明确证明零 clobber、有限重试、部分上传可恢复、manifest 单提交。

- [ ] **Step 7: 提交发布事务**

```bash
git add scripts/publish/publish.sh scripts/publish/publish.conf.example scripts/test-publish-architecture-transaction.sh scripts/test-publish-upload-contracts.sh
git commit -m "feat: publish architecture matrices atomically"
```

## Task 5: 官方 ddprof 双架构模块

**Files:**
- Create: `scripts/publish/recipes/ddprof.sh`
- Create: `scripts/test-ddprof-artifact-contracts.sh`
- Modify: `manifest.tsv`（只能由发布器更新）
- Modify: `README.md`（只能由发布器生成）

**Interfaces:**
- Produces: `ddprof-0.26.0-{aarch64,x86_64}.tar.gz`，顶层目录 `ddprof-0.26.0/`，入口 `bin/ddprof`。
- Consumes: GitHub 官方 release v0.26.0 的 asset digest。

- [ ] **Step 1: 写固定 digest 合同测试**

```bash
grep -Fq '03a76919bcc23a757f02d9c276dee7e58c1db688cc75e5568eb9a0f709bdce52' scripts/publish/recipes/ddprof.sh
grep -Fq '1c25657a53643d74eac4d13356a2953dbfd8d52cc80f9266025b3ae3983addef' scripts/publish/recipes/ddprof.sh
grep -Fq '8bf9255eecf4c93177bef7a5ccf5726b4df8b549fde9d5ed228073f784804b75' scripts/publish/recipes/ddprof.sh
grep -Fq '8edb9b30c355a2f685bfaf00e2f23998884d249b6c5ac7701a7bb9af3e324df4' scripts/publish/recipes/ddprof.sh
```

- [ ] **Step 2: 运行测试确认配方不存在**

Run: `bash scripts/test-ddprof-artifact-contracts.sh`

Expected: FAIL，缺少 `recipes/ddprof.sh`。

- [ ] **Step 3: 实现固定版本配方**

配方只接受 `VERSION=0.26.0`。x86_64 下载 `ddprof-0.26.0-amd64-linux.tar.xz`，aarch64 下载 `ddprof-0.26.0-arm64-linux.tar.xz`；先验 tar digest，再验解包二进制 digest，执行 `ddprof --version`，最后用确定性 tar/gzip 重新封装。禁止解析 `latest` 或在线 `sha256sum.txt` 作为版本权威。

- [ ] **Step 4: 本地 fixture 测试和构建机只读预检**

Run: `bash scripts/test-ddprof-artifact-contracts.sh`

Expected: PASS；配方测试不依赖真实 GitHub 上传。

- [ ] **Step 5: 通过正式发布器串行发布 ddprof**

Run: `./scripts/publish/publish.sh publish ddprof --yes`

Expected: aarch64、x86_64 两个资产都验证并上传后，manifest 才同时新增两行；发布提交已 push，prune 无孤儿资产。

- [ ] **Step 6: 闭环复核**

Run: `./scripts/publish/publish.sh prune && git status --short --branch`

Expected: prune 仅试运行且报告无孤儿；本地 HEAD 等于 `origin/main`，worktree clean。

## Task 6: x86_64 Agent canonical build 控制

**Files:**
- Create: `scripts/publish/recipes/dbdog-agent-x86_64.sh`
- Create: `scripts/publish/agent-build/x86_64/README.md`
- Create: `scripts/test-agent-x86_64-artifact-contracts.sh`
- Modify: `scripts/publish/publish.sh`
- Modify: `scripts/test-agent-artifact-contracts.sh`
- Create: `../dbdog-agent/dbdog-deploy/build/x86_64/README.md`

**Interfaces:**
- Consumes: 与 aarch64 相同的 `VERSION`、`SHA`、`CORE_SHA`、`ARCH=x86_64`。
- Produces: `dbdog-agent-<version>-x86_64.tar.gz`，runtime 根和 provenance 与 aarch64 同构。
- Produces: recipe 选择规则：存在 `recipes/<module>-<arch>.sh` 时精确选择，否则使用 `recipes/<module>.sh`。

- [ ] **Step 1: 写 recipe 选择和 provenance 失败测试**

测试要求 `dbdog-agent/x86_64` 精确选择新配方；两个架构 tar 内的 `provenance/build.txt` 必须有相同 `agent_git_sha`、`integrations_core_git_sha`、`release_version`，但 `builder_arch` 分别不同。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash scripts/test-agent-x86_64-artifact-contracts.sh`

Expected: FAIL，缺少 x86_64 配方。

- [ ] **Step 3: 固化已在 VM203 验过的 x86_64 Omnibus 流程**

新配方必须从 `RELEASE-BASELINE.tsv` 的完整 SHA 建独立 checkout，以 `/opt/dbdog-agent` 为 install root，构建 Core/Trace/Process/System Probe，离线安装同一 Core 源码生成的 gaussdb wheel，执行 runtime cutover 脚本中的 x86_64、rpath、import、version 和 provenance 门禁，再生成确定性 tar。不得把 VM203 上已安装目录反向打包成 release。

- [ ] **Step 4: 在 dbdog-agent 记录 builder contract**

`dbdog-deploy/build/x86_64/README.md` 只记录输入 SHA、原生 x86_64、安装根、验证命令和输出合同，不保存主机名、密码或一次性工作目录。

- [ ] **Step 5: 运行两架构静态合同**

Run: `bash scripts/test-agent-artifact-contracts.sh && bash scripts/test-agent-x86_64-artifact-contracts.sh`

Expected: PASS；原 aarch64 封存控制哈希仍有效，新 x86_64 控制有独立哈希链。

- [ ] **Step 6: 提交两个仓的源码改动**

```bash
git -C ../dbdog-agent add dbdog-deploy/build/x86_64/README.md
git -C ../dbdog-agent commit -m "docs: define canonical x86_64 agent build"
git add scripts/publish/recipes/dbdog-agent-x86_64.sh scripts/publish/agent-build/x86_64/README.md scripts/publish/publish.sh scripts/test-agent-artifact-contracts.sh scripts/test-agent-x86_64-artifact-contracts.sh
git commit -m "build: add canonical x86_64 agent release"
```

## Task 7: Agent 双架构正式发布和目标机冒烟

**Files:**
- Modify: `manifest.tsv`（发布器）
- Modify: `README.md`（发布器）
- Modify: `../dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`（仅源码锚确需前移时）
- Modify: `../dbdog-web/docs/devspec/agent-history.json`
- Generated: `../dbdog-web/docs/devspec/agent-history-data.js`

**Interfaces:**
- Consumes: Task 4 的原子架构矩阵和 Task 6 的两个 Agent 配方。
- Produces: 同版本、同源码锚的 `dbdog-agent` aarch64/x86_64 manifest 行。

- [ ] **Step 1: 确认两源码仓 origin/main 和 release baseline**

Run: `./scripts/publish/publish.sh plan`

Expected: 本地 Agent/Core 与 origin/main 一致；baseline 的 release source 是两仓 HEAD 的祖先；没有未推送源码。

- [ ] **Step 2: 正式串行发布 Agent 架构矩阵**

Run: `./scripts/publish/publish.sh publish dbdog-agent --bump patch --yes`

Expected: 两个架构完成构建、验证和上传后只产生一个 `publish:` 提交；manifest 两行 version/source_sha 相同。

- [ ] **Step 3: 在一台 aarch64 和一台 x86_64 测试主机只跑安装器 artifact 前置门禁**

Run: `sudo DBDOG_AGENT_PREFLIGHT_ONLY=1 ./scripts/upgrade.sh dbdog-agent`

Expected: 各自主机只下载本架构 tar；archive、ELF、ldd、version、provenance 全通过，不改配置、不停服务。

- [ ] **Step 4: 刷新 Agent 历史锚**

更新 `agent-history.json` 后运行：`npm run sync:agent-history`（在 dbdog-mcp 仓）。

Expected: 生成数据记录同一 Agent/Core 源码锚对应两个 release 架构，不手写生成摘要。

- [ ] **Step 5: 全量发布闭环**

Run: `bash scripts/test-manifest-architecture-contracts.sh && bash scripts/test-release-contracts.sh && bash scripts/test-publish-upload-contracts.sh && bash scripts/test-publish-architecture-transaction.sh && bash scripts/test-ddprof-artifact-contracts.sh && bash scripts/test-agent-artifact-contracts.sh && bash scripts/test-agent-x86_64-artifact-contracts.sh`

Expected: 全部 PASS；`git status --short --branch` clean 且 HEAD 等于 `origin/main`。

## Completion Gate

- manifest 每个数据行严格九列，`(module, arch)` 唯一，旧行只按确定 artifact 后缀迁移，未知架构 fail closed。
- 所有安装、升级、诊断和 fingerprint 消费者都精确选择本机架构，只对显式 `noarch` 模块回退。
- 一个模块的全部目标架构构建、校验和上传完成后，manifest/README 才由一次提交原子更新；中断可恢复且不覆盖远端资产。
- 官方 ddprof v0.26.0 的 aarch64/x86_64 输入 digest、解包 binary digest、ELF 架构和 version 都通过固定合同。
- Agent 的 aarch64/x86_64 产物来自同一 Agent/Core 源码锚和版本，分别通过原生 builder 与目标机 preflight，发布提交已进入 `origin/main`。
