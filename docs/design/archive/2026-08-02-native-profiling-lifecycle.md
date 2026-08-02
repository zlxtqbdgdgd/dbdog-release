# 原生 Continuous Profiling 生命周期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在一键数据库主机安装流程中，为 PostgreSQL、无 CM 的 GaussDB/openGauss 和 CM 管理的 GaussDB/openGauss 提供可选择、可暂缓重启、可验证、可回滚的 ddprof wrapper 生命周期，稳定采集 CPU、allocation 和 live heap，并保持原数据库管理面是唯一故障恢复决策者。

**Architecture:** release 安装器拥有统一 profiling 配置、符号门禁、launcher/supervisor 客户端合同、事务状态和三类 lifecycle adapter。CM 源码新增版本化、launch-only 的 datanode launcher hook，把自动启动、手工启动、故障恢复和 role-mode restart 收敛到同一个 argv 启动函数；launcher 只在进程启动边界插入 ddprof，不接管 stop、restart 或集群判断。用户先选择是否启用 wrapper，全部前置条件通过后再明确选择是否现在重启；拒绝重启时保留健康 DBM 并报告 `prepared_not_active`。

**Tech Stack:** Bash 4+、systemd、ddprof v0.26.0、ELF/readelf/elfutils、GaussDB `gs_ctl`、openGauss 7.0.0-RC1、openGauss CM C++/CMake/CTest、Agent trace intake。

## Global Constraints

- Continuous Profiling 成功形态必须是 `ddprof → database launch chain`；`ddprof -p <PID>` 只可诊断 CPU，不能算 profiling 已部署，也不能作为 heap 降级方案。
- 不启用 wrapper 时，Agent/DBM/进程 CPU 等普通采集仍正常，但明确显示“无 native allocation/live-heap”。
- 启用 wrapper 和立即重启是两个独立决定。安装器先问是否启用，再在全部 preflight 通过后问是否现在重启；任何非 TTY 自动化都不能默认为“重启”。
- 每个数据库实例只有一个生命周期 owner：PostgreSQL 原 systemd、无 CM 场景的 dbdog supervisor、或原 CM。launcher 不做重启循环。
- CM 场景必须是 `CM → launcher → ddprof → gaussdb`；不新增 CM 自定义 DN resource，不替换数据库身份，不全局设置 `/etc/ld.so.preload`，不把 ddprof 注入 cm_agent。
- CM 自动 start、operator start、故障恢复和 mode/role restart 必须全部经过同一个 launcher-aware 函数；只修 `StartDatanodeCheck` 不算完成。
- launcher 参数始终是 argv 边界，不拼 shell command、不使用 `eval`；真实数据库 binary、`-D` 数据目录和 instance ID 必须互相匹配。
- 目标 CM 的精确源码是硬门禁。若无法把目标 `cm_agent` 的构建身份映射到精确 source commit，就停止 CM 代码/二进制部署并报告 `unsupported_lifecycle`；禁止拿能下载到的 RC2 源码猜配 RC1/GaussDB 二进制。
- openGauss 数据库和验收固定使用 `7.0.0-RC1`；RC3 资产、路径、版本 tag 和结论不得进入新模板。
- ddprof 使用 release manifest 中已校验的官方 v0.26.0 架构产物；本阶段不编译 ddprof。
- 激活前必须证明运行 ELF 有 `.symtab`，或 detached debug 与运行 ELF 的 build-id/CRC 完全匹配并生成合并 ELF；只有地址的 profile 不算成功。
- Agent trace intake、API 转发、DBM、logs、process、system-probe 在切换前后都必须健康。profiling 失败只回滚启动链，不回滚已健康的 Agent/DBM。
- CM/openGauss 源码改动属于其源码仓；release 拥有安装编排和客户端合同；Agent 仓不再保存第二份 supervisor/unit；web 仓保存家族责任和采集契约。
- 所有实现使用隔离 worktree。先推源码仓 `origin/main`，再构建 release 产物；不在目标机手改后倒推源码。

---

## 文件结构

### dbdog-release

- Modify: `scripts/agent-install.sh` — 在 DBM 成功后编排 profiling；加入两个独立确认点。
- Create: `scripts/agent/profiling.sh` — profiling preflight、prepare、activate、verify、rollback 状态机。
- Create: `scripts/agent/profiling-config.sh` — 严格 profile 配置格式和实例索引。
- Create: `scripts/agent/profiling-symbols.sh` — ELF、build-id、debuglink、合并 ELF 和 bind mount 计划。
- Create: `scripts/agent/profiling-launcher` — CM/systemd 共用的 launch-only wrapper。
- Create: `scripts/agent/gaussdb-profiler-supervisor.sh` — 无 CM 的常驻 `gs_ctl` 生命周期。
- Create: `scripts/agent/profiling-systemd.sh` — PostgreSQL drop-in、no-CM unit、符号 mount unit 渲染。
- Create: `scripts/agent/profiling-adapters/postgresql.sh`
- Create: `scripts/agent/profiling-adapters/gaussdb-no-cm.sh`
- Create: `scripts/agent/profiling-adapters/gaussdb-cm.sh`
- Create: `scripts/test-profiling-launcher.sh`
- Create: `scripts/test-profiling-symbols.sh`
- Create: `scripts/test-profiling-postgresql-systemd.sh`
- Create: `scripts/test-gaussdb-profiler-supervisor.sh`
- Create: `scripts/test-profiling-cm-contract.sh`
- Create: `scripts/test-profiling-transaction.sh`
- Modify: `scripts/collect-diagnostics.sh`
- Modify: `scripts/dbdogctl`
- Modify: `docs/design/database-host-deployment.md`
- Modify: `docs/ops/RUNBOOK.md`

