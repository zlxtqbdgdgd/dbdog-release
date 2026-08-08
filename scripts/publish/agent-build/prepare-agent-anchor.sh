#!/usr/bin/env bash
# 换锚准备器：把上一代的构建控制物按新的 release source 锚机械改写成新一代，并落下一份
# ANCHOR-INFO 作为「这一代锚的控制物身份」的唯一来源。
#
# 背景：control overlay 的 runner/CONTROL-INFO、finalizer 与它的 root 入口 wrapper 都内嵌
# release source SHA、integration core SHA 与含短 SHA 的构建目录路径。过去换锚要人肉逐处
# 补，漏一处就是几小时构建之后才暴露的失败（8585423 漏了 runner 与 CONTROL.sha256 自身哈希、
# b6e9982 漏了 outputs manifest、7f8e53b 漏了 seed marker，还有一处 finalizer/wrapper 一直
# 没跟上）。本脚本把这套改写变成一次可复核的机械操作。
#
# 用法（构建机上以 root 执行）：
#   prepare-agent-anchor.sh \
#     --from-agent-sha <40hex> --from-core-sha <40hex> --from-overlay-generation vN \
#     --to-agent-sha <40hex>   --to-core-sha <40hex>   --to-overlay-generation vN+1 \
#     --reason <单行下划线短语> \
#     [--from-finalizer <path> --from-wrapper <path>]   # 首次迁移时指向 controls/ 下的旧控制物
#
# 不做的事：不碰上一代的任何字节（历史控制物不可变），不生成 GaussDB wheel（它由源码仓的
# 干净归档 + SOURCE_DATE_EPOCH 独立构建），不动 v7 manifest 与 v10 seal。
set -euo pipefail

umask 0022
IFS=$' \t\n'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
unset BASH_ENV CDPATH ENV GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
  GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_WORK_TREE

readonly CACHE_ROOT=/home/dbdog/cache/dbdog-agent
readonly WORK_ROOT=/home/dbdog/work
readonly OMNIBUS_CORE_SHA=7a4247599b029f1aca10d2cb63491d535fbd502f
readonly SEALED_ORIGIN_AGENT_SHA=4c39489b8c0b7fb7a46af88062fb9aadf2c08264
readonly OMNIBUS_RUBY_SHA=5b00eeae9fa553e5ae445ba91a0a0ab4c21aa749
readonly OVERLAY_SUFFIX="$OMNIBUS_CORE_SHA-aarch64-kylin10-v7-omnibus-kylin-platform"
readonly ANCHOR_INFO_FORMAT=dbdog-agent-anchor-v1

log() { printf '[prepare-agent-anchor] %s\n' "$*" >&2; }
die() { printf '[prepare-agent-anchor] ERROR: %s\n' "$*" >&2; exit 1; }

require_sha40() {
  local label=$1 value=$2
  [[ $value =~ ^[0-9a-f]{40}$ ]] || die "$label 必须是完整的小写 40 位提交 SHA: $value"
}

require_generation() {
  local label=$1 value=$2
  [[ $value =~ ^v[1-9][0-9]*$ ]] || die "$label 必须形如 v<N>: $value"
}

file_sha256() {
  local digest
  digest=$(sha256sum -- "$1") || die "无法计算 SHA-256: $1"
  printf '%s\n' "${digest%% *}"
}

from_agent_sha='' from_core_sha='' from_generation=''
to_agent_sha='' to_core_sha='' to_generation=''
reason='' from_finalizer='' from_wrapper=''

while (($# > 0)); do
  case $1 in
    --from-agent-sha) from_agent_sha=${2-}; shift 2 ;;
    --from-core-sha) from_core_sha=${2-}; shift 2 ;;
    --from-overlay-generation) from_generation=${2-}; shift 2 ;;
    --to-agent-sha) to_agent_sha=${2-}; shift 2 ;;
    --to-core-sha) to_core_sha=${2-}; shift 2 ;;
    --to-overlay-generation) to_generation=${2-}; shift 2 ;;
    --reason) reason=${2-}; shift 2 ;;
    --from-finalizer) from_finalizer=${2-}; shift 2 ;;
    --from-wrapper) from_wrapper=${2-}; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done

