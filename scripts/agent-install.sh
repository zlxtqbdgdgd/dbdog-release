#!/usr/bin/env bash
# GaussDB 主机：安装/升级 dbdog-agent（唯一需要 sudo 的环节——rpm 安装本身是特权操作）。
# 前提：该主机也 clone 了 dbdog-release（GitHub 只读可达）。
# 用法：
#   agent-install.sh          # 下载校验 rpm，打印需 DBA 执行的 sudo 命令
#   agent-install.sh --run    # 直接以 sudo 执行安装（当前用户需有 sudo 权限）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

version="$(manifest_get dbdog-agent 5)"
artifact="$(manifest_get dbdog-agent 6)"
sha256="$(manifest_get dbdog-agent 7)"
[ "$version" != "-" ] || die "dbdog-agent 尚未发布"

log "dbdog-agent 目标版本: $version"
pkg="$(download_artifact "$artifact" "$sha256")"

echo
echo "rpm 已就绪并通过校验: $pkg"
echo "安装/升级命令（需 root）："
echo "    sudo rpm -Uvh --replacepkgs $pkg"
echo "[首跑校准] 安装后 agent 配置（上报地址、GaussDB 连接）见 dbdog-agent 仓 dbdog-deploy/ 的文档。"

if [ "${1:-}" = "--run" ]; then
  sudo rpm -Uvh --replacepkgs "$pkg"
fi
