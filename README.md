# dbdog-release

dbdog 的发布仓。仓内只有模块清单（`manifest.tsv`）和安装升级脚本；二进制产物都在
GitHub Release [`artifacts`](../../releases/tag/artifacts) 里，文件名自带模块名、版本与架构。
内网环境从这里 clone 一次，之后靠 `git pull` + 脚本完成安装和升级。

## 最新版本

<!-- VERSION-TABLE:BEGIN -->
更新于 2026-09-02 02:58（此表由 publish.sh 生成，权威数据在 manifest.tsv）

| 模块 | 类别 | 装在 | 版本 | 产物 | 架构 |
| --- | --- | --- | --- | --- | --- |
| dbdog-server | first-party | 全家桶机 | 0.1.21 | dbdog-server-0.1.21-aarch64.tar.gz | aarch64 |
| dbdog-web | first-party | 全家桶机 | 0.1.23 | dbdog-web-0.1.23-aarch64.tar.gz | aarch64 |
| dbdog-mcp | first-party | 全家桶机 | 0.1.16 | dbdog-mcp-0.1.16-noarch.tar.gz | noarch |
| dbdog-agent | first-party | DB 主机 | 7.81.0-dbdog.11 | dbdog-agent-7.81.0-dbdog.11-aarch64.tar.gz | aarch64 |
| ddprof | third-party | DB 主机 | - | - | aarch64 |
| postgresql | third-party | 全家桶机 | 16.14-dbdog.1 | postgresql-16.14-dbdog.1-aarch64.tar.gz | aarch64 |
| clickhouse | third-party | 全家桶机 | 26.8.1.184 | clickhouse-26.8.1.184-aarch64.tar.gz | aarch64 |
| node | third-party | 全家桶机 | 20.18.1 | node-20.18.1-aarch64.tar.gz | aarch64 |
| goose | third-party | 全家桶机 | 3.27.3 | goose-3.27.3-aarch64.tar.gz | aarch64 |
<!-- VERSION-TABLE:END -->

「全家桶机」指跑 PostgreSQL、ClickHouse 和四个应用服务的那台机器；「DB 主机」指被监控的
数据库主机，只装 agent。当前发布物只出 aarch64（noarch 模块除外）。

## 全家桶机：首次安装

前提：麒麟 V10 / aarch64、专用 `dbdog` 账户、出网 HTTPS 可达 `github.com` 和
`release-assets.githubusercontent.com`。压缩产物合计约 305 MiB，此外还需模块解包及 PG/CH
数据空间；先用 `df -h "$HOME"` 确认余量。ClickHouse 首次探测会从约 154 MiB 自解压为约
708 MiB，模块目录应至少额外留出 1 GiB。

### 出网代理与 TLS

curl 与 Git 原生读取 `https_proxy`/`HTTPS_PROXY`、`all_proxy`/`ALL_PROXY` 和
`no_proxy`/`NO_PROXY`，脚本不会另拼 `--proxy`。建议统一用小写；大小写同时存在时 curl 以
小写为准。curl 不把大写 `HTTP_PROXY` 当作代理变量，访问本仓的 HTTPS 地址应设置
`https_proxy`。设置了代理时务必让本机服务绕过它：

```bash
export https_proxy=http://proxy.internal.example:3128
export no_proxy=127.0.0.1,localhost,::1
```

若代理重签目标站证书，优先取得运维提供的 PEM CA，让 clone、后续 pull 和产物下载继续
严格校验证书及主机名。Git 与下载脚本是两条链路，需分别设置：

```bash
ca=/path/to/internal-proxy-ca.pem
git -c http.sslCAInfo="$ca" clone \
  https://github.com/zlxtqbdgdgd/dbdog-release ~/dbdog/release
git -C ~/dbdog/release config --local http.sslCAInfo "$ca"
export CURL_CA_BUNDLE="$ca"
```

按上例 clone 后，从下一节的 `cd ~/dbdog/release` 继续，跳过重复的 `git clone`。

仅在无法及时取得 CA、且已通过可信渠道确认下载地址时，才可单次使用
`CURL_INSECURE=1 ./scripts/install.sh` 临时排障。只有精确值 `1` 会传给 curl 的
`--insecure`；未设置或设为 `0` 均保持严格 TLS，其他值直接报错。该模式关闭证书和主机名
校验，产物 SHA-256 只能发现内容变化、不能证明来源，因此不要写入 `.bashrc` 或长期启用；
它也不影响 Git。不要使用 `GIT_SSL_NO_VERIFY` 或 `git config http.sslVerify false`。

### 拉取并一键安装

安装会直接使用 PG `5432`、CH `8123/9000`、server `8080`、ddsql `8770`、web `3000`、
MCP `8090`；执行前必须确认这些端口未被占用。脚本完成模块安装、数据库初始化、配置生成、
迁移、管理员创建、服务启动和基础验收后才返回成功。

```bash
uname -m                             # 必须输出 aarch64
mkdir -p ~/dbdog
git clone https://github.com/zlxtqbdgdgd/dbdog-release ~/dbdog/release
cd ~/dbdog/release
./scripts/install.sh
```

