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
aarch64，所以本机就是 `dbdog-build`；将来某架构（如 x86_64）进了发布矩阵，其「本机」就是
那台对应架构的 builder。x86 靶机目前**不走发布流程**（本机构建自装，dbdog-deploy 路径），
不在本 skill 范围内。

发 agent 时两个动作按顺序都做：先发布到 GH，再发布到本机。只说「发布」而范围含 agent 时，
默认把「发布到本机」一起做完。server/web/mcp 没有「发布到本机」一说（见文末）。

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

## 发布到本机（agent 发布后的标准收尾）

前提：该版本已完成发布到 GH（本机装回会核对产物与 manifest 的名字/SHA-256 一字不差，
不一致 fail closed）。执行：

```bash
ssh root@<构建机> 'DBDOG_POSTGRES_EXCLUDE_PORTS=5432 bash -s -- local-upgrade <agent_sha>' \
  < scripts/publish/agent-build/build-host-prep.sh
```

它做的事：fast-forward 构建机上的 dbdog-release 检出 → 核对产物与 manifest → 播种进
`/root/dbdog/cache`（升级器缓存命中即免下载）→ 执行与内网 DB 主机完全相同的
`upgrade.sh dbdog-agent`：解包验收、root cutover、conf 渲染、逐引擎 check、稳定窗验收，
失败自动事务回滚。停服窗口只有 cutover 那约 2 分钟。

- **`DBDOG_POSTGRES_EXCLUDE_PORTS=5432` 在这台构建机上每次都要带**：5432 是私人 dev PG
  实例，监控体系拿不到其凭证；不带会在凭证探测处回滚。哪天该实例配好 dbdog 凭证即可去掉。
- 升级流程的问题在这一步暴露在构建机上，而不是等到内网——验收失败要当真排查
  （`/var/log/dbdog-agent/install-*.log`），不要绕过。
- server/web/mcp 不走这套：构建机上的应用栈要升级就正常 `scripts/upgrade.sh <模块>`
  （它们的包从 GitHub 拉，构建机可直连）。

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
