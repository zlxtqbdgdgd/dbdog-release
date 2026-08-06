#!/usr/bin/env bash
# 公网发布主脚本（在开发机上执行）。
#   publish.sh plan                      # 只看哪些模块有变更
#   publish.sh publish [模块...] [--bump patch|minor|major] [--yes]
#                                        # 默认发布所有有变更的一方模块；三方件需点名
#   publish.sh regen-readme              # 按 manifest 重新生成 README 版本表
#   publish.sh prune [--yes]             # 只保留 manifest 当前引用（默认试运行）
#   publish.sh migrate-manifest-v2 --write
#                                        # 一次性迁移：manifest.tsv 八列旧格式 → 九列（含 arch）
#   publish.sh register-module <模块> <first-party|third-party> <stack|dbhost> <yes|no> \
#     --arch <架构> [--arch <架构>]...    # 全新模块首发登记：原子写入未发布声明行
#                                        # （每架构一行，version/artifact/sha256/source_sha 全为 -），
#                                        # 之后照常 publish.sh publish <模块> --yes 完成首次真实发布
#   publish.sh register-arch <模块> --arch <架构> [--arch <架构>]...
#                                        # 给已登记模块补未发布架构声明行（kind/target/service
#                                        # 从现有行复制）；用于已发布模块扩展第二架构。
#                                        # DBDOG_PUBLISH_SKIP_PUSH=1 时只本地 commit，不 push。
#
# 依赖：ssh 可达构建机、gh 已登录（gh auth status）、各源仓与本仓是同级目录。
# 产物在构建机上完成架构/摘要校验并直传 GitHub；本机不再中转大文件。

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"   # log/die/manifest_* （其内网路径变量在本机不使用）

REPO="zlxtqbdgdgd/dbdog-release"
BUCKET_TAG="artifacts"
SCRATCH="$RELEASE_DIR/scratch"

CONF="$HERE/publish.conf"
# 合同测试会在 source 本文件前预设 SRC_ROOT/BUILD_HOST_* 等；publish.conf 不得覆盖它们。
_preset_src_root="${SRC_ROOT-}"
_preset_repo_root="${REPO_ROOT-}"
_preset_build_work="${BUILD_WORK-}"
_preset_tool_path="${TOOL_PATH-}"
_preset_build_host="${BUILD_HOST-}"
_preset_build_host_aarch64="${BUILD_HOST_AARCH64-}"
_preset_build_host_x86_64="${BUILD_HOST_X86_64-}"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi
[ -n "${_preset_src_root}" ] && SRC_ROOT="$_preset_src_root"
[ -n "${_preset_repo_root}" ] && REPO_ROOT="$_preset_repo_root"
[ -n "${_preset_build_work}" ] && BUILD_WORK="$_preset_build_work"
[ -n "${_preset_tool_path}" ] && TOOL_PATH="$_preset_tool_path"
[ -n "${_preset_build_host}" ] && BUILD_HOST="$_preset_build_host"
[ -n "${_preset_build_host_aarch64}" ] && BUILD_HOST_AARCH64="$_preset_build_host_aarch64"
[ -n "${_preset_build_host_x86_64}" ] && BUILD_HOST_X86_64="$_preset_build_host_x86_64"
unset _preset_src_root _preset_repo_root _preset_build_work _preset_tool_path \
  _preset_build_host _preset_build_host_aarch64 _preset_build_host_x86_64
SRC_ROOT="${SRC_ROOT:-$(cd "$RELEASE_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-/home/z1/dbdog/repo}"
BUILD_WORK="${BUILD_WORK:-/home/z1/dbdog-release-build}"
TOOL_PATH="${TOOL_PATH:-}"

# 未真正配置构建执行器时 publish.conf.example 里留下的占位值；BUILD_HOST 与
# BUILD_HOST_X86_64 都可能是它，任何一处出现都必须 fail closed，不能当成真机。
BUILD_HOST_PLACEHOLDER="z1@CHANGE-ME"

# 事务目录固定在这里（gitignored），mode 0700。build_one_arch 追加构建行；
# publish_commit_arch_matrix 消费后清理。跨进程重启仍可在这里找到未完成的事务
# （见 publish_txn_dir / publish_txn_init）。
PUBLISH_TXN_ROOT="$RELEASE_DIR/scratch/publish-txn"

# 大产物上传容易跨过 gh 默认的短 HTTP 超时。调用者仍可显式覆盖，但不接受
# gh 无法解释的值，避免发布跑到上传阶段才以模糊错误退出。
GH_HTTP_TIMEOUT="${GH_HTTP_TIMEOUT:-120}"
case "$GH_HTTP_TIMEOUT" in
  '' | 0 | *[!0-9]*) die "GH_HTTP_TIMEOUT 必须是正整数秒: $GH_HTTP_TIMEOUT" ;;
esac
[ "$GH_HTTP_TIMEOUT" -gt 0 ] || die "GH_HTTP_TIMEOUT 必须大于 0: $GH_HTTP_TIMEOUT"
export GH_HTTP_TIMEOUT

# 上传只在已经证明同名资产不存在时重试。该参数主要用于合同测试把等待置零；
# 正常发布保持有限次数和短暂退避，绝不重新进入构建阶段。
PUBLISH_UPLOAD_MAX_ATTEMPTS="${PUBLISH_UPLOAD_MAX_ATTEMPTS:-3}"
PUBLISH_UPLOAD_RETRY_DELAY_SECONDS="${PUBLISH_UPLOAD_RETRY_DELAY_SECONDS:-5}"
case "$PUBLISH_UPLOAD_MAX_ATTEMPTS" in
  '' | 0 | *[!0-9]*)
    die "PUBLISH_UPLOAD_MAX_ATTEMPTS 必须是正整数: $PUBLISH_UPLOAD_MAX_ATTEMPTS" ;;
esac
[ "$PUBLISH_UPLOAD_MAX_ATTEMPTS" -gt 0 ] \
  || die "PUBLISH_UPLOAD_MAX_ATTEMPTS 必须大于 0: $PUBLISH_UPLOAD_MAX_ATTEMPTS"
case "$PUBLISH_UPLOAD_RETRY_DELAY_SECONDS" in
  '' | *[!0-9]*)
    die "PUBLISH_UPLOAD_RETRY_DELAY_SECONDS 必须是非负整数: $PUBLISH_UPLOAD_RETRY_DELAY_SECONDS" ;;
esac

# Agent 的版本前缀和实际出货源码都只能来自 Agent 仓中已提交、已推送的发布基线。
# 这里故意不保留环境变量或 release.json/current_milestone fallback，避免构建者本机配置
# 把同一份源码打成不同版本，或把尚未钉住的 HEAD 悄悄带入产物。
load_agent_release_baseline() {
  local agent_repo="$SRC_ROOT/dbdog-agent"
  local core_repo="$SRC_ROOT/dbdog-agent-core"
  local baseline_rel="dbdog-deploy/RELEASE-BASELINE.tsv"
  local baseline="$agent_repo/$baseline_rel"

  [ -d "$agent_repo/.git" ] || die "Agent 源仓不存在: $agent_repo"
  [ -d "$core_repo/.git" ] || die "Agent integrations-core 源仓不存在: $core_repo"
  [ -f "$baseline" ] && [ ! -L "$baseline" ] \
    || die "Agent 发布基线不存在或不是普通文件: $baseline"
  git -C "$agent_repo" ls-files --error-unmatch -- "$baseline_rel" >/dev/null 2>&1 \
    || die "Agent 发布基线尚未纳入版本控制: $baseline_rel"
  git -C "$agent_repo" diff --quiet HEAD -- "$baseline_rel" \
    || die "Agent 发布基线有未提交变更，拒绝发布: $baseline_rel"
  git -C "$agent_repo" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 \
    || die "Agent 源仓缺少 origin/main，无法验证发布基线"
  git -C "$agent_repo" diff --quiet origin/main -- "$baseline_rel" \
    || die "Agent 发布基线尚未原样推送到 origin/main，拒绝发布"

  # v1 是严格的 key<TAB>value 合约：不得缺键、重复、留空或夹带未知字段。
  if ! awk -F '\t' '
      BEGIN {
        allowed["schema"] = 1
        allowed["agent_official_version"] = 1
        allowed["agent_official_tag"] = 1
        allowed["agent_official_commit"] = 1
        allowed["agent_release_source_commit"] = 1
        allowed["integrations_core_official_version"] = 1
        allowed["integrations_core_official_tag"] = 1
        allowed["integrations_core_official_commit"] = 1
        allowed["integrations_core_release_source_commit"] = 1
        allowed["official_version_format"] = 1
        allowed["official_tag_must_equal_version"] = 1
        allowed["official_commit_must_be_tag_target"] = 1
        allowed["official_commit_must_be_release_source_ancestor"] = 1
        allowed["release_source_commit_must_be_head_ancestor"] = 1
        allowed["release_prefix_key"] = 1
        allowed["dbdog_version_template"] = 1
        allowed["dbdog_revision_initial"] = 1
        allowed["dbdog_revision_current"] = 1
        allowed["dbdog_revision_reset_on_official_baseline_change"] = 1
        allowed["release_build_must_use_explicit_source_commits"] = 1
        allowed["release_json_current_milestone_is_prefix_authority"] = 1
        expected = 21
      }
      {
        if (NF != 2 || $1 == "" || $2 == "" || !($1 in allowed) || seen[$1]++) bad = 1
      }
      END {
        if (NR != expected) bad = 1
        for (key in allowed) if (!(key in seen)) bad = 1
        exit bad ? 1 : 0
      }
    ' "$baseline"; then
    die "Agent 发布基线不符合 dbdog-agent-release-baseline/v1 严格字段合约"
  fi

  agent_baseline_value() {
    awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$baseline"
  }
  AGENT_BASELINE_SCHEMA="$(agent_baseline_value schema)"
  AGENT_OFFICIAL_VERSION="$(agent_baseline_value agent_official_version)"
  AGENT_OFFICIAL_TAG="$(agent_baseline_value agent_official_tag)"
  AGENT_OFFICIAL_COMMIT="$(agent_baseline_value agent_official_commit)"
  AGENT_RELEASE_SOURCE_COMMIT="$(agent_baseline_value agent_release_source_commit)"
  INTEGRATIONS_CORE_OFFICIAL_VERSION="$(agent_baseline_value integrations_core_official_version)"
  INTEGRATIONS_CORE_OFFICIAL_TAG="$(agent_baseline_value integrations_core_official_tag)"
  INTEGRATIONS_CORE_OFFICIAL_COMMIT="$(agent_baseline_value integrations_core_official_commit)"
  INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT="$(agent_baseline_value integrations_core_release_source_commit)"

  [ "$AGENT_BASELINE_SCHEMA" = "dbdog-agent-release-baseline/v1" ] \
    || die "不支持的 Agent 发布基线 schema: $AGENT_BASELINE_SCHEMA"
  [[ "$AGENT_OFFICIAL_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "Agent 官方版本必须是稳定三段 SemVer: $AGENT_OFFICIAL_VERSION"
  [[ "$INTEGRATIONS_CORE_OFFICIAL_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "integrations-core 官方版本必须是稳定三段 SemVer: $INTEGRATIONS_CORE_OFFICIAL_VERSION"
  [ "$AGENT_OFFICIAL_TAG" = "$AGENT_OFFICIAL_VERSION" ] \
    || die "Agent 官方 tag 必须等于官方版本"
  [ "$INTEGRATIONS_CORE_OFFICIAL_TAG" = "$INTEGRATIONS_CORE_OFFICIAL_VERSION" ] \
    || die "integrations-core 官方 tag 必须等于官方版本"

  local commit
  for commit in \
    "$AGENT_OFFICIAL_COMMIT" "$AGENT_RELEASE_SOURCE_COMMIT" \
    "$INTEGRATIONS_CORE_OFFICIAL_COMMIT" "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT"; do
    [ "${#commit}" -eq 40 ] || die "Agent 发布基线 commit 不是 40 位 SHA: $commit"
    case "$commit" in *[!0-9a-f]*) die "Agent 发布基线 commit 含非法字符: $commit" ;; esac
  done

  [ "$(agent_baseline_value official_version_format)" = "three_segment_semver" ] \
    || die "Agent 发布基线禁止使用非三段稳定版本"
  [ "$(agent_baseline_value official_tag_must_equal_version)" = "true" ] \
    || die "Agent 发布基线必须要求 tag 等于 version"
  [ "$(agent_baseline_value official_commit_must_be_tag_target)" = "true" ] \
    || die "Agent 发布基线必须钉住 tag target"
  [ "$(agent_baseline_value official_commit_must_be_release_source_ancestor)" = "true" ] \
    || die "Agent 发布基线必须要求官方 commit 是出货源码祖先"
  [ "$(agent_baseline_value release_source_commit_must_be_head_ancestor)" = "true" ] \
    || die "Agent 发布基线必须要求出货源码是 HEAD 祖先"
  [ "$(agent_baseline_value release_prefix_key)" = "agent_official_version" ] \
    || die "Agent 发布前缀只能取 agent_official_version"
  [ "$(agent_baseline_value dbdog_version_template)" = '${agent_official_version}-dbdog.${revision}' ] \
    || die "Agent dbdog 版本模板不符合发布政策"
  [ "$(agent_baseline_value dbdog_revision_initial)" = "1" ] \
    || die "Agent 本地打包修订必须从 1 开始"
  local revision_current
  revision_current="$(agent_baseline_value dbdog_revision_current)"
  [[ "$revision_current" =~ ^[1-9][0-9]*$ ]] \
    || die "Agent dbdog_revision_current 必须是正整数: $revision_current"
  [ "$revision_current" -ge 1 ] \
    || die "Agent dbdog_revision_current 不能小于 dbdog_revision_initial"
  [ "$(agent_baseline_value dbdog_revision_reset_on_official_baseline_change)" = "true" ] \
    || die "Agent 官方基线变化时必须重置本地打包修订"
  [ "$(agent_baseline_value release_build_must_use_explicit_source_commits)" = "true" ] \
    || die "Agent 构建必须使用显式源码锚"
  [ "$(agent_baseline_value release_json_current_milestone_is_prefix_authority)" = "false" ] \
    || die "release.json current_milestone 禁止作为 Agent 发布前缀"

  git -C "$agent_repo" show-ref --verify --quiet "refs/tags/$AGENT_OFFICIAL_TAG" \
    || die "Agent 官方 tag 不存在: $AGENT_OFFICIAL_TAG"
  [ "$(git -C "$agent_repo" rev-parse --verify "refs/tags/$AGENT_OFFICIAL_TAG^{commit}")" = \
      "$AGENT_OFFICIAL_COMMIT" ] \
    || die "Agent 官方 tag 没有精确解析到基线 commit"
  git -C "$core_repo" show-ref --verify --quiet "refs/tags/$INTEGRATIONS_CORE_OFFICIAL_TAG" \
    || die "integrations-core 官方 tag 不存在: $INTEGRATIONS_CORE_OFFICIAL_TAG"
  [ "$(git -C "$core_repo" rev-parse --verify "refs/tags/$INTEGRATIONS_CORE_OFFICIAL_TAG^{commit}")" = \
      "$INTEGRATIONS_CORE_OFFICIAL_COMMIT" ] \
    || die "integrations-core 官方 tag 没有精确解析到基线 commit"

  git -C "$agent_repo" merge-base --is-ancestor \
    "$AGENT_OFFICIAL_COMMIT" "$AGENT_RELEASE_SOURCE_COMMIT" \
    || die "Agent 官方 commit 不是实际出货源码的祖先"
  git -C "$core_repo" merge-base --is-ancestor \
    "$INTEGRATIONS_CORE_OFFICIAL_COMMIT" "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" \
    || die "integrations-core 官方 commit 不是实际出货源码的祖先"
  git -C "$agent_repo" merge-base --is-ancestor "$AGENT_RELEASE_SOURCE_COMMIT" HEAD \
    || die "Agent 实际出货源码不是当前 HEAD 的祖先"
  git -C "$core_repo" merge-base --is-ancestor "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" HEAD \
    || die "integrations-core 实际出货源码不是当前 HEAD 的祖先"
  git -C "$agent_repo" merge-base --is-ancestor "$AGENT_RELEASE_SOURCE_COMMIT" origin/main \
    || die "Agent 实际出货源码尚未进入 origin/main"
  git -C "$core_repo" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 \
    || die "integrations-core 源仓缺少 origin/main"
  git -C "$core_repo" merge-base --is-ancestor "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" origin/main \
    || die "integrations-core 实际出货源码尚未进入 origin/main"

  unset -f agent_baseline_value
}

warn_agent_unshipped_heads() { # 调用前已 load_agent_release_baseline
  local agent_head core_head
  agent_head="$(git -C "$SRC_ROOT/dbdog-agent" rev-parse HEAD)"
  core_head="$(git -C "$SRC_ROOT/dbdog-agent-core" rev-parse HEAD)"
  [ "$agent_head" = "$AGENT_RELEASE_SOURCE_COMMIT" ] \
    || warn "dbdog-agent HEAD 已超前；本次只出货基线源码 ${AGENT_RELEASE_SOURCE_COMMIT:0:12}，HEAD ${agent_head:0:12} 未纳入"
  [ "$core_head" = "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" ] \
    || warn "dbdog-agent-core HEAD 已超前；本次只出货基线源码 ${INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT:0:12}，HEAD ${core_head:0:12} 未纳入"
}

agent_version_uses_loaded_baseline() { # <manifest version>；调用前已 load_agent_release_baseline
  local version="$1" revision prefix
  prefix="$AGENT_OFFICIAL_VERSION-dbdog."
  case "$version" in "$prefix"*) revision="${version#"$prefix"}" ;; *) return 1 ;; esac
  case "$revision" in "" | 0 | 0* | *[!0-9]*) return 1 ;; esac
  return 0
}

