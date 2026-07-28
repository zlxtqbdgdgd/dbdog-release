# 内网大模型诊断采集指引

这套入口用于人工、不定期触发诊断，不安装定时任务或常驻进程。它会按本机实际安装角色自动覆盖：

- 全家桶：PostgreSQL、ClickHouse、dbdog-server、ddsql-server、dbdog-web、dbdog-mcp；
- Agent：Core、Trace、Process、System Probe；
- Profiling 没有独立进程，由 Agent Core/Trace 与后端健康证据共同覆盖，不是漏采模块。

## 直接执行

全家桶机使用安装 dbdog 的账户：

```bash
cd ~/dbdog-release
./scripts/collect-diagnostics.sh
```

Agent 主机使用 root，才能完整读取 journal 和 coredump：

```bash
cd ~/dbdog-release
sudo ./scripts/collect-diagnostics.sh
```

同机同时安装全家桶和 Agent 时，显式保留全家桶目录；`$HOME` 会在 sudo 前由当前 shell 展开：

```bash
cd ~/dbdog-release
sudo DBDOG_HOME="$HOME/dbdog" \
  DBDOG_DIAGNOSTICS_DIR="$HOME/dbdog/diagnostics" \
  ./scripts/collect-diagnostics.sh
```

命令输出两个 mode `0600` 文件和采集结论：

- `*.internal.txt`：已遮盖常见密码、Token 和 Authorization，但仍可能含主机名、IP、数据库、
  schema、表名和 SQL 业务字面，只能留在内网供内网模型分析；
- `*.issue-card.txt`：只含版本、布尔状态、计数、错误分类和内部报告 SHA-256，不含原始日志、
  主机名、IP 或 SQL；外部反馈只能使用人工复核后的这个文件。

不要把 `*.internal.txt`、`collect-diagnostics.cursor`、env/YAML、数据库连接串或原始日志发到外网。

这些文件都在同一个 `diagnostics` 目录。报告文件名带 UTC 生成时间，报告内部同时记录
`scan_from_epoch`、`scan_until_epoch` 和本轮实际安全处理到的 `processed_until_epoch`；
`collect-diagnostics.cursor` 是下一次运行唯一认可的已提交水位，保存最后成功时间以及每个普通日志的
inode/offset/连续性指纹。不要手工编辑或复制别台机器的游标。

## 给内网大模型的指令

可以把下面整段原样交给内网大模型：

```text
在 dbdog-release 目录执行 ./scripts/collect-diagnostics.sh；如果报告识别到 Agent 且提示权限不完整，
改用 sudo 执行。只读取命令返回的最新 *.internal.txt，不读取或输出任何 env/YAML 原文。

先检查 schema、host_role、scan_from/scan_until、processed_until_epoch、collection_complete、
overall_healthy；若 agent_backlog_pending=true，提示用户再次手工运行以继续排空。再按本机角色检查：
0. release_checkout_commit/dirty、manifest_sha256 和 diagnostic_contract_sha256，确认诊断脚本代际；
1. stack 六个服务的 installed/desired 版本、进程状态、真实轻量 probe、资源和端口；
2. Agent 四服务的当前 PID/NRestarts 增量、status、GaussDB check、journal、kernel/coredump；
3. incremental plain logs 的 reason、backlog_bytes、rotation/truncation 和 error_class；
4. Profiling 没有独立进程，由 Agent Core/Trace 和后端证据覆盖。

把结论分成“当前健康”“采集完整性”“历史/近期线索”三类，不能把历史错误直接说成当前故障。
每条结论写出报告内的字段/章节证据；给出最可能根因、影响模块和正常升级路径，不建议手工修改内网
数据库或配置来绕过发布。若 collection_complete=false，先说明缺失的证据和权限，不猜结论。

将可外传摘要限制为最新 *.issue-card.txt 已有字段；不要复制原始日志、SQL、主机名、IP、数据库、
schema、表名或任何凭证。如果需要更详细的内部分析，另存到同一 diagnostics 目录并设 mode 0600，
文件仍须标记 internal_only=true。
```

## 增量与失败语义

首次成功采集时，journal 回看最近 24 小时；普通文件日志每个文件最多读取末尾 1 MiB。以后每次仍由
用户手工执行，不会在后台自动运行：

- journal 从 `collect-diagnostics.cursor` 的 `completed_until_epoch` 扫描到本次命令刚开始的时刻；
- journal/kernel/coredump 每个 collector 每次最多 5000 行、默认 256 KiB，Agent status/check 也有
  256 KiB 单项上限，整次 Agent 原始捕获默认最多 8 MiB；
- 请求窗口过大时，会按时间前缀找出本轮可以完整捕获的最大整秒子窗口。此时
  `agent_evidence_complete=true`、`agent_window_complete=false`、`agent_backlog_pending=true`，游标只推进到
  `agent_processed_until_epoch`；再次手工执行会从这里继续，直到 backlog 排空；
- 普通文件日志的 inode/offset 水位与 journal 时间水位彼此独立。journal 只完成安全子窗口时，文件日志
  仍可推进到本次冻结的字节上界，所以同一报告可能包含 `processed_until_epoch` 之后写入的文件日志；
  下一次会补齐对应时间段的 journal，允许跨来源时间重叠，但不会因此漏掉任一来源；
- 如果最小一秒仍超过上限，或 journal/coredump 工具、权限、机器结果校验失败，则
  `agent_evidence_complete=false`、`collection_complete=false`，时间游标完全不动；
- 文件日志用设备/inode、字节 offset、开头与游标边界 SHA-256 继续读取，每个文件每次最多
  1 MiB，积压会在后续手工执行中继续；
- rename/create 轮转会先按旧 inode 补读轮转文件余量，再读新文件；copytruncate 即使同 inode
  重长超过旧 offset，也会由前缀/边界指纹发现并从轮转副本补读。候选缺失或不唯一、采集中途轮转/
  短读都会判证据不完整，而不是悄悄推进游标；
- 本次扫描上界在命令开始时冻结，采集期间新写入的数据留给下一次，不会因游标先行而漏掉；
- 游标只在报告和 issue-card 完整原子落盘后更新。服务不健康但证据完整时仍推进安全水位；采集中断、
  journal/coredump 权限不足、日志读取失败或报告写入失败时不推进，避免把“采集失败”误当成功。

报告目录和临时工作目录为 mode `0700`，报告、issue-card、游标为 mode `0600`；并发运行会因锁存在
而 fail closed。脚本的私有临时目录在正常退出、错误或 Ctrl-C 时都会清理。

`healthy` 只表示当前进程与真实轻量 probe，`collection_complete` 只表示证据采集事务是否完整；两者
互不替代。发现错误时优先让内网模型先分析这份完整报告，只有报告明确缺少某项证据时，再追加最小的
只读命令，不再让最终用户来回搬运整份原始日志。
