#!/usr/bin/env bash
# 构建机侧的发布前置条件：一次查全、按需修复。在构建机上执行。
#
# 为什么需要它：agent 发布的前置条件散在四处，且配方遇到第一个不满足就 die，
# 只能一轮一轮串行发现（2026-08-06 那次为此来回五轮）。更要命的是其中两条
# 静默失效过：openGauss 因为不在封存 core 里而整个丢出产物（round-20 该引擎零遥测），
# base 层的改动因为同样原因没进包却无人察觉。
#
# 关键事实（换构建机的人必须先知道这条）：
#   omnibus 只从 **被 seal 钉死的 core**（ANCHOR-INFO 的 omnibus_core_sha）装 Python 包；
#   发布锚 core 的代码只有通过「锚定 wheel」才进得了产物。
#   所以「改了 agent-core 就会随下次发布出去」是错的——没有 wheel 兜底的包不会出去。
#
# 子命令：
#   check <agent_sha> <core_sha>          只读；报全部前置条件与漂移，缺项给修复命令
#   fetch-mirrors                         以属主 dbdog 身份 fetch 两个 bare mirror
#   install-wheels <agent_sha> <core_sha> root；装上 check 判定需要的锚定 wheel
set -euo pipefail

umask 0022
export LC_ALL=C

CACHE_ROOT=/home/dbdog/cache/dbdog-agent
INSTALL_DIR=/opt/dbdog-agent
GIT_DIR_AGENT="$CACHE_ROOT/git/dbdog-agent.git"
GIT_DIR_CORE="$CACHE_ROOT/git/dbdog-agent-core.git"
EMBEDDED_PYTHON="$INSTALL_DIR/embedded/bin/python3"

ok() { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [缺]   %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  [注意] %s\n' "$*"; }
fix() { printf '         修复: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s\n' "$*"; }

FAILURES=0

anchor_value() { # <agent_sha> <键>
  local info="$CACHE_ROOT/anchors/$1/ANCHOR-INFO"
  [ -f "$info" ] || return 1
  sed -n "s/^$2=//p" "$info" | head -1
}

git_has() { # <gitdir> <sha>
  git --git-dir="$1" cat-file -e "$2^{commit}" 2>/dev/null
}

# tree_id <gitdir> <sha> <路径> —— 路径不存在时回显空串。
# 必须带 --verify：不带的话 rev-parse 解析失败会把参数原样回显，非空判断就全废了
# （openGauss 会被误判成「只是漂移」，而它恰恰是「封存里根本没有」那一类）。
tree_id() {
  git --git-dir="$1" rev-parse --verify --quiet "$2:$3" 2>/dev/null || true
}

# 产物里的 Python 包全部来自封存 core，只有锚定 wheel 能把发布锚的代码带进去。
# 据此把「conf 已发」的引擎分成两类，严重程度完全不同：
#
#   missing —— 封存 core 里根本没有这个引擎。产物会整个缺掉它，而我们又发了它的
#              conf，采集静默归零。**硬阻断**，必须有锚定 wheel。（openGauss 就是这样
#              丢过两次，第一次让 round-20 整轮作废。）
#   drift   —— 封存里有、但与发布锚内容不同。产物能跑，装的是封存版；锚上对它的
#              改动这次不会出去。**只报告**，因为绝大多数只是上游漂移，不是我们改的。
classify_engines() { # <agent_sha> <core_sha> <sealed_sha> -> 每行 "missing|drift <引擎>"
  local agent_sha="$1" core_sha="$2" sealed="$3" entry name released sealed_tree
  git --git-dir="$GIT_DIR_AGENT" ls-tree --name-only \
    "$agent_sha:dbdog-deploy/conf/conf.d" 2>/dev/null | while IFS= read -r entry; do
    case "$entry" in *.d/) name="${entry%.d/}" ;; *.d) name="${entry%.d}" ;; *) continue ;; esac
    case "$name" in '' | *[!a-z0-9_]*) continue ;; esac
    released="$(tree_id "$GIT_DIR_CORE" "$core_sha" "$name/datadog_checks/$name")"
    [ -n "$released" ] || continue          # 该引擎在发布锚里没有 Python 集成，不入集合
    sealed_tree="$(tree_id "$GIT_DIR_CORE" "$sealed" "$name/datadog_checks/$name")"
    if [ -z "$sealed_tree" ]; then
      printf 'missing %s\n' "$name"
    elif [ "$released" != "$sealed_tree" ]; then
      printf 'drift %s\n' "$name"
    fi
  done
}

wheel_path_for() { # <引擎> <core_sha> —— 回显 wheel 路径；没有就回显空串（绝不失败）
  local dir="$CACHE_ROOT/sources/python/$1/$2"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name "datadog_$1-*-py3-none-any.whl" -type f 2>/dev/null \
    | head -1 || true
}

