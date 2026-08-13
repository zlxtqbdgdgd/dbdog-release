# 内网执行卡片 · 采集配置（第二轮）· 四个探针

第一轮结论：**初始化事件根本没发出来**（重启后 9.5 分钟内无任何 dbmhealth 请求），
而 `missed_collection` 每 10 分钟稳定到达——同一个方法、同一条管道是通的。
agent 日志也没有 `Error submitting health event for initialization`。

所以问题被压到很窄的一段：那条事件的调用方要么没被执行到，要么产出的事件不满足
server 的落库条件。下面四个探针互相独立，**做完全部四个**，每个都有明确的判据。

> 第一轮用的 `stream-event-platform --type dbm-health` 10 分钟无输出（期间明明有事件到
> server），说明该工具在这条管道上不可观测，**本轮不要再用它**。

---

## 探针 1（最关键）· 合成事件直投 server，隔离"发不出"还是"存不下"

在 **stack 主机（167）** 上执行。这条绕过 agent，直接把一条格式正确的初始化事件喂给 server：

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  -X POST http://127.0.0.1:8080/api/v2/dbmhealth \
  -H 'Content-Type: application/json' -H 'DD-API-KEY: probe' \
  -d '[{"timestamp":'"$(date +%s000)"',"check_id":"probe:1","category":"gaussdb","name":"initialization","status":"ok","ddagentversion":"7.81.0-dbdog.6","ddagenthostname":"probe-host","data":{"database_instance":"synthetic-probe","ddagenthostname":"probe-host","config":{"host":"127.0.0.1","port":37000},"instance":{"host":"127.0.0.1"}}}]'
```

紧接着查：

```bash
set -a; . ~/dbdog/etc/dbdog-server.env; set +a
~/dbdog/modules/postgresql/current/bin/psql "$PG_DSN" -Atc \
  "select dbms, database_instance, status from t_1.dbm_collection_configs
     where database_instance = 'synthetic-probe'"
grep '"ack dbm-health"' ~/dbdog/logs/dbdog-server.log | tail -2
```

| 结果 | 结论 |
|---|---|
| 查到 `gaussdb\|synthetic-probe\|ok`，且 ack 里 `collection_configs:1` | **server 侧完全正常**，问题 100% 在 agent 侧 → 看探针 2/3/4 |
| 查不到，ack 里 `collection_configs:0` | server 侧有问题，把 ack 那两行带回 |
| HTTP 非 202 | 带回状态码与响应体 |

> 这条会插入一行测试数据，验证完可删：
> `delete from t_1.dbm_collection_configs where database_instance = 'synthetic-probe';`

---

## 探针 2 · gaussdb check 到底有没有在跑 `check()`

在 **DB 主机（163）** 上：

```bash
/opt/dbdog-agent/bin/agent/agent status -c /etc/dbdog-agent 2>/dev/null \
  | grep -A 25 -iE "^\s+gaussdb"
```

要带回这一段的全文，重点看：

- `Total Runs` / `Last Execution Date`——**如果 Total Runs 是 0 或长期不涨，说明 `check()` 没在跑**
  （而异步作业线程仍在发 missed_collection，正好解释第一轮的现象）
- `Metric Samples` / `Events` / `Service Checks` 的数量
- 有没有 `Error` / `Warning` 段落，有就整段带回

同一份输出里再抓一段：

```bash
/opt/dbdog-agent/bin/agent/agent status -c /etc/dbdog-agent 2>/dev/null \
  | grep -B 3 -A 8 -i "Database Monitoring"
```

带回其中各 track（Health / Metadata / Activity / Samples）的计数。

---

## 探针 3 · 实际生效的 gaussdb 实例配置

在 **163** 上：

```bash
/opt/dbdog-agent/bin/agent/agent configcheck -c /etc/dbdog-agent 2>/dev/null \
  | grep -A 40 -i "^=== gaussdb"
