# 数据库主机与 DBM 一键部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `agent-install.sh` 做成数据库主机的一键安装入口：自动发现当前正在运行的 PostgreSQL、GaussDB 和 openGauss 7.0.0-RC1 实例，让用户选择实例并按需提供环境文件，为每个实例配置 DBM、全部非模板逻辑库和主机采集，且不重启数据库。

**Architecture:** 安装器拆成“主机事实发现 → 引擎适配 → 数据库初始化 → 托管配置渲染 → 原子切换”五层。一个主机只安装一个 Agent；数据库身份使用引擎、真实可执行文件和数据目录构成的稳定 ID，配置以该 ID 隔离。安装器只拥有带 `dbdog` 标记的文件和明确声明的 YAML 键，未知配置一律保留；数据库对象采用幂等 SQL 创建，配置文件切换失败可以回滚，已成功创建的数据库对象不做破坏性回滚。

**Tech Stack:** Bash 4+、Linux `/proc`、systemd、Agent embedded Python/PyYAML、psql/gsql、Datadog Agent PostgreSQL/GaussDB integrations、shell contract tests。

## Global Constraints

- 本阶段只配置采集，不改变数据库启动链，不安装 profiling wrapper，也不重启数据库；profiling 生命周期由下一阶段负责。
- 当前节点即用户要采集的主节点；即使检测到 CM，也不推断集群拓扑、不自动发现远端节点、不配置 stream 采集。
- 一个主机只运行一个 dbdog Agent；多实例通过多个 integration instance 配置表达。
- PostgreSQL、GaussDB 和 openGauss 都采集全部 `datallowconn AND NOT datistemplate` 的逻辑库；禁止只采安装时连接的一个库。
- openGauss 行为和实测基线固定为 `7.0.0-RC1`；不得拿 RC3 或 CM RC2 的行为替代 RC1 结论。
- 数据库实例的南向唯一身份是 `(engine, real_executable, canonical_data_dir)`；端口只是北向显示/DBM identity 的一部分，不能用端口代替物理身份。
- DBM 与 profiling 的用户可见 service key 统一为 `hostname:port`；不得在两个阶段生成不同 service 名。
- 环境文件只接受绝对路径、普通文件、不可被 group/other 写；绝不以 root 直接 `source` 用户文件。只在目标数据库用户的空环境子进程中加载白名单变量。
- 不修改 `pg_hba.conf`、密码策略、审计策略、数据库监听地址或业务用户；这些只做只读预检并给出可执行错误。
- 不覆盖用户的整个 `/etc/dbdog-agent`。只管理 `.dbdog-managed-files.tsv` 登记的文件和 `datadog.yaml` 中明确声明的键。
- Agent 与 Agent Core 使用执行时 `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv` 的当前锚；不要在计划文档中钉死会过期的提交号。
- 接口/采集面变化必须同步 `dbdog-web/docs/devspec/` 契约和家族文档；不能只改 release 脚本。
- 所有实现先在隔离 worktree 完成，源仓出货提交先进入各自 `origin/main`，再发布 release 产物。

---

## 文件结构

### dbdog-release

