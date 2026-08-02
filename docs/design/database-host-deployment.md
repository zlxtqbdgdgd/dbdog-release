# 数据库主机一键部署与原生 Continuous Profiling

状态：current
负责人：dbdog-release
最后确认：2026-08-01

## 1. 目标

管理员在一台正在运行数据库的 Linux 主机上执行一次：

```bash
sudo ./scripts/upgrade.sh dbdog-agent
```

安装器自动发现本机 PostgreSQL、GaussDB 和 openGauss 实例，允许选择一个或多个实例，并完成：

1. 安装或升级一个主机级 dbdog Agent；
2. 为每个选中实例配置主机指标、进程、日志和 DBM；
3. 为实例内全部业务数据库准备监控账号、权限和所需对象；
4. 按用户选择准备原生 Continuous Profiling；
5. 在不影响未选实例和非 dbdog 配置的前提下验收或回滚。

第一版面向当前主机上的单节点实例。安装器不推断集群拓扑；即使发现 CM，也把用户选中的运行实例视为当前主节点。用户可以在同一主机上选择多个彼此独立的物理实例。

## 2. 非目标

- 不自动识别集中式、分布式、流式复制或未来的主备拓扑。
- 不跟随主备切换把 profiling 自动迁移到另一台主机。
- 不使用 CM 自定义 DN 资源接管普通数据库实例。
- 不替换、改名或伪装 `$GAUSSHOME/bin/gaussdb`。
- 不通过 `/etc/ld.so.preload` 或给整个 `cm_agent` 注入 ddprof。
- 不编译 ddprof；使用固定版本、固定校验和的官方预编译产物。
- 不把 `ddprof -p <PID>` 的 CPU attach 当作已部署的 Continuous Profiling。
- 不在安装器中修改数据库产品的认证、密码策略或不相关配置来绕过前置检查。

## 3. 当前实现与需要修正的问题

现有 `scripts/agent-install.sh` 已经具备 GaussDB 主进程、`postmaster.pid`、端口、运行用户、客户端环境和日志的事实探测，以及 Agent 四个 systemd 单元、数据库对象准备、真实 check 验收和失败回滚。

它仍有以下边界：

- 只接受 AArch64 Agent 产物；
- 只识别 GaussDB，不识别 PostgreSQL 和 openGauss；
- 自动选择全部已发现实例，不能让用户确认目标；
- 多进程会被直接判成 `distributed`，不能区分多个独立单节点实例；
- 所有实例共用一个数据库名和环境文件；
- 只在一个逻辑数据库执行兼容对象 SQL，未启用 `database_autodiscovery`；
- 配置切换会替换整个 `/etc/dbdog-agent`，可能删除用户自有 check；
- 没有 ddprof 产物、profiling 状态和数据库生命周期适配。

本设计保留现有的事实验证、真实连接、原子切换和回滚能力，把引擎发现、DBM 准备、Agent 安装和 profiling 生命周期拆成独立模块。

## 4. 用户交互

### 4.1 主机级输入

安装器只在已有配置无法复用时询问：

- `dbdog-server` 地址；
- Agent ingest API key，隐藏输入；
- 部署环境名，默认 `prod`。

监控账号密码由安装器首次生成并以 root-only 配置保存；升级时复用。正常安装不要求用户输入数据库端口、数据目录、二进制路径或数据库 OS 用户。

### 4.2 实例发现与选择

安装器扫描运行中的 `postgres` 和 `gaussdb` 主进程。候选实例必须同时通过：

- `/proc/<pid>/exe` 指向预期数据库二进制；
- 命令行、运行环境或工作目录能得到数据目录；
- 数据目录中的 `postmaster.pid` 第一行等于该 PID；
- 能得到有效端口、运行用户和客户端程序。

安装器打印编号表，至少包含：

```text
编号  引擎       PID    端口   OS用户  数据目录                  二进制
1     gaussdb    1234   37000  Ruby    /data/gauss/dn_6002      /data/.../gaussdb
2     postgresql 2234   5432   postgres /var/lib/pgsql/16/data   /usr/pgsql-16/bin/postgres
```

