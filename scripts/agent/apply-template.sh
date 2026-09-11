#!/usr/bin/env bash
# 套采集模板（定制层）：apply-template.sh <gaussdb|opengauss|postgres> [--check]
# 安装/升级只渲染现场事实与最小配置；采集开关在模板里，装完（以及每次升级后）跑本脚本合并。
# 幂等：重复执行结果一致。--check 只比对不写盘，有差异退出 1。
# 模板随 agent 产物落在 $AGENT_RUNTIME_DIR/templates/dbdog/db/；可用 DBDOG_TEMPLATES_DIR 覆盖。
set -Eeuo pipefail
engine="${1:?用法: apply-template.sh <gaussdb|opengauss|postgres> [--check]}"; shift
runtime="${AGENT_RUNTIME_DIR:-/opt/dbdog-agent}"
tmpl="${DBDOG_TEMPLATES_DIR:-$runtime/templates/dbdog/db}/$engine.yaml"
conf="${AGENT_CONFIG_DIR:-/etc/dbdog-agent}/conf.d/$engine.d/conf.yaml"
py="${DBDOG_AGENT_PYTHON:-$runtime/embedded/bin/python3}"
[ -x "$py" ] || { printf '找不到 agent 自带 python: %s\n' "$py" >&2; exit 1; }
[ -f "$tmpl" ] || { printf '缺少 %s 采集模板: %s\n' "$engine" "$tmpl" >&2; exit 1; }
[ -f "$conf" ] || { printf '本机未渲染 %s 配置: %s\n' "$engine" "$conf" >&2; exit 1; }
exec "$py" "$(dirname "${BASH_SOURCE[0]}")/apply-template.py" --template "$tmpl" --conf "$conf" "$@"
