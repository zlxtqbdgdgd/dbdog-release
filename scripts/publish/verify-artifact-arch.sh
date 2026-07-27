#!/usr/bin/env bash
# 发布前检查 tar 包内机器码是否与文件名架构一致。
# 用法：verify-artifact-arch.sh <artifact.tar.gz> <aarch64|noarch> [module]

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

artifact="${1:-}"
expected="${2:-}"
module="${3:-}"
[ -f "$artifact" ] || die "产物不存在: $artifact"
case "$expected" in
  aarch64 | noarch) ;;
  *) die "期望架构只能是 aarch64 或 noarch" ;;
esac

for cmd in tar file find mktemp objdump; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少架构检查命令: $cmd"
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-artifact-arch.XXXXXX")"
extract="$tmp/extract"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$extract"

tar -tzf "$artifact" >/dev/null || die "无法读取 tar.gz: $artifact"
tar -xzf "$artifact" -C "$extract" || die "无法解包: $artifact"

machine_count=0
host_machine_count=0
check_machine() { # check_machine <显示路径> <file 输出>
  local path="$1" info="$2"
  case "$info" in
    *ELF* | *Mach-O* | *PE32*) ;;
    *) return 0 ;;
  esac
  machine_count=$((machine_count + 1))
  if [ "$expected" = "noarch" ]; then
    die "noarch 包含机器码: $path ($info)"
  fi
  # Agent 内含给 Linux 内核加载的 eBPF ELF；它不是宿主 CPU 用户态代码。
  # 只放行已知 runtime 目录，不能借此放过任意位置的非 AArch64 ELF。
  case "$info" in
    *ELF*relocatable*eBPF*)
      [ "$module" = "dbdog-agent" ] \
        || die "非 Agent 包含 eBPF 机器码: $path ($info)"
      case "$path" in
        embedded/share/system-probe/ebpf/*.o) return 0 ;;
        *) die "Agent 的 eBPF ELF 位于未知路径: $path" ;;
      esac
      ;;
    *PE32*)
      # pip distlib 的 Windows launcher 是 Python 随包资源；msodbcsql 的 .rll 是
      # ODBC 本地化消息资源。Linux 不执行它们，只精确放行当前已审路径。
      [ "$module" = "dbdog-agent" ] \
        || die "aarch64 包混入 Windows PE: $path ($info)"
      case "$path" in
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/t32.exe | \
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/t64.exe | \
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/t64-arm.exe | \
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/w32.exe | \
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/w64.exe | \
        embedded/lib/python3.13/site-packages/pip/_vendor/distlib/w64-arm.exe | \
        embedded/msodbcsql/share/resources/en_US/msodbcsqlr18.rll)
          return 0
          ;;
        *) die "Agent 包含未审 Windows PE 资源: $path ($info)" ;;
      esac
      ;;
  esac
  case "$info" in
    *ELF*ARM\ aarch64*) host_machine_count=$((host_machine_count + 1)) ;;
    *) die "aarch64 包混入其他架构: $path ($info)" ;;
  esac
}

check_elf_paths() { # check_elf_paths <文件> <显示路径>
  local file_path="$1" path="$2" dynamic path_list entry needed
  local -a entries
  dynamic="$(objdump -p "$file_path" 2>/dev/null)" \
    || die "无法读取 ELF 动态信息: $path"
  while IFS= read -r path_list; do
    [ -n "$path_list" ] || continue
    case "$path_list" in
      :* | *: | *::* ) die "ELF 的 RPATH/RUNPATH 含当前目录: $path ($path_list)" ;;
    esac
    IFS=: read -r -a entries <<<"$path_list"
    for entry in "${entries[@]}"; do
      # shellcheck disable=SC2016 # 这里匹配 ELF 中字面量 $ORIGIN。
      case "$entry" in
        '$ORIGIN' | '$ORIGIN/'* | '${ORIGIN}' | '${ORIGIN}/'*) ;;
        '$$ORIGIN')
          # 当前 Agent 的两个 pymongo 扩展带 `$ORIGIN:$$ORIGIN`；前一项有效，
          # 后一项是无效但不逃逸的重复构建遗留。仅对该固定 runtime 兼容。
          [ "$module" = "dbdog-agent" ] \
            || die "ELF 含不受支持的动态加载器 token: $path ($entry)"
          ;;
        /opt/dbdog-agent | /opt/dbdog-agent/*)
          # Agent 是固定安装到 /opt/dbdog-agent 的私有 runtime，不属于 modules/current
          # 可搬迁栈。仅它可使用该固定前缀，且拒绝 ..、空组件等词法逃逸。
          [ "$module" = "dbdog-agent" ] \
            || die "ELF 含不可搬迁的 RPATH/RUNPATH: $path ($entry)"
          case "$entry" in
            *//* | */../* | */.. | */./* | */.)
              die "Agent ELF 的固定 RPATH/RUNPATH 含路径逃逸: $path ($entry)"
              ;;
          esac
          ;;
        *) die "ELF 含不可搬迁的 RPATH/RUNPATH: $path ($entry)" ;;
      esac
    done
  done < <(printf '%s\n' "$dynamic" | awk '
    $1 == "RPATH" || $1 == "RUNPATH" {
      sub(/^[[:space:]]*(RPATH|RUNPATH)[[:space:]]+/, "")
      print
    }
  ')

  # DT_NEEDED 正常只能是 SONAME；带 slash 会绕过 RUNPATH，直接加载构建机绝对路径。
  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    case "$needed" in
      */*) die "ELF 的 DT_NEEDED 含路径: $path ($needed)" ;;
    esac
  done < <(printf '%s\n' "$dynamic" | awk '
    $1 == "NEEDED" {
      sub(/^[[:space:]]*NEEDED[[:space:]]+/, "")
      print
    }
  ')
}

while IFS= read -r -d '' file_path; do
  info="$(file -b "$file_path")"
  rel="${file_path#"$extract"/}"
  check_machine "$rel" "$info"

  case "$info" in
    *ELF*relocatable*eBPF*) ;;
    *ELF*) check_elf_paths "$file_path" "$rel" ;;
  esac

  case "$info" in
    *ar\ archive*)
      archive_dump="$(objdump -f "$file_path")" \
        || die "无法检查静态库成员: $rel"
      while IFS= read -r member_arch; do
        [ -n "$member_arch" ] || continue
        machine_count=$((machine_count + 1))
        if [ "$expected" = "noarch" ]; then
          die "noarch 包含机器码静态库: $rel ($member_arch)"
        fi
        [ "$member_arch" = "aarch64" ] \
          || die "aarch64 包的静态库混入其他架构: $rel ($member_arch)"
        host_machine_count=$((host_machine_count + 1))
      done < <(printf '%s\n' "$archive_dump" \
        | awk '/^architecture:/ { sub(/^architecture:[[:space:]]*/, ""); sub(/,.*/, ""); print }')
      ;;
  esac
done < <(find "$extract" -type f -print0)

if [ "$expected" = "aarch64" ] && [ "$host_machine_count" -eq 0 ]; then
  die "aarch64 包内没有发现任何 AArch64 ELF 机器码: $artifact"
fi

printf '架构检查通过: %s expected=%s machine_files=%s\n' \
  "$(basename "$artifact")" "$expected" "$machine_count"
