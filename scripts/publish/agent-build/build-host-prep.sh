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
#   install-wheels <agent_sha> <core_sha> root；照锚册 PINNED-WHEELS 安装锚定 wheel
#   local-upgrade dbdog-agent [<sha>]     root；「发布到本机」：把留存的 canonical 产物播种进
#   local-upgrade <栈模块>...             本机 cache 后走与内网完全相同的 upgrade.sh 升级路径
#                                         （缓存命中即免下载，其余校验/cutover/验收一步不少）。
#                                         agent 的 sha 缺省按 manifest 锚解析；栈模块要求已按
#                                         release 布局安装（首次安装=栈迁移，owner 安排）
#
# 锚定 wheel 的权威是换锚时落下的 anchors/<sha>/PINNED-WHEELS（摘要记在 ANCHOR-INFO）。
# 旧版准备器建的锚没有它，那类退回按封存 core 现场推导，并会明确提示是旧锚。
set -euo pipefail

umask 0022
export LC_ALL=C

# 根路径可被环境变量覆盖——只为让合成夹具能在不碰真实 cache 的前提下跑这套判定。
CACHE_ROOT="${DBDOG_AGENT_CACHE_ROOT:-/home/dbdog/cache/dbdog-agent}"
INSTALL_DIR="${DBDOG_AGENT_INSTALL_DIR:-/opt/dbdog-agent}"
# 构建不再直接占用宿主 $INSTALL_DIR：构建/最终化在私有挂载命名空间内进行，把
# $INSTALL_ROOTS/<agent_sha> bind 到 $INSTALL_DIR 之上——配方看到的仍是 canonical
# 前缀（前缀烤进 rpath 与 embedded python，产物不可重定位），宿主同路径上自己的
# dbdog-agent 服务全程照跑，构建期不停服。bind 源必须与 /var/lib 同文件系统
# （配方按同一设备核算 root 盘预算），因此固定在 /var/lib 下。
INSTALL_ROOTS="${DBDOG_AGENT_INSTALL_ROOTS:-/var/lib/dbdog-agent-install-roots}"
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
#   drift   —— 封存里有、但与发布锚内容不同。不补锚定 wheel 时产物装的是封存旧版，
#              锚上的改动**静默出不去**（postgres 曾因此把 schema 推荐字段困在构建期
#              补丁里）。2026-08-07 起与 missing 同等对待：必须有锚定 wheel，fail closed。
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

# 换锚时定死的锚定 wheel 清单（每行 "<引擎>\t<相对路径>\t<sha256>"）。
# 这次改动之前建的锚没有这个文件——那类走下面的推导兜底，并明确提示它是旧锚。
pinned_wheels_file() { # <agent_sha>
  printf '%s\n' "$CACHE_ROOT/anchors/$1/PINNED-WHEELS"
}

wheel_path_for() { # <引擎> <core_sha> —— 回显 wheel 路径；没有就回显空串（绝不失败）
  local dir="$CACHE_ROOT/sources/python/$1/$2"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name "datadog_$1-*-py3-none-any.whl" -type f 2>/dev/null \
    | head -1 || true
}