用户可选择一个、多个或全部实例。未选实例只读探测，不改配置、不建账号、不重启。

### 4.3 数据库环境文件

每个选中实例询问一次“是否有该实例专用的环境变量文件”。

- 选择“否”：使用 `/proc/<pid>/environ`、`/proc/<pid>/exe`、命令行、数据目录和 socket 等运行态事实。
- 选择“是”：要求输入绝对路径；在数据库 OS 用户、空环境和硬超时下加载，只取 `GAUSSHOME`、`GAUSSLOG`、`PGDATA`、`PGHOST`、`PGPORT`、`PATH`、`LD_LIBRARY_PATH` 白名单。

环境文件不能以 root 权限直接 source，任意额外变量和命令输出不能进入安装器状态。

### 4.4 功能选择

每个实例默认配置 DBM。用户只需决定：

```text
为该实例启用 Continuous Profiling？[y/N]
```

选择“是”表示使用 wrapper 同时采集 CPU、allocation 和 live heap。安装器完成全部前置检查后再询问：

```text
wrapper 已准备，需要重启该数据库实例才能生效。现在重启？[y/N]
```

选择“不重启”时，Agent 和 DBM 正常交付，profiling 状态记为 `prepared_not_active`，不得显示“profiling 已启用”。

CPU attach 只作为临时诊断命令存在，不出现在正式安装模式中。

## 5. 实例与配置模型

### 5.1 一个主机一个 Agent

同一 OS 主机只运行一套 dbdog Agent 四单元。每个物理数据库实例生成独立的 integration instance 配置；相同 integration 的多个实例可放在同一个由安装器管理的配置文件中。

物理实例的稳定身份由以下事实生成：

```text
engine + canonical executable + canonical data directory
```

对外的 DBM/profiling 实例键统一为：

```text
<agent_hostname>:<database_port>
```

稳定身份用于本机配置和回滚，对外实例键用于关联 DBM 与 profile。

### 5.2 多个逻辑数据库

每个选中物理实例默认监控全部非模板、允许连接的业务数据库：

- PostgreSQL 使用 `postgres` integration 的 `database_autodiscovery`；
- GaussDB 和 openGauss 使用 `gaussdb` integration 的同等能力；
- 模板库和产品内置排除库保持 integration 默认排除规则；
- 高级自动化可以通过显式 include/exclude 覆盖，但交互安装不逐库提问。

角色在实例范围创建一次；扩展、schema、函数、兼容视图和逐库授权在每个被监控逻辑数据库中幂等执行。任一数据库准备失败时，安装结果必须指出实例和数据库名，不能把其他数据库成功误报成整实例成功。

### 5.3 引擎适配

安装器内部使用统一实例事实模型，不把 PostgreSQL、GaussDB 和 openGauss 的 SQL、客户端命令与生命周期判断混在主流程中：

| 适配器 | 连接与 DBM | 数据库对象 | profiling 生命周期 |
|---|---|---|---|
| PostgreSQL | `psql` + `postgres.d` | 按 PostgreSQL 官方 DBM 语义 | systemd 服务 drop-in 或已验证的等价启动器 |
| GaussDB | `gsql` + `gaussdb.d` | GaussDB 兼容账号和视图 | CM launcher hook；无 CM 时使用 `gs_ctl` supervisor |
| openGauss | `gsql` + `gaussdb.d`，服务标识为 `opengauss` | 基于 RC1 对齐后的兼容对象 | CM launcher hook；无 CM 时使用 `gs_ctl` supervisor |

第一版不根据进程数量设置 `centralized/distributed`；服务与引擎标签来自适配器，节点角色固定标记为本次选中的当前主节点。

## 6. 配置所有权

安装器维护一份 managed-files 清单，只替换自己拥有的文件：

- `datadog.yaml` 中的 dbdog 管理字段；
- dbdog 创建的 system-probe 配置；
- dbdog 管理的主机、进程和数据库 integration 配置；
- dbdog 四个私有 systemd unit；
- profiling 实例配置和生命周期适配文件。

