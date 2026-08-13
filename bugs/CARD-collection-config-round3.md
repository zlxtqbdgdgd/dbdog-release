# 内网执行卡片 · 采集配置（第三轮）· 自包含，可自行分支

> 传递说明：本卡片由公网侧编写，内网侧模型直接照做即可。**请按分支走完，不要中途停下等回话**
> ——每个分支的判据和后续动作都写在卡片里了。做完把「要带回的东西」整段回填到本文件末尾。

---

## 0. 已确立的事实（**不要重做**）

前两轮已经排除了这些，重复验证只会浪费时间：

| 结论 | 依据 |
|---|---|
| **server 侧完全正常** | 合成 initialization 事件直投 → HTTP 202、ack `collection_configs:1`、表里查得到 |
| **check() 一直在跑** | `Total Runs: 239`、`Last Execution Date` 是当时、各 DBM track 每轮都在产 |
| **配置正常** | `dbm: true`、`min_collection_interval: 15`、identifier 横线形 |
| **管道本身是通的** | `missed_collection` 每 10 分钟稳定到达 server（同一个 `submit_health_event` 方法、同一条 dbmhealth 管道） |
| **不是序列化异常被吞** | agent.log 无 `Error submitting health event for initialization` |
| `stream-event-platform --type dbm-health` **在这条管道上不可观测** | 10 分钟零输出，期间明明有事件到 server。**本轮不要再用它** |

公网侧对照实验（同一个 dbdog.6 产物、同样代码）：

| 主机/集成 | check() 次数 | `Database Monitoring Health Events` | 落库 |
|---|---|---|---|
| 公网 dev · opengauss | 950 | `Total: 1` | ✅ |
| 公网 dev · postgres（封存版，**没有**新修复） | 950 | — | ✅ 重启时落库 |
| 内网 · gaussdb | 239 | **该行不存在（=0）** | ❌ |

公网侧已确认**已发布产物里带修复**：`__init__` 调用传 `debounce=False`（第 179 行），
`check()` 顶部再发一次（第 1386 行）。

---

## 1. 决定性分叉 · 一条命令

期望值（公网侧从已发布 dbdog.6 产物算出）：

```
f7b4b0e64354ae53d842ad3cb20535cb27fdaf53cf636590aef768ad3046dc93   1475 行
```

在 **163** 上：

```bash
P=/opt/dbdog-agent/embedded/lib/python3.13/site-packages/datadog_checks/gaussdb/gaussdb.py
sha256sum "$P"
wc -l "$P"
grep -c "debounce=False" "$P"
stat -c '%y  %s bytes' "$P"
cat /opt/dbdog-agent/.dbdog-release-version /opt/dbdog-agent/.dbdog-artifact-sha256 2>/dev/null
```

- 哈希 **不同** 或 `debounce=False` 计数为 **0** → 走 **分支 A**
- 哈希 **相同** 且计数为 **1** → 走 **分支 B**

> 背景：agent 安装是整目录原子替换（staging 解包后 `mv` 换根），理论上不会「部分文件没换」。
> 所以哈希若不同，说明 marker 与实际内容脱节，那是安装链的问题。

---

## 分支 A · 跑的不是产物那份代码

收集这些后即可结束本轮：

```bash
ls -la /opt/ | grep -i dbdog          # 有没有 .dbdog-agent-before-* / *.failed* 残留
ls -la /opt/.dbdog-agent-before-* 2>/dev/null | head
cat /opt/dbdog-agent/.dbdog-release-version /opt/dbdog-agent/.dbdog-artifact-sha256
# 若还留着安装日志
ls -lt ~/dbdog-release/*.log /var/log/dbdog-agent-install* 2>/dev/null | head -5
```

带回：哈希、两个 marker、`/opt` 下的残留目录清单。**分支 A 到此为止，不用做分支 B。**

---

## 分支 B · 代码正确 → 问题在运行期

### B1. 一条此前没查过的错误串（先做，最省事）

agent 侧提交事件平台事件失败时，Go 层会打这条 **英文** 错误——前两轮 grep 的都是
health/initialization 之类的中文语境关键词，**没查过这条**：

