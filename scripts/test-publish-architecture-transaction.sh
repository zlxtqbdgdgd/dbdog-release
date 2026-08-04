#!/usr/bin/env bash
# 本机可重复测试：多架构发布事务（build 全部架构 → verify → upload 全部架构（含恢复）
# → 一次 manifest 更新 → regen_readme → commit → push → prune）。
#
# 覆盖两条计划要求的场景：
#   1. 架构矩阵里第二个架构构建失败：manifest.tsv/README.md 字节不变，且不产生
#      git commit/push（事务边界卡在 build_one_arch 阶段，永远不会进入
#      publish_commit_arch_matrix）。
#   2. 上传响应在第一个架构成功、第二个架构失败后"丢失"（进程中断）：第二次执行
#      用事务记录 + GitHub size/digest 认领第一个架构已上传的资产（不重复上传），
#      完成第二个架构后只产生一个发布提交。
#
# 加一组补充断言：兼容别名 BUILD_HOST 只在 uname -m 精确匹配请求架构时才回退。
#
# 所有场景都真实调用 publish.sh 里的 publish_arches_for_module / build_one_arch /
# publish_commit_arch_matrix / resolve_build_host_for_arch，只在网络边界（ssh/gh）
# 打桩，复用 test-publish-upload-contracts.sh 的 fake 手法（按命令形状识别调用，
# 用环境变量控制场景），git/awk 全部走真实命令。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-publish-txn.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-publish-txn.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# ---- 共享 fake gh / ssh --------------------------------------------------
# 两者都按“命令形状”分派（识别参数里的固定子串），而不是按调用序号——这样两次
# 独立执行（模拟进程中断再重启）也能各自被正确识别。所有可变状态落盘在
# FAKE_STATE_DIR 里，天然跨“两次执行”持久化，模拟真实的 GitHub 产物桶和构建机。
mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_STATE_DIR:?}"
: "${FAKE_GH_TOKEN:?}"
: "${FAKE_RELEASE_DIR:?}"

if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then
  exit 0   # 产物桶已存在，跳过 ensure_bucket 的创建分支
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  printf '%s\n' "$FAKE_GH_TOKEN"
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  for a in "$@"; do
    if [ "$a" = ".id" ]; then
      printf '%s\n' 424242
      exit 0
    fi
    if [ "$a" = ".object.sha" ]; then
      git -C "$FAKE_RELEASE_DIR" rev-parse HEAD
      exit 0
    fi
  done
  # 两条真实代码路径查同一份资产清单，但 --jq 投影的列不同，必须分别响应：
  #   inspect_release_asset:            [.name, .size, .digest]  → name, size, sha256:sha
  #   prune_modules_to_manifest 的完整性校验: [.id, .name, .digest] → id, name, sha256:sha
  jq_filter=""
  for a in "$@"; do
    case "$a" in *'.assets[]'*) jq_filter="$a" ;; esac
  done
  case "$jq_filter" in
    *'.size'*) asset_shape=name-size-digest ;;
    *'.id'*) asset_shape=id-name-digest ;;
    *) echo "fake gh: 无法识别资产清单 --jq 投影: $jq_filter" >&2; exit 95 ;;
  esac
  # 清单里的资产名一律读事务当次上传时记下的真实名字（见 ssh 桩里的写入注释），
  # 不用调用清单查询这一刻的 FAKE_ASSET_NAME_*——两者在跨"轮次"复用同一个
  # FAKE_STATE_DIR 的测试场景里可能已经不是同一个版本了。
  if [ -f "$FAKE_STATE_DIR/asset-aarch64" ]; then
    IFS=$'\t' read -r nm sz sh <"$FAKE_STATE_DIR/asset-aarch64"
    if [ "$asset_shape" = name-size-digest ]; then
      printf '%s\t%s\tsha256:%s\n' "$nm" "$sz" "$sh"
    else
      printf '%s\t%s\tsha256:%s\n' 1001 "$nm" "$sh"
    fi
  fi
  if [ -f "$FAKE_STATE_DIR/asset-x86_64" ]; then
    IFS=$'\t' read -r nm sz sh <"$FAKE_STATE_DIR/asset-x86_64"
    if [ "$asset_shape" = name-size-digest ]; then
      printf '%s\t%s\tsha256:%s\n' "$nm" "$sz" "$sh"
    else
      printf '%s\t%s\tsha256:%s\n' 1002 "$nm" "$sh"
    fi
  fi
  exit 0
fi

printf 'unexpected fake gh call: %s\n' "$*" >&2
exit 90
EOF
chmod 0755 "$TEST_ROOT/bin/gh"

cat >"$TEST_ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_STATE_DIR:?}"
: "${FAKE_GH_TOKEN:?}"

count() { # count <name> → 自增并把当前计数写到 $FAKE_STATE_DIR/count-<name>
  local f="$FAKE_STATE_DIR/count-$1" n=0
  [ ! -f "$f" ] || n="$(<"$f")"
  n=$((n + 1))
  printf '%s\n' "$n" >"$f"
}

joined="$*"

# 1) 远端构建配方执行：ssh ... "$BUILD_HOST" MODULE=... ARCH=... bash -s <"$recipe"
#    真实调用以 "bash -s" 结尾（没有 --），本地 recipe 内容经 stdin 送达。
case "$joined" in
  *"bash -s")
    cat >/dev/null
    arch=""
    for a in "$@"; do
      case "$a" in ARCH=*) arch="${a#ARCH=}" ;; esac
    done
    count "build-$arch"
    case "$arch" in
      aarch64)
        printf 'building aarch64\n' >&2
        printf '%s\t%s\n' "${FAKE_VERSION:?}" "${FAKE_REMOTE_PATH_AARCH64:?}"
        exit 0
        ;;
      x86_64)
        if [ "${FAKE_BUILD_X86_64_FAIL:-0}" = 1 ]; then
          echo "fake recipe: simulated build failure for x86_64" >&2
          exit 1
        fi
        printf 'building x86_64\n' >&2
        printf '%s\t%s\n' "${FAKE_VERSION:?}" "${FAKE_REMOTE_PATH_X86_64:?}"
        exit 0
        ;;
      *)
        echo "fake recipe: unexpected ARCH=$arch" >&2
        exit 89
        ;;
    esac
    ;;
esac

# 2) 架构检查（verify-artifact-arch.sh）：含 "/usr/bin/bash -s --"
case "$joined" in
  *"/usr/bin/bash -s --"*)
    cat >/dev/null
    echo "fake: 架构检查通过"
    exit 0
    ;;
esac

# 3) 构建机直传（builder_upload_once）：含 "/usr/bin/bash -c"
#    必须在下面的元数据探针（case 4）之前判断：这条命令的内嵌校验脚本自己也含有
#    "stat -c"/"sha256sum --" 字样（用来核对远端文件 size/sha 再上传），如果顺序反了，
#    真实上传调用会被误判成元数据探针，永远不会走到 FAKE_UPLOAD_OUTCOME_* 分支。
case "$joined" in
  *"/usr/bin/bash -c"*)
    IFS= read -r token
    [ "$token" = "$FAKE_GH_TOKEN" ] || { echo "fake: token 未通过 stdin 送达" >&2; exit 96; }
    case "$joined" in
      *"$FAKE_GH_TOKEN"*) echo "fake: token 泄漏进 ssh 参数" >&2; exit 94 ;;
    esac
    arch=""
    case "$joined" in
      *"${FAKE_ASSET_NAME_AARCH64:?}"*) arch=aarch64 ;;
      *"${FAKE_ASSET_NAME_X86_64:?}"*) arch=x86_64 ;;
      *) echo "fake: 无法识别上传资产" >&2; exit 88 ;;
    esac
    count "upload-$arch"
    outcome_var="FAKE_UPLOAD_OUTCOME_${arch}"
    outcome="${!outcome_var:-fail}"
    if [ "$outcome" = "success" ]; then
      # 记录真正被上传的资产名（当次调用时的 FAKE_ASSET_NAME_*），不是"随便一个
      # 占位符，读的时候再拿当前环境变量现算"——调用方（同一次测试进程里的不同
      # 轮次）可能在两次上传之间把 FAKE_ASSET_NAME_* 改成新版本的名字，如果清单
      # 查询时才去读当前值，会把第一轮真实上传的旧资产错报成新版本的名字，产生
      # "资产已存在"的假阳性，第二轮就会被误判成可以直接认领、不必真的上传。
      case "$arch" in
        aarch64) printf '%s\t%s\t%s\n' "$FAKE_ASSET_NAME_AARCH64" "$FAKE_SIZE_AARCH64" "$FAKE_SHA_AARCH64" >"$FAKE_STATE_DIR/asset-aarch64" ;;
        x86_64) printf '%s\t%s\t%s\n' "$FAKE_ASSET_NAME_X86_64" "$FAKE_SIZE_X86_64" "$FAKE_SHA_X86_64" >"$FAKE_STATE_DIR/asset-x86_64" ;;
      esac
      exit 0
    fi
    echo "fake: 模拟上传响应丢失/网络失败" >&2
    exit 1
    ;;
esac

# 4) 远端产物元数据 / 恢复校验探针：含 "stat -c" 与 "sha256sum --"
#    remote_artifact_metadata 与 publish_verify_recovery_claim 用的是同一条命令形状。
case "$joined" in
  *"stat -c"*"sha256sum --"*)
    case "$joined" in
      *"${FAKE_REMOTE_PATH_AARCH64:?}"*)
        printf '%s\n%s  x\n' "${FAKE_SIZE_AARCH64:?}" "${FAKE_SHA_AARCH64:?}"
        ;;
      *"${FAKE_REMOTE_PATH_X86_64:?}"*)
        printf '%s\n%s  x\n' "${FAKE_SIZE_X86_64:?}" "${FAKE_SHA_X86_64:?}"
        ;;
      *)
        echo "fake: 未知远端产物路径" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
esac

echo "unexpected fake ssh call: $joined" >&2
exit 87
EOF
chmod 0755 "$TEST_ROOT/bin/ssh"

export PATH="$TEST_ROOT/bin:$PATH"

# ---- 固定测试用值 ---------------------------------------------------------
OLD_VERSION="0.1.0"
NEW_VERSION="0.1.1"
FAKE_ASSET_NAME_AARCH64="dbdog-web-$NEW_VERSION-aarch64.tar.gz"
FAKE_ASSET_NAME_X86_64="dbdog-web-$NEW_VERSION-x86_64.tar.gz"
FAKE_SIZE_AARCH64=1024
FAKE_SIZE_X86_64=2048
FAKE_SHA_AARCH64="$(printf 'a%.0s' $(seq 1 64))"
FAKE_SHA_X86_64="$(printf 'b%.0s' $(seq 1 64))"
FAKE_VERSION="$NEW_VERSION"
FAKE_GH_TOKEN='github_pat_test_secret_must_not_leak'
export FAKE_ASSET_NAME_AARCH64 FAKE_ASSET_NAME_X86_64 FAKE_SIZE_AARCH64 FAKE_SIZE_X86_64 \
  FAKE_SHA_AARCH64 FAKE_SHA_X86_64 FAKE_VERSION FAKE_GH_TOKEN