```

带回该段（**注意把 password 一行脱敏**）。重点确认：

- `min_collection_interval` 是多少（第一轮的 10 分钟周期怀疑与它有关）
- `dbm` 是不是 true
- `database_identifier` 模板是冒号形还是横线形
- 有没有 `database_instance_collection_interval`

---

## 探针 4 · 一次性跑一次 check，看能否逼出事件

在 **163** 上（会新建一个 check 实例，走一遍 `__init__`）：

```bash
/opt/dbdog-agent/bin/agent/agent check gaussdb -c /etc/dbdog-agent 2>&1 | tail -40
```

跑完立刻在 **167** 上查表和日志：

```bash
set -a; . ~/dbdog/etc/dbdog-server.env; set +a
~/dbdog/modules/postgresql/current/bin/psql "$PG_DSN" -Atc \
  "select dbms, database_instance, observed_at from t_1.dbm_collection_configs
     order by observed_at desc limit 5"
grep '"ack dbm-health"' ~/dbdog/logs/dbdog-server.log | tail -3
```

| 结果 | 结论 |
|---|---|
| 出现 gaussdb 行 | 事件能发、能存；问题在**常驻进程里 check() 的调度**（结合探针 2） |
| 仍无、但 `agent check` 输出里有 dbm-health 相关行 | 事件产出了但没投递，带回那几行 |
| 仍无、且无相关行 | 初始化事件确实没产出，带回 `agent check` 的完整尾部 40 行 |

---

## 汇总要带回的东西

1. 探针 1：两条查询结果 + HTTP 状态码
2. 探针 2：gaussdb check 状态段全文 + Database Monitoring 各 track 计数
3. 探针 3：gaussdb 实例配置段（脱敏）
4. 探针 4：`agent check` 尾部 40 行 + 之后的查表结果

四个探针互相独立，任何一个做不动就跳过做下一个，但**请四个都试**——它们排除的是不同分支。

---

## 内网验证结果（2026-08-07 15:46–15:57 CST）

执行环境同第一轮：163（agent .6，重启于 14:49:15）、167（server 0.1.13）。本轮未重启 agent，
在第一轮重启后约 1 小时执行，期间 agent 已累计 239 次_check()。

### 探针 1 · 合成事件直投 server — **server 侧 100% 正常**

```
=== POST synthetic initialization event (ts=1786088881000) ===
HTTP 202
--- response body (if any) ---

=== query t_1.dbm_collection_configs for synthetic-probe ===
gaussdb|synthetic-probe|ok
=== last 3 ack dbm-health ===
15:28:51  events:1, collection_configs:0
15:38:51  events:1, collection_configs:0
15:48:01  events:1, collection_configs:1     ← 合成事件这一条，落库成功
```

- HTTP 202，无响应体
- 表中查到 `gaussdb|synthetic-probe|ok`
- ack 里 `collection_configs:1` —— **server 正确解析出 collection_config 并落库**

**结论（按探针 1 判读表第一行）：server 侧完全正常，问题 100% 在 agent 侧。** 验证完已清理：
`delete from t_1.dbm_collection_configs where database_instance='synthetic-probe'`（DELETE 1，表回到空）。

### 探针 2 · gaussdb check 在跑 `check()` —— **在跑，但 0 个 health event**

```
gaussdb (1.0.1)
  Instance ID: gaussdb:fe27c9dccf60630e [OK]
  Total Runs: 239
  Metric Samples: Last Run: 7,721, Total: 1,849,000
  Events: Last Run: 0, Total: 0                                      ← 普通 Events 一直是 0
  Database Monitoring Activity Samples: Last Run: 1, Total: 325
  Database Monitoring Metadata Samples: Last Run: 3, Total: 505
  Database Monitoring Query Metrics:    Last Run: 1, Total: 357
  Database Monitoring Query Samples:    Last Run: 1, Total: 466
  dbm-column-statistics: Last Run: 1, Total: 11
  Service Checks: Last Run: 1, Total: 239
  Average Execution Time: 776ms
  Last Execution Date: 2026-08-07 15:48:54.977 CST
