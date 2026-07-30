#!/usr/bin/env bash
# 公网发布主脚本（在开发机上执行）。
#   publish.sh plan                      # 只看哪些模块有变更
#   publish.sh publish [模块...] [--bump patch|minor|major] [--yes]
#                                        # 默认发布所有有变更的一方模块；三方件需点名
#   publish.sh regen-readme              # 按 manifest 重新生成 README 版本表
#   publish.sh prune [--yes]             # 只保留 manifest 当前引用（默认试运行）
#
# 依赖：ssh 可达构建机、gh 已登录（gh auth status）、各源仓与本仓是同级目录。
# 产物在构建机上完成架构/摘要校验并直传 GitHub；本机不再中转大文件。

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"   # log/die/manifest_* （其内网路径变量在本机不使用）

REPO="zlxtqbdgdgd/dbdog-release"
BUCKET_TAG="artifacts"
SCRATCH="$RELEASE_DIR/scratch"

CONF="$HERE/publish.conf"
[ -f "$CONF" ] && source "$CONF"
SRC_ROOT="${SRC_ROOT:-$(cd "$RELEASE_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-/home/z1/dbdog/repo}"
BUILD_WORK="${BUILD_WORK:-/home/z1/dbdog-release-build}"
TOOL_PATH="${TOOL_PATH:-}"

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
        allowed["dbdog_revision_reset_on_official_baseline_change"] = 1
        allowed["release_build_must_use_explicit_source_commits"] = 1
        allowed["release_json_current_milestone_is_prefix_authority"] = 1
        expected = 20
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
  while IFS=$'\t' read -r m kind _t _s _v _a _h _recorded; do
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
  while IFS=$'\t' read -r m kind _t _s _v _a _h _recorded; do
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
  while IFS=$'\t' read -r m kind _t _s _v _a _h recorded; do
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