agent_version_uses_current_baseline() { # <manifest version>
  load_agent_release_baseline
  agent_version_uses_loaded_baseline "$1"
}

agent_loaded_source_fingerprint() { # 调用前已 load_agent_release_baseline
  local agent_short core_short
  agent_short="$(git -C "$SRC_ROOT/dbdog-agent" rev-parse --short=7 "$AGENT_RELEASE_SOURCE_COMMIT")"
  core_short="$(git -C "$SRC_ROOT/dbdog-agent-core" rev-parse --short=7 "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT")"
  printf 'agent:%s,core:%s\n' "$agent_short" "$core_short"
}

# ---- 变更检测 ----
live_sha() { # 当前源码指纹（与 manifest.source_sha 同格式）
  case "$1" in
    dbdog-agent)
      load_agent_release_baseline
      agent_loaded_source_fingerprint ;;
    *) git -C "$SRC_ROOT/$1" rev-parse --short=7 HEAD ;;
  esac
}

fetch_source_origin() { # <repo>；变更检测前刷新真实远端引用，禁止依赖过期缓存
  local repo="$1" attempt=1
  while ! git -C "$SRC_ROOT/$repo" fetch -q --prune origin; do
    [ "$attempt" -lt 3 ] \
      || die "$repo 连续 3 次无法刷新 origin，拒绝用过期引用判断发布范围"
    warn "$repo 刷新 origin 瞬时失败，2 秒后重试（$attempt/3）"
    sleep 2
    attempt=$((attempt + 1))
  done
  git -C "$SRC_ROOT/$repo" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 \
    || die "$repo 缺少 origin/main，无法判断发布范围"
}

source_checkout_matches_origin() { # <repo>
  local repo="$1"
  [ "$(git -C "$SRC_ROOT/$repo" rev-parse HEAD)" = \
    "$(git -C "$SRC_ROOT/$repo" rev-parse origin/main)" ]
}

refresh_first_party_origins() {
  local m kind
  while IFS=$'\t' read -r m kind _t _s _v _a _h _recorded _arch; do
    [ "$kind" = "first-party" ] || continue
    [ -d "$SRC_ROOT/$m/.git" ] || continue
    fetch_source_origin "$m"
    if [ "$m" = "dbdog-agent" ]; then
      [ -d "$SRC_ROOT/dbdog-agent-core/.git" ] \
        || die "Agent integrations-core 源仓不存在: $SRC_ROOT/dbdog-agent-core"
      fetch_source_origin dbdog-agent-core
    fi
  done < <(manifest_rows)
}

assert_first_party_checkouts_current() {
  local m kind stale=0
  while IFS=$'\t' read -r m kind _t _s _v _a _h _recorded _arch; do
    [ "$kind" = "first-party" ] || continue
    [ -d "$SRC_ROOT/$m/.git" ] || continue
    if ! source_checkout_matches_origin "$m"; then
      warn "$m 本地 HEAD 未对齐 origin/main"
      stale=1
    fi
    if [ "$m" = "dbdog-agent" ] && ! source_checkout_matches_origin dbdog-agent-core; then
      warn "dbdog-agent-core 本地 HEAD 未对齐 origin/main"
      stale=1
    fi
  done < <(manifest_rows)
  [ "$stale" -eq 0 ] \
    || die "存在未同步的自研源仓，拒绝自动推导发布范围；先 fast-forward 后重试"
}

changed_first_party() {
  while IFS=$'\t' read -r m kind _t _s _v _a _h recorded _arch; do
    [ "$kind" = "first-party" ] || continue
    [ -d "$SRC_ROOT/$m/.git" ] || { warn "源仓不存在: $SRC_ROOT/${m}，跳过 $m"; continue; }
    if [ "$m" = "dbdog-agent" ]; then
      load_agent_release_baseline
      local current_sha
      current_sha="$(agent_loaded_source_fingerprint)"
      if [ "$current_sha" != "$recorded" ] || ! agent_version_uses_loaded_baseline "$_v"; then
        echo "$m"
      fi
    elif [ "$(live_sha "$m")" != "$recorded" ]; then
      echo "$m"
    fi
  done < <(manifest_rows)
}

ensure_pushed() { # 构建机从 origin 取码，未推送的提交构建不到
  local repo target
  for repo in "$@"; do
    target=HEAD
    case "$repo" in
      dbdog-agent)
        load_agent_release_baseline
        target="$AGENT_RELEASE_SOURCE_COMMIT"
        ;;
      dbdog-agent-core)
        load_agent_release_baseline
        target="$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT"
        ;;
    esac
    fetch_source_origin "$repo"
    git -C "$SRC_ROOT/$repo" merge-base --is-ancestor "$target" origin/main \
      || die "$repo 出货源码 $target 尚未推送到 origin/main，先 push 再发布"
    case "$repo" in
      dbdog-agent | dbdog-agent-core) ;;
      *) source_checkout_matches_origin "$repo" \
        || die "$repo 本地 HEAD 未对齐 origin/main，拒绝发布过期源码；先 fast-forward 后重试" ;;
    esac
  done
}

# ---- 版本号 ----
bump_version() { # bump_version <模块> <当前版本> <patch|minor|major>
  local m="$1" cur="$2" level="${3:-patch}"
  if [ "$m" = "dbdog-agent" ]; then
    local revision prefix
    load_agent_release_baseline
    prefix="$AGENT_OFFICIAL_VERSION-dbdog."
    if agent_version_uses_loaded_baseline "$cur"; then
      revision="${cur#"$prefix"}"
      echo "$prefix$((revision + 1))"
    elif [ "$cur" = "-" ] || [[ "$cur" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dbdog\.([1-9][0-9]*)$ ]]; then
      echo "${prefix}1"
    else
      die "Agent manifest 版本格式非法，不能安全推导下一修订: $cur"
    fi
    return
  fi
  [ "$cur" = "-" ] && { echo "0.1.0"; return; }
  local a b c; IFS=. read -r a b c <<<"$cur"
  case "$level" in
    major) echo "$((a + 1)).0.0" ;;
    minor) echo "$a.$((b + 1)).0" ;;
    patch) echo "$a.$b.$((c + 1))" ;;
    *) die "未知 bump 级别: $level" ;;
  esac
}

# ---- 构建与上传 ----
ensure_bucket() {
  gh release view "$BUCKET_TAG" -R "$REPO" >/dev/null 2>&1 && return 0
  log "创建产物桶 release: $BUCKET_TAG"
  gh release create "$BUCKET_TAG" -R "$REPO" --prerelease --title "产物桶（artifacts）" \
    --notes "所有模块产物的唯一存放桶。版本语义只看 manifest.tsv / README 版本表，不看本页。"
}

inspect_release_asset() { # <asset name> <expected size> <expected sha256>；设置 RELEASE_ASSET_*
  local asset_name="$1" expected_size="$2" expected_sha="$3"
  local rows count remote_size remote_digest remote_sha

  case "$asset_name" in
    '' | *[!A-Za-z0-9._-]*)
      die "待上传产物名含不安全字符: $asset_name" ;;
  esac
  case "$expected_size" in
    '' | *[!0-9]*) die "待上传产物大小非法: $expected_size" ;;
  esac
  [ "${#expected_sha}" -eq 64 ] || die "待上传产物 SHA-256 长度非法: $expected_sha"
  case "$expected_sha" in
    *[!0-9a-f]*) die "待上传产物 SHA-256 非法: $expected_sha" ;;
  esac

  # 一次读取完整资产清单，再按精确名称筛选。不要把资产名插入 jq 表达式，
  # 也不要使用 --clobber；任何同名歧义都必须 fail closed。
  if ! rows="$(gh api "repos/$REPO/releases/tags/$BUCKET_TAG" \
      --jq '.assets[] | [.name, (.size | tostring), (.digest // "")] | @tsv')"; then
    RELEASE_ASSET_STATE="query-failed"
    RELEASE_ASSET_DETAIL="无法读取产物桶资产元数据"
    return 1
  fi
  count="$(printf '%s\n' "$rows" | awk -F '\t' -v name="$asset_name" \
    '$1 == name { count++ } END { print count + 0 }')"

  RELEASE_ASSET_STATE="absent"
  RELEASE_ASSET_DETAIL="远端不存在同名资产"
  [ "$count" -gt 0 ] || return 0
  if [ "$count" -ne 1 ]; then
    RELEASE_ASSET_STATE="conflict"
    RELEASE_ASSET_DETAIL="远端出现 $count 个同名资产，无法唯一核验"
    return 0
  fi

  remote_size="$(printf '%s\n' "$rows" | awk -F '\t' -v name="$asset_name" \
    '$1 == name { print $2; exit }')"
  remote_digest="$(printf '%s\n' "$rows" | awk -F '\t' -v name="$asset_name" \
    '$1 == name { print $3; exit }')"
  case "$remote_digest" in
    sha256:*) remote_sha="${remote_digest#sha256:}" ;;
    *) remote_sha="" ;;
  esac

  if [ "$remote_size" = "$expected_size" ] && [ "$remote_sha" = "$expected_sha" ]; then
    RELEASE_ASSET_STATE="identical"
    RELEASE_ASSET_DETAIL="远端 size/SHA-256 与本地一致"
  else
    RELEASE_ASSET_STATE="conflict"
    RELEASE_ASSET_DETAIL="远端 size=${remote_size:-unknown}, digest=${remote_digest:-unknown}；本地 size=$expected_size, digest=sha256:$expected_sha"
  fi
}

