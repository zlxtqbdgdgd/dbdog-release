#!/usr/bin/env bash
# 本机可重复测试：Agent 官方版本基线、显式源码锚与 -dbdog.N 修订策略。
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-publish-agent.XXXXXX")"
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dbdog-publish-agent.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

init_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name dbdog-contract-test
  git -C "$repo" config user.email dbdog-contract-test@example.invalid
}

commit_all() {
  local repo="$1" message="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$message"
}

write_baseline() {
  local file="$1" agent_official="$2" agent_source="$3" core_official="$4" core_source="$5"
  mkdir -p "$(dirname "$file")"
  {
    printf 'schema\tdbdog-agent-release-baseline/v1\n'
    printf 'agent_official_version\t7.81.0\n'
    printf 'agent_official_tag\t7.81.0\n'
    printf 'agent_official_commit\t%s\n' "$agent_official"
    printf 'agent_release_source_commit\t%s\n' "$agent_source"
    printf 'integrations_core_official_version\t7.81.0\n'
    printf 'integrations_core_official_tag\t7.81.0\n'
    printf 'integrations_core_official_commit\t%s\n' "$core_official"
    printf 'integrations_core_release_source_commit\t%s\n' "$core_source"
    printf 'official_version_format\tthree_segment_semver\n'
    printf 'official_tag_must_equal_version\ttrue\n'
    printf 'official_commit_must_be_tag_target\ttrue\n'
    printf 'official_commit_must_be_release_source_ancestor\ttrue\n'
    printf 'release_source_commit_must_be_head_ancestor\ttrue\n'
    printf 'release_prefix_key\tagent_official_version\n'
    printf 'dbdog_version_template\t${agent_official_version}-dbdog.${revision}\n'
    printf 'dbdog_revision_initial\t1\n'
    printf 'dbdog_revision_reset_on_official_baseline_change\ttrue\n'
    printf 'release_build_must_use_explicit_source_commits\ttrue\n'
    printf 'release_json_current_milestone_is_prefix_authority\tfalse\n'
  } >"$file"
}

fixture_root="$TEST_ROOT/src"
agent_repo="$fixture_root/dbdog-agent"
core_repo="$fixture_root/dbdog-agent-core"
init_repo "$agent_repo"
init_repo "$core_repo"

printf 'official agent\n' >"$agent_repo/source.txt"
commit_all "$agent_repo" 'official agent'
agent_official="$(git -C "$agent_repo" rev-parse HEAD)"
git -C "$agent_repo" tag 7.81.0
printf 'private agent release source\n' >>"$agent_repo/source.txt"
commit_all "$agent_repo" 'private agent release source'
agent_source="$(git -C "$agent_repo" rev-parse HEAD)"

printf 'official core\n' >"$core_repo/source.txt"
commit_all "$core_repo" 'official core'
core_official="$(git -C "$core_repo" rev-parse HEAD)"
git -C "$core_repo" tag 7.81.0
printf 'private core release source\n' >>"$core_repo/source.txt"
commit_all "$core_repo" 'private core release source'
core_source="$(git -C "$core_repo" rev-parse HEAD)"
printf 'later core work, deliberately not shipped\n' >>"$core_repo/source.txt"
commit_all "$core_repo" 'later core work'
git -C "$core_repo" update-ref refs/remotes/origin/main HEAD

baseline="$agent_repo/dbdog-deploy/RELEASE-BASELINE.tsv"
write_baseline "$baseline" "$agent_official" "$agent_source" "$core_official" "$core_source"
commit_all "$agent_repo" 'record release baseline'
git -C "$agent_repo" update-ref refs/remotes/origin/main HEAD

manifest="$TEST_ROOT/manifest.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  dbdog-agent first-party dbhost no 7.81.1-dbdog.3 \
  dbdog-agent-7.81.1-dbdog.3-aarch64.tar.gz deadbeef \
  "agent:${agent_source:0:7},core:${core_source:0:7}" >"$manifest"

SRC_ROOT="$fixture_root"
RELEASE_DIR="$RELEASE_ROOT"
MANIFEST="$manifest"
DBDOG_HOME="$TEST_ROOT/home"
# shellcheck source=publish/publish.sh
source "$SCRIPTS_DIR/publish/publish.sh"

load_agent_release_baseline
warn_agent_unshipped_heads 2>"$TEST_ROOT/baseline-warnings"
[ "$AGENT_RELEASE_SOURCE_COMMIT" = "$agent_source" ] || fail 'Agent 出货源码锚读取错误'
[ "$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT" = "$core_source" ] || fail 'Core 出货源码锚读取错误'
grep -Fq 'HEAD 已超前' "$TEST_ROOT/baseline-warnings" || fail 'HEAD 超前没有明确告警'
pass '官方 tag/commit、祖先关系、origin/main 与显式出货源码锚均通过验证'

fingerprint="$(live_sha dbdog-agent 2>/dev/null)"
[ "$fingerprint" = "agent:${agent_source:0:7},core:${core_source:0:7}" ] \
  || fail "live_sha 使用了 HEAD 而不是显式出货源码锚: $fingerprint"
pass 'Agent source_sha 只记录显式出货源码锚，HEAD 超前不会混入产物'

[ "$(bump_version dbdog-agent 7.81.0-dbdog.3 minor 2>/dev/null)" = 7.81.0-dbdog.4 ] \
  || fail '同一官方基线没有递增本地打包修订'