require_sha40 --from-agent-sha "$from_agent_sha"
require_sha40 --from-core-sha "$from_core_sha"
require_sha40 --to-agent-sha "$to_agent_sha"
require_sha40 --to-core-sha "$to_core_sha"
require_generation --from-overlay-generation "$from_generation"
require_generation --to-overlay-generation "$to_generation"
[[ -n $reason ]] || die '缺少 --reason'
[[ $reason =~ ^[A-Za-z0-9_.-]+$ ]] || die 'reason 只允许单行下划线短语（[A-Za-z0-9_.-]）'
[[ $from_agent_sha != "$to_agent_sha" ]] || die '新旧 release source 锚相同，无需换锚'

[[ $(id -u) == 0 ]] || die '必须以 root 执行：本脚本要写 root:root 只读控制物'
[[ $(uname -m) == aarch64 ]] || die '必须在 aarch64 构建机上执行'

readonly from_short=${from_agent_sha:0:8}
readonly to_short=${to_agent_sha:0:8}
readonly from_overlay_name="$from_agent_sha-$OVERLAY_SUFFIX-$from_generation"
readonly to_overlay_name="$to_agent_sha-$OVERLAY_SUFFIX-$to_generation"
readonly from_overlay_rel="control-overlays/$from_overlay_name"
readonly to_overlay_rel="control-overlays/$to_overlay_name"
readonly from_overlay_dir="$CACHE_ROOT/$from_overlay_rel"
readonly to_overlay_dir="$CACHE_ROOT/$to_overlay_rel"
readonly to_anchor_dir="$CACHE_ROOT/anchors/$to_agent_sha"
readonly to_build_dir="$WORK_ROOT/dbdog-agent-$to_short-build2"
readonly to_pipeline_lock="$CACHE_ROOT/locks/dbdog-agent-$to_short-aarch64-kylin10.pipeline.lock"
readonly to_finalizer="$to_anchor_dir/finalize-agent-runtime.sh"
readonly to_wrapper="$to_anchor_dir/run-finalize-agent-runtime.sh"

[[ -n $from_finalizer ]] || from_finalizer="$CACHE_ROOT/anchors/$from_agent_sha/finalize-agent-runtime.sh"
[[ -n $from_wrapper ]] || from_wrapper="$CACHE_ROOT/anchors/$from_agent_sha/run-finalize-agent-runtime.sh"
for source_control in "$from_finalizer" "$from_wrapper"; do
  [[ -f $source_control && ! -L $source_control ]] || \
    die "上一代控制物不是实际普通文件: $source_control"
  [[ $(stat -c '%u:%g' -- "$source_control") == 0:0 ]] || \
    die "上一代控制物必须由 root:root 持有: $source_control"
done

# ---- 改写规则：只允许替换锚 token 与 overlay 代号，其余字节必须原样保留 ----
# 每条规则都在替换后复核「旧 token 一个不剩」，避免出现只改了一半的控制物。
rewrite_anchor_tokens() { # <源文件> <目标文件>
  local source=$1 destination=$2
  # 代号那两条刻意写成 POSIX BRE：`\b` 是 GNU 扩展，改写规则必须能在任何 sed 上得到同一结果，
  # 否则「本地干跑通过、构建机上漏改一处」正是这套东西最容易翻车的地方。
  sed \
    -e "s/$from_agent_sha/$to_agent_sha/g" \
    -e "s/dbdog-agent-$from_short-/dbdog-agent-$to_short-/g" \
    -e "s/$from_core_sha/$to_core_sha/g" \
    -e "s/\\(omnibus-kylin-platform-\\)$from_generation\$/\\1$to_generation/g" \
    -e "s/\\(omnibus-kylin-platform-\\)$from_generation\\([^0-9]\\)/\\1$to_generation\\2/g" \
    -- "$source" >"$destination" || die "改写失败: $source"
  if grep -qF -e "$from_agent_sha" -e "dbdog-agent-$from_short-" -e "$from_core_sha" \
      -- "$destination"; then
    die "改写后仍残留旧锚 token，请人工核对: $destination"
  fi
  if grep -q "omnibus-kylin-platform-${from_generation}\$" -- "$destination" ||
    grep -q "omnibus-kylin-platform-${from_generation}[^0-9]" -- "$destination"; then
    die "改写后仍残留旧 overlay 代号: $destination"
  fi
}

install_root_readonly() { # <文件> <mode>
  local target=$1 mode=$2
  chown 0:0 -- "$target"
  chmod "$mode" -- "$target"
}

