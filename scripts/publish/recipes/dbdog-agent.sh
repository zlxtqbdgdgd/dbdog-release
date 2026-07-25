#!/usr/bin/env bash
# 配方：dbdog-agent（omnibus 运行时 tarball，非 rpm——fork 明确禁止自制 rpm，
# 见 dbdog-agent/dbdog-deploy/README.md §0 与 docs/ops/RUNBOOK.md §1）。
# 输入 env：MODULE VERSION SHA CORE_SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH
#
# ⚠️ 尚未跑通。2026-07 调研结论（详见发布会话记录）：
#   - 产物形态：omnibus 构建的完整运行时 tarball（dbdog-agent-<ver>-aarch64.tar.gz，
#     解压即 /opt/dbdog-agent 内容），内网 DB 主机用 fork 的
#     scripts/ops/dbdog-agent-runtime-cutover.sh 原子切换部署。
#   - 资源硬门槛：全量 omnibus 构建需 ≥8 vCPU / ≥16GB 内存 / ~50GB 盘（CI 用 16c/32G）。
#     当前 2GB 编译机不可行 → 临时把云编译机扩容到 8c16g 构建一次再缩回，或另租临时机。
#   - 构建入口：`dda inv -- -e omnibus.build --host-distribution=rhel`（native aarch64），
#     参考 .gitlab/build/packaging/rpm.yml 与 docs/public/how-to/build/distributions.md；
#     需改 omnibus/config/projects/agent.rb 的 package_name/install_dir=/opt/dbdog-agent。
#   - dbdog 内容进包：官方 integrations-core 7.81.0 为底，打包前对 staging 的
#     embedded/lib/python3.13/site-packages 跑 dbdog-deploy/scripts/patch-*.sh
#     （PATCH_ONLY=true），并 pip install dbdog-agent-core 的 gaussdb 目录（GaussDB 全新
#     check，不在补丁脚本覆盖范围内，别漏）。
#   - 依赖：Go 1.26.4(.go-version)、python 3.12(dda)、ruby/bundler(omnibus)、cmake≥3.15、
#     clang-bpf/llc-bpf（system-probe）。官方 arm 构建镜像 datadog/agent-buildimages-rpm_arm64
#     可作 docker 路线（native arm，勿 qemu）。
set -euo pipefail
log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }

die "agent omnibus 构建需要 ≥8c/16GB 的 arm 机（当前编译机 2GB 不可行）。扩容编译机后按文件头结论把真实步骤固化到本配方。agent@${SHA:-?} core@${CORE_SHA:-?}"
