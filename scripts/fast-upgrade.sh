#!/usr/bin/env bash
# 快升级（用户话术「部署」）：dev 日常迭代的本机部署。与慢升级共用**同一套部署代码
# 路径与同一套落盘布局**，只在两处更快：包来源（本机按 origin/main 出包，不经 GitHub/
# manifest 版本仪式）与 agent 的粒度（组件级替换，不整套 omnibus 重建）。
#
# 用法（构建机上，root）：
#   fast-upgrade.sh dbdog-server [dbdog-web dbdog-mcp ...]   # 栈模块（本机 arm）
#   fast-upgrade.sh dbdog-agent                              # 本机 agent（arm 组件级）
#   （x86 靶机的 agent 快升级仍是它的三步本机构建，由操作侧对那台机执行——
#     见 dbdog-agent/dbdog-deploy/scripts/x86-local/README.md；「部署 agent」话术
#     默认两台都做，编排在 publish skill。）
#
# 栈模块：各源仓 fast-forward 到 origin/main → 与正式发布**相同的 recipe** 出包
#（版本号 <manifest版本>-dev.g<短sha>）→ `upgrade.sh --artifact` 安装——staging/身份/
# 钩子/服务/OAuth 验收与慢升级逐行相同。
#
# agent（arm）：/opt/dbdog-agent 是安装器管理的 release 布局，快升级在**同一布局**上做
# 组件级替换（与 x86 三步同构）：Go 二进制 + 4 个集成 wheel + 重启验收；同时把
# .dbdog-artifact-sha256 改写为 dev 标记——下次慢升级必然整套换回 canonical，
# 不会把 dev 组件误当发布产物留在机上。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${DBDOG_REPO_ROOT:-/home/dbdog/repo}"
BUILD_WORK="${DBDOG_BUILD_WORK:-/home/dbdog/dbdog-release-build}"
TOOL_PATH="${DBDOG_TOOL_PATH:-/home/dbdog/tools/go/bin:/home/dbdog/tools/node/bin:/home/dbdog/.cargo/bin}"
PG_PREFIX="${DBDOG_PG_PREFIX:-/home/dbdog/tools/pgsql}"
CH_BIN="${DBDOG_CH_BIN:-/home/dbdog/tools/clickhouse/bin/clickhouse}"
STACK_USER="${DBDOG_STACK_USER:-dbdog}"
AGENT_RUNTIME=/opt/dbdog-agent
AGENT_CACHE=/home/dbdog/cache/dbdog-agent

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[ "$(id -u)" -eq 0 ] || die "fast-upgrade 必须以 root 执行（栈构建会自动降到 $STACK_USER）"
[ "$#" -ge 1 ] || die "用法: fast-upgrade.sh <模块>...（dbdog-server/dbdog-web/dbdog-mcp 或 dbdog-agent）"

as_stack_user() { # <cmd...>；构建与栈安装都以栈属主身份执行
  runuser -u "$STACK_USER" -- env HOME="/home/$STACK_USER" "$@"
}

ff_repo() { # <仓目录>；fast-forward 到 origin/main，输出全长 sha
  as_stack_user git -C "$1" fetch -q origin
  as_stack_user git -C "$1" merge -q --ff-only origin/main \
    || die "$1 无法 fast-forward 到 origin/main（本地有分叉改动？快升级只部署已推送的提交）"
  as_stack_user git -C "$1" rev-parse origin/main
}

manifest_field() { # <模块> <列>
  awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c; exit}' "$SCRIPTS_DIR/../manifest.tsv"
}

fast_stack_one() { # <模块>
  local m="$1" src sha short mver version recipe out line rpath
  case "$m" in
    dbdog-server | dbdog-web | dbdog-mcp) ;;
    *) die "快升级不支持模块: $m（栈仅 dbdog-server/dbdog-web/dbdog-mcp；三方件走正式发布）" ;;
  esac
  src="$REPO_ROOT/$m"
  [ -d "$src/.git" ] || die "构建机上没有源仓: $src"
  sha="$(ff_repo "$src")"
  short="$(printf '%.7s' "$sha")"
  mver="$(manifest_field "$m" 5)"
  [ -n "$mver" ] && [ "$mver" != - ] || die "$m 在 manifest 里没有已发布版本，无法命名 dev 版本"
  version="${mver}-dev.g${short}"
  recipe="$SCRIPTS_DIR/publish/recipes/$m.sh"
  [ -f "$recipe" ] || die "缺 recipe: $recipe"
  local arch=aarch64
  [ "$m" != dbdog-mcp ] || arch=noarch
  log "[$m] 出包 $version（源 $short，与正式发布同 recipe）"
  out="$(as_stack_user env MODULE="$m" VERSION="$version" SHA="$sha" CORE_SHA="" \
      ARCH="$arch" REPO_ROOT="$REPO_ROOT" BUILD_WORK="$BUILD_WORK" TOOL_PATH="$TOOL_PATH" \
      PG_PREFIX="$PG_PREFIX" CH_BIN="$CH_BIN" bash "$recipe")" \
    || die "[$m] recipe 构建失败"
  line="$(printf '%s\n' "$out" | tail -n1)"
  rpath="${line#*$'\t'}"
  [ -f "$rpath" ] || die "[$m] recipe 输出的产物路径不存在: $rpath"
  log "[$m] 安装（与慢升级同一套 upgrade.sh 代码路径）"
  as_stack_user bash -c "cd /home/$STACK_USER && exec '$SCRIPTS_DIR/upgrade.sh' --artifact '$rpath' '$m'" \
    || die "[$m] 快升级安装失败"
}