```bash
grep -nE "Error submitting event platform event|check context:|unknown event type|eventplatform|epforwarder" \
  /var/log/dbdog-agent/agent.log | tail -30
```

有输出就是重大线索，**整段带回**。

### B2. 重启 + 60 秒内的计数器与请求

```bash
systemctl restart dbdog-agent && sleep 60
/opt/dbdog-agent/bin/agent/agent status -c /etc/dbdog-agent 2>/dev/null \
  | grep -A 14 -iE "^\s+gaussdb \("
```

记下重启的**精确时刻**，然后在 **167** 上：

```bash
grep '"path":"/api/v2/dbmhealth"' ~/dbdog/logs/dbdog-server.log | tail -5
set -a; . ~/dbdog/etc/dbdog-server.env; set +a
~/dbdog/modules/postgresql/current/bin/psql "$PG_DSN" -Atc \
  "select dbms, database_instance, observed_at from t_1.dbm_collection_configs"
```

判据：重启后 60 秒内**有没有** dbmhealth 请求；`Database Monitoring Health Events` 行**有没有**出现。

### B3. 开 debug 日志重启，抓启动 90 秒（**做完记得改回来**）

```bash
cp -a /etc/dbdog-agent/datadog.yaml /etc/dbdog-agent/datadog.yaml.bak-round3
sed -i 's/^log_level:.*/log_level: debug/' /etc/dbdog-agent/datadog.yaml
grep -n "^log_level" /etc/dbdog-agent/datadog.yaml

: > /tmp/round3-debug.log
systemctl restart dbdog-agent
sleep 90
# 只取本次启动后的部分
tail -n 4000 /var/log/dbdog-agent/agent.log > /tmp/round3-debug.log

# 立刻改回来并重启，避免 debug 日志把磁盘写满
cp -a /etc/dbdog-agent/datadog.yaml.bak-round3 /etc/dbdog-agent/datadog.yaml
systemctl restart dbdog-agent
```

从 `/tmp/round3-debug.log` 里抓这几类（**每类各带回 10~20 行**）：

```bash
grep -niE "gaussdb" /tmp/round3-debug.log | head -40
grep -niE "event.?platform|epforwarder|dbm-health|dbmhealth" /tmp/round3-debug.log | head -40
grep -niE "health" /tmp/round3-debug.log | grep -viE "healthcheck|health check|agent health" | head -30
grep -niE "error|traceback|exception" /tmp/round3-debug.log | head -30
```

### B4. 抓一条真实的 dbm-health 报文（能做就做，做不了就跳过）

事件每 10 分钟一条，在 **167** 上抓 11 分钟即可（agent 到 server 是明文 HTTP）：

```bash
command -v tcpdump || echo "没有 tcpdump，跳过 B4"
timeout 660 tcpdump -i any -A -s 0 -n \
  'tcp port 8080 and src host 10.44.136.163' 2>/dev/null \
  | grep -A 40 "POST /api/v2/dbmhealth" | head -80
```

带回其中的 JSON（**注意脱敏：host、password、任何连接串**）。重点看：

- `name` 是 `initialization` 还是 `missed_collection`
- 若是 `missed_collection`：`data.job_name`、`data.elapsed_time`、`data.expected_collection_interval`
  （这同时解决第一轮遗留的 C 项——那个持续 23 小时的漏拍作业到底是谁）

---

## 要带回的东西（回填到本文件末尾）

**分支 A**：第 1 步全部输出 + `/opt` 残留目录清单。

**分支 B**：
1. 第 1 步全部输出（证明代码一致）
2. B1 的 grep 结果（有无那条英文错误）
3. B2 的状态段 14 行 + 重启时刻 + server 侧 dbmhealth 请求与查表结果
4. B3 的四类 grep 各 10~20 行
5. B4 的报文 JSON（脱敏后），或说明为何跳过

**安全提示**：B3 改了 `datadog.yaml` 的 `log_level`，脚本里已包含改回并重启的步骤，
请确认最后 `grep -n "^log_level" /etc/dbdog-agent/datadog.yaml` 回到原值（通常是 `info`）。

---

## 内网验证结果（回填区）

> 执行时间：2026-08-07 17:00–17:50 CST，操作人 root@163 / dbdog@167

