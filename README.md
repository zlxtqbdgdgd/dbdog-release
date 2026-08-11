# dbdog-release

dbdog 的二进制发布仓：公网构建产物经此分发到只读 GitHub 的内网环境。
仓库本体只有 manifest、脚本和 skill；二进制都在唯一的产物桶
（GitHub Release [`artifacts`](../../releases/tag/artifacts)）里，文件名自带版本。
设计动机见 [docs/adr/0001](docs/adr/0001-single-bucket-release-via-main.md)，术语见 [CONTEXT.md](CONTEXT.md)。

## 最新版本

<!-- VERSION-TABLE:BEGIN -->
更新于 2026-08-11 00:28（此表由 publish.sh 生成，权威数据在 manifest.tsv）

| 模块 | 类别 | 装在 | 版本 | 产物 | 架构 |
| --- | --- | --- | --- | --- | --- |
| dbdog-server | first-party | 全家桶机 | 0.1.17 | dbdog-server-0.1.17-aarch64.tar.gz | aarch64 |
| dbdog-web | first-party | 全家桶机 | 0.1.19 | dbdog-web-0.1.19-aarch64.tar.gz | aarch64 |
| dbdog-mcp | first-party | 全家桶机 | 0.1.13 | dbdog-mcp-0.1.13-noarch.tar.gz | noarch |
| dbdog-agent | first-party | DB 主机 | 7.81.0-dbdog.9 | dbdog-agent-7.81.0-dbdog.9-aarch64.tar.gz | aarch64 |
| postgresql | third-party | 全家桶机 | 16.14-dbdog.1 | postgresql-16.14-dbdog.1-aarch64.tar.gz | aarch64 |
| clickhouse | third-party | 全家桶机 | 26.8.1.184 | clickhouse-26.8.1.184-aarch64.tar.gz | aarch64 |
| node | third-party | 全家桶机 | 20.18.1 | node-20.18.1-aarch64.tar.gz | aarch64 |
| goose | third-party | 全家桶机 | 3.27.3 | goose-3.27.3-aarch64.tar.gz | aarch64 |
<!-- VERSION-TABLE:END -->

## 当前可用范围

- **全家桶机**：已在麒麟 V10 / 鲲鹏 920 完成首次基础部署验收，PostgreSQL、ClickHouse
  与四个应用服务均可启动；DDSQL 查询、鉴权和 agent 业务链路仍需继续验证。
- **GaussDB 主机 agent**：aarch64 运行时与正常首装/升级流程均已交付；安装器会完成
  目标机发现、监控账号/兼容视图、全量默认功能配置、四个 systemd 服务、真实 GaussDB check
  和失败回滚。首次进入内网目标机仍应先做一轮麒麟 V10 实机验收，再推广到其他数据库主机。

## 内网首次安装：全家桶机

前提：麒麟 V10 / aarch64、专用 `dbdog` 账户、出网 HTTPS 可达 `github.com` 和
`release-assets.githubusercontent.com`。当前 stack 压缩产物合计约 305 MiB，此外还需
模块解包及 PG/CH 数据空间；先用 `df -h "$HOME"` 确认实际余量。ClickHouse 首次探测会
从约 154 MiB 自解压为约 708 MiB，模块目录应至少额外留出 1 GiB。

### 出网代理与 TLS

curl 与 Git 会原生读取 `https_proxy`/`HTTPS_PROXY`、`all_proxy`/`ALL_PROXY` 和
`no_proxy`/`NO_PROXY`，下载脚本不需要也不会另拼 `--proxy`。建议统一用小写；大小写同时
存在时 curl 以小写为准。curl 不把大写 `HTTP_PROXY` 当作代理变量，访问本仓的 HTTPS
地址应设置 `https_proxy`（或 `HTTPS_PROXY`）。若设置了代理，务必让本机服务绕过它：

```bash
export https_proxy=http://proxy.internal.example:3128
export no_proxy=127.0.0.1,localhost,::1
```

若代理重签目标站证书，优先取得运维提供的 PEM CA 文件，让 Git clone、后续 pull 和产物
下载继续严格校验证书及主机名。Git 与下载脚本的 CA 配置是两条链路，需要分别设置：

```bash
ca=/path/to/internal-proxy-ca.pem
git -c http.sslCAInfo="$ca" clone \
  https://github.com/zlxtqbdgdgd/dbdog-release ~/dbdog/release
git -C ~/dbdog/release config --local http.sslCAInfo "$ca"
export CURL_CA_BUNDLE="$ca"
```