verify_remote_artifact_arch() { # <远端产物> <aarch64|noarch> <module>
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

update_manifest_row() { # <module> <version> <artifact> <sha256> <source_sha>
  awk -F'\t' -v OFS='\t' -v m="$1" -v v="$2" -v a="$3" -v h="$4" -v s="$5" \
    '!/^#/ && $1==m { $5=v; $6=a; $7=h; $8=s } { print }' \
    "$MANIFEST" >"$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
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

build_one() { # <module> <version(三方件传空)> → 设置 BUILT_VERSION/BUILT_ARTIFACT/BUILT_SHA256
  local m="$1" ver="$2" sha="" core="" kind agent_baseline_blob=""
  local recipe="$HERE/recipes/$m.sh"
  [ -f "$recipe" ] || die "缺少构建配方: $recipe"
  [ -n "${BUILD_HOST:-}" ] && [ "$BUILD_HOST" != "z1@CHANGE-ME" ] \
    || die "publish.conf 未配置 BUILD_HOST（cp publish.conf.example publish.conf）"
  kind="$(manifest_get "$m" 2)"
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

  local build_arch
  build_arch="$(ssh "$BUILD_HOST" uname -m | tail -n1)" \
    || die "[$m] 无法读取构建机架构"
  [ "$build_arch" = "$ARCH" ] \
    || die "[$m] 构建机架构是 $build_arch，不能发布为 $ARCH"

  log "[$m] 构建于 $BUILD_HOST ..."
  local out recipe_stdout
  if ! recipe_stdout="$(ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
        "$BUILD_HOST" MODULE="$m" VERSION="$ver" SHA="$sha" CORE_SHA="$core" \
        ARCH="$ARCH" REPO_ROOT="$REPO_ROOT" BUILD_WORK="$BUILD_WORK" TOOL_PATH="$TOOL_PATH" \
        PG_PREFIX="${PG_PREFIX:-}" CH_BIN="${CH_BIN:-}" bash -s <"$recipe")"; then
    die "[$m] 远端构建配方执行失败"
  fi
  out="$(printf '%s\n' "$recipe_stdout" | tail -n1)"
  BUILT_VERSION="${out%%$'\t'*}"
  local rpath="${out#*$'\t'}"
  [ -n "$BUILT_VERSION" ] && [ "$rpath" != "$out" ] || die "[$m] 配方输出不合约定（应为 版本<TAB>产物路径）: $out"
  if [ "$kind" = "first-party" ] && [ "$BUILT_VERSION" != "$ver" ]; then
    die "[$m] 配方返回版本与发布计划不一致: 计划=$ver，实际=$BUILT_VERSION"
  fi

  mkdir -p "$SCRATCH"
  BUILT_ARTIFACT="$(basename "$rpath")"
  case "$BUILT_ARTIFACT" in
    "$m"-*) ;;
    *) die "[$m] 产物名不属于该模块: $BUILT_ARTIFACT" ;;
  esac
  local expected_rpath
  if [ "$m" = dbdog-agent ]; then
    # Agent 的受封存配方、root finalizer 与 dependency seal 共同钉死这个 build attempt；
    # 它不能搬到通用 BUILD_WORK，否则就绕开 canonical artifact 的路径/owner/mode 门禁。
    expected_rpath="/home/dbdog/work/dbdog-agent-62ad2979-build2/out/$BUILT_ARTIFACT"
  else
    expected_rpath="$BUILD_WORK/$m/out/$BUILT_ARTIFACT"
  fi
  [ "$rpath" = "$expected_rpath" ] || \
    die "[$m] 配方产物不在约定的远端 out 目录: $rpath"
  local artifact_arch
  case "$BUILT_ARTIFACT" in
    *-"$ARCH".tar.gz) artifact_arch="$ARCH" ;;
    *-noarch.tar.gz) artifact_arch="noarch" ;;
    *) die "[$m] 产物名没有受支持的架构后缀: $BUILT_ARTIFACT" ;;
  esac
  remote_artifact_metadata "$rpath"
  verify_remote_artifact_arch "$rpath" "$artifact_arch" "$m"
  BUILT_SHA256="$REMOTE_ARTIFACT_SHA256"

  if [ "$m" = "dbdog-agent" ]; then
    # Agent 构建耗时很长；上传前重读基线，避免等待期间有人换锚，导致版本/manifest
    # 记录与刚构建完成的实际 SHA 不一致。
    load_agent_release_baseline
    [ "$AGENT_RELEASE_SOURCE_COMMIT" = "$sha" ] \
      && [ "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" = "$core" ] \
      && [ "$(git -C "$SRC_ROOT/dbdog-agent" hash-object \
        dbdog-deploy/RELEASE-BASELINE.tsv)" = "$agent_baseline_blob" ] \
      || die "[$m] 构建期间发布基线发生变化，拒绝上传；请按新基线重新构建"
    agent_version_uses_loaded_baseline "$BUILT_VERSION" \
      || die "[$m] 构建版本已不属于当前官方基线，拒绝上传: $BUILT_VERSION"
  fi

  ensure_bucket
  upload_release_asset_from_builder "$m" "$rpath" "$BUILT_ARTIFACT" \
    "$REMOTE_ARTIFACT_SIZE" "$BUILT_SHA256"

  local srcsha="-"
  if [ "$kind" = "first-party" ]; then
    if [ "$m" = "dbdog-agent" ]; then
      srcsha="$(agent_loaded_source_fingerprint)"
    else
      srcsha="$(live_sha "$m")"
    fi
  fi
  update_manifest_row "$m" "$BUILT_VERSION" "$BUILT_ARTIFACT" "$BUILT_SHA256" "$srcsha"
}

# ---- README 版本表 ----
regen_readme() {
  local tbl="$SCRATCH/.version-table.md"
  mkdir -p "$SCRATCH"
  {
    echo "更新于 $(date '+%Y-%m-%d %H:%M')（此表由 publish.sh 生成，权威数据在 manifest.tsv）"
    echo
    echo "| 模块 | 类别 | 装在 | 版本 | 产物 |"
    echo "| --- | --- | --- | --- | --- |"
    manifest_rows | awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $1, $2, ($3=="stack" ? "全家桶机" : "DB 主机"), $5, $6 }'
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
  while IFS=$'\t' read -r m kind _t _s v _a _h recorded; do
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
  while ! remote_head="$(git -C "$RELEASE_DIR" ls-remote origin refs/heads/main \
      | awk 'NR==1 {print $1}')"; do
    [ "$attempt" -lt 3 ] \
      || die "dbdog-release 连续 3 次无法读取 origin/main，拒绝删除产物"
    warn "dbdog-release 读取 origin/main 瞬时失败，2 秒后重试（$attempt/3）"
    sleep 2
    attempt=$((attempt + 1))
  done
  [ -n "$remote_head" ] && [ "$remote_head" = "$local_head" ] \
    || die "origin/main 已变化或不可确认，拒绝按本地 manifest 删除产物"
}

