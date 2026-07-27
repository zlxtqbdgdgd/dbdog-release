#!/usr/bin/env bash
# 公网发布主脚本（在开发机上执行）。
#   publish.sh plan                      # 只看哪些模块有变更
#   publish.sh publish [模块...] [--bump patch|minor|major] [--yes]
#                                        # 默认发布所有有变更的一方模块；三方件需点名
#   publish.sh regen-readme              # 按 manifest 重新生成 README 版本表
#   publish.sh prune [--yes]             # 只保留 manifest 当前引用（默认试运行）
#
# 依赖：ssh 可达构建机、gh 已登录（gh auth status）、各源仓与本仓是同级目录。

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
AGENT_BASE_VERSION="${AGENT_BASE_VERSION:-7.81.1}"

# ---- 变更检测 ----
live_sha() { # 当前源码指纹（与 manifest.source_sha 同格式）
  case "$1" in
    dbdog-agent)
      echo "agent:$(git -C "$SRC_ROOT/dbdog-agent" rev-parse --short=7 HEAD),core:$(git -C "$SRC_ROOT/dbdog-agent-core" rev-parse --short=7 HEAD)" ;;
    *) git -C "$SRC_ROOT/$1" rev-parse --short=7 HEAD ;;
  esac
}

changed_first_party() {
  while IFS=$'\t' read -r m kind _t _s _v _a _h recorded; do
    [ "$kind" = "first-party" ] || continue
    [ -d "$SRC_ROOT/$m/.git" ] || { warn "源仓不存在: $SRC_ROOT/${m}，跳过 $m"; continue; }
    [ "$(live_sha "$m")" != "$recorded" ] && echo "$m"
  done < <(manifest_rows)
}

ensure_pushed() { # 构建机从 origin 取码，未推送的提交构建不到
  local repo
  for repo in "$@"; do
    git -C "$SRC_ROOT/$repo" fetch -q origin \
      || warn "$repo fetch origin 失败，用本地已有的 origin/main 引用判断"
    git -C "$SRC_ROOT/$repo" merge-base --is-ancestor HEAD origin/main \
      || die "$repo 本地 HEAD 尚未推送到 origin/main，先 push 再发布"
  done
}