# cache root 所在的 XFS 上，父目录带 setgid 时新建目录会继承 S_ISGID，而 `chmod 0555`
# 在这里并不清掉它——上一轮手工准备的 v15 overlay 就是这么变成 2555 的，而 finalizer
# 要求 overlay 目录恰好 0:0:555。所以目录一律显式清位后再断言。
install_root_readonly_dir() { # <目录>
  local target=$1 mode
  chown 0:0 -- "$target"
  chmod 0555 -- "$target"
  chmod g-s -- "$target"
  mode=$(stat -c '%u:%g:%a' -- "$target")
  [[ $mode == 0:0:555 ]] || die "无法把目录设为 root:root 0555（实际 $mode）: $target"
}

# 「清单自洽 + release_agent_sha 正确」并不能证明 overlay 被完整改写过：runner 内部还有
# 构建目录白名单与 pipeline lock 路径，它们带旧短 SHA 时清单照样自洽。手工准备的 v15 就是
# 这么漏了三处，一直到 omnibus runner 拒绝 build dir 才暴露。所以无论是新生成还是复用现成
# 的 overlay，都要逐字节扫一遍：runner 里出现的每个 dbdog-agent-<短SHA>- 必须是本次锚，
# 出现的每个 40 位 hex 必须属于本代允许的身份集合。
verify_overlay_free_of_stale_anchors() { # <overlay 目录>
  local overlay_dir=$1 runner="$1/run-agent-omnibus.sh" token
  # runner 合法引用两个构建目录：本次锚的 attempt，以及 sealed 69 项 handoff 的来源 attempt。
  local sealed_short=${SEALED_ORIGIN_AGENT_SHA:0:8}
  # 合法的 40 位提交 SHA：本次两个锚 + sealed origin + Omnibus core + 被钉住的 omnibus-ruby。
  local -a allowed=("$to_agent_sha" "$to_core_sha" "$SEALED_ORIGIN_AGENT_SHA" \
    "$OMNIBUS_CORE_SHA" "$OMNIBUS_RUBY_SHA")

  while IFS= read -r token; do
    [[ -z $token ]] && continue
    [[ $token == "dbdog-agent-$to_short-" || $token == "dbdog-agent-$sealed_short-" ]] || \
      die "overlay runner 仍指向别的构建目录锚 ${token}（应为 dbdog-agent-$to_short-）: $runner"
  done < <(grep -oE 'dbdog-agent-[0-9a-f]{8}-' -- "$runner" | sort -u)

  while IFS= read -r token; do
    [[ -z $token ]] && continue
    local matched=0 candidate
    for candidate in "${allowed[@]}"; do
      [[ $token == "$candidate" ]] && matched=1
    done
    ((matched == 1)) || \
      die "overlay runner 含不属于本代身份集合的 40 位提交 SHA $token: $runner"
  done < <(grep -oE '\b[0-9a-f]{40}\b' -- "$runner" | sort -u)

  # CONTROL-INFO 的 previous_result / previous_overlay 是对上一代的历史描述，本来就该提到
  # 旧代号，所以只查身份字段本身。
  [[ $(awk -F= '$1 == "release_agent_sha" { sub(/^[^=]*=/, ""); print }' \
    "$overlay_dir/CONTROL-INFO") == "$to_agent_sha" ]] || \
    die 'CONTROL-INFO 自报的 release_agent_sha 不是新锚'
  while IFS= read -r token; do
    [[ -z $token ]] && continue
    [[ $token == "dbdog-agent-$to_short-" ]] || \
      die "CONTROL-INFO 的构建目录路径仍指向 ${token}（应为 dbdog-agent-$to_short-）"
  done < <(grep -oE '^(go_tmpdir|selinux_policy_final_path)=.*' -- "$overlay_dir/CONTROL-INFO" |
    grep -oE 'dbdog-agent-[0-9a-f]{8}-' | sort -u)
}

# ---- 1. control overlay ----
# 已经就位且自洽的 overlay 直接复用（例如本代由人工按同一规则准备过），否则由上一代派生。
if [[ -e $to_overlay_dir ]]; then
  log "control overlay 已存在，跳过生成并转入校验: $to_overlay_dir"