upload_release_asset() { # <module> <local file> <asset name> <sha256>
  local module="$1" local_file="$2" asset_name="$3" expected_sha="$4"
  local expected_size attempt=1

  [ -f "$local_file" ] && [ ! -L "$local_file" ] \
    || die "[$module] 待上传产物不存在或不是普通文件: $local_file"
  expected_size="$(wc -c <"$local_file" | tr -d '[:space:]')"

  # 发布开始前已有同名资产仍按版本冲突处理；只有本次上传返回失败后的
  # 不确定状态，才允许通过远端 size + digest 证明其实已经成功。
  inspect_release_asset "$asset_name" "$expected_size" "$expected_sha" \
    || die "[$module] 无法读取产物桶资产元数据，拒绝上传"
  [ "$RELEASE_ASSET_STATE" = "absent" ] \
    || die "[$module] 产物桶已存在同名文件，拒绝覆盖: ${asset_name}（${RELEASE_ASSET_DETAIL}）"

  while [ "$attempt" -le "$PUBLISH_UPLOAD_MAX_ATTEMPTS" ]; do
    log "[$module] 上传产物桶（第 $attempt/$PUBLISH_UPLOAD_MAX_ATTEMPTS 次）"
    if gh release upload "$BUCKET_TAG" "$local_file" -R "$REPO"; then
      return 0
    fi

    warn "[$module] 上传命令失败；先核验远端同名资产，再决定是否重试"
    inspect_release_asset "$asset_name" "$expected_size" "$expected_sha" \
      || die "[$module] 上传失败且无法确认远端状态，拒绝盲目重试"
    case "$RELEASE_ASSET_STATE" in
      identical)
        log "[$module] 上传响应虽失败，但 ${RELEASE_ASSET_DETAIL}，按成功继续"
        return 0
        ;;
      conflict)
        die "[$module] 上传失败后发现同名资产不一致，拒绝覆盖: ${asset_name}（${RELEASE_ASSET_DETAIL}）"
        ;;
      absent)
        if [ "$attempt" -ge "$PUBLISH_UPLOAD_MAX_ATTEMPTS" ]; then
          die "[$module] 上传已失败 $attempt 次，且远端仍无同名资产"
        fi
        if [ "$PUBLISH_UPLOAD_RETRY_DELAY_SECONDS" -gt 0 ]; then
          sleep "$PUBLISH_UPLOAD_RETRY_DELAY_SECONDS"
        fi
        attempt=$((attempt + 1))
        ;;
      *) die "[$module] 未知远端资产状态: $RELEASE_ASSET_STATE" ;;
    esac
  done
}

remote_artifact_metadata() { # <远端绝对路径>；设置 REMOTE_ARTIFACT_SIZE/SHA256
  local remote_path="$1" remote_q metadata
  printf -v remote_q '%q' "$remote_path"
  metadata="$(ssh "$BUILD_HOST" \
    "test -f $remote_q && test ! -L $remote_q && stat -c '%s' -- $remote_q && sha256sum -- $remote_q")" \
    || die "无法读取构建机产物元数据: $remote_path"
  REMOTE_ARTIFACT_SIZE="$(sed -n '1p' <<<"$metadata")"
  REMOTE_ARTIFACT_SHA256="$(sed -n '2p' <<<"$metadata" | awk '{print $1}')"
  case "$REMOTE_ARTIFACT_SIZE" in
    '' | *[!0-9]*) die "构建机产物大小非法: $REMOTE_ARTIFACT_SIZE" ;;
  esac
  [ "$REMOTE_ARTIFACT_SIZE" -gt 0 ] || die "构建机产物是空文件: $remote_path"
  [ "${#REMOTE_ARTIFACT_SHA256}" -eq 64 ] \
    || die "构建机产物 SHA-256 长度非法: $REMOTE_ARTIFACT_SHA256"
  case "$REMOTE_ARTIFACT_SHA256" in
    *[!0-9a-f]*) die "构建机产物 SHA-256 非法: $REMOTE_ARTIFACT_SHA256" ;;
  esac
}

verify_remote_artifact_arch() { # <远端产物> <aarch64|x86_64|noarch> <module>
  local remote_path="$1" expected="$2" module="$3"
  # 大型 Agent 包的解包和逐文件扫描可能长时间没有 stdout；主动发送 SSH
  # keepalive，避免中间网络设备把仍在运行的只读检查误判为空闲连接。
  ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
    "$BUILD_HOST" /usr/bin/bash -s -- "$remote_path" "$expected" "$module" \
    <"$HERE/verify-artifact-arch.sh" \
    || die "[$module] 构建机产物架构检查失败"
}

builder_upload_once() { # <远端产物> <asset> <release id> <size> <sha256>
  local remote_path="$1" asset_name="$2" release_id="$3" expected_size="$4" expected_sha="$5"
  local token remote_script remote_cmd

  token="$(gh auth token)" || return 1
  [ -n "$token" ] || return 1

  # 令牌只经 SSH stdin 进入远端 shell；不进入 ssh 命令行、远端进程参数或日志。
  # curl 的临时 config 为 0600，并由 trap 删除。上传文件始终是已经过 size/SHA
  # 和架构门禁的构建机 canonical 产物。
  remote_script=$'set -euo pipefail\n'
  remote_script+=$'remote_path=$1\nasset_name=$2\nrepo=$3\nrelease_id=$4\nexpected_size=$5\nexpected_sha=$6\n'
  remote_script+=$'test -f "$remote_path" && test ! -L "$remote_path"\n'
  remote_script+=$'test "$(stat -c \'%s\' -- "$remote_path")" = "$expected_size"\n'
  remote_script+=$'test "$(sha256sum -- "$remote_path" | awk \'{print $1}\')" = "$expected_sha"\n'
  remote_script+=$'IFS= read -r token\ntest -n "$token"\numask 077\n'
  remote_script+=$'auth_config=$(mktemp /tmp/dbdog-gh-auth.XXXXXX)\nresponse=$(mktemp /tmp/dbdog-gh-upload.XXXXXX)\n'
  remote_script+=$'cleanup() { rm -f -- "$auth_config" "$response"; }\ntrap cleanup EXIT HUP INT TERM\n'
  remote_script+=$'printf \'header = "Authorization: Bearer %s"\\n\' "$token" >"$auth_config"\nunset token\n'
  remote_script+=$'set +e\nhttp_code=$(curl --silent --show-error --output "$response" --write-out \'%{http_code}\' --request POST --config "$auth_config" --header \'Accept: application/vnd.github+json\' --header \'X-GitHub-Api-Version: 2022-11-28\' --header \'Content-Type: application/octet-stream\' --data-binary "@$remote_path" "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$asset_name")\ncurl_rc=$?\nset -e\n'
  remote_script+=$'if [ "$curl_rc" -ne 0 ] || [ "$http_code" != 201 ]; then\n  printf \'GitHub builder upload failed: curl_rc=%s http=%s\\n\' "$curl_rc" "$http_code" >&2\n  sed -n \'1,20p\' "$response" >&2\n  exit 1\nfi\n'

  printf -v remote_cmd '/usr/bin/bash -c %q _ %q %q %q %q %q %q' \
    "$remote_script" "$remote_path" "$asset_name" "$REPO" "$release_id" \
    "$expected_size" "$expected_sha"
  printf '%s\n' "$token" | ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
    "$BUILD_HOST" "$remote_cmd"
}

upload_release_asset_from_builder() { # <module> <远端产物> <asset> <size> <sha256>
  local module="$1" remote_path="$2" asset_name="$3" expected_size="$4" expected_sha="$5"
  local release_id attempt=1

  inspect_release_asset "$asset_name" "$expected_size" "$expected_sha" \
    || die "[$module] 无法读取产物桶资产元数据，拒绝上传"
  [ "$RELEASE_ASSET_STATE" = "absent" ] \
    || die "[$module] 产物桶已存在同名文件，拒绝覆盖: ${asset_name}（${RELEASE_ASSET_DETAIL}）"
  release_id="$(gh api "repos/$REPO/releases/tags/$BUCKET_TAG" --jq '.id')" \
    || die "[$module] 无法读取产物桶 release id"
  case "$release_id" in '' | *[!0-9]*) die "[$module] 产物桶 release id 非法" ;; esac

  while [ "$attempt" -le "$PUBLISH_UPLOAD_MAX_ATTEMPTS" ]; do
    log "[$module] 构建机直传产物桶（第 $attempt/$PUBLISH_UPLOAD_MAX_ATTEMPTS 次）"
    if builder_upload_once "$remote_path" "$asset_name" "$release_id" \
        "$expected_size" "$expected_sha"; then
      return 0
    fi

    warn "[$module] 构建机直传失败；先核验远端同名资产，再决定是否重试"
    inspect_release_asset "$asset_name" "$expected_size" "$expected_sha" \
      || die "[$module] 直传失败且无法确认远端状态，拒绝盲目重试"
    case "$RELEASE_ASSET_STATE" in
      identical)
        log "[$module] 上传响应虽失败，但 ${RELEASE_ASSET_DETAIL}，按成功继续"
        return 0
        ;;
      conflict)
        die "[$module] 直传失败后发现同名资产不一致，拒绝覆盖: ${asset_name}（${RELEASE_ASSET_DETAIL}）"
        ;;
      absent)
        [ "$attempt" -lt "$PUBLISH_UPLOAD_MAX_ATTEMPTS" ] \
          || die "[$module] 构建机直传已失败 $attempt 次，且远端仍无同名资产"
        [ "$PUBLISH_UPLOAD_RETRY_DELAY_SECONDS" -eq 0 ] \
          || sleep "$PUBLISH_UPLOAD_RETRY_DELAY_SECONDS"
        attempt=$((attempt + 1))
        ;;
      *) die "[$module] 未知远端资产状态: $RELEASE_ASSET_STATE" ;;
    esac
  done
}

fetch_remote_artifact() { # <远端绝对路径> <本地文件>；校验远端 SHA，支持断点续传
  local remote_path="$1" dest="$2" remote_q metadata remote_size remote_sha
  local local_size=0 local_sha="" remote_prefix_sha=""
  printf -v remote_q '%q' "$remote_path"
  metadata="$(ssh "$BUILD_HOST" \
    "stat -c '%s' -- $remote_q && sha256sum -- $remote_q")" \
    || die "无法读取构建机产物元数据: $remote_path"
  remote_size="$(sed -n '1p' <<<"$metadata")"
  remote_sha="$(sed -n '2p' <<<"$metadata" | awk '{print $1}')"
  case "$remote_size" in '' | *[!0-9]*) die "构建机产物大小非法: $remote_size" ;; esac
  [ "${#remote_sha}" -eq 64 ] || die "构建机产物 SHA-256 长度非法: $remote_sha"
  case "$remote_sha" in *[!0-9a-f]*) die "构建机产物 SHA-256 非法: $remote_sha" ;; esac

  if [ -f "$dest" ]; then
    local_size="$(wc -c <"$dest" | tr -d '[:space:]')"
    if [ "$local_size" -eq "$remote_size" ]; then
      local_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
      if [ "$local_sha" = "$remote_sha" ]; then
        log "复用已完整取回的产物（远端 SHA-256 一致）"
        return 0
      fi
    fi

    if [ "$local_size" -gt 0 ] && [ "$local_size" -lt "$remote_size" ]; then
      local_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
      remote_prefix_sha="$(ssh "$BUILD_HOST" \
        "head -c $local_size -- $remote_q | sha256sum" | awk '{print $1}')" \
        || die "无法校验构建机产物前缀"
      if [ "$local_sha" != "$remote_prefix_sha" ]; then
        warn "本地产物前缀与构建机不一致，从头取回"
        truncate -s 0 -- "$dest"
        local_size=0
      fi
    else
      truncate -s 0 -- "$dest"
      local_size=0
    fi
  fi

  if [ "$local_size" -gt 0 ]; then
    log "从 $local_size / $remote_size 字节继续取回"
  fi
  # 目标构建机的 SFTP 链路可能极慢；SSH stdout 既能复用现有认证，也能从精确字节续传。
  # banner 走 stderr，不会混入产物。失败时保留已验证前缀，下一次 publish 可继续。
  ssh "$BUILD_HOST" "tail -c +$((local_size + 1)) -- $remote_q" >>"$dest" \
    || die "从构建机取回产物失败（已保留断点）"
  [ "$(wc -c <"$dest" | tr -d '[:space:]')" -eq "$remote_size" ] \
    || die "取回后的产物大小与构建机不一致"
  sha256_verify "$dest" "$remote_sha" \
    || die "取回后的产物 SHA-256 与构建机不一致"
}

