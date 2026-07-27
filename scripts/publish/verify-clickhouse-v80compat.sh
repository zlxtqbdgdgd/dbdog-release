#!/usr/bin/env bash
# 离线审计 ClickHouse aarch64v80compat 自解压文件：只反汇编 ELF 可执行节，
# 不把压缩数据误当指令。该检查用于更新 recipe 内容锁；目标机最终仍以 upgrade.sh
# 在 staging 中实际运行 `clickhouse --version` 为准。

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

source_binary="${1:-}"
[ -f "$source_binary" ] || die "用法: $0 <clickhouse-aarch64v80compat-self-extracting>"

for cmd in awk file mktemp python3 rm sha256sum tr wc zstd; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少离线审计命令: $cmd"
done

if command -v llvm-objdump >/dev/null 2>&1; then
  objdump_cmd=(llvm-objdump)
elif command -v objdump >/dev/null 2>&1; then
  objdump_cmd=(objdump)
elif command -v xcrun >/dev/null 2>&1 && xcrun -f llvm-objdump >/dev/null 2>&1; then
  objdump_cmd=(xcrun llvm-objdump)
else
  die "缺少能反汇编 AArch64 ELF 的 objdump/llvm-objdump"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbdog-clickhouse-v80-audit.XXXXXX")"
inner="$tmp/clickhouse-stripped"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

count_rcpc_loads() {
  local elf="$1"
  "${objdump_cmd[@]}" -d --no-show-raw-insn "$elf" 2>/dev/null \
    | awk '
        tolower($2) ~ /^(ldapr(b|h)?|ldapur(b|h|sb|sh|sw)?)$/ { count++ }
        END { print count + 0 }
      '
}

# 旧 binutils 可能把 ARMv8.3 RCpc 编码显示成 `.inst`，那样“计数为 0”是假阴性。
# 先用最小 AArch64 ELF object 验证 LDAPR*（RCpc v1）和 LDAPUR*（RCpc v2）
# 全部 load-acquire 形式；AArch64 ISA 不存在 LDAPRSW，带符号 word 形式是 LDAPURSW。
rcpc_fixture="$tmp/aarch64-rcpc-load-fixture.o"
python3 - "$rcpc_fixture" <<'PY'
import base64
import sys

payload = """f0VMRgIBAQAAAAAAAAAAAAEAtwABAAAAAAAAAAAAAAAAAAAAAAAAAMgAAAAAAAAAAAAAAEAAAAAAAEAABAABACDAv7hiwL/4pMC/OObAv3goAUCZagFA2awBQBnuAUBZMALAGXICgBm0AsBZ9gKAWTgDgJkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAACR4AC50ZXh0AC5zdHJ0YWIALnN5bXRhYgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgAAAAMAAAAAAAAAAAAAAAAAAAAAAAAAqAAAAAAAAAAaAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAQAAAABAAAABgAAAAAAAAAAAAAAAAAAAEAAAAAAAAAANAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAASAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAB4AAAAAAAAADAAAAAAAAAAAQAAAAIAAAAIAAAAAAAAABgAAAAAAAAA="""
with open(sys.argv[1], "wb") as fixture:
    fixture.write(base64.b64decode(payload))
PY
fixture_rcpc="$(count_rcpc_loads "$rcpc_fixture")" \
  || die "无法用所选反汇编器读取 AArch64 RCpc fixture: ${objdump_cmd[*]}"
[ "$fixture_rcpc" -eq 13 ] \
  || die "反汇编器不认识全部 RCpc load-acquire 编码（fixture 期望 13，实际 ${fixture_rcpc}）；拒绝产生可能的假阴性"

outer_info="$(LC_ALL=C file -b "$source_binary")"
case "$outer_info" in
  *ELF*64-bit*LSB*ARM\ aarch64*) ;;
  *) die "外层不是 Linux AArch64 ELF: $outer_info" ;;
esac

# 格式来自 ClickHouse 同提交的 utils/self-extracting-executable/types.h：
# EOF MetaData=<uint64 files,uint64 metadata_offset>，每项 FileData 是 48 字节，
# 后跟 name；只把标为 executable 的 zstd blob 解为内层 ELF。
python3 - "$source_binary" "$inner" <<'PY'
import os
import struct
import subprocess
import sys

source, output = sys.argv[1:]
file_data_size = 48
size = os.path.getsize(source)
if size < 64:
    raise SystemExit("self-extracting file is too small")

