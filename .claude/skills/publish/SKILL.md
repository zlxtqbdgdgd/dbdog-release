---
name: publish
description: 公网侧发布 dbdog 模块：检测源仓变更，经 aarch64 构建机出包，验证并上传 GitHub 产物桶，原子提交 manifest。用户要求“发布”“publish”“发版”“构建正式包”“清理旧产物”时使用。
---

# dbdog 发布

核心逻辑全在 `scripts/publish/publish.sh`。不要手工修改 `manifest.tsv`、README 版本表或
GitHub 资产来绕过脚本。

## 流程

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

6. **闭环复核**：确认本地 HEAD 等于 `origin/main`，manifest/README 一致，GitHub 资产唯一，
   其 size/digest 等于 manifest，并运行 `./scripts/publish/publish.sh prune` 确认无孤儿资产。
7. **汇报**：列出模块、版本、发布提交、资产 SHA-256；提示内网走正常升级路径。

## 注意

- 源仓出货提交必须已经进入各自 `origin/main`；发布器会 fail closed。
- Agent 正式配方已经跑通。版本和 Agent/Core 源码锚只认
  `dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv`，不要用 `publish.conf` 覆盖。
- Agent、Web、MCP 等正式发布不要并发执行；它们会修改同一份 manifest 和 `main`。
- 清理先运行 `./scripts/publish/publish.sh prune`，确认目标后再加 `--yes`。
- 网络错误发生在上传或 push 之后时，不要盲目重跑：先核对 GitHub 同名资产、远端 `main` 和
  manifest，避免错误递增版本。构建前失败且三者均未变化时才安全重跑原命令。
- 中途退出时检查 `git status`。保留用户已有的 `.codex/`、`bugs/` 和无关工作树修改。
