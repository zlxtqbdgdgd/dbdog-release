# upgrade.sh 升级 dbdog-mcp 后 OAuth 验收误报失败事实记录

> 本文只记录事实（原始命令输出、日志、脚本代码段、定位定界证据），不包含结论与修复建议。
> 供外部定位脚本 `scripts/upgrade.sh` 与 `scripts/verify.sh` 在 dbdog-mcp 升级流程中的服务启动与验收时序问题。

## 环境

| 项 | 值 |
|----|----|
| 主机 | 10.44.136.167（stack 服务器，aarch64） |
| 连接用户 | dbdog |
| 升级前版本 | dbdog-mcp 0.1.6 |
| 目标版本 | dbdog-mcp 0.1.9（artifact sha256 前缀 `1cea3b98f00b`） |
| 同批升级模块 | dbdog-server 0.1.8→0.1.12、dbdog-web 0.1.9→0.1.14、dbdog-mcp 0.1.6→0.1.9 |
| 脚本 | `~/dbdog-release/scripts/upgrade.sh`（origin/main @ ce5c74d）、`~/dbdog-release/scripts/verify.sh` |
| 服务管理器 | `~/dbdog-release/scripts/dbdogctl`（非 systemd；通过 pidfile + `start_app` 后台拉起） |
| 时间 | 2026-08-06 16:15–16:37 CST |

## 执行命令

```bash
cd ~/dbdog-release
export http_proxy='http://***@proxyhk.huawei.com:8080'
export https_proxy="$http_proxy"
CURL_INSECURE=1 bash scripts/upgrade.sh dbdog-server dbdog-web dbdog-mcp
```

命令行显式包含 `dbdog-mcp`。

---

## 失败现象

### 升级输出末尾（16:16:34 同一秒内）

```
[16:16:34] dbdog-mcp: 0.1.6 → 0.1.9（artifact 1cea3b98f00b）完成
[16:16:34] 通过: server/web/MCP 内部 token 一致且非占位
[16:16:34] 通过: web/MCP OAuth JWT 一致且非占位
[16:16:34] 通过: web 后端与 PUBLIC_* URL 已配置
[16:16:34] 通过: MCP 后端/OAuth/public URL 已配置
[16:16:34] 通过: Web OAuth 表结构已迁移

WARN: 失败: MCP OAuth discovery 与 401 challenge 可用
ERROR: 1 项基础验收失败；查看 /home/dbdog/dbdog/logs/ 下对应服务日志
```

对比同批的 dbdog-server、dbdog-web 升级输出，两者都有形如
`[16:16:00] dbdog-server 已启动并通过启动检查 (pid 3609151)` 的行；
dbdog-mcp 切包行 `[16:16:34] dbdog-mcp: 0.1.6 → 0.1.9 ... 完成` 之后**没有**任何
"已启动并通过启动检查" 行。

### 升级后服务状态（16:19 采集）

```
postgresql     运行中 pid=93298    v16.14
clickhouse     运行中 pid=2984437  v26.8.1.184
dbdog-server   运行中 pid=3609151  v0.1.12
ddsql-server   运行中 pid=3610189  v0.1.12
dbdog-web      运行中 pid=3622364  v0.1.14
dbdog-mcp      已停止 -            v0.1.9
```

dbdog-mcp 显示「已停止」，但 current 软链已切到 0.1.9：
```
lrwxrwxrwx 1 dbdog dbdog 123 Aug  6 16:16 current ->
  /home/dbdog/dbdog/modules/dbdog-mcp/dbdog-mcp-0.1.9.sha256-1cea3b98f00b...
```

---

## 定位定界证据

### 证据 A：dbdog-mcp 进程在升级期间未启动，10 分钟后手动启动才起来

进程启动时间（`ps -eo pid,lstart,etime,cmd | grep -E "dbdog-server|dbdog-web|index.js"`）：

```
3609151 Thu Aug  6 16:15:56 2026    01:36:27 .../dbdog-server/current/bin/dbdog-server
3610189 Thu Aug  6 16:16:00 2026    01:36:23 .../dbdog-server/current/bin/ddsql-server
3774649 Thu Aug  6 16:26:05 2026    01:26:18 .../node/current/bin/node index.js
```

dbdog-server / ddsql-server 在 16:15–16:16 启动（升级流程拉起）；
dbdog-mcp（node index.js）在 **16:26:05** 启动，对应手动执行
`dbdogctl start dbdog-mcp` 的时间，比升级切包晚 10 分钟。