cmd_check() {
  local agent_sha="$1" core_sha="$2" sealed info_core covered engine wheel
  local base_released base_sealed base_rel base_pin_sha reason kind manifest expect_digest actual_digest
  local pw_engine pw_rel pw_sha
  local local_build_dir install_src

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

  section "构建安装根（命名空间 bind 源；宿主 $INSTALL_DIR 与在跑服务不受构建影响）"
  local_build_dir="$(anchor_value "$agent_sha" build_dir || true)"
  install_src="$INSTALL_ROOTS/$agent_sha"
  if [ -n "$local_build_dir" ] && [ -e "$local_build_dir/omnibus.success" ] && \
     find "$local_build_dir/out" -maxdepth 1 -name 'dbdog-agent-*.tar.gz' -print -quit 2>/dev/null | grep -q .; then
    # 配方在 canonical 产物已出时走「验证并复用」路径，根本不碰安装根；
    # 此时 bind 源里留着的正是刚最终化的运行时，要求它为空反而会拦住复跑 publish。
    ok "本锚已有 canonical 产物（publish 验证复用，不要求空 bind 源）"
  elif [ ! -e "$install_src" ] && [ ! -L "$install_src" ]; then
    ok "bind 源尚未创建（publish 构建时自动以 dbdog:dbdog 0755 创建）: $install_src"
  elif [ ! -d "$install_src" ] || [ -L "$install_src" ]; then
    bad "bind 源不是实际目录: $install_src"
    fix "移走后重跑（publish 会重建），或 install -d -o dbdog -g dbdog -m 0755 $install_src"
  elif [ "$(stat -c '%U:%G %a' "$install_src")" != "dbdog:dbdog 755" ]; then
    bad "bind 源属主/模式应为 dbdog:dbdog 0755，实为 $(stat -c '%U:%G %a' "$install_src")"
    fix "chown dbdog:dbdog $install_src && chmod 0755 $install_src"
  elif [ -n "$(find "$install_src" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    bad "bind 源非空——release attempt 只接受空的安装根（上次构建残留？）"
    fix "mv $install_src <该代build目录>/finalized-runtime-<版本> 归档（只移不删）并重建空目录"
  else
    ok "bind 源存在、属主模式正确、为空"
  fi

  section "锚定 wheel（决定发布锚的代码能否进产物）"
  covered="$(anchor_value "$agent_sha" gaussdb_wheel_rel | sed -n 's|^sources/python/\([^/]*\)/.*|\1|p')"
  if [ -n "$covered" ]; then printf '         finalizer 自带覆盖: %s\n' "$covered"; fi
  manifest="$(pinned_wheels_file "$agent_sha")"
  if [ -f "$manifest" ]; then
    expect_digest="$(anchor_value "$agent_sha" pinned_wheels_sha256 || true)"
    actual_digest="$(sha256sum "$manifest" | awk '{ print $1 }')"
    if [ -n "$expect_digest" ] && [ "$expect_digest" != "$actual_digest" ]; then
      bad "PINNED-WHEELS 内容与 ANCHOR-INFO 记录不符（清单被改过）"
    fi
    while IFS="$(printf '\t')" read -r pw_engine pw_rel pw_sha; do
      [ -n "$pw_engine" ] || continue
      if [ ! -f "$CACHE_ROOT/$pw_rel" ]; then
        bad "$pw_engine：锚册登记的 wheel 不在了（$pw_rel）"
      elif [ "$(sha256sum "$CACHE_ROOT/$pw_rel" | awk '{ print $1 }')" != "$pw_sha" ]; then
        bad "$pw_engine：wheel 内容与锚册记录的 sha256 不符"
      elif [ "$(stat -c '%U:%G %a' "$CACHE_ROOT/$pw_rel")" != "root:root 444" ]; then
        bad "$pw_engine：wheel 属主模式应为 root:root 0444"
      else
        ok "$pw_engine：锚册登记的 wheel 就位且内容吻合"
      fi
    done <"$manifest"
  else
    warn "这一代锚没有 PINNED-WHEELS（换锚时的旧版准备器所建），改用推导兜底"
  fi
  # missing 与 drift 同等对待：都必须有锚定 wheel，否则改动/集成静默出不去 —— 硬阻断
  while read -r kind engine; do
    [ -n "$engine" ] || continue
    if [ "$engine" = "$covered" ]; then
      ok "$engine：finalizer 用锚定 wheel 覆盖，锚上的改动会进产物"
      continue
    fi
    case "$kind" in
      missing) reason="封存 core 里没有它，缺 wheel 产物会整个缺掉这个集成" ;;
      drift)   reason="封存 core 里是旧版，缺 wheel 锚上的改动会静默出不去" ;;
      *)       continue ;;
    esac
    wheel="$(wheel_path_for "$engine" "$core_sha")"
    if [ -z "$wheel" ]; then
      bad "$engine：$reason —— 无锚定 wheel"
      fix "开发机 build-integration-wheel.sh --integration $engine --core-sha $core_sha --out ./dist"
      fix "送到 $CACHE_ROOT/sources/python/$engine/$core_sha/（root:root 0444），再 install-wheels"
    elif [ "$(stat -c '%U:%G %a' "$wheel")" != "root:root 444" ]; then
      bad "$engine：wheel 属主模式应为 root:root 0444，实为 $(stat -c '%U:%G %a' "$wheel")"
    elif [ -f "$manifest" ] && ! awk -F'\t' -v e="$engine" '$1 == e { found = 1 } END { exit !found }' "$manifest"; then
      # wheel 躺在磁盘上 ≠ 会被装。install-wheels 照 PINNED-WHEELS 安装，锚册没登记就
      # 一行不装——「盘上有」和「会装上」是两件事，只查前者等于没查。2026-08-10 的 v19
      # 首版锚册漏登记 opengauss/postgres，这里当时报的却是 OK，把静默放行到了构建之后。
      bad "$engine（$kind）：wheel 在盘上但锚册未登记——install-wheels 不会装它，$reason"
      fix "重跑换锚准备器重建 PINNED-WHEELS（先确认 mirror 已含本次锚提交）"
    else
      ok "$engine（$kind）：锚定 wheel 已登记入册（install-wheels 会覆盖装）"
    fi
  done <<EOF
