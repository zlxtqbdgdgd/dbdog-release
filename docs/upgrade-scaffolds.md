# 升级脚手架登记

**规矩（家族军规 10）**：一次变更如果会让在网环境需要人工介入才能恢复正常
（改 env、补字段、跑一次性 SQL、手工重启……），那就不是「写进文档让运维照做」，
而是 `install.sh` / `upgrade.sh` 自己在升级时把它做掉；版本号看不出来的漂移，
还要在 `check-upgrade.sh` 里报出来（`pending_stack_config`），否则那台机永远等不到
能修好它的那次升级。

这类「为了升到某个版本多干的事」会随版本一条条累积。**它们都是有到期日的**：等线上环境
都升过了那一版，对应的脚手架就是纯负担，按「删除清单」整条删掉（军规 4）。本表 2026-09-03
起立，**此前的一次性迁移逻辑不追溯登记**。

## 用法

```bash
./scripts/scaffold-status.sh      # 每条自哪个发布版本起随产物生效、距最新发布差几个版本
```

「生效版本」不写在表里——它由「引入提交之后的第一次该模块发布」确定性推导（军规 3），
钉成字面量只会烂掉。**判断能不能删，看的是线上最老的那台机是否已经升过生效版本**：
升到那一版必然跑过一次 `upgrade.sh`，也就必然被自愈过一次。拿不准就上机跑判据那条命令。

## 在册

### S1 · dbdog-web 缺 `DBDOG_APIKEY_ENC_KEY`

<!-- scaffold id=S1 module=dbdog-web introduced=0ebbfc5 -->

| 项 | 值 |
|---|---|
| 引入 | 2026-09-03，release `0ebbfc5`（自愈）+ `1ae376e`（探测） |
| 病症 | `etc/dbdog-web.env` 里该行是空的（发布模板派生自 web 仓 `.env.example`，一直没值），控制台「新建 API Key」直接报 `DBDOG_APIKEY_ENC_KEY 未配置或不是 32 字节 base64`（web 侧有意 fail closed） |
| 谁中招 | 引入之前装/升过的所有环境；生效版本之后**首装**的环境天然正确 |
| 自愈 | `lib.sh: ensure_apikey_enc_key`——值缺失或解不出 32 字节才生成一把写回，合法值永不轮换 |
| 探测 | `lib.sh: pending_stack_config` → `check-upgrade.sh` 打进表格并退 10 |
| 判据 | 每台机 `grep '^DBDOG_APIKEY_ENC_KEY=' ~/dbdog/etc/dbdog-web.env` 是 44 位 base64 |
| 删除清单 | ① `pending_stack_config` 里这一项（表空了就连函数带 `check-upgrade.sh` 的接线一起删）；② dbdog-build `test-release-contracts.sh` 里「待校准配置探测」那段。**`ensure_apikey_enc_key` 不删**——发布模板里这行永远是空的，首装生成是长期能力，不是脚手架 |

### S2 · dbm 签名字典：被丢弃计划的 plan 脱敏正文落在 `raw_statement` 列

<!-- scaffold id=S2 module=dbdog-server introduced=68fe706 -->

| 项 | 值 |
|---|---|
| 引入 | 2026-09-13，loop S305。机制与步骤都在 **dbdog-server**（读路径只认脱敏列、写路径按样本子类分列、蓝图 `migrations/blueprint/ch/0037_dbm_statement_dictionary_obfuscated_column.sql.tmpl`），本仓只登记。`introduced` 取登记时本仓 main 头：生效版本 = 其后第一次 `publish: dbdog-server@…`，**前提是那次发布已含上述 server 改动**——若 server 改动合入之前已有一次 server 发布，把 `introduced` 改成合入之后的本仓 HEAD |
| 病症 | 升级前的 server 把「计划不可能（no_plans_possible）而被丢弃计划」的 plan 事件正文（agent 已脱敏）写进 `dbm_query_statements.raw_statement`、`statement` 留空；新读路径为了永不回出原文只读 `statement`，这批签名在 `get_dbdog_database_query_statement` 上会变成 found:false，直到同签名的新 plan 事件重写或行按表 TTL 过期 |
| 谁中招 | 生效版本之前摄入过 DBM 样本的每个租户库；生效版本之后首装的环境没有存量 |
| 自愈 | 不在本仓：dbdog-server 启动期 `tenancy.Provisioner.MigrateAll` 推进蓝图 ch/0037——两条 `ALTER … UPDATE … SETTINGS mutations_sync = 2`，只搬 **tags 里没有 `raw_query_statement` 键** 的行（该 tag 与 rqt/rqp 原文事件由同一 agent 开关、同一上游提交引入，带它的行分不清来源，一行不动），重跑收敛。`upgrade.sh` 升级 server 后的重启即触发 |
| 探测 | 不另加 `pending_stack_config` 项：步骤失败写 `org_blueprint_state.last_error`，已由 L1 的 `blueprint_drift_rows` 报出；步骤成功则 ch 版本 ≥ 37，版本号看得出来 |
| 上机判据 | ① `psql "$PG_DSN" -Atqc "SELECT org_id, version, last_error FROM public.org_blueprint_state WHERE engine = 'ch' ORDER BY org_id"` 每行 version ≥ 37 且 last_error 为空；② 每个租户库 `SELECT count() FROM obs_t_<org>.dbm_query_statements WHERE statement = '' AND raw_statement != '' AND NOT mapContains(tags, 'raw_query_statement')` 为 0 |
| 删除清单 | ① 蓝图步骤**不能删文件**（`tenancy.ParseFS` 要求版本号连续，删了新租户推进会断档）：把 `0037_…sql.tmpl` 的两条 UPDATE 换成一条以 `{{ .CHDatabase }}.dbm_query_statements` 限定的零命中只读语句（`TestRealBlueprintParsesAndRenders` 要求 CH 语句带租户库前缀；该替换写法没在真 CH 上验过）；② server `internal/storage/clickhouse/statement_dictionary_live_test.go` 里「存量自愈」那一段连同 `dictHealStepName`。**读路径只认脱敏列、写路径按子类分列不删**——那是长期语义，不是脚手架 |