pidfile 时间戳（`ls -la ~/dbdog/run/`）：

```
-rw-rw-r-- 1 dbdog dbdog 8 Aug  6 16:15 dbdog-server.pid
-rw-rw-r-- 1 dbdog dbdog 8 Aug  6 16:16 dbdog-web.pid
-rw-rw-r-- 1 dbdog dbdog 8 Aug  6 16:16 ddsql-server.pid
-rw-rw-r-- 1 dbdog dbdog 8 Aug  6 16:26 dbdog-mcp.pid
```

dbdog-mcp.pid 的 mtime 是 16:26（手动启动），其余三个是 16:15–16:16（升级流程）。

### 证据 B：dbdog-mcp.log 在 16:16 切包时段无任何启动 banner

`~/dbdog/logs/dbdog-mcp.log` 共 52 行。dbdog-mcp 每次启动会打印 banner
`[dbdog-mcp] streamable-http on http://0.0.0.0:8090/mcp → dbdog http://127.0.0.1:8080`。
banner 出现的行号：

```
17,18,19,20,21,24,25,26,52
```

第 17–26 行属于旧版 0.1.0 历史启动（紧随其后的 SyntaxError 路径为
`dbdog-mcp-0.1.0/index.js`）；第 27–51 行是旧进程的 OOM 崩溃堆栈
（`FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory`，
pid 836581）；**第 52 行是文件最后一行，对应 16:26 手动启动**。
16:16 升级切包时段没有任何 banner 或错误输出。

### 证据 C：手动启动后 OAuth 验收全部通过

16:26 手动执行 `dbdogctl start dbdog-mcp`：
```
[16:26:07] dbdog-mcp 已启动并通过启动检查 (pid 3774649)
```

16:37 重新执行 `bash scripts/verify.sh --oauth`：
```
[16:37:01] 通过: server/web/MCP 内部 token 一致且非占位
[16:37:01] 通过: web/MCP OAuth JWT 一致且非占位
[16:37:01] 通过: web 后端与 PUBLIC_* URL 已配置
[16:37:01] 通过: MCP 后端/OAuth/public URL 已配置
[16:37:01] 通过: Web OAuth 表结构已迁移
[16:37:01] 通过: MCP OAuth discovery 与 401 challenge 可用

[16:37:01] OAuth 自动认证链验收通过
```

手动启动后 OAuth 端点实测（`curl`）：

```
GET /.well-known/oauth-protected-resource → HTTP 200
  {"resource":"http://10.44.136.167:8090/mcp",
   "authorization_servers":["http://10.44.136.167:3000"],
   "bearer_methods_supported":["header"]}

POST /mcp (无 Authorization 头) → HTTP 401
```

### 证据 D：升级前 dbdog-mcp 未在运行

结合证据 A/B/C：升级前 dbdog-mcp 进程不存在（pidfile 指向的旧进程 836581 已 OOM 崩溃，
日志无 0.1.6 启动 banner）。升级流程未在切包后启动它，手动启动才拉起。

---

## 脚本相关代码段

### upgrade.sh: upgrade_one 函数中"停服务→切包→启服务"逻辑

**来源**：`scripts/upgrade.sh:277-411`（`grep -n "upgrade_one()" scripts/upgrade.sh` → 277）

停服务与记录在跑服务（升级前快照）：

```bash
  # 停该模块的服务（记录原本在跑的，升级后拉回来）
  local svcs running=""
  svcs="$(module_services "$m")"
  for s in $svcs; do
    if "$DBDOGCTL" status "$s" | grep -q 运行中; then running="$running $s"; fi
  done
```

`running` 仅在 `dbdogctl status` 显示「运行中」时追加该服务名。
若升级前服务未运行，`running` 为空字符串。

切包后启动服务（`scripts/upgrade.sh:393`）：

```bash
  # shellcheck disable=SC2086
  [ -n "$running" ] && "$DBDOGCTL" start $running    # 只拉回升级前在跑的服务
```

`[ -n "$running" ]` 在 `running` 为空时为假，**不会调用 `dbdogctl start`**。
因此切包后若升级前服务未运行，服务保持停止状态，不会打印
"已启动并通过启动检查"。

`module_services` 函数（`scripts/lib.sh:680-694`）：