$(classify_engines "$agent_sha" "$core_sha" "$sealed")
EOF

  section "共享基座漂移（漂移必须由锚定 wheel 覆盖，否则改动静默出不去）"
  base_released="$(tree_id "$GIT_DIR_CORE" "$core_sha" datadog_checks_base/datadog_checks/base)"
  base_sealed="$(tree_id "$GIT_DIR_CORE" "$sealed" datadog_checks_base/datadog_checks/base)"
  if [ -n "$base_released" ] && [ "$base_released" != "$base_sealed" ]; then
    base_rel="$(awk -F'\t' '$1 == "datadog_checks_base" { print $2; exit }' "$manifest" 2>/dev/null || true)"
    base_pin_sha="$(awk -F'\t' '$1 == "datadog_checks_base" { print $3; exit }' "$manifest" 2>/dev/null || true)"
    if [ -n "$base_rel" ] && [ -f "$CACHE_ROOT/$base_rel" ] \
      && [ "$(sha256sum "$CACHE_ROOT/$base_rel" | awk '{ print $1 }')" = "$base_pin_sha" ]; then
      ok "datadog_checks_base 有漂移，已由锚册登记的 wheel 覆盖（install-wheels 会装）"
    else
      bad "datadog_checks_base 在发布锚与封存 core 之间有差异，且锚册未覆盖——改动出不去"
      fix "开发机 build-integration-wheel.sh --integration datadog_checks_base --core-sha $core_sha --out ./dist"
      fix "送到 $CACHE_ROOT/sources/python/datadog_checks_base/$core_sha/（root:root 0444），重跑换锚准备器"
      # 列出具体差异：看得见改了什么，才判断得了走哪条路。
      git --git-dir="$GIT_DIR_CORE" diff --name-only "$sealed" "$core_sha" \
        -- datadog_checks_base/datadog_checks 2>/dev/null | while IFS= read -r changed; do
        [ -n "$changed" ] || continue
        printf '         差异: %s\n' "${changed#datadog_checks_base/datadog_checks/}"
      done
    fi
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

# 与 finalizer 装 gaussdb 完全同一套语义：净化环境、离线、不牵连依赖、不写字节码。
# pip 在 bind 了构建安装根的私有命名空间里执行：一来绝不会碰宿主 $INSTALL_DIR 里
# 正在跑的运行时，二来 embedded python 自见的前缀就是 canonical 路径，装出来的
# 脚本 shebang / RECORD 与旧流程逐字节同形。RUNTIME_SRC 由 cmd_install_wheels 设置。
install_one_wheel() { # <引擎> <wheel 绝对路径>
  [ "$(stat -c '%U:%G %a' "$2")" = "root:root 444" ] \
    || die "$1 的 wheel 必须是 root:root 0444: $2"
  env -i HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/bin:/bin \
    PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 \
    unshare --mount --propagation private /usr/bin/bash -c \
    'mount --bind "$1" "$2" && exec "$3" -I -B -m pip install \
       --no-index --no-deps --force-reinstall --no-cache-dir "$4"' \
    _ "$RUNTIME_SRC" "$INSTALL_DIR" "$EMBEDDED_PYTHON" "$2" >/dev/null \
    || die "$1 离线 wheel 安装失败"
  printf 'installed %s from %s\n' "$1" "$2"
}

# 发布收尾的本机装回（「发布到本机」）：不再手工搬运行时/二进制（那是纯拷贝，升级流程
# 的问题只会等到内网才暴露）。这里把构建机上留存的 canonical 产物播种进本机 cache，然后
# 执行与内网完全相同的 upgrade.sh 路径——download_artifact 缓存命中即跳过下载，manifest
# 校验、解包验收、cutover、配置与验收一步不少。
#   local-upgrade dbdog-agent [<agent_sha>]   # sha 缺省时按 manifest 短锚在 anchors/ 解析
#   local-upgrade <栈模块>...                 # dbdog-server/dbdog-web/dbdog-mcp 等
# agent 与栈模块不能混在一次调用里（upgrade.sh 的既有规则）。
LOCAL_BUILD_WORK="${DBDOG_BUILD_WORK:-/home/dbdog/dbdog-release-build}"

