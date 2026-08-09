---
name: publish
description: 公网侧发布 dbdog 模块：检测源仓变更，经 aarch64 构建机出包，验证并上传 GitHub 产物桶，原子提交 manifest；发布收尾可把 agent 经内网升级路径装回构建机。用户要求“发布”“publish”“发版”“发布到 gh”“发布到本机”“构建正式包”“清理旧产物”时使用。
---

# dbdog 发布

核心逻辑全在 `scripts/publish/publish.sh`。不要手工修改 `manifest.tsv`、README 版本表或
GitHub 资产来绕过脚本。

## 两个动作（话术）

| 用户说 | 动作 | 含义 |
|---|---|---|
| 「发布」「发版」「publish」「发布到 gh」 | **发布到 GH** | 构建 → 验证 → 上传 GitHub 产物桶 → 原子提交 manifest。内网此后可升级到该版本 |
| 「发布到本机」 | **发布到本机** | 把已发布的 agent 在构建机上走**与内网完全相同的升级路径**装回（免下载，其余校验/cutover/验收一步不少）。agent 发布到 GH 后的标准收尾 |

**「本机」的定义：出这个包的那台构建机**（编译在哪台，装回哪台）。当前发布矩阵只出
aarch64，所以本机就是 `dbdog-build`；将来某架构进了发布矩阵，其「本机」就是那台对应
架构的 builder。x86 现状：发布域的多架构槽位（`BUILD_HOST_X86_64`、manifest arch 矩阵、
逐架构 fail closed）都在，`dbdog-build-x86`（146.56.217.73，CentOS Stream，兼 GaussDB
靶机）ssh 别名已备；编译域缺口是 server/web 的 cargo/node 工具链（机械活）与 agent 的
整条 x86 封存/换锚链（真项目，需专门排期）。mcp 是 noarch，天然全架构。在 x86 入矩阵前，
x86 靶机的 agent 仍走 dbdog-deploy 本机构建自装，不在本 skill 范围内。

发 agent 时两个动作按顺序都做：先发布到 GH，再发布到本机。只说「发布」时，默认把范围内
模块的「发布到本机」一起做完（栈模块见下文前提）。

**开发测试频繁提交怎么办（统一性与效率的分界）**：日常 dev 迭代继续走快路径（dev 栈直接
换二进制/重启），**不**要求每个提交走发布；但每次正式发布（版本切点）必须「发布到 GH +
发布到本机」成对做完——所有正式版本都经真实升级路径落到构建机，升级流程的问题在这里
先暴露，而高频提交不被发版仪式拖慢。

## 发布到 GH

1. **读环境**：确认 `scripts/publish/publish.conf` 存在；缺失时从
   `publish.conf.example` 复制。配置是本机私有文件，禁止提交。
2. **做预检**：

   ```bash
   gh auth status
   source scripts/publish/publish.conf
   ssh -G "$BUILD_HOST" | grep -E '^(hostname|user|identityfile|identitiesonly) '
   ssh -o BatchMode=yes "$BUILD_HOST" \
     'uname -m; test -d /home/dbdog/repo; test -d /home/dbdog/dbdog-release-build'
   ```

   标准维护机的 `BUILD_HOST` 是 `dbdog-build`；`dbdog-build-old` 仅供回退核对，禁止用于新发布。
3. **看变更**：运行 `./scripts/publish/publish.sh plan`，核对模块、当前版本、源码锚和目标版本。
4. **定范围**：按用户要求确定模块与 bump；默认 patch。三方件只有用户点名才发布。
5. **执行**：正式发布必须串行：

   ```bash
   ./scripts/publish/publish.sh publish <模块...> --bump <patch|minor|major> --yes
   ```

   server/web/mcp 一条命令到底。**agent 是四段节奏**（构建在私有挂载命名空间里进行，
   宿主 agent 不停服；`<agent_sha>`/`<core_sha>` 取自 `plan` 显示的出货锚，40 位全长）：

   ```bash
   # ① 上面的 publish 命令：预检→构建（~15 分钟）→末尾预期报「缺少 root 最终化产物」
   # ② 装锚定 wheel（root；pip 自动进命名空间，不碰宿主运行时）
   ssh root@<构建机> 'bash -s -- install-wheels <agent_sha> <core_sha>' \
     < scripts/publish/agent-build/build-host-prep.sh
   # ③ finalize（root，命名空间内；①末尾的报错信息里有可直接复制的完整命令）
   ssh root@<构建机> "unshare --mount --propagation private /usr/bin/bash -c \
     'mount --bind /var/lib/dbdog-agent-install-roots/<agent_sha> /opt/dbdog-agent \
      && exec /home/dbdog/cache/dbdog-agent/anchors/<agent_sha>/run-finalize-agent-runtime.sh <版本>'"
   # ④ 复跑①的 publish 命令：验证复用 canonical 产物→上传→manifest→清理
   ```