默认访问地址按默认路由的本机 IPv4 生成；需要指定 DNS 名或固定 IP 时，在首次安装命令前
设置 `DBDOG_ADVERTISE_HOST`，例如 `DBDOG_ADVERTISE_HOST=dbdog.internal ./scripts/install.sh`。
该值只用于生成访问 URL，服务仍监听默认端口。反向代理和 HTTPS 可在安装成功后作为可选运维
配置，不阻塞默认安装。

安装会生成随机内部 Token/OAuth JWT，并同步写入 server、web、MCP 的 `0600` env 文件；
PG/CH 使用只监听本机的默认连接。已有真实配置不会被覆盖。首次迁移会创建
`admin@dbdog.local` 管理员并把随机密码输出一次；请当场保存并在登录后立即修改，后续升级
不会重置密码。登录后的管理员可在 Settings → 用户管理创建其他用户，Web 不开放匿名注册。

安装末尾自动调用的 `verify.sh` 会检查配置占位值、实际执行 PG/CH 查询，并等待 server、
ddsql、web、MCP HTTP 就绪；同时验证 Web OAuth 表、授权服务器元数据、MCP 受保护资源元数据
以及 401 `WWW-Authenticate` 挑战。出现 `基础部署及 OAuth 自动发现链验收通过` 才可继续业务
场景验证。浏览器登录、用户授权和真实工具调用仍属于业务场景验收。`dbdogctl status all`
只反映进程状态，不等于健康。

Claude Code 使用 Streamable HTTP 连接，不需要手工复制内部 Token：

```bash
claude mcp add --transport http --scope user dbdog http://<全家桶主机>:8090/mcp
```

随后在 Claude Code 的 `/mcp` 中选择 `Authenticate`，浏览器会转到 Web `3000` 端口登录并
授权。服务端自动发布 OAuth discovery；不要把固定 Bearer Token 写进 Claude 配置作为默认方案。

旧环境若曾停在「已落包、未迁移」的中间状态，更新本仓后可执行一次
`./scripts/install.sh --finish` 恢复；这不是新安装的正常步骤。

失败时先看：

```bash
./scripts/dbdogctl status all
ls -1 ~/dbdog/logs
tail -n 100 ~/dbdog/logs/dbdog-server.log   # 按失败项换成对应日志
./scripts/fingerprint.sh --oneline
```

判断架构以 `file <二进制>` 为准；发布物中的 Linux 用户态机器码均为 AArch64。安装/升级会先
在 staging 中运行 `--version`，成功后才切换 `current`。若报 `Illegal instruction`，请保留
下面各项原始输出再反馈：

```bash
uname -m
grep -m1 '^Features' /proc/cpuinfo
file ~/dbdog/modules/clickhouse/current/bin/clickhouse
~/dbdog/modules/clickhouse/current/bin/clickhouse --version; echo "rc=$?"
tail -n 80 ~/dbdog/logs/clickhouse.err.log
```

## 全家桶机：日常升级

```bash
cd ~/dbdog/release
./scripts/check-upgrade.sh --pull   # 0=版本+SHA 一致，10=需升级/校准
./scripts/upgrade.sh                # 升级已安装且版本或产物 SHA 不同的模块
./scripts/verify.sh
```

数据库结构升级已包含在上述流程中，不需要另跑迁移命令。`upgrade.sh` 先按依赖顺序处理基础
运行时，再升级 server、web 和 MCP；各自的数据库迁移在模块切换前自动执行，失败即停止升级。
迁移文件随模块产物发布并校验完整性。Web/MCP 升级还会自动补齐缺失或空的本机 OAuth/public
URL，迁移已知旧模板地址，重启受影响的运行中服务，并执行 OAuth 专项验收；已有自定义域名、
反代地址和真实凭证不覆盖。

缺失模块不会被无参数升级自动安装，需要显式点名，例如 `./scripts/upgrade.sh dbdog-web`。
旧版目录首次会因没有 SHA marker 做一次身份校准；之后即使版本号相同，只要 manifest SHA
改变也会安装新产物。升级保留有效缓存与旧身份目录，但数据库迁移只向前；不要把切软链当成
完整数据库回滚。破坏性的 `./scripts/reset.sh --yes-i-mean-it` 会删掉 PG/CH 全部数据，只能
作为最后手段。

服务管理：`./scripts/dbdogctl start|stop|restart|status [服务|all]`。机器重启后当前仍需手动
执行 `./scripts/dbdogctl start all`。

## DB 主机：agent

前提：麒麟 V10 / aarch64、目标数据库正在运行、dbdog-server 已可从该主机直连，并已从
dbdog-web 的 Agent 接入页签发 ingest API key。dbdog 的私有运行时、配置和服务分别固定在
`/opt/dbdog-agent`、`/etc/dbdog-agent` 与 `dbdog-agent*`，不会触碰同机其他采集 agent。