local_upgrade_sync_repo() { # → stdout manifest 路径；顺带把检出对齐远端 main
  local repo="${DBDOG_RELEASE_REPO:-/home/dbdog/repo/dbdog-release}"
  [ -d "$repo/.git" ] || die "构建机上没有 dbdog-release 检出: $repo"
  # 检出属主是 dbdog，root 直接 fetch 会往 .git 里留 root 属主对象（同 mirror 的坑）。
  su -s /bin/bash dbdog -c "git -C '$repo' fetch -q origin main && git -C '$repo' merge -q --ff-only origin/main" \
    || die "无法把 $repo fast-forward 到 origin/main"
  [ -f "$repo/manifest.tsv" ] || die "缺 manifest: $repo/manifest.tsv"
  printf '%s' "$repo"
}

local_upgrade_seed() { # <模块> <产物绝对路径> <manifest>；核对一字不差后播种 cache
  local m="$1" artifact="$2" manifest="$3" art_name m_version m_artifact m_sha file_sha cache
  art_name="$(basename "$artifact")"
  m_version="$(awk -F'\t' -v m="$m" '$1==m{print $5; exit}' "$manifest")"
  m_artifact="$(awk -F'\t' -v m="$m" '$1==m{print $6; exit}' "$manifest")"
  m_sha="$(awk -F'\t' -v m="$m" '$1==m{print $7; exit}' "$manifest")"
  [ -n "$m_version" ] && [ "$m_version" != - ] || die "manifest 里 $m 尚未发布"
  [ "$art_name" = "$m_artifact" ] || \
    die "$m 构建产物 $art_name 与 manifest 记录 $m_artifact 不一致——先完成发布到 GH 再发布到本机"
  file_sha="$(sha256sum "$artifact" | awk '{print $1}')"
  [ "$file_sha" = "$m_sha" ] || \
    die "$m 构建产物 SHA-256 与 manifest 不一致（产物=$file_sha manifest=$m_sha）"
  cache="${DBDOG_HOME:-$HOME/dbdog}/cache"
  install -d -m 0755 "$cache"
  install -m 0644 "$artifact" "$cache/$art_name"
  printf 'seeded %s (%s) -> %s\n' "$art_name" "$m_version" "$cache/$art_name"
}

