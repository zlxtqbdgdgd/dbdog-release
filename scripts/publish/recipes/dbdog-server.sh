#!/usr/bin/env bash
# 配方：dbdog-server（Go，含 cgo）+ ddsql-server（Rust）+ migrations + goose 钩子。
# 输入 env：MODULE VERSION SHA ARCH REPO_ROOT BUILD_WORK TOOL_PATH（可选 CARGO_TARGET_DIR）
set -euo pipefail
export LC_ALL=C

log() { echo "[recipe:$MODULE] $*" >&2; }
die() { echo "[recipe:$MODULE] ERROR: $*" >&2; exit 1; }
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "构建机缺少命令: $1"
}

export PATH="${TOOL_PATH:+$TOOL_PATH:}$PATH"
for cmd in awk basename cargo chmod cp cut dirname du env find git go grep head \
  install ldd mkdir mv readelf readlink rm rustc sha256sum sort tar uname; do
  require_cmd "$cmd"
done

[ "$ARCH" = "aarch64" ] || die "dbdog-server 配方只发布 aarch64，收到 ARCH=$ARCH"
[ "$(uname -m)" = "aarch64" ] || die "构建机不是原生 aarch64"

# 优先复用 PATH 中的 patchelf；原构建机还保有 agent 已封存并校验的固定工具。
PATCHELF="$(command -v patchelf || true)"
PINNED_PATCHELF="$HOME/cache/dbdog-agent/tools/patchelf/0.18.0-aarch64-kylin10-v2/bin/patchelf"
if [ -z "$PATCHELF" ] && [ -x "$PINNED_PATCHELF" ]; then
  PATCHELF="$PINNED_PATCHELF"
  PINNED_PATCHELF_SHA256="01c84c7b8053b6b0c7f133ddbd979477bc1c9e7478e0018e1d8d96d117529faf"
  actual_patchelf_sha256="$(sha256sum "$PATCHELF" | awk '{print $1}')"
  [ "$actual_patchelf_sha256" = "$PINNED_PATCHELF_SHA256" ] || \
    die "固定 patchelf SHA-256 不匹配: $PATCHELF"
fi
[ -x "${PATCHELF:-/nonexistent}" ] || \
  die "找不到 patchelf；把它加入 TOOL_PATH，或准备固定工具 $PINNED_PATCHELF"
log "使用 $($PATCHELF --version | head -n1) ($PATCHELF)"

WORK="$BUILD_WORK/$MODULE"; PKG="$WORK/pkg/$MODULE-$VERSION"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/cargo-target}"
export CARGO_TARGET_DIR
DEPS_RAW="$WORK/ddsql-runtime-deps.raw"
DEPS_SORTED="$WORK/ddsql-runtime-deps.sorted"
NEEDED_RAW="$WORK/ddsql-runtime-needed.raw"
NEEDED_SORTED="$WORK/ddsql-runtime-needed.sorted"
rm -rf "$WORK/pkg" "$WORK/src"; mkdir -p "$PKG/bin" "$PKG/lib" "$WORK/out"

log "检出 $SHA"
git -C "$REPO_ROOT/dbdog-server" fetch -q origin 2>/dev/null || log "构建机对源仓无 fetch 凭据，用现有本地对象"
git clone -q --shared "$REPO_ROOT/dbdog-server" "$WORK/src"
git -C "$WORK/src" checkout -q "$SHA" || die "构建机仓库缺 ${SHA}（先在构建机上刷新该仓）"
cd "$WORK/src"

# 固定通用 ARMv8 基线，避免构建机 CPU 特性泄漏进 Go 产物。
export GOARM64=v8.0

log "Go 构建（CGO_CFLAGS=-DHAVE_STRCHRNUL，见源仓 Makefile 注释）"
# -p 限低并行：编译机内存小（2GB+swap），防 OOM
CGO_ENABLED=1 CGO_CFLAGS="-DHAVE_STRCHRNUL" \
  go build -p "${GO_JOBS:-2}" -trimpath -ldflags "-s -w" -o "$PKG/bin/dbdog-server" ./cmd/dbdog-server

log "Rust 构建 ddsql-server（release）"
# 不继承构建机的 CPU flags，强制 Rust 使用通用 AArch64 指令基线。
export RUSTFLAGS="-C target-cpu=generic"
(cd ddsql && cargo build --locked --release -j "${CARGO_JOBS:-2}")
install -m 755 "$CARGO_TARGET_DIR/release/ddsql-server" "$PKG/bin/ddsql-server"

is_dynamic_elf() {
  readelf -d "$1" 2>/dev/null | grep -q 'Dynamic section'
}