未知的 `conf.d` 目录、用户新增文件和非 dbdog systemd unit 必须保留。升级时旧版已知的 dbdog 文件可以迁移到 managed-files 清单；无法确认所有权的文件不删除。

Agent runtime/config 切换仍使用 staging、旧目录备份、服务状态快照和验收后提交 marker。profiling 失败不能回滚已经健康的 Agent/DBM。

## 7. ddprof 发布合同

### 7.1 产物

ddprof 作为 `dbhost` 目标的第三方模块进入 release manifest 和统一 artifacts release：

- 固定版本，不使用 `latest`；
- 分别发布 `x86_64` 和 `aarch64` 官方二进制；
- 发布前校验上游 SHA-256；
- 目标机再次校验 release manifest SHA-256、ELF 架构、动态依赖和 `ddprof --version`；
- dbdog 不重新编译或修改 ddprof。

manifest 在现有八列后追加第九列 `arch`，旧列位置保持不变。取值只允许规范化后的 `x86_64`、`aarch64` 或 `noarch`；逻辑主键从 `module` 改为 `(module, arch)`。目标机先按本机架构精确选择，只有模块声明为 `noarch` 时才允许回退。旧 manifest 没有第九列时，只能从产物名的 `-x86_64.tar.gz`、`-aarch64.tar.gz` 或 `-noarch.tar.gz` 后缀确定性迁移；后缀缺失或冲突必须失败，不能把未知架构当成 `noarch` 或本机架构。

Agent 同一版本的多架构产物必须来自同一组 Agent/Agent Core 源码锚，并作为一次模块发布原子更新，不能出现两个架构版本漂移。发布校验还必须拒绝重复 `(module, arch)`、同模块多版本和缺失目标架构的部分发布。

### 7.2 通用 profile 参数

每个实例使用：

- `--preset cpu_live_heap`；
- 本机 dbdog Agent trace 接收端口；
- `service` 为 `postgres`、`gaussdb` 或 `opengauss`；
- `env` 与 DBM 一致；
- `version` 为目标数据库真实版本；
- `instance:<port>`；
- `database_instance:<agent_hostname>:<port>`；
- 引擎专属 build 标识。

上传周期显式固定，不依赖 ddprof 新版本的默认值。

### 7.3 符号

启用 wrapper 前检查实际运行 ELF：

- 内嵌 `.symtab` 可直接使用；
- 外置符号必须与运行 ELF 的 build-id 和校验和精确匹配；
- 当前 ddprof 若不读取 detached debuglink，则生成匹配的合并 ELF，并以只读 bind mount 暴露在原二进制路径；
- 不允许拿“同版本”但 build-id 不同的符号凑数。

GaussDB 常见 release 二进制若已带 `.symtab`，只做只读验证。openGauss RC1 的受控构建使用 release 优化并保留符号表，不改数据库运行语义。PostgreSQL 发行包若被 strip，必须取得匹配 debuginfo 后再激活 profiling。

缺少匹配符号时，安装器在重启前停止 profiling 激活并给出修复信息；不能把只有地址或 mapping 名的 flame graph 验收为成功。

## 8. wrapper 与生命周期

### 8.1 总原则

Continuous Profiling 必须在数据库进程启动前注入。`ddprof -p <PID>` 只能对现有目标做 CPU 采样，不能得到完整 allocation/live-heap，因此不属于部署成功形态。

每个实例只能有一个故障恢复决策者。wrapper 负责启动注入，不再建立一套与原生命周期管理器竞争的数据库自动重启策略。

### 8.2 PostgreSQL

由 systemd 直接管理 `postgres` 时，安装 drop-in，把原 `ExecStart` 的数据库命令和参数原样放到 ddprof 后面。停止、重启、超时、资源限制和运行用户保持原 unit 语义。

不是 systemd 管理的 PostgreSQL 只有在存在已验证、可恢复的生命周期适配器时才能激活 wrapper；未知启动器在重启前失败关闭。

### 8.3 无 CM 的 GaussDB/openGauss

`gs_ctl start` 拉起数据库后会退出，不能直接作为 ddprof 的长期目标。无 CM 场景使用已验证的常驻 supervisor：

