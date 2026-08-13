# 内网执行卡片 · 采集配置空白的收尾验证（2026-08-06 起）

公网侧已定位到最可能的原因，需要内网做一次**决定性验证**。全程约 3 分钟。

## 背景（一句话）

「采集配置」那页的数据来自 Agent 的**初始化健康事件**，该事件每个 agent 进程**只发一次**
（6 小时去抖，发送方拿不到投递结果）。8-06 那次 server 从 0.1.8 升到 0.1.12 期间它必然送不达
（旧版收下不落库、重启窗口连不上），配额已消耗 → 6 小时内不再重发 → 页面一直空着。
公网 dev 环境实测：**agent 重启后 5~7 秒即落库**。

所以预期是：**重启 agent 就好**。下面就是验证这一点。

---

## A. 决定性验证（先做这个）

**A1. 在被采集的 DB 主机（linux163）上重启 agent**

```bash
systemctl restart dbdog-agent
```

**A2. 等 60 秒，在 stack 主机（linux167）上查表**

```bash
set -a; . ~/dbdog/etc/dbdog-server.env; set +a
PSQL=~/dbdog/modules/postgresql/current/bin/psql
$PSQL "$PG_DSN" -Atc "select dbms, database_instance, agent_version, status, observed_at
                        from t_1.dbm_collection_configs order by observed_at desc"
```

**A3. 同时看 server 有没有真的存进去**

```bash
grep '"ack dbm-health"' ~/dbdog/logs/dbdog-server.log | tail -5
```

### 判读

| 结果 | 结论 | 要带回什么 |
|---|---|---|
| A2 出现 gaussdb 那一行，且 `collection_configs` ≥ 1 | **结案**：根因是升级时序，不是功能故障 | 带回 A2 那一行即可 |
| A2 仍为空，但 A3 里 `collection_configs:0`、`events` ≥ 1 | 事件到了却被摄入边界丢弃 | 做下面的 B，并带回 B 的完整事件体 |
| A3 完全没有新的 ack 行 | 事件根本没发出来 | 带回 `grep -i "health event for initialization" /var/log/dbdog-agent/agent.log \| tail` |

---

## B. 抓一条事件原文（A 判读需要时才做；也用于查 C）

在 linux163 上开着，**最多等 10 分钟**会出一条：

```bash
/opt/dbdog-agent/bin/agent/agent stream-event-platform --type dbm-health -c /etc/dbdog-agent
```

带回这些字段（整条 JSON 更好，注意脱敏）：

- `name`（是 `initialization` 还是 `missed_collection`）
- `category`
- `data.database_instance`
- `data` 里有没有 `config` 这个键
- 若是 `missed_collection`：`data.job_name`、`data.elapsed_time`、`data.expected_collection_interval`

---

## C. 另一个独立问题：有作业在持续漏拍

8-06 的 server 日志里，`ack dbm-health` **每 10 分钟一条、连续三小时没停**。那是
`missed_collection` 事件——**有个 DBM 异步采集作业一直在错过采集周期**。它跟采集配置无关，
是独立的采集健康问题，此前没人跟进。

B 抓到的事件里 `data.job_name` 就是漏拍的作业名，带回来即可定位。

---

## D. 顺带确认环境指纹

```bash
/opt/dbdog-agent/bin/agent/agent version -c /etc/dbdog-agent
```

带回版本号。若还不是 `7.81.0-dbdog.6`，说明 agent 尚未升级到含修复的版本——
但注意 **A 的验证与是否升级无关**，重启就该出数据。

---

## 附：升级 agent 到 dbdog.6 时的顺序铁律

dbdog.6 把实例标识分隔符从 `:` 改成了 `-`（`linux163:37000` → `linux163-37000`），
在 server 侧会变成两个实例。清理历史数据必须按这个顺序，反了会白删：

1. 先把**所有**被采集主机的 agent 升完并重启；
2. 确认新标识在写、冒号形的实例停止增长；
3. 再跑 `scripts/one-off/clean-colon-identifier-data.sh`（不带 `--apply` 只统计）。

---

## 内网验证结果（2026-08-07 14:48–15:12 CST）

### 执行环境