prune_modules_to_manifest() { # <execute:0|1> [模块...]；先完整校验，再删非当前资产
  local execute="$1"; shift
  local asset_rows assets protected m current expected remote_digest f asset_id
  local modules=("$@") victims=""

  if [ ${#modules[@]} -eq 0 ]; then
    while IFS= read -r m; do modules+=("$m"); done < <(manifest_modules)
  fi

  [ "$execute" -eq 1 ] && assert_manifest_is_origin_main

  asset_rows="$(gh api "repos/$REPO/releases/tags/$BUCKET_TAG" \
    --jq '.assets[] | [.id, .name, (.digest // "")] | @tsv')" \
    || die "读取产物桶失败"
  assets="$(printf '%s\n' "$asset_rows" | cut -f2)"
  protected="$(manifest_rows | cut -f6)"

  # 删除任何文件前，先保证当前资产的模块归属、存在性和内容都正确。
  for m in "${modules[@]}"; do
    current="$(manifest_get "$m" 6)"
    case "$current" in
      "$m"-[0-9]*) ;;
      *) die "[$m] manifest 当前资产名不属于该模块，拒绝清理: $current" ;;
    esac
    printf '%s\n' "$assets" | grep -Fqx -- "$current" \
      || die "[$m] manifest 当前资产不在产物桶，拒绝清理: $current"
    expected="$(manifest_get "$m" 7)"
    remote_digest="$(printf '%s\n' "$asset_rows" | awk -F'\t' -v a="$current" \
      '$2==a { sub(/^sha256:/, "", $3); print $3; exit }')"
    [ -n "$remote_digest" ] && [ "$remote_digest" = "$expected" ] \
      || die "[$m] 产物桶 SHA-256 与 manifest 不一致，拒绝清理: $current"
  done

  for m in "${modules[@]}"; do
    current="$(manifest_get "$m" 6)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        "$m"-[0-9]*)
          [ "$f" = "$current" ] && continue
          # 即使未来模块名前缀发生重叠，也绝不删除任一 manifest 当前引用。
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
    [ ${#mods[@]} -gt 0 ] || { log "没有变更的一方模块（三方件需点名发布）"; exit 0; }
  fi

  echo "发布计划（bump=${bump}）:"
  local plan_vers=()
  for m in "${mods[@]}"; do
    local kind cur nv
    kind="$(manifest_get "$m" 2)"; cur="$(manifest_get "$m" 5)"
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

  local i=0 summary=""
  for m in "${mods[@]}"; do
    local kind ver=""
    kind="$(manifest_get "$m" 2)"
    if [ "$kind" = "first-party" ]; then
      if [ "$m" = "dbdog-agent" ]; then ensure_pushed dbdog-agent dbdog-agent-core; else ensure_pushed "$m"; fi
      ver="${plan_vers[$i]}"
    fi
    build_one "$m" "$ver"
    summary="$summary $m@$BUILT_VERSION"
    i=$((i + 1))
  done

  regen_readme
  git -C "$RELEASE_DIR" add manifest.tsv README.md
  git -C "$RELEASE_DIR" commit -m "publish:$summary"
  git -C "$RELEASE_DIR" push origin main
  # main/manifest 成为权威后再清理；push 失败时绝不提前删除旧资产。
  prune_modules_to_manifest 1 "${mods[@]}"
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

main() {
  case "${1:-plan}" in
    plan) cmd_plan ;;
    publish) shift; cmd_publish "$@" ;;
    regen-readme) regen_readme ;;
    prune) shift; cmd_prune "$@" ;;
    *) die "用法: publish.sh plan|publish|regen-readme|prune" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