- Modify: `scripts/agent-install.sh` — 只保留参数、阶段编排、事务和最终摘要。
- Modify: `scripts/agent-lib.sh` — 保留通用日志、权限、命令和原子文件工具，移除 GaussDB 单实例假设。
- Create: `scripts/agent/instances.sh` — 稳定实例模型、去重、选择和自动化输入。
- Create: `scripts/agent/environment.sh` — 数据库用户环境文件的安全提取。
- Create: `scripts/agent/adapters/postgresql.sh` — PostgreSQL 进程识别、事实补全和客户端执行。
- Create: `scripts/agent/adapters/gaussdb.sh` — GaussDB 事实补全和客户端执行。
- Create: `scripts/agent/adapters/opengauss.sh` — openGauss RC1 事实补全和客户端执行。
- Create: `scripts/agent/database.sh` — 逻辑库枚举、全局/per-db SQL 分发和校验。
- Create: `scripts/agent/render.sh` — integration、system-probe 和 host check 配置渲染。
- Create: `scripts/agent/managed-files.sh` — 托管清单、YAML merge、原子安装和回滚。
- Create: `scripts/agent/merge-yaml.py` — 只覆盖 dbdog-owned YAML path 的结构化合并器。
- Create: `scripts/agent/sql/postgresql/{global,perdb}.sql`
- Create: `scripts/agent/sql/gaussdb/{global,perdb}.sql`
- Create: `scripts/agent/sql/opengauss/{global,perdb}.sql`
- Create: `scripts/test-agent-instance-discovery.sh`
- Create: `scripts/test-agent-engine-adapters.sh`
- Create: `scripts/test-agent-database-bootstrap.sh`
- Create: `scripts/test-agent-managed-files.sh`
- Modify: `scripts/test-agent-install-contracts.sh`
- Modify: `scripts/collect-diagnostics.sh`
- Modify: `scripts/dbdogctl`
- Modify: `docs/design/database-host-deployment.md`
- Modify: `docs/ops/RUNBOOK.md`

### dbdog-agent

- Delete: `dbdog-deploy/scripts/init-datadog-user-opengauss-global.sql`
- Delete: `dbdog-deploy/scripts/init-datadog-user-opengauss-perdb.sql`
- Delete: `dbdog-deploy/scripts/init-datadog-user-postgres.sql`
- Delete: `dbdog-deploy/scripts/init-dbdog-user-gaussdb-global.sql`
- Delete: `dbdog-deploy/scripts/init-dbdog-user-gaussdb-perdb.sql`
- Delete: `dbdog-deploy/scripts/init-dbdog-user-pg-global.sql`
- Delete: `dbdog-deploy/scripts/init-dbdog-user-pg-perdb.sql`
- Modify: owning runbooks under `dbdog-deploy/` — link to release installer instead of retaining a second SQL source.

### dbdog-web

- Modify: `docs/design/dbm/gaussdb-collection.md` — document multi-instance/all-database behavior and RC1 basis.
- Modify: `docs/design/dbm/gaussdb-pg-opengauss-field-parity.md` — reference the effective generated integration config.
- Modify: `docs/devspec/agent-config-data.js` — record generated files, managed keys and autodiscovery.
- Regenerate: artifacts required by `docs/devspec/README.md` — never hand-edit generated HTML.

## Stable Interfaces

`scripts/agent/instances.sh` exposes parallel arrays because the supported installer Bash version cannot rely on associative-array ordering:

```bash
AGENT_DB_IDS=()
AGENT_DB_ENGINES=()
AGENT_DB_PIDS=()
AGENT_DB_PORTS=()
AGENT_DB_OWNERS=()
AGENT_DB_OWNER_HOMES=()
AGENT_DB_DATA_DIRS=()
AGENT_DB_BINARIES=()
AGENT_DB_CLIENTS=()
AGENT_DB_SOCKET_DIRS=()
AGENT_DB_ENV_FILES=()
AGENT_DB_PATHS=()
AGENT_DB_LD_LIBRARY_PATHS=()
AGENT_DB_LOG_GLOBS=()
AGENT_DB_LIFECYCLES=()
```

`agent_register_instance` 的位置参数顺序必须与上述字段一致；每次写入后检查所有数组长度相同。`agent_instance_id` 对 `engine`、`realpath(binary)`、`realpath(data_dir)` 三个值做长度前缀编码再算 SHA-256，使用完整 64 位值落盘，界面只显示前 12 位。

自动化输入合同：

- `DBDOG_INSTANCE_SELECTION=all` 或逗号分隔的完整 instance ID；未设置且 stdin 是 TTY 时打印表格让用户选择。
- `DBDOG_INSTANCE_ENV_MAP=/absolute/root-owned.tsv`，每行严格为 `instance_id<TAB>/absolute/env-file`；未设置时逐个询问“是否存在环境变量文件”。
- `DBDOG_DB_ADMIN_MAP=/absolute/root-owned.tsv`，只允许需要交互认证的实例指定管理员连接参数文件；普通场景使用数据库 owner 的本地 peer/ident 连接。
- 密码不作为命令行参数、环境回显或安装日志输出；实例 credential 文件权限固定为 root:dbdog `0640`。

