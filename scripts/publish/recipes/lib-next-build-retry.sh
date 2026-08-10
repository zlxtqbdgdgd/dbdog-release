#!/usr/bin/env bash
# next build 的「已知可安全重试」失败签名与重试执行。
#
# 单独成文件，是为了让 scripts/test-publish-web-build-retry.sh 能直接 source 它，
# 拿**真实失败日志**喂进来验判定与重试次数——否则要验这套逻辑就得真跑一次 next build。
#
# 背景（2026-08-10 实测）：next build 的最后一步 "Collecting build traces" 由十几个进程
# 并行产/读每页的 `*.nft.json` 清单（Next 用它裁剪 standalone 产物）。偶发读到尚未落盘的
# 清单，报 ENOENT——而该文件事后确实存在。同一提交同一构建机，第一次挂、第二次过。
# 编译、类型检查、静态页生成三步都已通过，失败只在这最后一步。

# 判定：这次失败是不是那个已知的并行抢跑。
#
# **只认这一种签名**。别的失败一律照常炸——重试会把真问题掩盖成偶发，而且掩盖得越久越难查：
# 一个每次都失败的构建会被当成「又是那个抖动」重跑三次，直到有人肯读日志。
is_retryable_next_build_failure() { # <构建日志文件>
  local log_file="${1:-}"
  [ -n "$log_file" ] && [ -f "$log_file" ] || return 1
  grep -qE "ENOENT.*\.nft\.json" "$log_file"
}

# 跑构建；只在命中上述签名时清 .next 重试一次。
# 日志同时实时打到 stderr 与落盘（落盘供判定用；实时是为了长构建能看见进度）。
run_next_build_with_one_retry() { # <日志文件> <构建命令...>
  local log_file="$1"; shift
  [ "$#" -gt 0 ] || { echo "run_next_build_with_one_retry: 缺构建命令" >&2; return 2; }

  if "$@" 2>&1 | tee "$log_file" >&2; then return 0; fi

  if ! is_retryable_next_build_failure "$log_file"; then
    echo "[next-build] 失败签名不在已知可重试之列，不重试（见上方日志）" >&2
    return 1
  fi

  echo "[next-build] 构建追踪抢跑（.nft.json ENOENT）——已知偶发，清 .next 后重试一次；再失败即真失败" >&2
  rm -rf .next
  "$@" 2>&1 | tee "$log_file" >&2
}
