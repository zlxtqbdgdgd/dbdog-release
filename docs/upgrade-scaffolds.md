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