manifest_module_field() { # manifest_module_field <module> <列号>；取该模块模块级字段
  # 只用于按模块恒定、不随架构变化的列（kind/target/service/version/source_sha）。
  # 允许同一模块混有已发布行与未发布声明行时：version/source_sha 优先取已发布行
  # （非 "-"）；kind/target/service 取任意一行（manifest_all_rows 已强制一致）。
  # 不要用它读 artifact/sha256，那两列按架构各不相同。
  local m="$1" col="$2" value
  value="$(manifest_all_rows | awk -F'\t' -v m="$m" -v c="$col" '
      $1 == m {
        if (c == 5 || c == 8) {
          if ($c != "-") { print $c; found = 1; exit }
          if (!pending) pending = $c
        } else {
          print $c; found = 1; exit
        }
      }
      END {
        if (!found && pending != "") print pending
      }
    ')"
  [ -n "$value" ] || { printf 'ERROR: manifest 中没有模块 %s\n' "$m" >&2; return 1; }
  printf '%s\n' "$value"
}

publish_maybe_push_main() { # publish_maybe_push_main <失败提示>
  local fail_msg="$1"
  if [ "${DBDOG_PUBLISH_SKIP_PUSH:-}" = "1" ]; then
    log "DBDOG_PUBLISH_SKIP_PUSH=1：跳过 git push origin main（本地已提交）"
    return 0
  fi
  git -C "$RELEASE_DIR" push origin main || die "$fail_msg"
}

# ---- 原生 builder 解析（每个架构独立执行器；旧 BUILD_HOST 只在自证同架构时兼容回退）----
resolve_build_host_for_arch() { # resolve_build_host_for_arch <aarch64|x86_64|noarch> → 设置 RESOLVED_BUILD_HOST
  local arch="$1" configured="" varname="" legacy_arch=""
  case "$arch" in
    aarch64) configured="${BUILD_HOST_AARCH64:-}"; varname=BUILD_HOST_AARCH64 ;;
    x86_64) configured="${BUILD_HOST_X86_64:-}"; varname=BUILD_HOST_X86_64 ;;
    noarch)
      # noarch 产物不含机器码，用哪台已登记的原生机构建都一样；优先复用 aarch64 的
      # builder（历史上唯一的 BUILD_HOST 就是 aarch64 机），没配置才试 x86_64。
      configured="${BUILD_HOST_AARCH64:-}"; varname=BUILD_HOST_AARCH64
      if [ -z "$configured" ] || [ "$configured" = "$BUILD_HOST_PLACEHOLDER" ]; then
        configured="${BUILD_HOST_X86_64:-}"; varname=BUILD_HOST_X86_64
      fi
      ;;
    *) die "不支持为架构 $arch 解析原生 builder" ;;
  esac
  if [ -n "$configured" ] && [ "$configured" != "$BUILD_HOST_PLACEHOLDER" ]; then
    RESOLVED_BUILD_HOST="$configured"
    return 0
  fi
  if [ "$arch" = "noarch" ]; then
    # noarch 不对应任何真实 CPU 架构，不需要（也没法）验证 uname -m；只要旧
    # BUILD_HOST 存在就可以直接复用，不用 QEMU、不把未登记的 VM 当 builder。
    [ -n "${BUILD_HOST:-}" ] && [ "$BUILD_HOST" != "$BUILD_HOST_PLACEHOLDER" ] \
      || die "没有为 noarch 构建配置任何原生 builder（BUILD_HOST_AARCH64/BUILD_HOST_X86_64 或兼容的 BUILD_HOST），拒绝构建（cp publish.conf.example publish.conf 后按架构填写）"
    RESOLVED_BUILD_HOST="$BUILD_HOST"
    return 0
  fi
  # 兼容回退：旧的单一 BUILD_HOST，只有在它对这个架构自证是原生机时才可用；
  # 不用 QEMU、不把未登记的 VM 当 builder，没有对应 builder 就整体 fail closed。
  [ -n "${BUILD_HOST:-}" ] && [ "$BUILD_HOST" != "$BUILD_HOST_PLACEHOLDER" ] \
    || die "没有为架构 $arch 配置原生 builder（${varname} 或兼容的 BUILD_HOST），拒绝构建（cp publish.conf.example publish.conf 后按架构填写）"
  legacy_arch="$(ssh "$BUILD_HOST" uname -m | tail -n1)" \
    || die "无法读取 BUILD_HOST（${BUILD_HOST}）架构，拒绝把它当作 $arch 的兼容 builder"
  legacy_arch="$(normalize_arch "$legacy_arch" 2>/dev/null)" \
    || die "BUILD_HOST（${BUILD_HOST}）架构无法规范化，拒绝把它当作 $arch 的兼容 builder"
  [ "$legacy_arch" = "$arch" ] \
    || die "BUILD_HOST（${BUILD_HOST}，实际架构 ${legacy_arch}）与请求架构 $arch 不一致，拒绝跨架构构建；请配置 ${varname}"
  RESOLVED_BUILD_HOST="$BUILD_HOST"
}

publish_ensure_arch_builders() { # publish_ensure_arch_builders <module>；该模块全部目标架构必须都有可用原生 builder
  # 逐架构预检，不产生任何构建/上传副作用（resolve_build_host_for_arch 只读配置、
  # 最多探一次 uname -m）。任一架构缺少 builder 就在这里 die，早于对该模块任何
  # 一个架构调用 build_one_arch——避免排在前面的架构先真的构建了一遍，才发现矩阵
  # 因为后面某个架构没有 builder 而注定无法完整提交。
  local m="$1" arch
  while IFS= read -r arch; do
    [ -n "$arch" ] || continue
    resolve_build_host_for_arch "$arch"
  done < <(publish_arches_for_module "$m")
}

# ---- 事务目录（gitignored scratch/publish-txn/<module>-<version>-<release-head>/，mode 0700）----
publish_txn_dir() { # publish_txn_dir <module> <version> → 事务目录路径（不创建，不写文件）
  local m="$1" v="$2" head
  case "$m" in "" | */* | *$'\n'* | *$'\t'*) die "事务目录模块名非法: $m" ;; esac
  case "$v" in */* | *$'\n'* | *$'\t'*) die "事务目录版本号非法: $v" ;; esac
  head="$(git -C "$RELEASE_DIR" rev-parse HEAD)" \
    || die "无法读取发布仓 HEAD，拒绝定位事务目录"
  printf '%s/%s-%s-%s\n' "$PUBLISH_TXN_ROOT" "$m" "${v:-unversioned}" "$head"
}

publish_txn_init() { # publish_txn_init <module> <version> → 创建/复用事务目录（0700），校验 release-head 未漂移
  local m="$1" v="$2" dir head_file head
  dir="$(publish_txn_dir "$m" "$v")"
  head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  mkdir -p "$dir"
  chmod 0700 "$dir"
  head_file="$dir/release-head"
  if [ -f "$head_file" ]; then
    [ "$(<"$head_file")" = "$head" ] \
      || die "[$m] 事务目录已记录不同的 release HEAD，拒绝复用: $dir"
  else
    printf '%s\n' "$head" >"$head_file"
    chmod 0600 "$head_file"
  fi
  printf '%s\n' "$dir"
}

publish_arches_for_module() { # publish_arches_for_module <module> → 该模块 manifest 中的目标架构（一行一个）
  manifest_arches "$1"
}

resolve_module_recipe() { # resolve_module_recipe <module> <arch> → 设置 RESOLVED_RECIPE
  # 存在 recipes/<module>-<arch>.sh 时精确选择该架构专属配方，否则回退
  # 到共享的 recipes/<module>.sh。其余模块的架构差异（如 ddprof）在同一份配方
  # 内部用 ARCH 分支处理，没有拆分文件，也就没有对应的 <module>-<arch>.sh，
  # 天然落进回退分支。
  local m="$1" arch="$2"
  local exact="$HERE/recipes/$m-$arch.sh"
  if [ -f "$exact" ] && [ ! -L "$exact" ]; then
    RESOLVED_RECIPE="$exact"
  else
    RESOLVED_RECIPE="$HERE/recipes/$m.sh"
  fi
}

agent_preflight_anchor_controls() { # <build host> <agent sha> <core sha>
  # Agent 的 omnibus 构建要跑几小时，而它依赖的一整套随锚控制物（anchor 目录、control
  # overlay、GaussDB wheel、build attempt、pipeline lock）都得由管理员用
  # prepare-agent-anchor.sh 事先以 root 就位。任何一项缺失或对不上锚，过去都要等到构建
  # 中途甚至 finalize 阶段才暴露；这里在花掉那几小时之前先把它们全查一遍。
  local host="$1" sha="$2" core="$3" detail
  log "[dbdog-agent/aarch64] 预检构建机上的随锚控制物 ..."
  if ! detail="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" \
      "AGENT_SHA=$sha CORE_SHA=$core bash -s" <<'REMOTE_PREFLIGHT'
set -u
cache=/home/dbdog/cache/dbdog-agent
short=${AGENT_SHA:0:8}
anchor_dir="$cache/anchors/$AGENT_SHA"
anchor_info="$anchor_dir/ANCHOR-INFO"
fail() { printf 'PREFLIGHT_FAIL %s\n' "$*"; exit 1; }
field() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; n++ } END { exit(n == 1 ? 0 : 1) }' "$1"; }

[ -f "$anchor_info" ] || fail "缺少 $anchor_info"
[ "$(stat -c '%u:%g:%a' -- "$anchor_info")" = 0:0:444 ] || fail 'ANCHOR-INFO 必须是 root:root 0444'
[ "$(field "$anchor_info" release_agent_sha)" = "$AGENT_SHA" ] || fail 'ANCHOR-INFO 的 release_agent_sha 与基线不符'
[ "$(field "$anchor_info" integration_core_sha)" = "$CORE_SHA" ] || fail 'ANCHOR-INFO 的 integration_core_sha 与基线不符'

overlay_rel="$(field "$anchor_info" control_overlay_rel)" || fail 'ANCHOR-INFO 缺少 control_overlay_rel'
overlay_dir="$cache/$overlay_rel"
[ -d "$overlay_dir" ] || fail "缺少 control overlay $overlay_dir"
[ "$(stat -c '%u:%g' -- "$overlay_dir")" = 0:0 ] || fail 'control overlay 必须由 root:root 持有'
[ "$(field "$overlay_dir/CONTROL-INFO" release_agent_sha)" = "$AGENT_SHA" ] || fail 'control overlay 自报的 release_agent_sha 与基线不符'
(cd "$cache" && sha256sum -c "$overlay_rel/CONTROL.sha256" >/dev/null 2>&1) || fail 'control overlay 内容与自带清单不符'

for control in finalize-agent-runtime.sh run-finalize-agent-runtime.sh; do
  [ -f "$anchor_dir/$control" ] || fail "缺少随锚重写的 $control"
  [ "$(stat -c '%u:%g:%a' -- "$anchor_dir/$control")" = 0:0:555 ] || fail "$control 必须是 root:root 0555"
done
expect_finalizer="$(field "$anchor_info" finalizer_sha256)"
actual_finalizer="$(sha256sum -- "$anchor_dir/finalize-agent-runtime.sh")"
[ "${actual_finalizer%% *}" = "$expect_finalizer" ] || fail 'finalizer 字节与 ANCHOR-INFO 记录不符'
expect_wrapper="$(field "$anchor_info" finalizer_wrapper_sha256)"
actual_wrapper="$(sha256sum -- "$anchor_dir/run-finalize-agent-runtime.sh")"
[ "${actual_wrapper%% *}" = "$expect_wrapper" ] || fail 'finalizer wrapper 字节与 ANCHOR-INFO 记录不符'

wheel="$cache/sources/python/gaussdb/$CORE_SHA/datadog_gaussdb-1.0.1-py3-none-any.whl"
[ -f "$wheel" ] || fail "缺少该 core 提交的 GaussDB wheel: $wheel"
[ "$(stat -c '%u:%g:%a' -- "$wheel")" = 0:0:444 ] || fail 'GaussDB wheel 必须是 root:root 0444'