assert_aarch64_elf() {
  local elf="$1" machine
  machine="$(readelf -h "$elf" 2>/dev/null | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  [ "$machine" = "AArch64" ] || \
    die "DDSQL 运行闭包混入非 aarch64 ELF: ${elf#"$PKG/"} ($machine)"
}

is_base_runtime() {
  # 只把目标 Kylin V10 的 glibc/loader 当基础运行时；libgcc、OpenSSL、zlib 等必须随包。
  case "$1" in
    linux-vdso.so.1|ld-linux-aarch64.so.1|libc.so.6|libm.so.6|\
    libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2|\
    libutil.so.1|libanl.so.1)
      return 0
      ;;
    *) return 1 ;;
  esac
}

collect_resolved_dependencies() {
  local elf output
  : >"$DEPS_RAW"
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    assert_aarch64_elf "$elf"
    output="$(LD_LIBRARY_PATH="$PKG/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$elf" 2>&1)" || \
      die "ldd 失败: ${elf#"$PKG/"}: $output"
    if grep -Eq '=>[[:space:]]+not found' <<<"$output"; then
      die "动态库无法解析: ${elf#"$PKG/"}: $(grep -E '=>[[:space:]]+not found' <<<"$output" | awk '{$1=$1; print}')"
    fi
    awk '$2 == "=>" && $3 ~ /^\// { print $1 "\t" $3 }' <<<"$output" >>"$DEPS_RAW"
  done < <(find "$PKG/bin/ddsql-server" "$PKG/lib" -type f -print0)
  sort -u "$DEPS_RAW" >"$DEPS_SORTED"
}

copy_ddsql_runtime_closure() {
  local round=0 added soname dep dest dep_sha dest_sha
  while :; do
    collect_resolved_dependencies
    added=0
    while IFS=$'\t' read -r soname dep; do
      [ -n "$soname" ] || continue
      is_base_runtime "$soname" && continue
      case "$soname" in
        */*) die "ELF 依赖名含路径，拒绝封包: $soname" ;;
      esac
      [ -f "$dep" ] || die "解析到的动态库不是普通文件: $soname => $dep"
      assert_aarch64_elf "$dep"
      dest="$PKG/lib/$soname"
      if [ -e "$dest" ]; then
        dep_sha="$(sha256sum "$dep" | awk '{print $1}')"
        dest_sha="$(sha256sum "$dest" | awk '{print $1}')"
        [ "$dep_sha" = "$dest_sha" ] || \
          die "DDSQL 同名动态库内容冲突: $soname ($dep 与 $dest)"
        continue
      fi
      install -m 0755 "$dep" "$dest"
      log "DDSQL 收录运行库 $soname（来自 $dep）"
      added=1
    done <"$DEPS_SORTED"
    [ "$added" -eq 1 ] || break
    round=$((round + 1))
    [ "$round" -le 32 ] || die "DDSQL 动态库闭包超过 32 轮，疑似解析异常"
  done
}

collect_needed_sonames() {
  local elf
  : >"$NEEDED_RAW"
  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    readelf -d "$elf" | awk '
      /\(NEEDED\)/ {
        sub(/^.*\[/, "")
        sub(/\].*$/, "")
        print
      }
    ' >>"$NEEDED_RAW"
  done < <(find "$PKG/bin/ddsql-server" "$PKG/lib" -type f -print0)
  sort -u "$NEEDED_RAW" >"$NEEDED_SORTED"
}

assert_ddsql_runtime_closed() {
  local soname
  collect_needed_sonames
  while IFS= read -r soname; do
    [ -n "$soname" ] || continue
    case "$soname" in
      */*) die "ELF NEEDED 使用了绝对/相对路径: $soname" ;;
    esac
    is_base_runtime "$soname" && continue
    [ -f "$PKG/lib/$soname" ] || die "DDSQL 非基础依赖未收入包内: $soname"
  done <"$NEEDED_SORTED"

  # 当前 DDSQL 的明确 TLS ABI 合约，避免再次发布依赖目标机 OpenSSL 1.1 的包。
  for soname in libssl.so.1.1 libcrypto.so.1.1; do
    grep -Fxq "$soname" "$NEEDED_SORTED" || \
      die "DDSQL 运行 ABI 与已审合约不符，未发现依赖: $soname"
    [ -f "$PKG/lib/$soname" ] || die "DDSQL TLS 运行库未收入包内: $soname"
  done
}

patch_ddsql_runpaths() {
  local elf actual ddsql_runpath="\$ORIGIN/../lib" lib_runpath="\$ORIGIN"
  "$PATCHELF" --set-rpath "$ddsql_runpath" "$PKG/bin/ddsql-server" || \
    die "无法给 ddsql-server 写入 RUNPATH"
  actual="$($PATCHELF --print-rpath "$PKG/bin/ddsql-server")"
  [ "$actual" = "$ddsql_runpath" ] || \
    die "ddsql-server RUNPATH 不正确: $actual"

  while IFS= read -r -d '' elf; do
    is_dynamic_elf "$elf" || continue
    "$PATCHELF" --set-rpath "$lib_runpath" "$elf" || \
      die "无法写入运行库 RUNPATH: ${elf#"$PKG/"}"
    actual="$($PATCHELF --print-rpath "$elf")"
    [ "$actual" = "$lib_runpath" ] || \
      die "运行库 RUNPATH 不正确: ${elf#"$PKG/"}: $actual"
  done < <(find "$PKG/lib" -type f -print0)
}