with open(source, "rb") as src:
    src.seek(size - 16)
    number_of_files, metadata_offset = struct.unpack("<QQ", src.read(16))
    if not 0 < number_of_files <= 16:
        raise SystemExit(f"implausible self-extracting file count: {number_of_files}")
    if not 0 < metadata_offset < size - 16:
        raise SystemExit(f"invalid self-extracting metadata offset: {metadata_offset}")

    pos = metadata_offset
    executable = []
    for _ in range(number_of_files):
        if pos + file_data_size > size - 16:
            raise SystemExit("truncated self-extracting FileData")
        src.seek(pos)
        raw = src.read(file_data_size)
        start, end, name_size, unpacked_size, _mode, is_executable = struct.unpack("<QQQQQ?7x", raw)
        if not 0 < name_size <= 4096 or pos + file_data_size + name_size > size - 16:
            raise SystemExit("invalid self-extracting file name size")
        name = src.read(name_size)
        if not 0 <= start < end <= metadata_offset:
            raise SystemExit("invalid self-extracting compressed range")
        if is_executable:
            executable.append((start, end, unpacked_size, name))
        pos += file_data_size + name_size

    if pos != size - 16:
        raise SystemExit("self-extracting metadata does not end at trailer")
    if len(executable) != 1:
        raise SystemExit(f"expected one executable payload, found {len(executable)}")
    start, end, unpacked_size, name = executable[0]
    if name.rstrip(b"\0") != b"clickhouse-stripped":
        raise SystemExit(f"unexpected executable payload name: {name!r}")

    src.seek(start)
    proc = subprocess.Popen(
        ["zstd", "-d", "-q", "-f", "-o", output],
        stdin=subprocess.PIPE,
    )
    assert proc.stdin is not None
    remaining = end - start
    try:
        while remaining:
            block = src.read(min(1024 * 1024, remaining))
            if not block:
                raise SystemExit("truncated compressed payload")
            proc.stdin.write(block)
            remaining -= len(block)
        proc.stdin.close()
        rc = proc.wait()
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    if rc != 0:
        raise SystemExit(f"zstd failed with exit code {rc}")
    actual_size = os.path.getsize(output)
    if actual_size != unpacked_size:
        raise SystemExit(
            f"inner size mismatch: metadata={unpacked_size} actual={actual_size}"
        )

print(f"self_extract_files={number_of_files}")
print(f"inner_metadata_size={unpacked_size}")
PY

inner_info="$(LC_ALL=C file -b "$inner")"
case "$inner_info" in
  *ELF*64-bit*LSB*ARM\ aarch64*) ;;
  *) die "内层不是 Linux AArch64 ELF: $inner_info" ;;
esac

# 只禁用本次鲲鹏 SIGILL 的 RCpc load-acquire 指令；STLR 是 ARMv8 基线，CAS/LSE
# 可存在于运行时选择的实现中，不能用全文件存在性误判为必需 CPU 特性。
outer_rcpc="$(count_rcpc_loads "$source_binary")" \
  || die "无法反汇编 ClickHouse 自解压外层"
inner_rcpc="$(count_rcpc_loads "$inner")" \
  || die "无法反汇编 ClickHouse 内层 ELF"
[ "$outer_rcpc" -eq 0 ] \
  || die "自解压外层可执行节含 $outer_rcpc 条 RCpc load-acquire 指令，不是已审 v8.0 基线"
[ "$inner_rcpc" -eq 0 ] \
  || die "内层可执行节含 $inner_rcpc 条 RCpc load-acquire 指令，不是已审 v8.0 基线"

printf 'outer_sha256=%s\n' "$(sha256sum "$source_binary" | awk '{print $1}')"
printf 'outer_size=%s\n' "$(wc -c <"$source_binary" | tr -d '[:space:]')"
printf 'inner_sha256=%s\n' "$(sha256sum "$inner" | awk '{print $1}')"
printf 'inner_size=%s\n' "$(wc -c <"$inner" | tr -d '[:space:]')"
printf 'outer_rcpc_loads_in_executable_sections=%s\n' "$outer_rcpc"
printf 'inner_rcpc_loads_in_executable_sections=%s\n' "$inner_rcpc"
printf '%s\n' '注意：静态审计不替代目标机 staging 的实际 --version 门禁。'