build_dir=/home/dbdog/work/dbdog-agent-$short-build2
[ -d "$build_dir" ] || fail "缺少 build attempt $build_dir"
[ "$(stat -c '%U:%G:%a' -- "$build_dir")" = dbdog:dbdog:775 ] || fail 'build attempt 必须是 dbdog:dbdog 0775'
lock="$cache/locks/dbdog-agent-$short-aarch64-kylin10.pipeline.lock"
[ -f "$lock" ] || fail "缺少 pipeline lock $lock"
[ "$(stat -c '%U:%G:%a' -- "$lock")" = root:dbdog:644 ] || fail 'pipeline lock 必须是 root:dbdog 0644'

printf 'PREFLIGHT_OK overlay=%s generation=%s\n' "${overlay_rel##*/}" "$(field "$anchor_info" control_overlay_generation)"
REMOTE_PREFLIGHT
    )"; then
    printf '%s\n' "$detail" >&2
    die "[dbdog-agent/aarch64] 构建机上的随锚控制物未就位或与基线不符。请管理员在构建机上以 root 执行 scripts/publish/agent-build/prepare-agent-anchor.sh 换锚到 ${sha:0:12} / core ${core:0:12} 后重试"
  fi
  log "[dbdog-agent/aarch64] 预检通过：${detail#PREFLIGHT_OK }"
}

build_one_arch() { # build_one_arch <module> <version(三方件传空)> <arch> → 向事务 TSV 追加一行，不上传、不改 manifest
  local m="$1" ver="$2" arch="$3" sha="" core="" kind agent_baseline_blob=""
  local recipe txn_dir txn_tsv
  resolve_module_recipe "$m" "$arch"
  recipe="$RESOLVED_RECIPE"
  [ -f "$recipe" ] && [ ! -L "$recipe" ] || die "缺少构建配方: $recipe"
  case "$arch" in
    aarch64 | x86_64 | noarch) ;;
    *) die "[$m] 不支持的构建架构: $arch" ;;
  esac

  txn_dir="$(publish_txn_init "$m" "$ver")"
  txn_tsv="$txn_dir/txn.tsv"

  # kind/sha/Agent 基线门禁必须在短路判断之前算出来——短路只是"跳过重新构建"，
  # 不是"跳过校验"：Agent 的官方基线合法性（agent_version_uses_loaded_baseline）
  # 每次调用都要重新核实，不能因为事务里已经有一行记录就假定基线没变过。
  kind="$(manifest_get "$m" 2 "$arch")"
  if [ "$kind" = "first-party" ]; then
    if [ "$m" = "dbdog-agent" ]; then
      load_agent_release_baseline
      sha="$AGENT_RELEASE_SOURCE_COMMIT"
      core="$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT"
      agent_version_uses_loaded_baseline "$ver" \
        || die "[$m] 待构建版本不属于当前官方基线: $ver"
      agent_baseline_blob="$(git -C "$SRC_ROOT/dbdog-agent" hash-object \
        dbdog-deploy/RELEASE-BASELINE.tsv)"
    else
      sha="$(git -C "$SRC_ROOT/$m" rev-parse HEAD)"
    fi
  fi

  # 这次调用如果真的构建，理应记录的 source_sha——短路前用它核对事务里已经记录的
  # 那一行是否仍然对应当前源码/当前基线；真正构建完成后也复用同一份计算结果写进
  # 事务行，两处不用两套口径，避免分裂。
  local live_srcsha="-"
  if [ "$kind" = "first-party" ]; then
    if [ "$m" = "dbdog-agent" ]; then
      live_srcsha="$(agent_loaded_source_fingerprint)"
    else
      live_srcsha="$(live_sha "$m")"
    fi
  fi

  if [ -f "$txn_tsv" ]; then
    local existing_srcsha
    existing_srcsha="$(awk -F'\t' -v m="$m" -v a="$arch" \
      '$1==m && $2==a { print $7; exit }' "$txn_tsv")"
    if [ -n "$existing_srcsha" ]; then
      [ "$existing_srcsha" = "$live_srcsha" ] || \
        die "[$m/$arch] 事务已记录的构建使用了旧的 source_sha（事务记录=${existing_srcsha}，当前源码=${live_srcsha}），源码/基线在事务开始后发生了漂移，拒绝复用陈旧构建；清理事务目录后重新发布: $txn_dir"
      log "[$m/$arch] 事务已记录该架构的构建结果，且 source_sha 与当前源码一致，跳过重复构建（同一事务目录内恢复）"
      return 0
    fi
  fi

  resolve_build_host_for_arch "$arch"
  local BUILD_HOST="$RESOLVED_BUILD_HOST"

  if [ "$m" = dbdog-agent ] && [ "$arch" = aarch64 ]; then
    agent_preflight_anchor_controls "$BUILD_HOST" "$sha" "$core"
  fi

  log "[$m/$arch] 构建于 $BUILD_HOST ..."
  local out recipe_stdout
  if ! recipe_stdout="$(ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
        "$BUILD_HOST" MODULE="$m" VERSION="$ver" SHA="$sha" CORE_SHA="$core" \
        ARCH="$arch" REPO_ROOT="$REPO_ROOT" BUILD_WORK="$BUILD_WORK" TOOL_PATH="$TOOL_PATH" \
        PG_PREFIX="${PG_PREFIX:-}" CH_BIN="${CH_BIN:-}" bash -s <"$recipe")"; then
    die "[$m/$arch] 远端构建配方执行失败"
  fi
  out="$(printf '%s\n' "$recipe_stdout" | tail -n1)"
  BUILT_VERSION="${out%%$'\t'*}"
  local rpath="${out#*$'\t'}"
  [ -n "$BUILT_VERSION" ] && [ "$rpath" != "$out" ] || die "[$m/$arch] 配方输出不合约定（应为 版本<TAB>产物路径）: $out"
  if [ "$kind" = "first-party" ] && [ "$BUILT_VERSION" != "$ver" ]; then
    die "[$m/$arch] 配方返回版本与发布计划不一致: 计划=${ver}，实际=$BUILT_VERSION"
  fi

  BUILT_ARTIFACT="$(basename "$rpath")"
  case "$BUILT_ARTIFACT" in
    "$m"-*) ;;
    *) die "[$m/$arch] 产物名不属于该模块: $BUILT_ARTIFACT" ;;
  esac
  local expected_rpath
  if [ "$m" = dbdog-agent ] && [ "$arch" = aarch64 ]; then
    # aarch64 Agent 的受封存配方、root finalizer 与 dependency seal 共同钉死这个
    # build attempt；它不能搬到通用 BUILD_WORK，否则就绕开 canonical artifact 的
    # 路径/owner/mode 门禁。（曾并存过一份 x86_64 Agent 配方，按「GitHub 只出 arm」
    # 的决定于 2026-08-05 删除；未来若有别的架构配方，同样落在通用 BUILD_WORK 下。）
    expected_rpath="/home/dbdog/work/dbdog-agent-${sha:0:8}-build2/out/$BUILT_ARTIFACT"
  else
    expected_rpath="$BUILD_WORK/$m/out/$BUILT_ARTIFACT"
  fi
  [ "$rpath" = "$expected_rpath" ] || \
    die "[$m/$arch] 配方产物不在约定的远端 out 目录: $rpath"
  local artifact_arch
  case "$BUILT_ARTIFACT" in
    *-"$arch".tar.gz) artifact_arch="$arch" ;;
    *-noarch.tar.gz) artifact_arch="noarch" ;;
    *) die "[$m/$arch] 产物名没有受支持的架构后缀: $BUILT_ARTIFACT" ;;
  esac
  remote_artifact_metadata "$rpath"
  verify_remote_artifact_arch "$rpath" "$artifact_arch" "$m"
  BUILT_SHA256="$REMOTE_ARTIFACT_SHA256"

  if [ "$m" = "dbdog-agent" ]; then
    # Agent 构建耗时很长；记录事务前重读基线，避免等待期间有人换锚，导致版本/事务
    # 记录与刚构建完成的实际 SHA 不一致。
    load_agent_release_baseline
    [ "$AGENT_RELEASE_SOURCE_COMMIT" = "$sha" ] \
      && [ "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" = "$core" ] \
      && [ "$(git -C "$SRC_ROOT/dbdog-agent" hash-object \
        dbdog-deploy/RELEASE-BASELINE.tsv)" = "$agent_baseline_blob" ] \
      || die "[$m/$arch] 构建期间发布基线发生变化，拒绝记录事务；请按新基线重新构建"
    agent_version_uses_loaded_baseline "$BUILT_VERSION" \
      || die "[$m/$arch] 构建版本已不属于当前官方基线，拒绝记录事务: $BUILT_VERSION"
  fi

  # 复用函数开头算好的 live_srcsha（短路判断用的是同一个值），不再重新计算一遍，
  # 避免两处口径分裂；Agent 分支上面的基线复读门禁已经确认它没有在构建期间失效。
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$m" "$arch" "$BUILT_VERSION" "$rpath" "$REMOTE_ARTIFACT_SIZE" "$BUILT_SHA256" "$live_srcsha" \
    >>"$txn_tsv"
  log "[$m/$arch] 已记录事务行（未上传、未改 manifest）"
}

# ---- 恢复认领：release HEAD、module、version、source SHA、arch、远端绝对路径、size、
# sha 全部与事务记录一致，且 manifest 仍指向旧版本，才允许把远端已存在的同名资产当
# 成本次事务自己上传的产物；任一项不一致就 return 1（调用方 fail closed，不删除资产）。
publish_verify_recovery_claim() { # <module> <arch> <version> <remote_path> <size> <sha> <source_sha> <txn_dir>；调用前 BUILD_HOST 已按 arch 解析
  local module="$1" arch="$2" version="$3" remote_path="$4" size="$5" sha="$6"
  local source_sha="$7" txn_dir="$8"
  local head_file="$txn_dir/release-head" recorded_head current_head

  [ -f "$head_file" ] || return 1
  recorded_head="$(<"$head_file")"
  current_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)" || return 1
  [ "$recorded_head" = "$current_head" ] || return 1

  local live_kind live_source
  live_kind="$(manifest_get "$module" 2 "$arch" 2>/dev/null)" || return 1
  if [ "$live_kind" = "first-party" ]; then
    if [ "$module" = "dbdog-agent" ]; then
      load_agent_release_baseline
      live_source="$(agent_loaded_source_fingerprint)"
    else
      live_source="$(live_sha "$module")"
    fi
  else
    live_source="-"
  fi
  [ "$live_source" = "$source_sha" ] || return 1

  # manifest 仍指向旧版本，证明这次事务的提交阶段确实还没跑过。
  local manifest_version
  if manifest_version="$(manifest_get "$module" 5 "$arch" 2>/dev/null)"; then
    [ "$manifest_version" != "$version" ] || return 1
  fi

  local remote_q remote_probe remote_size remote_sha
  printf -v remote_q '%q' "$remote_path"
  remote_probe="$(ssh "$BUILD_HOST" \
    "test -f $remote_q && test ! -L $remote_q && stat -c '%s' -- $remote_q && sha256sum -- $remote_q" \
    2>/dev/null)" || return 1
  remote_size="$(sed -n '1p' <<<"$remote_probe")"
  remote_sha="$(sed -n '2p' <<<"$remote_probe" | awk '{print $1}')"
  [ "$remote_size" = "$size" ] || return 1
  [ "$remote_sha" = "$sha" ] || return 1

  return 0
}

publish_claim_or_upload_arch_asset() { # <module> <arch> <version> <remote_path> <asset> <size> <sha> <source_sha> <txn_dir>
  local module="$1" arch="$2" version="$3" remote_path="$4" asset_name="$5"
  local size="$6" sha="$7" source_sha="$8" txn_dir="$9"

  resolve_build_host_for_arch "$arch"
  local BUILD_HOST="$RESOLVED_BUILD_HOST"

  inspect_release_asset "$asset_name" "$size" "$sha" \
    || die "[$module/$arch] 无法读取产物桶资产元数据，拒绝上传"
  case "$RELEASE_ASSET_STATE" in
    absent)
      upload_release_asset_from_builder "$module" "$remote_path" "$asset_name" "$size" "$sha"
      ;;
    identical)
      if publish_verify_recovery_claim "$module" "$arch" "$version" "$remote_path" \
          "$size" "$sha" "$source_sha" "$txn_dir"; then
        log "[$module/$arch] 认领已上传的产物桶资产（恢复记录七项一致，未重新上传）：$asset_name"
      else
        die "[$module/$arch] 产物桶已存在同名文件但恢复校验未通过，拒绝认领（可能是无关残留，不删除现有资产）: $asset_name"
      fi
      ;;
    conflict)
      die "[$module/$arch] 产物桶已存在同名文件，拒绝覆盖: ${asset_name}（${RELEASE_ASSET_DETAIL}）"
      ;;
    *) die "[$module/$arch] 未知远端资产状态: $RELEASE_ASSET_STATE" ;;
  esac
}