### exact target CM source repository

- Create: `src/include/cm/cm_agent/cma_datanode_launcher.h`
- Create: `src/cm_agent/cma_datanode_launcher.cpp`
- Modify: `src/cm_agent/client_adpts/libpq/cma_datanode.cpp`
- Modify: `src/cm_agent/cma_process_messages.cpp`
- Modify: `src/include/cm/cm_agent/cma_global_params.h`
- Modify: `src/cm_agent/cma_global_params.cpp`
- Modify: `src/cm_agent/cma_common.cpp`
- Modify: `src/cm_agent/cma_main.cpp`
- Modify: `src/cm_agent/cm_agent.conf.sample`
- Modify: `src/cm_agent/cm_agent.centralized.conf.sample`
- Modify: `src/cm_agent/cm_agent.centralized_new.conf.sample` if present in the exact target source.
- Modify: root `CMakeLists.txt` and `src/cm_agent/CMakeLists.txt`
- Create: `src/cm_agent/tests/CMakeLists.txt`
- Create: `src/cm_agent/tests/cma_datanode_launcher_test.cpp`

### dbdog-agent

- Delete: `dbdog-deploy/scripts/gaussdb-profiler-supervisor.sh`
- Delete: `dbdog-deploy/scripts/test-gaussdb-profiler-supervisor.sh`
- Delete: `dbdog-deploy/systemd/dbdog-profiled-gaussdb.service`
- Delete: `dbdog-deploy/systemd/dbdog-profiled-opengauss.service`
- Modify: `dbdog-deploy/docs/ops/RUNBOOK-ddprof-*.md` — 保留历史实证，入口和资产 ownership 指向 release。

### dbdog-web

- Modify: `docs/family/topics/profiling.md` — release 拥有安装/lifecycle 编排，Agent 拥有 intake/forwarding，CM 拥有 DN lifecycle hook。
- Modify/Regenerate: profiling-related `docs/devspec/` contract artifacts as required by `docs/devspec/README.md`.

## Versioned Launcher Contract

合同常量为 `dbdog-dn-launcher/v1`。

CM 对 launcher 的调用严格为：

```text
/usr/local/libexec/dbdog-profile-launcher \
  --binary /absolute/path/to/gaussdb \
  -- <original-gaussdb-argv-without-argv0>
```

`cm_agent --dbdog-launcher-contract-version` 和 `dbdog-profile-launcher --contract-version` 都只打印一行 `dbdog-dn-launcher/v1` 并以 0 退出。安装器在修改 CM 配置或数据库启动链之前比较两端输出。

CM 新配置键：

```text
dbdog_dn_launcher = '/usr/local/libexec/dbdog-profile-launcher'
```

空值表示直启真实 `gaussdb`。非空值必须是 absolute、regular、非 symlink、可执行、root-owned 且 group/other 不可写。SIGHUP reload 遇到无效新值时保留上一份有效值并明确报警。

实例配置位于 `/etc/dbdog-agent/profiling/<instance-id>.conf`，只允许以下键：

```text
contract_version=dbdog-dn-launcher/v1
enabled=true
instance_id=<64-hex>
engine=gaussdb|opengauss|postgresql
data_dir=<canonical-absolute-path>
binary=<canonical-absolute-path>
binary_sha256=<64-hex>
ddprof=/opt/dbdog-agent/embedded/bin/ddprof
service=<engine-service>
environment=<tag>
version=<database-version>
database_instance=<hostname:port>
tags=<comma-separated-validated-tags>
agent_port=5126
upload_period_seconds=59
```

文件不含 API key、数据库密码或 shell 片段。launcher 自己逐行 parse 白名单，拒绝重复键、未知键、控制字符和不匹配的 binary/data-dir；不能 `source` 配置。

---

## Task 0: 锁定目标 CM 的精确源码和可恢复构建链

**Files:**
- Create: `docs/testing/cm-source-provenance.md`
- Reference only: target VM CM binary/package/config.
- Reference only: exact target CM source repository/worktree.

- [ ] **Step 1: 在目标 VM 只读采集 CM 身份**

