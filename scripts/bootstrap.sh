#!/usr/bin/env bash
# dbdog Agent 一行安装自举脚本（Install Agents 页面 curl|bash 的入口）。
# 本文件是 curl|bash 的信任根，自身不进 sha256s 清单（自证无意义）；完整性由它拉取
# /install/sha256s（server 发布时构建期生成、随二进制内嵌）后对全部安装器脚本做
# sha256sum -c 保证。残余风险（明网 http 下脚本+清单被一致性替换）见 devspec
# install-channel.md 的信任链陈述。
#
# 页面命令形态（变量由 Install Agents 页预填）：
#   DBDOG_SERVER_URL="http://<server>:8080" DBDOG_API_KEY="ddog_..." \
#   bash -c "$(curl -s http://<server>:8080/install/bootstrap.sh)"
#
# 安装模式（DBDOG_INSTALL_MODE，缺省 host）：
#   host  Install Agents 页：--host-only，只装主机基线（原行为，缺省零变化）。
#   auto  Databases「添加数据库实例」向导：不带 --host-only——安装器探测数据库引擎、
#         验收 *_MONITOR_PASSWORD、渲染引擎 conf.d。已装主机的机器重入此模式是幂等
#         升级 + 引擎接入（runtime 一致则只刷新配置，见 agent-install.sh 幂等分支）。
set -Eeuo pipefail

die() {
  printf 'bootstrap: %s\n' "$*" >&2
  exit 1
}

# root 自提升（对齐 Datadog setup.sh 的 UID 判定，但用自 re-exec 而非逐命令 sudo——
# agent-install.sh 特权命令多，前缀改造面大；显式 env 传递避开 sudoers env_reset 剥变量）。
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "非 root 且系统无 sudo，请以 root 重新执行"
  exec sudo -E env \
    DBDOG_SERVER_URL="${DBDOG_SERVER_URL:-}" \
    DBDOG_API_KEY="${DBDOG_API_KEY:-}" \
    DBDOG_INSTALL_MODE="${DBDOG_INSTALL_MODE:-}" \
    bash -c "$(curl -fsS "${DBDOG_SERVER_URL%/}/install/bootstrap.sh")"
fi

[ -n "${DBDOG_SERVER_URL:-}" ] || die "缺少 DBDOG_SERVER_URL（在 dbdog-web「安装 Agent」页复制完整命令）"
[ -n "${DBDOG_API_KEY:-}" ] || die "缺少 DBDOG_API_KEY（在 dbdog-web「安装 Agent」页复制完整命令）"
DBDOG_SERVER_URL="${DBDOG_SERVER_URL%/}"
case "${DBDOG_INSTALL_MODE:-host}" in
  host) ;;
  auto) ;;
  *) die "DBDOG_INSTALL_MODE 只能是 host 或 auto，当前值: ${DBDOG_INSTALL_MODE}" ;;
esac

for tool in curl sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool，请先安装（内网源或系统镜像）"
done

# 预验 key：失败点尽量前移，避免拉完脚本才因凭证问题失败。
validate_out="$(curl -fsS --connect-timeout 10 --max-time 30 \
  -H "DD-API-KEY: ${DBDOG_API_KEY}" \
  "${DBDOG_SERVER_URL}/api/v1/validate" 2>&1)" || \
  die "dbdog-server 不可达或 Agent API key 无效：${DBDOG_SERVER_URL}（命令请从「安装 Agent」页原样复制）"
[ "$validate_out" = '{"valid":true}' ] || die "server 未确认 Agent API key 有效：${validate_out}"

tmp="$(mktemp -d /tmp/dbdog-bootstrap.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

# 文件清单从 sha256s 解析（清单单源：server /install/sha256s 即安装器合约文件集合），
# 不在 bootstrap 里硬编码——新增合约文件自动进入分发，两处清单永不漂移。
curl -fsS --connect-timeout 10 --max-time 60 \
  "${DBDOG_SERVER_URL}/install/sha256s" >"$tmp/sha256s.txt" || \
  die "无法取得安装脚本指纹清单（server 可能低于含 /install/* 的版本）"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '下载: %s\n' "$name"
  curl -fsS --create-dirs --connect-timeout 10 --max-time 120 \
    -o "$tmp/$name" "${DBDOG_SERVER_URL}/install/scripts/$name" || \
    die "下载失败: $name"
done < <(awk '{print $2}' "$tmp/sha256s.txt")

# 先验后执行：任何一字节不符即拒，主机不做任何变更。
if ! (cd "$tmp" && sha256sum -c sha256s.txt); then
  printf '\nbootstrap: 指纹不匹配，拒绝执行，主机未做任何变更。\n' >&2
  printf '期望指纹（server 发布值）:\n' >&2
  cat "$tmp/sha256s.txt" >&2
  printf '\n实际指纹:\n' >&2
  (cd "$tmp" && sha256sum $(awk '{print $2}' sha256s.txt)) >&2 || true
  exit 1
fi

# manifest.tsv（agent-install 解析产物版本的发布事实）不在指纹清单里，单独拉取；
# 完整性由产物下载自身的 sha 校验兜底。
printf '下载: manifest.tsv\n'
curl -fsS --connect-timeout 10 --max-time 60 \
  -o "$tmp/manifest.tsv" "${DBDOG_SERVER_URL}/install/scripts/manifest.tsv" || \
  die "下载失败: manifest.tsv"

export DBDOG_SERVER_URL DBDOG_API_KEY
export MANIFEST="$tmp/manifest.tsv"
# 模式分流：Install Agents 页保持 --host-only；向导 auto 走完整安装（引擎发现+渲染）。
# 监控密码 env（DBDOG_*_MONITOR_PASSWORD）经进程环境透传，安装器自行收割。
if [ "${DBDOG_INSTALL_MODE:-host}" = "auto" ]; then
  exec bash "$tmp/agent-install.sh"
fi
exec bash "$tmp/agent-install.sh" --host-only