```text
systemd
  -> ddprof
    -> dbdog gaussdb supervisor
      -> gs_ctl start
        -> gaussdb
```

supervisor 通过 `postmaster.pid` 和 `/proc/<pid>/exe` 确认实例，停止时调用原 `gs_ctl stop`。它只管理所选数据目录，不扫描或停止同机其他实例。

### 8.4 CM 管理的 GaussDB/openGauss

确认的目标链路是：

```text
cm_agent
  -> dbdog-gaussdb-launcher
    -> ddprof --preset cpu_live_heap
      -> gaussdb
```

职责边界：

- CM 仍是唯一的启动、停止、角色变化和故障恢复决策者；
- launcher 是 launch-only wrapper，负责选择实例配置、校验参数并执行 ddprof；
- ddprof 建立 profiler worker 后执行真实 `gaussdb`；
- CM 的 PID、状态文件和数据库连接检查继续观察真实 `gaussdb`；
- launcher 不运行第二套数据库重启循环。

CM 必须提供版本化 launcher contract：

1. 配置项只接受 launcher 的绝对路径，不接受 shell 字符串；
2. CM 调用形式为 `launcher --binary <real-gaussdb> -- <original-argv...>`；
3. launcher 根据规范化 `-D` 数据目录找到本机实例配置，未启用 profiling 时直接执行真实二进制；
4. 自动拉起、手工 start、故障恢复和角色变化后的 restart 全部进入同一个启动函数；
5. 原先直接执行 `gaussdb` 或 `gs_ctl restart` 的路径不能绕过 launcher；停止仍可使用厂商原有 stop 语义；
6. launcher 配置支持 CM reload，准备阶段不要求重启整套 CM；
7. CM 暴露只读 contract version，安装器在任何修改前验证兼容版本。

launcher 不使用 `eval`，不重新解析为 shell 命令；它校验绝对二进制、数据目录、实例身份和参数边界后以数组形式执行。每实例 profiling 配置由数据库 OS 用户只读，不含 API key 或数据库密码。

目标机 CM 不具备该 contract 时，Agent 和 DBM 仍可安装，但 profiling 必须报告 `unsupported_lifecycle`，不得自动改用 CM 自定义资源、替换数据库二进制或静默降级为 CPU attach。

ddprof worker 在数据库运行期间退出时，CM 不应因此重启健康数据库。Agent 报告 profiling 断流；恢复 heap profiling 需要操作者确认下一次数据库重启。

## 9. 安装事务与回滚

安装分为两个独立事务。

### 9.1 Agent/DBM 事务

1. 下载并验证 Agent 产物；
2. 只读发现实例并完成全部连接、认证和 SQL 前置检查；
3. 在 staging 中生成 managed 配置；
4. 准备所有选中逻辑数据库的账号、权限和对象；
5. 原子切换 runtime、managed 配置和四个 unit；
6. 验收四单元、真实 engine check、日志和 DBM；
7. 写提交 marker。

失败时恢复旧 runtime、managed 配置、unit enable/active 状态和凭证。数据库对象采用幂等定义，回滚不删除可能已被其他采集使用的监控角色。

### 9.2 Profiling 事务

1. 校验 ddprof、Agent trace 端口、目标 ELF 和符号；
2. 识别并验证生命周期适配器或 CM launcher contract；
3. 快照原启动配置、CM 参数、unit、数据库 PID、监听和健康状态；
4. 安装 launcher/supervisor/drop-in 和每实例配置，但不立即重启；
5. 用户确认后只重启当前实例；
6. 验收数据库、原生命周期管理面和连续 profile；
7. 成功后记录 `active` 状态。

启动、数据库健康或 profile 验收失败时，恢复原启动配置并用原生命周期方式恢复数据库。Agent/DBM 保持运行。回滚必须重新验证端口、`SELECT 1`、原管理面和未选实例 PID。

## 10. 状态与输出

安装结束逐实例输出：