else
  [[ -d $from_overlay_dir && ! -L $from_overlay_dir ]] || \
    die "缺少上一代 control overlay: $from_overlay_dir"
  log "由上一代 overlay 派生: $from_overlay_name -> $to_overlay_name"
  staging=$(mktemp -d "$CACHE_ROOT/control-overlays/.anchor-staging.XXXXXX")
  trap 'if [[ -n ${staging:-} && -d $staging ]]; then rm -rf -- "$staging"; fi' EXIT
  for overlay_file in run-agent-omnibus.sh agent-build-kylin-platform.patch CONTROL-INFO; do
    [[ -f $from_overlay_dir/$overlay_file && ! -L $from_overlay_dir/$overlay_file ]] || \
      die "上一代 overlay 缺少 $overlay_file"
    rewrite_anchor_tokens "$from_overlay_dir/$overlay_file" "$staging/$overlay_file"
  done
  # CONTROL-INFO 的沿革字段不是锚的函数，单独写：control_overlay_name 已由代号规则改写，
  # 这里补上 previous_overlay / previous_result / reason 三项。
  python3 - "$staging/CONTROL-INFO" "$from_overlay_name" "$to_generation" "$reason" <<'PYEOF'
import sys

path, previous_overlay_name, generation, reason = sys.argv[1:5]
previous_generation = previous_overlay_name.rsplit("-", 1)[-1]
overrides = {
    "previous_overlay": "omnibus-kylin-platform-" + previous_generation,
    "previous_result": "superseded_by_" + generation,
    "reason": reason,
}
seen = set()
lines = []
with open(path, encoding="utf-8") as stream:
    for line in stream:
        key = line.split("=", 1)[0]
        if key in overrides:
            if key in seen:
                raise SystemExit("duplicate key in CONTROL-INFO: " + key)
            seen.add(key)
            lines.append(key + "=" + overrides[key] + "\n")
        else:
            lines.append(line)
missing = set(overrides) - seen
if missing:
    raise SystemExit("CONTROL-INFO lacks expected keys: " + ",".join(sorted(missing)))
with open(path, "w", encoding="utf-8") as stream:
    stream.writelines(lines)
PYEOF

  # CONTROL.sha256 按新内容重算，四行顺序与配方 verify_persistent_controls 完全一致。
  patchelf_rel=$(awk -F= '$1 == "patchelf_rel" { sub(/^[^=]*=/, ""); print }' "$staging/CONTROL-INFO")
  [[ -n $patchelf_rel ]] || die 'CONTROL-INFO 缺少 patchelf_rel'
  [[ -f $CACHE_ROOT/$patchelf_rel ]] || die "CONTROL-INFO 指向的 patchelf 不存在: $patchelf_rel"
  {
    printf '%s  %s\n' "$(file_sha256 "$staging/run-agent-omnibus.sh")" \
      "$to_overlay_rel/run-agent-omnibus.sh"
    printf '%s  %s\n' "$(file_sha256 "$staging/agent-build-kylin-platform.patch")" \
      "$to_overlay_rel/agent-build-kylin-platform.patch"
    printf '%s  %s\n' "$(file_sha256 "$staging/CONTROL-INFO")" \
      "$to_overlay_rel/CONTROL-INFO"
    printf '%s  %s\n' "$(file_sha256 "$CACHE_ROOT/$patchelf_rel")" "$patchelf_rel"
  } >"$staging/CONTROL.sha256"

  install_root_readonly "$staging/run-agent-omnibus.sh" 0555
  for overlay_file in agent-build-kylin-platform.patch CONTROL-INFO CONTROL.sha256; do
    install_root_readonly "$staging/$overlay_file" 0444
  done
  install_root_readonly_dir "$staging"
  mv -T -- "$staging" "$to_overlay_dir"
  staging=
  trap - EXIT
fi

# 无论是新生成还是复用，都按配方的口径复验一遍再往下走。
[[ -d $to_overlay_dir && ! -L $to_overlay_dir ]] || die "control overlay 不是实际目录: $to_overlay_dir"
[[ $(stat -c '%u:%g:%a' -- "$to_overlay_dir") == 0:0:555 ]] || \
  die 'control overlay 目录必须是 root:root mode 0555'
