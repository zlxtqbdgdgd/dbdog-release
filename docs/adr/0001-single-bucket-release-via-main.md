# 0001. 单产物桶 + main 即发布 + 生产同构机构建

日期：2026-07-24（2026-07-25 修订：内网 OS 确认为麒麟 V10；构建改在专职 arm 编译机）
状态：已接受

## 背景

dbdog 在公网开发，需部署到一个受限内网（鲲鹏 aarch64 / 麒麟 V10）：GitHub 只读、
无法访问优质大模型、不便抓取编译依赖。决定不把源码带入内网，以二进制发布仓
dbdog-release 作为唯一分发通道；内网问题以 issue 回流公网修复。

约束：

- GitHub 仓库内单文件 100MB 硬限制，ClickHouse/agent 安装包远超此限；
  大二进制进 git 历史会使内网 fetch 成本永久膨胀。
- 内网 GitHub 只读，一切"内网侧动作"只能是拉取。
- GitHub Actions 的 arm runner 是 Ubuntu，glibc 比麒麟 V10（2.28）新，产物大概率
  在目标机起不来；且 agent 的 omnibus 构建链在 CI 上调通成本高。
- 公网原测试机是 x86_64（openEuler 22.03），与内网架构不符（2026-07-25 实测发现），
  故专门购置了一台与内网同构的编译机：麒麟 V10 / 鲲鹏 aarch64 / glibc 2.28 云主机，
  dbdog 账户免 root 运作。x86 测试机保持原样，只可用于 noarch 模块应急。
- 各源仓无 tag、无 CI，不希望给日常开发增加发版纪律负担。

## 决策

1. **单产物桶**：dbdog-release 上只建一个固定 GitHub Release（tag `artifacts`），
   充当纯文件桶。每个模块只保留 manifest 当前版本的产物，文件名自带模块名、版本、
   架构（如 `dbdog-web-0.4.2-aarch64.tar.gz`）。不按发布打 tag。
2. **main 即发布**：一次发布 = 构建变更模块 → 产物入桶 → 向 main 提交一次
   manifest.tsv + README 版本表更新。发布历史即 manifest 的 git log；main push
   成功后，发布脚本删除该模块不再被 manifest 引用的旧产物。需要回退时按历史提交
   重新构建并发布，而不是长期保留旧二进制。
3. **生产同构机构建**：所有 aarch64 产物在与内网同构的专职编译机
   （麒麟 V10 / aarch64）上构建（ssh 驱动），不用 GitHub Actions。三方件
   （Node/goose/PG/CH）也在这台机器上安装/编译并验证"实际能跑"后打包，
   产物兼容性由同构性背书。例外：agent 的 omnibus 构建需 ≥8c/16GB，
   需临时扩容编译机执行。
4. **manifest.tsv 为唯一权威**：TSV 而非 JSON，纯 bash/awk 可解析，内网零依赖
   （EulerOS 上 jq/python3 均不可假设）。README 版本表只是它的人类可读镜像，
   由发布脚本生成。

## 后果

- 内网升级只需 `git pull` +（按 manifest）curl 下载若干文件，无需理解 tag/Release 语义。
- 变更检测 = 各源仓 HEAD 对比 manifest 记录的 source_sha，源仓零侵入。
- 开发阶段产物桶每模块只保留 manifest 当前引用；部署端发现版本变化时只重新拉取
  对应模块。发布后会自动清理，也可用 prune 先试运行再手工清理孤儿资产。
- Releases 页面没有"发布时间线"可看——接受，人和脚本都只看 manifest/README。
- 构建可重现性弱于 CI（依赖那台机器的环境）——现阶段接受，构建配方全部
  脚本化在 scripts/publish/recipes/，迁移到任何同构机只需装同样工具链。

## 备选方案

- 每次发布打日期 tag、只传变更资产：机制多一层，下载地址散落在多个 tag 下，
  收益只是一个装饰性的 Releases 时间线。
- Git LFS：有配额费用，且内网代理对 LFS 端点的放行不确定。
- GitHub Actions 构建：glibc 兼容风险 + omnibus 调通成本，放弃。