按上例完成 clone 后，从下一节的 `cd ~/dbdog/release` 继续，跳过重复的 `git clone`。

仅在无法及时取得 CA、且已通过可信渠道确认下载地址时，才可单次使用
`CURL_INSECURE=1 ./scripts/install.sh` 临时排障。只有精确值 `1` 会传给 curl 的
`--insecure`；未设置或设为 `0` 均保持严格 TLS，其他值会直接报错。该模式会关闭证书和
主机名校验，产物 SHA-256 只能发现内容变化，不能证明下载来源，因此不要写入 `.bashrc`
或长期启用；它也不会影响 Git。不要使用 `GIT_SSL_NO_VERIFY` 或
`git config http.sslVerify false`。

当前 PostgreSQL `16.14-dbdog.1` 已内置 `libpq.so.5`、`libreadline.so.8` 等运行库，
并使用相对 RUNPATH 从模块自己的 `lib/` 加载；安装脚本不需要设置 `LD_LIBRARY_PATH`。
不要为 dbdog 把该变量写入 `.bashrc`。若目标机仍留有首次部署时的临时 workaround，
移除后可用 `env -u LD_LIBRARY_PATH ~/dbdog/modules/postgresql/current/bin/psql --version`
验证独立运行。

### 拉取并一键安装

安装会直接使用 PG `5432`、CH `8123/9000`、server `8080`、ddsql `8770`、web
`3000`、MCP `8090`；执行前必须确认这些端口未被占用。脚本完成模块安装、数据库初始化、
配置生成、迁移、管理员创建、服务启动和基础验收后才返回成功。

```bash
uname -m                             # 必须输出 aarch64
mkdir -p ~/dbdog
git clone https://github.com/zlxtqbdgdgd/dbdog-release ~/dbdog/release
cd ~/dbdog/release
./scripts/install.sh
```

默认访问地址根据默认路由的本机 IPv4 自动生成；需要指定 DNS 名或固定 IP 时，可在首次
安装命令前设置 `DBDOG_ADVERTISE_HOST`，例如
`DBDOG_ADVERTISE_HOST=dbdog.internal ./scripts/install.sh`。该值只用于生成访问 URL，服务仍
监听默认端口。反向代理和 HTTPS 可在安装成功后作为可选运维配置，不阻塞默认安装。

安装会生成随机内部 Token/OAuth JWT，并同步写入 server、web、MCP 的 `0600` env 文件；
PG/CH 使用只监听本机的默认连接。已有真实配置不会被覆盖。首次迁移会创建
`admin@dbdog.local` 管理员并把随机密码输出一次；请当场保存并在登录后立即修改。后续
升级不会重置密码。登录后的管理员可在
Settings → 用户管理创建其他用户，因此 Web 不开放匿名注册。

安装末尾自动调用的 `verify.sh` 会检查配置占位值、实际执行 PG/CH 查询，并等待
server、ddsql、web、MCP HTTP 就绪；同时验证 Web OAuth 表、授权服务器元数据、MCP
受保护资源元数据以及 401 `WWW-Authenticate` 挑战。最后出现
`基础部署及 OAuth 自动发现链验收通过` 才可继续业务场景验证。浏览器登录、用户授权和
真实工具调用仍属于业务场景验收。`dbdogctl status all` 只反映进程状态，不等于健康。

Claude Code 使用 Streamable HTTP 正常连接，不需要手工复制内部 Token：

```bash
claude mcp add --transport http --scope user dbdog http://<全家桶主机>:8090/mcp
```

随后在 Claude Code 的 `/mcp` 中选择 `Authenticate`，浏览器会转到 Web `3000` 端口登录并
授权。服务端自动发布 OAuth discovery；不要把固定 Bearer Token 写进 Claude 配置作为默认方案。

旧版本若曾停在“已落包、未迁移”的中间状态，更新 release 仓后可执行一次
`./scripts/install.sh --finish` 恢复；这不是新安装的正常步骤。

失败时先看：

```bash
./scripts/dbdogctl status all
ls -1 ~/dbdog/logs
tail -n 100 ~/dbdog/logs/dbdog-server.log   # 按失败项换成对应日志
./scripts/fingerprint.sh --oneline
```