记录 `cm_agent -V`、真实 binary 路径、SHA-256、ELF build-id、package owner、编译器标记、当前 CM unit/启动方式、当前 config 路径和数据库实例列表。命令输出脱敏后进入 provenance 文档。

- [ ] **Step 2: 从 vendor source package/build metadata 得到唯一 source commit**

仅用版本字符串不够。必须由 package source、build manifest 或 vendor CI 元数据证明 `target binary SHA/build-id → repository URL + commit + build options`。

- [ ] **Step 3: 在隔离 worktree 重建未修改 CM 并做基线比较**

允许动态时间戳导致整文件 SHA 不同，但 text section、导出符号、依赖、配置 sample 和 smoke 行为必须解释一致。记录 builder OS、compiler、CMake flags 和依赖版本。

- [ ] **Step 4: 建立可恢复安装包和目标机回滚包**

保存原 CM binary/package/config checksum，验证能在不更改数据库数据目录的情况下恢复原包。未完成恢复演练前不得进入 Task 6 的 CM 部署。

- [ ] **Step 5: Gate 结论**

若精确源码无法获得：提交 provenance 文档，CM adapter 固定返回 `unsupported_lifecycle`，继续完成 PostgreSQL 和 no-CM 功能；禁止修改或部署 CM。若获得：在该精确 source commit 上建立 feature worktree。

- [ ] **Step 6: 提交证据**

```bash
git add docs/testing/cm-source-provenance.md
git commit -m "docs(profiling): pin target cm source provenance"
```

## Task 1: 实现严格 profiling 配置和共用 launcher

**Files:**
- Create: `scripts/agent/profiling-config.sh`
- Create: `scripts/agent/profiling-launcher`
- Create: `scripts/test-profiling-launcher.sh`

**Interfaces:**
- Produces: `profiling_write_config <instance-index> <staging-root>` — strict, secret-free file。
- Produces: `profiling_index_data_dir <instance-id> <canonical-data-dir>` — collision-safe index。
- Produces: `dbdog-profile-launcher --contract-version`。
- Consumes: `--instance-id <id>` for systemd, or canonical `-D` from argv for CM.
- Executes: disabled → real binary directly; enabled → `ddprof ... real-binary original-argv...`。

- [ ] **Step 1: 写失败测试覆盖 passthrough、启用、参数边界和恶意配置**

用 fake ddprof/gaussdb 以 NUL 格式记录 argv。覆盖含空格路径、`--`、重复 `-D`、缺 `-D`、binary SHA 变化、symlink 替换、未知配置键、换行 tag、enabled=false 和两个实例 data-dir collision。

- [ ] **Step 2: 运行并确认 launcher 尚不存在**

Run: `bash scripts/test-profiling-launcher.sh`

Expected: FAIL。

- [ ] **Step 3: 实现无 `source`/无 `eval` parser 与实例匹配**

CM 路径从原 argv 中读取唯一 `-D <dir>` 或 `--pgdata=<dir>`，canonicalize 后查索引；systemd 路径使用 installer 写入的完整 instance ID。索引不存在、多个匹配或身份不符都 fail closed，不能直启未验证的另一个 binary。

- [ ] **Step 4: 以 Bash array 构造 ddprof argv**

固定包含 `-S`、`-E`、`-V`、`-T instance:<port>,database_instance:<hostname:port>,...`、`-P 5126`、`--preset cpu_live_heap`、显式 upload period、`-l notice --log_mode stdout`，最后追加真实 binary 与原始 argv。

- [ ] **Step 5: 明确 disabled passthrough**

只有已找到且合同有效、`enabled=false` 的配置可 passthrough；配置缺失表示部署错误并退出非零，避免 CM 以为 profiling 已准备却绕过 wrapper。CM 未启用 hook 时由 CM 自己直启，不调用 launcher。

- [ ] **Step 6: 运行测试和 shell 静态检查**