publish_manifest_row_matches_target() { # <module> <arch> <version> <artifact> <sha256> <source_sha> → 0/1
  # manifest.tsv 里 (module, arch) 那一行是否已经恰好等于事务要写入的目标值。
  # 只在这五列都能读到且完全相等时返回 0；读不到该行（尚未发布过这个架构）或任一
  # 列不等都返回 1——这是"目标状态尚未生效"，不是错误。
  local m="$1" a="$2" v="$3" art="$4" sha="$5" ssha="$6"
  local cur_v cur_art cur_sha cur_ssha
  cur_v="$(manifest_get "$m" 5 "$a" 2>/dev/null)" || return 1
  cur_art="$(manifest_get "$m" 6 "$a" 2>/dev/null)" || return 1
  cur_sha="$(manifest_get "$m" 7 "$a" 2>/dev/null)" || return 1
  cur_ssha="$(manifest_get "$m" 8 "$a" 2>/dev/null)" || return 1
  [ "$cur_v" = "$v" ] && [ "$cur_art" = "$art" ] && [ "$cur_sha" = "$sha" ] && [ "$cur_ssha" = "$ssha" ]
}

publish_resume_pending_push() { # publish_resume_pending_push <module> → 0：HEAD 已是该模块本次发布的提交、只差 push，已就地补 push+prune 并返回；1：不是这个状态，调用方走正常流程
  # 覆盖"commit 成功、push 失败"这道中断窗口。这个状态下 release HEAD 已经因为
  # 我们自己的 commit 前进了，publish_txn_dir 会算出一个新目录、找不到旧事务
  # 记录，没法用 build_one_arch 的短路机制识别"已经做过"；只能反过来看：HEAD 本
  # 身是不是一个还没推的 "publish: <module>@<version>" 提交。命中就只补
  # push+prune，完全不碰构建/上传/manifest，不会重建矩阵也不会重复上传。
  local m="$1" head_msg v arch head_sha origin_sha
  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv README.md || return 1
  head_msg="$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD 2>/dev/null)" || return 1
  case "$head_msg" in
    "publish: ${m}@"*) v="${head_msg#"publish: ${m}@"}" ;;
    *) return 1 ;;
  esac
  [ -n "$v" ] || return 1
  while IFS= read -r arch; do
    [ -n "$arch" ] || continue
    [ "$(manifest_get "$m" 5 "$arch" 2>/dev/null)" = "$v" ] || return 1
  done < <(publish_arches_for_module "$m")

  # 硬判据：上面三条在"上一次发布已经完全成功"这个最常见的稳态下也会全部成立
  # （commit 和 push 都做完之后，HEAD 的提交信息、manifest 版本自然就是这样）——
  # 光凭它们会把稳态误判成"待推送"，直接 no-op 跳过下一次真正该发布的新版本。
  # 必须再确认 HEAD 真的领先本地已知的 origin/main 才能当成"待推送"：push 成功后
  # git 会把本地这个 remote-tracking ref 前移到与 HEAD 一致，push 失败/从未 push
  # 则不会。只用本地缓存的 ref 比较，不为此发起网络访问（不 fetch）；ref 读不到
  # 就不敢确认，一律 fail closed 走正常流程。
  head_sha="$(git -C "$RELEASE_DIR" rev-parse HEAD)" || return 1
  origin_sha="$(git -C "$RELEASE_DIR" rev-parse origin/main 2>/dev/null)" || return 1
  [ "$head_sha" != "$origin_sha" ] || return 1

  log "[$m] HEAD 已是本次发布提交（${head_msg}），只是尚未推送；直接补 push（不重建矩阵、不重新上传）"
  # 显式 || die，不指望调用方永远处在 set -e 会触发的位置——if/while 条件、
  # 命令替换等上下文里 set -e 对普通命令失效，但 die() 的 exit 不受这个影响，
  # 任何时候 push 失败都必须可靠地在这里停下，不能滑到 prune 那一步。
  git -C "$RELEASE_DIR" push origin main \
    || die "[$m] push origin main 失败（本地已提交 ${head_msg}，尚未推送）；请检查网络/权限后重试，不会自动重建矩阵，也不会删除任何资产"
  prune_modules_to_manifest 1 "$m"
  RESUMED_PUBLISH_VERSION="$v"
  return 0
}

