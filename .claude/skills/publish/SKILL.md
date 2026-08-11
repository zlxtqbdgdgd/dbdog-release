---
name: publish
description: dbdog 发布与部署：正式发布（GitHub 一套，仅 arm）、快升级（「部署」，dev 日常，agent 双机/栈 arm）、慢升级（GitHub 下载走全流程）、发布到本机（发布收尾验证）。用户说“发布”“publish”“发版”“发布到 gh”“部署 X”“快升级 X”“慢升级 X”“发布到本机”“构建正式包”“清理旧产物”时使用。
---

# dbdog 发布与部署

核心原则：**正式发布只有 GitHub 一套（只发布 arm 版本）；快慢升级共用同一套部署代码
路径与同一套落盘布局，绝不搞两套部署**。快慢的差别只在包来源与粒度，装完的机器长得
一模一样。发布逻辑全在 `scripts/publish/publish.sh`，部署逻辑全在 `scripts/upgrade.sh`
（快升级经 `--artifact` 走同一段代码）；不要手工改 `manifest.tsv`、README 版本表或
GitHub 资产绕过脚本。

## 话术总表

| 用户说 | 含义 | 作用范围 |
|---|---|---|
| 「发布」「发版」「publish」「发布到 gh」 | 正式发布：构建→验证→上传 GitHub 产物桶→原子提交 manifest | 仅 arm 产物；内网此后可升级 |
| 「部署 X」「快升级 X」 | dev 日常快路径，按 origin/main 出活，落**同一 release 布局** | agent→arm 构建机 + x86 靶机**两台**；server/web/mcp→arm 构建机 |
| 「慢升级 X」 | 从 GitHub 下载 + 完整升级流程（校验/staging/cutover/验收/回滚） | 在哪台机说就升哪台（内网主机同一命令） |
| 「发布到本机」 | 正式发布的收尾：本机构建产物播种 cache 免下载，其余与慢升级一字不差 | 出包的那台构建机 |

正式发布 agent 时「发布到 GH → 发布到本机」成对做完。dev 高频提交走「部署」，
不必发版——统一性靠「同一套部署代码 + 同一布局」保证，效率靠免仪式的快路径保证。

## 正式发布（发布到 GH）

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
3. **看变更**：`./scripts/publish/publish.sh plan`，核对模块、当前版本、源码锚和目标版本。
4. **定范围**：按用户要求确定模块与 bump；默认 patch。三方件只有用户点名才发布。
5. **执行**（串行）：

   ```bash
   ./scripts/publish/publish.sh publish <模块...> --bump <patch|minor|major> --yes
   ```

   server/web/mcp 一条命令到底。**agent 是四段节奏**（构建在私有挂载命名空间里，宿主
   agent 不停服；`<agent_sha>`/`<core_sha>` 取 `plan` 显示的出货锚，40 位全长）：

   ```bash
   # ① 上面的 publish：预检→构建（~15 分钟）→末尾预期报「缺少 root 最终化产物」
   # ② 装锚定 wheel（root；pip 自动进命名空间）
   ssh root@<构建机> 'bash -s -- install-wheels <agent_sha> <core_sha>' \
     < scripts/publish/agent-build/build-host-prep.sh
   # ③ finalize（root，命名空间内；①末尾报错里有可复制的完整命令）
   ssh root@<构建机> "unshare --mount --propagation private /usr/bin/bash -c \
     'mount --bind /var/lib/dbdog-agent-install-roots/<agent_sha> /opt/dbdog-agent \
      && exec /home/dbdog/cache/dbdog-agent/anchors/<agent_sha>/run-finalize-agent-runtime.sh <版本>'"
   # ④ 复跑①：验证复用 canonical 产物→上传→manifest→清理
   ```

6. **闭环复核**：本地 HEAD == `origin/main`，manifest/README 一致，GitHub 资产唯一且
   size/digest 等于 manifest，`./scripts/publish/publish.sh prune` 无孤儿。
7. **发布到本机**（agent 发布收尾；栈模块同理可选）：

   ```bash
   ssh root@<构建机> 'DBDOG_POSTGRES_EXCLUDE_PORTS=5432 bash -s -- local-upgrade dbdog-agent' \
     < scripts/publish/agent-build/build-host-prep.sh          # sha 按 manifest 锚自动解析
   ssh root@<构建机> 'bash -s -- local-upgrade dbdog-server dbdog-web dbdog-mcp' \
     < scripts/publish/agent-build/build-host-prep.sh          # 栈模块（可多个）
   ```

8. **汇报**：模块、版本、发布提交、资产 SHA-256；提示内网走慢升级。

## 部署（快升级）——dev 日常