GaussDB / openGauss 目标机必须先由 DBA 完成两项前置配置，安装器只读检查、不会替你改配置
文件，也不会 reload/restart 数据库：

```text
SHOW password_encryption_type;          -- 必须返回 1
host all dbdog 127.0.0.1/32 md5         # pg_hba.conf 中必须存在
```

`password_encryption_type=1` 决定新建监控用户时同时保存 SHA256 与 MD5 凭证，HBA 的 `md5`
才决定这次 TCP 连接采用 MD5 认证，两者缺一不可。HBA 使用首条匹配规则且不会回退，`user=all`
同样会匹配 `dbdog`，因此精确的 MD5 规则必须放在可能匹配它的宽泛规则之前。

安装与后续升级是同一条命令：

```bash
cd ~/dbdog/release
git pull --ff-only
sudo ./scripts/upgrade.sh dbdog-agent
```

首次运行只会在终端提示两个无法安全猜测的外部值：dbdog-server 地址和 Web 签发的 Agent API
key。监控用户密码由安装器随机生成并写入 root `0600` 配置，升级自动保留，不需要人工知道或
再次输入。非交互自动化可用 `DBDOG_SERVER_URL`、`DBDOG_API_KEY` 传入；确需接管既有监控密码
时才设置 `DBDOG_GAUSSDB_MONITOR_PASSWORD`。不要把明文写进仓库、shell history 或命令参数。

安装器会自动发现目标实例的端口、socket、数据与日志路径，创建或复用 `dbdog` 监控用户及兼容
视图，安装并启用四个私有服务，最后以真实的数据库 check 和全组件 readiness 收口；任一步失败
都会恢复上一套运行时、配置与 systemd 单元。已幂等创建的监控用户、权限与兼容对象按数据库
迁移的只前进语义保留，重跑升级会复用，不做破坏性数据库回滚。

若旧环境中的 `dbdog` 用户是在 `password_encryption_type=2/3` 下创建的，仅把参数改成 `1`
不会补出 MD5 凭证。安装器不会擅自替已有账号改密：应由 DBA 在 mode `1` 生效后为该用户设置
一个新密码，并在同次升级中通过安全环境注入 `DBDOG_GAUSSDB_MONITOR_PASSWORD`；或者删除确认
可重建的旧监控用户，让安装器重新创建。全新环境不需要这一步。

`check-upgrade.sh --pull` 除了比较版本和产物 SHA，还比较安装器合约指纹；只改安装逻辑而未重
编二进制时也会提示执行上面同一条升级命令。从不具备该机制的旧版本首次过渡时，必须按上面
先独立 `git pull --ff-only` 再执行 `upgrade.sh dbdog-agent`。

升级或排障后统一运行 `sudo ./scripts/dbdogctl diagnose dbdog-agent`。结论中的 `healthy`
表示当前检查，`diagnostic_complete` 表示证据是否采全，`historical_or_recent_evidence_findings`
只表示发现历史或近期线索；历史 `NRestarts` 非零不能单独证明当前仍在 crash，必须结合本次诊断
的 `restart_delta`、PID 和当前错误判断。诊断文件均为 root `0600`，位于
`/var/log/dbdog-agent/install-*.log`。

极慢主机可在 30–600 秒内显式设置 `DBDOG_AGENT_HEALTH_TIMEOUT`（默认 90 秒）；这只延长严格的
全组件验收，不会把单次 forwarder 202 当作整机健康。`DBDOG_GAUSSDB_ENV_FILE`、
`DBDOG_GAUSSDB_PGHOST`、`DBDOG_GAUSSDB_LD_LIBRARY_PATH`、`DBDOG_GAUSSDB_PORT`、
`DBDOG_GAUSSDB_LOG_GLOB`、`DBDOG_GAUSSDB_DEPLOYMENT`、`DBDOG_ENV`、`DBDOG_AGENT_HOSTNAME`
只用于自动发现无法表达的特殊部署，正常安装不需要。上一套运行时/配置会保留在安装输出给出的
`.dbdog-agent-before-*` 目录。

目标机不能访问 GitHub 时，应从可联网机器同步同一个 commit 的完整 checkout，不要只挑拣个别
文件：`manifest.tsv` 和整个 `scripts/` 共同组成安装事务和内容指纹，缺失会明确报出路径并拒绝
继续。对应 manifest 文件名的 agent tarball 可预置到 `DBDOG_HOME/cache/`（默认
`~/dbdog/cache/`），安装器仍会校验 SHA-256 后才使用。

## 诊断与反馈

需要一次全机巡检或故障取证时，手工执行 `./scripts/collect-diagnostics.sh`（agent 主机用
`sudo`）。它自动识别机器角色，生成 mode `0600` 的内网脱敏报告和无原始日志的问题卡片；同目录
游标记录最后成功时间及日志水位，下次运行从该水位增量扫描。本功能不会创建定时任务。完整说明见
[内网诊断采集指引](docs/internal-ai-diagnostics.md)。

本仓公开。反馈问题时只使用问题卡片的内容，不要提交内网 IP、主机名、密钥或原始日志。
