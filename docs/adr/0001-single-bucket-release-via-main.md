# 0001. 单产物桶 + main 即发布 + 生产同构机构建

日期：2026-07-24
状态：已接受

## 背景

dbdog 在公网开发，需部署到一个受限内网（鲲鹏 aarch64 / EulerOS）：GitHub 只读、
无法访问优质大模型、不便抓取编译依赖。决定不把源码带入内网，以二进制发布仓
dbdog-release 作为唯一分发通道；内网问题以 issue 回流公网修复。

约束：

- GitHub 仓库内单文件 100MB 硬限制，ClickHouse/agent 安装包远超此限；
  大二进制进 git 历史会使内网 fetch 成本永久膨胀。
- 内网 GitHub 只读，一切"内网侧动作"只能是拉取。
- GitHub Actions 的 arm runner 是 Ubuntu，glibc 比 EulerOS 新，产物大概率
  在目标机起不来；且 agent 的 omnibus 构建链在 CI 上调通成本高。
- 公网现有 Linux 测试机（/home/z1/dbdog）与内网目标机产物已验证兼容。
- 各源仓无 tag、无 CI，不希望给日常开发增加发版纪律负担。

## 决策

1. **单产物桶**：dbdog-release 上只建一个固定 GitHub Release（tag `artifacts`），
   充当纯文件桶。所有模块所有版本的产物都上传到它，文件名自带模块名、版本、
   架构（如 `dbdog-web-0.4.2-aarch64.tar.gz`）。不按发布打 tag。
2. **main 即发布**：一次发布 = 构建变更模块 → 产物入桶 → 向 main 提交一次
   manifest.tsv + README 版本表更新。发布历史即 manifest 的 git log；回滚 =
   按历史 manifest 安装旧版（旧文件仍在桶里）。
3. **生产同构机构建**：所有 aarch64 产物在公网测试机上构建（ssh 驱动），
   不用 GitHub Actions。三方件（Node/goose/PG/CH）也从这台"实际能跑"的机器
   上取用打包，而非从官网下载。
4. **manifest.tsv 为唯一权威**：TSV 而非 JSON，纯 bash/awk 可解析，内网零依赖
   （EulerOS 上 jq/python3 均不可假设）。README 版本表只是它的人类可读镜像，
   由发布脚本生成。

## 后果

- 内网升级只需 `git pull` +（按 manifest）curl 下载若干文件，无需理解 tag/Release 语义。
- 变更检测 = 各源仓 HEAD 对比 manifest 记录的 source_sha，源仓零侵入。
- 产物桶会累积历史版本，发布脚本提供 prune（每模块保留最近 3 版，且永不删
  当前 manifest 引用的文件）。
- Releases 页面没有"发布时间线"可看——接受，人和脚本都只看 manifest/README。
- 构建可重现性弱于 CI（依赖那台机器的环境）——现阶段接受，构建配方全部
  脚本化在 scripts/publish/recipes/，迁移到任何同构机只需装同样工具链。

## 备选方案

- 每次发布打日期 tag、只传变更资产：机制多一层，下载地址散落在多个 tag 下，
  收益只是一个装饰性的 Releases 时间线。
- Git LFS：有配额费用，且内网代理对 LFS 端点的放行不确定。
- GitHub Actions 构建：glibc 兼容风险 + omnibus 调通成本，放弃。