overlay_inventory=$(find "$to_overlay_dir" -xdev -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[[ $overlay_inventory == $'CONTROL-INFO\nCONTROL.sha256\nagent-build-kylin-platform.patch\nrun-agent-omnibus.sh' ]] || \
  die 'control overlay 文件集合不匹配'
(cd "$CACHE_ROOT" && sha256sum -c "$to_overlay_rel/CONTROL.sha256" >/dev/null) || \
  die 'control overlay 内容与自带清单不符'
verify_overlay_free_of_stale_anchors "$to_overlay_dir"
log 'control overlay 已确认不含任何上一代锚残留'

# ---- 2. anchor 目录与随锚重写的 root 控制物 ----
mkdir -p -- "$CACHE_ROOT/anchors"
install_root_readonly_dir "$CACHE_ROOT/anchors"
[[ ! -e $to_anchor_dir ]] || die "anchor 目录已存在，拒绝覆盖历史控制物: $to_anchor_dir"

anchor_staging=$(mktemp -d "$CACHE_ROOT/anchors/.anchor-staging.XXXXXX")
trap 'if [[ -n ${anchor_staging:-} && -d $anchor_staging ]]; then rm -rf -- "$anchor_staging"; fi' EXIT

# overlay 的三个摘要不是字符串改写能得到的，必须按新 overlay 重算后代入。finalizer 与
# wrapper **都**钉了这三个值，只是变量名不同（finalizer 用 EXPECTED_ 前缀）；早先只代了
# wrapper，结果 finalize 阶段死在 `omnibus.success does not match`——omnibus.success 是对的，
# 是 finalizer 自己还拿着上一代的 runner 摘要。
runner_sha256=$(file_sha256 "$to_overlay_dir/run-agent-omnibus.sh")
control_info_sha256=$(file_sha256 "$to_overlay_dir/CONTROL-INFO")
control_manifest_sha256=$(file_sha256 "$to_overlay_dir/CONTROL.sha256")

set_readonly_assignments() { # <文件> <name=value>...
  local target=$1
  shift
  python3 - "$target" "$@" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    text = stream.read()
for pair in sys.argv[2:]:
    name, _, value = pair.partition("=")
    pattern = re.compile(r"^readonly %s=.*$" % re.escape(name), re.MULTILINE)
    text, count = pattern.subn(
        lambda _match, value=value, name=name: "readonly %s=%s" % (name, value), text)
    if count != 1:
        raise SystemExit("expected exactly one %s assignment, found %d" % (name, count))
with open(path, "w", encoding="utf-8") as stream:
    stream.write(text)
PYEOF
}

rewrite_anchor_tokens "$from_finalizer" "$anchor_staging/finalize-agent-runtime.sh"

# GaussDB wheel 的摘要同样随 core 锚变——路径能靠字符串改写跟上，内容摘要不能。漏代这一处
# 会让 finalize 死在 `pinned datadog-gaussdb wheel checksum mismatch`，同样是构建之后才暴露。
gaussdb_wheel_rel=$(awk -F= '$1 == "readonly GAUSSDB_WHEEL_REL" { sub(/^[^=]*=/, ""); print }' \
  "$anchor_staging/finalize-agent-runtime.sh")
[[ $gaussdb_wheel_rel == "sources/python/gaussdb/$to_core_sha/"* ]] || \
  die "改写后的 GaussDB wheel 路径不指向新 core 锚: $gaussdb_wheel_rel"
gaussdb_wheel="$CACHE_ROOT/$gaussdb_wheel_rel"
[[ -f $gaussdb_wheel && ! -L $gaussdb_wheel ]] || \
  die "缺少该 core 提交的 GaussDB wheel（需先独立构建并以 root:root 0444 就位）: $gaussdb_wheel"
[[ $(stat -c '%u:%g:%a' -- "$gaussdb_wheel") == 0:0:444 ]] || \
  die "GaussDB wheel 必须是 root:root mode 0444: $gaussdb_wheel"
gaussdb_wheel_sha256=$(file_sha256 "$gaussdb_wheel")

# --- 锚定 wheel 清单：把「谁必须有 wheel」在换锚这一步就定死 -------------------
#
# 产物里的 Python 包默认来自被 seal 钉死的 core（$OMNIBUS_CORE_SHA）。两类引擎必须有
# 锚定 wheel，否则 fail closed（换锚是最早能发现的时刻，比构建几十分钟后才报废划算）：
#
#   missing —— 封存 core 里根本没有（openGauss 曾是）：缺 wheel 会整个缺出产物，
#              而 conf 又已经发了，采集静默归零——它因此丢过两次。
#   drift   —— 封存 core 里有、但与发布锚 tree 不同（postgres 曾是）：缺 wheel 时产物
#              装的是封存旧版，锚上的改动**静默出不去**。2026-08-07 定则：fork 对集成的
#              改动一律进源码、经锚定 wheel 出去，不再打构建期补丁——所以漂移即必须有
#              wheel，判据是机械的 tree SHA 比对，不靠人记「我改过哪些」。
#
# gaussdb 由 finalizer 自己装（上面那段）；其余记进 PINNED-WHEELS，由
# build-host-prep.sh install-wheels 在 finalize 之前装（pip --force-reinstall，
# 覆盖封存版），语义与 finalizer 完全一致。
pinned_wheels_file="$anchor_staging/PINNED-WHEELS"
: >"$pinned_wheels_file"
printf 'gaussdb\t%s\t%s\n' "$gaussdb_wheel_rel" "$gaussdb_wheel_sha256" >>"$pinned_wheels_file"

agent_git="$CACHE_ROOT/git/dbdog-agent.git"
core_git="$CACHE_ROOT/git/dbdog-agent-core.git"
tree_at() { # <gitdir> <sha> <路径> —— 不存在回显空串；--verify 不能少
  git --git-dir="$1" rev-parse --verify --quiet "$2:$3" 2>/dev/null || true
}
for conf_entry in $(git --git-dir="$agent_git" ls-tree --name-only \
  "$to_agent_sha:dbdog-deploy/conf/conf.d" 2>/dev/null); do
  engine=${conf_entry%/}
  engine=${engine%.d}
  case $engine in '' | *[!a-z0-9_]*) continue ;; esac
  [[ $engine == gaussdb ]] && continue
  released_tree=$(tree_at "$core_git" "$to_core_sha" "$engine/datadog_checks/$engine")
  [[ -n $released_tree ]] || continue
  sealed_tree=$(tree_at "$core_git" "$OMNIBUS_CORE_SHA" "$engine/datadog_checks/$engine")
  # 封存与发布锚 tree 一致才可跳过；不同（missing 或 drift）都必须有锚定 wheel。
  [[ $released_tree == "$sealed_tree" ]] && continue
  if [[ -n $sealed_tree ]]; then
    wheel_reason="$engine 在封存 core 里是旧版（tree 与发布锚不同），缺锚定 wheel 时锚上的改动会静默出不去"
  else
    wheel_reason="$engine 不在封存 core 里，缺锚定 wheel 时产物会整个缺掉它"
  fi
  extra_wheel=$(find "$CACHE_ROOT/sources/python/$engine/$to_core_sha" -maxdepth 1 \
    -name "datadog_$engine-*-py3-none-any.whl" -type f 2>/dev/null | head -1 || true)
  [[ -n $extra_wheel ]] || die \
    "$wheel_reason。
   先在开发机上跑 build-integration-wheel.sh --integration $engine --core-sha $to_core_sha，
   再以 root:root 0444 放到 $CACHE_ROOT/sources/python/$engine/$to_core_sha/"
  [[ $(stat -c '%u:%g:%a' -- "$extra_wheel") == 0:0:444 ]] || \
    die "$engine 的锚定 wheel 必须是 root:root mode 0444: $extra_wheel"
  printf '%s\t%s\t%s\n' "$engine" "${extra_wheel#"$CACHE_ROOT/"}" "$(file_sha256 "$extra_wheel")" \
    >>"$pinned_wheels_file"
  log "锚定 wheel 入册: $engine <- ${extra_wheel##*/}"