cmd_check() {
  local agent_sha="$1" core_sha="$2" sealed info_core covered engine wheel
  local base_released base_sealed drifted kind

  section "锚控制物"
  if anchor_value "$agent_sha" anchor_info_format >/dev/null 2>&1; then
    ok "ANCHOR-INFO 存在: anchors/$agent_sha/"
  else
    bad "缺 anchors/$agent_sha/ANCHOR-INFO"
    fix "以 root 跑 prepare-agent-anchor.sh 换锚到 ${agent_sha:0:12}"
    printf '\n前置条件缺失 %s 项\n' "$FAILURES"
    return 1
  fi
  info_core="$(anchor_value "$agent_sha" integration_core_sha)"
  if [ "$info_core" = "$core_sha" ]; then
    ok "ANCHOR-INFO 的 core 锚与基线一致"
  else
    bad "ANCHOR-INFO core 锚为 ${info_core}，基线要求 ${core_sha}"
  fi
  sealed="$(anchor_value "$agent_sha" omnibus_core_sha)"
  [ -n "$sealed" ] || die "ANCHOR-INFO 缺 omnibus_core_sha"
  printf '         omnibus 封存 core: %s（产物里未被 wheel 覆盖的包都来自它）\n' "${sealed:0:12}"

  section "Git mirror"
  if git_has "$GIT_DIR_AGENT" "$agent_sha"; then
    ok "agent mirror 有 ${agent_sha:0:12}"
  else
    bad "agent mirror 缺 ${agent_sha:0:12}"
    fix "build-host-prep.sh fetch-mirrors"
  fi
  if git_has "$GIT_DIR_CORE" "$core_sha"; then
    ok "core mirror 有 ${core_sha:0:12}"
  else
    bad "core mirror 缺 ${core_sha:0:12}"
    fix "build-host-prep.sh fetch-mirrors"
  fi

  section "安装根 $INSTALL_DIR"
  if [ ! -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
    bad "不是实际目录"
    fix "install -d -o dbdog -g dbdog -m 0755 $INSTALL_DIR"
  elif [ "$(stat -c '%U:%G %a' "$INSTALL_DIR")" != "dbdog:dbdog 755" ]; then
    bad "属主/模式应为 dbdog:dbdog 0755，实为 $(stat -c '%U:%G %a' "$INSTALL_DIR")"
    fix "chown dbdog:dbdog $INSTALL_DIR && chmod 0755 $INSTALL_DIR"
  elif [ -n "$(find "$INSTALL_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    bad "非空——release attempt 只接受空的安装根"
    fix "systemctl stop dbdog-agent（它占着这个运行时）"
    fix "mv $INSTALL_DIR <上一代build目录>/finalized-runtime-<上一版本> 并重建空目录"
  else
    ok "存在、属主模式正确、为空"
  fi
  if pgrep -f "$INSTALL_DIR/bin/agent/agent run" >/dev/null 2>&1; then
    bad "有进程正在使用该运行时（会在 finalizer 清理后重写 run/，导致打包失败）"
    fix "systemctl stop dbdog-agent"
  else
    ok "没有进程占用该运行时"
  fi

  section "锚定 wheel（决定发布锚的代码能否进产物）"
  covered="$(anchor_value "$agent_sha" gaussdb_wheel_rel | sed -n 's|^sources/python/\([^/]*\)/.*|\1|p')"
  if [ -n "$covered" ]; then printf '         finalizer 自带覆盖: %s\n' "$covered"; fi
  drifted=""
  while read -r kind engine; do
    [ -n "$engine" ] || continue
    if [ "$kind" = drift ]; then
      if [ "$engine" = "$covered" ]; then
        ok "$engine：finalizer 用锚定 wheel 覆盖，锚上的改动会进产物"
      else
        drifted="$drifted $engine"
      fi
      continue
    fi
    # missing：封存 core 里没有，产物会整个缺掉它 —— 硬阻断
    wheel="$(wheel_path_for "$engine" "$core_sha")"
    if [ -z "$wheel" ]; then
      bad "$engine：封存 core 里没有它，且无锚定 wheel —— 产物会整个缺掉这个集成"
      fix "开发机 build-integration-wheel.sh --integration $engine --core-sha $core_sha --out ./dist"
      fix "送到 $CACHE_ROOT/sources/python/$engine/$core_sha/（root:root 0444），再 install-wheels"
    elif [ "$(stat -c '%U:%G %a' "$wheel")" != "root:root 444" ]; then
      bad "$engine：wheel 属主模式应为 root:root 0444，实为 $(stat -c '%U:%G %a' "$wheel")"
    else
      ok "$engine：封存 core 里没有，已由锚定 wheel 补上（install-wheels 会装）"
    fi
  done <<EOF
$(classify_engines "$agent_sha" "$core_sha" "$sealed")
EOF
  if [ -n "$drifted" ]; then
    warn "以下引擎封存 core 里有、但与发布锚内容不同，产物装的是**封存版**:${drifted}"
    warn "它们在发布锚上的改动这次不会出去；要出去得推进 omnibus seal 或给它加锚定 wheel"
  fi

  section "共享基座漂移（不阻断发布，但决定改动是否白改）"
  base_released="$(tree_id "$GIT_DIR_CORE" "$core_sha" datadog_checks_base/datadog_checks/base)"
  base_sealed="$(tree_id "$GIT_DIR_CORE" "$sealed" datadog_checks_base/datadog_checks/base)"
  if [ -n "$base_released" ] && [ "$base_released" != "$base_sealed" ]; then
    warn "datadog_checks_base 在发布锚与封存 core 之间有差异"
    warn "产物里的 base 来自封存 core，锚上对 base 的改动**不会进这次产物**"
    warn "要出去只能推进 omnibus seal（编译域改动，不是发一次版能解决的）"
  else
    ok "datadog_checks_base 与封存 core 一致"
  fi

  printf '\n'
  if [ "$FAILURES" -gt 0 ]; then
    printf '前置条件缺失 %s 项，按上面的修复命令处理后重跑 check\n' "$FAILURES"
    return 1
  fi
  printf '全部前置条件满足，可以发布\n'
}

cmd_fetch_mirrors() {
  local d
  for d in "$GIT_DIR_AGENT" "$GIT_DIR_CORE"; do
    [ -d "$d" ] || die "mirror 不存在: $d"
    # mirror 属主是 dbdog；用 root fetch 会在里面留下 root 属主的对象。
    if [ "$(id -u)" -eq 0 ]; then
      su -s /bin/bash dbdog -c "git --git-dir='$d' fetch origin" >/dev/null
    else
      git --git-dir="$d" fetch origin >/dev/null
    fi
    printf 'fetched %s\n' "$(basename "$d")"
  done
}

cmd_install_wheels() {
  local agent_sha="$1" core_sha="$2" sealed covered engine wheel kind
  [ "$(id -u)" -eq 0 ] || die "install-wheels 必须以 root 执行"
  [ -x "$EMBEDDED_PYTHON" ] || die "运行时里没有 embedded Python（先跑 omnibus 构建）"
  sealed="$(anchor_value "$agent_sha" omnibus_core_sha)" || die "读不到 ANCHOR-INFO"
  covered="$(anchor_value "$agent_sha" gaussdb_wheel_rel | sed -n 's|^sources/python/\([^/]*\)/.*|\1|p')"

  classify_engines "$agent_sha" "$core_sha" "$sealed" | while read -r kind engine; do
    # 只补「封存 core 里没有」的；drift 那类装的是封存版，不在这里越权替换。
    if [ "$kind" != missing ]; then continue; fi
    if [ "$engine" = "$covered" ]; then continue; fi   # 这个由 finalizer 自己装
    wheel="$(wheel_path_for "$engine" "$core_sha")"
    [ -n "$wheel" ] || die "$engine 的锚定 wheel 未就位（先跑 check）"
    [ "$(stat -c '%U:%G %a' "$wheel")" = "root:root 444" ] \
      || die "$engine 的 wheel 必须是 root:root 0444"
    # 与 finalizer 装 gaussdb 完全同一套语义：净化环境、离线、不牵连依赖、不写字节码。
    env -i HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/bin:/bin \
      PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 \
      "$EMBEDDED_PYTHON" -I -B -m pip install \
      --no-index --no-deps --force-reinstall --no-cache-dir "$wheel" >/dev/null \
      || die "$engine 离线 wheel 安装失败"
    printf 'installed %s from %s\n' "$engine" "$wheel"
  done
}

case "${1:-}" in
  check)
    [ "$#" -eq 3 ] || die "用法: build-host-prep.sh check <agent_sha> <core_sha>"
    cmd_check "$2" "$3"
    ;;
  fetch-mirrors)
    [ "$#" -eq 1 ] || die "用法: build-host-prep.sh fetch-mirrors"
    cmd_fetch_mirrors
    ;;
  install-wheels)
    [ "$#" -eq 3 ] || die "用法: build-host-prep.sh install-wheels <agent_sha> <core_sha>"
    cmd_install_wheels "$2" "$3"
    ;;
  *)
    die "用法: build-host-prep.sh check|fetch-mirrors|install-wheels [参数...]"
    ;;
esac
