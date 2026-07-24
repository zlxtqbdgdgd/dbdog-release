---
name: publish
description: 公网侧一键发布：检测各源仓变更，ssh 构建机出包，上传产物桶，提交 manifest。用户说"发布"、"publish"、"发个版"时使用。
---

# dbdog 发布

核心逻辑全在 `scripts/publish/publish.sh`，本 skill 只是驾驶它。

## 流程

1. **前置检查**（第一次或报错时）：
   - `scripts/publish/publish.conf` 存在（否则 `cp publish.conf.example publish.conf` 并让用户填 BUILD_HOST）；
   - `gh auth status` 通过；`ssh <BUILD_HOST> true` 可达。
2. **看变更**：`scripts/publish/publish.sh plan`，把结果表原样给用户看。
3. **定范围**：与用户确认要发哪些模块、bump 级别（默认 patch；接口/行为有破坏性变化建议 minor/major）。三方件只在用户点名时发布。
4. **执行**：`scripts/publish/publish.sh publish <模块...> --bump <级别> --yes`
   （交互确认由你在第 3 步完成，脚本层直接 --yes。）
5. **汇报**：发布了哪些模块、各自新版本号；提醒内网可 `check-upgrade.sh --pull` 升级。

## 注意

- 脚本会因"本地 HEAD 未推送到 origin/main"而拒绝发布——这是特性，提醒用户先 push。
- agent（dbdog-agent）配方尚未跑通，发布它会明确报错；不要试图绕过，引导用户看配方文件头的一次性准备清单。
- 桶膨胀时问一句是否 `publish.sh prune --keep 3`（试运行后再 --yes）。
- 发布失败中途退出时，manifest 未提交的改动用 `git -C . status` 检查，不留半成品提交。