done
# --- 通用漂移兜底：锚册覆盖不到的 Python 集成不许静默漂移 ----------------------
#
# 上面的循环只枚举「有 conf.d 条目」的引擎。datadog_checks_base 这类共享基座没有 conf，
# 但产物同样装的是封存版——它若在发布锚上被改过而无出路，改动就是白改（还以为发出去了；
# dbdog.6 的 base 层 health.py 修复正是这么丢的）。这里按 git diff 机械检出封存与发布锚
# 之间所有漂移的顶层 Python 集成目录，凡不在锚册覆盖内的同样要求锚定 wheel 并入册，
# 缺 wheel 即 fail closed。包名规则：引擎目录（postgres）的 wheel 是 datadog_<目录>-*，
# datadog_ 开头的共享包目录（datadog_checks_base）的 wheel 就是 <目录>-*。
while IFS= read -r drift_dir; do
  [[ -n $drift_dir ]] || continue
  # 只关心 Python 集成目录（其下有 datadog_checks/）
  [[ -n $(tree_at "$core_git" "$to_core_sha" "$drift_dir/datadog_checks") ]] || continue
  cut -f1 "$pinned_wheels_file" | grep -qx -- "$drift_dir" && continue
  case $drift_dir in
    datadog_*) drift_wheel_prefix=$drift_dir ;;
    *)         drift_wheel_prefix=datadog_$drift_dir ;;
  esac
  drift_wheel=$(find "$CACHE_ROOT/sources/python/$drift_dir/$to_core_sha" -maxdepth 1 \
    -name "${drift_wheel_prefix}-*-py*-none-any.whl" -type f 2>/dev/null | head -1 || true)
  [[ -n $drift_wheel ]] || die \
    "$drift_dir 在封存 core 与发布锚之间有漂移，锚上的改动会静默出不去。
   先在开发机上跑 build-integration-wheel.sh --integration $drift_dir --core-sha $to_core_sha，
   再以 root:root 0444 放到 $CACHE_ROOT/sources/python/$drift_dir/$to_core_sha/"
  [[ $(stat -c '%u:%g:%a' -- "$drift_wheel") == 0:0:444 ]] || \
    die "$drift_dir 的锚定 wheel 必须是 root:root mode 0444: $drift_wheel"
  printf '%s\t%s\t%s\n' "$drift_dir" "${drift_wheel#"$CACHE_ROOT/"}" "$(file_sha256 "$drift_wheel")" \
    >>"$pinned_wheels_file"
  log "锚定 wheel 入册(共享基座漂移): $drift_dir <- ${drift_wheel##*/}"