| 项 | 值 |
|----|----|
| 被采集 DB 主机 | 10.44.136.163（linux163，aarch64，root） |
| stack 主机 | 10.44.136.167（linux167，dbdog 用户） |
| agent 版本 | `Agent 7.81.0-dbdog.6 - Commit: 6ee3c89953 - Serialization version: v5.0.198 - Go version: go1.26.4` |
| server 版本 | 0.1.13 |
| agent 重启前 ActiveEnterTimestamp | `Fri 2026-08-07 12:45:55 CST`（.6 升级时启动的，已运行约 2 小时） |
| agent 重启前 NRestarts | 0 |
| 重启执行时间 | 14:49:15 CST（`systemctl restart dbdog-agent`，24 秒完成，active） |

### A1. 重启 agent

```
14:48:51  (重启前)
14:49:15  systemctl restart dbdog-agent 完成
14:49:15  active
```

agent health（重启后）：
```
Agent health: PASS
=== 16 healthy components ===
ad-config-provider-do-query-actions, ad-config-provider-dsm-kafka-actions, ad-processlistener,
ad-scheduler-controller, ad-servicelistening, aggregator, collector-queue-15s, forwarder,
healthcheck, healthcheck, logs-agent, tagger-store, tagger-workloadmeta, workloadmeta-process,
workloadmeta-puller, workloadmeta-store
```

### A2. 重启后查表（等 60 秒 + 额外 2 分钟，共 5 分钟后）

```
=== 14:51:25 (重启后 65 秒) ===
 dbms | database_instance | agent_version | status | observed_at
------+-------------------+---------------+--------+-------------
(0 rows)
count=0

=== 14:54:13 (重启后 5 分钟) ===
（表仍为 0 行）
```

**表从重启前到现在始终为 0 行。**

### A3. server 日志 ack dbm-health

重启前最后 10 条 ack（全部 `events:1, collection_configs:0`，每 10 分钟一条）：
```
{"time":"2026-08-07T13:05:31.53593208+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}
{"time":"2026-08-07T13:15:31.55576586+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}
...（每 10 分钟一条）...
{"time":"2026-08-07T14:45:31.73108524+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}
{"time":"2026-08-07T14:48:51.75674089+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}  ← 重启前最后一条
```

重启后新增的 ack（14:49 之后）：
```
{"time":"2026-08-07T14:58:51.77284125+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}  ← 重启后第一条，距重启约 9.5 分钟
{"time":"2026-08-07T15:08:51.79019431+08:00","level":"INFO","msg":"ack dbm-health","events":1,"collection_configs":0}  ← 重启后第二条
```

**重启后只出现了每 10 分钟一条的周期性 ack（events:1, collection_configs:0），没有出现初始化事件对应的 ack（预期应该有 collection_configs≥1）。**

#### server 日志中 14:58:51 ack 的完整上下文

```
{"time":"2026-08-07T14:58:51.77067053+08:00","msg":"ingest dbm-samples","track":"dbm-samples","accepted":0,"dropped":1,"deduped":0}
{"time":"2026-08-07T14:58:51.77069559+08:00","msg":"http request","method":"POST","path":"/api/v2/databasequery","status":202,"bytes":60}
{"time":"2026-08-07T14:58:51.77180375+08:00","msg":"ingest dbm-metadata","track":"dbm-metadata","accepted":0,"dropped":1,"deduped":0,"unknown_instance":0}
{"time":"2026-08-07T14:58:51.77181904+08:00","msg":"http request","method":"POST","path":"/api/v2/dbmmetadata","status":202,"bytes":60}
{"time":"2026-08-07T14:58:51.77229111+08:00","msg":"ingest dbm-activity","track":"dbm-activity","accepted":0,"dropped":0,"deduped":0}
{"time":"2026-08-07T14:58:51.77230487+08:00","msg":"http request","method":"POST","path":"/api/v2/dbmactivity","status":202,"bytes":60}
{"time":"2026-08-07T14:58:51.77284125+08:00","msg":"ack dbm-health","events":1,"collection_configs":0}
{"time":"2026-08-07T14:58:51.77286019+08:00","msg":"http request","method":"POST","path":"/api/v2/dbmhealth","status":202,"bytes":0,"remote":"10.44.136.163:36900"}
```

关键观察：
- `POST /api/v2/dbmhealth` 来自 10.44.136.163（agent），status 202 — **dbm-health 请求确实到了 server**
- `ack dbm-health` 显示 `events:1, collection_configs:0` — server 从该请求中提取出 1 个事件，但 collection_configs 为 0
- `ingest dbm-metadata` 显示 `dropped:1, unknown_instance:0` — 有一个 dbm-metadata 被丢弃，但不是因为 unknown_instance