---

## Task 1: 建立实例事实模型和稳定去重合同

**Files:**
- Create: `scripts/agent/instances.sh`
- Create: `scripts/test-agent-instance-discovery.sh`
- Modify: `scripts/agent-lib.sh`

- [ ] **Step 1: 写失败测试，覆盖稳定 ID、数组完整性和物理实例去重**

```bash
id1="$(agent_instance_id gaussdb /opt/gauss/bin/gaussdb /data/dn)"
id2="$(agent_instance_id gaussdb /opt/gauss/bin/../bin/gaussdb /data/./dn)"
[ "$id1" = "$id2" ]
agent_register_instance gaussdb 101 5432 omm /home/omm /data/dn /opt/gauss/bin/gaussdb gsql /tmp '' '' '' '/var/log/gauss/*' cm
[ "${#AGENT_DB_IDS[@]}" -eq 1 ]
agent_register_instance gaussdb 102 5432 omm /home/omm /data/dn /opt/gauss/bin/gaussdb gsql /tmp '' '' '' '/var/log/gauss/*' cm
[ "${#AGENT_DB_IDS[@]}" -eq 1 ]
```

- [ ] **Step 2: 运行测试并确认旧单实例实现失败**

Run: `bash scripts/test-agent-instance-discovery.sh`

Expected: FAIL，`instances.sh` 不存在，旧逻辑按第一个 GaussDB PID 提前返回。

- [ ] **Step 3: 实现长度前缀 ID、parallel-array invariant 和确定性排序**

发现结束后按 `engine,port,data_dir` 排序；检测到同一物理 ID 但 owner、binary 或 lifecycle 相互冲突时直接失败，不能静默采用第一条。

- [ ] **Step 4: 实现交互/非交互选择合同**

TTY 显示 `序号 engine port owner data_dir lifecycle id-prefix`；非 TTY 未提供 `DBDOG_INSTANCE_SELECTION` 时失败并打印可用完整 ID，不能默认选择错实例。

- [ ] **Step 5: 运行合同测试**