```

关键观察：
- `Total Runs: 239`，`Last Execution Date` 是刚才——**check() 一直在跑**（不是 0、不是停滞）
- 776ms 平均执行，每 15 秒一次（与探针 3 的 `min_collection_interval: 15` 吻合）
- Activity / Metadata / Query Metrics / Query Samples / column-statistics / Service Checks **每轮都在产出**（Last Run 各 1）
- **但 `Events: Total: 0`，且状态段里根本没有 "Database Monitoring Health Events" 这一行** ——
  对比探针 4 的一次性 check 输出，那一行在 health event 计数 > 0 时才会出现

**结论：常驻进程里 check() 一直在跑、所有 DBM track 都在送，唯独 health event 从未产出（counter=0/缺行）。**
第一轮怀疑的"check() 没在跑"被排除——它在跑，只是不产 health event。
10 分钟周期的 `missed_collection` 不是 check() 的产物，是异步作业线程发的（所以它独立地在到）。

### 探针 3 · 实际生效的 gaussdb 实例配置 — **配置正常**

```
=== gaussdb check ===
Config for instance ID: gaussdb:fe27c9dccf60630e
dbm: true
dbname: postgres
host: 127.0.0.1
port: 37000
password: "********"                                  ← configcheck 已自动脱敏
database_identifier:
  template: $resolved_hostname-$port                  ← 横线形（.6 修复生效）
min_collection_interval: 15                           ← 15 秒，不是 10 分钟
collect_activity_metrics: true
collect_column_statistics: { collection_interval: 300, enabled: true, ... }
collect_schemas:       { collection_interval: 30,  enabled: true, ... }
collect_settings:      { collection_interval: 30,  enabled: true }
query_samples: { enabled: true, explain_function: public.dbdog_explain_statement }
... (其余 collect_* / max_relations / ignore_databases 等)
```

关键确认：
- `dbm: true` ✓
- `min_collection_interval: 15`（**15 秒，不是 10 分钟**——第一轮怀疑的 10 分钟周期与它无关；
  10 分钟周期是异步 DBM 作业的，不是 check() 的）
- `database_identifier` 模板是横线形 `$resolved_hostname-$port`（.6 修复生效）
- **没有 `database_instance_collection_interval` 这个键**（configcheck 输出里未出现）
- password 一行 configcheck 已自动脱敏为 `"********"`

### 探针 4 · 一次性 check — **产出了 1 个 health event，但没投递到 server**

163 上 `agent check gaussdb`（新建 check 实例，走一遍 `__init__`）尾部 40 行关键段：

```
gaussdb (1.0.1)
  Instance ID: gaussdb:fe27c9dccf60630e [OK]
  Total Runs: 1
  Metric Samples: Last Run: 7,500, Total: 7,500
  Events: Last Run: 0, Total: 0
  Database Monitoring Health Events: Last Run: 1, Total: 1     ← ★ 一次性 check 产出了 1 个 health event
  Database Monitoring Metadata Samples: Last Run: 1, Total: 1
  Service Checks: Last Run: 1, Total: 1
  Average Execution Time: 847ms
  Last Execution Date: 2026-08-07 15:49:17.592 CST
```

紧接着在 167 上查表 + 日志（15:49:17 之后约 5–8 分钟）：

```
=== t_1.dbm_collection_configs (latest 5) ===
gaussdb|synthetic-probe|ok|2026-08-07 15:48:01+08     ← 只有探针 1 的合成行，没有 linux163-37000

=== last 5 ack dbm-health ===
15:18:51  events:1, collection_configs:0
15:28:51  events:1, collection_configs:0
15:38:51  events:1, collection_configs:0
15:48:01  events:1, collection_configs:1              ← 探针 1 合成事件
15:48:51  events:1, collection_configs:0              ← 10 分钟周期 missed_collection