判断架构以 `file <二进制>` 为准；当前发布物中的 Linux 用户态机器码均为 AArch64。
ClickHouse 26.8.1.184 是官方 `aarch64v80compat` 快照，基线为 ARMv8+CRC，不要求
RCpc/LDAPR，供鲲鹏 920 等缺少 `lrcpc` 的 CPU 使用。安装/升级会先在 staging 中运行
`--version`，成功后才切换 `current`。若仍报 `Illegal instruction`，请保留下面各项原始输出：

```bash
uname -m
grep -m1 '^Features' /proc/cpuinfo
file ~/dbdog/modules/clickhouse/current/bin/clickhouse
~/dbdog/modules/clickhouse/current/bin/clickhouse --version; echo "rc=$?"
tail -n 80 ~/dbdog/logs/clickhouse.err.log
```

本仓公开；反馈问题时不要提交内网 IP、主机名、密钥或原始日志。

## 内网日常升级

```bash
cd ~/dbdog/release
./scripts/check-upgrade.sh --pull   # 0=版本+SHA一致（Agent 另含安装器合约），10=需升级/校准
./scripts/upgrade.sh                # 升级已安装且版本或产物 SHA 不同的模块
./scripts/verify.sh
```

数据库结构升级已经包含在上述正常流程中，不需要另跑迁移命令。`upgrade.sh` 会先按依赖
顺序处理基础运行时，再升级 server、web 和 MCP；server 的 Goose 与 web 的 Drizzle
迁移都在各自模块切换前自动执行，失败即停止升级。迁移文件随模块产物发布并校验完整性。
Web/MCP 升级还会自动补齐缺失或空的本机 OAuth/public URL，迁移已知旧模板地址，重启受
影响的运行中服务，并执行 OAuth 专项验收；已有自定义域名、反代地址和真实凭证不覆盖。
表结构的唯一所有者和跨模块兼容规则见
[数据库结构所有权与发布契约](docs/schema-ownership.md)。

缺失模块不会被无参数升级自动安装；需要显式执行，例如
`./scripts/upgrade.sh dbdog-web`。旧版目录首次会因没有 SHA marker 做一次身份校准；之后即使
版本号相同，只要 manifest SHA 改变也会安装新产物。升级保留有效缓存与旧身份目录，但数据库
迁移只向前；不要把切软链当成完整数据库回滚。破坏性 `./scripts/reset.sh --yes-i-mean-it` 会删掉 PG/CH 全部数据，
只能作为最后手段。

服务管理：`./scripts/dbdogctl start|stop|restart|status [服务|all]`。机器重启后当前仍需
手动执行 `./scripts/dbdogctl start all`。

需要让内网大模型做一次全机巡检或故障取证时，手工执行
`./scripts/collect-diagnostics.sh`（Agent 主机用 `sudo`）。它自动识别全家桶/Agent 角色，
生成 mode `0600` 的内网脱敏报告和无原始日志的 issue-card；同目录游标记录最后成功时间及普通日志
inode/offset，下一次手工运行从该水位增量扫描。大 journal 会按安全时间子窗口逐次排空，轮转/截断
可识别，采集失败不推进游标。本功能不会创建定时任务。
完整的内网模型提示词、覆盖模块、结果语义和外传边界见
[内网大模型诊断采集指引](docs/internal-ai-diagnostics.md)。

## GaussDB 主机 agent

前提：麒麟 V10 / aarch64、GaussDB 正在运行、dbdog-server 已可从该主机直连，并已从
dbdog-web 的 Agent 接入页签发 ingest API key。不要覆盖同机官方
`/opt/datadog-agent`；dbdog 私有运行时、配置和服务分别固定在 `/opt/dbdog-agent`、
`/etc/dbdog-agent` 与 `dbdog-agent*`。

```bash
cd ~/dbdog/release
sudo ./scripts/upgrade.sh dbdog-agent
```

首次运行只会在终端提示两个无法安全猜测的外部值：dbdog-server 地址和 Web 签发的 Agent
API key。GaussDB `dbdog` 监控用户密码由安装器随机生成并写入 root `0600` 配置；升级自动
保留，不需要人工知道或再次输入。输入只发生在这条正常安装命令里，不需要随后手改 YAML 或
systemd。非交互自动化可用 `DBDOG_SERVER_URL`、`DBDOG_API_KEY` 传入；确需接管既有监控
密码时才设置 `DBDOG_GAUSSDB_MONITOR_PASSWORD`。不要把明文写进仓库、shell history 或命令参数。

