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

# root 自提升（沿用常见 setup.sh 的 UID 判定，但用自 re-exec 而非逐命令 sudo——
# agent-install.sh 特权命令多，前缀改造面大；显式 env 传递避开 sudoers env_reset 剥变量）。
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "非 root 且系统无 sudo，请以 root 重新执行"
  exec sudo -E env \
    DBDOG_SERVER_URL="${DBDOG_SERVER_URL:-}" \
    DBDOG_API_KEY="${DBDOG_API_KEY:-}" \
    DBDOG_INSTALL_MODE="${DBDOG_INSTALL_MODE:-}" \
    DBDOG_ENGINES="${DBDOG_ENGINES:-}" \
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
#
# 优先取产物桶那份：菜单与产物同一个货架、同一次发布写入，永远不会比产物旧，而且
# 本机为了下 agent 产物本来就必须能连产物桶，不新增任何出网前置。server 内嵌的那份
# 是 server 构建期快照，只当产物桶不可达时兜底——它会比产物旧：2026-09-07 x86_64
# 首发后，线上 server 0.1.24 的快照里 x86_64 那行仍是未发布，x86 主机一行安装当场
# 撞 "dbdog-agent 尚未发布"，而包好好地躺在桶里。所以走到兜底一定要出声。
BUCKET_URL="${BUCKET_URL:-https://github.com/zlxtqbdgdgd/dbdog-release/releases/download/artifacts}"

fetch_manifest() { # <url> <来源说明>；下载并做形态校验，两者任一不过都算这个来源失败
  curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp/manifest.tsv" "$1" || return 1
  # 形态校验：截断的下载、错误页、被中间设备替换的响应都会在这里现形，不会以
  # "尚未发布" 这种指向完全错误的报错甩给装机的人。
  awk -F'\t' '$1 == "dbdog-agent" { found = 1 } END { exit !found }' "$tmp/manifest.tsv" || {
    printf 'bootstrap: %s 的 manifest.tsv 内容不合法（没有 dbdog-agent 行）\n' "$2" >&2
    return 1
  }
  return 0
}

printf '下载: manifest.tsv\n'
if fetch_manifest "${BUCKET_URL%/}/manifest.tsv" "产物桶"; then
  printf '  manifest 来源: 产物桶（与 agent 产物同一次发布写入）\n'
elif fetch_manifest "${DBDOG_SERVER_URL}/install/scripts/manifest.tsv" "server 内嵌快照"; then
  printf '  manifest 来源: server 内嵌快照\n'
  printf 'bootstrap: 警告——产物桶 manifest.tsv 取不到，已回退到 server 内嵌快照。该快照定格在 server 构建之时，可能不含最新发布的版本或架构；若下面报某模块"尚未发布"，先核对产物桶再判断。\n' >&2
else
  die "下载失败: manifest.tsv（产物桶与 server 两处都取不到或内容不合法）"
fi

export DBDOG_SERVER_URL DBDOG_API_KEY
export MANIFEST="$tmp/manifest.tsv"
# 模式分流：Install Agents 页保持 --host-only；向导 auto 走完整安装（引擎发现+渲染）。
# 监控密码 env（DBDOG_*_MONITOR_PASSWORD）经进程环境透传，安装器自行收割。
if [ "${DBDOG_INSTALL_MODE:-host}" = "auto" ]; then
  # 引擎白名单随 auto 模式透传（向导按用户所选引擎传入；缺省空=全引擎）。
  export DBDOG_ENGINES="${DBDOG_ENGINES:-}"
  exec bash "$tmp/agent-install.sh"
fi
exec bash "$tmp/agent-install.sh" --host-only