# ---- fixture 建造 ---------------------------------------------------------
hashes_of() { # hashes_of <release dir>；跨平台取 manifest.tsv/README.md 的内容摘要
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$1" && sha256sum manifest.tsv README.md )
  else
    ( cd "$1" && shasum -a 256 manifest.tsv README.md )
  fi
}

write_manifest() { # write_manifest <path> <version> <source_sha>
  local f="$1" v="$2" ssha="$3"
  {
    printf 'dbdog-web\tfirst-party\tstack\tyes\t%s\tdbdog-web-%s-aarch64.tar.gz\toldsha-aarch64-placeholder\t%s\taarch64\n' \
      "$v" "$v" "$ssha"
    printf 'dbdog-web\tfirst-party\tstack\tyes\t%s\tdbdog-web-%s-x86_64.tar.gz\toldsha-x86_64-placeholder\t%s\tx86_64\n' \
      "$v" "$v" "$ssha"
  } >"$f"
}

setup_release_repo() { # setup_release_repo <dir> <bare> <manifest fixture>
  local dir="$1" bare="$2" manifest_fixture="$3"
  git init -q --bare "$bare"
  git init -q "$dir"
  git -C "$dir" config user.name dbdog-contract-test
  git -C "$dir" config user.email dbdog-contract-test@example.invalid
  git -C "$dir" remote add origin "$bare"
  cp "$manifest_fixture" "$dir/manifest.tsv"
  cat >"$dir/README.md" <<'MD'
# dbdog-release（测试 fixture）

<!-- VERSION-TABLE:BEGIN -->
<!-- VERSION-TABLE:END -->
MD
  git -C "$dir" add manifest.tsv README.md
  git -C "$dir" commit -qm 'init fixture'
  git -C "$dir" branch -M main
  git -C "$dir" push -q -u origin main
}

setup_src_repo() { # setup_src_repo <dir>
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.name dbdog-contract-test
  git -C "$dir" config user.email dbdog-contract-test@example.invalid
  printf 'dbdog-web source under test\n' >"$dir/main.go"
  git -C "$dir" add -A
  git -C "$dir" commit -qm 'source under test'
}

run_txn_pipeline() { # run_txn_pipeline <module> <version> → 依次跑三阶段（真实驱动被测函数），
  # 镜像 cmd_publish 里真实的调用序列：先看是不是"commit 成功、push 失败"的中断恢复
  # （命中就直接补 push，不进入下面任何一步），否则给整个矩阵做 builder 预检、再逐
  # 架构构建。
  local m="$1" v="$2" arch txn_dir
  if publish_resume_pending_push "$m"; then
    return 0
  fi
  publish_ensure_arch_builders "$m"
  while IFS= read -r arch; do
    [ -n "$arch" ] || continue
    build_one_arch "$m" "$v" "$arch"
  done < <(publish_arches_for_module "$m")
  txn_dir="$(publish_txn_dir "$m" "$v")"
  publish_commit_arch_matrix "$txn_dir/txn.tsv"
}

write_gate_hook() { # write_gate_hook <repo> <hook名> <marker文件> → 除非 marker 存在，
  # 否则该 git hook 拒绝操作；用真实 git hook 模拟"commit/push 在这一步失败"，
  # 不需要另外 fake git 本身。
  local repo="$1" hook="$2" marker="$3"
  mkdir -p "$repo/.git/hooks"
  cat >"$repo/.git/hooks/$hook" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
if [ -f "$marker" ]; then
  exit 0
fi
echo "blocked by test $hook gate (marker not present: $marker)" >&2
exit 1
EOF
  chmod +x "$repo/.git/hooks/$hook"
}

# ===========================================================================
# 场景 1：第二个架构（x86_64）构建失败 → manifest/README 字节不变，无 commit/push
# ===========================================================================
CASE1="$TEST_ROOT/case1"
mkdir -p "$CASE1"
manifest_fixture1="$CASE1/manifest.fixture.tsv"

setup_src_repo "$CASE1/src/dbdog-web"
source_sha1="$(git -C "$CASE1/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture1" "$OLD_VERSION" "$source_sha1"
setup_release_repo "$CASE1/release" "$CASE1/release-bare.git" "$manifest_fixture1"

DBDOG_HOME="$CASE1/home"
RELEASE_DIR="$CASE1/release"
SRC_ROOT="$CASE1/src"
# 显式设置 MANIFEST（而不是让 lib.sh 用 RELEASE_DIR 派生默认值）：本文件后面还有
# 场景 2/3 各自的 ( ... ) 子 shell，bash 子 shell 会继承父 shell 的全部变量（不只是
# export 的），如果这里让 MANIFEST 走 "${MANIFEST:-...}" 的默认值分支，后面场景的
# 子 shell 会在 source lib.sh 时发现 MANIFEST 已经"被设置过"（继承自本场景），从而
# 沿用这里的 CASE1 路径，而不是各自场景自己的 RELEASE_DIR/manifest.tsv。
MANIFEST="$RELEASE_DIR/manifest.tsv"
export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
# shellcheck source=publish/publish.sh
source "$SCRIPTS_DIR/publish/publish.sh"

# publish.conf.example 的占位值必须不可用；显式给两个架构配置互不相同的原生 builder。
BUILD_HOST_AARCH64="fake-aarch64-builder"
BUILD_HOST_X86_64="fake-x86_64-builder"
BUILD_HOST=""
BUILD_WORK="$CASE1/build-work"
REPO_ROOT="$CASE1/repo-root"
TOOL_PATH=""
PUBLISH_UPLOAD_MAX_ATTEMPTS=1
PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64

before_hashes="$(hashes_of "$RELEASE_DIR")"
before_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"

FAKE_STATE_DIR="$CASE1/state"
mkdir -p "$FAKE_STATE_DIR"
export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
export FAKE_BUILD_X86_64_FAIL=1