日常采集使用包内 psycopg/libpq，经 `127.0.0.1` TCP 和密码连接 GaussDB，不使用 Unix socket
`trust` 绕过认证。标准 PostgreSQL libpq 并非只支持 MD5，但 GaussDB 的私有 SHA256/SM3 认证不等同于
PostgreSQL SCRAM；当前经过交付验证、明确支持的兼容合同是本机 TCP + MD5。安装/升级前必须由 DBA
按 GaussDB 规范完成并确认以下前置条件：

```text
SHOW password_encryption_type;          -- 必须返回 1
host all dbdog 127.0.0.1/32 md5         # pg_hba.conf 中必须存在
```

`password_encryption_type=1` 决定新建监控用户时同时保存 SHA256 与 MD5 凭证，HBA 的 `md5` 才决定
这次 TCP 连接采用 MD5 认证；两个配置缺一不可。HBA 使用首条匹配规则且不会回退，`user=all`
同样会匹配 `dbdog`，因此精确 MD5 规则必须放在可能匹配它的宽泛规则之前。安装器不会仅凭文件中
出现过 `trust` 就误判：精确规则之后、不影响该 TCP endpoint 的规则可以存在。已有监控用户会在
变更前验证实际握手；全新用户因服务端可能返回防枚举用的模拟 challenge，则在创建后立即要求
PostgreSQL MD5 AuthenticationRequest code `5`，随后再用随包 libpq 登录。
安装器只读检查这两项，不会修改 `postgresql.conf`、`pg_hba.conf`，也不会替 DBA reload/restart
GaussDB。可在创建前判定的 mode、字面 HBA 和已有账号认证问题会提前失败；新用户的生效认证只能
在创建后验证，失败时 Agent 安装事务会回滚；已创建的监控用户会保留，重跑自动复用同一份凭证。
已有用户在安装变更前、
新用户在创建后，安装器都会读取服务端当前生效的协议认证请求，必须得到 MD5 challenge；因此磁盘
文件已改但尚未 reload、规则顺序被其他认证方式遮蔽等情况也不会误报成功。
安装失败会恢复 Agent runtime、配置和 systemd 单元；已幂等创建或升级的 `dbdog` 监控用户、
权限与兼容对象按数据库迁移的只前进语义保留，重跑正常升级会复用，不做破坏性数据库回滚。

如果旧环境中的 `dbdog` 用户是在 `password_encryption_type=2/3` 下创建的，仅把参数改为 `1` 不会
补出 MD5 凭证。安装器不会擅自替已有数据库账号改密：应由 DBA 在 mode `1` 已生效后按安全流程为
该用户设置一个不同的新密码，并在同次升级中通过安全环境注入
`DBDOG_GAUSSDB_MONITOR_PASSWORD`；或者删除确认可重建的旧监控用户，让安装器重新创建。全新/已重装
且不存在 `dbdog` 用户的环境不需要这一步，安装器会自动生成密码并创建账号。

安装器自动完成以下工作：

- 下载并校验 manifest 产物，确认它确实包含 GaussDB integration、编译后的
  `psycopg_c`/私有 `libpq` 和五个核心二进制；
- 从运行中的 `gaussdb` 进程、`/proc/<pid>/environ`、`postmaster.pid` 与配置发现实际端口、
  Unix socket、`GAUSSHOME`、`PGDATA`、`GAUSSLOG`、`PATH` 与 `LD_LIBRARY_PATH`。只接受
  `PGDATA/postmaster.pid` 第一行能反向确认 PID 的实例主进程，自动忽略同名的 backend、
  fenced UDF 与辅助进程。运行进程环境优先；同时在清空的环境中，以数据库 OS 用户权限和
  硬超时加载 `.profile`、`.bash_profile`、
  `.bashrc`，以及 `MPPDB_ENV_SEPARATE_PATH`、`gauss_env_file`/`gsql_env.sh` 等常见环境文件，
  最终只把 gsql 启动所需的白名单变量交给 root 安装器；
- 用发现出的同一套客户端环境和目标 Unix socket，依次执行 `ldd gsql`、`gsql --version` 和
  本地 `SELECT 1` 预检；这个 socket 只属于安装期管理通道，不会写进日常采集配置；