```bash
module_services() {
  case "$1" in
    dbdog-server) echo "dbdog-server ddsql-server" ;;
    dbdog-web) echo "dbdog-web" ;;
    dbdog-mcp) echo "dbdog-mcp" ;;
    postgresql) echo "postgresql" ;;
    clickhouse) echo "clickhouse" ;;
    *) echo "" ;;
  esac
}
```

### upgrade.sh: 升级后重启与 OAuth 验收的编排（line 515-553）

```bash
server_was_running=0
ddsql_was_running=0
web_was_running=0
mcp_was_running=0
if [ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-server | grep -q '运行中'; then
  server_was_running=1
fi
if [ "$DBDOG_SERVER_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status ddsql-server | grep -q '运行中'; then
  ddsql_was_running=1
fi
if [ "$DBDOG_WEB_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-web | grep -q '运行中'; then
  web_was_running=1
fi
if [ "$DBDOG_MCP_CONFIG_CHANGED" -eq 1 ] \
  && "$DBDOGCTL" status dbdog-mcp | grep -q '运行中'; then
  mcp_was_running=1
fi
log "升级计划: ${targets[*]}"
for m in "${targets[@]}"; do upgrade_one "$m"; done
if [ "$server_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-server
fi
if [ "$ddsql_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart ddsql-server
fi
if [ "$web_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-web
fi
if [ "$mcp_was_running" -eq 1 ]; then
  "$DBDOGCTL" restart dbdog-mcp
fi
if [ "$oauth_upgrade" -eq 1 ]; then
  "$SCRIPTS_DIR/verify.sh" --oauth
fi
```

`mcp_was_running=1` 需要两个条件同时满足：
1. `DBDOG_MCP_CONFIG_CHANGED -eq 1`（配置校准阶段 mcp.env 的 cksum 发生变化）
2. `dbdogctl status dbdog-mcp | grep -q '运行中'`（升级前 mcp 在运行）

`oauth_upgrade` 的设置（line 503-508）：

```bash
oauth_upgrade=0
for m in "${targets[@]}"; do
  case "$m" in
    dbdog-server) remote_config_upgrade=1 ;;
    dbdog-web | dbdog-mcp) oauth_upgrade=1 ;;
  esac
done
```

`oauth_upgrade=1` 只要 targets 里包含 dbdog-web 或 dbdog-mcp 即成立，
**不依赖服务是否在运行**。随后 `verify.sh --oauth` 无条件执行。

### verify.sh: probe_oauth_discovery 需要 mcp 进程在监听

**来源**：`scripts/verify.sh:299-380`

```bash
probe_oauth_discovery() (
  ...
  mcp_port="$(env_value dbdog-mcp DBDOG_HTTP_PORT)" || return 1
  ...
  resource_metadata="$(retry_http \
    "http://127.0.0.1:${mcp_port}/.well-known/oauth-protected-resource")" \
    || return 1
  ...
  challenge="$(curl -sS --noproxy '*' --connect-timeout 1 --max-time 2 \
    -D - -o /dev/null -X POST \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "http://127.0.0.1:${mcp_port}/mcp")" || return 1
  ...
)
```

该函数向 `127.0.0.1:${mcp_port}`（本例 8090）发起 HTTP 请求。
若 mcp 进程未在监听，`retry_http` 与 `curl` 会连接失败，函数返回 1，
`check "MCP OAuth discovery 与 401 challenge 可用" probe_oauth_discovery` 计为失败。

该检查项在 verify.sh 中的注册（`grep -n` verify.sh）：

```
388:  check "MCP OAuth discovery 与 401 challenge 可用" probe_oauth_discovery    # --oauth 模式
440:  check "MCP OAuth discovery 与 401 challenge 可用" probe_oauth_discovery    # 全量模式
```

### dbdogctl: start_one 函数（服务启动与启动检查）

**来源**：`scripts/dbdogctl:197-273`

