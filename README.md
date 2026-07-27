# dbdog-release

dbdog 的二进制发布仓：公网构建产物经此分发到只读 GitHub 的内网环境。
仓库本体只有 manifest、脚本和 skill；二进制都在唯一的产物桶
（GitHub Release [`artifacts`](../../releases/tag/artifacts)）里，文件名自带版本。
设计动机见 [docs/adr/0001](docs/adr/0001-single-bucket-release-via-main.md)，术语见 [CONTEXT.md](CONTEXT.md)。

## 最新版本

<!-- VERSION-TABLE:BEGIN -->
更新于 2026-07-27 03:38（此表由 publish.sh 生成，权威数据在 manifest.tsv）

| 模块 | 类别 | 装在 | 版本 | 产物 |
| --- | --- | --- | --- | --- |
| dbdog-server | first-party | 全家桶机 | 0.1.1 | dbdog-server-0.1.1-aarch64.tar.gz |
| dbdog-web | first-party | 全家桶机 | 0.1.3 | dbdog-web-0.1.3-aarch64.tar.gz |
| dbdog-mcp | first-party | 全家桶机 | 0.1.1 | dbdog-mcp-0.1.1-noarch.tar.gz |
| dbdog-agent | first-party | DB 主机 | 7.81.1-dbdog.1 | dbdog-agent-7.81.1-dbdog.1-aarch64.tar.gz |
| postgresql | third-party | 全家桶机 | 16.14-dbdog.1 | postgresql-16.14-dbdog.1-aarch64.tar.gz |
| clickhouse | third-party | 全家桶机 | 26.8.1.184 | clickhouse-26.8.1.184-aarch64.tar.gz |
| node | third-party | 全家桶机 | 20.18.1 | node-20.18.1-aarch64.tar.gz |
| goose | third-party | 全家桶机 | 3.27.3 | goose-3.27.3-aarch64.tar.gz |
<!-- VERSION-TABLE:END -->

## 当前可用范围

- **全家桶机**：已在麒麟 V10 / 鲲鹏 920 完成首次基础部署验收，PostgreSQL、ClickHouse
  与四个应用服务均可启动；DDSQL 查询、鉴权和 agent 业务链路仍需继续验证。
- **GaussDB 主机 agent**：aarch64 运行时已发布，但 root cutover、systemd 单元和配置落位流程尚未交付；当前只能下载校验，不能按本仓完成安装。

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

### 1. 拉取并安装到配置阶段

第一阶段会直接用 PG `5432`、CH `8123/9000` 启动本机数据库，当前不支持在初始化前
改这三个端口；执行前必须确认它们未被占用。server、ddsql、web、MCP 端口可在
`--finish` 前通过 env 调整。

```bash
uname -m                             # 必须输出 aarch64
mkdir -p ~/dbdog
git clone https://github.com/zlxtqbdgdgd/dbdog-release ~/dbdog/release
cd ~/dbdog/release
./scripts/install.sh                 # 下载校验、初始化 PG/CH、生成应用配置
ls -l ~/dbdog/etc/{dbdog-server,ddsql-server,dbdog-web,dbdog-mcp}.env
```

应用默认端口：server `8080`、ddsql `8770`、web `3000`、MCP `8090`。

### 2. 填配置

真实配置在 `~/dbdog/etc/`，模板只用于起步；升级不会覆盖。至少逐项确认：

`install.sh` 以 `dbdog` 用户初始化 PG；首次本机验证可让 server 的 `PG_DSN` 与 web 的
`DATABASE_URL` 都使用 `postgres://dbdog@127.0.0.1:5432/ctl?sslmode=disable`。

- `dbdog-server.env`：`PG_DSN`、ClickHouse 地址/库名、`DBDOG_INTERNAL_TOKEN`。
- `dbdog-web.env`：`DATABASE_URL`、`DBDOG_SERVER_URL`、与 server 相同的内部 token、
  `DBDOG_OAUTH_JWT_SECRET`、三个 `PUBLIC_*_URL`；需要改 web 端口时追加 `PORT`。