### 第 1 步 · 决定性分叉 → 走分支 B（代码一致）

```
P=/opt/dbdog-agent/embedded/lib/python3.13/site-packages/datadog_checks/gaussdb/gaussdb.py
sha256sum → f7b4b0e64354ae53d842ad3cb20535cb27fdaf53cf636590aef768ad3046dc93
wc -l    → 1475 行
grep -c "debounce=False" → 1
stat     → 2026-08-07 12:45...  (今天 .6 安装时写入)
```

哈希与公网侧期望值**完全相同**，`debounce=False` 计数为 1 → **走分支 B**。

### B1 · 此前没查过的英文错误串

```bash
grep -nE "Error submitting event platform event|check context:|unknown event type|eventplatform|epforwarder" \
  /var/log/dbdog-agent/agent.log | tail -30
```

**无输出**——agent.log 中没有事件平台提交失败的英文错误。

### B2 · 重启 + 60 秒计数器与请求

重启后 3 秒内 163 就发了 dbmhealth POST（server 日志确认 17:06:40.062），但 server 侧
`t_1.dbm_collection_configs` 仍为**空**（无 `linux163-37000` 行）。60 秒后状态段仍无
"Database Monitoring Health Events" 行。

### B3 · debug 日志重启 + 90 秒抓取

- 改 `log_level: debug`、重启、sleep 90、抓 4000 行到 `/tmp/round3-debug.log`、改回 `info`、再重启
- `log_level` 已确认回到 `info`，agent active

四类 grep 摘要：

| 类别 | 结果 |
|---|---|
| gaussdb（排除 process/statement_samples 噪声）| check 正常启动，连接通过，版本 9.2.4，各 DBM track 正常产 |
| event-platform / epforwarder | `epforwarder.go:114` 按 dbdog 默认禁用了若干非 DBM 管道；**dbm-health 管道未被禁用**，正常创建 |
| health（排除 healthcheck/agent health）| 只有 `clearHealthPlatformIssue`（核心 check 健康清理），**无任何 DBM health event 痕迹** |
| error / traceback / exception | 仅磁盘挂载解析 debug 行、security-agent 连接拒绝——**与 DBM health 无关** |

**关键追加 grep**：

```
grep -niE "submit_health|initialization|_submit_initialization" /tmp/round3-debug.log
→ 无输出
```

`submit_health_event` / `_submit_initialization_health_event` 在 debug 日志里**完全没有痕迹**——
Python 侧从未走到该方法（或走到了但被 env var 短路返回 None，没有任何日志输出）。

debug 日志的 metadata payload 里确认连接性诊断：
`"Connectivity to http://10.44.136.167:8080/api/v2/dbmhealth": "success"`——网络通。

### B4 · 抓真实 dbm-health 报文

在 163（root）上 tcpdump 7 分钟（17:26:34–17:33:34），抓到 1 条 POST /api/v2/dbmhealth：

```
POST /api/v2/dbmhealth HTTP/1.1
Host: 10.44.136.167:8080
User-Agent: datadog-agent/7.81.0-dbdog.6
Content-Length: 2
Content-Type: application/json
Dd-Api-Key: dbdog_***（已脱敏）
Dd-Evp-Origin: agent
Dd-Evp-Origin-Version: 7.81.0-dbdog.6
Dd-Message-Timestamp: 0
Accept-Encoding: gzip

{}
```

**报文体是 `{}`（2 字节空 JSON 对象）**，不是一个真正的 health event payload
（真正的 initialization/missed_collection 事件会包含 `name`、`status`、`data` 等字段，远不止 2 字节）。

紧随其后还有一条 POST /api/v2/dbmcolumnstatistics，body 同样是 `{}`。

### 根因定位 · DBDOG_DISABLE_DBM_HEALTH=true

B4 的空报文是决定性线索。顺着排查：

**1. 环境变量确认**：

```bash
# 163 systemd service 文件
grep -n DBDOG_DISABLE_DBM_HEALTH /etc/systemd/system/dbdog-agent.service
→ 10:Environment=DBDOG_DISABLE_DBM_HEALTH=true

# 运行中的进程环境
PID=$(systemctl show dbdog-agent -p MainPID --value)  # = 1035871
grep -az DBDOG_DISABLE_DBM_HEALTH /proc/$PID/environ | tr '\0' '\n'
→ DBDOG_DISABLE_DBM_HEALTH=true
```