[ "$(bump_version dbdog-agent 7.81.1-dbdog.9 patch 2>/dev/null)" = 7.81.0-dbdog.1 ] \
  || fail '官方基线变化没有把本地打包修订重置为 1'
if (bump_version dbdog-agent 7.81.0-rc.6 >/dev/null 2>&1); then
  fail '非发布版本格式被当成了合法 manifest 版本'
fi
pass '发布号固定为官方三段 tag 前缀 + -dbdog.N，换基线从 1 重置'

[ "$(changed_first_party 2>/dev/null)" = dbdog-agent ] \
  || fail 'source_sha 未变但版本前缀过时时，没有判定 Agent 需要发布'
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  dbdog-agent first-party dbhost no 7.81.0-dbdog.3 \
  dbdog-agent-7.81.0-dbdog.3-aarch64.tar.gz deadbeef \
  "agent:${agent_source:0:7},core:${core_source:0:7}" >"$manifest"
[ -z "$(changed_first_party 2>/dev/null)" ] \
  || fail '源码锚和官方版本前缀都一致时仍误报需要发布'
pass '变更检测同时比较显式源码锚和官方版本前缀'

bad_dirty="$TEST_ROOT/bad-dirty"
cp -R "$fixture_root" "$bad_dirty"
printf 'unknown_field\tunexpected\n' >>"$bad_dirty/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv"
if (SRC_ROOT="$bad_dirty" load_agent_release_baseline) >/dev/null 2>&1; then
  fail '有未提交修改的发布基线未被拒绝'
fi
pass '发布基线有未提交修改时 fail closed'

bad_policy="$TEST_ROOT/bad-policy"
cp -R "$fixture_root" "$bad_policy"
awk -F '\t' -v OFS='\t' \
  '$1 == "release_json_current_milestone_is_prefix_authority" {$2 = "true"} {print}' \
  "$bad_policy/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv" \
  >"$bad_policy/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv.tmp"
mv "$bad_policy/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv.tmp" \
  "$bad_policy/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv"
commit_all "$bad_policy/dbdog-agent" 'invalid milestone authority'
git -C "$bad_policy/dbdog-agent" update-ref refs/remotes/origin/main HEAD
if (SRC_ROOT="$bad_policy" load_agent_release_baseline) >/dev/null 2>&1; then
  fail 'current_milestone 被允许作为版本前缀权威'
fi
pass 'release.json current_milestone 不能成为发布版本基线'

bad_tag="$TEST_ROOT/bad-tag"
cp -R "$fixture_root" "$bad_tag"
awk -F '\t' -v OFS='\t' -v source="$agent_source" \
  '$1 == "agent_official_commit" {$2 = source} {print}' \
  "$bad_tag/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv" \
  >"$bad_tag/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv.tmp"
mv "$bad_tag/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv.tmp" \
  "$bad_tag/dbdog-agent/dbdog-deploy/RELEASE-BASELINE.tsv"
commit_all "$bad_tag/dbdog-agent" 'invalid official tag target'
git -C "$bad_tag/dbdog-agent" update-ref refs/remotes/origin/main HEAD
if (SRC_ROOT="$bad_tag" load_agent_release_baseline) >/dev/null 2>&1; then
  fail '官方 tag 与 commit 不一致时仍通过验证'
fi
pass '官方 tag 必须精确解析到登记 commit'

grep -Fq 'sha="$AGENT_RELEASE_SOURCE_COMMIT"' "$SCRIPTS_DIR/publish/publish.sh" \
  || fail 'build_one 未把 Agent 显式源码锚传给 recipe'
grep -Fq 'core="$INTEGRATIONS_CORE_RELEASE_SOURCE_COMMIT"' "$SCRIPTS_DIR/publish/publish.sh" \
  || fail 'build_one 未把 Core 显式源码锚传给 recipe'
if grep -Fq 'AGENT_BASE_VERSION' "$SCRIPTS_DIR/publish/publish.sh"; then
  fail 'publish.sh 仍保留本机 AGENT_BASE_VERSION fallback'
fi
pass '构建输入只使用基线源码锚，且不存在本机版本前缀 fallback'

grep -Fq 'if ! recipe_stdout="$(ssh "$BUILD_HOST"' "$SCRIPTS_DIR/publish/publish.sh" || \
  fail 'publish.sh 没有在截取结果行前保留远端 recipe 退出状态'
if grep -Fq 'bash -s <"$recipe" | tail -n1' "$SCRIPTS_DIR/publish/publish.sh"; then
  fail 'publish.sh 仍用 tail 成功状态掩盖远端 recipe 失败'
fi
awk '
  /DBDOG_AGENT_CACHE_ROOT=.*\\$/ {
    getline
    if ($0 ~ /\/usr\/bin\/bash .*VERIFY\.sh/) found=1
  }
  END { exit(found ? 0 : 1) }
' "$SCRIPTS_DIR/publish/recipes/dbdog-agent.sh" || \
  fail 'dependency seal env 命令仍可能被续行中的注释截断并污染 stdout'
pass '远端 recipe 失败状态不会被 tail 掩盖，seal 校验不会向结果通道泄漏环境'

printf 'ALL PASS: 9 Agent publish policy contract tests\n'