fast_agent_local() {
  local agent_repo="$REPO_ROOT/dbdog-agent" core_repo="$REPO_ROOT/dbdog-agent-core"
  local agent_sha core_sha short official patchelf_bin wheel_dir e wheel cached
  [ -x "$AGENT_RUNTIME/bin/agent/agent" ] || die "本机没有 release 布局的 agent 运行时: $AGENT_RUNTIME"
  agent_sha="$(ff_repo "$agent_repo")"
  core_sha="$(ff_repo "$core_repo")"
  short="$(printf '%.7s' "$agent_sha")"

  # 与 x86 三步同一前提：fork 未改 rtloader 时才可复用打包版（embedded 3.13 的那份）。
  official="$(awk -F'\t' '$1=="agent_official_commit"{print $2}' "$agent_repo/dbdog-deploy/RELEASE-BASELINE.tsv")"
  [ -n "$official" ] || die "读不到 agent_official_commit"
  as_stack_user git -C "$agent_repo" diff --quiet "$official"..origin/main -- rtloader/ \
    || die "rtloader 相对上游基线已有改动，组件级快升级前提失效（须整套 omnibus 慢路径）"

  # bazel（schema 生成步骤）离线化：复用 omnibus 封存的 distdir/downloader 配置——这台机
  # 对部分外网源超时，在线拉取会卡死；缓存是现成的。
  #
  # ⚠️ repository_cache 必须**另起一份 dev 专用目录**，绝不能指向 `bazel/repository`。
  # 那个目录不是"只读缓存"，它就是 omnibus seal 本体：seal 对这一类按
  # `storage=cache-reference` 封存——只记 sha256，不存内容副本（CATEGORY-SUMMARY 里
  # bazel-repository-expanded 的 reference_only_files 等于其 files）。而 bazel 对
  # repository_cache 是可写的，会新建条目、回收旧条目。2026-08-10 dbdog.9 发布因此撞墙：
  # 快升级跑过之后，7 个条目被 GC 掉共 26783 个文件，seal VERIFY 直接失败，发布路径断了，
  # 且内容在 seal 里无副本、不可从 git 重建——只能靠别的机器拷回来。
  #
  # dev 目录用硬链接播种：几乎不占盘、离线即热，且 bazel 之后的删除/回收只摘掉 dev 这边的
  # 目录项，封存路径的链接照在。
  # 注意判据是「缺文件 **或** 文件里还指着封存目录」：早期版本写死了封存路径，只判存在
  # 会让已经落地的坏配置永远留着，下一次快升级继续啃 seal。
  local dev_repo_cache="$AGENT_CACHE/bazel/repository-dev"
  if [ ! -f "$agent_repo/user.bazelrc" ] \
    || grep -qE "^common --repository_cache=$AGENT_CACHE/bazel/repository/?\$" "$agent_repo/user.bazelrc"; then
    local dl_cfg
    dl_cfg="$(find "$AGENT_CACHE/manifests" -maxdepth 3 -name bazel-downloader.cfg 2>/dev/null | head -1)"
    if [ ! -d "$dev_repo_cache" ] && [ -d "$AGENT_CACHE/bazel/repository" ]; then
      log "[agent] 硬链接播种 dev bazel repository_cache（不动封存目录）"
      as_stack_user cp -al "$AGENT_CACHE/bazel/repository" "$dev_repo_cache" \
        || die "播种 dev repository_cache 失败: $dev_repo_cache"
    fi
    as_stack_user bash -c "cat >'$agent_repo/user.bazelrc'" <<BRC
startup --host_jvm_args=-Xms128m
startup --host_jvm_args=-Xmx1200m
common --repository_cache=$dev_repo_cache
common --http_max_parallel_downloads=2
common --repo_env=GOSUMDB
${dl_cfg:+common --downloader_config=$dl_cfg}
common --distdir=$AGENT_CACHE/distdir
BRC
    log "[agent] 已落 dev 仓 user.bazelrc（dev 专用 repository_cache，封存 distdir 只读复用）"
  fi

  log "[agent] dda 构建 Go agent（源 $short，--build-exclude=systemd）"
  # 工具链 PATH 与 omnibus overlay runner 同源（dda-venv/ruby/python312/go/tools/node/cargo）。
  local build_path="/home/dbdog/tools/dda-venv/bin:/home/dbdog/tools/ruby27/bin:/home/dbdog/tools/python312/bin:/home/dbdog/tools/go/bin:/home/dbdog/tools/bin:/home/dbdog/tools/node/bin:/home/dbdog/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
  # 不建 rtloader：链接面直接取 embedded 运行时（lib + include 都在），与运行期同源；
  # arm 的 tools/python312 是静态非 PIC，本地建 rtloader 必然 -fPIC 失败，也没必要建。
  as_stack_user bash -c "cd '$agent_repo' && unset LD_LIBRARY_PATH && export PATH='$build_path' && exec dda inv -- agent.build --build-exclude=systemd --exclude-rtloader --rtloader-root=$AGENT_RUNTIME/embedded" \
    || die "agent Go 构建失败（构建机应有 /home/dbdog/tools/dda-venv；见 omnibus 构建日志里的 DDA 行）"
  [ -f "$agent_repo/bin/agent/agent" ] || die "构建产物缺失: $agent_repo/bin/agent/agent"

  log "[agent] 构建/复用 4 个集成 wheel（core $(printf '%.7s' "$core_sha")）"
  wheel_dir="$(mktemp -d /tmp/dbdog-fast-wheels.XXXXXX)"
  for e in datadog_checks_base gaussdb opengauss postgres; do
    cached="$(find "$AGENT_CACHE/sources/python/$e/$core_sha" -maxdepth 1 -name '*.whl' -print -quit 2>/dev/null || true)"
    if [ -n "$cached" ]; then
      cp "$cached" "$wheel_dir/"
      log "[agent] $e：复用锚册 wheel（core 未动）"
    else
      as_stack_user bash "$SCRIPTS_DIR/publish/agent-build/build-integration-wheel.sh" \
        --core-repo "$core_repo" --core-sha "$core_sha" --integration "$e" --out "$wheel_dir" >/dev/null \
        || die "$e wheel 构建失败"
      log "[agent] $e：按 core HEAD 新建 wheel"
    fi
  done

  log "[agent] 停服 → 换 Go 二进制 + 装 wheel → 起服（同一 release 布局，组件级）"
  systemctl stop dbdog-agent-trace.service dbdog-agent-process.service dbdog-agent.service dbdog-agent-sysprobe.service
  install -m 0755 "$agent_repo/bin/agent/agent" "$AGENT_RUNTIME/bin/agent/agent"
  patchelf_bin="$(find "$AGENT_CACHE/tools/patchelf" -name patchelf -type f 2>/dev/null | head -1)"
  [ -n "$patchelf_bin" ] || die "找不到固定 patchelf"
  "$patchelf_bin" --set-rpath "$AGENT_RUNTIME/embedded/lib" "$AGENT_RUNTIME/bin/agent/agent"
  for wheel in "$wheel_dir"/*.whl; do
    env -i HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/bin:/bin \
      PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 \
      "$AGENT_RUNTIME/embedded/bin/python3" -I -B -m pip install \
      --no-index --no-deps --force-reinstall --no-cache-dir "$wheel" >/dev/null \
      || die "wheel 安装失败: $wheel"
  done
  rm -rf "$wheel_dir"

  # 身份失效：dev 组件不得冒充发布产物。慢升级看到非 manifest SHA 会整套换回 canonical。
  chmod u+w "$AGENT_RUNTIME/.dbdog-artifact-sha256" 2>/dev/null || true
  printf 'fast-deploy-dev agent:%s core:%.7s %s\n' "$short" "$core_sha" "$(date -u +%FT%TZ)" \
    >"$AGENT_RUNTIME/.dbdog-artifact-sha256"
  chmod 0444 "$AGENT_RUNTIME/.dbdog-artifact-sha256"

  systemctl start dbdog-agent-sysprobe.service dbdog-agent.service \
    dbdog-agent-trace.service dbdog-agent-process.service
  sleep 8
  local unit v
  for unit in dbdog-agent-sysprobe dbdog-agent dbdog-agent-trace dbdog-agent-process; do
    systemctl is-active --quiet "$unit" || die "快升级后服务未运行: $unit"
  done
  v="$("$AGENT_RUNTIME/bin/agent/agent" version)" || die "agent version 执行失败"
  printf '%s\n' "$v"
  printf '%s' "$v" | grep -q "$short" || die "agent version 未带上本次源码短 sha ${short}——装的不是刚构建的二进制？"
  log "[agent] 本机（arm）快升级完成；x86 靶机按 x86-local 三步另行执行"
}

want_agent=0
declare -a stack=()
for m in "$@"; do
  case "$m" in
    dbdog-agent) want_agent=1 ;;
    *) stack+=("$m") ;;
  esac
done
if [ "$want_agent" -eq 1 ] && [ "${#stack[@]}" -gt 0 ]; then
  die "dbdog-agent 与栈模块不混在一次快升级里（分两次跑）"
fi

if [ "$want_agent" -eq 1 ]; then
  fast_agent_local
else
  for m in "${stack[@]}"; do
    fast_stack_one "$m"
  done
fi
log "快升级完成: $*"
