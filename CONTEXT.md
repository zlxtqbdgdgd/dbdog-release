# dbdog-release

dbdog 的二进制发布与内网升级语境。公网开发产出的模块经此仓分发到只读 GitHub 的内网环境；内网问题以 issue 形式回流公网修复。

## Language

**模块（Module）**：
发布集中一个独立版本化的交付单元，各模块版本互相独立、按需发布与升级。
_Avoid_: 组件、包（泛指时）

**一方模块（First-party module）**：
由 dbdog 源码仓构建出的模块：dbdog-server（含 ddsql-server）、dbdog-web、dbdog-mcp、dbdog-agent。agent-core 不是模块——它在构建期被打进 dbdog-agent 的安装包，运行时不独立存在。

**三方件（Third-party component）**：
原样转分发的外部依赖模块：PostgreSQL、ClickHouse、Node.js 运行时、goose。版本号沿用上游版本，基本不变，首次安装后长期跳过。
_Avoid_: 依赖（易与代码库依赖混淆）

**发布集（Release set）**：
经 dbdog-release 分发的全部模块。dbdog-labs 不在发布集内（走自己的 marketplace 只读拉取）。

**发布（Publish）**：
公网侧动作：只重建有变更的模块，产物入桶，随后向 main 提交一次 manifest 更新。一次发布 = 一个 manifest 提交；发布历史即 manifest 的 git 历史。
_Avoid_: 部署、上线

**产物桶（Artifact bucket）**：
dbdog-release 上唯一固定的 GitHub Release，存放所有模块所有版本的产物文件；文件名自带模块名、版本与架构。不承载版本语义——版本语义只在 manifest。

**升级（Upgrade）**：
内网侧动作：逐模块对比 manifest 版本与本地已装版本，只安装有新版本的模块。
_Avoid_: 重装、更新（泛指时）

**Manifest**：
最新发布的权威模块版本清单（机器可读），README 中的版本表是它的人类可读镜像。

**反馈 issue（Feedback issue）**：
内网发现的问题经内网大模型总结后，由人工带出（如拍照）、在 dbdog-release 上建的 issue。仓库公开，issue 不得含内部环境细节与原始日志。

**问题卡片（Issue card）**：
内网侧生成的一页式问题描述（现象/复现/期望/环境指纹），为"拍照带出"优化：短、结构化、无敏感信息。

**环境指纹（Fingerprint）**：
一台机器上已装模块及其版本的快照清单，随问题卡片附带，让公网侧无需追问就知道问题发生在哪套版本上。

**逃生门重建（Reset）**：
显式触发的删库重建初始化，仅用于升级损坏或无法增量的场合；不是默认升级路径。
_Avoid_: 升级（重建不是升级）

## Flagged ambiguities

- "agent-core 是一个二进制" —— 否。agent-core 是 Python 库仓，产物是被 dbdog-agent omnibus 包吸收的 wheels，发布集内没有 agent-core 条目。

## Example dialogue

> 开发：GaussDB 补丁改在 agent-core 里，要单独发布 agent-core 吗？
> 专家：不用。重新构建 dbdog-agent 的 omnibus 包，dbdog-agent 这个模块的版本号 +1，内网整包升级。
> 开发：那这次发布 web 也没改，要动吗？
> 专家：发布只刷新有变更的模块。manifest 里 web 版本不变，内网升级时自然跳过它。