=== 15:49 之后 163 发来的所有请求（共 435 条）路径分布 ===
/api/v2/logs, /api/v2/dbmmetrics, /api/v1/collector, /api/v2/dbmactivity,
/api/v1/check_run, /api/v2/databasequery, /api/v1/connections, /api/intake/metrics/v3/series
★ 没有 /api/v2/dbmhealth —— 一次性 check 的 health event 没有产生任何 dbmhealth POST
```

**结论（按探针 4 判读表第二行）：事件产出了（counter=1）但没投递。** 一次性 check 内部计数了 1 个
"Database Monitoring Health Events"，但没有触发任何 `/api/v2/dbmhealth` POST ——
要么该事件进了某队列但进程退出前来不及 flush（一次性进程寿命短），要么 health event 走的投递路径
在一次性模式下不激活。表里始终没有 `linux163-37000` 行。

### 163 agent.log 里没有任何 health event 痕迹

```
grep -iE "health.event|dbm.health|submitting health|initialization|collection_config|missed_collection" /var/log/dbdog-agent/agent.log
→ 仅 tagger 的 "has just finished initialization" 无关行，0 条 health/dbm-health/initialization 相关
grep -iE "error.*health|health.*error|failed.*health|health.*fail" /var/log/dbdog-agent/agent.log
→ 0 条
```

forwarder 成功日志里也看不到 `/api/v2/dbmhealth`（只有 `/intake/`、`/api/v1/check_run`、
`/api/v1/collector`、`/api/intake/metrics/v3/series`）——而 server 侧明明每 10 分钟收到一条
来自 163 的 dbmhealth POST，说明 dbmhealth 走的不是 forwarder 那条成功日志路径（或被 500 条
抽稀吞了）。

---

## 综合判读（四个探针合起来）

| 分支 | 探针 | 排除/坐实 |
|---|---|---|
| server 存不下 | 探针 1 | **排除**。合成初始化事件 HTTP 202、ack `collection_configs:1`、表里查得到 |
| check() 没在跑 | 探针 2 | **排除**。Total Runs 239、Last Execution 刚刚、各 DBM track 每轮都在产 |
| 配置错（dbm/min_interval/identifier） | 探针 3 | **排除**。dbm=true、min_collection_interval=15s、identifier 横线形 |
| 一次性 check 能否逼出事件 | 探针 4 | **半坐实**：counter=1 产出了，但没投递（无 dbmhealth POST、表里无行） |

**核心矛盾**：
- **常驻进程**（探针 2）：check() 跑了 239 次，`Events: Total: 0`，状态段根本没有
  "Database Monitoring Health Events" 行 —— **health event 从未产出**
- **一次性 check**（探针 4）：1 次运行，`Database Monitoring Health Events: Last Run: 1, Total: 1`
  —— **产出了 1 个，但没投递到 server**（15:49 后 163 发了 435 条请求，没有一条是 dbmhealth）

即：**health event 的"产出"和"投递"两个环节都有问题**。
- 常驻进程里 check() 跑了 239 次一个都没产出（counter=0/缺行）
- 一次性 check 产出了 1 个却没投递（无 dbmhealth POST）

第一轮看到的"10 分钟周期 events:1, collection_configs:0"是异步作业线程发的 `missed_collection`，
不是 check() 的初始化事件——它与本问题无关，只是恰好走同一条 dbmhealth 管道、每 10 分钟准点到。

**问题被压到 agent 侧 health event 的产出/投递代码路径**：为什么常驻进程的 check() 不产
initialization health event（而一次性 check 会产）？为什么一次性 check 产了却没通过
dbmhealth POST 投递？需要公网侧模型看 agent 的 DBM health event 提交代码（产出条件 + 投递队列/flush 逻辑）。

### 顺带：持续漏拍问题（第一轮 C 项）仍未定位

`missed_collection` 每 10 分钟一条持续 23+ 小时（从 2026-08-06 16:18 server 升级到 0.1.12 后开始），
全部 `events:1, collection_configs:0`。本轮未抓到事件原文（`stream-event-platform --type dbm-health`
第一轮已证不可观测，本轮按卡片要求未再用），**`data.job_name` 仍缺**。若公网侧需要，
下一轮可考虑直接从 agent 侧 grep missed_collection 的产出函数名，或从 server 侧把
dbmhealth 请求体落盘一条来看。

### 已做的清理

- 探针 1 插入的 `synthetic-probe` 测试行已删除（`DELETE 1`），表回到空状态

### 要带回公网侧的关键证据

1. 探针 1：`HTTP 202` + `gaussdb|synthetic-probe|ok` + ack `collection_configs:1` → server 正常
2. 探针 2：`Total Runs: 239` / `Events: Total: 0` / 无 "Database Monitoring Health Events" 行 / 各 DBM track Last Run: 1
3. 探针 3：`dbm: true` / `min_collection_interval: 15` / `database_identifier: $resolved_hostname-$port` / 无 `database_instance_collection_interval`
4. 探针 4：一次性 check `Database Monitoring Health Events: Last Run: 1, Total: 1`，但 15:49 后 163 发 435 条请求**无一条 dbmhealth**，表无 `linux163-37000` 行
5. agent.log：0 条 health event / dbm.health / initialization 相关，0 条 health event 错误