Run: `bash scripts/test-profiling-launcher.sh && bash -n scripts/agent/profiling-config.sh scripts/agent/profiling-launcher`

Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add scripts/agent/profiling-config.sh scripts/agent/profiling-launcher scripts/test-profiling-launcher.sh
git commit -m "feat(profiling): add versioned database launch wrapper"
```

## Task 2: 实现 ddprof、Agent intake 和符号硬门禁

**Files:**
- Create: `scripts/agent/profiling-symbols.sh`
- Create: `scripts/test-profiling-symbols.sh`
- Modify: `scripts/agent/profiling-config.sh`

**Interfaces:**
- Produces: `profiling_verify_ddprof <path> <expected-version> <expected-sha> <arch>`。
- Produces: `profiling_verify_intake` — local Agent trace intake and non-database smoke。
- Produces: `profiling_prepare_symbols <instance-index>` → `native-symtab|merged-bind|unsupported`。
- Produces: `profiling_verify_symbol_mount <instance-index>`。

- [ ] **Step 1: 写 ELF fixture 测试**

fixture 包括：自带 `.symtab`、完全 stripped、匹配 debuglink、错误 CRC、错误 build-id、错误架构、合并后 text SHA 不同、目标 binary 在 preflight 后被替换。

- [ ] **Step 2: 运行测试并确认旧流程只做路径存在检查**

Run: `bash scripts/test-profiling-symbols.sh`

Expected: FAIL。

- [ ] **Step 3: 验证 manifest SHA、ELF arch、动态依赖和 ddprof version**

校验失败发生在任何数据库 mutation 之前。用一个 85 秒非数据库 busy-loop smoke 证明 `cpu_live_heap` 可启动并能通过本机 Agent intake 上传，不复用另一台机器的结果。

- [ ] **Step 4: 实现 native `.symtab` 快路径**

记录 `.symtab` size、ELF build-id、binary SHA 和 `readelf -Ws` 可解析函数数量；GaussDB/openGauss RC1 自带符号时不修改 binary 或 mount。

- [ ] **Step 5: 实现 detached debug 严格合并**

只接受 ELF `.gnu_debuglink` 指向或用户显式提供的 absolute debug file；同时验证 debuglink CRC 和 build-id。用 `eu-unstrip` 生成 `/var/lib/dbdog-agent/profiling/<id>/bin/<name>`，验证架构、program headers、version output 和 executable mode，再生成 read-only bind mount 计划。

- [ ] **Step 6: 为持久 bind mount 设置 lifecycle dependency**

只有 lifecycle owner 是 systemd unit 时支持自动 merged bind：生成 `dbdog-profile-symbols-<id-prefix>.mount`，并让数据库/CM unit `Requires=`、`After=` 它。非 systemd owner 缺 `.symtab` 时返回 `symbols_unavailable`，不得临时 mount 后留下重启隐患。

- [ ] **Step 7: 运行测试**

Run: `bash scripts/test-profiling-symbols.sh`

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add scripts/agent/profiling-symbols.sh scripts/agent/profiling-config.sh scripts/test-profiling-symbols.sh
git commit -m "feat(profiling): require matching native symbols"
```

## Task 3: 接入 PostgreSQL systemd 生命周期

**Files:**
- Create: `scripts/agent/profiling-systemd.sh`
- Create: `scripts/agent/profiling-adapters/postgresql.sh`
- Create: `scripts/test-profiling-postgresql-systemd.sh`

- [ ] **Step 1: 写 fake systemd 测试覆盖 unit ownership 和 argv 保真**

从 `/proc/<postmaster-pid>/cgroup` 与 systemd MainPID 双向证明 unit ownership；从 `/proc/<pid>/cmdline` 读取 NUL argv。覆盖 template unit、带空格参数、多个 ExecStart、不由 systemd 管理、MainPID 不符、unit 已有第三方 wrapper 和 rollback。

- [ ] **Step 2: 运行测试并确认无 PostgreSQL lifecycle adapter**

Run: `bash scripts/test-profiling-postgresql-systemd.sh`

Expected: FAIL。

- [ ] **Step 3: 只支持可证明拥有当前 postmaster 的单一 systemd unit**

不是 systemd、unit/MainPID 不一致、已有未知 wrapper 或无法获得原 argv 时返回 `unsupported_lifecycle`。不得从 `ps` 文本或 unit shell string 猜 argv。

- [ ] **Step 4: 生成只覆盖 `ExecStart` 的 drop-in**

保留原 unit 的 User、Group、Environment、limits、timeouts、KillMode、Restart 和 dependencies。drop-in 先清空 `ExecStart=`，再用经过 systemd escaping 的 `/usr/local/libexec/dbdog-profile-launcher --instance-id ... --binary ... -- <proc-cmdline args>`；`systemd-analyze verify` 失败则不安装。

- [ ] **Step 5: 准备阶段只 daemon-reload，不重启**

保存原 PID/start time 和 drop-in 快照；用户拒绝重启时 unit 仍运行原进程，状态为 `prepared_not_active`。下一次明确激活或自然维护重启前仍要重新验证 binary SHA 和 symbols。

- [ ] **Step 6: 实现精确 instance restart 与 rollback**

用户批准后只 `systemctl restart <owned-unit>`；失败时移除/恢复 drop-in、daemon-reload、按原 unit restart，并验证原 service、port、`SELECT 1` 和未选实例 PID。

- [ ] **Step 7: 运行测试**