## 长期机制（不是脚手架，永不到期，故不写在册表那行机器可读的登记元数据）

本节收「军规 10 要求升级脚本自己做掉、但没有到期日」的那些能力。它们和上面的在册脚手架
共用 `pending_stack_config` 与 `check-upgrade.sh` 的接线，却**不随线上环境升级而失效**，
所以不进在册表、`scaffold-status.sh` 也不该把它们算成待删项。

### L1 · 租户蓝图（storage v3 的 ClickHouse 表）没推进到位

| 项 | 值 |
|---|---|
| 机制归属 | **dbdog-server**，不是本仓。启动期 `tenancy.Provisioner`（`Provision` default org + `MigrateAll`）按 `migrations/blueprint/ch/NNNN_*.sql.tmpl` 的步骤序把每个租户库 `obs_t_<org>` 推到最新，进度记在 ctl 的 `public.org_blueprint_state(org_id, engine, version, last_error)`。server recipe 的 pre-switch 钩子注释即这条分工的单源：「PG ctl 库增量迁移（goose up）。CH 租户表由 dbdog-server 启动时 blueprint 自动推进」 |
| 病症 | 某租户某引擎的某一步失败时，server 只写 `last_error` 并记一条 Error 日志，**照常对外服务**（`cmd/dbdog-server/main.go` 把 `runProvisioner` 的错误降级成日志）。于是模块版本全对、产物 SHA 全对，读路径却因为缺列 500——CH 列缺失打崩 events 读面这件事，2026-08-06（`clickhouse_v2/00038` 的 `events.host`）和 2026-09-04（`00044` 的 `event_status`/`aggregation_key`/`priority`）各来过一次，两次都是靠人手工 `ALTER` 单台机器收的场 |
| 谁中招 | 任何一次蓝图步骤执行失败的环境（CH 短暂不可达、DDL 在该库上真的过不去、租户库被外部改过） |
| 自愈 | `lib.sh: heal_blueprint_drift`——`upgrade.sh` 收尾（含「没有可升级的模块」那条早退路径）重启一次 dbdog-server 让 `MigrateAll` 重跑；一次升级只重启一轮，仍失败就报出来要人看，不反复重启 |
| 探测 | `lib.sh: blueprint_drift_rows` → `pending_stack_config` → `check-upgrade.sh` 打进表格并退 10。探不到（PG 没起、模块没装、DSN 自定义形态）一律当没漂移：宁可漏报也不让假警报把整条检查废掉 |
| 上机判据 | `psql "$PG_DSN" -Atqc "SELECT org_id, engine, version, last_error FROM public.org_blueprint_state ORDER BY org_id, engine"`——`last_error` 全为空即到位 |
| 为什么不删 | 只要 CH 租户表还是「启动期推进 + 失败降级成日志」这个形状，这条漂移就永远可能发生。它不是某一版引入的一次性病症，没有「线上最老的机器升过 X 版就可以删」这个终点 |
| **它探不到什么**（明写，免得被当成全覆盖） | 迁移作者**忘了加蓝图步骤**——`migrations/clickhouse_v2/NNNNN_*.sql` 写了新列却没有对应的 `migrations/blueprint/ch/NNNN_*.sql.tmpl` 时，`org_blueprint_state` 显示的是「已推到最新」（版本齐、`last_error` 空），而新租户的表里根本没有那几列。守这条的是 **dbdog-server 侧** 的 `blueprint_columns_integration_test`（建租户后直查 `system.columns`，断言 events 含 `eventColumns` 引用的每一列）——它要真 CH 才跑，不在本仓能力范围内 |

### L2 · GaussDB 本机 MD5 HBA 受管规则

| 项 | 值 |
|---|---|
| 机制归属 | 本仓 `agent-install.sh: agent_ensure_gaussdb_hba_rule`（预检阶段，cutover 之前）；失败退出由 `agent_restore_gaussdb_hba_rules` 还原 |
| 病症 | GaussDB 默认 HBA 标准 libpq 一条都用不了（`sha256` 是私有握手，`trust` 免密且救不了没建号）；07-28 之前的安装器写的是 `local all dbdog trust` 受管块，07-28～09-06 之间改成只读门禁让 DBA 手加 md5 行（内网 163 实机就卡在这，2026-09-06） |
| 自愈 | 每次安装/升级把 `host all dbdog 127.0.0.1/32 md5` 以 `# dbdog-release BEGIN/END` 受管块**置顶**写入 `SHOW hba_file` 所指文件并 `pg_reload_conf()`；旧 socket trust 受管块在同一步换成 md5 行；DBA 的行逐字节不碰；改前副本留 `/var/log/dbdog-agent/gs_hba.conf.<port>.before-*` |
| 上机判据 | `head -3 $(gsql -Atc 'SHOW hba_file;')` 前三行正是受管块；`SELECT 1` 用 dbdog 经 127.0.0.1 TCP 收到 MD5 challenge（安装器的最小握手探针 code=5） |
| 为什么不删 | 只要采集走标准 libpq、GaussDB 默认不是 md5，这条就是每台 GaussDB 主机的接入基础，没有「线上都升过 X 版」这个终点 |

