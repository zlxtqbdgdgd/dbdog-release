#!/usr/bin/env bash
# GaussDB 主机：下载并校验 dbdog-agent 运行时（omnibus tarball，非 rpm）。
# 前提：该主机也 clone 了 dbdog-release（GitHub 只读可达）。
# 用法：
#   agent-install.sh          # 目前只下载校验；root cutover 尚未交付

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

version="$(manifest_get dbdog-agent 5)"
artifact="$(manifest_get dbdog-agent 6)"
sha256="$(manifest_get dbdog-agent 7)"
[ "$version" != "-" ] || die "dbdog-agent 尚未发布"

log "dbdog-agent 目标版本: $version"
pkg="$(download_artifact "$artifact" "$sha256")"

echo
echo "运行时 tarball 已就绪并通过校验: $pkg"
die "尚未交付 root cutover、systemd 单元和配置落位流程；本命令没有安装 agent，请勿手工覆盖 /opt/datadog-agent"
