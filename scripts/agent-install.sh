#!/usr/bin/env bash
# GaussDB 主机：安装/升级 dbdog-agent 运行时（omnibus tarball，非 rpm）。
# 前提：该主机也 clone 了 dbdog-release（GitHub 只读可达）。
# 用法：
#   agent-install.sh          # 下载校验运行时 tarball，打印切换步骤
#
# 部署形态（源自 dbdog-agent fork 的生产流程，RUNBOOK §5）：
#   tarball 解压 = /opt/dbdog-agent 的完整运行时，用随包 cutover 脚本原子切换并
#   翻转 dbdog-agent* systemd 单元——systemd 操作需要 root，这是全流程唯一要
#   sudo 的环节。严禁把它覆盖到官方 /opt/datadog-agent。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

version="$(manifest_get dbdog-agent 5)"
artifact="$(manifest_get dbdog-agent 6)"
sha256="$(manifest_get dbdog-agent 7)"
[ "$version" != "-" ] || die "dbdog-agent 尚未发布（首个 aarch64 运行时构建待编译机扩容后进行）"

log "dbdog-agent 目标版本: $version"
pkg="$(download_artifact "$artifact" "$sha256")"

echo
echo "运行时 tarball 已就绪并通过校验: $pkg"
echo "切换步骤（需 root，具体以包内 README/cutover 脚本为准）："
echo "  1. sudo mkdir -p /opt/dbdog-agent-staging && sudo tar -xzf $pkg -C /opt/dbdog-agent-staging"
echo "  2. 执行包内 cutover 脚本原子切换到 /opt/dbdog-agent 并重启 dbdog-agent* 单元"
echo "  3. 配置（datadog.yaml / conf.d/gaussdb.d）在首次部署时按 dbdog-deploy 文档落位"
