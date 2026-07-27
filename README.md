# dbdog-release

dbdog 的二进制发布仓：公网构建产物经此分发到只读 GitHub 的内网环境。
仓库本体只有 manifest、脚本和 skill；二进制都在唯一的产物桶
（GitHub Release [`artifacts`](../../releases/tag/artifacts)）里，文件名自带版本。
设计动机见 [docs/adr/0001](docs/adr/0001-single-bucket-release-via-main.md)，术语见 [CONTEXT.md](CONTEXT.md)。

## 最新版本

<!-- VERSION-TABLE:BEGIN -->
更新于 2026-07-26 17:01（此表由 publish.sh 生成，权威数据在 manifest.tsv）

| 模块 | 类别 | 装在 | 版本 | 产物 |
| --- | --- | --- | --- | --- |
| dbdog-server | first-party | 全家桶机 | 0.1.0 | dbdog-server-0.1.0-aarch64.tar.gz |
| dbdog-web | first-party | 全家桶机 | 0.1.1 | dbdog-web-0.1.1-aarch64.tar.gz |
| dbdog-mcp | first-party | 全家桶机 | 0.1.0 | dbdog-mcp-0.1.0-noarch.tar.gz |
| dbdog-agent | first-party | DB 主机 | 7.81.1-dbdog.1 | dbdog-agent-7.81.1-dbdog.1-aarch64.tar.gz |
| postgresql | third-party | 全家桶机 | 16.14 | postgresql-16.14-aarch64.tar.gz |
| clickhouse | third-party | 全家桶机 | 24.8.5.115 | clickhouse-24.8.5.115-aarch64.tar.gz |
| node | third-party | 全家桶机 | 20.18.1 | node-20.18.1-aarch64.tar.gz |
| goose | third-party | 全家桶机 | 3.27.3 | goose-3.27.3-aarch64.tar.gz |
<!-- VERSION-TABLE:END -->

## 当前可用范围

- **全家桶机**：产物与安装脚本已齐，等待今天在目标内网完成首次端到端验证。
- **GaussDB 主机 agent**：aarch64 运行时已发布，但 root cutover、systemd 单元和配置落位流程尚未交付；当前只能下载校验，不能按本仓完成安装。

## 内网首次安装：全家桶机

前提：麒麟 V10 / aarch64、专用 `dbdog` 账户、出网 HTTPS 可达 `github.com` 和
`release-assets.githubusercontent.com`。当前 stack 压缩产物合计约 280 MiB，此外还需
模块解包及 PG/CH 数据空间；先用 `df -h "$HOME"` 确认实际余量。

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

本仓公开；反馈问题时不要提交内网 IP、主机名、密钥或原始日志。

## 内网日常升级

```bash
cd ~/dbdog/release
./scripts/check-upgrade.sh --pull   # 0=无已装模块需升级，10=存在版本不同的已装模块
./scripts/upgrade.sh                # 只升级已安装且版本与 manifest 不同的模块
./scripts/verify.sh
```

缺失模块不会被无参数升级自动安装；需要显式执行，例如
`./scripts/upgrade.sh dbdog-web`。升级保留有效下载缓存与旧模块目录，但数据库迁移只向前；
不要把切软链当成完整数据库回滚。破坏性 `./scripts/reset.sh --yes-i-mean-it` 会删掉 PG/CH 全部数据，
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