6. **闭环复核**：确认本地 HEAD 等于 `origin/main`，manifest/README 一致，GitHub 资产唯一，
   其 size/digest 等于 manifest，并运行 `./scripts/publish/publish.sh prune` 确认无孤儿资产。
7. **汇报**：列出模块、版本、发布提交、资产 SHA-256；提示内网走正常升级路径。

## 发布到本机（发布到 GH 后的标准收尾）

前提：该版本已完成发布到 GH——本机装回会核对留存产物与 manifest 的名字/SHA-256
一字不差，不一致 fail closed。统一入口（agent 与栈模块同一话术、同一命令形）：

```bash
# agent（sha 可省略，按 manifest 锚自动解析；这台构建机要带 5432 排除，见下）
ssh root@<构建机> 'DBDOG_POSTGRES_EXCLUDE_PORTS=5432 bash -s -- local-upgrade dbdog-agent' \
  < scripts/publish/agent-build/build-host-prep.sh
# 栈模块（可多个；agent 不能与栈模块混在一次里）
ssh root@<构建机> 'bash -s -- local-upgrade dbdog-server dbdog-web dbdog-mcp' \
  < scripts/publish/agent-build/build-host-prep.sh
```

它做的事：fast-forward 构建机上的 dbdog-release 检出 → 核对留存产物（agent 在
`anchors/<sha>` 对应 build 目录、栈模块在 `$BUILD_WORK/<模块>/out/`）与 manifest →
播种进 `/root/dbdog/cache`（升级器缓存命中即免下载）→ 执行与内网完全相同的
`upgrade.sh`：解包验收、cutover、配置、验收，失败自动事务回滚。agent 的停服窗口只有
cutover 那约 2 分钟。

- **`DBDOG_POSTGRES_EXCLUDE_PORTS=5432` 在这台构建机上发 agent 时每次都要带**：5432 是
  私人 dev PG 实例，监控体系拿不到其凭证；不带会在凭证探测处回滚。配好凭证即可去掉。
- **栈模块前提（一次性迁移，owner 安排）**：栈的「发布到本机」只升级**已按 release 布局
  安装**（`/root/dbdog/modules/<模块>/current` 存在）的模块。这台构建机的 server/web/mcp
  目前是 `dbdogt-*` 手工 dev 栈（端口/数据/服务与 release 布局冲突），首次安装=栈迁移
  （涉及 CH/PG 数据与端口切换），须由 owner 安排窗口执行；迁移前命令会 fail closed 指路。
- 升级流程的问题在这一步暴露在构建机上，而不是等到内网——验收失败要当真排查
  （agent 看 `/var/log/dbdog-agent/install-*.log`），不要绕过。

## 注意

- 源仓出货提交必须已经进入各自 `origin/main`；发布器会 fail closed。
- Agent 正式配方已经跑通。版本和 Agent/Core 源码锚只认
  `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`，不要用 `publish.conf` 覆盖。
- **换锚**（要把新的 agent/core 源码改动带出去）先读
  `scripts/publish/agent-build/README.md` 的换锚 SOP；锚不变的重发不重建。**产物里的 Python
  包来自被 seal 钉死的 core，不是发布锚**——只有锚定 wheel 能把锚上的改动带进产物。
  `build-host-prep.sh check` 会算清这件事并一次报全前置条件（publish 预检已自动调用）；
  它报的「封存 core 里没有」是硬阻断，「内容不同」意味着这次改动不会出去。
- Agent 构建/finalize 都在 bind 了构建安装根的私有挂载命名空间内进行，构建期**不停**宿主
  agent；按旧方式直跑配方会被挂载点断言拒绝。复跑 publish 不要求空安装根（canonical
  产物已出时走验证复用）。
- Agent、Web、MCP 等正式发布不要并发执行；它们会修改同一份 manifest 和 `main`。
- 清理先运行 `./scripts/publish/publish.sh prune`，确认目标后再加 `--yes`。
- 网络错误发生在上传或 push 之后时，不要盲目重跑：先核对 GitHub 同名资产、远端 `main` 和
  manifest，避免错误递增版本。构建前失败且三者均未变化时才安全重跑原命令。
- 中途退出时检查 `git status`。保留用户已有的 `.codex/`、`bugs/` 和无关工作树修改。