```bash
start_one() {
  local svc="$1"
  if is_running "$svc"; then
    if wait_started "$svc"; then
      log "$svc 已在运行且通过启动检查 (pid $(pid_of "$svc"))"
      return 0
    fi
    warn "$svc 进程存在但未通过启动检查；查看 $(service_log_path "$svc")"
    return 1
  fi
  case "$svc" in
    ...
    dbdog-mcp)
      rm -f "$RUN_DIR/dbdog-mcp.pid" || return 1
      if ! start_app dbdog-mcp "$MODULES_DIR/dbdog-mcp/current" \
          "$MODULES_DIR/node/current/bin/node" index.js; then
        warn "$svc 后台启动器失败；查看 $(service_log_path "$svc")"
        return 1
      fi
      ;;
    *) die "未知服务: $svc" ;;
  esac

  if ! wait_started "$svc"; then
    warn "$svc 启动命令已返回，但进程未稳定就绪；查看 $(service_log_path "$svc")"
    ...
    return 1
  fi
  log "$svc 已启动并通过启动检查 (pid $(pid_of "$svc"))"
}
```

`log()` 函数（`scripts/lib.sh:33`）：

```bash
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
```

输出格式 `[HH:MM:SS] <消息>`，与升级输出中
`[16:16:00] dbdog-server 已启动并通过启动检查 (pid 3609151)` 格式吻合。
本次升级输出中 dbdog-mcp 没有该行，说明 `dbdogctl start dbdog-mcp` 未被调用
（或 `is_running` 判定已在运行而实际未通过启动检查，但后者会打印 warn 行，
本次无 warn 行）。

---

## 逻辑链（事实串联，不含结论）

1. 升级前 dbdog-mcp 进程未运行（证据 D：旧进程 836581 已 OOM，日志无 0.1.6 启动 banner，ps lstart 16:26 为手动启动）。
2. `upgrade_one dbdog-mcp` 执行时，`for s in $(module_services dbdog-mcp); do dbdogctl status "$s" | grep -q 运行中` 判定 `running=""`（空）。
3. 切包（`ln -sfn "$newdir" "$current"`）执行，current → 0.1.9。
4. 切包后 `[ -n "$running" ] && "$DBDOGCTL" start $running` 因 `running` 为空，未调用 `dbdogctl start dbdog-mcp`（证据：升级输出无"已启动并通过启动检查"行，日志无 16:16 banner，pidfile mtime 16:26，ps lstart 16:26）。
5. 升级后编排段：`mcp_was_running=0`（因升级前 mcp 未运行，`dbdogctl status | grep 运行中` 为假），`"$DBDOGCTL" restart dbdog-mcp` 未执行。
6. `oauth_upgrade=1`（targets 含 dbdog-mcp），`verify.sh --oauth` 无条件执行。
7. `probe_oauth_discovery` 向 `127.0.0.1:8090` 发请求，mcp 未在监听，`retry_http`/`curl` 连接失败，函数返回 1，`check` 计 1 项失败。
8. 升级输出 `ERROR: 1 项基础验收失败`。
9. 手动 `dbdogctl start dbdog-mcp` 后（16:26），mcp 在 8090 监听，`verify.sh --oauth` 全部通过（证据 C）。

---

## 补充：dbdog-mcp 旧进程 OOM 崩溃记录（历史，非本次升级引入）

`~/dbdog/logs/dbdog-mcp.log` 第 27–51 行包含一次 OOM 崩溃（发生在本次升级之前）：

```
<--- Last few GCs --->

[836581:0x2dc9f140] 474708142 ms: Scavenge 4058.0 (4140.8) -> 4057.4 (4141.0) MB, 4.35 / 0.00 ms  (average mu = 0.980, current mu = 0.001) allocation failure;
[836581:0x2dc9f140] 474708149 ms: Scavenge 4058.3 (4141.0) -> 4057.7 (4141.2) MB, 4.04 / 0.00 ms  (average mu = 0.980, current mu = 0.001) allocation failure;
[836581:0x2dc9f140] 474708155 ms: Scavenge 4058.5 (4141.2) -> 4057.8 (4144.2) MB, 4.17 / 0.00 ms  (average mu = 0.980, current mu = 0.001) allocation failure;

<--- JS stacktrace --->

FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
----- Native stack trace -----
 1: 0xb876e4 node::OOMErrorHandler ...
 ...
```

崩溃进程 pid 836581，堆内存约 4058 MB（`4058.0 (4140.8) -> 4057.4 (4141.0) MB`）。
该 OOM 发生在本次升级之前，是升级前 mcp 进程已不运行的原因之一。
该日志段不含时间戳，其前最近的带时间戳行为 telemetry 条目
`{"ts":"2026-07-30T10:12:30.461Z",...}`（UTC，即 2026-07-30 18:12 CST）。