- 只读核对 `password_encryption_type=1` 及精确的本机 `dbdog` TCP MD5 HBA 规则存在，并以实际
  握手确认该 TCP endpoint 当前生效认证为 MD5；用目标机实际 `$GAUSSHOME/bin/gsql` 做一次性、幂等的安装准备。用户不存在时
  创建随机密码的 `dbdog` MONADMIN，用户已存在时只验证已保存密码而不擅自改密；随后创建
  `dbdog.statements`/`dbdog.activity`/explain 兼容对象；最后以协议握手确认当前生效认证确为 MD5，
  并用包内实际 psycopg/libpq 完成 `127.0.0.1` TCP 登录验证。`gsql` 不参与日常采集；
- 默认开启现网已验证的 GaussDB DBM（query metrics/samples、schema、settings、activity、
  database size）、数据库日志、主机指标、Live Processes/Process Discovery、NPM/USM、
  APM/OpenLineage、Remote Config 与 inventories/metadata；同时把全部 intake/EvP endpoint
  指向本次输入的 dbdog-server，并关闭只会访问 Datadog 公网端点的 Agent/APM telemetry；
- 以 root 安装并启用 Core、Trace、Process、System Probe 四个私有服务；只有 API key
  validate、Remote Config trust root、四服务 active、全部 Agent readiness 组件和真实
  `agent check gaussdb` 全部通过才返回成功，否则恢复上一套 runtime/config/unit。

readiness 使用真实墙钟截止时间而不是固定调用次数，默认等待 90 秒，并把每次尝试的时间、
耗时、退出码和组件列表追加到安装诊断。极慢主机可在 30–600 秒内显式设置
`DBDOG_AGENT_HEALTH_TIMEOUT`；这只延长严格的全组件验收，不会把单次 forwarder 202 当作整机健康。

Agent 包里的 `datadog-gaussdb` 版本（以 `manifest.tsv` 对应 Agent 产物为准）是
**GaussDB integration 自身的版本**，不是被监控 GaussDB 的服务端版本，
两者没有版本绑定关系。
日常采集由该 integration 通过 psycopg `ConnectionPool` 和包内 libpq 完成，服务端版本则在
运行期执行 `SHOW SERVER_VERSION` / `SELECT version()` 识别。安装器不会因为目标 GaussDB
版本字符串（包括 505/507）做猜测式门禁，而是直接验证当前连接是否返回 PostgreSQL MD5
AuthenticationRequest code `5`，再用随包 libpq 实际登录。若看到 SASL 不兼容，说明当前首匹配
认证并非这条已验证的 MD5 合同，而不能据此推断整个 GaussDB 版本不受支持。若新版本真实改变了
协议或系统视图，末尾 check 会 fail closed，此时应
升级 integration，而不是换成 `gsql` 短连接采集或绑定目标机客户端库。Agent 产物也显式
禁止夹带 `gsql`/`gaussdb` 服务端二进制，安装期需要时只使用目标机当前版本自己的 gsql。

后续升级仍是同一条正常命令，不另设 cutover 流程；`upgrade.sh` 直接进入 Agent 自己的原子
安装/升级事务，已落地的 server URL、API key 和数据库密码会自动保留，端口与日志路径会
重新按目标机事实发现：

```bash
cd ~/dbdog/release
git pull --ff-only
sudo ./scripts/upgrade.sh dbdog-agent
```

升级或排障后统一运行 `sudo ./scripts/dbdogctl diagnose dbdog-agent`；它汇总宿主内核/页大小、
安全范围内的采集周期、四服务当前状态与重启增量、近期日志及 Agent status/check。结论中的
`healthy` 表示当前检查，`diagnostic_complete` 表示证据是否采全，
`historical_or_recent_evidence_findings` 只表示发现历史或近期线索；历史 `NRestarts` 非零不能
单独证明当前仍在 crash，必须结合本次诊断的 `restart_delta`、PID 和当前错误判断。

新版 `check-upgrade.sh --pull` 除了比较 Agent 二进制版本和产物 SHA，还比较 Agent 专属安装器合约
指纹；因此只更新安装、认证前置校验或配置逻辑而无需重编二进制时，也会明确提示执行上面同一条正常升级
命令，不会因为 manifest 版本未变化而误报“已是最新”。但从不具备该机制的旧 release 首次过渡到
本版本时，旧 checker 进程无法在运行中获得新判断逻辑；本次必须按上面的两条命令先独立
`git pull --ff-only`，再直接执行正常的 `upgrade.sh dbdog-agent`。之后 checker 会在 pull 到新脚本时
自动重新执行最新逻辑。