if (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE1/run.log" 2>&1; then
  sed -n '1,200p' "$CASE1/run.log" >&2
  fail "第二个架构（x86_64）构建失败时，事务流水线本应中止却成功完成"
fi
grep -Fq '远端构建配方执行失败' "$CASE1/run.log" \
  || { sed -n '1,200p' "$CASE1/run.log" >&2; fail "x86_64 构建失败没有留下预期的诊断信息"; }
pass "x86_64 架构构建按预期失败并中止事务流水线"

after_hashes="$(hashes_of "$RELEASE_DIR")"
[ "$before_hashes" = "$after_hashes" ] \
  || fail "第二架构构建失败后 manifest.tsv/README.md 字节发生了变化"
pass "第二架构构建失败时 manifest.tsv 与 README.md 字节完全不变"

after_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
[ "$before_head" = "$after_head" ] \
  || fail "第二架构构建失败后仍然产生了 git commit"
[ "$(git -C "$RELEASE_DIR" rev-list --count HEAD)" = 1 ] \
  || fail "第二架构构建失败后 release 仓提交数不是初始的 1"
pass "第二架构构建失败时没有产生任何 git commit"

[ ! -e "$FAKE_STATE_DIR/count-upload-aarch64" ] && [ ! -e "$FAKE_STATE_DIR/count-upload-x86_64" ] \
  || fail "第二架构构建失败前不应该有任何架构进入上传阶段"
pass "第二架构构建失败时零上传（build 阶段整体先于 upload 阶段）"

txn_dir1="$(publish_txn_dir dbdog-web "$NEW_VERSION")"
[ -d "$txn_dir1" ] || fail "事务目录未创建: $txn_dir1"
mode1="$(stat -c '%a' "$txn_dir1" 2>/dev/null || stat -f '%Lp' "$txn_dir1")"
[ "$mode1" = 700 ] || fail "事务目录权限不是 0700: $mode1"
[ "$(awk -F'\t' '$1=="dbdog-web"' "$txn_dir1/txn.tsv" | wc -l | tr -d ' ')" = 1 ] \
  || fail "事务 TSV 应该只有 aarch64 一行（x86_64 从未成功追加）"
pass "事务目录 mode 0700，且只记录了成功架构（aarch64）那一行"

# ===========================================================================
# 场景 2：aarch64 上传成功后进程中断；第二次执行认领同一 asset，不重复上传，
#         完成 x86_64 后只产生一个发布提交。
# ===========================================================================
CASE2="$TEST_ROOT/case2"
mkdir -p "$CASE2"
manifest_fixture2="$CASE2/manifest.fixture.tsv"

setup_src_repo "$CASE2/src/dbdog-web"
source_sha2="$(git -C "$CASE2/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture2" "$OLD_VERSION" "$source_sha2"
setup_release_repo "$CASE2/release" "$CASE2/release-bare.git" "$manifest_fixture2"

(
  DBDOG_HOME="$CASE2/home"
  RELEASE_DIR="$CASE2/release"
  SRC_ROOT="$CASE2/src"
  # 见场景 1 里的同一条注释：显式设置 MANIFEST，不依赖 lib.sh 的默认派生，
  # 避免子 shell 继承场景 1 已经 export 过的 MANIFEST。
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE2/build-work"
  REPO_ROOT="$CASE2/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64

  FAKE_STATE_DIR="$CASE2/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"

  before_hashes="$(hashes_of "$RELEASE_DIR")"
  before_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"

  # ---- 第一次执行：两个架构都构建成功；aarch64 上传成功，x86_64 上传"响应丢失"----
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=fail
  if (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE2/round1.log" 2>&1; then
    sed -n '1,200p' "$CASE2/round1.log" >&2
    fail "第一次执行本应在 x86_64 上传失败时中断，却成功完成"
  fi
  pass "第一次执行：aarch64 上传成功，x86_64 上传失败后中断（模拟进程中断）"

  [ -f "$FAKE_STATE_DIR/asset-aarch64" ] \
    || fail "第一次执行后 aarch64 资产应该已经真实上传"
  [ ! -f "$FAKE_STATE_DIR/asset-x86_64" ] \
    || fail "第一次执行后 x86_64 资产不应该已经上传成功"
  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "aarch64 第一次执行的上传尝试次数不是 1"
  x86_64_upload_attempts_round1="$(<"$FAKE_STATE_DIR/count-upload-x86_64")"
  [ "$x86_64_upload_attempts_round1" = 1 ] \
    || fail "x86_64 第一次执行的上传尝试次数不是 1（PUBLISH_UPLOAD_MAX_ATTEMPTS=1，应恰好失败一次后中断）"
  pass "第一次执行后：aarch64 资产已在（模拟）GitHub 落地，x86_64 尚未落地"

  after_round1_hashes="$(hashes_of "$RELEASE_DIR")"
  [ "$before_hashes" = "$after_round1_hashes" ] \
    || fail "第一次执行中断后 manifest.tsv/README.md 字节发生了变化"
  after_round1_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$before_head" = "$after_round1_head" ] \
    || fail "第一次执行中断后不应该产生任何 git commit"
  pass "第一次执行中断后 manifest/README 字节不变，且没有 commit（尚未提交阶段）"

  # ---- 第二次执行：恢复。aarch64 应被认领（不重复上传），x86_64 补齐上传 ----
  export FAKE_UPLOAD_OUTCOME_x86_64=success
  (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE2/round2.log" 2>&1 \
    || { sed -n '1,200p' "$CASE2/round2.log" >&2; fail "第二次执行未能完成剩余架构的发布"; }
  pass "第二次执行：认领 aarch64、补齐 x86_64 上传，事务完成"

  grep -Fq '认领已上传的产物桶资产' "$CASE2/round2.log" \
    || { sed -n '1,200p' "$CASE2/round2.log" >&2; fail "第二次执行没有留下 aarch64 恢复认领的日志"; }
  pass "第二次执行的日志明确记录了 aarch64 恢复认领（不是静默重新上传）"

  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "aarch64 在恢复后被重复上传了（认领应跳过真实上传调用，总次数应保持第一次执行时的 1）"
  x86_64_upload_attempts_round2="$(<"$FAKE_STATE_DIR/count-upload-x86_64")"
  [ "$((x86_64_upload_attempts_round2 - x86_64_upload_attempts_round1))" = 1 ] \
    || fail "第二次执行里 x86_64 的上传尝试次数不是恰好 1（第一次失败的 1 次 + 第二次成功的 1 次，总数应为 2）"
  [ -f "$FAKE_STATE_DIR/count-build-aarch64" ] && [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "aarch64 在两轮执行中被构建的次数不是恰好 1（应该在第一次执行中构建、第二次命中事务记录短路）"
  [ -f "$FAKE_STATE_DIR/count-build-x86_64" ] && [ "$(<"$FAKE_STATE_DIR/count-build-x86_64")" = 1 ] \
    || fail "x86_64 在两轮执行中被构建的次数不是恰好 1（构建矩阵在第一次执行已全部完成，第二次只补上传）"
  pass "两个架构全程只被真实构建一次；aarch64 只被真实上传一次，x86_64 补齐时只上传一次"

  final_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$final_head" != "$before_head" ] \
    || fail "两轮执行完成后没有产生任何 commit"
  commit_count="$(git -C "$RELEASE_DIR" rev-list --count "$before_head..HEAD")"
  [ "$commit_count" = 1 ] \
    || fail "两轮执行完成后应该只产生一个发布提交，实际: $commit_count"
  pass "恢复完成整个架构矩阵后，两轮执行合计只产生一个发布提交"

  new_row_aarch64="$(manifest_get dbdog-web 6 aarch64)"
  new_row_x86_64="$(manifest_get dbdog-web 6 x86_64)"
  [ "$new_row_aarch64" = "$FAKE_ASSET_NAME_AARCH64" ] \
    || fail "manifest aarch64 行的 artifact 未更新为新产物"
  [ "$new_row_x86_64" = "$FAKE_ASSET_NAME_X86_64" ] \
    || fail "manifest x86_64 行的 artifact 未更新为新产物"
  [ "$(manifest_get dbdog-web 5 aarch64)" = "$NEW_VERSION" ] \
    || fail "manifest aarch64 行的 version 未更新为新版本"
  [ "$(manifest_get dbdog-web 5 x86_64)" = "$NEW_VERSION" ] \
    || fail "manifest x86_64 行的 version 未更新为新版本"
  pass "提交后 manifest 两个架构行都精确更新为各自的新产物/新版本"
) || exit 1

# ===========================================================================
# 补充：兼容别名 BUILD_HOST 只在 uname -m 与请求架构一致时才作为回退。
# ===========================================================================
CASE3="$TEST_ROOT/case3"
mkdir -p "$CASE3/release"
git init -q "$CASE3/release"
git -C "$CASE3/release" config user.name dbdog-contract-test
git -C "$CASE3/release" config user.email dbdog-contract-test@example.invalid
: >"$CASE3/release/manifest.tsv"
git -C "$CASE3/release" add manifest.tsv
git -C "$CASE3/release" commit -qm init

(
  RELEASE_DIR="$CASE3/release"
  DBDOG_HOME="$CASE3/home"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export RELEASE_DIR DBDOG_HOME MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"
  BUILD_HOST_AARCH64=""
  BUILD_HOST_X86_64=""
  BUILD_HOST="legacy-aarch64-only"

  ssh() { # 局部桩：只答复 "uname -m"，模拟旧 BUILD_HOST 是一台真实 aarch64 机器
    case "$*" in
      "legacy-aarch64-only uname -m") echo aarch64 ;;
      *) echo "unexpected legacy probe ssh call: $*" >&2; return 1 ;;
    esac
  }

  resolve_build_host_for_arch aarch64
  [ "$RESOLVED_BUILD_HOST" = "legacy-aarch64-only" ] \
    || fail "旧 BUILD_HOST 在 uname -m 匹配请求架构时应该被接受为兼容回退"

  # resolve_build_host_for_arch 对架构不匹配走的是 die()（exit），不是 return 1——
  # 这是有意的：生产代码里它只会被 build_one_arch/publish_claim_or_upload_arch_asset
  # 调用，架构不匹配就应该让整个发布硬失败，不是优雅返回给调用方处理。所以这里必须
  # 用子 shell 隔离 exit，只让子 shell 死掉，不能把测试脚本自己也带死
  # （同样的教训见 test-publish-agent-version-contracts.sh 对 load_agent_release_baseline 的调用方式）。
  if (resolve_build_host_for_arch x86_64) 2>"$CASE3/legacy-mismatch.log"; then
    fail "旧 BUILD_HOST 是 aarch64 机器时不应该被接受为 x86_64 的兼容回退"
  fi
  grep -Fq '与请求架构 x86_64 不一致' "$CASE3/legacy-mismatch.log" \
    || { sed -n '1,50p' "$CASE3/legacy-mismatch.log" >&2; fail "架构不匹配时没有给出明确拒绝原因"; }
) || exit 1
pass "兼容别名 BUILD_HOST 只在 uname -m 精确匹配请求架构时才作为回退，不匹配时 fail closed"

# ===========================================================================
# 补充：noarch 产物（如 dbdog-mcp）不对应任何真实 CPU 架构，resolve_build_host_for_arch
# 必须能为它解析出一个可用 builder，而不是落进"未知架构"拒绝分支（这是实现过程中
# 真实踩到的回归：build_one_arch 对 noarch 一直无条件调用
# resolve_build_host_for_arch，如果后者不认识 "noarch"，dbdog-mcp 这类现有 noarch
# 模块的发布会在触碰任何构建前就先被拒绝）。
# ===========================================================================
CASE4="$TEST_ROOT/case4"
mkdir -p "$CASE4/release"
git init -q "$CASE4/release"
git -C "$CASE4/release" config user.name dbdog-contract-test
git -C "$CASE4/release" config user.email dbdog-contract-test@example.invalid
: >"$CASE4/release/manifest.tsv"
git -C "$CASE4/release" add manifest.tsv
git -C "$CASE4/release" commit -qm init

(
  RELEASE_DIR="$CASE4/release"
  DBDOG_HOME="$CASE4/home"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export RELEASE_DIR DBDOG_HOME MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  # 场景 A：只配置了 BUILD_HOST_AARCH64，没有专门给 noarch 配置什么——应该直接复用它。
  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64=""
  BUILD_HOST=""
  resolve_build_host_for_arch noarch
  [ "$RESOLVED_BUILD_HOST" = "fake-aarch64-builder" ] \
    || fail "noarch 应该优先复用已配置的 BUILD_HOST_AARCH64"

  # 场景 B：只配置了旧的单一 BUILD_HOST（未迁移到双执行器的老配置）——noarch 不需要
  # 验证 uname -m（它本来就不对应任何 CPU 架构），应该直接可用。
  BUILD_HOST_AARCH64=""
  BUILD_HOST_X86_64=""
  BUILD_HOST="legacy-only-builder"
  resolve_build_host_for_arch noarch
  [ "$RESOLVED_BUILD_HOST" = "legacy-only-builder" ] \
    || fail "noarch 在只有旧 BUILD_HOST 时应该直接复用，不需要 uname -m 校验"

  # 场景 C：什么都没配置——必须 fail closed，而不是当成"不支持的架构"报错。
  BUILD_HOST_AARCH64=""
  BUILD_HOST_X86_64=""
  BUILD_HOST=""
  if (resolve_build_host_for_arch noarch) 2>"$CASE4/noarch-unconfigured.log"; then
    fail "noarch 在完全没有配置任何 builder 时不应该成功"
  fi
  grep -Fq '没有为 noarch 构建配置任何原生 builder' "$CASE4/noarch-unconfigured.log" \
    || { sed -n '1,50p' "$CASE4/noarch-unconfigured.log" >&2; fail 'noarch 未配置 builder 时的拒绝原因不明确（不应该是「不支持的架构」）'; }
) || exit 1
pass "noarch 产物能正确解析出可用 builder（优先复用 aarch64/旧 BUILD_HOST），未配置任何 builder 时才 fail closed"

# ===========================================================================
# 补充：矩阵里任一架构缺少 builder，必须在触碰任何构建之前整体失败——即使排在
# 前面的架构（aarch64）本来是有 builder、能构建成功的，也不能先真的构建它一遍。
# ===========================================================================
CASE5="$TEST_ROOT/case5"
mkdir -p "$CASE5"
manifest_fixture5="$CASE5/manifest.fixture.tsv"
setup_src_repo "$CASE5/src/dbdog-web"
source_sha5="$(git -C "$CASE5/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture5" "$OLD_VERSION" "$source_sha5"
setup_release_repo "$CASE5/release" "$CASE5/release-bare.git" "$manifest_fixture5"

(
  DBDOG_HOME="$CASE5/home"
  RELEASE_DIR="$CASE5/release"
  SRC_ROOT="$CASE5/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  # aarch64 配了真实（fake）builder；x86_64 完全没配置——矩阵不完整，必须整体失败。
  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64=""
  BUILD_HOST=""
  BUILD_WORK="$CASE5/build-work"
  REPO_ROOT="$CASE5/repo-root"
  TOOL_PATH=""

  FAKE_STATE_DIR="$CASE5/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64

  if (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE5/run.log" 2>&1; then
    sed -n '1,200p' "$CASE5/run.log" >&2
    fail "x86_64 缺少 builder 时事务流水线本应整体失败却成功完成"
  fi
  grep -Fq '没有为架构 x86_64 配置原生 builder' "$CASE5/run.log" \
    || { sed -n '1,200p' "$CASE5/run.log" >&2; fail "x86_64 缺少 builder 时没有留下预期的诊断信息"; }
  [ ! -e "$FAKE_STATE_DIR/count-build-aarch64" ] \
    || fail "x86_64 缺少 builder 时，排在前面的 aarch64 不应该被真的构建（矩阵预检应先于任何构建）"
) || exit 1
pass "矩阵中任一架构缺少 builder 时，整个矩阵在触碰任何构建之前就整体失败（不会先构建排在前面的架构）"

# ===========================================================================
# 评审 Important 1：build 阶段的恢复短路必须校验 source SHA（含 Agent 基线），
# 不能只按 (module, arch) 匹配就无条件跳过重新构建。
#
# 场景：第一轮把两个架构都构建完（事务记录 source_sha=S1），在进入上传阶段之前
# 中断（比如进程被杀）；源仓这时候被人补了一个新 commit（source_sha 变成 S2）；
# 第二次执行必须拒绝直接复用旧事务行去发布 S1 的产物，而不是静默跳过重新构建。
# ===========================================================================
CASE6="$TEST_ROOT/case6"
mkdir -p "$CASE6"
manifest_fixture6="$CASE6/manifest.fixture.tsv"
setup_src_repo "$CASE6/src/dbdog-web"
source_sha6_s1="$(git -C "$CASE6/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture6" "$OLD_VERSION" "$source_sha6_s1"
setup_release_repo "$CASE6/release" "$CASE6/release-bare.git" "$manifest_fixture6"

(
  DBDOG_HOME="$CASE6/home"
  RELEASE_DIR="$CASE6/release"
  SRC_ROOT="$CASE6/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE6/build-work"
  REPO_ROOT="$CASE6/repo-root"
  TOOL_PATH=""

  FAKE_STATE_DIR="$CASE6/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64
  export FAKE_BUILD_X86_64_FAIL=0

  # 第一轮：两个架构都构建成功（模拟"死在进入上传阶段之前"，所以只调用
  # build_one_arch，不调用 publish_commit_arch_matrix）。
  build_one_arch dbdog-web "$NEW_VERSION" aarch64
  build_one_arch dbdog-web "$NEW_VERSION" x86_64
  txn_dir6="$(publish_txn_dir dbdog-web "$NEW_VERSION")"
  [ "$(awk -F'\t' '$1=="dbdog-web"' "$txn_dir6/txn.tsv" | wc -l | tr -d ' ')" = 2 ] \
    || fail "第一轮结束后事务记录应该恰好有两行（aarch64+x86_64）"

  # 源仓在事务开始后被人补了一个新 commit——source_sha 从 S1 漂移到 S2。
  printf 'unexpected upstream drift after the transaction started\n' >>"$CASE6/src/dbdog-web/main.go"
  git -C "$CASE6/src/dbdog-web" add -A
  git -C "$CASE6/src/dbdog-web" commit -qm 'drift after txn started'
  source_sha6_s2="$(git -C "$CASE6/src/dbdog-web" rev-parse --short=7 HEAD)"
  [ "$source_sha6_s2" != "$source_sha6_s1" ] \
    || fail "测试 fixture 本身有问题：漂移前后的 source_sha 应该不同"

  # 第二次执行：对 aarch64 重新调用 build_one_arch，必须拒绝短路复用 S1 的旧构建。
  if (build_one_arch dbdog-web "$NEW_VERSION" aarch64) >"$CASE6/rerun.log" 2>&1; then
    sed -n '1,200p' "$CASE6/rerun.log" >&2
    fail "源码在事务开始后漂移时，重跑本应拒绝短路却直接返回成功"
  fi
  grep -Fq '源码/基线在事务开始后发生了漂移' "$CASE6/rerun.log" \
    || { sed -n '1,200p' "$CASE6/rerun.log" >&2; fail "源码漂移时没有给出明确的漂移诊断"; }
  grep -Fq "$source_sha6_s1" "$CASE6/rerun.log" && grep -Fq "$source_sha6_s2" "$CASE6/rerun.log" \
    || { sed -n '1,200p' "$CASE6/rerun.log" >&2; fail "漂移诊断信息里应该同时出现事务记录的旧 SHA 和当前的新 SHA，方便定位"; }

  # 事务记录里 aarch64 那一行必须原封不动（不能被静默改写成新 source_sha，
  # 也不能变成重复行——拒绝短路之后应该在漂移检查这里就停下，不触碰 txn.tsv）。
  [ "$(awk -F'\t' '$1=="dbdog-web" && $2=="aarch64"' "$txn_dir6/txn.tsv" | wc -l | tr -d ' ')" = 1 ] \
    || fail "拒绝短路后事务记录不应该产生额外/重复的 aarch64 行"
  awk -F'\t' '$1=="dbdog-web" && $2=="aarch64" {print $7}' "$txn_dir6/txn.tsv" \
    | grep -Fqx "$source_sha6_s1" \
    || fail "拒绝短路后事务记录里 aarch64 那一行的 source_sha 被意外改写了"

  # 没有发生任何新的真实构建（第二次调用在漂移检查这里就 die 了，从未走到
  # resolve_build_host_for_arch/ssh 那一步）。
  [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "源码漂移时 aarch64 不应该发生新的真实构建（应该在漂移校验处就 die）"
) || exit 1
pass "构建阶段的恢复短路会校验 source_sha；源码在事务开始后漂移时拒绝复用旧构建并给出精确诊断"

# ===========================================================================
# 评审 Important 2a：manifest 已经 mv 到本次目标版本、但 commit 还没做（用真实
# git pre-commit hook 模拟"死在 mv 之后、commit 之前"）——重跑必须识别这个状态，
# 跳过重新上传，直接补 commit/push，不能把自己刚写的 manifest 说成"无关残留"
# 而拒绝，也不能留一个脏工作区不管。
# ===========================================================================
CASE7="$TEST_ROOT/case7"
mkdir -p "$CASE7"
manifest_fixture7="$CASE7/manifest.fixture.tsv"
setup_src_repo "$CASE7/src/dbdog-web"
source_sha7="$(git -C "$CASE7/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture7" "$OLD_VERSION" "$source_sha7"
setup_release_repo "$CASE7/release" "$CASE7/release-bare.git" "$manifest_fixture7"
allow_commit7="$CASE7/allow-commit"
write_gate_hook "$CASE7/release" pre-commit "$allow_commit7"

(
  DBDOG_HOME="$CASE7/home"
  RELEASE_DIR="$CASE7/release"
  SRC_ROOT="$CASE7/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE7/build-work"
  REPO_ROOT="$CASE7/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_STATE_DIR="$CASE7/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=success

  before_head7="$(git -C "$RELEASE_DIR" rev-parse HEAD)"

  # 第一次执行：两个架构构建、上传都成功，manifest 也 mv 成功，commit 被
  # pre-commit hook 挡住（模拟"死在 mv 之后、commit 之前"）。
  if (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE7/round1.log" 2>&1; then
    sed -n '1,200p' "$CASE7/round1.log" >&2
    fail "第一次执行本应在 commit 阶段被 pre-commit hook 挡住却成功完成"
  fi
  grep -Fq 'blocked by test pre-commit gate' "$CASE7/round1.log" \
    || { sed -n '1,200p' "$CASE7/round1.log" >&2; fail "第一次执行没有在预期的 pre-commit hook 处失败"; }
  pass "第一次执行：build/upload/manifest mv 全部成功，commit 被 pre-commit hook 挡住后中断"

  [ "$(git -C "$RELEASE_DIR" rev-parse HEAD)" = "$before_head7" ] \
    || fail "commit 被 hook 挡住后不应该产生任何新提交"
  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv \
    && fail "commit 被挡住后 manifest.tsv 应该相对 HEAD 有未提交的改动（已经 mv 到新版本）"
  [ "$(manifest_get dbdog-web 5 aarch64)" = "$NEW_VERSION" ] \
    || fail "commit 被挡住后本地 manifest.tsv（未提交）应该已经是新版本"
  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "第一次执行 aarch64 的上传次数不是 1"
  [ "$(<"$FAKE_STATE_DIR/count-upload-x86_64")" = 1 ] \
    || fail "第一次执行 x86_64 的上传次数不是 1"
  pass "commit 被挡住后：manifest.tsv 已在工作区 mv 到新版本但未提交，HEAD 不变，两个架构各自只上传了一次"

  # 放开 pre-commit hook，第二次执行必须识别"已经 mv、只差 commit"，不重新上传。
  : >"$allow_commit7"
  (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE7/round2.log" 2>&1 \
    || { sed -n '1,200p' "$CASE7/round2.log" >&2; fail "第二次执行（放开 pre-commit hook 后）未能完成发布"; }
  grep -Fq '判定为「mv 之后、commit 之前中断」的恢复' "$CASE7/round2.log" \
    || { sed -n '1,200p' "$CASE7/round2.log" >&2; fail "第二次执行没有留下识别出「mv 之后、commit 之前」状态的日志"; }
  pass "第二次执行：正确识别出「已经 mv、只差 commit」的状态并补完提交"

  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "第二次执行不应该重新上传 aarch64（manifest 已经是目标状态，不该再走一遍上传循环）"
  [ "$(<"$FAKE_STATE_DIR/count-upload-x86_64")" = 1 ] \
    || fail "第二次执行不应该重新上传 x86_64"
  [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "第二次执行不应该重新构建 aarch64"
  [ "$(<"$FAKE_STATE_DIR/count-build-x86_64")" = 1 ] \
    || fail "第二次执行不应该重新构建 x86_64"
  after_head7="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$after_head7" != "$before_head7" ] || fail "第二次执行后应该产生了新的 commit"
  [ "$(git -C "$RELEASE_DIR" rev-list --count "${before_head7}..${after_head7}")" = 1 ] \
    || fail "两轮执行合计应该只产生一个 commit"
  git -C "$RELEASE_DIR" diff --quiet HEAD -- manifest.tsv README.md \
    || fail "第二次执行后工作区不应该再有未提交的改动"
) || exit 1
pass "manifest 已 mv、commit 未做时中断重跑：零重复上传、零重复构建，只产生一个 commit，收敛干净"

# ===========================================================================
# 评审 Important 2b：commit 已经成功、push 还没做（用真实 git pre-push hook
# 模拟）——release HEAD 已经因为这次 commit 前进，事务目录按新 HEAD 是找不到旧
# 记录的；重跑必须靠 publish_resume_pending_push 识别"HEAD 本身就是这次未推送
# 的发布提交"，直接补推同一个提交，不重建矩阵、不重复上传。
# ===========================================================================
CASE8="$TEST_ROOT/case8"
mkdir -p "$CASE8"
manifest_fixture8="$CASE8/manifest.fixture.tsv"
setup_src_repo "$CASE8/src/dbdog-web"
source_sha8="$(git -C "$CASE8/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture8" "$OLD_VERSION" "$source_sha8"
setup_release_repo "$CASE8/release" "$CASE8/release-bare.git" "$manifest_fixture8"
allow_push8="$CASE8/allow-push"
write_gate_hook "$CASE8/release" pre-push "$allow_push8"

(
  DBDOG_HOME="$CASE8/home"
  RELEASE_DIR="$CASE8/release"
  SRC_ROOT="$CASE8/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE8/build-work"
  REPO_ROOT="$CASE8/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_STATE_DIR="$CASE8/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=success

  before_head8="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  before_origin8="$(git -C "$CASE8/release-bare.git" rev-parse refs/heads/main)"

  # 第一次执行：build/upload/mv/commit 全部成功，push 被 pre-push hook 挡住。
  if (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE8/round1.log" 2>&1; then
    sed -n '1,200p' "$CASE8/round1.log" >&2
    fail "第一次执行本应在 push 阶段被 pre-push hook 挡住却成功完成"
  fi
  grep -Fq 'blocked by test pre-push gate' "$CASE8/round1.log" \
    || { sed -n '1,200p' "$CASE8/round1.log" >&2; fail "第一次执行没有在预期的 pre-push hook 处失败"; }
  pass "第一次执行：build/upload/manifest/commit 全部成功，push 被 pre-push hook 挡住后中断"

  after_round1_head8="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$after_round1_head8" != "$before_head8" ] \
    || fail "commit 应该已经成功，本地 HEAD 应该已经前进"
  [ "$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD)" = "publish: dbdog-web@$NEW_VERSION" ] \
    || fail "本地 HEAD 的提交信息应该是本次发布提交"
  [ "$(git -C "$CASE8/release-bare.git" rev-parse refs/heads/main)" = "$before_origin8" ] \
    || fail "push 被挡住后 origin（bare 仓）不应该有任何变化"
  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "第一次执行 aarch64 的上传次数不是 1"
  [ "$(<"$FAKE_STATE_DIR/count-upload-x86_64")" = 1 ] \
    || fail "第一次执行 x86_64 的上传次数不是 1"
  pass "push 被挡住后：本地已经提交（HEAD 前进），origin 完全没变，两个架构各自只上传了一次"

  # 放开 pre-push hook，第二次执行必须识别"HEAD 已经是本次发布提交，只差 push"。
  : >"$allow_push8"
  (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE8/round2.log" 2>&1 \
    || { sed -n '1,200p' "$CASE8/round2.log" >&2; fail "第二次执行（放开 pre-push hook 后）未能完成发布"; }
  grep -Fq '只是尚未推送；直接补 push' "$CASE8/round2.log" \
    || { sed -n '1,200p' "$CASE8/round2.log" >&2; fail "第二次执行没有留下识别出「commit 已完成、只差 push」状态的日志"; }
  pass "第二次执行：正确识别出「commit 已完成、只差 push」的状态并补推"

  final_head8="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$final_head8" = "$after_round1_head8" ] \
    || fail "第二次执行不应该产生新的 commit，本地 HEAD 应该和第一次执行后完全一样（重推同一个提交）"
  [ "$(git -C "$CASE8/release-bare.git" rev-parse refs/heads/main)" = "$final_head8" ] \
    || fail "第二次执行后 origin（bare 仓）应该和本地 HEAD 一致"
  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "第二次执行不应该重新上传 aarch64"
  [ "$(<"$FAKE_STATE_DIR/count-upload-x86_64")" = 1 ] \
    || fail "第二次执行不应该重新上传 x86_64"
  [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "第二次执行不应该重新构建 aarch64（不应该重建矩阵）"
  [ "$(<"$FAKE_STATE_DIR/count-build-x86_64")" = 1 ] \
    || fail "第二次执行不应该重新构建 x86_64（不应该重建矩阵）"
) || exit 1
pass "commit 已完成、push 未做时中断重跑：重推同一个提交，零重建矩阵、零重复上传"

# ===========================================================================
# 评审 Critical：publish_resume_pending_push 必须要求 HEAD 真的领先本地已知的
# origin/main 才能命中"待推送"。上一次发布已经完全成功（commit 和 push 都成
# 功）之后是最常见的稳态：manifest/README 相对 HEAD 干净、HEAD 的提交信息形如
# "publish: <module>@<version>"、manifest 里该模块每个架构都已经是这个版本——
# 光凭这三条会把这个稳态误判成"待推送"，直接 no-op 返回成功，导致下一次真正该
# 发布的新版本被静默跳过（不构建、不上传、manifest 也不会更新）。
# ===========================================================================
CASE9="$TEST_ROOT/case9"
mkdir -p "$CASE9"
manifest_fixture9="$CASE9/manifest.fixture.tsv"
setup_src_repo "$CASE9/src/dbdog-web"
source_sha9="$(git -C "$CASE9/src/dbdog-web" rev-parse --short=7 HEAD)"
write_manifest "$manifest_fixture9" "$OLD_VERSION" "$source_sha9"
setup_release_repo "$CASE9/release" "$CASE9/release-bare.git" "$manifest_fixture9"

(
  DBDOG_HOME="$CASE9/home"
  RELEASE_DIR="$CASE9/release"
  SRC_ROOT="$CASE9/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE9/build-work"
  REPO_ROOT="$CASE9/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_STATE_DIR="$CASE9/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=success

  # ---- 第一轮：完全成功的正常发布（build+upload+commit+push 全部成功，没有任何
  # hook 挡路）——制造"上一次发布已经完全成功"这个稳态起点。----
  FAKE_ASSET_NAME_AARCH64="dbdog-web-$NEW_VERSION-aarch64.tar.gz"
  FAKE_ASSET_NAME_X86_64="dbdog-web-$NEW_VERSION-x86_64.tar.gz"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  FAKE_VERSION="$NEW_VERSION"
  export FAKE_ASSET_NAME_AARCH64 FAKE_ASSET_NAME_X86_64 FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64 FAKE_VERSION

  (run_txn_pipeline dbdog-web "$NEW_VERSION") >"$CASE9/round1.log" 2>&1 \
    || { sed -n '1,200p' "$CASE9/round1.log" >&2; fail "第一轮（完全成功的正常发布）本身就应该成功，却失败了"; }
  pass "第一轮：build/upload/commit/push 全部成功（无任何 hook 阻拦）"

  after_round1_head9="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$(git -C "$CASE9/release-bare.git" rev-parse refs/heads/main)" = "$after_round1_head9" ] \
    || fail "第一轮结束后 origin（bare 仓）应该已经和本地 HEAD 一致（push 真的成功了）"
  [ "$(manifest_get dbdog-web 5 aarch64)" = "$NEW_VERSION" ] \
    || fail "第一轮结束后 manifest 应该已经是 $NEW_VERSION"
  [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "第一轮 aarch64 的构建次数不是 1"

  # ---- 第二轮：稳态下的正常再发布（source 没变，但决定再发一个新版本，比如手工
  # bump）——必须真的重新走 build/upload，不能被 publish_resume_pending_push 误判
  # 成"上一次还没推"而直接 no-op 掉。----
  bumped_v9="$(bump_version dbdog-web "$NEW_VERSION" patch)"
  [ "$bumped_v9" = "0.1.2" ] || fail "测试 fixture 假设有误：bump_version 算出来的不是 0.1.2: $bumped_v9"

  FAKE_ASSET_NAME_AARCH64="dbdog-web-$bumped_v9-aarch64.tar.gz"
  FAKE_ASSET_NAME_X86_64="dbdog-web-$bumped_v9-x86_64.tar.gz"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  FAKE_VERSION="$bumped_v9"
  export FAKE_ASSET_NAME_AARCH64 FAKE_ASSET_NAME_X86_64 FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64 FAKE_VERSION

  (run_txn_pipeline dbdog-web "$bumped_v9") >"$CASE9/round2.log" 2>&1 \
    || { sed -n '1,200p' "$CASE9/round2.log" >&2; fail "第二轮（稳态下的正常再发布）应该真的走一遍发布流程却失败了"; }

  grep -Fq '只是尚未推送；直接补 push' "$CASE9/round2.log" \
    && { sed -n '1,200p' "$CASE9/round2.log" >&2; fail "第二轮被 publish_resume_pending_push 误判成「待推送」而 no-op 跳过了（稳态误命中）"; }
  pass "第二轮：没有被误判成「待推送」，走了正常发布流程"

  build_count_aarch64_r2="$(<"$FAKE_STATE_DIR/count-build-aarch64")"
  build_count_x86_64_r2="$(<"$FAKE_STATE_DIR/count-build-x86_64")"
  upload_count_aarch64_r2="$(<"$FAKE_STATE_DIR/count-upload-aarch64")"
  upload_count_x86_64_r2="$(<"$FAKE_STATE_DIR/count-upload-x86_64")"
  [ "$build_count_aarch64_r2" = 2 ] \
    || fail "第二轮结束后 aarch64 的累计构建次数应该是 2（两轮各构建一次），实际: $build_count_aarch64_r2"
  [ "$build_count_x86_64_r2" = 2 ] \
    || fail "第二轮结束后 x86_64 的累计构建次数应该是 2，实际: $build_count_x86_64_r2"
  [ "$upload_count_aarch64_r2" = 2 ] \
    || fail "第二轮结束后 aarch64 的累计上传次数应该是 2，实际: $upload_count_aarch64_r2"
  [ "$upload_count_x86_64_r2" = 2 ] \
    || fail "第二轮结束后 x86_64 的累计上传次数应该是 2，实际: $upload_count_x86_64_r2"
  pass "第二轮真的重新构建、重新上传了两个架构（不是复用第一轮的结果）"

  [ "$(manifest_get dbdog-web 5 aarch64)" = "$bumped_v9" ] \
    || fail "第二轮结束后 manifest aarch64 行应该是新版本 $bumped_v9"
  [ "$(manifest_get dbdog-web 5 x86_64)" = "$bumped_v9" ] \
    || fail "第二轮结束后 manifest x86_64 行应该是新版本 $bumped_v9"
  [ "$(manifest_get dbdog-web 6 aarch64)" = "$FAKE_ASSET_NAME_AARCH64" ] \
    || fail "第二轮结束后 manifest aarch64 行的 artifact 应该是新产物"
  pass "第二轮结束后 manifest 两个架构行都落到了新版本"

  final_head9="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$final_head9" != "$after_round1_head9" ] \
    || fail "第二轮结束后应该产生了新的 commit"
  [ "$(git -C "$RELEASE_DIR" rev-list --count "${after_round1_head9}..${final_head9}")" = 1 ] \
    || fail "两轮总共应该恰好各产生一个 commit（第二轮相对第一轮只多一个）"
  [ "$(git -C "$RELEASE_DIR" log --format=%s -1 "$after_round1_head9")" = "publish: dbdog-web@$NEW_VERSION" ] \
    || fail "第一轮的提交信息应该是 publish: dbdog-web@$NEW_VERSION"
  [ "$(git -C "$RELEASE_DIR" log --format=%s -1 "$final_head9")" = "publish: dbdog-web@$bumped_v9" ] \
    || fail "第二轮的提交信息应该是 publish: dbdog-web@$bumped_v9"
  [ "$(git -C "$CASE9/release-bare.git" rev-parse refs/heads/main)" = "$final_head9" ] \
    || fail "第二轮结束后 origin（bare 仓）应该和本地 HEAD 一致"
) || exit 1
pass "稳态下（上一次发布已完全成功）再次发布同一模块：真实走 build/upload/bump，不会被误判成「待推送」而静默 no-op"

# ===========================================================================
# 场景 10：全新模块首发——manifest 里完全没有该模块任何行时，唯一合法登记路径是
# publish.sh register-module：原子写入未发布声明行（每架构一行，version/artifact/
# sha256/source_sha 全为 "-"），发布事务从声明行读目标架构矩阵，
# publish_apply_arch_matrix_manifest_update 的既有 "(module,arch) 键更新" 语义把
# 声明行原地替换成真实行，不需要额外的"插入新行"能力。
# ===========================================================================
CASE10="$TEST_ROOT/case10"
mkdir -p "$CASE10"
manifest_fixture10="$CASE10/manifest.fixture.tsv"
setup_src_repo "$CASE10/src/dbdog-web"
source_sha10="$(git -C "$CASE10/src/dbdog-web" rev-parse --short=7 HEAD)"
# 混入一个已发布的无关模块，证明登记新模块不会挪动/触碰它的行。
write_manifest "$manifest_fixture10" "$OLD_VERSION" "$source_sha10"
setup_release_repo "$CASE10/release" "$CASE10/release-bare.git" "$manifest_fixture10"

(
  DBDOG_HOME="$CASE10/home"
  RELEASE_DIR="$CASE10/release"
  SRC_ROOT="$CASE10/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE10/build-work"
  REPO_ROOT="$CASE10/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_STATE_DIR="$CASE10/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"

  # ---- 10a：register-module 参数校验（不接触 git，纯本地拒绝）----
  if (cmd_register_module) >"$CASE10/badargs-none.log" 2>&1; then
    fail "register-module 不带任何参数本应报用法错误却成功了"
  fi
  if (cmd_register_module ddprof) >"$CASE10/badargs-partial.log" 2>&1; then
    fail "register-module 只给 module 本应报用法错误却成功了"
  fi
  if (cmd_register_module ddprof bogus-kind dbhost no --arch aarch64) \
      >"$CASE10/badargs-kind.log" 2>&1; then
    fail "register-module 接受了非法 kind"
  fi
  grep -Fq 'kind 只能是' "$CASE10/badargs-kind.log" \
    || { sed -n '1,40p' "$CASE10/badargs-kind.log" >&2; fail "非法 kind 的报错不清楚"; }
  if (cmd_register_module ddprof third-party bogus-target no --arch aarch64) \
      >"$CASE10/badargs-target.log" 2>&1; then
    fail "register-module 接受了非法 target"
  fi
  if (cmd_register_module ddprof third-party dbhost bogus-service --arch aarch64) \
      >"$CASE10/badargs-service.log" 2>&1; then
    fail "register-module 接受了非法 service"
  fi
  if (cmd_register_module ddprof third-party dbhost no) >"$CASE10/badargs-noarch.log" 2>&1; then
    fail "register-module 在没有任何 --arch 时本应拒绝却成功了"
  fi
  if (cmd_register_module ddprof third-party dbhost no --arch aarch64 --arch aarch64) \
      >"$CASE10/badargs-duparch.log" 2>&1; then
    fail "register-module 接受了重复的 --arch"
  fi
  if (cmd_register_module ddprof third-party dbhost no --arch riscv64) \
      >"$CASE10/badargs-badarch.log" 2>&1; then
    fail "register-module 接受了不支持的架构"
  fi
  if (cmd_register_module '../evil' third-party dbhost no --arch aarch64) \
      >"$CASE10/badargs-badname.log" 2>&1; then
    fail "register-module 接受了不安全的模块名"
  fi
  pass "register-module 拒绝缺参数/非法 kind-target-service/零架构/重复架构/不支持架构/不安全模块名"

  # 评审 Important 3：noarch 不能和具体架构（aarch64/x86_64）混登记——manifest_all_rows
  # 是所有写入者共享的唯一校验点，register-module 应该借由它自然被拦，不需要自己另开
  # 一套重复校验。
  if (cmd_register_module noarch-mix third-party stack no --arch aarch64 --arch noarch) \
      >"$CASE10/badargs-noarchmix.log" 2>&1; then
    fail "register-module 接受了同一次调用里 aarch64 与 noarch 混用"
  fi
  # manifest_all_rows 自己的 die() 直接 exit，先于 cmd_register_module 那句包装
  # 用的 die 生效（同 cmd_migrate_manifest_v2 里一样的既有模式：包装 die 本身在这条
  # 失败路径下永远到不了，manifest_all_rows 自己的诊断信息才是真正打印出来的那条）。
  grep -Fq '不得混用 noarch 与具体架构' "$CASE10/badargs-noarchmix.log" \
    || { sed -n '1,40p' "$CASE10/badargs-noarchmix.log" >&2; fail "noarch 混用被拒绝，但没有指向 manifest_all_rows 这道共享校验"; }
  if manifest_all_rows | awk -F'\t' '$1=="noarch-mix"{f=1} END{exit(f?0:1)}'; then
    fail "noarch 混用注册失败后，manifest 里不应该残留任何 noarch-mix 的行"
  fi
  pass "register-module 在同一次调用里混用 noarch 与具体架构时被 manifest_all_rows 这道共享校验拒绝，且不残留任何声明行"

  before_register_hashes="$(hashes_of "$RELEASE_DIR")"
  before_register_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"

  # 上面的失败尝试一个字节都不该落地。
  after_badargs_hashes="$(hashes_of "$RELEASE_DIR")"
  [ "$before_register_hashes" = "$after_badargs_hashes" ] \
    || fail "register-module 参数校验失败的尝试改动了 manifest.tsv/README.md"

  # ---- 10b：正式登记 ddprof（third-party/dbhost/no，aarch64+x86_64）----
  cmd_register_module ddprof third-party dbhost no --arch aarch64 --arch x86_64 \
    >"$CASE10/register.log" 2>&1 \
    || { sed -n '1,80p' "$CASE10/register.log" >&2; fail "register-module 登记新模块本应成功却失败了"; }

  [ "$(manifest_get ddprof 2 aarch64)" = third-party ] || fail "登记后 ddprof/aarch64 的 kind 不对"
  [ "$(manifest_get ddprof 3 aarch64)" = dbhost ] || fail "登记后 ddprof/aarch64 的 target 不对"
  [ "$(manifest_get ddprof 4 aarch64)" = no ] || fail "登记后 ddprof/aarch64 的 service 不对"
  [ "$(manifest_get ddprof 5 aarch64)" = '-' ] || fail "登记后 ddprof/aarch64 的 version 应该是 -"
  [ "$(manifest_get ddprof 6 aarch64)" = '-' ] || fail "登记后 ddprof/aarch64 的 artifact 应该是 -"
  [ "$(manifest_get ddprof 7 aarch64)" = '-' ] || fail "登记后 ddprof/aarch64 的 sha256 应该是 -"
  [ "$(manifest_get ddprof 8 aarch64)" = '-' ] || fail "登记后 ddprof/aarch64 的 source_sha 应该是 -"
  [ "$(manifest_get ddprof 5 x86_64)" = '-' ] || fail "登记后 ddprof/x86_64 的 version 应该是 -"
  pass "register-module 原子写入两条未发布声明行（kind/target/service 真实，version/artifact/sha256/source_sha 全为 -）"

  [ "$(manifest_get dbdog-web 5 aarch64)" = "$OLD_VERSION" ] \
    || fail "登记新模块不应该改动无关模块 dbdog-web 的既有行"
  pass "登记新模块不触碰 manifest 里已存在的无关模块行"

  grep -Fq '| ddprof | third-party | DB 主机 | - | - | aarch64 |' "$RELEASE_DIR/README.md" \
    || { sed -n '1,50p' "$RELEASE_DIR/README.md" >&2; fail "README 版本表没有把未发布行的版本列如实显示为 -"; }
  pass "regen_readme 把未发布声明行的版本列如实显示为 -（不做特殊标记）"

  after_register_head="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$after_register_head" != "$before_register_head" ] \
    || fail "register-module 成功后应该产生一个新的 git commit"
  [ "$(git -C "$RELEASE_DIR" rev-list --count "${before_register_head}..${after_register_head}")" = 1 ] \
    || fail "register-module 应该恰好产生一个 commit"
  [ "$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD)" = 'register: ddprof (aarch64,x86_64) unpublished' ] \
    || fail "register-module 的 commit message 不符合约定: $(git -C "$RELEASE_DIR" log -1 --format=%s HEAD)"
  [ "$(git -C "$CASE10/release-bare.git" rev-parse refs/heads/main)" = "$after_register_head" ] \
    || fail "register-module 应该已经 push 到 origin（bare 仓）"
  pass "register-module 的登记是单个已推送的 commit（经发布器改 manifest 的合法路径）"

  [ "$(publish_arches_for_module ddprof | tr '\n' ' ')" = 'aarch64 x86_64 ' ] \
    || fail "publish_arches_for_module 未能从刚登记的声明行读出目标架构矩阵"
  pass "publish_arches_for_module 从未发布声明行正确读出 ddprof 的目标架构矩阵"

  # ---- 10c：重复登记必须拒绝，且不产生任何新改动/commit ----
  if (cmd_register_module ddprof third-party dbhost no --arch aarch64) \
      >"$CASE10/register-dup.log" 2>&1; then
    fail "对已登记模块重复调用 register-module 本应拒绝却成功了"
  fi
  grep -Fq '已经' "$CASE10/register-dup.log" \
    || { sed -n '1,40p' "$CASE10/register-dup.log" >&2; fail "重复登记的报错信息不清楚"; }
  [ "$(git -C "$RELEASE_DIR" rev-parse HEAD)" = "$after_register_head" ] \
    || fail "重复登记的失败尝试不应该产生任何新 commit"
  pass "对已登记模块重复调用 register-module 拒绝，且不产生任何新改动"

  # ---- 10d：登记之后走完整的架构矩阵发布事务（真实驱动 build_one_arch/
  # publish_commit_arch_matrix），验证声明行被原子替换成真实行，且只产生一个
  # 额外的发布 commit（登记的 commit 已经在 10b 里单独产生）。----
  DDPROF_VERSION="0.26.0"
  FAKE_ASSET_NAME_AARCH64="ddprof-$DDPROF_VERSION-aarch64.tar.gz"
  FAKE_ASSET_NAME_X86_64="ddprof-$DDPROF_VERSION-x86_64.tar.gz"
  FAKE_SIZE_AARCH64=3333
  FAKE_SIZE_X86_64=4444
  FAKE_SHA_AARCH64="$(printf 'c%.0s' $(seq 1 64))"
  FAKE_SHA_X86_64="$(printf 'd%.0s' $(seq 1 64))"
  FAKE_VERSION="$DDPROF_VERSION"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/ddprof/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/ddprof/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_ASSET_NAME_AARCH64 FAKE_ASSET_NAME_X86_64 FAKE_SIZE_AARCH64 FAKE_SIZE_X86_64 \
    FAKE_SHA_AARCH64 FAKE_SHA_X86_64 FAKE_VERSION FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=success

  # 三方件的版本由配方探测，真实 cmd_publish 对非 first-party 模块传空版本——这里
  # 用同样的空串驱动 run_txn_pipeline，镜像生产路径。
  (run_txn_pipeline ddprof "") >"$CASE10/publish.log" 2>&1 \
    || { sed -n '1,200p' "$CASE10/publish.log" >&2; fail "全新模块首发的架构矩阵发布本应成功却失败了"; }
  pass "登记后紧接着的架构矩阵发布（两个架构）成功完成"

  [ "$(manifest_get ddprof 5 aarch64)" = "$DDPROF_VERSION" ] \
    || fail "发布完成后 ddprof/aarch64 的声明行未被替换成真实版本"
  [ "$(manifest_get ddprof 6 aarch64)" = "$FAKE_ASSET_NAME_AARCH64" ] \
    || fail "发布完成后 ddprof/aarch64 的声明行未被替换成真实 artifact"
  [ "$(manifest_get ddprof 7 aarch64)" = "$FAKE_SHA_AARCH64" ] \
    || fail "发布完成后 ddprof/aarch64 的声明行未被替换成真实 sha256"
  [ "$(manifest_get ddprof 5 x86_64)" = "$DDPROF_VERSION" ] \
    || fail "发布完成后 ddprof/x86_64 的声明行未被替换成真实版本"
  [ "$(manifest_get ddprof 6 x86_64)" = "$FAKE_ASSET_NAME_X86_64" ] \
    || fail "发布完成后 ddprof/x86_64 的声明行未被替换成真实 artifact"
  # kind/target/service（register-module 写入的列）在整个替换过程中原样保留。
  [ "$(manifest_get ddprof 2 aarch64)" = third-party ] \
    || fail "发布完成后 ddprof 的 kind 不应该被发布事务改动"
  [ "$(manifest_get ddprof 3 aarch64)" = dbhost ] \
    || fail "发布完成后 ddprof 的 target 不应该被发布事务改动"
  pass "publish_apply_arch_matrix_manifest_update 的既有 (module,arch) 更新语义把两条声明行原子替换成真实行，kind/target/service 保持不变"

  grep -Fq '| ddprof | third-party | DB 主机 | 0.26.0 |' "$RELEASE_DIR/README.md" \
    || { sed -n '1,50p' "$RELEASE_DIR/README.md" >&2; fail "README 版本表没有更新为真实版本"; }
  pass "regen_readme 把已发布的 ddprof 显示为真实版本"

  final_head10="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$final_head10" != "$after_register_head" ] \
    || fail "架构矩阵发布完成后应该产生新的 commit"
  [ "$(git -C "$RELEASE_DIR" rev-list --count "${after_register_head}..${final_head10}")" = 1 ] \
    || fail "登记之后的架构矩阵发布应该恰好只产生一个 commit"
  [ "$(git -C "$RELEASE_DIR" log -1 --format=%s "$final_head10")" = "publish: ddprof@$DDPROF_VERSION" ] \
    || fail "架构矩阵发布的 commit message 不符合既有约定"
  [ "$(git -C "$CASE10/release-bare.git" rev-parse refs/heads/main)" = "$final_head10" ] \
    || fail "架构矩阵发布完成后应该已经 push 到 origin（bare 仓）"
  pass "全新模块首发全过程（register-module 一个 commit + 架构矩阵发布一个 commit）与既有事务保证完全一致"
) || exit 1
pass "全新模块首发：register-module 原子登记未发布声明行 → 架构矩阵发布把声明行原子替换成真实行，全程遵守既有事务不变式"

# ===========================================================================
# 场景 11（评审 Important 2）：manifest 里任何一个"已登记未发布"模块（声明行，
# artifact="-"）都不能让 prune_modules_to_manifest 整体 die——它枚举全部模块时
# 会走到未发布模块那一行，之前的实现要求 artifact 匹配 "<module>-[0-9]*"，
# "-" 直接不匹配，导致整仓库的 prune 从此永久报错，直到该模块真正发布为止。
# 未发布模块没有任何资产需要保护/清理，命中 artifact="-" 应该直接跳过。
# ===========================================================================
CASE11="$TEST_ROOT/case11"
mkdir -p "$CASE11/release"
manifest11="$CASE11/release/manifest.tsv"
PRUNE_SHA_A="$(printf 'e%.0s' $(seq 1 64))"
{
  # 已发布模块：真实资产已经存在于（模拟）产物桶，prune 应该识别为"当前引用"，
  # 既不清理也不报错。
  printf 'published-mod\tthird-party\tstack\tno\t1.0.0\tpublished-mod-1.0.0-aarch64.tar.gz\t%s\t-\taarch64\n' \
    "$PRUNE_SHA_A"
  # 未发布模块：register-module 登记后、真正发布前的声明行，artifact="-"。
  printf 'unpublished-mod\tthird-party\tdbhost\tno\t-\t-\t-\t-\taarch64\n'
} >"$manifest11"

(
  RELEASE_DIR="$CASE11/release"
  DBDOG_HOME="$CASE11/home"
  MANIFEST="$manifest11"
  export RELEASE_DIR DBDOG_HOME MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  FAKE_STATE_DIR="$CASE11/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR" FAKE_GH_TOKEN="unused-in-dry-run"
  # 让共享假 gh 的资产清单只报告 published-mod 已经真实存在的那一份资产
  # （aarch64 槽位复用共享脚本；unpublished-mod 完全没有资产，不占用 x86_64 槽位）。
  printf 'published-mod-1.0.0-aarch64.tar.gz\t2048\t%s\n' "$PRUNE_SHA_A" \
    >"$FAKE_STATE_DIR/asset-aarch64"

  prune_out="$CASE11/prune.log"
  # prune_modules_to_manifest 内部失败走 die()（直接 exit），不是普通返回非零状态——
  # 必须用子 shell 包住调用本身，否则失败时会把 exit 一路带到这层 CASE11 子 shell，
  # 跳过下面的 || 兜底，连诊断信息都来不及打印（同 test-publish-architecture-
  # transaction.sh 里 resolve_build_host_for_arch 等其它 die 调用点的既有教训）。
  if ! (prune_modules_to_manifest 0 published-mod unpublished-mod) >"$prune_out" 2>&1; then
    sed -n '1,80p' "$prune_out" >&2
    fail "manifest 含未发布模块（artifact=-）时 prune 试运行本应成功却失败了"
  fi
  grep -Fq '无可清理产物' "$prune_out" \
    || { sed -n '1,80p' "$prune_out" >&2; fail "prune 试运行应该报告没有可清理的产物（唯一真实资产仍被 published-mod 引用）"; }
  if grep -Fq 'manifest 当前资产名不属于该模块' "$prune_out"; then
    fail "prune 仍然把未发布模块的 artifact=\"-\" 当成了非法资产名"
  fi
) || exit 1
pass "manifest 里存在已登记未发布的模块（artifact=\"-\"）时，prune 试运行正确跳过它、不报错，且已发布模块的真实资产仍被正确保护"

# ===========================================================================
# 场景 12（终审 Important 1）：裸跑（cmd_publish 不点名任何模块，mods 为空靠
# changed_first_party 自动推导）在 push 失败后再次裸跑重试，必须走
# publish_resume_pending_push 补推同一个提交，不能被 changed_first_party 判定
# "无变更"而静默 no-op——CASE8/CASE9 只覆盖点名重跑（run_txn_pipeline 直接把
# 模块名传给 publish_resume_pending_push），从未走过 cmd_publish 本体的裸跑分支
# （mods 为空 → changed_first_party → 空则直接 exit 0）；这里必须直接调用
# cmd_publish 才能复现/覆盖这个 bug——第一次裸跑成功 commit 后，manifest 的
# source_sha 已经被更新为当前源码 sha，第二次裸跑时 changed_first_party 会认为
# "没有变更"，问题就在这个夹缝里发生。
# ===========================================================================
CASE12="$TEST_ROOT/case12"
mkdir -p "$CASE12"
manifest_fixture12="$CASE12/manifest.fixture.tsv"

setup_tracked_src_repo() { # setup_tracked_src_repo <dir> <bare>；与 setup_src_repo 的区别是
  # 额外建一个 bare remote 并 push——cmd_publish 裸跑分支会先跑
  # refresh_first_party_origins/assert_first_party_checkouts_current，两者都要求
  # 本地 HEAD 与 origin/main 完全一致，不能像其它场景那样只建本地仓、不建远端。
  local dir="$1" bare="$2"
  git init -q --bare "$bare"
  git init -q "$dir"
  git -C "$dir" config user.name dbdog-contract-test
  git -C "$dir" config user.email dbdog-contract-test@example.invalid
  git -C "$dir" remote add origin "$bare"
  printf 'dbdog-web source under test\n' >"$dir/main.go"
  git -C "$dir" add -A
  git -C "$dir" commit -qm 'source under test'
  git -C "$dir" branch -M main
  git -C "$dir" push -q -u origin main
}

setup_tracked_src_repo "$CASE12/src/dbdog-web" "$CASE12/src-bare/dbdog-web.git"
old_source_sha12="$(git -C "$CASE12/src/dbdog-web" rev-parse --short=7 HEAD)"
# 制造"源码已有未发布变更"的起点：多提交一次并推送，让 live_sha 领先 manifest
# 记录的 source_sha，这样第一次裸跑的 changed_first_party 才能自动推导出 dbdog-web。
printf 'more work\n' >>"$CASE12/src/dbdog-web/main.go"
git -C "$CASE12/src/dbdog-web" commit -qam 'more work, ready to publish'
git -C "$CASE12/src/dbdog-web" push -q origin main

write_manifest "$manifest_fixture12" "$OLD_VERSION" "$old_source_sha12"
setup_release_repo "$CASE12/release" "$CASE12/release-bare.git" "$manifest_fixture12"
allow_push12="$CASE12/allow-push"
write_gate_hook "$CASE12/release" pre-push "$allow_push12"

(
  DBDOG_HOME="$CASE12/home"
  RELEASE_DIR="$CASE12/release"
  SRC_ROOT="$CASE12/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  BUILD_HOST_AARCH64="fake-aarch64-builder"
  BUILD_HOST_X86_64="fake-x86_64-builder"
  BUILD_HOST=""
  BUILD_WORK="$CASE12/build-work"
  REPO_ROOT="$CASE12/repo-root"
  TOOL_PATH=""
  PUBLISH_UPLOAD_MAX_ATTEMPTS=1
  PUBLISH_UPLOAD_RETRY_DELAY_SECONDS=0

  FAKE_STATE_DIR="$CASE12/state"
  mkdir -p "$FAKE_STATE_DIR"
  export FAKE_STATE_DIR FAKE_RELEASE_DIR="$RELEASE_DIR"
  FAKE_ASSET_NAME_AARCH64="dbdog-web-$NEW_VERSION-aarch64.tar.gz"
  FAKE_ASSET_NAME_X86_64="dbdog-web-$NEW_VERSION-x86_64.tar.gz"
  FAKE_SIZE_AARCH64=5555
  FAKE_SIZE_X86_64=6666
  FAKE_SHA_AARCH64="$(printf 'f%.0s' $(seq 1 64))"
  FAKE_SHA_X86_64="$(printf '1%.0s' $(seq 1 64))"
  FAKE_VERSION="$NEW_VERSION"
  FAKE_REMOTE_PATH_AARCH64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_AARCH64"
  FAKE_REMOTE_PATH_X86_64="$BUILD_WORK/dbdog-web/out/$FAKE_ASSET_NAME_X86_64"
  export FAKE_ASSET_NAME_AARCH64 FAKE_ASSET_NAME_X86_64 FAKE_SIZE_AARCH64 FAKE_SIZE_X86_64 \
    FAKE_SHA_AARCH64 FAKE_SHA_X86_64 FAKE_VERSION FAKE_REMOTE_PATH_AARCH64 FAKE_REMOTE_PATH_X86_64
  export FAKE_BUILD_X86_64_FAIL=0
  export FAKE_UPLOAD_OUTCOME_aarch64=success
  export FAKE_UPLOAD_OUTCOME_x86_64=success

  before_head12="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  before_origin12="$(git -C "$CASE12/release-bare.git" rev-parse refs/heads/main)"

  # 第一次裸跑：changed_first_party 应自动识别出 dbdog-web 有未发布变更，
  # build/upload/commit 全部成功，push 被 pre-push hook 挡住后中断。
  if (cmd_publish --yes) >"$CASE12/round1.log" 2>&1; then
    sed -n '1,200p' "$CASE12/round1.log" >&2
    fail "裸跑第一次执行本应在 push 阶段被 pre-push hook 挡住却成功完成"
  fi
  grep -Fq 'blocked by test pre-push gate' "$CASE12/round1.log" \
    || { sed -n '1,200p' "$CASE12/round1.log" >&2; fail "裸跑第一次执行没有在预期的 pre-push hook 处失败"; }
  after_round1_head12="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$after_round1_head12" != "$before_head12" ] \
    || fail "裸跑第一次执行应该已经本地 commit 成功，HEAD 应该已经前进"
  [ "$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD)" = "publish: dbdog-web@$NEW_VERSION" ] \
    || fail "裸跑第一次执行后本地 HEAD 的提交信息应该是本次发布提交"
  [ "$(git -C "$CASE12/release-bare.git" rev-parse refs/heads/main)" = "$before_origin12" ] \
    || fail "push 被挡住后 origin（bare 仓）不应该有任何变化"
  [ "$(manifest_get dbdog-web 8 aarch64)" = "$(git -C "$CASE12/src/dbdog-web" rev-parse --short=7 HEAD)" ] \
    || fail "第一次裸跑后 manifest 的 source_sha 应该已经更新为当前源码 sha（这正是第二次裸跑会被 changed_first_party 判定为「无变更」的原因）"
  pass "裸跑第一次执行：changed_first_party 自动识别出 dbdog-web 有变更，build/upload/manifest/commit 全部成功，push 被 pre-push hook 挡住后中断"

  # 放开 pre-push hook。这是本 finding 的核心复现点：源码没有新变更（第一次裸跑
  # 已把 manifest 的 source_sha 更新成当前值），changed_first_party 对 dbdog-web
  # 会返回"无变更"，mods 为空——修复前 cmd_publish 会直接打印"没有变更的一方模块"
  # 后 exit 0，origin 永远停在 push 失败前的状态，是静默 no-op；修复后必须识别出
  # HEAD 本身就是一个待推送的 "publish: dbdog-web@version" 提交，直接补推。
  : >"$allow_push12"
  (cmd_publish --yes) >"$CASE12/round2.log" 2>&1 \
    || { sed -n '1,200p' "$CASE12/round2.log" >&2; fail "裸跑第二次执行（放开 pre-push hook 后）未能完成发布"; }
  grep -Fq '只是尚未推送；直接补 push' "$CASE12/round2.log" \
    || { sed -n '1,200p' "$CASE12/round2.log" >&2; fail "裸跑第二次执行没有留下识别出「commit 已完成、只差 push」状态的日志（很可能回归成「没有变更的一方模块」静默 no-op）"; }
  ! grep -Fq '没有变更的一方模块' "$CASE12/round2.log" \
    || fail "裸跑第二次执行不应该把「待推送」状态误判成「没有变更」而静默跳过"
  pass "裸跑第二次执行：正确识别出「commit 已完成、只差 push」的状态并补推，没有被 changed_first_party 判定成无变更而静默跳过"

  final_head12="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$final_head12" = "$after_round1_head12" ] \
    || fail "裸跑第二次执行不应该产生新的 commit，本地 HEAD 应该和第一次执行后完全一样（重推同一个提交）"
  [ "$(git -C "$CASE12/release-bare.git" rev-parse refs/heads/main)" = "$final_head12" ] \
    || fail "裸跑第二次执行后 origin（bare 仓）应该和本地 HEAD 一致（即 finding 描述的「origin/main 静默落后」问题已修复）"
  [ "$(<"$FAKE_STATE_DIR/count-upload-aarch64")" = 1 ] \
    || fail "裸跑第二次执行不应该重新上传 aarch64"
  [ "$(<"$FAKE_STATE_DIR/count-upload-x86_64")" = 1 ] \
    || fail "裸跑第二次执行不应该重新上传 x86_64"
  [ "$(<"$FAKE_STATE_DIR/count-build-aarch64")" = 1 ] \
    || fail "裸跑第二次执行不应该重新构建 aarch64（不应该重建矩阵）"
  [ "$(<"$FAKE_STATE_DIR/count-build-x86_64")" = 1 ] \
    || fail "裸跑第二次执行不应该重新构建 x86_64（不应该重建矩阵）"
) || exit 1
pass "裸跑（不点名模块）push 失败后再次裸跑重试：正确补推同一提交，零重建矩阵、零重复上传，origin 不再静默落后"

# ===========================================================================
# 场景 13：register-arch 给已发布模块补未发布架构声明行；SKIP_PUSH 只本地 commit。
# ===========================================================================
CASE13="$TEST_ROOT/case13"
mkdir -p "$CASE13"
manifest_fixture13="$CASE13/manifest.fixture.tsv"
PUBLISHED_SHA13="$(printf 'f%.0s' $(seq 1 64))"
{
  printf '# test\n'
  printf 'expandme\tfirst-party\tdbhost\tno\t1.0.0\texpandme-1.0.0-aarch64.tar.gz\t%s\tabc1234\taarch64\n' \
    "$PUBLISHED_SHA13"
} >"$manifest_fixture13"
setup_release_repo "$CASE13/release" "$CASE13/release-bare.git" "$manifest_fixture13"

(
  DBDOG_HOME="$CASE13/home"
  RELEASE_DIR="$CASE13/release"
  SRC_ROOT="$CASE13/src"
  MANIFEST="$RELEASE_DIR/manifest.tsv"
  export DBDOG_HOME RELEASE_DIR SRC_ROOT MANIFEST
  # shellcheck source=publish/publish.sh
  source "$SCRIPTS_DIR/publish/publish.sh"

  before_arch="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  (cmd_register_arch expandme --arch x86_64) >"$CASE13/register-arch.log" 2>&1 \
    || { sed -n '1,80p' "$CASE13/register-arch.log" >&2; fail "register-arch 给已发布模块补 x86_64 失败"; }
  [ "$(manifest_get expandme 5 aarch64)" = '1.0.0' ] \
    || fail "register-arch 不应改动已发布 aarch64 行的 version"
  [ "$(manifest_get expandme 5 x86_64)" = '-' ] \
    || fail "register-arch 应为 x86_64 写入未发布声明行"
  [ "$(manifest_module_field expandme 5)" = '1.0.0' ] \
    || fail "manifest_module_field 在混合行下应优先返回已发布 version"
  [ "$(manifest_arches expandme | tr '\n' ' ')" = 'aarch64 x86_64 ' ] \
    || fail "register-arch 后 manifest_arches 应包含两个架构"
  [ "$(git -C "$RELEASE_DIR" log -1 --format=%s HEAD)" = 'register-arch: expandme (+x86_64) unpublished' ] \
    || fail "register-arch commit message 不符合约定"
  after_arch="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
  [ "$after_arch" != "$before_arch" ] || fail "register-arch 应产生新 commit"
  [ "$(git -C "$CASE13/release-bare.git" rev-parse refs/heads/main)" = "$after_arch" ] \
    || fail "register-arch 默认应 push 到 origin"
  pass "register-arch 给已发布模块追加未发布架构声明行并 push"

  if (cmd_register_arch expandme --arch x86_64) >"$CASE13/register-arch-dup.log" 2>&1; then
    fail "重复 register-arch 同一架构本应拒绝"
  fi
  pass "register-arch 拒绝重复登记同一架构"

  before_skip_origin="$(git -C "$CASE13/release-bare.git" rev-parse refs/heads/main)"
  (DBDOG_PUBLISH_SKIP_PUSH=1 cmd_register_module other first-party dbhost no --arch aarch64 --arch x86_64) \
    >"$CASE13/skip-push.log" 2>&1 \
    || { sed -n '1,80p' "$CASE13/skip-push.log" >&2; fail "DBDOG_PUBLISH_SKIP_PUSH=1 的 register-module 失败"; }
  grep -Fq '跳过 git push' "$CASE13/skip-push.log" \
    || { sed -n '1,40p' "$CASE13/skip-push.log" >&2; fail "SKIP_PUSH 没有留下跳过 push 的日志"; }
  [ "$(git -C "$CASE13/release-bare.git" rev-parse refs/heads/main)" = "$before_skip_origin" ] \
    || fail "SKIP_PUSH 后 origin 不应前进"
  pass "DBDOG_PUBLISH_SKIP_PUSH=1 时 register-module 只本地 commit 不 push"
) || exit 1
pass "register-arch 扩展已发布模块架构矩阵 + SKIP_PUSH 本地登记"

printf 'ALL PASS: 47 publish architecture transaction contract tests\n'