done < <(git --git-dir="$core_git" diff --name-only "$OMNIBUS_CORE_SHA" "$to_core_sha" \
  2>/dev/null | cut -d/ -f1 | sort -u)

pinned_wheels_sha256=$(file_sha256 "$pinned_wheels_file")

set_readonly_assignments "$anchor_staging/finalize-agent-runtime.sh" \
  "EXPECTED_CONTROL_OVERLAY_RUNNER_SHA256=$runner_sha256" \
  "EXPECTED_CONTROL_INFO_SHA256=$control_info_sha256" \
  "EXPECTED_CONTROL_MANIFEST_SHA256=$control_manifest_sha256" \
  "GAUSSDB_WHEEL_SHA256=$gaussdb_wheel_sha256"
bash -n "$anchor_staging/finalize-agent-runtime.sh" || die '改写后的 finalizer 语法不合法'
finalizer_sha256=$(file_sha256 "$anchor_staging/finalize-agent-runtime.sh")

# wrapper 引用 finalizer 的路径与摘要，所以必须在 finalizer 定稿之后再写。
rewrite_anchor_tokens "$from_wrapper" "$anchor_staging/run-finalize-agent-runtime.sh"
set_readonly_assignments "$anchor_staging/run-finalize-agent-runtime.sh" \
  "RUNNER_SHA256=$runner_sha256" \
  "CONTROL_INFO_SHA256=$control_info_sha256" \
  "CONTROL_MANIFEST_SHA256=$control_manifest_sha256" \
  "FINALIZER_SHA256=$finalizer_sha256" \
  "FINALIZER=$to_finalizer" \
  "EXPECTED_SELF=$to_wrapper"
bash -n "$anchor_staging/run-finalize-agent-runtime.sh" || die '改写后的 wrapper 语法不合法'
wrapper_sha256=$(file_sha256 "$anchor_staging/run-finalize-agent-runtime.sh")