| 状态 | 含义 |
|---|---|
| `dbm_active` | Agent 真实 check 和数据库准备均通过 |
| `profiling_disabled` | 用户未选择 profiling |
| `prepared_not_active` | wrapper 已准备，用户未批准重启 |
| `profiling_active` | wrapper 生效并通过完整验收 |
| `unsupported_lifecycle` | 原生命周期没有兼容 launcher contract，未改数据库 |
| `profiling_rolled_back` | 激活失败，数据库已恢复原生命周期 |

失败信息必须包含主机实例键、数据目录和失败阶段，不输出 API key、数据库密码或环境文件内容。

## 11. 验收标准

### 11.1 Agent 与 DBM

- 四个 dbdog 私有 unit active/enabled，且稳定窗内没有退出或重启；
- 每个选中实例的 integration check 成功；
- 每个被监控逻辑数据库能建立连接并读取所需对象；
- schema、settings、activity、query metrics、query samples、日志和主机采集按配置产生；
- 未选实例、官方 Datadog Agent 和用户自有 check 的进程、文件与状态不变。

### 11.2 Profiling

- 数据库端口、`SELECT 1` 和原生命周期管理面正常；
- 连续至少三个显式上传周期有 `sample.count`，无 exporter error；
- `unwind.errors=0`；
- 事件同时包含 `cpu-time/cpu-samples`、`alloc-size/alloc-samples`、`heap-live-size/heap-live-samples`；
- CPU、allocation 和 live-heap 三种 flame graph 都能解析数据库函数名；
- 记录 profiler CPU/RSS，不能复用其他机器的开销结论。

CM 场景还必须验证：CM 查询正常；停止并重新启动测试实例后，启动再次经过 launcher，新的 profile 仍含六轴；其他 CM 管理实例不受影响。

## 12. 测试矩阵

实现至少覆盖：

- AArch64 与 x86_64 artifact 选择、ELF 和 checksum 拒绝用例；
- PostgreSQL、GaussDB、openGauss 的主进程正反例与多实例选择；
- 有/无专用环境文件、环境文件超时和白名单；
- 多物理实例、同端口冲突、多逻辑数据库和排除规则；
- 旧版 dbdog 配置迁移与未知用户配置保留；
- Agent/DBM 各失败点的原子回滚；
- PostgreSQL systemd、无 CM `gs_ctl` supervisor 和 CM launcher contract；
- CM 自动启动、restart 绕过防护、launcher passthrough 和 contract 版本不匹配；
- 用户拒绝重启、wrapper 激活失败、符号不匹配和 profile 断流；
- 目标数据库重启后 Agent、DBM、日志、进程和系统采集继续正常。

真实环境验收至少包含一个 PostgreSQL、一个无 CM 的 openGauss RC1、一个带兼容 launcher contract 的 CM 管理 GaussDB/openGauss。只有 contract 测试通过不能替代目标机实测。

## 13. 实施拆分与交付顺序

这一设计拆成三个连续的实施计划，避免把发布格式、数据库接入和数据库生命周期放在一次不可独立验收的改动中：

1. **多架构发布基础**：扩展 manifest、发布流程和目标机架构选择；把当前 Agent 与 Agent Core 主线重新构建为匹配产物，并接入官方 ddprof 二进制。
2. **数据库主机与 DBM**：拆分安装器，实现统一发现、选择、环境、managed-files、三个引擎适配器和逐库准备；这一阶段不修改数据库启动方式即可独立交付。
3. **原生 profiling 生命周期**：先在 CM/openGauss 源码中定义并实现 launcher contract，使所有 DN 启动入口统一，再接入 PostgreSQL、无 CM 和 CM 三类 lifecycle adapter 与 profiling 事务。

三个计划分别通过 contract 和故障注入后，再进行跨计划真实主机验收，最后作为正式 dbdog-release 版本发布。第二个计划不依赖第三个计划，用户即使暂不重启或目标 CM 暂不兼容，也能先得到完整 Agent/DBM 能力。

CM/openGauss 的实现和测试属于其源码仓；dbdog-release 只拥有产物选择、目标机编排、launcher 客户端合同、状态和回滚。跨仓行为变化按家族规范同步刷新 dbdog-web 的研发契约与 profiling 责任文档。