verify_ddsql_packaged_resolution() {
  local output soname resolved resolved_real
  output="$(env -u LD_LIBRARY_PATH ldd "$PKG/bin/ddsql-server" 2>&1)" || \
    die "封包前 ddsql-server ldd 失败: $output"
  if grep -Eq '=>[[:space:]]+not found' <<<"$output"; then
    die "封包后 DDSQL 仍有动态库缺失: $(grep -E '=>[[:space:]]+not found' <<<"$output" | awk '{$1=$1; print}')"
  fi
  while IFS=$'\t' read -r soname resolved; do
    [ -n "$soname" ] || continue
    is_base_runtime "$soname" && continue
    resolved_real="$(readlink -f "$resolved")" || \
      die "无法规范化 DDSQL 动态库路径: $soname => $resolved"
    case "$resolved_real" in
      "$PKG"/lib/*) ;;
      *) die "DDSQL 非基础依赖未从包内加载: $soname => $resolved_real" ;;
    esac
  done < <(awk '$2 == "=>" && $3 ~ /^\// { print $1 "\t" $3 }' <<<"$output")
  log "DDSQL 封包 ldd smoke 通过（无需 LD_LIBRARY_PATH）"
}

copy_ddsql_runtime_closure
assert_ddsql_runtime_closed
patch_ddsql_runpaths
verify_ddsql_packaged_resolution

cp -a migrations "$PKG/migrations"
[ -z "$(find "$PKG/migrations" -type l -print -quit)" ] \
  || die "migrations 不允许包含软链"

mkdir -p "$PKG/etc"
if [ -f deploy/.env.example ]; then
  cp deploy/.env.example "$PKG/etc/dbdog-server.env.example"
else
  printf '# [首跑校准] dbdog-server 环境变量（PG_DSN、CH_*、DBDOG_*）\n' >"$PKG/etc/dbdog-server.env.example"
fi
printf '# [首跑校准] ddsql-server 环境变量（如需）\n' >"$PKG/etc/ddsql-server.env.example"

mkdir -p "$PKG/hooks"
# 最终产物内自带迁移文件清单。artifact SHA 保护下载过程；此清单额外防止安装目录
# 在真正执行迁移前被局部修改。
(
  cd "$PKG"
  find migrations -type f -print | LC_ALL=C sort | while IFS= read -r migration; do
    sha256sum "$migration"
  done
) >"$PKG/hooks/postgres-migrations.sha256"
[ -s "$PKG/hooks/postgres-migrations.sha256" ] || die "PG migrations 校验清单为空"
cat >"$PKG/hooks/pre-switch.sh" <<'EOF'
#!/usr/bin/env bash
# PG ctl 库增量迁移（goose up）。CH 租户表由 dbdog-server 启动时 blueprint 自动推进。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ETC_DIR/dbdog-server.env"
REQUIRED="${DBDOG_MIGRATION_REQUIRED:-0}"
case "$REQUIRED" in 0 | 1) ;; *) echo "[hook] 非法 DBDOG_MIGRATION_REQUIRED=$REQUIRED" >&2; exit 1 ;; esac
if [ ! -f "$ENVF" ]; then
  [ "$REQUIRED" = 0 ] && { echo "[hook] 无 ${ENVF}，首次落包暂不迁移（install.sh 收尾阶段自动补跑）"; exit 0; }
  echo "[hook] 缺少 ${ENVF}，拒绝在未迁移数据库时升级 dbdog-server" >&2
  exit 1
fi
set -a; source "$ENVF"; set +a
[ -n "${PG_DSN:-}" ] || {
  [ "$REQUIRED" = 0 ] && { echo "[hook] PG_DSN 未设置，首次落包暂不迁移"; exit 0; }
  echo "[hook] PG_DSN 未设置，拒绝在未迁移数据库时升级 dbdog-server" >&2
  exit 1
}
(cd "$HERE" && sha256sum -c hooks/postgres-migrations.sha256 >/dev/null) \
  || { echo "[hook] dbdog-server 迁移文件完整性校验失败" >&2; exit 1; }
"$MODULES_DIR/goose/current/bin/goose" -dir "$HERE/migrations" postgres "$PG_DSN" up
EOF
chmod +x "$PKG/hooks/pre-switch.sh"
echo "$VERSION" >"$PKG/VERSION"

ART="$MODULE-$VERSION-$ARCH.tar.gz"
tar -czf "$WORK/out/$ART" -C "$WORK/pkg" "$MODULE-$VERSION"
log "打包完成 $ART ($(du -h "$WORK/out/$ART" | cut -f1))"
printf '%s\t%s\n' "$VERSION" "$WORK/out/$ART"
