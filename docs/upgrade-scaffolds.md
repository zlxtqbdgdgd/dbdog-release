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