# ---- 版本号 ----
bump_version() { # bump_version <模块> <当前版本> <patch|minor|major>
  local m="$1" cur="$2" level="${3:-patch}"
  if [ "$m" = "dbdog-agent" ]; then
    if [[ "$cur" == "$AGENT_BASE_VERSION-dbdog."* ]]; then
      echo "$AGENT_BASE_VERSION-dbdog.$(( ${cur##*.} + 1 ))"
    else
      echo "$AGENT_BASE_VERSION-dbdog.1"
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

update_manifest_row() { # <module> <version> <artifact> <sha256> <source_sha>
  awk -F'\t' -v OFS='\t' -v m="$1" -v v="$2" -v a="$3" -v h="$4" -v s="$5" \
    '!/^#/ && $1==m { $5=v; $6=a; $7=h; $8=s } { print }' \
    "$MANIFEST" >"$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
}

build_one() { # <module> <version(三方件传空)> → 设置 BUILT_VERSION/BUILT_ARTIFACT/BUILT_SHA256
  local m="$1" ver="$2" recipe="$HERE/recipes/$m.sh" sha="" core=""
  [ -f "$recipe" ] || die "缺少构建配方: $recipe"
  [ -n "${BUILD_HOST:-}" ] && [ "$BUILD_HOST" != "z1@CHANGE-ME" ] \
    || die "publish.conf 未配置 BUILD_HOST（cp publish.conf.example publish.conf）"
  if [ "$(manifest_get "$m" 2)" = "first-party" ]; then
    sha="$(git -C "$SRC_ROOT/$m" rev-parse HEAD)"
    [ "$m" = "dbdog-agent" ] && core="$(git -C "$SRC_ROOT/dbdog-agent-core" rev-parse HEAD)"
  fi

  log "[$m] 构建于 $BUILD_HOST ..."
  local out
  out="$(ssh "$BUILD_HOST" MODULE="$m" VERSION="$ver" SHA="$sha" CORE_SHA="$core" \
        ARCH="$ARCH" REPO_ROOT="$REPO_ROOT" BUILD_WORK="$BUILD_WORK" TOOL_PATH="$TOOL_PATH" \
        PG_PREFIX="${PG_PREFIX:-}" CH_BIN="${CH_BIN:-}" bash -s <"$recipe" | tail -n1)"
  BUILT_VERSION="${out%%$'\t'*}"
  local rpath="${out#*$'\t'}"
  [ -n "$BUILT_VERSION" ] && [ "$rpath" != "$out" ] || die "[$m] 配方输出不合约定（应为 版本<TAB>产物路径）: $out"

  mkdir -p "$SCRATCH"
  BUILT_ARTIFACT="$(basename "$rpath")"
  log "[$m] 取回产物 $BUILT_ARTIFACT"
  scp -q "$BUILD_HOST:$rpath" "$SCRATCH/$BUILT_ARTIFACT"
  BUILT_SHA256="$(shasum -a 256 "$SCRATCH/$BUILT_ARTIFACT" | awk '{print $1}')"

  ensure_bucket
  log "[$m] 上传产物桶"
  gh release upload "$BUCKET_TAG" "$SCRATCH/$BUILT_ARTIFACT" --clobber -R "$REPO"

  local srcsha="-"
  [ "$(manifest_get "$m" 2)" = "first-party" ] && srcsha="$(live_sha "$m")"
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
  printf '%-14s %-24s %-24s %s\n' "模块" "manifest 记录" "当前源码" "状态"
  printf '%s\n' "--------------------------------------------------------------------------"
  while IFS=$'\t' read -r m kind _t _s v _a _h recorded; do
    if [ "$kind" = "first-party" ]; then
      if [ -d "$SRC_ROOT/$m/.git" ]; then
        local_sha="$(live_sha "$m")"
        st="一致"; [ "$local_sha" != "$recorded" ] && st="有变更 ←"
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
}

assert_manifest_is_origin_main() {
  local local_head remote_head
  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv \
    || die "manifest.tsv 有未提交变更，拒绝删除产物"
  local_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  remote_head="$(git -C "$RELEASE_DIR" ls-remote origin refs/heads/main | awk 'NR==1 {print $1}')" \
    || die "读取 origin/main 失败，拒绝删除产物"
  [ -n "$remote_head" ] && [ "$remote_head" = "$local_head" ] \
    || die "origin/main 已变化或不可确认，拒绝按本地 manifest 删除产物"
}

prune_modules_to_manifest() { # <execute:0|1> [模块...]；先完整校验，再删非当前资产
  local execute="$1"; shift
  local asset_rows assets protected m current expected remote_digest f
  local modules=("$@") victims=""

  if [ ${#modules[@]} -eq 0 ]; then
    while IFS= read -r m; do modules+=("$m"); done < <(manifest_modules)
  fi

  [ "$execute" -eq 1 ] && assert_manifest_is_origin_main

  asset_rows="$(gh release view "$BUCKET_TAG" -R "$REPO" --json assets \
    --jq '.assets[] | [.name, (.digest // "")] | @tsv')" \
    || die "读取产物桶失败"
  assets="$(printf '%s\n' "$asset_rows" | cut -f1)"
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
      '$1==a { sub(/^sha256:/, "", $2); print $2; exit }')"
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
      gh release delete-asset "$BUCKET_TAG" "$f" -y -R "$REPO" \
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
  if [ ${#mods[@]} -eq 0 ]; then
    while read -r m; do mods+=("$m"); done < <(changed_first_party)
    [ ${#mods[@]} -gt 0 ] || { log "没有变更的一方模块（三方件需点名发布）"; exit 0; }
  fi

  echo "发布计划（bump=${bump}）:"
  local plan_vers=()
  for m in "${mods[@]}"; do
    local kind cur nv
    kind="$(manifest_get "$m" 2)"; cur="$(manifest_get "$m" 5)"
    if [ "$kind" = "first-party" ]; then nv="$(bump_version "$m" "$cur" "$bump")"; else nv="(配方探测)"; fi
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

case "${1:-plan}" in
  plan) cmd_plan ;;
  publish) shift; cmd_publish "$@" ;;
  regen-readme) regen_readme ;;
  prune) shift; cmd_prune "$@" ;;
  *) die "用法: publish.sh plan|publish|regen-readme|prune" ;;
esac