# 上一代 overlay 的三个摘要一个都不许留在新控制物里，新的三个必须都在。少代一处就会在
# finalize 阶段——也就是几小时构建之后——才暴露。
prev_runner_sha256=$(file_sha256 "$from_overlay_dir/run-agent-omnibus.sh")
prev_control_info_sha256=$(file_sha256 "$from_overlay_dir/CONTROL-INFO")
prev_control_manifest_sha256=$(file_sha256 "$from_overlay_dir/CONTROL.sha256")
prev_wheel="$CACHE_ROOT/sources/python/gaussdb/$from_core_sha/${gaussdb_wheel_rel##*/}"
prev_wheel_sha256=$([[ -f $prev_wheel ]] && file_sha256 "$prev_wheel" || printf 'n/a\n')
for generated in "$anchor_staging/finalize-agent-runtime.sh" \
  "$anchor_staging/run-finalize-agent-runtime.sh"; do
  for stale in "$prev_runner_sha256" "$prev_control_info_sha256" \
    "$prev_control_manifest_sha256" "$prev_wheel_sha256"; do
    [[ $stale == n/a ]] && continue
    if grep -qF -- "$stale" "$generated"; then
      die "生成的控制物仍钉着上一代 overlay 摘要 $stale: $generated"
    fi
  done
  for fresh in "$runner_sha256" "$control_info_sha256" "$control_manifest_sha256"; do
    grep -qF -- "$fresh" "$generated" || \
      die "生成的控制物没有代入本代 overlay 摘要 $fresh: $generated"
  done
done
grep -qF -- "$gaussdb_wheel_sha256" "$anchor_staging/finalize-agent-runtime.sh" || \
  die "finalizer 没有代入本代 GaussDB wheel 摘要 $gaussdb_wheel_sha256"

cat >"$anchor_staging/ANCHOR-INFO" <<EOF
anchor_info_format=$ANCHOR_INFO_FORMAT
release_agent_sha=$to_agent_sha
integration_core_sha=$to_core_sha
generated_outputs_origin_agent_sha=$SEALED_ORIGIN_AGENT_SHA
omnibus_core_sha=$OMNIBUS_CORE_SHA
control_overlay_generation=$to_generation
control_overlay_rel=$to_overlay_rel
control_overlay_runner_sha256=$runner_sha256
control_info_sha256=$control_info_sha256
control_manifest_sha256=$control_manifest_sha256
finalizer_sha256=$finalizer_sha256
finalizer_wrapper_sha256=$wrapper_sha256
gaussdb_wheel_rel=$gaussdb_wheel_rel
gaussdb_wheel_sha256=$gaussdb_wheel_sha256
pinned_wheels_sha256=$pinned_wheels_sha256
build_dir=$to_build_dir
pipeline_lock=$to_pipeline_lock
derived_from_agent_sha=$from_agent_sha
derived_from_overlay_generation=$from_generation
reason=$reason
EOF

install_root_readonly "$anchor_staging/finalize-agent-runtime.sh" 0555
install_root_readonly "$anchor_staging/run-finalize-agent-runtime.sh" 0555
install_root_readonly "$anchor_staging/ANCHOR-INFO" 0444
install_root_readonly "$anchor_staging/PINNED-WHEELS" 0444
install_root_readonly_dir "$anchor_staging"
mv -T -- "$anchor_staging" "$to_anchor_dir"
anchor_staging=
trap - EXIT

# ---- 3. pipeline lock 与 build attempt ----
if [[ -e $to_pipeline_lock ]]; then
  log "pipeline lock 已存在: $to_pipeline_lock"
else
  : >"$to_pipeline_lock"
  chown 0:dbdog -- "$to_pipeline_lock"
  chmod 0644 -- "$to_pipeline_lock"
  log "已创建 pipeline lock: $to_pipeline_lock"
fi
[[ $(stat -c '%U:%G:%a' -- "$to_pipeline_lock") == root:dbdog:644 ]] || \
  die 'pipeline lock 必须是 root:dbdog mode 0644'

if [[ -e $to_build_dir ]]; then
  log "build attempt 已存在: $to_build_dir"
else
  mkdir -- "$to_build_dir"
  chown dbdog:dbdog -- "$to_build_dir"
  chmod 0775 -- "$to_build_dir"
  log "已创建 build attempt: $to_build_dir"
fi
[[ $(stat -c '%U:%G:%a' -- "$to_build_dir") == dbdog:dbdog:775 ]] || \
  die 'build attempt 必须是 dbdog:dbdog mode 0775'

log '完成。ANCHOR-INFO：'
cat -- "$to_anchor_dir/ANCHOR-INFO"
log "下一步：把 RELEASE-BASELINE.tsv 的 agent_release_source_commit 改为 $to_agent_sha、"
log "integrations_core_release_source_commit 改为 $to_core_sha，然后跑 publish.sh。"
log "GaussDB wheel 需另行按该 core 提交独立构建并以 root:root 0444 就位于"
log "$CACHE_ROOT/sources/python/gaussdb/$to_core_sha/。"