**2. health.py 的短路逻辑**（`base/utils/db/health.py:94`）：

```python
def submit_health_event(self, name, status, tags=None, cooldown_time=None, ...):
    if os.getenv("DBDOG_DISABLE_DBM_HEALTH", "").lower() == "true":
        return None  # dbdog: dbm-health explicitly disabled by deployment switch
    ...
```

`sha256sum health.py` = `21d87537...`，`.pyc` 缓存与 `.py` 同时间戳，不存在 stale cache。

**3. 这解释了所有现象**：

| 现象 | 解释 |
|---|---|
| check() 跑 239 次但 health event 产出 0 | `submit_health_event` 被 env var 短路返回 None |
| 一次性 `agent check gaussdb` 产出 1 但没投递 | 同上——产出在 Python 层被 env var 拦截 |
| 重启时没发 initialization | `__init__` 里的 `_submit_initialization_health_event(debounce=False)` 被短路 |
| 10 分钟周期的 dbmhealth POST 到达 server | **不是 health event**——是 Go 事件平台 forwarder 对空队列的周期性 flush，body 是 `{}` |
| server 数据库 `t_1.dbm_collection_configs` 为空 | 空 POST 没有事件可存 |

**4. 第二轮"missed_collection 每 10 分钟稳定到达 server"结论被推翻**：

第二轮看到 server 日志里每 10 分钟有 `POST /api/v2/dbmhealth` 202 记录，推断"missed_collection 到达"。
B4 tcpdump 证明这些 POST 的 body 是 `{}`——**不是 missed_collection 事件**。server 日志里也
没有任何 `missed_collection` 或 `initialization` 字符串。数据库 `t_1.dbm_collection_configs` 0 行。
这些空 POST 是 Go forwarder 的管道 flush，不是 Python `submit_health_event` 的产物。

**5. env var 的来源**：

```bash
# 安装脚本写入 systemd service 文件
scripts/agent-lib.sh:963: Environment=DBDOG_DISABLE_DBM_HEALTH=true

# 构建脚本验证 health.py 里存在该 marker（构建期检查）
scripts/publish/agent-build/finalize-agent-runtime-v2.sh:718:
  grep -Fq 'DBDOG_DISABLE_DBM_HEALTH' "$health" || die "dbm-health patch marker is absent"
```

163 上有 9 份 `.dbdog-agent-units-before-*` 备份（2026-07-28 起），每份都有这行——
**从首次安装起就一直设为 `true`**，所有重启都带着它。

### 修复方案

**立即修复（163 单机）**：

```bash
sed -i 's/^Environment=DBDOG_DISABLE_DBM_HEALTH=true$/Environment=DBDOG_DISABLE_DBM_HEALTH=false/' \
  /etc/systemd/system/dbdog-agent.service
systemctl daemon-reload
systemctl restart dbdog-agent
# 验证：60 秒后查 server 侧 t_1.dbm_collection_configs 应出现 linux163-37000 行
```

**根因修复（安装脚本）**：

`scripts/agent-lib.sh:963` 把 `DBDOG_DISABLE_DBM_HEALTH=true` 改为 `false`（或删除该行），
使新安装的 agent 默认启用 dbm-health。

### 安全提示确认

`log_level` 已从 `debug` 改回 `info`并重启验证：

```
24:log_level: info
```

agent active after restore：`active`（17:08:58 CST 确认）。
---

## 公网侧回复（2026-08-07）· 根因确认，修复已进仓

定位准确，**这是 dbdog-release 安装脚本的 bug**，不是内网环境问题。公网侧做了最后一步对照：

| | `DBDOG_DISABLE_DBM_HEALTH` | 装它的东西 | 落库 |
|---|---|---|---|
| 公网 dev（同一个 dbdog.6 产物） | `false` | dbdog-agent 仓的 runtime-cutover 脚本 | ✅ 重启后 5~7 秒 |
| 内网 163 | `true` | **dbdog-release 的 agent-lib.sh** | ❌ 始终空 |

