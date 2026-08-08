#!/usr/bin/env bash
# 按 core 提交可复现地构建某个 Python 集成的 wheel（开发机执行，产物再送构建机）。
#
# 为什么需要它：构建机的 embedded Python 被 finalizer 按 SHA 钉死（3.7，且无 hatchling），
# 所以 wheel 一直是"外部供给"。做法此前只在 agent-build/README.md 里一句话，2026-08-06
# 那次发布是现推出来的——一旦换开发机就要重推一遍。
#
# 复现要点（缺一不可）：
#   1. 源码取自 `git archive <core_sha> <集成>` 的干净归档，不用工作树（会带进未提交改动）;
#   2. SOURCE_DATE_EPOCH 取该 commit 的提交时间，否则 wheel 内的时间戳每次都变;
#   3. 独立构建两次并逐字节比对，证明这次构建本身是确定性的。
#
# --self-check 是最有价值的一条：先按一个已知锚重建 wheel，跟构建机 ANCHOR-INFO 里
# 记着的 sha256 比。吻合才说明这台开发机的工具链能复现历史，新 wheel 才可信。
#
# 用法：
#   build-integration-wheel.sh --core-sha <40hex> --integration gaussdb --out ./dist
#   build-integration-wheel.sh ... --self-check <已知core_sha>=<已知sha256>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_REPO="${DBDOG_CORE_REPO:-$(cd "$HERE/../../.." && pwd)/../dbdog-agent-core}"
VENV_DIR="${DBDOG_WHEEL_BUILD_VENV:-$HOME/.cache/dbdog-release/wheel-build-venv}"

log() { printf '[build-integration-wheel] %s\n' "$*" >&2; }
die() { printf '[build-integration-wheel] ERROR: %s\n' "$*" >&2; exit 1; }

core_sha=""
integration=""
out_dir=""
self_checks=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --core-repo) CORE_REPO="${2:-}"; shift 2 ;;
    --core-sha) core_sha="${2:-}"; shift 2 ;;
    --integration) integration="${2:-}"; shift 2 ;;
    --out) out_dir="${2:-}"; shift 2 ;;
    --self-check) self_checks="$self_checks ${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$core_sha" ] || die "缺 --core-sha"
[ -n "$integration" ] || die "缺 --integration"
[ -n "$out_dir" ] || die "缺 --out"
case "$core_sha" in
  *[!0-9a-f]* | "") die "core-sha 必须是小写 40 位十六进制: ${core_sha}" ;;
esac
[ "${#core_sha}" -eq 40 ] || die "core-sha 必须是完整 40 位提交 SHA: ${core_sha}"
case "$integration" in
  '' | *[!a-z0-9_]*) die "集成名只允许小写字母数字下划线: ${integration}" ;;
esac
[ -d "$CORE_REPO/.git" ] || die "core 仓不是 git 工作树: ${CORE_REPO}"

git -C "$CORE_REPO" cat-file -e "$core_sha^{commit}" 2>/dev/null \
  || die "core 仓里没有该提交（先 fetch）: ${core_sha}"
git -C "$CORE_REPO" cat-file -e "$core_sha:$integration/pyproject.toml" 2>/dev/null \
  || die "该 core 提交里没有集成 ${integration}"

# --- 构建工具链：缓存一个只装 build+hatchling 的 venv，避免污染开发机环境 ---
ensure_venv() {
  if [ -x "$VENV_DIR/bin/python" ] \
    && "$VENV_DIR/bin/python" -c 'import build, hatchling' >/dev/null 2>&1; then
    return 0
  fi
  log "准备构建 venv: ${VENV_DIR}"
  rm -rf -- "$VENV_DIR"
  mkdir -p -- "$(dirname "$VENV_DIR")"
  python3 -m venv "$VENV_DIR" >/dev/null 2>&1 || die "创建 venv 失败（需要 python3 -m venv）"
  "$VENV_DIR/bin/pip" -q install build hatchling >/dev/null 2>&1 \
    || die "安装 build/hatchling 失败（首次运行需要网络）"
}

# build_one <core_sha> <集成> <目标目录> —— 回显 wheel 路径与 sha256
build_one() {
  local sha="$1" pkg="$2" dest="$3" epoch stage
  epoch="$(git -C "$CORE_REPO" show -s --format=%ct "$sha")"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-wheel.XXXXXX")"
  git -C "$CORE_REPO" archive "$sha" "$pkg" | tar -x -C "$stage"
  SOURCE_DATE_EPOCH="$epoch" "$VENV_DIR/bin/python" -m build --wheel --no-isolation \
    --outdir "$dest" "$stage/$pkg" >"$stage/build.log" 2>&1 || {
      sed -n '1,25p' "$stage/build.log" >&2
      rm -rf -- "$stage"
      die "构建失败: ${pkg}@${sha:0:8}"
    }
  rm -rf -- "$stage"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# 逐条按已知锚反验工具链：这台机器复现不出历史 wheel，就没资格出新 wheel。
run_self_checks() {
  local spec known_sha known_digest tmp built
  for spec in $self_checks; do
    known_sha="${spec%%=*}"
    known_digest="${spec#*=}"
    [ "$known_sha" != "$spec" ] && [ -n "$known_digest" ] \
      || die "--self-check 格式应为 <core_sha>=<sha256>: ${spec}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-wheel-selfcheck.XXXXXX")"
    build_one "$known_sha" "$integration" "$tmp"
    built="$(ls "$tmp"/*.whl)"
    if [ "$(sha256_of "$built")" != "$known_digest" ]; then
      log "实得 $(sha256_of "$built")"
      log "期望 ${known_digest}"
      rm -rf -- "$tmp"
      die "反验失败：本机复现不出 ${known_sha:0:8} 的 wheel，先查工具链再出新包"
    fi
    rm -rf -- "$tmp"
    log "反验通过: ${integration}@${known_sha:0:8} 复现出 ${known_digest}"
  done
}