Run: `bash scripts/test-profiling-postgresql-systemd.sh`

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add scripts/agent/profiling-systemd.sh scripts/agent/profiling-adapters/postgresql.sh scripts/test-profiling-postgresql-systemd.sh
git commit -m "feat(profiling): wrap systemd postgres lifecycle"
```

## Task 4: 迁移并通用化无 CM 的 `gs_ctl` supervisor

**Files:**
- Create: `scripts/agent/gaussdb-profiler-supervisor.sh`
- Create: `scripts/agent/profiling-adapters/gaussdb-no-cm.sh`
- Create: `scripts/test-gaussdb-profiler-supervisor.sh`
- Delete/Modify: matching assets and runbooks in `dbdog-agent`.

- [ ] **Step 1: 从 Agent 当前已实测 supervisor 行为写失败测试**

覆盖 start、stop、postmaster.pid、错误 executable、already-running exit 75、start timeout、unexpected exit、signal forwarding、带/不带 `-l`，并新增多个实例独立 unit 与环境文件安全加载。

- [ ] **Step 2: 运行测试并确认 release 尚无该 asset**

Run: `bash scripts/test-gaussdb-profiler-supervisor.sh`

Expected: FAIL。

- [ ] **Step 3: 迁移 supervisor，删除 VM202/VM203 硬编码**

所有 `gs_ctl`、data dir、expected exe、owner home、log path 来自 instance state；helper 子进程清空 `LD_PRELOAD`，避免轮询噪声；不包含 `Ruby`、37000、RC3 等机器值。

- [ ] **Step 4: 生成每实例 systemd unit**

unit 名为 `dbdog-profiled-<engine>@<id-prefix>.service`，进程链固定为 `profile-launcher → ddprof → supervisor → gs_ctl → gaussdb`。原生命周期必须可唯一识别并在切换前 stop/disable；未知 lifecycle 拒绝切换。

- [ ] **Step 5: 实现 rollback 到原 lifecycle**

切换失败时 stop/disable 新 unit，恢复原 unit/gs_ctl 启动方式并启动数据库；禁止 systemd 和原脚本同时具有 Restart 权限。

- [ ] **Step 6: release 新 asset 提交后删除 Agent 重复 source**

Agent 中历史 runbook 保留事实证据，但明确新安装由 dbdog-release 生成，不保留可继续漂移的模板 unit/supervisor 副本。

- [ ] **Step 7: 运行测试并扫描硬编码**

Run: `bash scripts/test-gaussdb-profiler-supervisor.sh`

Run: `rg -n 'Ruby|37000|7\.0\.0-RC3|host109-vm20' scripts/agent`

Expected: PASS；扫描为零。

- [ ] **Step 8: 提交**

```bash
git add scripts/agent/gaussdb-profiler-supervisor.sh scripts/agent/profiling-adapters/gaussdb-no-cm.sh scripts/test-gaussdb-profiler-supervisor.sh
git commit -m "feat(profiling): manage non-cm gauss lifecycle"
```

## Task 5: 在精确 CM 源码中先实现纯 launcher argv 合同

**Files:**
- Create: `src/include/cm/cm_agent/cma_datanode_launcher.h`
- Create: `src/cm_agent/cma_datanode_launcher.cpp`
- Create: `src/cm_agent/tests/CMakeLists.txt`
- Create: `src/cm_agent/tests/cma_datanode_launcher_test.cpp`
- Modify: root `CMakeLists.txt`
- Modify: `src/cm_agent/CMakeLists.txt`

**C++ Interfaces:**

```cpp
constexpr const char* DBDOG_DN_LAUNCHER_CONTRACT = "dbdog-dn-launcher/v1";

struct DatanodeLaunchSpec {
    std::string binary;
    std::vector<std::string> arguments;
    std::string logFile;
};

std::vector<std::string> BuildDatanodeExecArgv(
    const DatanodeLaunchSpec& spec, const std::string& launcher);
int SpawnDatanodeDetached(const std::vector<std::string>& argv,
    const std::string& logFile);