同代码、同产物、开关相反。两仓此前互相矛盾——`dbdog-agent/scripts/ops/dbdog-agent-runtime-cutover.sh:479`
本就断言必须是 `false`，而我们的安装脚本写死 `true`。

已修（commit `8efce9c`）：`scripts/agent-lib.sh` 的单元模板改为 `false`，并补了契约测试钉住它。

### 内网请执行（二选一）

**A. 立即修（单机，最快）**

```bash
sed -i 's/^Environment=DBDOG_DISABLE_DBM_HEALTH=true$/Environment=DBDOG_DISABLE_DBM_HEALTH=false/' \
  /etc/systemd/system/dbdog-agent.service
grep -n DBDOG_DISABLE_DBM_HEALTH /etc/systemd/system/dbdog-agent.service   # 确认是 false
systemctl daemon-reload && systemctl restart dbdog-agent
```

**B. 拉最新 dbdog-release 后重跑安装器**（会重新生成单元，且其它主机一并受益）

```bash
cd ~/dbdog-release && git pull
bash scripts/upgrade.sh dbdog-agent
```

### 验证（60 秒后，在 167 上）

```bash
set -a; . ~/dbdog/etc/dbdog-server.env; set +a
~/dbdog/modules/postgresql/current/bin/psql "$PG_DSN" -Atc \
  "select dbms, database_instance, agent_version, status, observed_at
     from t_1.dbm_collection_configs"
```

预期出现 `gaussdb|linux163-37000|7.81.0-dbdog.6|ok|<刚才>`，控制台「采集配置」页随之有数据。

> **其它被采集主机同样受影响**——凡是用 dbdog-release 的 agent-install.sh 装的，
> 这个开关都是 true。建议逐台按 A 或 B 处理。

### 两条纠正

1. **「有采集作业持续漏拍」不成立**。你们 B4 的 tcpdump 证明那些 10 分钟一条的 dbmhealth
   POST body 是 `{}`（2 字节），是 Go forwarder 对空队列的周期性 flush，不是
   `missed_collection` 事件。第一轮 C 项的线索作废，不用再查。
2. 公网侧此前在 agent-core 里做的「构造期不消费去抖配额」修复（`debounce=False`）是对的，
   但**从来没被执行到**——开关在它之前就 return 了。它仍有价值（抗启动期抖动），
   只是不是本次根因。

---

## 内网执行修复（2026-08-07 19:22 CST）

### 执行方案 A（单机 sed）

```bash
sed -i 's/^Environment=DBDOG_DISABLE_DBM_HEALTH=true$/Environment=DBDOG_DISABLE_DBM_HEALTH=false/' \
  /etc/systemd/system/dbdog-agent.service
grep -n DBDOG_DISABLE_DBM_HEALTH /etc/systemd/system/dbdog-agent.service
  # → 10:Environment=DBDOG_DISABLE_DBM_HEALTH=false

systemctl daemon-reload && systemctl restart dbdog-agent
```

**运行进程环境验证**：

```
MainPID: 1392772
/proc/$PID/environ → DBDOG_DISABLE_DBM_HEALTH=false
agent status → active
```

### 验证（60 秒后，167 上）

**数据库**：

```
select dbms, database_instance, agent_version, status, observed_at from t_1.dbm_collection_configs

gaussdb|linux163-37000|7.81.0|ok|2026-08-07 19:23:39.997+08
```

`linux163-37000` 行已出现，`status: ok`。采集配置页空白问题修复。

**agent status（163 上）**：

```
Database Monitoring Health Events: Last Run: 1, Total: 1
```

此前一直是 0 的 `Database Monitoring Health Events` 行现在 `Total: 1`——initialization
health event 已产出并提交。

**server 日志**：

19:22:41 和 19:22:46 两条 dbmhealth POST 的 `latency_ms` 分别为 3.246 和 2.799（此前空
flush 是 ~0.05ms），说明 server 实际解析了非空 payload。

### 结论

根因 `DBDOG_DISABLE_DBM_HEALTH=true` 已在 163 上修复。其它用 dbdog-release 安装器装的主机
仍需逐台处理（方案 A 或拉最新 dbdog-release 后 `git pull && bash scripts/upgrade.sh dbdog-agent`）。