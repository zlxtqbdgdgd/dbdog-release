#!/usr/bin/env bash
# 配方 @include 展开 —— **正式发布（publish.sh）与快升级（fast-upgrade.sh）共用的单源**。
#
# 为什么要内联而不是让配方自己 source：配方经 stdin 喂给构建机 bash，对端没有本仓，
# $BASH_SOURCE[0] 也未绑定，配方里 source 同目录 lib 必然失败。
# 快升级虽是在构建机本地按文件路径跑配方，但**跑的是同一份配方**——不展开就缺函数定义。
# 2026-08-10 dbdog-web 快升级即因此当场炸（run_next_build_with_one_retry: command not found）。
#
# 调用方须已定义 die()。
compose_recipe_includes() { # <配方路径> <recipes 目录> <可写临时目录> → stdout: 最终配方路径
  local recipe="$1" recipes_dir="$2" scratch="$3"
  [ -f "$recipe" ] || die "缺少配方: $recipe"
  if ! grep -qE '^# @include ' "$recipe"; then
    printf '%s\n' "$recipe"
    return 0
  fi

  mkdir -p "$scratch"
  local composed="$scratch/.recipe-$(basename "$recipe")"
  : >"$composed"
  local line inc
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '# @include '*)
        inc="${line#\# @include }"
        inc="${inc%%[[:space:]]*}"
        case "$inc" in
          */*|'') die "配方 $(basename "$recipe") 的 @include 只接受 recipes/ 下的文件名: '$inc'" ;;
        esac
        [ -f "$recipes_dir/$inc" ] \
          || die "配方 $(basename "$recipe") @include 的文件不存在: recipes/$inc"
        printf '# ---- @include recipes/%s（内联）----\n' "$inc" >>"$composed"
        cat "$recipes_dir/$inc" >>"$composed"
        printf '# ---- end recipes/%s ----\n' "$inc" >>"$composed"
        ;;
      *) printf '%s\n' "$line" >>"$composed" ;;
    esac
  done <"$recipe"
  # 快升级以 root 展开、以栈属主身份执行配方，必须让对方读得到。
  chmod 0644 "$composed"
  printf '%s\n' "$composed"
}