publish_apply_arch_matrix_manifest_update() { # <updates.tsv: module arch version artifact sha256 source_sha>
  local updates="$1" tmp
  [ -s "$updates" ] || die "manifest 矩阵更新输入为空: $updates"
  tmp="$(mktemp "$MANIFEST.matrix.XXXXXX")" || die "无法创建 manifest 临时文件"
  if ! awk -F'\t' -v OFS='\t' '
      FNR == NR {
        key = $1 SUBSEP $2
        ver[key] = $3; art[key] = $4; sha[key] = $5; src[key] = $6
        seen[key] = 1
        next
      }
      /^[[:space:]]*(#|$)/ { print; next }
      {
        key = $1 SUBSEP $9
        if (key in seen) {
          $5 = ver[key]; $6 = art[key]; $7 = sha[key]; $8 = src[key]
          matched[key] = 1
        }
        print
      }
      END {
        for (key in seen) {
          if (!(key in matched)) {
            split(key, parts, SUBSEP)
            printf "manifest 矩阵更新目标行不存在 (module=%s, arch=%s)\n", parts[1], parts[2] > "/dev/stderr"
            exit 1
          }
        }
      }
    ' "$updates" "$MANIFEST" >"$tmp"; then
    rm -f -- "$tmp"
    die "manifest 矩阵更新失败（目标 (module,arch) 行必须已存在）"
  fi
  if ! MANIFEST="$tmp" manifest_all_rows >/dev/null; then
    rm -f -- "$tmp"
    die "manifest 矩阵更新结果未通过 manifest_all_rows 严格校验（同模块 version/source_sha 必须一致），拒绝替换 manifest"
  fi
  mv -- "$tmp" "$MANIFEST"
}

publish_commit_arch_matrix() { # publish_commit_arch_matrix <txn.tsv> → 校验完整矩阵、上传/恢复、一次更新全部 (module,arch) 行，regen_readme/commit/push/prune
  local txn_tsv="$1" txn_dir module="" version=""
  [ -f "$txn_tsv" ] && [ ! -L "$txn_tsv" ] || die "事务记录不存在或不是普通文件: $txn_tsv"
  txn_dir="$(cd "$(dirname "$txn_tsv")" && pwd)"

  local -a row_module=() row_arch=() row_version=() row_path=() row_size=() row_sha=() row_srcsha=()
  local m a v p sz sh ss
  while IFS=$'\t' read -r m a v p sz sh ss; do
    [ -n "$m" ] || continue
    if [ -z "$module" ]; then module="$m"; version="$v"; fi
    [ "$m" = "$module" ] || die "事务记录混入多个模块，拒绝提交（${module} 与 ${m}）: $txn_tsv"
    [ "$v" = "$version" ] || die "[$module] 事务记录内版本不一致（${version} 与 ${v}），拒绝提交: $txn_tsv"
    row_module+=("$m"); row_arch+=("$a"); row_version+=("$v"); row_path+=("$p")
    row_size+=("$sz"); row_sha+=("$sh"); row_srcsha+=("$ss")
  done <"$txn_tsv"
  [ ${#row_module[@]} -gt 0 ] || die "事务记录为空，没有可提交的架构: $txn_tsv"

  local expected_arches got_arches
  expected_arches="$(publish_arches_for_module "$module" | sort)"
  got_arches="$(printf '%s\n' "${row_arch[@]}" | sort)"
  [ "$got_arches" = "$expected_arches" ] || die \
    "[$module] 事务未覆盖全部目标架构，拒绝上传（期望: $(tr '\n' ' ' <<<"$expected_arches")｜实际: $(tr '\n' ' ' <<<"$got_arches")）"

  local head_file="$txn_dir/release-head" recorded_head current_head
  [ -f "$head_file" ] || die "[$module] 事务缺少 release-head 记录: $head_file"
  recorded_head="$(<"$head_file")"
  current_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$recorded_head" = "$current_head" ] || die \
    "[$module] 发布仓 HEAD 已从 ${recorded_head:0:12} 漂移到 ${current_head:0:12}，拒绝在陈旧事务上提交"

  ensure_bucket

  # 恢复场景之一：上一次执行已经把全部资产真实上传/认领、也已经把 manifest mv 到
  # 本次目标状态，只是在 commit 之前中断（release HEAD 还没变，所以还能走到这
  # 里）。这种情况下不能再跑一遍上传循环——upload_release_asset_from_builder 对
  # 已经上传过的资产会直接 fail closed（"产物桶已存在同名文件，拒绝覆盖"），而
  # publish_verify_recovery_claim 的恢复认领要求"manifest 仍指向旧版本"，manifest
  # 已经是新版本时会被它拒绝，报出"可能是无关残留"这种其实指向自己刚写的状态、
  # 容易误导人的话。所以先检测这个状态，命中就跳过上传循环和 manifest 更新，只对
  # 每个架构的资产做一次轻量 GitHub digest 核验（不完全信任本地 manifest），再继续
  # 走 commit/push/prune。
  local already_applied=1 i asset_name
  for ((i = 0; i < ${#row_module[@]}; i++)); do
    asset_name="$(basename "${row_path[$i]}")"
    if ! publish_manifest_row_matches_target "${row_module[$i]}" "${row_arch[$i]}" \
        "${row_version[$i]}" "$asset_name" "${row_sha[$i]}" "${row_srcsha[$i]}"; then
      already_applied=0
      break
    fi
  done

  if [ "$already_applied" -eq 1 ]; then
    log "[$module] manifest 已处于本次事务目标状态，判定为「mv 之后、commit 之前中断」的恢复；跳过重新上传与 manifest 更新"
    for ((i = 0; i < ${#row_module[@]}; i++)); do
      asset_name="$(basename "${row_path[$i]}")"
      inspect_release_asset "$asset_name" "${row_size[$i]}" "${row_sha[$i]}" \
        || die "[$module/${row_arch[$i]}] 无法读取产物桶资产元数据，拒绝确认恢复状态"
      [ "$RELEASE_ASSET_STATE" = "identical" ] || \
        die "[$module/${row_arch[$i]}] manifest 已指向本次目标版本，但产物桶资产状态是 ${RELEASE_ASSET_STATE}（期望 identical），拒绝在未确认远端资产完整前继续；请人工核实后再重试，不要直接删除任何资产"
    done
  else
    local updates
    updates="$txn_dir/manifest-updates.tsv"
    : >"$updates"
    for ((i = 0; i < ${#row_module[@]}; i++)); do
      asset_name="$(basename "${row_path[$i]}")"
      publish_claim_or_upload_arch_asset "${row_module[$i]}" "${row_arch[$i]}" "${row_version[$i]}" \
        "${row_path[$i]}" "$asset_name" "${row_size[$i]}" "${row_sha[$i]}" "${row_srcsha[$i]}" "$txn_dir"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${row_module[$i]}" "${row_arch[$i]}" "${row_version[$i]}" "$asset_name" "${row_sha[$i]}" "${row_srcsha[$i]}" \
        >>"$updates"
    done

    # 全部目标资产已确认存在（本次真实上传或恢复认领）且 digest 正确后，才精确更新
    # 全部 (module, arch) 行；publish_apply_arch_matrix_manifest_update 内部会再校验一遍
    # 同模块 version/source_sha 一致。
    publish_apply_arch_matrix_manifest_update "$updates"
  fi

  regen_readme
  if git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv README.md; then
    # 没有未提交变更：说明这次的 commit 已经做过了（例如上一次恰好死在 commit 成功、
    # push 失败之间）。不能再 commit 一次——那样会产生第二个提交，破坏"一次事务一个
    # commit"。正常情况下走不到这一分支，因为这种状态应该在更早的
    # publish_resume_pending_push 那一关就被拦下、直接补 push 了；这里只是防御。
    log "[$module] manifest/README 相对 HEAD 已无未提交变更，跳过重复 commit"
  else
    git -C "$RELEASE_DIR" add manifest.tsv README.md
    # 显式 || die：commit 失败（比如 pre-commit hook 拒绝）必须可靠地在这里停下，
    # 不能指望调用方总是处在 set -e 会触发的位置——if/while 条件、命令替换等上下文
    # 里 set -e 对普通命令失效，但 die() 的 exit 不受这个影响。
    git -C "$RELEASE_DIR" commit -m "publish: $module@$version" \
      || die "[$module] git commit 失败（manifest/README 已经 mv 到本次目标版本但未提交）；修复问题后重新执行发布会识别出这个状态并补完提交，不会重新上传"
  fi
  git -C "$RELEASE_DIR" push origin main \
    || die "[$module] push origin main 失败（本地已提交本次发布但尚未推送）；请检查网络/权限后重试，重新执行发布会识别出这个状态并只补推同一个提交，不会重建矩阵"
  # main/manifest 成为权威后再清理；push 失败上面已经 die，绝不会滑到这里提前删除旧资产。
  prune_modules_to_manifest 1 "$module"

  rm -rf -- "$txn_dir"
  log "[$module] 架构矩阵发布完成: ${version}（$(tr '\n' ' ' <<<"$got_arches")）"
}

# ---- manifest v2 迁移（一次性：八列旧格式 → 九列，第九列 arch）----
publish_migrate_manifest_v2() { # publish_migrate_manifest_v2 <输出路径>；读 $MANIFEST（严格八列旧格式）
  # 按 artifact 文件名后缀推导第九列 arch，写九列 v2 内容到 <输出路径>。只接受八列输入，
  # 输入已经是九列或列数异常一律拒绝；未知 artifact 后缀 fail closed；未发布行
  # （version/artifact/sha256 均为 "-"）本应由模块目标架构声明生成第九列，但当前迁移规则
  # 未实现该场景（迁移时 manifest 里也确实没有这类行）——明确报错，不留死代码路径去猜。
  # 注释与空行原样透传，只给数据行追加第九列，保证 git diff 只新增一列。
  local out="$1"
  [ -n "$out" ] || die "publish_migrate_manifest_v2 需要输出路径参数"
  if ! awk -F'\t' -v OFS='\t' '
      /^[[:space:]]*(#|$)/ { print; next }
      {
        if (NF != 8) {
          printf "manifest 第 %d 行必须恰好八列（迁移前的 v1 旧格式；实际 %d 列）: %s\n", \
            FNR, NF, $0 > "/dev/stderr"
          exit 1
        }
        module = $1; artifact = $6
        if (artifact == "-") {
          printf "manifest 第 %d 行是未发布行（version/artifact/sha256=\"-\"），需要按模块 %s 的目标架构声明生成第九列，当前迁移规则未实现该场景，拒绝猜测: %s\n", \
            FNR, module, $0 > "/dev/stderr"
          exit 1
        }
        if (artifact ~ /-aarch64\.tar\.gz$/) { arch = "aarch64" }
        else if (artifact ~ /-x86_64\.tar\.gz$/) { arch = "x86_64" }
        else if (artifact ~ /-noarch\.tar\.gz$/) { arch = "noarch" }
        else {
          printf "manifest 第 %d 行 artifact 文件名没有受支持的架构后缀（只认 -aarch64/-x86_64/-noarch.tar.gz）: %s\n", \
            FNR, artifact > "/dev/stderr"
          exit 1
        }
        print $0, arch
      }
    ' "$MANIFEST" >"$out"; then
    rm -f -- "$out"
    return 1
  fi
}

# ---- README 版本表 ----
regen_readme() {
  local tbl="$SCRATCH/.version-table.md"
  mkdir -p "$SCRATCH"
  {
    echo "更新于 $(date '+%Y-%m-%d %H:%M')（此表由 publish.sh 生成，权威数据在 manifest.tsv）"
    echo
    echo "| 模块 | 类别 | 装在 | 版本 | 产物 | 架构 |"
    echo "| --- | --- | --- | --- | --- | --- |"
    manifest_all_rows | awk -F'\t' '{ printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, ($3=="stack" ? "全家桶机" : "DB 主机"), $5, $6, $9 }'
  } >"$tbl"
  awk -v tbl="$tbl" '
    /<!-- VERSION-TABLE:BEGIN -->/ { print; while ((getline l < tbl) > 0) print l; skip=1; next }
    /<!-- VERSION-TABLE:END -->/ { skip=0 }
    !skip { print }' "$RELEASE_DIR/README.md" >"$RELEASE_DIR/README.md.tmp" \
    && mv "$RELEASE_DIR/README.md.tmp" "$RELEASE_DIR/README.md"
  log "README 版本表已更新"
}

# ---- 子命令 ----
cmd_plan() {
  refresh_first_party_origins
  printf '%-14s %-24s %-24s %s\n' "模块" "manifest 记录" "当前源码" "状态"
  printf '%s\n' "--------------------------------------------------------------------------"
  local stale=0
  while IFS=$'\t' read -r m kind _t _s v _a _h recorded _arch; do
    if [ "$kind" = "first-party" ]; then
      if [ -d "$SRC_ROOT/$m/.git" ]; then
        if [ "$m" = "dbdog-agent" ]; then
          if ! source_checkout_matches_origin dbdog-agent \
              || ! source_checkout_matches_origin dbdog-agent-core; then
            local_sha="?"
            st="本地未同步 origin/main ←"
            stale=1
          else
            load_agent_release_baseline
            warn_agent_unshipped_heads
            local_sha="$(agent_loaded_source_fingerprint)"
            st="一致"; [ "$local_sha" != "$recorded" ] && st="有变更 ←"
            agent_version_uses_loaded_baseline "$v" || st="官方版本基线变化 ←"
          fi
        else
          if source_checkout_matches_origin "$m"; then
            local_sha="$(live_sha "$m")"
            st="一致"; [ "$local_sha" != "$recorded" ] && st="有变更 ←"
          else
            local_sha="$(git -C "$SRC_ROOT/$m" rev-parse --short=7 origin/main)"
            st="远端有更新；本地未同步 ←"
            stale=1
          fi
        fi
        printf '%-14s %-24s %-24s %s\n' "$m(v$v)" "$recorded" "$local_sha" "$st"
      else
        printf '%-14s %-24s %-24s %s\n' "$m(v$v)" "$recorded" "?" "源仓缺失"
      fi
    else
      printf '%-14s %-24s %-24s %s\n' "$m(v$v)" "-" "-" "三方件（点名发布）"
    fi
  done < <(manifest_rows)
  echo
  echo "发布: publish.sh publish [模块...] [--bump patch|minor|major]"
  [ "$stale" -eq 0 ] \
    || die "存在未同步的自研源仓；plan 已显示真实 origin/main，先 fast-forward 后重试"
}

assert_manifest_is_origin_main() {
  local local_head remote_head attempt=1
  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv \
    || die "manifest.tsv 有未提交变更，拒绝删除产物"
  local_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  while ! remote_head="$(gh api "repos/$REPO/git/ref/heads/main" --jq '.object.sha')"; do
    [ "$attempt" -lt 3 ] \
      || die "dbdog-release 连续 3 次无法通过 GitHub API 读取 main，拒绝删除产物"
    warn "dbdog-release 通过 GitHub API 读取 main 瞬时失败，2 秒后重试（$attempt/3）"
    sleep 2
    attempt=$((attempt + 1))
  done
  [ -n "$remote_head" ] && [ "$remote_head" = "$local_head" ] \
    || die "origin/main 已变化或不可确认，拒绝按本地 manifest 删除产物"
}

prune_modules_to_manifest() { # <execute:0|1> [模块...]；先完整校验，再删非当前资产
  local execute="$1"; shift
  local asset_rows assets protected m arch current expected remote_digest f asset_id
  local modules=("$@") victims="" current_assets=""

  if [ ${#modules[@]} -eq 0 ]; then
    while IFS= read -r m; do modules+=("$m"); done < <(manifest_modules)
  fi

  [ "$execute" -eq 1 ] && assert_manifest_is_origin_main

  asset_rows="$(gh api "repos/$REPO/releases/tags/$BUCKET_TAG" \
    --jq '.assets[] | [.id, .name, (.digest // "")] | @tsv')" \
    || die "读取产物桶失败"
  assets="$(printf '%s\n' "$asset_rows" | cut -f2)"
  # manifest_all_rows 是严格的九列合同，逐 (module, arch) 行输出；一个模块可能有
  # 多个架构行，每一行的 artifact 都要保护，不能只看某一个架构。
  protected="$(manifest_all_rows | cut -f6)"

  # 删除任何文件前，先保证该模块登记的每个架构自己的当前资产都归属、存在且内容正确
  # （不能只查 host_arch 选中的那一行——否则另一个架构的资产永远不会被校验）。
  for m in "${modules[@]}"; do
    while IFS= read -r arch; do
      [ -n "$arch" ] || continue
      current="$(manifest_get "$m" 6 "$arch")"
      # 未发布模块（register-module 登记的声明行，artifact="-"）没有任何资产可以
      # 保护也没有任何资产可以清理；不能因为它不匹配 "<module>-[0-9]*" 就整体
      # die——否则任何一个已登记未发布的模块存在，都会让 prune 永久报废，直到
      # 该模块真正发布为止。
      [ "$current" != "-" ] || continue
      case "$current" in
        "$m"-[0-9]*) ;;
        *) die "[$m/$arch] manifest 当前资产名不属于该模块，拒绝清理: $current" ;;
      esac
      printf '%s\n' "$assets" | grep -Fqx -- "$current" \
        || die "[$m/$arch] manifest 当前资产不在产物桶，拒绝清理: $current"
      expected="$(manifest_get "$m" 7 "$arch")"
      remote_digest="$(printf '%s\n' "$asset_rows" | awk -F'\t' -v a="$current" \
        '$2==a { sub(/^sha256:/, "", $3); print $3; exit }')"
      [ -n "$remote_digest" ] && [ "$remote_digest" = "$expected" ] \
        || die "[$m/$arch] 产物桶 SHA-256 与 manifest 不一致，拒绝清理: $current"
      current_assets="${current_assets}${current_assets:+$'\n'}$current"
    done < <(publish_arches_for_module "$m")
  done

  for m in "${modules[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        "$m"-[0-9]*)
          printf '%s\n' "$current_assets" | grep -Fqx -- "$f" && continue
          # 即使未来模块名前缀发生重叠，也绝不删除任一 manifest 当前引用（任意架构）。
          printf '%s\n' "$protected" | grep -Fqx -- "$f" && continue
          if [ -n "$victims" ] && printf '%s\n' "$victims" | grep -Fqx -- "$f"; then
            continue
          fi
          victims="${victims}${victims:+$'\n'}$f"
          ;;
      esac
    done < <(printf '%s\n' "$assets")
  done

  [ -n "$victims" ] || { log "无可清理产物（每模块仅保留 manifest 当前引用）"; return 0; }
  echo "将删除（manifest 未引用）:"
  while IFS= read -r f; do echo "  $f"; done <<<"$victims"
  if [ "$execute" -eq 1 ]; then
    while IFS= read -r f; do
      # 缩小并发发布窗口；检测到 main 漂移时宁可留下旧文件。
      assert_manifest_is_origin_main
      asset_id="$(printf '%s\n' "$asset_rows" | awk -F'\t' -v a="$f" '$2==a {print $1; exit}')"
      [ -n "$asset_id" ] || die "找不到旧产物的 asset ID，拒绝删除: $f"
      gh api --method DELETE "repos/$REPO/releases/assets/$asset_id" \
        || die "删除旧产物失败: $f"
    done <<<"$victims"
    log "清理完成"
  else
    log "试运行结束（加 --yes 执行删除）"
  fi
}

cmd_publish() {
  local bump="patch" yes=0 mods=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --bump) bump="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) mods+=("$1"); shift ;;
    esac
  done
  case "$bump" in patch | minor | major) ;; *) die "未知 bump 级别: $bump" ;; esac
  if [ ${#mods[@]} -eq 0 ]; then
    local changed
    refresh_first_party_origins
    assert_first_party_checkouts_current
    changed="$(changed_first_party)" \
      || die "检测一方模块发布状态失败"
    while IFS= read -r m; do
      [ -n "$m" ] && mods+=("$m")
    done <<<"$changed"
    if [ ${#mods[@]} -eq 0 ]; then
      # 裸跑（不点名任何模块）也可能撞上"commit 成功、push 失败"的中断窗口：那次
      # commit 已经把 manifest 的 source_sha 更新成当前源码值，changed_first_party
      # 从此再也看不出"变更"，若这里直接 exit 0，待推送的发布提交会被永久静默
      # 丢在本地，origin/main 悄悄落后而没有任何报错——这正是终审 Important 1
      # 指出的场景。在判定"无变更"之前，先看 HEAD 是不是这样一个还没推的
      # "publish: <module>@<version>" 提交，命中就直接交给
      # publish_resume_pending_push 补推（它自己会用本地缓存的 origin/main 校验
      # "HEAD 真的领先"，稳态下不会误命中，见 test-publish-architecture-
      # transaction.sh CASE9/CASE12）。
      local pending_head_msg pending_module=""
      pending_head_msg="$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD 2>/dev/null)" || pending_head_msg=""
      case "$pending_head_msg" in
        "publish: "*"@"*)
          pending_module="${pending_head_msg#publish: }"
          pending_module="${pending_module%%@*}"
          ;;
      esac
      if [ -n "$pending_module" ] && publish_resume_pending_push "$pending_module"; then
        log "发布完成: ${pending_module}@${RESUMED_PUBLISH_VERSION}"
        exit 0
      fi
      log "没有变更的一方模块（三方件需点名发布）"
      exit 0
    fi
  fi

  echo "发布计划（bump=${bump}）:"
  local plan_vers=()
  for m in "${mods[@]}"; do
    local kind cur nv
    kind="$(manifest_module_field "$m" 2)"; cur="$(manifest_module_field "$m" 5)"
    if [ "$kind" = "first-party" ]; then
      if [ "$m" = "dbdog-agent" ]; then
        load_agent_release_baseline
        warn_agent_unshipped_heads
      fi
      nv="$(bump_version "$m" "$cur" "$bump")"
    else
      nv="(配方探测)"
    fi
    plan_vers+=("$nv")
    printf '  %-14s %s → %s\n' "$m" "$cur" "$nv"
  done
  if [ "$yes" -ne 1 ]; then
    read -r -p "确认发布？[y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { log "已取消"; exit 0; }
  fi

  # 正式模块发布串行执行：每个模块自己的架构矩阵是一个完整事务
  # （build 全部架构 → verify → upload 全部架构（含恢复）→ 一次 manifest 更新 →
  # regen_readme → commit → push → prune）；一个模块完成/失败不影响下一个模块。
  local i=0 summary=""
  for m in "${mods[@]}"; do
    # 先看这是不是"上一次已经 commit 成功、只是 push 失败"的中断恢复：这种状态下
    # release HEAD 已经因为那次 commit 前进了，事务目录按新 HEAD 是找不到的，必须
    # 在触碰 build_one_arch/版本规划之前单独识别，直接补 push，不重建矩阵。
    if publish_resume_pending_push "$m"; then
      summary="$summary $m@$RESUMED_PUBLISH_VERSION"
      i=$((i + 1))
      continue
    fi

    local kind ver="" arch txn_dir="" actual_ver
    kind="$(manifest_module_field "$m" 2)"
    if [ "$kind" = "first-party" ]; then
      if [ "$m" = "dbdog-agent" ]; then ensure_pushed dbdog-agent dbdog-agent-core; else ensure_pushed "$m"; fi
      ver="${plan_vers[$i]}"
    fi
    publish_ensure_arch_builders "$m"
    while IFS= read -r arch; do
      [ -n "$arch" ] || continue
      build_one_arch "$m" "$ver" "$arch"
    done < <(publish_arches_for_module "$m")
    txn_dir="$(publish_txn_dir "$m" "$ver")"
    # 三方件的真实版本由配方探测，只有构建完成后才知道；从事务记录里取，
    # 不依赖上面可能仍是空串的 $ver（publish_commit_arch_matrix 会把事务目录删掉，
    # 所以要在调用它之前读出来）。
    actual_ver="$(awk -F'\t' 'NR==1 { print $3; exit }' "$txn_dir/txn.tsv")"
    publish_commit_arch_matrix "$txn_dir/txn.tsv"
    summary="$summary $m@$actual_ver"
    i=$((i + 1))
  done

  log "发布完成:$summary"
}

cmd_prune() {
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) die "prune 不认识参数: $1" ;;
    esac
  done
  prune_modules_to_manifest "$yes"
}

cmd_migrate_manifest_v2() { # 一次性迁移：manifest.tsv 八列旧格式 → 九列（含 arch），再重建 README
  local write=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --write) write=1; shift ;;
      *) die "migrate-manifest-v2 不认识参数: $1" ;;
    esac
  done
  [ "$write" -eq 1 ] || die "migrate-manifest-v2 是一次性迁移，只支持 --write（没有试运行模式）"

  local tmp
  tmp="$(mktemp "$MANIFEST.migrate.XXXXXX")" || die "无法创建迁移临时文件"
  if ! publish_migrate_manifest_v2 "$tmp"; then
    rm -f -- "$tmp"
    die "manifest v2 迁移失败（源 manifest 必须严格八列，且 artifact 后缀必须是 -aarch64/-x86_64/-noarch.tar.gz 之一）"
  fi
  if ! MANIFEST="$tmp" manifest_all_rows >/dev/null; then
    rm -f -- "$tmp"
    die "迁移结果未通过 manifest_all_rows 严格校验，拒绝替换 manifest"
  fi

  mv -- "$tmp" "$MANIFEST"
  regen_readme
  log "manifest 已迁移到 v2（九列，含 arch），README 版本表已重建"
}

# ---- 新模块首发登记：manifest 里完全没有该模块任何行时，唯一合法登记路径 ----
# 原子写入未发布声明行（每个目标架构一行，version/artifact/sha256/source_sha 全部
# 写 "-"）。发布事务（build_one_arch/publish_arches_for_module/
# publish_apply_arch_matrix_manifest_update）不需要为"首发"另开分支：
# publish_arches_for_module 本来就是读 manifest 里该模块出现过的架构，声明行天然
# 提供这个矩阵；真正发布时 publish_apply_arch_matrix_manifest_update 按既有的
# "(module,arch) 键匹配就更新" 语义，把声明行原地替换成真实行——不需要新增"插入
# 新行"的能力，也就不需要放松那个函数对未匹配键的 fail-closed 保护。
cmd_register_module() { # register-module <module> <first-party|third-party> <stack|dbhost> <yes|no> --arch <架构> [--arch <架构>]...
  local m="" kind="" target="" service=""
  local -a arches=()
  if [ $# -ge 4 ]; then
    m="$1"; kind="$2"; target="$3"; service="$4"; shift 4
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --arch)
        [ $# -ge 2 ] || die "register-module: --arch 需要参数"
        arches+=("$2"); shift 2
        ;;
      *) die "register-module 不认识的参数: $1" ;;
    esac
  done
  [ -n "$m" ] && [ -n "$kind" ] && [ -n "$target" ] && [ -n "$service" ] \
    || die "用法: register-module <module> <first-party|third-party> <stack|dbhost> <yes|no> --arch <架构> [--arch <架构>]..."
  case "$m" in
    "" | "." | ".." | */* | *$'\n'* | *$'\r'* | *$'\t'*)
      die "register-module 模块名不是安全的单层路径名: $m"
      ;;
  esac
  case "$kind" in
    first-party | third-party) ;;
    *) die "register-module 的 kind 只能是 first-party|third-party，收到: $kind" ;;
  esac
  case "$target" in
    stack | dbhost) ;;
    *) die "register-module 的 target 只能是 stack|dbhost，收到: $target" ;;
  esac
  case "$service" in
    yes | no) ;;
    *) die "register-module 的 service 只能是 yes|no，收到: $service" ;;
  esac
  [ ${#arches[@]} -gt 0 ] || die "register-module 至少需要一个 --arch"

  local -a normalized=()
  local raw na seen dup
  for raw in "${arches[@]}"; do
    na="$(normalize_arch "$raw")" || die "register-module 不支持的架构: $raw"
    dup=0
    for seen in ${normalized[@]+"${normalized[@]}"}; do
      [ "$seen" != "$na" ] || { dup=1; break; }
    done
    [ "$dup" -eq 0 ] || die "register-module 重复的 --arch: $na"
    normalized+=("$na")
  done

  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv README.md \
    || die "manifest.tsv/README.md 有未提交的改动，拒绝在脏工作区上登记新模块"
  manifest_all_rows >/dev/null \
    || die "现有 manifest.tsv 未通过 manifest_all_rows 严格校验，拒绝在此基础上登记新模块"
  if manifest_all_rows | awk -F'\t' -v m="$m" '$1==m{f=1} END{exit(f?0:1)}'; then
    die "模块 $m 已经在 manifest 里登记过，拒绝重复登记（如需变更用发布流程更新已有行，不要手改 manifest）"
  fi

  # 固定按 aarch64/x86_64/noarch 输出声明行，和 manifest_arches 的既有顺序约定一致，
  # 不依赖调用方传 --arch 的顺序。
  local ordered="" order_arch cand
  for order_arch in aarch64 x86_64 noarch; do
    for cand in "${normalized[@]}"; do
      [ "$cand" != "$order_arch" ] || ordered="$ordered${ordered:+ }$order_arch"
    done
  done

  local tmp
  tmp="$(mktemp "$MANIFEST.register.XXXXXX")" || die "无法创建 manifest 临时文件"
  if ! cp -- "$MANIFEST" "$tmp"; then
    rm -f -- "$tmp"
    die "无法复制 manifest 到临时文件"
  fi
  for na in $ordered; do
    printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\t%s\n' "$m" "$kind" "$target" "$service" "$na" >>"$tmp"
  done
  if ! MANIFEST="$tmp" manifest_all_rows >/dev/null; then
    rm -f -- "$tmp"
    die "register-module 写入的声明行未通过 manifest_all_rows 校验，拒绝落地"
  fi
  mv -- "$tmp" "$MANIFEST"

  regen_readme
  git -C "$RELEASE_DIR" add manifest.tsv README.md
  git -C "$RELEASE_DIR" commit -m "register: ${m} (${ordered// /,}) unpublished" \
    || die "register-module git commit 失败（manifest/README 已写入声明行但未提交）；确认工作区改动后手动 git add/commit，或 git checkout -- manifest.tsv README.md 撤销后重跑"
  publish_maybe_push_main \
    "register-module push 失败（本地已提交声明行）；请检查网络/权限后手动 git push origin main（重新执行 register-module 会因模块已登记而拒绝）"
  log "已登记新模块 ${m}（${ordered}，未发布，version=-）"
}

cmd_register_arch() { # register-arch <module> --arch <架构> [--arch <架构>]...
  # 给已存在模块追加未发布架构声明行；kind/target/service 从现有行复制。
  local m=""
  local -a arches=()
  if [ $# -ge 1 ]; then
    m="$1"; shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --arch)
        [ $# -ge 2 ] || die "register-arch: --arch 需要参数"
        arches+=("$2"); shift 2
        ;;
      *) die "register-arch 不认识的参数: $1" ;;
    esac
  done
  [ -n "$m" ] || die "用法: register-arch <module> --arch <架构> [--arch <架构>]..."
  case "$m" in
    "" | "." | ".." | */* | *$'\n'* | *$'\r'* | *$'\t'*)
      die "register-arch 模块名不是安全的单层路径名: $m"
      ;;
  esac
  [ ${#arches[@]} -gt 0 ] || die "register-arch 至少需要一个 --arch"

  local -a normalized=()
  local raw na seen dup
  for raw in "${arches[@]}"; do
    na="$(normalize_arch "$raw")" || die "register-arch 不支持的架构: $raw"
    dup=0
    for seen in ${normalized[@]+"${normalized[@]}"}; do
      [ "$seen" != "$na" ] || { dup=1; break; }
    done
    [ "$dup" -eq 0 ] || die "register-arch 重复的 --arch: $na"
    normalized+=("$na")
  done

  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv README.md \
    || die "manifest.tsv/README.md 有未提交的改动，拒绝在脏工作区上登记架构"
  manifest_all_rows >/dev/null \
    || die "现有 manifest.tsv 未通过 manifest_all_rows 严格校验，拒绝在此基础上登记架构"
  if ! manifest_all_rows | awk -F'\t' -v m="$m" '$1==m{f=1} END{exit(f?0:1)}'; then
    die "模块 $m 尚未在 manifest 里登记；新模块请用 register-module"
  fi

  local existing_arches kind target service
  existing_arches="$(manifest_arches "$m")"
  kind="$(manifest_module_field "$m" 2)"
  target="$(manifest_module_field "$m" 3)"
  service="$(manifest_module_field "$m" 4)"

  local -a to_add=()
  for na in "${normalized[@]}"; do
    if printf '%s\n' "$existing_arches" | grep -Fxq -- "$na"; then
      die "模块 $m 已经登记过架构 $na，拒绝重复登记"
    fi
    to_add+=("$na")
  done

  local ordered="" order_arch cand
  for order_arch in aarch64 x86_64 noarch; do
    for cand in "${to_add[@]}"; do
      [ "$cand" != "$order_arch" ] || ordered="$ordered${ordered:+ }$order_arch"
    done
  done

  local tmp
  tmp="$(mktemp "$MANIFEST.register.XXXXXX")" || die "无法创建 manifest 临时文件"
  if ! cp -- "$MANIFEST" "$tmp"; then
    rm -f -- "$tmp"
    die "无法复制 manifest 到临时文件"
  fi
  for na in $ordered; do
    printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\t%s\n' "$m" "$kind" "$target" "$service" "$na" >>"$tmp"
  done
  if ! MANIFEST="$tmp" manifest_all_rows >/dev/null; then
    rm -f -- "$tmp"
    die "register-arch 写入的声明行未通过 manifest_all_rows 校验，拒绝落地"
  fi
  mv -- "$tmp" "$MANIFEST"

  regen_readme
  git -C "$RELEASE_DIR" add manifest.tsv README.md
  git -C "$RELEASE_DIR" commit -m "register-arch: ${m} (+${ordered// /,}) unpublished" \
    || die "register-arch git commit 失败（manifest/README 已写入声明行但未提交）；确认工作区改动后手动 git add/commit，或 git checkout -- manifest.tsv README.md 撤销后重跑"
  publish_maybe_push_main \
    "register-arch push 失败（本地已提交声明行）；请检查网络/权限后手动 git push origin main"
  log "已为模块 ${m} 登记架构 ${ordered}（未发布，version=-）"
}

main() {
  case "${1:-plan}" in
    plan) cmd_plan ;;
    publish) shift; cmd_publish "$@" ;;
    regen-readme) regen_readme ;;
    prune) shift; cmd_prune "$@" ;;
    migrate-manifest-v2) shift; cmd_migrate_manifest_v2 "$@" ;;
    register-module) shift; cmd_register_module "$@" ;;
    register-arch) shift; cmd_register_arch "$@" ;;
    *) die "用法: publish.sh plan|publish|regen-readme|prune|migrate-manifest-v2|register-module|register-arch" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