```

- [ ] **Step 1: 启用最小 CTest target 并写失败单测**

不用引入新 test framework；测试 executable 逐项断言 vector。覆盖 launcher 空/非空、带空格参数、`--` 边界、绝对路径拒绝、日志打开失败、fork/exec 失败和 child exit 不阻塞 CM。

- [ ] **Step 2: 构建 test target 并确认失败**

Run: exact target repo documented CMake configure command with `-DBUILD_TESTING=ON`, then `ctest -R cma_datanode_launcher --output-on-failure`。

Expected: FAIL，helper 未实现。

- [ ] **Step 3: 实现纯 argv builder**

launcher 为空时 vector 为 `[real-gaussdb, original-args...]`；非空时为 `[launcher, --binary, real-gaussdb, --, original-args...]`。禁止生成 shell quoting 或单个 command string。

- [ ] **Step 4: 实现后台 exec，保持现有 CM 非阻塞语义**

使用 fork/double-fork、`open(O_APPEND|O_CREAT)`、`dup2`、`execv` 和明确 errno pipe，使 parent 能区分“成功 exec”与“fork 成功但 exec 失败”。不能用 `system()` 启动 datanode，也不能留下 zombie。

- [ ] **Step 5: 运行 CTest、ASAN/UBSAN 可用时也运行**

Run: `ctest -R cma_datanode_launcher --output-on-failure`

Expected: PASS。

- [ ] **Step 6: 提交 CM 纯 helper**

```bash
git add CMakeLists.txt src/cm_agent/CMakeLists.txt src/cm_agent/tests src/cm_agent/cma_datanode_launcher.cpp src/include/cm/cm_agent/cma_datanode_launcher.h
git commit -m "feat(cm_agent): add versioned datanode launcher argv"
```

## Task 6: 让 CM 全部 DN start/restart 入口使用统一 helper

**Files:**
- Modify: `src/cm_agent/client_adpts/libpq/cma_datanode.cpp`
- Modify: `src/cm_agent/cma_process_messages.cpp`
- Modify: `src/cm_agent/tests/cma_datanode_launcher_test.cpp`

- [ ] **Step 1: 先加绕过防护测试**

测试对源文件和可执行行为双重检查：`BuildStartCommand` 不再返回 shell string；`StartDatanodeCheck` 不再对 DN start 调 `system(command)`；`process_restart_by_mode_command` 不再使用 `gs_ctl restart` 拉起 DN；每个 start mode 的最终 argv 都经过 `BuildDatanodeExecArgv`。

- [ ] **Step 2: 运行测试并确认当前首次启动和 mode restart 都绕过 helper**

Expected: FAIL。

- [ ] **Step 3: 把 `BuildStartCommand` 重构为 `BuildDatanodeLaunchSpec`**

逐分支把 DCF、single/primary/standby/pending 等 mode 的原参数变成 vector；为重构前后每个分支建立 argv snapshot，除插入 launcher 外参数顺序和语义完全一致。

- [ ] **Step 4: `StartDatanodeCheck` 调统一 `SpawnDatanodeDetached`**

启动返回后继续使用现有 PID/status/connection 检查观察真实 gaussdb；不把 launcher 或 ddprof worker PID 写成 datanode PID。

- [ ] **Step 5: 把 mode restart 改为“原语义 stop + 统一 start”**

`process_restart_by_mode_command` 使用现有 `gs_ctl stop`/等待逻辑停止目标 DN，然后构造新 role/mode 的 `DatanodeLaunchSpec` 并调用统一 helper。保留原 timeout、错误上报和角色切换状态机；任何路径不得再调用 `gs_ctl restart`。

- [ ] **Step 6: 源码扫描所有 DN start bypass**

Run: `rg -n 'gaussdb.*&|gs_ctl restart|DN START system|system\(command\)' src/cm_agent`

逐条分类；与其他资源无关的 `system()` 可以保留，但所有 datanode launch 命中必须为零或由测试白名单解释。

- [ ] **Step 7: 运行 CTest 和 CM 现有 build/smoke**

Expected: 所有 launcher tests PASS；未启用 launcher 时行为与基线一致。

- [ ] **Step 8: 提交**

```bash
git add src/cm_agent/client_adpts/libpq/cma_datanode.cpp src/cm_agent/cma_process_messages.cpp src/cm_agent/tests/cma_datanode_launcher_test.cpp
git commit -m "feat(cm_agent): route every datanode start through launcher"
```

## Task 7: 增加 CM 配置、reload 和只读 contract version

**Files:**
- Modify: `src/include/cm/cm_agent/cma_global_params.h`
- Modify: `src/cm_agent/cma_global_params.cpp`
- Modify: `src/cm_agent/cma_common.cpp`
- Modify: `src/cm_agent/cma_main.cpp`
- Modify: `src/cm_agent/cm_agent*.conf.sample`
- Modify: `src/cm_agent/tests/cma_datanode_launcher_test.cpp`

- [ ] **Step 1: 写失败测试覆盖启动读取、SIGHUP reload 和无效值保留旧配置**

覆盖空值、相对路径、symlink、非 regular、不可执行、group-writable、非 root-owned、有效 absolute launcher、有效→无效 reload、有效→空值 reload。

- [ ] **Step 2: 为 global params 增加线程安全 snapshot**

配置解析在临时 buffer 中完成全部验证，再在 mutex/atomic snapshot 边界替换；start 线程每次只复制一份完整 launcher path，不能观察半写字符串。

- [ ] **Step 3: 接入初始加载和现有 SIGHUP 路径**

初始无效配置使 CM 启动失败并指出键；reload 无效只拒绝新值、保留旧值并报警。空值是显式禁用，下一次 DN start 直启；reload 本身不重启 CM 或数据库。

- [ ] **Step 4: 添加只读版本 CLI**

`cm_agent --dbdog-launcher-contract-version` 在加载集群配置前打印合同并退出；不能要求 CM 正在运行，也不能输出其他日志到 stdout。

- [ ] **Step 5: 运行 CTest、sample config parse 和完整构建**

Expected: PASS；sample 默认空值，未配置用户零行为变化。

- [ ] **Step 6: 提交**

```bash
git add src/include/cm/cm_agent/cma_global_params.h src/cm_agent/cma_global_params.cpp src/cm_agent/cma_common.cpp src/cm_agent/cma_main.cpp src/cm_agent/cm_agent*.conf.sample src/cm_agent/tests/cma_datanode_launcher_test.cpp
git commit -m "feat(cm_agent): configure reloadable datanode launcher"
```

## Task 8: 实现 release 侧 CM adapter 和统一 profiling 事务

**Files:**
- Create: `scripts/agent/profiling-adapters/gaussdb-cm.sh`
- Create: `scripts/agent/profiling.sh`
- Create: `scripts/test-profiling-cm-contract.sh`
- Create: `scripts/test-profiling-transaction.sh`
- Modify: `scripts/agent-install.sh`

**States:** `profiling_disabled`、`prepared_not_active`、`profiling_active`、`unsupported_lifecycle`、`symbols_unavailable`、`profiling_rolled_back`。

- [ ] **Step 1: 写合同和故障注入测试**

覆盖 CM contract 匹配/不匹配、launcher 配置 reload、不启用 wrapper、启用但拒绝重启、非 TTY 默认不重启、restart 失败、数据库健康失败、profile 无 heap、profile worker 退出和 rollback 恢复原 CM 配置。

- [ ] **Step 2: 运行测试并确认安装器没有 profiling 阶段**

Run: `bash scripts/test-profiling-cm-contract.sh && bash scripts/test-profiling-transaction.sh`

Expected: FAIL。

- [ ] **Step 3: 实现两个独立输入合同**

`DBDOG_PROFILING=ask|enabled|disabled`；`DBDOG_PROFILE_RESTART=ask|yes|no`。TTY 未设置时逐实例询问；非 TTY 未设置时分别等价于 `disabled` 和 `no`。只有用户显式给 `yes` 才允许重启。

- [ ] **Step 4: prepare 顺序固定且全量完成后才问 restart**

顺序：ddprof → intake smoke → binary/symbol → lifecycle/CM contract → snapshot → staging config/launcher/unit/CM setting → static verification。任何实例 preflight 失败不影响 DBM，也不重启任何实例。

- [ ] **Step 5: CM adapter 只改 launcher config 并 SIGHUP**

先验证两端 contract version，再安装 root-owned launcher/config，原子修改唯一 `dbdog_dn_launcher` 键，向现有 cm_agent 发 SIGHUP并读日志/状态证明 reload 成功。不得 stop/restart cm_agent 作为配置动作。

- [ ] **Step 6: 用户批准后只重启选中的当前实例**

PostgreSQL 使用 owned systemd unit；no-CM 使用原 lifecycle stop 后启动 profiled unit；CM 使用原 CM/`cm_ctl` 对该 DN 的受支持 restart 命令。当前节点视为主节点，不做 stream/remote 节点操作。

- [ ] **Step 7: 验收失败按实例恢复原启动链**

恢复 drop-in/unit/CM config/symbol mount，使用原 lifecycle 启动数据库；验证 port、`SELECT 1`、CM status、DBM、其他 Agent checks 和所有未选实例原 PID。Agent/DBM 保持安装。

- [ ] **Step 8: 运行事务测试**

Run: `bash scripts/test-profiling-launcher.sh && bash scripts/test-profiling-symbols.sh && bash scripts/test-profiling-postgresql-systemd.sh && bash scripts/test-gaussdb-profiler-supervisor.sh && bash scripts/test-profiling-cm-contract.sh && bash scripts/test-profiling-transaction.sh`

Expected: PASS。

- [ ] **Step 9: 提交**

```bash
git add scripts/agent/profiling.sh scripts/agent/profiling-adapters/gaussdb-cm.sh scripts/agent-install.sh scripts/test-profiling-cm-contract.sh scripts/test-profiling-transaction.sh
git commit -m "feat(agent-install): orchestrate native profiling lifecycle"
```

## Task 9: 构建并安全部署 patched CM 到目标环境

**Files:**
- Modify: exact CM source packaging/build metadata required by its native release process.
- Create: `docs/testing/cm-launcher-deployment-acceptance.md`

- [ ] **Step 1: 从 Task 0 的精确 source/build environment 编 release 版本**

使用原优化级别和依赖，只增加 launcher contract 改动；保留 CM 自身需要的 debug/symbol artifact 供崩溃诊断。产物记录 source commit、builder identity、compiler、CMake flags、binary SHA/build-id 和 SBOM/依赖。

- [ ] **Step 2: 在同版本隔离环境验证未启用 hook 的行为**

空 `dbdog_dn_launcher` 下跑 CM 原 smoke、start/stop/restart/role mode 测试，证明 argv snapshot 和基线等价。没有这一步不得部署到 VM203/真实 GaussDB。

- [ ] **Step 3: 部署前快照目标管理面**

记录 CM quorum/status、全部 DN PID/role/port、数据库事务健康、Agent/DBM/log/process/system checks、原 binary/config checksums 和回滚命令。CM binary 切换本身按 vendor runbook 执行，不能由 `agent-install.sh` 静默完成。

- [ ] **Step 4: 安装 patched CM，先保持 launcher 空值**

验证 CM 恢复健康、全部数据库实例状态未变化、`--dbdog-launcher-contract-version` 正确，再由 release installer prepare launcher config。

- [ ] **Step 5: 激活一个测试 DN，验证 restart 也不绕过**

先做 operator start，再做一次 CM mode/role restart 或可恢复的故障拉起；两次新的 gaussdb 进程都必须具有 ddprof parent/worker 证据，且 CM 仍识别真实 gaussdb PID 和健康状态。

- [ ] **Step 6: 失败时恢复原 CM package 和 config**

按 Task 0 已演练路径回滚，验证 CM 和所有 DN 恢复；不删除 Agent/DBM。记录失败阶段、是否已发生 DB restart 和恢复后的 PID/role。

- [ ] **Step 7: 提交验收证据并推 CM 源码**

源代码 review/test 通过后按 CM 仓规则推送授权分支/`origin/main`；验收文档提交到 release。不能只在目标机留下二进制。

## Task 10: 端到端六轴验收、诊断和跨仓责任同步

**Files:**
- Modify: `scripts/collect-diagnostics.sh`
- Modify: `scripts/dbdogctl`
- Create: `docs/testing/native-profiling-acceptance.md`
- Modify: `docs/design/database-host-deployment.md`
- Modify: `docs/ops/RUNBOOK.md`
- Modify: `dbdog-web/docs/family/topics/profiling.md`
- Modify/Regenerate: relevant `dbdog-web/docs/devspec/` artifacts.
- Modify: `dbdog-agent/dbdog-deploy/docs/ops/RUNBOOK-ddprof-*.md`.

- [ ] **Step 1: diagnostics/status 显示状态而非猜测**

`dbdogctl status` 对每实例输出 lifecycle owner、contract version、wrapper prepared/active、database PID、binary/build-id、symbol mode、ddprof worker、最近 profile period 和六轴状态。不得读取或输出 secret。

- [ ] **Step 2: 三类 lifecycle 各做一次真实验收**

至少：一个 PostgreSQL systemd、一个 openGauss 7.0.0-RC1 no-CM、一个 exact-contract CM 管理的 GaussDB/openGauss。保存 prepare-only 和 approved-restart 两条结果。

- [ ] **Step 3: 连续三个 upload period 验证六轴和 unwind**

对同一 `database_instance=hostname:port` 验证 CPU time/count、allocation bytes/count、live-heap bytes/count，且 events 与 flame graph 都可查询；`unwind.errors=0`，无 exporter error。只有进程/CPU metrics 不算 PASS。

- [ ] **Step 4: 验证数据库与全部既有采集不受损**

对比切换前后 DBM queries/samples、host metrics、process、logs、traces、system-probe 和其他 integrations；对未选实例 PID/start time 必须完全相同。记录 profiler CPU/RSS 实测，不复用其他主机开销。

- [ ] **Step 5: 验证重启持久性和 profile worker 退出语义**

正常重启后 wrapper 仍生效；单独让 profiler worker 退出时 CM/systemd 不应为健康数据库制造额外 restart，状态报告断流；恢复 heap profiling需要操作者再次确认数据库重启。

- [ ] **Step 6: 更新三仓 ownership 和契约**

web family topic 写清 release=installation/lifecycle orchestration、Agent=intake/forwarding、CM=DN lifecycle hook、ddprof=official binary；Agent 历史 runbook 不再宣称模板 source ownership。按 `docs/devspec/README.md` 用生成器刷新契约。

- [ ] **Step 7: 运行全量检查和 placeholder 扫描**

Run in release: `for t in scripts/test-*.sh; do bash "$t"; done`

Run in CM: native build/test commands plus `ctest --output-on-failure`。

Run in web/Agent: each repository's owning checks。

Run: `rg -n 'TBD|TODO|FIXME|7\.0\.0-RC3|Ruby|37000|host109-vm20' scripts docs/ops docs/testing`

Expected: tests PASS；无机器硬编码或未解决 placeholder。

- [ ] **Step 8: 分仓提交**

```bash
git commit -m "docs(profiling): publish one-click lifecycle contract"
```

## Completion Gate

- 用户未选 wrapper 时 DBM 正常且明确说明没有 native heap；用户选 wrapper 但拒绝重启时状态严格为 `prepared_not_active`。
- PostgreSQL、no-CM 和 CM 三种生命周期都能在用户批准后只重启目标实例，并在失败时恢复原管理面。
- CM 的首次启动、故障恢复和 mode/role restart 都使用同一版本化 launcher contract；contract 不匹配时绝不激活。
- openGauss 验收版本为 7.0.0-RC1；patched CM 来自目标二进制的精确 source，而不是 RC2/未知近似源码。
- 所有 active 实例连续三个周期具有 CPU、allocation、live-heap 六轴、可读函数符号和零 unwind error。
- profiling 切换未破坏 Agent、DBM、logs、process、system-probe、traces 或未选数据库实例。
- release、CM、Agent、web 四方源码、产物、责任文档和目标机状态能够相互追溯。
