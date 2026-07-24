#!/usr/bin/env bash
# 配方：dbdog-agent（omnibus rpm，内含 agent-core 的 GaussDB 补丁）。
# 输入 env：MODULE VERSION SHA CORE_SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH
#
# ⚠️ 尚未跑通（验证清单第 2 项）。omnibus 构建链需要在构建机一次性准备：
#   1. dbdog-agent 与 dbdog-agent-core 在 $REPO_ROOT 下有 clone；
#   2. 上游构建依赖（dda/invoke、omnibus 的 ruby 工具链、系统包）装好；
#   3. 摸清 fork 的构建入口（上游是 `dda inv omnibus.build` 一族，dbdog 补丁经
#      dbdog-agent-core/dbdog/apply-patches.sh 进入），把下面 die 替换为真实步骤；
#   4. 产物 rpm 重命名为 dbdog-agent-$VERSION-$ARCH.rpm 后按约定输出最后一行。
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"

die "agent 的 omnibus 构建配方尚未跑通——先在构建机手工走一遍 omnibus 构建，再把步骤固化进本配方（见文件头注释）。agent@$SHA core@$CORE_SHA"

# 跑通后的骨架（参考）：
# WORK="$BUILD_WORK/$MODULE"; mkdir -p "$WORK/out"
# checkout dbdog-agent@$SHA 与 dbdog-agent-core@$CORE_SHA → 应用补丁 → omnibus 构建
# cp <omnibus 产物>.rpm "$WORK/out/dbdog-agent-$VERSION-$ARCH.rpm"
# printf '%s\t%s\n' "$VERSION" "$WORK/out/dbdog-agent-$VERSION-$ARCH.rpm"