按 origin/main 出活，落同一 release 布局；验收照跑（栈走 OAuth 全链，agent 走版本戳+服务）。

```bash
# 部署 server/web/mcp（arm 构建机；可多个模块）
ssh root@dbdog-build '/home/dbdog/repo/dbdog-release/scripts/fast-upgrade.sh dbdog-server dbdog-web dbdog-mcp'

# 部署 agent = 双机，先 arm 后 x86：
ssh root@dbdog-build '/home/dbdog/repo/dbdog-release/scripts/fast-upgrade.sh dbdog-agent'
ssh dbdog-x86-root 'bash /home/dbdog/repo/dbdog-agent/dbdog-deploy/scripts/x86-local/deploy-local.sh'
```

机制：栈=源仓 ff 到 origin/main → 与正式发布**相同 recipe** 出包（版本
`<manifest>-dev.g<短sha>`）→ `upgrade.sh --artifact` 安装（与慢升级同一段代码）。
agent=组件级替换（Go 二进制 + 4 集成 wheel；arm 复用 embedded rtloader 与封存 bazel
缓存，x86 走其三步脚本），并把 `.dbdog-artifact-sha256` 改写为 dev 标记——下次慢升级
必整套换回 canonical，dev 组件不会冒充发布产物。执行前记得先把构建机的
dbdog-release 检出 `git pull --ff-only`（fast-upgrade 自身不自更新）。

## 慢升级——GitHub 下载 + 全流程

在目标机上执行（内网主机与构建机同一命令）：

```bash
# 栈（以栈属主身份；构建机上是 dbdog）
runuser -u dbdog -- bash -c 'cd ~ && exec /home/dbdog/repo/dbdog-release/scripts/upgrade.sh dbdog-server dbdog-web dbdog-mcp'
# agent（root；构建机要带 5432 排除）
DBDOG_POSTGRES_EXCLUDE_PORTS=5432 /home/dbdog/repo/dbdog-release/scripts/upgrade.sh dbdog-agent
```

x86 靶机没有慢升级（发布物只出 arm）；它的 agent 只有「部署」快路径。

## 注意

- 源仓出货提交必须已进各自 `origin/main`；发布器 fail closed。快升级同样只部署已推送提交。
- 版本和 Agent/Core 源码锚只认 `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`。**换锚**
  （要把新的 agent/core 源码改动正式出货）先读 `scripts/publish/agent-build/README.md` 的
  SOP；锚不变的重发不重建。**产物里的 Python 包来自被 seal 钉死的 core**——只有锚定
  wheel 能把锚上的改动带进正式产物（快升级的 wheel 是 dev 路径，不影响此规则）。
- Agent 构建/finalize 在 bind 构建安装根的私有挂载命名空间内进行，构建期**不停**宿主
  agent；直跑配方会被挂载点断言拒绝。复跑 publish 不要求空安装根。
- 构建机栈已按 release 布局运行（dbdogctl 管理，配置在 /home/dbdog/dbdog/etc）；
  postgresql 模块仅作 psql 客户端存在（数据面仍是 dbdogt-pg/ch，服务不启动）。
  旧 dbdogt-{server,ddsql,web,mcp} 单元已停用保留，仅作紧急回退。
- `DBDOG_POSTGRES_EXCLUDE_PORTS=5432` 在构建机上装/升 agent 时每次都带（5432 是私人
  dev PG，凭证不归监控体系管）。
- 各类正式发布不要并发执行；清理先 `prune` 再 `--yes`；上传/push 后的网络错误不要盲目
  重跑（先核对 GitHub 资产、远端 `main`、manifest 三者未变）。
- 依赖缓存优先复用（构建机 BUILD_WORK 各模块 out/、封存 bazel 缓存、锚册 wheel），
  不要重复下载；清理时只删后续构建确定不用的东西。
- **`cache/dbdog-agent/bazel/repository` 是 seal 本体，不许任何会写它的工具指向它**
  （`distdir`/CAS 只读复用没问题）。它按 `cache-reference` 封存——只记 sha256 不存副本，
  被删就救不回来；2026-08-10 快升级的 bazel repository_cache 指到这里，GC 掉 26783 个文件、
  正式发布路径当场断掉。恢复与重新封存 SOP 见 `scripts/publish/agent-build/README.md`
  的「seal 是活目录」一节。
- 构建机 `/` 与 `/home/dbdog` 是**两块盘**，`df /home` 看的是前者；真正的约束是
  `df -h /home/dbdog`（长期 95%+ 满）。可安全清理的对象同上文档。
- 中途退出检查 `git status`；保留用户的 `.codex/`、`bugs/` 与无关工作树修改。
