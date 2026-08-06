#!/usr/bin/env bash
# 发布前检查 Agent tar 包里**真的带上了我们发 conf 的那些 Python 集成**。
# 用法：verify-agent-integrations.sh <artifact.tar.gz> <期望集成，逗号分隔>
#
# 为什么要有这条（2026-08-06 实事故）：
#   发布物 dbdog-agent-7.81.0-dbdog.5 里有 datadog_checks/gaussdb/、**没有
#   datadog_checks/opengauss/**，而 manifest.tsv 声明的 core:3ae431a 明明已包含
#   openGauss 集成（08-02 入库）。conf.d/opengauss.d/conf.yaml 照发，于是采集端
#   看起来一切正常、实则**指标与 DBM 活动流双双静默归零**：agent 12:38 重启后
#   openGauss 全停，19:32 开跑的 round-20 三引擎轮里那一腿是零遥测，整轮作废。
#   直到 e2e 收轮才发现，隔了两轮。
#
#   既有的构建验收只验五个二进制入口 + ELF/rpath/补丁 marker（见 dbdog-agent
#   dbdog-deploy/docs/ops/RUNBOOK.md §构建合同 5），**没有任何一条校验集成集合**——
#   整个集成静默丢失不会让任何检查变红。本脚本补上这一条。
#
# 期望集合怎么来（**推导，不钉字面量**，军规 3）：调用方按
#   「我们发了 conf.d/<x>.d，且 agent-core 里存在 <x>/datadog_checks/<x>」
# 逐一推出，见 publish.sh 的 expected_agent_integrations()。核心检查（cpu/disk/
# memory 等）由 Go 实现、没有 Python 包，因此天然不在集合里。

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

artifact="${1:-}"
expected_csv="${2:-}"
[ -f "$artifact" ] || die "产物不存在: $artifact"
[ -n "$expected_csv" ] || die "未给期望集成集合（逗号分隔）"

command -v tar >/dev/null 2>&1 || die "缺少 tar"

# 只列表、不解包：整包解开一次要几分钟且占盘，这里只需要路径清单。
listing="$(tar -tzf "$artifact")" || die "无法读取 tar.gz: $artifact"

# 产物内实际带的集成：datadog_checks/<name>/__init__.py 是每个 Python 集成的入口。
present="$(printf '%s\n' "$listing" \
  | sed -n 's|.*/site-packages/datadog_checks/\([a-z0-9_]*\)/__init__\.py$|\1|p' \
  | sort -u)"

[ -n "$present" ] || die "产物里一个 Python 集成都没有，产物形态异常: $artifact"

missing=""
checked=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  checked=$((checked + 1))
  if ! printf '%s\n' "$present" | grep -qx -- "$name"; then
    missing="$missing $name"
  fi
done <<EOF
$(printf '%s' "$expected_csv" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
EOF

[ "$checked" -gt 0 ] || die "期望集合解析后为空: $expected_csv"

if [ -n "$missing" ]; then
  printf 'ERROR: 产物缺少这些集成（我们发了它们的 conf，采集会静默归零）:%s\n' "$missing" >&2
  printf '产物实际带的集成共 %s 个，其中 gauss/postgres 家族：\n' "$(printf '%s\n' "$present" | wc -l | tr -d ' ')" >&2
  printf '%s\n' "$present" | grep -E 'gauss|postgres' | sed 's/^/  - /' >&2
  die "Agent 产物集成集合检查失败: $artifact"
fi

printf 'PASS: 产物含全部 %s 个期望集成（共 %s 个 Python 集成）\n' \
  "$checked" "$(printf '%s\n' "$present" | wc -l | tr -d ' ')"