目标机不能访问 GitHub 时，应从可联网机器同步同一个 commit 的完整 `dbdog-release` checkout；
不要只挑拣 `agent-install.sh` 等几个文件。`manifest.tsv`、整个 `scripts/`（包括
`scripts/agent/init-gaussdb-perdb.sql`）共同组成安装事务和内容指纹，缺失会明确报出具体路径并
fail closed。对应 manifest 文件名的 Agent tarball 可预置到目标机有效 `DBDOG_HOME/cache/`
（默认是执行安装命令用户的 `~/dbdog/cache/`），安装器仍会校验 SHA-256 后才使用。

显式设置 `DBDOG_GAUSSDB_ENV_FILE`、`DBDOG_GAUSSDB_PGHOST`（仅安装期 gsql 管理 socket）、
`DBDOG_GAUSSDB_LD_LIBRARY_PATH`、`DBDOG_GAUSSDB_PORT`、`DBDOG_GAUSSDB_LOG_GLOB`、
`DBDOG_GAUSSDB_DEPLOYMENT`、`DBDOG_ENV` 或 `DBDOG_AGENT_HOSTNAME` 只用于自动发现无法表达的
特殊部署；`DBDOG_AGENT_HEALTH_TIMEOUT` 只用于有证据表明冷启动超过默认 90 秒的机器。正常集中式
安装不需要这些覆盖。上一套 runtime/config 会保留在安装输出给出的
`.dbdog-agent-before-*` 目录。安装验收诊断均为 root `0600` 文件：配置检查在
`/var/log/dbdog-agent/install-configcheck.log`，逐次 readiness 在
`/var/log/dbdog-agent/install-agent-health.log`，数据库 check 在
`/var/log/dbdog-agent/install-gaussdb-check.log`，跨两个采集周期的新生命周期
PID/NRestarts/InvocationID 证据在
`/var/log/dbdog-agent/install-agent-stability.log`，本次启动后的有界日志差量在
`/var/log/dbdog-agent/install-agent-validation.log`。

## 公网：发布（维护者）

新会话先执行持久化预检；标准构建机只通过 `dbdog-build` SSH 别名访问，
`dbdog-build-old` 仅用于回退核对：

```bash
cd ~/Code/github.com/zlxtqbdgdgd/dbdog-release
test -f scripts/publish/publish.conf
gh auth status
source scripts/publish/publish.conf
ssh -o BatchMode=yes "$BUILD_HOST" 'uname -m; nproc; test -d /home/dbdog/repo'
```

`scripts/publish/publish.conf` 是 gitignore 的本机环境配置；标准目录为 `/home/dbdog/repo`、
`/home/dbdog/dbdog-release-build`，工具链位于 `/home/dbdog/tools` 与 `/home/dbdog/.cargo`。
发布 Agent/Web/MCP 等模块必须串行。

```bash
cp scripts/publish/publish.conf.example scripts/publish/publish.conf  # 首次：填 BUILD_HOST 等
./scripts/publish/publish.sh plan                # 看哪些模块有变更
./scripts/publish/publish.sh publish             # 发布全部变更模块（patch）
./scripts/publish/publish.sh publish dbdog-web --bump minor   # 点名+指定级别
./scripts/publish/publish.sh prune               # 核对非 manifest 当前产物（--yes 执行清理）
```

构建在麒麟 V10 / aarch64 专职机完成。产物在构建机上完成架构与 SHA-256 校验后直接上传
GitHub，本机只负责发布编排和 manifest 提交；`gh` 登录令牌通过 SSH stdin 临时传给上传进程，
不写入构建机持久配置或日志。开发阶段每模块只保留 manifest 当前产物；发布脚本先推 main，再删除
该模块旧资产。发布必须串行，清理会校验远端 HEAD、文件名与 SHA-256。
自动化代理发布前还必须完整读取 [发布 Skill](.claude/skills/publish/SKILL.md)。

设计说明见 [ADR 0001](docs/adr/0001-single-bucket-release-via-main.md)，术语见
[CONTEXT.md](CONTEXT.md)。
