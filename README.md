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

内网判断是否要升级：`git pull` 后看上表（或跑 `scripts/check-upgrade.sh`），
版本号比本机装的新就升。各模块版本独立，只升有变化的。

## 内网：首次安装（全家桶机）

前提：专用 `dbdog` 账户（无需 root）；能 `git clone` 本仓；
能下载 `objects.githubusercontent.com`（GitHub 资产下载会 302 到该域名，需代理放行）。

```bash
mkdir -p ~/dbdog && cd ~/dbdog
git clone https://github.com/zlxtqbdgdgd/dbdog-release release
cd release
./scripts/install.sh          # 装基础件+初始化库+装应用件
vi ~/dbdog/etc/*.env          # 按提示填连接串等配置
./scripts/install.sh --finish # 跑数据库迁移 + 启动全部服务
./scripts/dbdogctl status all
```

目录布局（`~/dbdog/`）：`release/` 本仓 clone；`modules/<模块>/<版本>/` + `current` 软链；
`etc/` 配置（升级永不覆盖）；`data/` PG/CH 数据（升级永不碰）；`logs/`、`run/`、`cache/`。

## 内网：日常升级

```bash
cd ~/dbdog/release
./scripts/check-upgrade.sh --pull   # 拉最新 manifest，看差异（退出码 10=有可升级）
./scripts/upgrade.sh                # 升级全部有新版的模块（或点名：upgrade.sh dbdog-web）
./scripts/dbdogctl status all
```

升级动作 = 下载校验 → 停服务 → 数据库增量迁移（goose/drizzle 钩子，CH 租户表由
server 启动时自动推进）→ 切 `current` 软链 → 起服务。

- **回滚**：`ln -sfn ~/dbdog/modules/<模块>/<模块>-<旧版> ~/dbdog/modules/<模块>/current`
  后 `dbdogctl restart <服务>`（旧版本目录都保留着）。
- **逃生门**：升级损坏且无法增量修复时 `./scripts/reset.sh --yes-i-mean-it`
  ——删库重建，丢失租户/API key/全部监控数据，最后手段。

## 内网：GaussDB 主机装 agent

该主机同样 clone 本仓，然后：

```bash
./scripts/agent-install.sh        # 下载校验运行时 tarball，打印切换步骤（需 DBA 执行）
```

agent 产物是 omnibus 运行时 tarball（非 rpm，自制 rpm 与官方包冲突被 fork 明确禁止），
用 cutover 脚本原子切换到 /opt/dbdog-agent。切换涉及 systemd，是全流程唯一需要 root 的环节。

## 服务管理（无 root，纯脚本）

```bash
./scripts/dbdogctl start|stop|restart|status [服务|all]
# 服务：postgresql clickhouse dbdog-server ddsql-server dbdog-web dbdog-mcp
```

机器重启后需手动 `dbdogctl start all`（可自行加 crontab `@reboot`）。

## Skill（可选，配合 agent CLI）

内外网通用：在本仓目录里启动 Claude Code（或兼容 agent CLI），
`.claude/skills/` 下的 skill 自动可用，无需安装：

| skill | 用在哪 | 说什么触发 |
| --- | --- | --- |
| `publish` | 公网开发机 | "发布"、"发个版" |
| `upgrade` | 内网全家桶机 | "升级"、"检查更新" |
| `issue-card` | 内网 | "记个问题"、"生成问题卡片" |

skill 只是薄壳，核心永远是 `scripts/` 里的纯 bash——没有模型也照跑。

## 问题反馈

内网发现问题 → 用 `issue-card` skill（或手动照模板）生成一页式问题卡片 →
拍照带出 → 在本仓建 issue 贴上。
**本仓公开**：卡片/issue 不得包含内网 IP、主机名、账号、密钥、原始日志。
环境指纹用 `./scripts/fingerprint.sh --oneline` 生成。

## 公网：发布（维护者）

```bash
cd scripts/publish && cp publish.conf.example publish.conf  # 首次：填 BUILD_HOST 等
./scripts/publish/publish.sh plan                # 看哪些模块有变更
./scripts/publish/publish.sh publish             # 发布全部变更模块（patch）
./scripts/publish/publish.sh publish dbdog-web --bump minor   # 点名+指定级别
./scripts/publish/publish.sh prune --keep 3      # 清理桶内旧产物（试运行，--yes 执行）
```

构建在专职 arm 编译机上进行（麒麟 V10 / 鲲鹏 aarch64，与内网同构，ssh 驱动），
产物只出 aarch64（纯 JS 模块为 noarch）。三方件（postgresql/clickhouse/node/goose）
在编译机环境变化后点名发布一次即可。

## 待验证清单（内网 ready 后逐项打钩）

- [ ] 内网可下载 `objects.githubusercontent.com`（产物桶资产直链）
- [ ] agent 的 omnibus aarch64 运行时构建：需临时将编译机扩容到 ≥8c/16GB/50G 盘跑一次
      （当前 2GB 机不可行），随后 `scripts/publish/recipes/dbdog-agent.sh` 转正（结论已写在该文件头）
- [ ] dbdog-server 的 `migrations/clickhouse*/` 是否有 blueprint 覆盖不到、需手动执行的 CH DDL
- [ ] 各 `.env` 模板在内网首装时逐个校准（配方里标了 [首跑校准]）