#### 重启后 14:49–14:58 之间没有任何 dbmhealth 请求

```
=== 14:49 后所有 POST /api/v2/dbmhealth ===
14:58:51  POST /api/v2/dbmhealth  202  remote=10.44.136.163:36900
15:08:51  POST /api/v2/dbmhealth  202  remote=10.44.136.163:39078
```

agent 重启在 14:49:15，但第一条 dbmhealth 请求在 14:58:51（约 9.5 分钟后）。**重启时没有初始化事件发出来**，只有 10 分钟周期的 missed_collection 到了。

#### server 日志全量 ack dbm-health 统计

- 旧格式（`bytes":2`，无 events/collection_configs 字段）：从 2026-07-28 09:31 开始，共 2220 条
- 新格式（有 events/collection_configs 字段）：从 2026-08-06 16:18 开始（server 升级到 0.1.12 后），全部 `collection_configs:0`
- **新格式里 collection_configs > 0 的条数：0**（从未有任何初始化事件成功落库）

### B. 抓事件原文

在 linux163 上执行（15:00:01 启动，等待 10 分钟）：
```
/opt/dbdog-agent/bin/agent/agent stream-event-platform --type dbm-health -c /etc/dbdog-agent
```

结果：**10 分钟内无任何输出**（空）。agent 日志在 15:00:01 有一行：
```
2026-08-07 15:00:01 CST | CORE | INFO | (comp/api/api/utils/stream/stream.go:30 in func2) | Got a request to stream event platform payloads.
```

但未输出任何事件 JSON。`stream-event-platform` 未捕获到 dbm-health 事件体。

### agent 日志中 initialization 事件痕迹

```
grep -ci "health event for initialization" /var/log/dbdog-agent/agent.log
0

grep -i "dbm.health\|health.event\|stream-event\|event-platform\|collection_config" /var/log/dbdog-agent/agent.log
（无匹配，仅有 tagger 的 "has just finished initialization" 无关行）
```

**agent 日志里没有任何 dbm-health 初始化事件的痕迹。**

### agent forwarder 正常工作

```
2026-08-07 14:49:18 CST | CORE | INFO | Successfully posted payload to "http://10.44.136.167:8080/intake/" (202 Accepted)
2026-08-07 15:12:47 CST | CORE | INFO | Successfully posted payload to "http://10.44.136.167:8080/api/intake/metrics/v3/series" (202 Accepted)
```

GaussDB check 正常调度（statement_samples、execution plans 等 WARN 均为业务噪声，非致命）。

### C. 持续漏拍

server 日志里 `ack dbm-health` **每 10 分钟一条**，从 2026-08-06 16:18（server 升级到 0.1.12 后）开始持续至今（2026-08-07 15:08），连续 23 小时没停。全部 `events:1, collection_configs:0`。

由于 B 未抓到事件原文，**无法带回 `data.job_name`**（漏拍的作业名）。`stream-event-platform --type dbm-health` 在 10 分钟窗口内没有输出任何事件 JSON。

### D. 环境指纹

```
Agent 7.81.0-dbdog.6 - Commit: 6ee3c89953 - Serialization version: v5.0.198 - Go version: go1.26.4
```

agent 已在 .6（含 database_identifier 分隔符从 `:` 改 `-` 的修复）。**A 的验证与版本无关——重启就该出数据，但重启后仍未出数据。**

---

### 判读

CARD 的 A 判读表里，本次结果落在第二行和第三行的混合：

- **A2 仍为空**（0 行）
- **A3 有新的 ack 行**（14:58:51, 15:08:51），但全部 `collection_configs:0, events:1`
- **重启后 14:49–14:58 之间没有 dbmhealth 请求**（初始化事件没有发出来）
- **10 分钟周期的 missed_collection 事件正常到达**（POST /api/v2/dbmhealth, 202, events:1）
- **server 从每条 dbm-health 请求中提取出 1 个事件但 collection_configs=0**（事件到了但不含 config 数据，或 server 未提取出 config）
- **agent 日志无 "health event for initialization"**（初始化事件根本没发出来）
- **stream-event-platform 未捕获到事件原文**（10 分钟内无输出）

综合：**初始化事件在 agent 重启时没有发出来**（不是"事件到了被丢弃"，而是"根本没发"）。只有 10 分钟周期的 missed_collection 事件在正常发送，但 server 从中提取 collection_configs=0。公网 dev 环境"agent 重启后 5~7 秒即落库"的预期，在内网 163/167 环境上未复现。