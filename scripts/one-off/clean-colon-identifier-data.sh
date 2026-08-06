#!/usr/bin/env bash
# 一次性：清掉 database_instance 里还带冒号的历史数据。
#
# 用法（在 dbdog-server 所在机器上跑，需能读 prod.env）：
#   clean-colon-identifier-data.sh [--apply]      # 不带 --apply 只统计、不删
#
# 背景：2026-08-06 起 agent 的 database_identifier 模板由 `$resolved_hostname:$port`
# 改为 `-$port`（`:` 是 DD 查询语法的 key/value 分隔符，标识里带它会让「按实例过滤」必须整体
# 加引号——round-19 实证：裸写 database_instance:<host>:<port> 的调用 104 次、98% 报错，而
# skill 教的 service:<engine> 写法 80 次仅 4% 报错）。切换后同一实例会出现新旧两个标识，
# 图表/看板按实例分组时会裂成两条。
#
# 为什么直接删而不是改写：这是**开发中的内网环境**（owner 2026-08-06 确认两套环境的数据
# 都可清理）。改写要动 ORDER BY 键、代价与风险都高于重采；删掉后按新标识重新积累即可。
#
# 一次性代码：全部环境切完就该删掉本脚本，别留成常驻工具。
#
# 顺序铁律：**先换模板 + 重启 agent，再跑本脚本**。反过来会先删完、agent 又按旧模板写回来。

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

ENV_FILE="${PROD_ENV:-/home/dbdogt/dev/prod.env}"
[ -f "$ENV_FILE" ] || die "找不到 prod.env（可用 PROD_ENV= 指定）: $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

CH_DB="${DBDOG_CH_DATABASE:-obs}"
CH_USER="${DBDOG_CH_USERNAME:-default}"
: "${CH_PASSWORD:?prod.env 里没有 CH_PASSWORD}"
CH_URL="http://127.0.0.1:8123/"

ch() { curl -sS -u "$CH_USER:$CH_PASSWORD" "$CH_URL" --data-binary "$1"; }

# 带冒号的标识列（各表列名不同：events/metric_points 用 tags，DBM 事实表用 instance）。
# 只挑真实存在的表，避免因某表未建而整条脚本挂掉。
tables_with_instance_col() {
  ch "SELECT table FROM system.columns
      WHERE database = '$CH_DB' AND name = 'instance'
      GROUP BY table ORDER BY table FORMAT TSV"
}

printf '库: %s\n' "$CH_DB"
printf '\n== 带冒号标识的行数（instance 列） ==\n'
total=0
mapfile -t tabs < <(tables_with_instance_col)
for t in "${tabs[@]}"; do
  [ -n "$t" ] || continue
  n="$(ch "SELECT count() FROM $CH_DB.$t WHERE position(instance, ':') > 0 FORMAT TSV")"
  [ "${n:-0}" -gt 0 ] || continue
  printf '  %-32s %s\n' "$t" "$n"
  total=$((total + n))
done

printf '\n== events（tags/database_instance 列） ==\n'
ev="$(ch "SELECT count() FROM $CH_DB.events WHERE position(database_instance, ':') > 0 FORMAT TSV" || echo 0)"
printf '  %-32s %s\n' "events" "$ev"

printf '\n合计约 %s 行（不含 events 的 %s 行）\n' "$total" "$ev"

if [ "$APPLY" -ne 1 ]; then
  printf '\n（未加 --apply，只统计，什么都没删）\n'
  exit 0
fi

printf '\n== 开始删除（ALTER … DELETE 是异步 mutation，提交后用 system.mutations 看进度） ==\n'
for t in "${tabs[@]}"; do
  [ -n "$t" ] || continue
  ch "ALTER TABLE $CH_DB.$t DELETE WHERE position(instance, ':') > 0" >/dev/null
  printf '  已提交: %s\n' "$t"
done
ch "ALTER TABLE $CH_DB.events DELETE WHERE position(database_instance, ':') > 0" >/dev/null
printf '  已提交: events\n'

printf '\n进度: SELECT table, is_done, parts_to_do, latest_fail_reason FROM system.mutations WHERE database='"'"'%s'"'"' AND is_done=0\n' "$CH_DB"