Run: `bash scripts/test-agent-instance-discovery.sh`

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add scripts/agent/instances.sh scripts/agent-lib.sh scripts/test-agent-instance-discovery.sh
git commit -m "feat(agent-install): model multiple database instances"
```

## Task 2: 实现三种引擎的进程发现与安全环境补全

**Files:**
- Create: `scripts/agent/environment.sh`
- Create: `scripts/agent/adapters/postgresql.sh`
- Create: `scripts/agent/adapters/gaussdb.sh`
- Create: `scripts/agent/adapters/opengauss.sh`
- Create: `scripts/test-agent-engine-adapters.sh`

**Interfaces:**
- Produces: `agent_discover_all` — 扫描 `/proc/[0-9]*/exe` 和 NUL 分隔 cmdline，不依赖 `ps | grep`。
- Produces: `agent_adapter_probe_<engine> <pid>` — 成功时调用一次 `agent_register_instance`。
- Produces: `agent_load_owner_environment <instance-index> <optional-env-file>` — 只返回白名单 `PATH`、`LD_LIBRARY_PATH`、`GAUSSHOME`、`PGDATA`、`PGHOST`、`PGPORT`、`GS_CLUSTER_NAME`。
- Produces: `agent_db_exec <instance-index> <database> <sql-file>` — argv 数组执行，不使用 `eval`。

- [ ] **Step 1: 用 fake `/proc` 和 fake `readlink` 写失败测试**

夹具必须包含：PG 的 `postgres -D`、GaussDB 的 `gaussdb -D`、openGauss RC1 的 `gaussdb -D`、重复线程/PID、带空格的数据目录、已经退出的 PID，以及端口只能通过 `postmaster.pid`/SQL 补全的实例。

- [ ] **Step 2: 运行测试并确认三个适配器尚不存在**

Run: `bash scripts/test-agent-engine-adapters.sh`

Expected: FAIL。

- [ ] **Step 3: 先按真实可执行文件和版本输出分类，再读取实例事实**

分类顺序固定为：可执行文件 realpath → `--version`/只读 SQL 识别发行版 → adapter。二进制名为 `gaussdb` 不能直接等同于 GaussDB；识别不确定时显示 `unsupported` 并跳过，不得猜测。

- [ ] **Step 4: 安全读取 owner 环境**

以 `setpriv`/`runuser` 启动数据库 owner 的 `env -i` 子进程，用超时和 NUL 输出采集白名单；用户指定 env 文件时在该低权限、空环境子进程内读取。拒绝 symlink、相对路径、owner 不匹配和 group/other writable 文件。

- [ ] **Step 5: 用只读连接补全 port/socket/version 并验证 RC1**

openGauss adapter 将 `SELECT version()` 结果记录进状态；若不是 `openGauss 7.0.0-RC1`，可继续作为“未验证版本”配置 DBM，但验收报告必须明确不计入 RC1 parity，不得把它伪装成 RC1 通过。

- [ ] **Step 6: 运行合同测试和 shell 语法检查**

Run: `bash scripts/test-agent-engine-adapters.sh && bash -n scripts/agent/*.sh scripts/agent/adapters/*.sh`

Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add scripts/agent/environment.sh scripts/agent/adapters scripts/test-agent-engine-adapters.sh
git commit -m "feat(agent-install): discover postgres and gauss instances"
```

## Task 3: 把数据库初始化 SQL 迁到唯一发布源

**Files:**
- Create: `scripts/agent/database.sh`
- Create: `scripts/agent/sql/postgresql/global.sql`
- Create: `scripts/agent/sql/postgresql/perdb.sql`
- Create: `scripts/agent/sql/gaussdb/global.sql`
- Create: `scripts/agent/sql/gaussdb/perdb.sql`
- Create: `scripts/agent/sql/opengauss/global.sql`
- Create: `scripts/agent/sql/opengauss/perdb.sql`
- Create: `scripts/test-agent-database-bootstrap.sh`
- Delete/Modify: listed `dbdog-agent/dbdog-deploy` SQL and owning runbooks.

**Interfaces:**
- Produces: `agent_list_databases <index>` — 一行一个原始数据库名，NUL-safe internal transport。
- Produces: `agent_bootstrap_global <index>` — cluster-wide role/grants, exactly once per physical instance。
- Produces: `agent_bootstrap_database <index> <db>` — per-database views/functions/grants。
- Produces: `agent_verify_database_access <index> <db>` — monitor role can query every installed object。

- [ ] **Step 1: 从 `dbdog-agent` 当前 `origin/main` 复制语义，写 fixture digest 和 SQL 行为测试**

测试不要只比较文件文本；fake client 记录调用，断言 global SQL 每实例一次、per-db SQL 对每个可连接非模板库一次，并覆盖带空格/引号的数据库名。

- [ ] **Step 2: 运行测试并确认 release 尚无三引擎 SQL source**

Run: `bash scripts/test-agent-database-bootstrap.sh`

Expected: FAIL。

- [ ] **Step 3: 实现严格数据库枚举**

三种 adapter 的基础查询均以这条语义为准：

```sql
SELECT datname
FROM pg_database
WHERE datallowconn AND NOT datistemplate
ORDER BY datname;
```

引擎特有系统库排除只能在对应 adapter 明文登记并写测试；不得用 shell word splitting 传数据库名。

- [ ] **Step 4: 迁移并审查 global/per-db SQL**

每个对象使用幂等创建/替换；monitor role 名由 adapter 明确给出。保留 PostgreSQL 官方 DBM 需要的 schema、函数、视图和权限，保留已确认语义等价的 GaussDB/openGauss 字段，不趁迁移重做字段设计。

- [ ] **Step 5: 先提交 release 新 source，再删除 Agent 重复 source**

Agent runbook 只保留 release 安装入口和版本对应关系。两个仓的提交消息分别说明 ownership move，保证任一中间提交不会让正式 release 丢 SQL。

- [ ] **Step 6: 运行 SQL 调度和 Agent 仓引用扫描**

Run: `bash scripts/test-agent-database-bootstrap.sh`

Run in `dbdog-agent`: `rg 'init-(datadog|dbdog)-user-(opengauss|postgres|gaussdb|pg)' dbdog-deploy`

Expected: 测试 PASS；扫描只剩迁移说明或为零，不存在死链接。

- [ ] **Step 7: 提交**

```bash
git add scripts/agent/database.sh scripts/agent/sql scripts/test-agent-database-bootstrap.sh
git commit -m "feat(agent-install): bootstrap dbm for every logical database"
```

## Task 4: 渲染多实例配置并保留未知用户配置

**Files:**
- Create: `scripts/agent/render.sh`
- Create: `scripts/agent/managed-files.sh`
- Create: `scripts/agent/merge-yaml.py`
- Create: `scripts/test-agent-managed-files.sh`

**Managed paths:**
- `/etc/dbdog-agent/conf.d/postgres.d/dbdog.yaml`
- `/etc/dbdog-agent/conf.d/gaussdb.d/dbdog.yaml`
- `/etc/dbdog-agent/conf.d/system_probe.d/dbdog.yaml`
- `/etc/dbdog-agent/credentials/<instance-id>.env`
- `/etc/dbdog-agent/instances/<instance-id>.state`
- `/etc/dbdog-agent/.dbdog-managed-files.tsv`

- [ ] **Step 1: 写失败测试，先放入未知顶层键、未知 integration 文件和用户注释**

断言升级后：未知文件不变；`datadog.yaml` 未声明键不变；已登记旧 instance 文件在取消选择后删除；未登记同名相邻文件不删除；所有 secret/state 权限正确。

- [ ] **Step 2: 运行测试并确认旧安装器覆盖整个配置目录**

Run: `bash scripts/test-agent-managed-files.sh`

Expected: FAIL。

- [ ] **Step 3: 实现结构化 YAML merge**

使用 Agent embedded Python 的 PyYAML；merge API 接收 `--owned-path tags --owned-path hostname --owned-path apm_config.enabled ...`。若目标 YAML 无法解析或出现重复键，安装在 mutation 前失败并指出文件，不备份后硬覆盖。

- [ ] **Step 4: 每个 engine 只生成一个 `dbdog.yaml`，其中包含全部已选实例**

每个 instance 至少写入 `host/port/username/password/service/dbm/database_autodiscovery`，其中 service 严格为 `hostname:port`。GaussDB 和 openGauss 都使用 gaussdb integration，但以 tags 明确 `db.engine` 和发行版，不能生成重复物理实例。

- [ ] **Step 5: 实现托管 manifest 和 atomic staging**

manifest 每行记录 `relative_path<TAB>sha256<TAB>mode<TAB>owner:group`。先在 root-owned 临时目录完成渲染、YAML parse、权限检查，再逐文件 `rename(2)` 切换；只删除上一版 manifest 登记而本版不再登记的路径。

- [ ] **Step 6: 运行测试**

Run: `bash scripts/test-agent-managed-files.sh`

Expected: PASS，包括二次执行 byte-stable。

- [ ] **Step 7: 提交**

```bash
git add scripts/agent/render.sh scripts/agent/managed-files.sh scripts/agent/merge-yaml.py scripts/test-agent-managed-files.sh
git commit -m "feat(agent-install): render managed multi-instance configuration"
```

## Task 5: 将安装器改成有阶段边界的事务编排

**Files:**
- Modify: `scripts/agent-install.sh`
- Modify: `scripts/agent-lib.sh`
- Modify: `scripts/test-agent-install-contracts.sh`

**Stages:** `preflight → discover → select → database-plan → database-apply → config-stage → agent-install → config-activate → verify`。

- [ ] **Step 1: 扩展合同测试覆盖三种引擎、多实例、无 TTY 和中途失败**

至少注入这些故障：第二个实例连接失败、第三个逻辑库 SQL 失败、YAML parse 失败、Agent unit 启动失败、Agent check 失败。断言 mutation 前失败不落文件；配置激活后失败恢复旧配置和旧 unit 状态。

- [ ] **Step 2: 运行测试并确认旧线性脚本不能回滚**

Run: `bash scripts/test-agent-install-contracts.sh`

Expected: FAIL。

- [ ] **Step 3: preflight 所有已选实例后再做第一次 mutation**

预检内容：owner、数据目录、客户端、socket/TCP、管理员权限、逻辑库列表、SQL 文件、磁盘、Agent artifact、systemd、端口唯一显示。任何一项失败都打印 instance ID 和修复建议。

- [ ] **Step 4: 明确数据库对象与主机文件的不同回滚语义**

数据库 SQL 必须可重入，成功创建的监控角色/视图不自动删除；主机文件和 unit 有快照并回滚。失败摘要列出 `database_applied`、`host_rolled_back`，避免用户误以为数据库对象被删除。

- [ ] **Step 5: 激活后按实际 engine 执行 Agent check**

存在 PostgreSQL 时运行 `agent check postgres`；存在 GaussDB/openGauss 时运行 `agent check gaussdb`；再验证 system-probe/host check。每个实例必须在 check 输出中匹配 service `hostname:port`。

- [ ] **Step 6: 打印最终实例矩阵，不输出 secret**

每行输出 `engine version instance-id service logical-db-count lifecycle dbm-status`；本阶段 profiling 一律显示 `not-configured`。

- [ ] **Step 7: 运行安装器合同全集**

Run: `bash scripts/test-agent-instance-discovery.sh && bash scripts/test-agent-engine-adapters.sh && bash scripts/test-agent-database-bootstrap.sh && bash scripts/test-agent-managed-files.sh && bash scripts/test-agent-install-contracts.sh`

Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add scripts/agent-install.sh scripts/agent-lib.sh scripts/test-agent-install-contracts.sh
git commit -m "feat(agent-install): orchestrate transactional dbm setup"
```

## Task 6: 补齐诊断、升级和重复执行合同

**Files:**
- Modify: `scripts/collect-diagnostics.sh`
- Modify: `scripts/dbdogctl`
- Modify: `scripts/test-release-contracts.sh`
- Create: `scripts/test-agent-upgrade-idempotency.sh`

- [ ] **Step 1: 写失败测试覆盖二次安装、实例增删和 Agent 升级**

第二次运行相同输入必须无配置 diff、无数据库 restart、SQL 可重入；新增实例只新增对应 state/config；取消实例只删除 dbdog-owned 文件，不删除数据库角色/视图。

- [ ] **Step 2: 让 diagnostics 读取 managed manifest 和 instance state**

输出中对密码、API key、连接 URI userinfo 做 redaction；记录发现事实与已配置事实的差异，但不自动修复。

- [ ] **Step 3: 给 `dbdogctl status` 增加 database-host 矩阵**

状态只读，不 source env 文件，不连接时更改数据库。至少区分 `configured`、`agent-check-failed`、`instance-not-running`、`unsupported-version`。

- [ ] **Step 4: 运行回归**

Run: `bash scripts/test-agent-upgrade-idempotency.sh && bash scripts/test-release-contracts.sh && bash scripts/test-diagnostics-contracts.sh`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add scripts/collect-diagnostics.sh scripts/dbdogctl scripts/test-agent-upgrade-idempotency.sh scripts/test-release-contracts.sh
git commit -m "feat(agent-install): report database host deployment state"
```

## Task 7: 在三个仓刷新权威文档和研发契约

**Files:**
- Modify: `dbdog-release/docs/design/database-host-deployment.md`
- Modify: `dbdog-release/docs/ops/RUNBOOK.md`
- Modify: `dbdog-web/docs/design/dbm/gaussdb-collection.md`
- Modify: `dbdog-web/docs/design/dbm/gaussdb-pg-opengauss-field-parity.md`
- Modify/Regenerate: `dbdog-web/docs/devspec/agent-config-data.js` and generated artifacts.
- Modify: `dbdog-agent/dbdog-deploy` owning runbooks.

- [ ] **Step 1: 用最终脚本 `--help` 和测试矩阵更新 release runbook**

写清交互输入、自动化环境变量、管理边界、逻辑库范围、RC1 版本口径、无数据库 restart，以及失败后的 database/host 不同回滚语义。

- [ ] **Step 2: 更新 Agent 仓责任边界**

Agent 仓继续拥有采集代码和 runtime 行为；release 仓拥有安装 SQL 与部署编排。删除任何暗示用户应直接运行已迁移 SQL 的命令。

- [ ] **Step 3: 按 `dbdog-web/docs/devspec/README.md` 刷新契约**

契约必须展示 PostgreSQL 与 GaussDB/openGauss 的真实生成键、`database_autodiscovery`、service 规则和 managed paths。不要手写 HTML 或跳过生成器。

- [ ] **Step 4: 运行三个仓各自文档/契约检查**

Run in `dbdog-web`: 由 `docs/devspec/README.md` 指定的 refresh/check 命令。

Run in `dbdog-agent`: 与所改 runbook/部署资产相关的现有测试。

Run in `dbdog-release`: `bash scripts/test-release-contracts.sh`。

- [ ] **Step 5: 分仓提交**

```bash
git commit -m "docs(agent-install): document multi-instance dbm deployment"
```

## Task 8: RC1 和 PostgreSQL 真机验收

**Files:**
- Create: `docs/testing/database-host-acceptance.md`
- Modify: `docs/design/database-host-deployment.md` — 只记录稳定结论，原始日志放测试证据位置。

**Required fixtures:**
- 一台同时运行两个 PostgreSQL 实例的主机。
- 一台 GaussDB 单节点主机；有 CM 也按当前主节点处理。
- 一台 openGauss `7.0.0-RC1` 单节点主机。
- 每个实例至少两个非模板业务库，其中一个名称含空格或非 ASCII 字符。

- [ ] **Step 1: 在隔离快照/可恢复环境执行 dry-run 和交互选择**

保存发现矩阵、选择矩阵和将被管理的文件列表；确认未出现远端节点/stream 推断。

- [ ] **Step 2: 执行安装并验证所有逻辑库**

逐库以 monitor role 查询所需对象；分别运行 `agent check postgres`/`agent check gaussdb`，并在 dbdog-server 验证每个 `hostname:port` service 有 DBM 数据。

- [ ] **Step 3: 验证不影响数据库生命周期和现有采集**

记录安装前后数据库 PID/start time、Agent host metrics、logs、traces 和已有 checks；数据库 PID/start time 必须不变，已有采集不得消失。

- [ ] **Step 4: 原输入重复安装，再增删一个实例配置**

第一次重复运行必须无 diff；取消实例后其 Agent config 消失但数据库仍运行、业务对象未删除；重新加入后无需人工清理即可恢复采集。

- [ ] **Step 5: 运行 release 全量测试并审查工作树**

Run: `for t in scripts/test-*.sh; do bash "$t"; done`

Run: `git diff --check && git status --short`

Expected: 全部 PASS；只包含本计划声明的变更。

- [ ] **Step 6: 提交验收证据**

```bash
git add docs/testing/database-host-acceptance.md docs/design/database-host-deployment.md
git commit -m "test(agent-install): record database host acceptance"
```

## Completion Gate

- PostgreSQL、GaussDB、openGauss RC1 的真实运行实例均能被发现和明确选择。
- 同一主机多实例不会重复安装 Agent，也不会因端口相同/变化误认物理身份。
- 所有非模板可连接数据库都已初始化并由 Agent autodiscovery 采集。
- 安装过程不重启数据库、不推断 cluster/stream、不覆盖未知 Agent 配置。
- 二次运行幂等；主机文件失败可回滚；数据库对象回滚边界在输出和文档中明确。
- 三仓责任边界、研发契约和真实生成配置一致。
