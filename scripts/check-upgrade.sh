#!/usr/bin/env bash
# 内网：检查已安装模块是否与 manifest 的版本、产物 SHA 及安装器合约一致。
# 用法：check-upgrade.sh [--pull]   （--pull 先拉取 release 仓 main）
# 退出码：0 = 已安装模块身份均一致；10 = 存在版本/SHA/安装器合约不同或身份未知。

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/agent-lib.sh"

case "${1:-}" in
  "" | --pull) ;;
  *) die "用法: check-upgrade.sh [--pull]" ;;
esac
[ "$#" -le 1 ] || die "用法: check-upgrade.sh [--pull]"

if [ "${1:-}" = "--pull" ]; then
  before_pull="$(git -C "$RELEASE_DIR" rev-parse HEAD)" || die "无法读取 pull 前 release commit"
  log "拉取 dbdog-release main ..."
  if ! git -C "$RELEASE_DIR" pull --ff-only; then
    die "git pull/fetch 失败；停止检查，未使用可能过期的本地 manifest 判断是否为最新"
  fi
  after_pull="$(git -C "$RELEASE_DIR" rev-parse HEAD)" || die "无法读取 pull 后 release commit"
  if [ "$before_pull" != "$after_pull" ] && [ "${DBDOG_CHECK_UPGRADE_REEXEC:-0}" != 1 ]; then
    log "release 脚本已更新，重新执行最新 check-upgrade 逻辑 ..."
    exec env DBDOG_CHECK_UPGRADE_REEXEC=1 "$SCRIPTS_DIR/check-upgrade.sh"
  fi
fi

updates=0
agent_updates=0
selected_arch="$(host_arch)"
printf '%-14s %-12s %-12s %s\n' "模块" "已装" "manifest" "状态"
printf '%s\n' "--------------------------------------------------------"
while IFS=$'\t' read -r m _kind target _service version _artifact sha256 _source_sha _arch; do
  if [ "$target" = "dbhost" ]; then
    # Agent 不使用 stack 的 current 软链，但仍由同一 manifest 判定版本和产物身份。
    inst="$(agent_marker_value "$AGENT_RUNTIME_DIR/.dbdog-release-version" "$AGENT_RUNTIME_DIR")"
    inst_sha256="$(agent_marker_value "$AGENT_RUNTIME_DIR/.dbdog-artifact-sha256" "$AGENT_RUNTIME_DIR")"
  else
    inst="$(installed_version "$m")"
    inst_sha256="$(installed_artifact_sha256 "$m")"
  fi
  if [ "$version" = "-" ]; then
    st="未发布"
  elif [ "$inst" = "-" ]; then
    st="未安装（install.sh 或 upgrade.sh ${m}）"
  elif [ "$inst" = "?" ]; then
    st="版本 marker 损坏 ←"
    updates=$((updates + 1))
    [ "$target" != "dbhost" ] || agent_updates=$((agent_updates + 1))
  elif [ "$inst" != "$version" ]; then
    st="版本不同 ←"
    updates=$((updates + 1))
    [ "$target" != "dbhost" ] || agent_updates=$((agent_updates + 1))
  elif [ "$inst_sha256" = "-" ]; then
    st="版本一致；产物身份未知 ←"
    updates=$((updates + 1))
    [ "$target" != "dbhost" ] || agent_updates=$((agent_updates + 1))
  elif [ "$inst_sha256" = "?" ]; then
    st="产物身份 marker 损坏 ←"
    updates=$((updates + 1))
    [ "$target" != "dbhost" ] || agent_updates=$((agent_updates + 1))
  elif [ "$inst_sha256" != "$sha256" ]; then
    st="版本一致；产物 SHA 不同 ←"
    updates=$((updates + 1))
    [ "$target" != "dbhost" ] || agent_updates=$((agent_updates + 1))
  elif [ "$m" = "dbdog-agent" ]; then
    # 运行时二进制可能没有换版，但 release 安装器会继续演进。只有版本和产物身份
    # 已完全一致后才比较独立合约 marker，让正常 upgrade 重跑配置与真实采集验收。
    contract_marker="$AGENT_RUNTIME_DIR/$AGENT_INSTALLER_CONTRACT_MARKER"
    if ! expected_contract="$(agent_installer_contract_fingerprint "$SCRIPTS_DIR")"; then
      die "无法计算当前 dbdog-agent 安装器合约指纹"
    fi
    if ! [[ "$expected_contract" =~ ^[0-9a-f]{64}$ ]]; then
      die "当前 dbdog-agent 安装器合约指纹格式非法"
    fi
    if [ ! -e "$contract_marker" ] && [ ! -L "$contract_marker" ]; then
      st="版本/产物一致；安装器合约 marker 缺失 ←"
      updates=$((updates + 1))
      agent_updates=$((agent_updates + 1))
    else
      installed_contract="$(agent_marker_value "$contract_marker" "$AGENT_RUNTIME_DIR")"
      if ! [[ "$installed_contract" =~ ^[0-9a-f]{64}$ ]]; then
        st="版本/产物一致；安装器合约 marker 损坏 ←"
        updates=$((updates + 1))
        agent_updates=$((agent_updates + 1))
      elif [ "$installed_contract" != "$expected_contract" ]; then
        st="版本/产物一致；安装器合约不同 ←"
        updates=$((updates + 1))
        agent_updates=$((agent_updates + 1))
      else
        st="一致"
      fi
    fi
  else
    st="一致"
  fi
  printf '%-14s %-12s %-12s %s\n' "$m" "$inst" "$version" "$st"
done < <(manifest_selected_rows "" "$selected_arch")

echo
if [ "$updates" -gt 0 ]; then
  if [ "$agent_updates" -gt 0 ]; then
    log "$updates 个已安装模块需升级或校准产物身份/安装器合约；Agent 执行: sudo scripts/upgrade.sh dbdog-agent"
  else
    log "$updates 个已安装模块需升级或校准产物身份。执行: scripts/upgrade.sh"
  fi
  exit 10
fi
if [ "${1:-}" = "--pull" ]; then
  log "远端 manifest 拉取成功，已安装模块均一致（未安装项见上表）。"
else
  log "按当前本地 manifest，已安装模块均一致（未安装项见上表；确认远端请加 --pull）。"
fi