- `dbdog-mcp.env`：`DBDOG_BASE_URL`、与 web/server 相同的内部 token、与 web 相同的
  OAuth JWT，以及实际的 `DBDOG_OAUTH_ISSUER`、`DBDOG_PUBLIC_MCP_URL`、
  `DBDOG_APP_BASE_URL`；端口变量是 `DBDOG_HTTP_PORT`。
- `ddsql-server.env`：默认继承 `dbdog-server.env` 中的 PG/CH/metric 配置；这里只写覆盖项。

内部 token/JWT 至少 16 字符；不要保留 `user:pass`、`change-me` 或公网测试机 URL。
真实 PUBLIC/OAuth URL 取决于内网入口，本仓不能代填。`.env` 会自动收为 `0600`。

### 3. 迁移、启动、验收

```bash
cd ~/dbdog/release
./scripts/install.sh --finish
./scripts/verify.sh
```

首次 `--finish` 会在迁移后创建 `admin@dbdog.local` 管理员，并把随机密码输出一次；请当场
保存并在登录后立即修改。后续升级会检测既有账号，不会重置密码。登录后的管理员可在
Settings → 用户管理创建其他用户，因此 Web 不开放匿名注册。

`verify.sh` 会检查配置占位值、实际执行 PG/CH 查询，并等待 server、ddsql、web、MCP
HTTP 就绪；最后出现 `基础部署验收通过` 才可继续业务场景验证。它不证明 DDSQL 查询、
鉴权或 agent 链路已经端到端通过。`dbdogctl status all` 只反映进程状态，不等于健康。

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
./scripts/check-upgrade.sh --pull   # 0=已装模块版本+SHA一致，10=需要升级/身份校准
./scripts/upgrade.sh                # 升级已安装且版本或产物 SHA 不同的模块
./scripts/verify.sh
```

缺失模块不会被无参数升级自动安装；需要显式执行，例如
`./scripts/upgrade.sh dbdog-web`。旧版目录首次会因没有 SHA marker 做一次身份校准；之后即使
版本号相同，只要 manifest SHA 改变也会安装新产物。升级保留有效缓存与旧身份目录，但数据库
迁移只向前；不要把切软链当成完整数据库回滚。破坏性 `./scripts/reset.sh --yes-i-mean-it` 会删掉 PG/CH 全部数据，
只能作为最后手段。

服务管理：`./scripts/dbdogctl start|stop|restart|status [服务|all]`。机器重启后当前仍需
手动执行 `./scripts/dbdogctl start all`。

## GaussDB 主机 agent

```bash
cd ~/dbdog/release
./scripts/agent-install.sh
```

该命令目前只下载并校验 manifest 中的 omnibus tarball，随后会明确报错退出；它不会安装
agent。不要手工覆盖官方 `/opt/datadog-agent`。待版本化 cutover、systemd、配置与回滚验收
流程一并交付后，再开放内网安装。

## 公网：发布（维护者）

```bash
cp scripts/publish/publish.conf.example scripts/publish/publish.conf  # 首次：填 BUILD_HOST 等
./scripts/publish/publish.sh plan                # 看哪些模块有变更
./scripts/publish/publish.sh publish             # 发布全部变更模块（patch）
./scripts/publish/publish.sh publish dbdog-web --bump minor   # 点名+指定级别
./scripts/publish/publish.sh prune               # 核对非 manifest 当前产物（--yes 执行清理）
```

构建在麒麟 V10 / aarch64 专职机完成。开发阶段每模块只保留 manifest 当前产物；发布脚本
先推 main，再删除该模块旧资产。发布必须串行，清理会校验远端 HEAD、文件名与 SHA-256。

设计说明见 [ADR 0001](docs/adr/0001-single-bucket-release-via-main.md)，术语见
[CONTEXT.md](CONTEXT.md)。