ensure_venv
[ -n "$self_checks" ] && run_self_checks

mkdir -p -- "$out_dir"
pass1="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-wheel-p1.XXXXXX")"
pass2="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-wheel-p2.XXXXXX")"
build_one "$core_sha" "$integration" "$pass1"
build_one "$core_sha" "$integration" "$pass2"
w1="$(ls "$pass1"/*.whl)"
w2="$(ls "$pass2"/*.whl)"
cmp -s "$w1" "$w2" || { rm -rf -- "$pass1" "$pass2"; die "两次独立构建不一致，构建不确定"; }

# finalizer 对锚定 wheel 的门禁在这里先过一遍，别等到构建机上才失败。
"$VENV_DIR/bin/python" - "$w1" "$integration" <<'PYEOF'
from email.parser import BytesParser
from pathlib import PurePosixPath
import sys
import zipfile

wheel_path, integration = sys.argv[1:]
with zipfile.ZipFile(wheel_path) as archive:
    names = archive.namelist()
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name:
            raise SystemExit(f"unsafe wheel member: {name!r}")
        if name.lower().endswith((".so", ".dylib", ".dll", ".pyd")):
            raise SystemExit(f"wheel is not pure Python: {name!r}")
    metadata_names = [n for n in names if n.endswith(".dist-info/METADATA")]
    wheel_names = [n for n in names if n.endswith(".dist-info/WHEEL")]
    if len(metadata_names) != 1 or len(wheel_names) != 1:
        raise SystemExit("wheel must contain one METADATA and one WHEEL record")
    metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
    wheel_metadata = BytesParser().parsebytes(archive.read(wheel_names[0]))
    # 引擎目录（postgres）的包名是 datadog-<目录>；datadog_ 开头的共享包目录
    # （datadog_checks_base）的包名就是目录名的连字符形。两类都要能走 wheel 通路。
    expected_name = (
        integration.replace("_", "-")
        if integration.startswith("datadog_")
        else f"datadog-{integration}"
    )
    if metadata.get("Name") != expected_name:
        raise SystemExit(f"wheel name mismatch: {metadata.get('Name')!r} != {expected_name!r}")
    if wheel_metadata.get("Root-Is-Purelib") != "true":
        raise SystemExit("wheel does not declare Root-Is-Purelib: true")
    # 引擎 wheel 是 py3-none-any；datadog_checks_base 上游保留 py2 兼容 tag，
    # 构建产出 py2.py3-none-any。两种都是纯 Python 单 wheel，其余一律拒绝。
    if wheel_metadata.get_all("Tag", []) not in (
        ["py3-none-any"],
        ["py2-none-any", "py3-none-any"],
    ):
        raise SystemExit("wheel does not have a pure py3-none-any (or py2.py3) tag set")
PYEOF
version="$("$VENV_DIR/bin/python" - "$w1" <<'PYEOF'
from email.parser import BytesParser
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as a:
    name = [n for n in a.namelist() if n.endswith(".dist-info/METADATA")][0]
    print(BytesParser().parsebytes(a.read(name)).get("Version"))
PYEOF
)"

# 版本必须与该 core 提交声明的一致——finalizer 会用 __about__.py 复核。
# 引擎目录的包路径是 <目录>/datadog_checks/<目录>；datadog_checks_base 的包路径是
# datadog_checks_base/datadog_checks/base（目录名去掉 datadog_checks_ 前缀）。
about_pkg=$integration
case "$integration" in
  datadog_checks_*) about_pkg=${integration#datadog_checks_} ;;
esac
declared="$(git -C "$CORE_REPO" show "$core_sha:$integration/datadog_checks/$about_pkg/__about__.py" \
  | sed -n 's/^__version__[[:space:]]*=[[:space:]]*["'"'"']\(.*\)["'"'"']$/\1/p')"
[ "$declared" = "$version" ] \
  || die "wheel 版本 ${version} 与该 core 提交声明的 ${declared} 不一致"

final="$out_dir/$(basename "$w1")"
cp -- "$w1" "$final"
rm -rf -- "$pass1" "$pass2"

digest="$(sha256_of "$final")"
log "两次独立构建字节一致；finalizer 门禁预检通过"
printf 'INTEGRATION=%s\nVERSION=%s\nCORE_SHA=%s\nWHEEL=%s\nSHA256=%s\n' \
  "$integration" "$version" "$core_sha" "$final" "$digest"