cmd_local_upgrade() { # <模块|agent_sha>...
  local repo manifest agent_sha="" build_dir artifact m short
  local -a stack_modules=()
  [ "$(id -u)" -eq 0 ] || die "local-upgrade 必须以 root 执行"
  repo="$(local_upgrade_sync_repo)"
  manifest="$repo/manifest.tsv"

  local want_agent=0
  for m in "$@"; do
    if [ "$m" = dbdog-agent ]; then
      want_agent=1
    elif printf '%s' "$m" | grep -qE '^[0-9a-f]{40}$'; then
      # 兼容旧用法：直接给 40 位 agent 锚
      want_agent=1
      agent_sha="$m"
    else
      stack_modules+=("$m")
    fi
  done
  if [ "$want_agent" -eq 1 ] && [ "${#stack_modules[@]}" -gt 0 ]; then
    die "dbdog-agent 位于 DB 主机语义，不能与栈模块混在一次本机升级里（分两次跑）"
  fi

  if [ "$want_agent" -eq 1 ]; then
    if [ -z "$agent_sha" ]; then
      # 从 manifest 的 agent:<短锚> 在 anchors/ 解析出全长锚——发布到本机永远装 manifest 记录的那个。
      short="$(awk -F'\t' '$1=="dbdog-agent"{print $8; exit}' "$manifest" | sed -n 's/^agent:\([0-9a-f]*\),.*/\1/p')"
      [ -n "$short" ] || die "manifest 里读不到 dbdog-agent 的源码锚"
      agent_sha="$(find "$CACHE_ROOT/anchors" -maxdepth 1 -type d -name "${short}*" -printf '%f\n' 2>/dev/null | head -1)"
      [ -n "$agent_sha" ] || die "anchors/ 里没有匹配 manifest 锚 ${short} 的锚目录——这台构建机没出过该版本？"
    fi
    build_dir="$(anchor_value "$agent_sha" build_dir)" || die "读不到 ANCHOR-INFO"
    [ -n "$build_dir" ] || die "ANCHOR-INFO 缺 build_dir"
    artifact="$(find "$build_dir/out" -maxdepth 1 -name 'dbdog-agent-*.tar.gz' -print -quit 2>/dev/null)"
    [ -n "$artifact" ] || die "该锚还没有 canonical 产物（先完成 publish/finalize）: $build_dir/out"
    local_upgrade_seed dbdog-agent "$artifact" "$manifest"
    exec "$repo/scripts/upgrade.sh" dbdog-agent
  fi

  [ "${#stack_modules[@]}" -gt 0 ] || die "用法: local-upgrade dbdog-agent [<agent_sha>] | local-upgrade <栈模块>..."
  for m in "${stack_modules[@]}"; do
    # 栈模块的「发布到本机」只覆盖**已按 release 布局安装**的模块。这台构建机上的
    # dev 栈（dbdogt-* 单元）若尚未迁移到 release 布局，首次安装涉及端口/数据/服务
    # 切换，必须由 owner 按迁移计划安排窗口，不能由本命令顺手做掉。
    [ -e "${DBDOG_HOME:-$HOME/dbdog}/modules/$m/current" ] || \
      die "$m 尚未按 release 布局安装（${DBDOG_HOME:-$HOME/dbdog}/modules/$m/current 不存在）——首次安装是栈迁移动作，见 publish skill 的迁移说明"
    artifact="$LOCAL_BUILD_WORK/$m/out/$(awk -F'\t' -v m="$m" '$1==m{print $6; exit}' "$manifest")"
    [ -f "$artifact" ] || die "$m 在本构建机没有留存的构建产物: $artifact（发布到 GH 的那次构建须出自本机）"
    local_upgrade_seed "$m" "$artifact" "$manifest"
  done
  exec "$repo/scripts/upgrade.sh" "${stack_modules[@]}"
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
  local agent_sha="$1" core_sha="$2" sealed covered engine wheel kind manifest rel sha
  [ "$(id -u)" -eq 0 ] || die "install-wheels 必须以 root 执行"
  RUNTIME_SRC="$INSTALL_ROOTS/$agent_sha"
  [ -x "$RUNTIME_SRC/embedded/bin/python3" ] || \
    die "构建安装根里没有 embedded Python（先跑 omnibus 构建；命名空间构建的运行时应在 $RUNTIME_SRC）"
  sealed="$(anchor_value "$agent_sha" omnibus_core_sha)" || die "读不到 ANCHOR-INFO"
  covered="$(anchor_value "$agent_sha" gaussdb_wheel_rel | sed -n 's|^sources/python/\([^/]*\)/.*|\1|p')"

  manifest="$(pinned_wheels_file "$agent_sha")"
  if [ -f "$manifest" ]; then
    # 锚册是权威：换锚时已按封存 core 判定并 fail closed，这里照单安装即可。
    while IFS="$(printf '\t')" read -r engine rel sha; do
      [ -n "$engine" ] || continue
      if [ "$engine" = "$covered" ]; then continue; fi  # finalizer 自己装
      wheel="$CACHE_ROOT/$rel"
      [ -f "$wheel" ] || die "锚册登记的 wheel 不在了: $rel"
      [ "$(sha256sum "$wheel" | awk '{ print $1 }')" = "$sha" ] \
        || die "$engine 的 wheel 内容与锚册记录不符"
      install_one_wheel "$engine" "$wheel"
    done <"$manifest"
    return 0
  fi
  printf '注意: 这一代锚没有 PINNED-WHEELS（旧版准备器所建），改用推导兜底\n' >&2
  classify_engines "$agent_sha" "$core_sha" "$sealed" | while read -r kind engine; do
    # 只补「封存 core 里没有」的；drift 那类装的是封存版，不在这里越权替换。
    if [ "$kind" != missing ]; then continue; fi
    if [ "$engine" = "$covered" ]; then continue; fi   # 这个由 finalizer 自己装
    wheel="$(wheel_path_for "$engine" "$core_sha")"
    [ -n "$wheel" ] || die "$engine 的锚定 wheel 未就位（先跑 check）"
    install_one_wheel "$engine" "$wheel"
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
  local-upgrade)
    [ "$#" -ge 2 ] || die "用法: build-host-prep.sh local-upgrade dbdog-agent [<agent_sha>] | local-upgrade <栈模块>..."
    shift
    cmd_local_upgrade "$@"
    ;;
  *)
    die "用法: build-host-prep.sh check|fetch-mirrors|install-wheels|local-upgrade [参数...]"
    ;;
esac
