---
name: upgrade
description: 内网侧一键升级：检查 manifest 与本地版本差异，按需下载安装变更模块。用户说"升级"、"检查更新"、"update"时使用。
---

# dbdog 内网升级

核心逻辑全在纯 bash 脚本里（无网络/无模型也能跑），本 skill 只是驾驶它们。

## 流程

1. **检查**：`scripts/check-upgrade.sh --pull`，把差异表原样给用户看。
   退出码 0=全最新，10=有可升级。
2. **确认**：和用户确认升级范围（默认全部可升级模块；也可点名）。
3. **执行**：`scripts/upgrade.sh`（或 `scripts/upgrade.sh <模块>...`）。
   脚本自己处理：下载校验 → 停服务 → 数据库增量迁移（钩子）→ 切软链 → 起服务。
4. **验证**：`scripts/dbdogctl status all`；异常看 `~/dbdog/logs/<服务>.log` 尾部。
5. **汇报**：升了什么版本、服务状态；有问题建议用 issue-card skill 生成问题卡片。

## 故障处置

- 某模块升级后异常 → 回滚：
  `ln -sfn ~/dbdog/modules/<模块>/<模块>-<旧版本> ~/dbdog/modules/<模块>/current`
  然后 `scripts/dbdogctl restart <服务>`。旧版本目录都还在，直接列目录看。
- 数据库迁移钩子失败 → 修复配置后 `scripts/install.sh --finish` 幂等补跑。
- 彻底坏掉且不心疼数据 → `scripts/reset.sh --yes-i-mean-it`（删库重建，最后手段，
  会丢租户/API key/全部监控历史，需用户明确同意）。
- GaussDB 主机上的 agent 不归本机脚本管，用 `scripts/agent-install.sh`（需 DBA sudo）。
