#!/usr/bin/env bash
# dbdog-agent 安装辅助：目标机事实探测与配置渲染。
# 本文件只定义函数，供 agent-install.sh 与契约测试 source。

AGENT_RUNTIME_DIR="${AGENT_RUNTIME_DIR:-/opt/dbdog-agent}"
AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-/etc/dbdog-agent}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/dbdog-agent}"
AGENT_RUN_DIR="${AGENT_RUN_DIR:-$AGENT_RUNTIME_DIR/run}"
# shellcheck disable=SC2034 # 由 source 本文件的 agent-install.sh/check-upgrade.sh 使用。
AGENT_INSTALLER_CONTRACT_MARKER=".dbdog-installer-contract-sha256"
# shellcheck disable=SC2034 # 由 source 本文件的安装器与 dbdogctl 使用。
AGENT_SYSTEMD_UNITS=(
  dbdog-agent-sysprobe.service
  dbdog-agent.service
  dbdog-agent-trace.service
  dbdog-agent-process.service
)

# 诊断输出可能来自 journal 或 Agent CLI，两者都不是我们能完全约束的
# 文本。这里只保留定位所需的错误和时序信息，统一遮掉常见凭证形态。
agent_redact_diagnostic_stream() {
  sed -E \
    -e "s#(([Pp][Rr][Oo][Xx][Yy]-)?[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][\"']?[[:space:]]*[:=][[:space:]]*).*#\\1<redacted>#g" \
    -e "s#(([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])([[:space:]]*=[[:space:]]*|[[:space:]]+))(\"[^\"]*\"|'[^']*'|[^[:space:],;]+)#\\1<redacted>#g" \
    -e "s#(([Ii][Dd][Ee][Nn][Tt][Ii][Ff][Ii][Ee][Dd][[:space:]]+[Bb][Yy][[:space:]]+))(\"[^\"]*\"|'[^']*'|[^[:space:],;]+)#\\1<redacted>#g" \
    -e "s#([A-Za-z][A-Za-z0-9+.-]*://[^:/@[:space:]]+:)[^@/[:space:]]+@#\\1<redacted>@#g" \
    -e "s#([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+/=-]+#\\1<redacted>#g" \
    -e "s#(([\"']?)([Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn])[\"']?[[:space:]]*[:=][[:space:]]*)(\"[^\"]*\"|'[^']*'|[^[:space:],;]+)#\\1<redacted>#g" \
    -e "s#(--([Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:],;]+)#\\1<redacted>#g"
}

agent_known_runtime_error_pattern() {
  # 返回单行 ERE，供安装验收和诊断入口共用；不用泛化的
  # "error" 匹配，避免把 status 中的历史计数器误判为当前失败。
  printf '%s\n' 'Function age\(xid32\) does not exist|operator does not exist:[[:space:]]*text[[:space:]]*=[[:space:]]*record|GaussDB query scope failed:.*category=(undefined-function|programming-error|database-error)([[:space:]]|$)|error:query-scope-(undefined-function|programming-error|database-error)([[:space:],]|$)|Unable to collect statement metrics due to an error|job:database-metadata[^]]*\][[:space:]]+Job loop (database error|crash)|database-metadata.*Job loop (database error|crash)|panic: runtime error: index out of range \[65536\] with length 28672|preventSegmentMajorPageFault'
}

agent_sha256_file() { # <文件>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

agent_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    return 1
  fi
}

agent_installer_contract_fingerprint() { # <scripts 目录>；覆盖 Agent 专属脚本及其共享 shell 运行库
  local scripts="$1" relative path digest payload=""
  for relative in lib.sh agent-install.sh agent-lib.sh agent/init-gaussdb-perdb.sql \
    agent/init-dbdog-user-gaussdb-all-databases.sh \
    agent/init-dbdog-user-pg-all-databases.sh agent/init-dbdog-user-pg-perdb.sql \
    agent/init-dbdog-user-opengauss-all-databases.sh \
    agent/init-dbdog-user-opengauss-perdb.sql; do
    path="$scripts/$relative"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      printf 'Agent 安装器合约缺少文件: %s\n' "$path" >&2
      return 1
    fi
    if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ]; then
      printf 'Agent 安装器合约文件必须是可读普通文件且不能是符号链接: %s\n' "$path" >&2
      return 1
    fi
    digest="$(agent_sha256_file "$path")" || return 1
    [ "${#digest}" -eq 64 ] || return 1
    case "$digest" in *[!0-9a-f]*) return 1 ;; esac
    payload+="${relative}:${digest}"$'\n'
  done
  printf '%s' "$payload" | agent_sha256_stdin
}

agent_generate_gaussdb_password() {
  local random
  # 14 随机字节给出 112 bit 熵；固定前缀确保四类字符，整体恰好 32 字符。
  random="$(od -An -N14 -tx1 /dev/urandom | tr -d '[:space:]')" || return 1
  [ "${#random}" -eq 28 ] || return 1
  printf 'Aa1_%s\n' "$random"
}

agent_validate_gaussdb_password() { # <密码>；符合 GaussDB 默认长度与三类字符约束
  local password="$1" classes=0
  [ "${#password}" -ge 8 ] && [ "${#password}" -le 32 ] || return 1
  printf '%s' "$password" | LC_ALL=C grep -q '[^[:print:]]' && return 1
  printf '%s' "$password" | LC_ALL=C grep -q '[[:space:]]' && return 1
  case "$password" in *[A-Z]*) classes=$((classes + 1)) ;; esac
  case "$password" in *[a-z]*) classes=$((classes + 1)) ;; esac
  case "$password" in *[0-9]*) classes=$((classes + 1)) ;; esac
  case "$password" in *[!A-Za-z0-9]*) classes=$((classes + 1)) ;; esac
  [ "$classes" -ge 3 ]
}

agent_require_single_line() { # <字段名> <值>
  local name="$1" value="$2"
  case "$value" in
    *$'\n'* | *$'\r'*) die "$name 不能包含换行" ;;
  esac
}

agent_yaml_quote() { # 任意单行字符串 -> YAML 单引号标量
  agent_require_single_line "YAML value" "$1"
  printf "'"
  printf '%s' "$1" | sed "s/'/''/g"
  printf "'"
}

agent_yaml_unquote() { # 读取本安装器生成的单/双引号或裸标量
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\')
      value="${value#\'}"; value="${value%\'}"
      printf '%s\n' "$value" | sed "s/''/'/g"
      ;;
    \"*\")
      value="${value#\"}"; value="${value%\"}"
      printf '%s\n' "$value" | sed 's/\\"/"/g; s/\\\\/\\/g'
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

agent_existing_top_scalar() { # <yaml> <key>；只读顶层简单标量
  local file="$1" key="$2" raw
  [ -f "$file" ] || return 1
  raw="$(awk -v key="$key" '
    $0 ~ ("^" key "[[:space:]]*:") {
      sub("^[^:]*:[[:space:]]*", "")
      print
      exit
    }
  ' "$file")"
  [ -n "$raw" ] || return 1
  agent_yaml_unquote "$raw"
}

agent_harvest_engine_passwords() { # <引擎 conf>；输出 port<TAB>password 对（每实例一行）
  # 同引擎多实例的监控密码可以各不相同（构建机 5432/5433 实测就是两套），升级路径
  # 必须按实例收割而不是拿首实例的密码套全引擎。conf 是我们自己的渲染/deploy 形制：
  # 实例块内 port 先于 password 出现。
  local file="$1" line port="" raw
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      '    port:'*)
        port="${line#*:}"
        port="$(printf '%s' "$port" | tr -d '[:space:]')"
        ;;
      '    password:'*)
        [ -n "$port" ] || continue
        raw="${line#*password:}"
        raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//')"
        printf '%s\t%s\n' "$port" "$(agent_yaml_unquote "$raw")"
        port=""
        ;;
    esac
  done <"$file"
}

agent_existing_gauss_scalar() { # <gauss conf> <key>；取第一实例的简单标量
  local file="$1" key="$2" raw
  [ -f "$file" ] || return 1
  raw="$(awk -v key="$key" '
    $0 ~ ("^[[:space:]]{4}" key "[[:space:]]*:") {
      sub("^[^:]*:[[:space:]]*", "")
      print
      exit
    }
  ' "$file")"
  [ -n "$raw" ] || return 1
  agent_yaml_unquote "$raw"
}

agent_validate_server_url() { # 输出去尾斜线的 http(s) origin
  local url="$1" authority
  agent_require_single_line DBDOG_SERVER_URL "$url"
  url="${url%/}"
  case "$url" in
    http://*) authority="${url#http://}" ;;
    https://*) authority="${url#https://}" ;;
    *) die "DBDOG_SERVER_URL 必须是 http:// 或 https:// 开头的服务 origin" ;;
  esac
  [ -n "$authority" ] || die "DBDOG_SERVER_URL 缺少主机"
  case "$authority" in
    */* | *\?* | *\#* | *@* | *[[:space:]]*)
      die "DBDOG_SERVER_URL 只能是 scheme://host[:port]，不能带路径、凭证或空白"
      ;;
  esac
  printf '%s\n' "$url"
}

agent_server_hostport() {
  local url="$1"
  url="${url#http://}"; url="${url#https://}"
  printf '%s\n' "$url"
}

agent_valid_port() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

agent_proc_env() { # <pid> <KEY>
  local pid="$1" key="$2" root="${DBDOG_PROC_ROOT:-/proc}"
  [ -r "$root/$pid/environ" ] || return 1
  tr '\000' '\n' <"$root/$pid/environ" |
    awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }'
}

agent_merge_path_lists() { # <colon-list>...；保序去重并丢弃隐式当前目录
  local result="" list part finished
  for list in "$@"; do
    finished=0
    while [ "$finished" -eq 0 ]; do
      case "$list" in
        *:*) part="${list%%:*}"; list="${list#*:}" ;;
        *) part="$list"; list=""; finished=1 ;;
      esac
      [ -n "$part" ] || continue
      case ":$result:" in *":$part:"*) continue ;; esac
      if [ -n "$result" ]; then result="$result:$part"; else result="$part"; fi
    done
  done
  printf '%s\n' "$result"
}

agent_find_in_path() { # <PATH> <程序名>
  local paths="$1" program="$2" dir finished=0
  while [ "$finished" -eq 0 ]; do
    case "$paths" in
      *:*) dir="${paths%%:*}"; paths="${paths#*:}" ;;
      *) dir="$paths"; paths=""; finished=1 ;;
    esac
    [ -n "$dir" ] || continue
    if [ -x "$dir/$program" ] && [ ! -d "$dir/$program" ]; then
      printf '%s\n' "$dir/$program"
      return 0
    fi
  done
  return 1
}

agent_proc_socket_dir() { # <port>；从运行态 Unix socket 表发现目录
  local port="$1" root="${DBDOG_PROC_ROOT:-/proc}" sockets
  sockets="$root/net/unix"
  [ -r "$sockets" ] || return 1
  awk -v suffix="/.s.PGSQL.$port" '
    NF >= 8 && length($NF) > length(suffix) && \
      substr($NF, length($NF) - length(suffix) + 1) == suffix {
      print substr($NF, 1, length($NF) - length(suffix))
      exit
    }
  ' "$sockets"
}

agent_load_owner_environment() { # <owner> <home> <进程中的 MPPDB_ENV_SEPARATE_PATH> <显式 env 文件>
  local owner="$1" home="$2" seed_mpp="$3" explicit_file="$4"
  local capture timeout_bin runuser_bin env_bin bash_bin record key value rc=0 invalid_capture=0
  AGENT_OWNER_ENV_GAUSSHOME=""
  AGENT_OWNER_ENV_GAUSSLOG=""
  AGENT_OWNER_ENV_PGDATA=""
  AGENT_OWNER_ENV_PGHOST=""
  AGENT_OWNER_ENV_PGPORT=""
  AGENT_OWNER_ENV_LD_LIBRARY_PATH=""
  AGENT_OWNER_ENV_PATH=""
  [ -n "$owner" ] && [ -n "$home" ] || return 1
  case "$explicit_file" in "" | /*) ;; *) return 1 ;; esac

  timeout_bin="${DBDOG_TIMEOUT_BIN:-$(command -v timeout 2>/dev/null || true)}"
  runuser_bin="${DBDOG_RUNUSER_BIN:-$(command -v runuser 2>/dev/null || true)}"
  env_bin="${DBDOG_ENV_BIN:-$(command -v env 2>/dev/null || true)}"
  bash_bin="${DBDOG_BASH_BIN:-/bin/bash}"
  [ -x "$timeout_bin" ] && [ -x "$runuser_bin" ] && [ -x "$env_bin" ] && \
    [ -x "$bash_bin" ] || return 1
  capture="$(mktemp "${TMPDIR:-/tmp}/dbdog-gauss-env.XXXXXX")" || return 1

  # profile 可能含命令，因此只在数据库 OS 用户权限下、空环境与硬超时中执行；
  # 输出只保留客户端启动所需白名单，绝不把 profile 的任意变量带回 root 安装器。
  # shellcheck disable=SC2016 # 下方单引号内容由目标数据库用户的内层 bash 解释。
  "$timeout_bin" --kill-after=2 10 "$runuser_bin" -u "$owner" -- "$env_bin" -i \
    HOME="$home" USER="$owner" LOGNAME="$owner" SHELL="$bash_bin" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DBDOG_SEED_MPP="$seed_mpp" DBDOG_EXPLICIT_ENV_FILE="$explicit_file" \
    "$bash_bin" --noprofile --norc -c '
      loaded=:
      load_env_file() {
        file=$1
        [ -n "$file" ] || return 0
        case "$file" in /*) ;; *) file="$HOME/$file" ;; esac
        [ -f "$file" ] && [ -r "$file" ] || return 0
        case "$loaded" in *":$file:"*) return 0 ;; esac
        { . "$file" </dev/null; } >/dev/null 2>&1 || return 1
        loaded="${loaded}${file}:"
      }

      load_env_file "$HOME/.profile"
      load_env_file "$HOME/.bash_profile"
      load_env_file "$HOME/.bashrc"
      mpp=${MPPDB_ENV_SEPARATE_PATH:-$DBDOG_SEED_MPP}
      load_env_file "$mpp"
      load_env_file "$HOME/gauss_env_file"
      load_env_file "$HOME/.gauss_env"
      load_env_file "$HOME/gsql_env.sh"
      if [ -n "${GAUSSHOME:-}" ]; then
        load_env_file "$GAUSSHOME/gsql_env.sh"
        load_env_file "$GAUSSHOME/bin/gsql_env.sh"
      fi
      if [ -n "$DBDOG_EXPLICIT_ENV_FILE" ]; then
        [ -f "$DBDOG_EXPLICIT_ENV_FILE" ] && [ -r "$DBDOG_EXPLICIT_ENV_FILE" ] || exit 42
        load_env_file "$DBDOG_EXPLICIT_ENV_FILE" required || exit 43
      fi
      printf "GAUSSHOME=%s\0" "${GAUSSHOME:-}"
      printf "GAUSSLOG=%s\0" "${GAUSSLOG:-}"
      printf "PGDATA=%s\0" "${PGDATA:-}"
      printf "PGHOST=%s\0" "${PGHOST:-}"
      printf "PGPORT=%s\0" "${PGPORT:-}"
      printf "LD_LIBRARY_PATH=%s\0" "${LD_LIBRARY_PATH:-}"
      printf "PATH=%s\0" "${PATH:-}"
      printf "MPPDB_ENV_SEPARATE_PATH=%s\0" "${MPPDB_ENV_SEPARATE_PATH:-$mpp}"
    ' >"$capture" 2>/dev/null || rc=$?

  if [ "$rc" -ne 0 ] || [ ! -s "$capture" ]; then
    rm -f -- "$capture"
    return 1
  fi
  while IFS= read -r -d '' record; do
    key="${record%%=*}"
    value="${record#*=}"
    case "$value" in *$'\n'* | *$'\r'*) invalid_capture=1; break ;; esac
    case "$key" in
      GAUSSHOME) AGENT_OWNER_ENV_GAUSSHOME="$value" ;;
      GAUSSLOG) AGENT_OWNER_ENV_GAUSSLOG="$value" ;;
      PGDATA) AGENT_OWNER_ENV_PGDATA="$value" ;;
      PGHOST) AGENT_OWNER_ENV_PGHOST="$value" ;;
      PGPORT) AGENT_OWNER_ENV_PGPORT="$value" ;;
      LD_LIBRARY_PATH) AGENT_OWNER_ENV_LD_LIBRARY_PATH="$value" ;;
      PATH) AGENT_OWNER_ENV_PATH="$value" ;;
      MPPDB_ENV_SEPARATE_PATH) : ;; # 仅驱动 profile 内二次加载，不向安装器传播。
    esac
  done <"$capture"
  rm -f -- "$capture"
  [ "$invalid_capture" -eq 0 ] || return 1
}

agent_cached_owner_environment() { # 参数同 agent_load_owner_environment；一次探测内按事实源复用
  local owner="$1" home="$2" seed_mpp="$3" explicit_file="$4" key index
  key="$owner|$home|$seed_mpp|$explicit_file"
  for ((index=0; index<${#AGENT_OWNER_ENV_CACHE_KEYS[@]}; index++)); do
    [ "${AGENT_OWNER_ENV_CACHE_KEYS[$index]}" = "$key" ] || continue
    AGENT_OWNER_ENV_GAUSSHOME="${AGENT_OWNER_ENV_CACHE_HOMES[$index]}"
    AGENT_OWNER_ENV_GAUSSLOG="${AGENT_OWNER_ENV_CACHE_LOGS[$index]}"
    AGENT_OWNER_ENV_PGDATA="${AGENT_OWNER_ENV_CACHE_DATA[$index]}"
    AGENT_OWNER_ENV_PGHOST="${AGENT_OWNER_ENV_CACHE_HOSTS[$index]}"
    AGENT_OWNER_ENV_PGPORT="${AGENT_OWNER_ENV_CACHE_PORTS[$index]}"
    AGENT_OWNER_ENV_LD_LIBRARY_PATH="${AGENT_OWNER_ENV_CACHE_LDS[$index]}"
    AGENT_OWNER_ENV_PATH="${AGENT_OWNER_ENV_CACHE_PATHS[$index]}"
    return 0
  done
  agent_load_owner_environment "$owner" "$home" "$seed_mpp" "$explicit_file" || return 1
  AGENT_OWNER_ENV_CACHE_KEYS+=("$key")
  AGENT_OWNER_ENV_CACHE_HOMES+=("$AGENT_OWNER_ENV_GAUSSHOME")
  AGENT_OWNER_ENV_CACHE_LOGS+=("$AGENT_OWNER_ENV_GAUSSLOG")
  AGENT_OWNER_ENV_CACHE_DATA+=("$AGENT_OWNER_ENV_PGDATA")
  AGENT_OWNER_ENV_CACHE_HOSTS+=("$AGENT_OWNER_ENV_PGHOST")
  AGENT_OWNER_ENV_CACHE_PORTS+=("$AGENT_OWNER_ENV_PGPORT")
  AGENT_OWNER_ENV_CACHE_LDS+=("$AGENT_OWNER_ENV_LD_LIBRARY_PATH")
  AGENT_OWNER_ENV_CACHE_PATHS+=("$AGENT_OWNER_ENV_PATH")
}

agent_cmdline_facts() { # <pid>；设置 AGENT_CMD_DATA_DIR / AGENT_CMD_PORT
  local pid="$1" root="${DBDOG_PROC_ROOT:-/proc}" arg expect=""
  AGENT_CMD_DATA_DIR=""
  AGENT_CMD_PORT=""
  [ -r "$root/$pid/cmdline" ] || return 0
  while IFS= read -r -d '' arg; do
    if [ "$expect" = data ]; then AGENT_CMD_DATA_DIR="$arg"; expect=""; continue; fi
    if [ "$expect" = port ]; then AGENT_CMD_PORT="$arg"; expect=""; continue; fi
    case "$arg" in
      -D | --pgdata | --data-directory) expect=data ;;
      -D?*) AGENT_CMD_DATA_DIR="${arg#-D}" ;;
      --pgdata=* | --data-directory=*) AGENT_CMD_DATA_DIR="${arg#*=}" ;;
      -p | --port) expect=port ;;
      -p?*) AGENT_CMD_PORT="${arg#-p}" ;;
      --port=*) AGENT_CMD_PORT="${arg#*=}" ;;
    esac
  done <"$root/$pid/cmdline"
}

agent_gauss_main_data_dir() { # <pid>；只接受由 postmaster.pid 正向证明的实例主进程
  local pid="$1" root="${DBDOG_PROC_ROOT:-/proc}" data cwd exe state recorded_pid candidate
  local candidates=()
  [ -r "$root/$pid/comm" ] || return 1
  [ "$(tr -d '\r\n' <"$root/$pid/comm")" = gaussdb ] || return 1
  [ -L "$root/$pid/exe" ] || return 1
  exe="$(readlink -f "$root/$pid/exe" 2>/dev/null || true)"
  [ "${exe##*/}" = gaussdb ] || return 1
  if [ -r "$root/$pid/status" ]; then
    state="$(awk '/^State:/ { print $2; exit }' "$root/$pid/status")"
    [ "$state" != Z ] || return 1
  fi

  agent_cmdline_facts "$pid"
  data="$AGENT_CMD_DATA_DIR"
  [ -n "$data" ] || data="$(agent_proc_env "$pid" PGDATA 2>/dev/null || true)"
  cwd="$(readlink -f "$root/$pid/cwd" 2>/dev/null || true)"
  if [ -z "$data" ]; then
    # 少数启动器既不保留 -D 也不导出 PGDATA；PostgreSQL/GaussDB 主进程通常
    # chdir 到实例目录。cwd 仍必须通过同一个 postmaster.pid PID 合同，不能单独采信。
    [ -z "$cwd" ] || candidates+=("$cwd")
  else
    case "$data" in
      /*) candidates+=("$data") ;;
      *)
        # postmaster 启动后通常已经 chdir(PGDATA)，但 cmdline 仍保留启动时的
        # 相对 -D；也兼容尚未 chdir、cwd 仍是其父目录的实现。两者都必须再过 pidfile。
        if [ -n "$cwd" ]; then candidates+=("$cwd" "$cwd/$data"); fi
        ;;
    esac
  fi
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
    [ -d "$candidate" ] && [ -r "$candidate/postmaster.pid" ] || continue
    recorded_pid="$(awk 'NR == 1 { print $1; exit }' "$candidate/postmaster.pid")"
    [ "$recorded_pid" = "$pid" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

agent_owner_home() { # <uid>
  local uid="$1" entry
  if command -v getent >/dev/null 2>&1; then
    entry="$(getent passwd "$uid" 2>/dev/null || true)"
  else
    entry="$(awk -F: -v uid="$uid" '$3 == uid { print; exit }' /etc/passwd 2>/dev/null || true)"
  fi
  [ -n "$entry" ] || return 1
  printf '%s\n' "$entry" | awk -F: '{print $6}'
}

agent_owner_name() { # <uid>
  local uid="$1" entry
  if command -v getent >/dev/null 2>&1; then
    entry="$(getent passwd "$uid" 2>/dev/null || true)"
  else
    entry="$(awk -F: -v uid="$uid" '$3 == uid { print; exit }' /etc/passwd 2>/dev/null || true)"
  fi
  [ -n "$entry" ] || return 1
  printf '%s\n' "$entry" | awk -F: '{print $1}'
}

agent_find_gauss_pids() { # 设置 AGENT_GAUSS_PIDS
  local root="${DBDOG_PROC_ROOT:-/proc}" path pid comm requested="${DBDOG_GAUSSDB_PID:-}"
  AGENT_GAUSS_PIDS=()
  if [ -n "$requested" ]; then
    case "$requested" in *[!0-9]* | '') die "DBDOG_GAUSSDB_PID 不是合法 PID" ;; esac
    [ -r "$root/$requested/comm" ] || die "找不到指定 GaussDB PID: $requested"
    comm="$(tr -d '\r\n' <"$root/$requested/comm")"
    [ "$comm" = gaussdb ] || die "指定 PID ${requested} 不是 gaussdb（comm=${comm}）"
    agent_gauss_main_data_dir "$requested" >/dev/null || \
      die "指定 PID ${requested} 不是可验证的 GaussDB 实例主进程（需由 PGDATA/postmaster.pid 记录该 PID）"
    AGENT_GAUSS_PIDS+=("$requested")
    return
  fi
  for path in "$root"/[0-9]*/comm; do
    [ -r "$path" ] || continue
    comm="$(tr -d '\r\n' <"$path")"
    [ "$comm" = gaussdb ] || continue
    pid="${path%/comm}"; pid="${pid##*/}"
    agent_gauss_main_data_dir "$pid" >/dev/null || continue
    AGENT_GAUSS_PIDS+=("$pid")
  done
}

agent_add_unique() { # <数组名> <值>；数组名仅限本文件内常量调用
  # shellcheck disable=SC2034 # current 在 eval 展开的循环体中使用。
  local name="$1" value="$2" current
  eval 'for current in ${'"$name"'[@]+"${'"$name"'[@]}"}; do
    [ "$current" != "$value" ] || return 0
  done'
  eval "$name+=(\"\$value\")"
}

agent_detect_gaussdb() {
  local root="${DBDOG_PROC_ROOT:-/proc}" pid data port env_port env_home env_log env_data
  local env_host env_ld env_path env_mpp uid owner_home owner exe gsql socket_dir
  local map_index mapped explicit_env="${DBDOG_GAUSSDB_ENV_FILE:-}"
  local old_conf="${AGENT_EXISTING_GAUSS_CONFIG:-}"
  case "$explicit_env" in "" | /*) ;; *) die "DBDOG_GAUSSDB_ENV_FILE 必须是绝对路径" ;; esac
  case "${DBDOG_GAUSSDB_PGHOST:-}" in
    "" | /*) ;;
    *) die "DBDOG_GAUSSDB_PGHOST 必须是绝对 Unix socket 目录，不能使用 TCP host" ;;
  esac
  AGENT_GAUSS_PORTS=()
  AGENT_GAUSS_LOG_GLOBS=()
  AGENT_GAUSS_PID_PORTS=()
  AGENT_GAUSS_PID_DATA_DIRS=()
  AGENT_GAUSS_PID_HOMES=()
  AGENT_GAUSS_PID_OWNERS=()
  AGENT_GAUSS_PID_OWNER_HOMES=()
  AGENT_GAUSS_PID_HOSTS=()
  AGENT_GAUSS_PID_LD_LIBRARY_PATHS=()
  AGENT_GAUSS_PID_PATHS=()
  AGENT_GAUSS_PID_GSQLS=()
  AGENT_GAUSS_PID_SOURCE_PIDS=()
  AGENT_OWNER_ENV_CACHE_KEYS=()
  AGENT_OWNER_ENV_CACHE_HOMES=()
  AGENT_OWNER_ENV_CACHE_LOGS=()
  AGENT_OWNER_ENV_CACHE_DATA=()
  AGENT_OWNER_ENV_CACHE_HOSTS=()
  AGENT_OWNER_ENV_CACHE_PORTS=()
  AGENT_OWNER_ENV_CACHE_LDS=()
  AGENT_OWNER_ENV_CACHE_PATHS=()
  agent_find_gauss_pids

  if [ "${#AGENT_GAUSS_PIDS[@]}" -eq 0 ]; then
    # openGauss 的主进程同样叫 gaussdb，会走到这条链上再由安装器分类；这里的
    # 「零 gaussdb 进程」只有在主机也没有其它受支持引擎（postgres）时才是硬失败，
    # 由安装器在全引擎检测后统一裁决（AGENT_GAUSS_ALLOW_NONE=1 时放行空结果）。
    if [ "${AGENT_GAUSS_ALLOW_NONE:-0}" = 1 ]; then
      return 0
    fi
    die "未发现可由 PGDATA/postmaster.pid 验证的运行中 GaussDB 实例主进程"
  fi

  for pid in ${AGENT_GAUSS_PIDS[@]+"${AGENT_GAUSS_PIDS[@]}"}; do
    owner_home=""
    owner=""
    data="$(agent_gauss_main_data_dir "$pid")" || continue
    agent_cmdline_facts "$pid"
    port="$AGENT_CMD_PORT"
    env_port="$(agent_proc_env "$pid" PGPORT 2>/dev/null || true)"
    env_home="$(agent_proc_env "$pid" GAUSSHOME 2>/dev/null || true)"
    env_log="$(agent_proc_env "$pid" GAUSSLOG 2>/dev/null || true)"
    env_data="$(agent_proc_env "$pid" PGDATA 2>/dev/null || true)"
    env_host="$(agent_proc_env "$pid" PGHOST 2>/dev/null || true)"
    env_ld="$(agent_proc_env "$pid" LD_LIBRARY_PATH 2>/dev/null || true)"
    env_path="$(agent_proc_env "$pid" PATH 2>/dev/null || true)"
    env_mpp="$(agent_proc_env "$pid" MPPDB_ENV_SEPARATE_PATH 2>/dev/null || true)"

    if [ -z "$env_home" ] && [ -L "$root/$pid/exe" ]; then
      exe="$(readlink -f "$root/$pid/exe" 2>/dev/null || true)"
      case "$exe" in */bin/gaussdb) env_home="${exe%/bin/gaussdb}" ;; esac
    fi

    if [ -r "$root/$pid/status" ]; then
      uid="$(awk '/^Uid:/ { print $2; exit }' "$root/$pid/status")"
      owner_home="$(agent_owner_home "$uid" 2>/dev/null || true)"
      owner="$(agent_owner_name "$uid" 2>/dev/null || true)"
      if ! agent_cached_owner_environment "$owner" "$owner_home" "$env_mpp" "$explicit_env"; then
        [ -z "$explicit_env" ] || \
          die "无法以 GaussDB 运行用户加载 DBDOG_GAUSSDB_ENV_FILE: $explicit_env"
        warn "未能加载 GaussDB 运行用户 profile；继续使用 /proc 运行态环境"
      else
        if [ -n "$explicit_env" ]; then
          # 显式环境文件代表操作者确认过的完整客户端环境，优先级高于自动事实。
          [ -z "$AGENT_OWNER_ENV_PGPORT" ] || env_port="$AGENT_OWNER_ENV_PGPORT"
          [ -z "$AGENT_OWNER_ENV_GAUSSHOME" ] || env_home="$AGENT_OWNER_ENV_GAUSSHOME"
          [ -z "$AGENT_OWNER_ENV_GAUSSLOG" ] || env_log="$AGENT_OWNER_ENV_GAUSSLOG"
          [ -z "$AGENT_OWNER_ENV_PGDATA" ] || env_data="$AGENT_OWNER_ENV_PGDATA"
          [ -z "$AGENT_OWNER_ENV_PGHOST" ] || env_host="$AGENT_OWNER_ENV_PGHOST"
          [ -z "$AGENT_OWNER_ENV_LD_LIBRARY_PATH" ] || env_ld="$AGENT_OWNER_ENV_LD_LIBRARY_PATH"
          [ -z "$AGENT_OWNER_ENV_PATH" ] || env_path="$AGENT_OWNER_ENV_PATH"
        else
          [ -n "$env_port" ] || env_port="$AGENT_OWNER_ENV_PGPORT"
          [ -n "$env_home" ] || env_home="$AGENT_OWNER_ENV_GAUSSHOME"
          [ -n "$env_log" ] || env_log="$AGENT_OWNER_ENV_GAUSSLOG"
          [ -n "$env_data" ] || env_data="$AGENT_OWNER_ENV_PGDATA"
          [ -n "$env_host" ] || env_host="$AGENT_OWNER_ENV_PGHOST"
          # gaussdb 服务进程和 gsql 客户端可能需要不同的补充库目录；运行态在前，profile 在后。
          env_ld="$(agent_merge_path_lists "$env_ld" "$AGENT_OWNER_ENV_LD_LIBRARY_PATH")"
          env_path="$(agent_merge_path_lists "$env_path" "$AGENT_OWNER_ENV_PATH")"
        fi
      fi
    fi
    [ -z "${DBDOG_GAUSSDB_PGHOST:-}" ] || env_host="$DBDOG_GAUSSDB_PGHOST"
    [ -z "${DBDOG_GAUSSDB_LD_LIBRARY_PATH:-}" ] || \
      env_ld="$DBDOG_GAUSSDB_LD_LIBRARY_PATH"
    [ -n "$data" ] || data="$env_data"
    if [ -z "$port" ] && [ -n "$data" ] && [ -r "$data/postmaster.pid" ]; then
      port="$(sed -n '4p' "$data/postmaster.pid" | tr -d '[:space:]')"
    fi
    [ -n "$port" ] || port="$env_port"
    if [ -z "$port" ] && [ -n "$data" ] && [ -r "$data/postgresql.conf" ]; then
      port="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*port[[:space:]]*=/ {
          sub(/^[^=]*=[[:space:]]*/, "")
          sub(/[[:space:]]*(#.*)?$/, "")
          print
          exit
        }
      ' "$data/postgresql.conf")"
    fi
    [ -n "${DBDOG_GAUSSDB_PORT:-}" ] && port="$DBDOG_GAUSSDB_PORT"
    agent_valid_port "$port" || die "无法从 gaussdb PID $pid 确定有效监听端口"
    agent_add_unique AGENT_GAUSS_PORTS "$port"

    # 这里发现的 PGHOST 只供安装期目标 gsql 管理连接使用，因此必须恢复为
    # 目标实例自己的 Unix socket；Agent 日常采集端点固定为 127.0.0.1 TCP。
    case "$env_host" in /*) ;; *) env_host="" ;; esac
    if [ -z "$env_host" ] && [ -n "$data" ] && [ -r "$data/postmaster.pid" ]; then
      socket_dir="$(sed -n '5p' "$data/postmaster.pid" | awk '{$1=$1; print}')"
      [ -z "$socket_dir" ] || env_host="$socket_dir"
    fi
    [ -n "$env_host" ] || env_host="$(agent_proc_socket_dir "$port" 2>/dev/null || true)"
    [ -n "$env_home" ] || die "无法从 gaussdb PID $pid 确定 GAUSSHOME"
    [ -n "$owner" ] || die "无法从 gaussdb PID $pid 确定运行用户"
    [ -n "$env_host" ] || \
      die "无法发现 GaussDB 本地 socket；可显式设置 DBDOG_GAUSSDB_PGHOST"
    case "$env_host" in
      /*) ;;
      *) die "发现的 GaussDB PGHOST 不是绝对 Unix socket 目录: $env_host" ;;
    esac

    # 实际运行环境优先，并只追加当前安装中真实存在的标准相对目录。
    [ ! -d "$env_home/lib" ] || env_ld="$(agent_merge_path_lists "$env_ld" "$env_home/lib")"
    [ ! -d "$env_home/lib/libsimsearch" ] || \
      env_ld="$(agent_merge_path_lists "$env_ld" "$env_home/lib/libsimsearch")"
    env_path="$(agent_merge_path_lists "$env_path" \
      "$env_home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")"
    gsql="$env_home/bin/gsql"
    [ -x "$gsql" ] || gsql="$(agent_find_in_path "$env_path" gsql 2>/dev/null || true)"
    [ -n "$gsql" ] || die "目标 GaussDB 客户端环境中找不到可执行 gsql"

    # 主进程已由 PGDATA/postmaster.pid 正向验证；这里仍对重复实例事实做防御性去重。
    mapped=0
    for ((map_index=0; map_index<${#AGENT_GAUSS_PID_PORTS[@]}; map_index++)); do
      [ "${AGENT_GAUSS_PID_PORTS[$map_index]}" = "$port" ] || continue
      [ "${AGENT_GAUSS_PID_HOSTS[$map_index]}" = "$env_host" ] || continue
      mapped=1
      [ -n "${AGENT_GAUSS_PID_DATA_DIRS[$map_index]}" ] || AGENT_GAUSS_PID_DATA_DIRS[map_index]="$data"
      [ -n "${AGENT_GAUSS_PID_HOMES[$map_index]}" ] || AGENT_GAUSS_PID_HOMES[map_index]="$env_home"
      [ -n "${AGENT_GAUSS_PID_OWNERS[$map_index]}" ] || AGENT_GAUSS_PID_OWNERS[map_index]="$owner"
      [ -n "${AGENT_GAUSS_PID_OWNER_HOMES[$map_index]}" ] || AGENT_GAUSS_PID_OWNER_HOMES[map_index]="$owner_home"
      [ -n "${AGENT_GAUSS_PID_HOSTS[$map_index]}" ] || AGENT_GAUSS_PID_HOSTS[map_index]="$env_host"
      AGENT_GAUSS_PID_LD_LIBRARY_PATHS[map_index]="$(agent_merge_path_lists \
        "${AGENT_GAUSS_PID_LD_LIBRARY_PATHS[$map_index]}" "$env_ld")"
      AGENT_GAUSS_PID_PATHS[map_index]="$(agent_merge_path_lists \
        "${AGENT_GAUSS_PID_PATHS[$map_index]}" "$env_path")"
      [ -n "${AGENT_GAUSS_PID_GSQLS[$map_index]}" ] || AGENT_GAUSS_PID_GSQLS[map_index]="$gsql"
      break
    done
    if [ "$mapped" -eq 0 ]; then
      AGENT_GAUSS_PID_PORTS+=("$port")
      AGENT_GAUSS_PID_DATA_DIRS+=("$data")
      AGENT_GAUSS_PID_HOMES+=("$env_home")
      AGENT_GAUSS_PID_OWNERS+=("$owner")
      AGENT_GAUSS_PID_OWNER_HOMES+=("$owner_home")
      AGENT_GAUSS_PID_HOSTS+=("$env_host")
      AGENT_GAUSS_PID_LD_LIBRARY_PATHS+=("$env_ld")
      AGENT_GAUSS_PID_PATHS+=("$env_path")
      AGENT_GAUSS_PID_GSQLS+=("$gsql")
      AGENT_GAUSS_PID_SOURCE_PIDS+=("$pid")
    fi

    # 两种落盘布局都要覆盖：多节点部署按节点名分子目录（gs_log/dn_6002/），集中式单节点
    # 直接落在 gs_log/ 下（2026-08-05 x86-gaussdb-73 实证）。tailer 对匹配不到的 glob 静默
    # 跳过，多给一条无副作用；只给带子目录那条会让集中式实例一条日志都采不到。
    if [ -n "$env_log" ]; then
      agent_add_unique AGENT_GAUSS_LOG_GLOBS "$env_log/gs_log/*/gaussdb-*.log"
      agent_add_unique AGENT_GAUSS_LOG_GLOBS "$env_log/gs_log/gaussdb-*.log"
    fi
  done

  [ "${#AGENT_GAUSS_PID_PORTS[@]}" -gt 0 ] || \
    die "GaussDB 主进程在事实探测期间退出或改变，未得到可安装实例"

  # 日常采集固定使用 127.0.0.1:port；两个实例若端口相同，即使管理 socket
  # 不同，也无法被该 TCP endpoint 唯一区分，必须在渲染配置前 fail closed。
  if [ "${#AGENT_GAUSS_PID_PORTS[@]}" -gt 0 ] && \
     [ "${#AGENT_GAUSS_PID_PORTS[@]}" -ne "${#AGENT_GAUSS_PORTS[@]}" ]; then
    die "发现多个 GaussDB 实例共享监听端口；127.0.0.1 TCP 监控无法唯一区分，请调整实例端口后重跑"
  fi

  if [ -n "${DBDOG_GAUSSDB_LOG_GLOB:-}" ]; then
    AGENT_GAUSS_LOG_GLOBS=("$DBDOG_GAUSSDB_LOG_GLOB")
  elif [ "${#AGENT_GAUSS_LOG_GLOBS[@]}" -eq 0 ]; then
    data="$(agent_existing_gauss_scalar "$old_conf" path 2>/dev/null || true)"
    [ -n "$data" ] && AGENT_GAUSS_LOG_GLOBS+=("$data")
  fi

  if [ "${#AGENT_GAUSS_LOG_GLOBS[@]}" -eq 0 ]; then
    # openGauss 实例常不设 GAUSSLOG（日志在 $PGDATA/pg_log，由安装器分类后另行推导）。
    # 只有当主机存在真 GaussDB 实例时缺 GAUSSLOG 才是硬失败——那由安装器在分类后裁决；
    # 这里在放行模式下先不拦。
    if [ "${AGENT_GAUSS_ALLOW_NONE:-0}" != 1 ]; then
      die "无法发现 GAUSSLOG；请只在首次安装时显式设置 DBDOG_GAUSSDB_LOG_GLOB"
    fi
  fi

  AGENT_GAUSS_DEPLOYMENT="${DBDOG_GAUSSDB_DEPLOYMENT:-}"
  if [ -z "$AGENT_GAUSS_DEPLOYMENT" ]; then
    if [ "${#AGENT_GAUSS_PID_PORTS[@]}" -gt 1 ]; then
      AGENT_GAUSS_DEPLOYMENT=distributed
    else
      AGENT_GAUSS_DEPLOYMENT=centralized
    fi
  fi
  case "$AGENT_GAUSS_DEPLOYMENT" in
    centralized | distributed) ;;
    *) die "DBDOG_GAUSSDB_DEPLOYMENT 只能是 centralized 或 distributed" ;;
  esac
}

agent_detect_postgres() {
  # PostgreSQL 实例事实探测（只读）。主进程判据与 gauss 检测同一口径：argv 带 -D 的
  # postgres 进程 + postmaster.pid 正向验证（辅助进程 cmdline 是 "postgres: xxx"，
  # 天然被 -D 过滤掉）。端口一律取运行态 postmaster.pid 第 4 行——配置文件可能改过
  # 未 reload。日志 glob 从 log_directory 推导（相对路径落在 data 目录下，PG 默认 log/），
  # 推不出时留空——logs 采集少一路是软缺口，不拦安装。
  local root="${DBDOG_PROC_ROOT:-/proc}" pid cmdline data port logdir args
  # 显式排除口子（DBDOG_POSTGRES_EXCLUDE_PORTS，空格/逗号分隔）：停掉某实例的监控是
  # 操作者决策，必须显式点名并大声记录，绝不允许静默缺口。典型场景：与监控无关的
  # 私人 dev 实例（其超管凭证不归监控体系管）。
  local excluded=",${DBDOG_POSTGRES_EXCLUDE_PORTS:-},"
  excluded="$(printf '%s' "$excluded" | tr ' 	' ',,')"
  AGENT_PG_PORTS=()
  AGENT_PG_DATA_DIRS=()
  AGENT_PG_LOG_GLOBS=()
  for pid in "$root"/[0-9]*; do
    pid="${pid##*/}"
    [ -r "$root/$pid/cmdline" ] || continue
    cmdline="$(tr '\0' '\n' <"$root/$pid/cmdline" 2>/dev/null || true)"
    [ -n "$cmdline" ] || continue
    case "$(printf '%s\n' "$cmdline" | head -1)" in
      */bin/postgres | postgres) ;;
      *) continue ;;
    esac
    # 取 -D 的下一个参数为 data 目录；没有 -D 的不是 postmaster 主进程。
    data="$(printf '%s\n' "$cmdline" | awk 'prev=="-D" { print; exit } { prev=$0 }')"
    [ -n "$data" ] || continue
    case "$data" in /*) ;; *) continue ;; esac
    [ -r "$data/postmaster.pid" ] || continue
    # postmaster.pid 首行必须就是该 PID——防把 standby 工具或残留 pid 文件当实例。
    [ "$(sed -n '1p' "$data/postmaster.pid" | tr -d '[:space:]')" = "$pid" ] || continue
    port="$(sed -n '4p' "$data/postmaster.pid" | tr -d '[:space:]')"
    agent_valid_port "$port" || die "无法从 postgres PID $pid 确定有效监听端口（$data）"
    case "$excluded" in *",$port,"*)
      warn "按 DBDOG_POSTGRES_EXCLUDE_PORTS 显式排除 PostgreSQL 实例 127.0.0.1:${port}（$data）——不监控它是操作者决策，不是静默缺口"
      continue ;;
    esac
    case " ${AGENT_PG_PORTS[*]-} " in *" $port "*) \
      die "发现多个 PostgreSQL 实例共享监听端口 ${port}；127.0.0.1 TCP 监控无法唯一区分" ;; esac
    AGENT_PG_PORTS+=("$port")
    AGENT_PG_DATA_DIRS+=("$data")
    logdir="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*log_directory[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
        gsub(/^'\''|'\''$/, ""); print; exit
      }
    ' "$data/postgresql.conf" 2>/dev/null || true)"
    [ -n "$logdir" ] || logdir=log
    case "$logdir" in /*) ;; *) logdir="$data/$logdir" ;; esac
    [ ! -d "$logdir" ] || agent_add_unique AGENT_PG_LOG_GLOBS "$logdir/*.log"
  done
}

agent_render_datadog_yaml() { # <文件> <server_url> <api_key> <hostname> <rc_root_json>
  local out="$1" server="$2" api_key="$3" hostname="$4" rc_root="$5" hostport no_ssl
  hostport="$(agent_server_hostport "$server")"
  case "$server" in https://*) no_ssl=false ;; *) no_ssl=true ;; esac
  cat >"$out" <<EOF
# Generated by dbdog-release/scripts/agent-install.sh; rerun that command to update.
api_key: $(agent_yaml_quote "$api_key")
hostname: $(agent_yaml_quote "$hostname")

dd_url: $(agent_yaml_quote "$server")
skip_ssl_validation: true
use_v3_api:
  series:
    enabled: true

database_monitoring:
  metrics:
    dd_url: $(agent_yaml_quote "$server")
  samples:
    dd_url: $(agent_yaml_quote "$server")
  activity:
    dd_url: $(agent_yaml_quote "$server")
  metadata:
    dd_url: $(agent_yaml_quote "$server")

confd_path: $(agent_yaml_quote "$AGENT_CONFIG_DIR/conf.d")
run_path: $(agent_yaml_quote "$AGENT_RUN_DIR")
log_file: $(agent_yaml_quote "$AGENT_LOG_DIR/agent.log")
log_level: info

# dbdog 使用自己的私有摄入端；不要向 Datadog 公网 instrumentation intake
# 发送 Agent/APM 遥测，避免隔离内网中的持续 DNS 错误和无效重试。
agent_telemetry:
  enabled: false

cmd_port: 5101
expvar_port: 5102
GUI_port: -1
agent_ipc:
  port: 0

enable_payloads:
  series: true
  events: true
  service_checks: true
  sketches: true

logs_enabled: true
use_dogstatsd: false
apm_config:
  enabled: true
  receiver_port: 5126
  apm_dd_url: $(agent_yaml_quote "$server")
  log_file: $(agent_yaml_quote "$AGENT_LOG_DIR/trace-agent.log")
  telemetry:
    enabled: false
ol_proxy_config:
  enabled: true
  dd_url: $(agent_yaml_quote "$server/api/v1/lineage")
  api_key: $(agent_yaml_quote "$api_key")
  api_version: 2
process_config:
  process_dd_url: $(agent_yaml_quote "$server")
  log_file: $(agent_yaml_quote "$AGENT_LOG_DIR/process-agent.log")
  cmd_port: 6163
  expvar_port: 6063
  language_detection:
    grpc_port: 6263
  process_collection:
    enabled: true
  container_collection:
    enabled: false
  process_discovery:
    enabled: true
    interval: 1h
remote_configuration:
  enabled: true
  rc_dd_url: $(agent_yaml_quote "$server")
  no_tls: $no_ssl
  no_tls_validation: true
  config_root: $(agent_yaml_quote "$rc_root")
  director_root: $(agent_yaml_quote "$rc_root")
inventories_enabled: true
enable_metadata_collection: true
cloud_provider_metadata: []
collect_ec2_tags: false

sbom:
  enabled: false
  dd_url: $(agent_yaml_quote "$server")
  container_image:
    enabled: false
container_image:
  enabled: false
  dd_url: $(agent_yaml_quote "$server")
container_lifecycle:
  enabled: false
  dd_url: $(agent_yaml_quote "$server")
network_devices:
  metadata:
    dd_url: $(agent_yaml_quote "$server")
  config_management:
    forwarder:
      dd_url: $(agent_yaml_quote "$server")
  snmp_traps:
    forwarder:
      dd_url: $(agent_yaml_quote "$server")
  netflow:
    forwarder:
      dd_url: $(agent_yaml_quote "$server")
network_path:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")
genresources:
  dd_url: $(agent_yaml_quote "$server")
synthetics:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")
event_management:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")
data_streams:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")
data_observability:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")
software_inventory:
  forwarder:
    dd_url: $(agent_yaml_quote "$server")

logs_config:
  logs_dd_url: $(agent_yaml_quote "$hostport")
  logs_no_ssl: $no_ssl
  use_http: true
  use_compression: true
  container_collect_all: false
EOF
}

agent_render_system_probe_yaml() { # <文件>
  cat >"$1" <<EOF
# Generated by dbdog-release/scripts/agent-install.sh.
log_file: $(agent_yaml_quote "$AGENT_LOG_DIR/system-probe.log")
system_probe_config:
  enabled: true
  sysprobe_socket: $(agent_yaml_quote "$AGENT_RUN_DIR/sysprobe.sock")
  process_service_inference:
    enabled: true

discovery:
  enabled: true
  service_collection_interval: 60s

network_config:
  enabled: true

service_monitoring_config:
  enabled: true
  http2:
    enabled: true
  kafka:
    enabled: true
  postgres:
    enabled: true
  redis:
    enabled: true

# 当前产品未启用 CWS/FIM，保持明确关闭。
runtime_security_config:
  enabled: false
  fim_enabled: false
EOF
}

# 渲染语义的权威是 dbdog-agent/dbdog-deploy/conf/conf.d 的三引擎模板（84a58e3 对齐）：
# 显式项只留 dbm/database_identifier/service/连接五元组/ignore_databases/relations/
# database_autodiscovery/query_samples.explain_function/collect_column_statistics/
# collect_activity_metrics/tags，其余采集开关一律用 check 默认值（避免部署漂移）。
# 引擎在位由检测结果决定：GaussDB 走完整建号链，openGauss/PostgreSQL 凭证只验不建
#（监控用户由 DBA 按 scripts/agent/init-dbdog-user-*-all-databases.sh 预先准备）。
agent_render_checks() { # <conf.d> <gauss_password> <db_user> <gauss_dbname> <env>
  local confd="$1" password="$2" username="$3" dbname="$4" env_name="$5"
  local check dir port glob
  local has_gauss=0 has_og=0 has_pg=0
  [ -z "${AGENT_GAUSSDB_RENDER_PORTS[*]-}" ] || has_gauss=1
  [ -z "${AGENT_OPENGAUSS_RENDER_PORTS[*]-}" ] || has_og=1
  [ -z "${AGENT_PG_PORTS[*]-}" ] || has_pg=1
  [ "$has_gauss$has_og$has_pg" != 000 ] || die "没有可渲染的数据库实例（GaussDB/openGauss/PostgreSQL 均未发现）"
  if [ "$has_gauss" = 1 ] && [ -z "$password" ]; then
    die "GaussDB 监控密码为空，无法渲染"
  fi
  # og/pg 凭证按实例走（同引擎多实例密码可各不相同）：渲染前每个端口都必须有密码。
  local cred_i
  if [ "$has_og" = 1 ]; then
    for ((cred_i=0; cred_i<${#AGENT_OPENGAUSS_RENDER_PORTS[@]}; cred_i++)); do
      [ -n "${AGENT_OPENGAUSS_RENDER_PASSWORDS[$cred_i]-}" ] || \
        die "openGauss 实例 127.0.0.1:${AGENT_OPENGAUSS_RENDER_PORTS[$cred_i]} 没有监控密码；凭证只验不建，请先由 DBA 跑 scripts/agent/init-dbdog-user-opengauss-all-databases.sh，再以 DBDOG_OPENGAUSS_MONITOR_PASSWORD 提供（升级路径自动按现有 conf 逐实例沿用）"
    done
  fi
  if [ "$has_pg" = 1 ]; then
    for ((cred_i=0; cred_i<${#AGENT_PG_PORTS[@]}; cred_i++)); do
      [ -n "${AGENT_PG_RENDER_PASSWORDS[$cred_i]-}" ] || \
        die "PostgreSQL 实例 127.0.0.1:${AGENT_PG_PORTS[$cred_i]} 没有监控密码；凭证只验不建，请先由 DBA 跑 scripts/agent/init-dbdog-user-pg-all-databases.sh，再以 DBDOG_POSTGRES_MONITOR_PASSWORD 提供（升级路径自动按现有 conf 逐实例沿用）"
    done
  fi
  for check in cpu disk file_handle io load memory network system_core uptime; do
    dir="$confd/$check.d"
    install -d -m 0755 "$dir"
    cat >"$dir/conf.yaml" <<'EOF'
init_config:
instances:
  # Agent 采集 cadence；前端查询 bucket/rollup 需独立选择。
  - min_collection_interval: 15
EOF
  done

  dir="$confd/process.d"
  install -d -m 0755 "$dir"
  cat >"$dir/conf.yaml" <<EOF
init_config:
instances:
EOF
  # openGauss 的进程名同样是 gaussdb；两类同机并存时只渲染 gaussdb 一条，避免同一批
  # 进程被两个实例重复聚合。
  if [ "$has_gauss" = 1 ] || [ "$has_og" = 1 ]; then
    local gauss_family_service=gaussdb
    [ "$has_gauss" = 1 ] || gauss_family_service=opengauss
    cat >>"$dir/conf.yaml" <<EOF
  - name: $gauss_family_service
    # Agent 采集 cadence；前端查询 bucket/rollup 需独立选择。
    min_collection_interval: 15
    search_string: ['gaussdb']
    exact_match: false
    collect_children: true
    tags:
      - service:$gauss_family_service
EOF
  fi
  if [ "$has_pg" = 1 ]; then
    cat >>"$dir/conf.yaml" <<EOF
  - name: postgres
    min_collection_interval: 15
    search_string: ['postgres']
    exact_match: false
    collect_children: true
    tags:
      - service:postgres
EOF
  fi

  if [ "$has_gauss" = 1 ]; then
    dir="$confd/gaussdb.d"
    install -d -m 0755 "$dir"
    cat >"$dir/conf.yaml" <<EOF
# Generated from target-host facts; rerun agent-install.sh after moving/reconfiguring GaussDB.
init_config:

instances:
EOF
    for port in "${AGENT_GAUSSDB_RENDER_PORTS[@]}"; do
      cat >>"$dir/conf.yaml" <<EOF
  - dbm: true
    database_identifier:
      # 分隔符用 '-' 不用 ':'（2026-08-06）：':' 是 DD 查询语法的 key/value 分隔符，标识里带它会让
      # 「按实例过滤」必须整体加引号——round-19 实证：裸写 database_instance:<host>:<port> 的调用
      # 104 次、98% 报错，而 skill 教的 service:<engine> 写法 80 次仅 4% 报错。区分同机多实例效果不变。
      # 有意偏离 DD 文档示例（上游 conf.yaml.example 为 \$env-\$resolved_hostname:\$port），军规 5 登记。
      # **首次安装即为横线形**；老机器的冒号形由 upgrade 路径一次性迁移（见 agent_migrate_identifier_separator）。
      template: '\$resolved_hostname-\$port'
    service: gaussdb
    host: 127.0.0.1
    port: $port
    username: $(agent_yaml_quote "$username")
    password: $(agent_yaml_quote "$password")
    # 主连接库。其余采集开关一律用 check 默认值，模板不显式配置（避免部署漂移）。
    dbname: $(agent_yaml_quote "$dbname")
    ignore_databases:
      - template0
      - template1
      - templatea
      - templatem
    relations:
      - relation_regex: .*
    query_samples:
      # canonical explain 入口在 public：GaussDB 的 SECURITY DEFINER 动态 SQL 按函数所属
      # schema 解析未限定表名，入口只在 dbdog schema 时解释不了 public 下的业务 SQL。
      explain_function: public.dbdog_explain_statement
    # 库自动发现：逐库采集非模板库的表级指标（relations/schema/column_stats）。
    # 默认关，这里显式开启；以 postgres 为 global_view_db，排除 GaussDB 模板库。
    database_autodiscovery:
      enabled: true
      global_view_db: postgres
      include:
        - .*
      exclude:
        - template0
        - template1
        - templatea
        - templatem
    # 列统计(pg_stats 投影)。上游默认调 datadog.column_statistics()；dbdog 命名下必须显式
    # 指向，否则报 schema "datadog" does not exist（2026-08-05 x86-gaussdb-73 实证）。
    collect_column_statistics:
      enabled: true
      function_name: dbdog.column_statistics()
    # activity 直发指标(active_queries/transactions.open 等；上游默认 false)，显式开启。
    collect_activity_metrics: true
    # 完成态(已结束语句)采集。check 默认 false，这里显式开启：它是 dbm_type:query_completion
    # 这条流的唯一来源，关着的话流是空的，而空集在诊断语境下会被读成"这台库没有慢 SQL"。
    # 来源是 dbe_perf.statement_history 系统表，不读服务器日志，故与下面 logs stanza 不重叠。
    statement_history:
      enabled: true
    tags:
      - $(agent_yaml_quote "env:$env_name")
      - $(agent_yaml_quote "gaussdb_deployment:$AGENT_GAUSS_DEPLOYMENT")
EOF
    done
    printf '\nlogs:\n' >>"$dir/conf.yaml"
    for glob in ${AGENT_GAUSS_LOG_GLOBS[@]+"${AGENT_GAUSS_LOG_GLOBS[@]}"}; do
      cat >>"$dir/conf.yaml" <<EOF
  - type: file
    path: $(agent_yaml_quote "$glob")
    source: gaussdb
    service: gaussdb
    # logs stanza 的 tags 与 instances 的 tags 是**两个作用域**，日志不继承 instance tag。
    # 不写这块的后果：日志事件 env 为空——env 是 dd.logs 官方 7 列之一，env:<环境> 筛选会整个
    # 漏掉本引擎（2026-08-04 box34 openGauss 实证）。
    tags:
      - $(agent_yaml_quote "env:$env_name")
      - dbm_source:gaussdb_logs
    log_processing_rules:
      - type: multi_line
        name: new_log_start_with_date
        pattern: '\\d{4}\\-(0?[1-9]|1[012])\\-(0?[1-9]|[12][0-9]|3[01])'
EOF
    done
  fi

  if [ "$has_og" = 1 ]; then
    dir="$confd/opengauss.d"
    install -d -m 0755 "$dir"
    cat >"$dir/conf.yaml" <<EOF
# Generated from target-host facts; rerun agent-install.sh after moving/reconfiguring openGauss.
init_config:

instances:
EOF
    for ((cred_i=0; cred_i<${#AGENT_OPENGAUSS_RENDER_PORTS[@]}; cred_i++)); do
      port="${AGENT_OPENGAUSS_RENDER_PORTS[$cred_i]}"
      cat >>"$dir/conf.yaml" <<EOF
  - dbm: true
    database_identifier:
      # opengauss- 前缀区分独立集成实例身份（与历史 gaussdb wire 模式实例不混淆）；
      # 分隔符用 '-' 不用 ':'，同 gaussdb.d 的军规 5 登记。
      template: 'opengauss-\$resolved_hostname-\$port'
    service: opengauss
    host: 127.0.0.1
    port: $port
    username: $(agent_yaml_quote "$username")
    password: $(agent_yaml_quote "${AGENT_OPENGAUSS_RENDER_PASSWORDS[$cred_i]}")
    # 主连接库。其余采集开关一律用 check 默认值，模板不显式配置（避免部署漂移）。
    dbname: $(agent_yaml_quote "${DBDOG_OPENGAUSS_DBNAME:-postgres}")
    ignore_databases:
      - template0
      - template1
      - templatea
      - templatem
    relations:
      - relation_regex: .*
    query_samples:
      # openGauss 与 GaussDB 同规则：SECURITY DEFINER 动态 SQL 按函数所属 schema
      # 解析未限定表名，canonical explain 入口在 public。
      explain_function: public.dbdog_explain_statement
    database_autodiscovery:
      enabled: true
      global_view_db: postgres
      include:
        - .*
      exclude:
        - template0
        - template1
        - templatea
        - templatem
    collect_column_statistics:
      enabled: true
      function_name: dbdog.column_statistics()
    collect_activity_metrics: true
    # 完成态(已结束语句)采集，同 gaussdb.d：check 默认 false，显式开启。读
    # dbe_perf.statement_history 系统表，与下面 logs stanza 采的服务器日志不是同一份数据。
    statement_history:
      enabled: true
    tags:
      - $(agent_yaml_quote "env:$env_name")
EOF
    done
    printf '\nlogs:\n' >>"$dir/conf.yaml"
    for glob in ${AGENT_OPENGAUSS_LOG_GLOBS[@]+"${AGENT_OPENGAUSS_LOG_GLOBS[@]}"}; do
      cat >>"$dir/conf.yaml" <<EOF
  - type: file
    path: $(agent_yaml_quote "$glob")
    source: opengauss
    service: opengauss
    tags:
      - $(agent_yaml_quote "env:$env_name")
      - dbm_source:opengauss_logs
    log_processing_rules:
      - type: multi_line
        name: new_log_start_with_date
        pattern: '\\d{4}\\-(0?[1-9]|1[012])\\-(0?[1-9]|[12][0-9]|3[01])'
EOF
    done
  fi

  if [ "$has_pg" = 1 ]; then
    dir="$confd/postgres.d"
    install -d -m 0755 "$dir"
    cat >"$dir/conf.yaml" <<EOF
# Generated from target-host facts; rerun agent-install.sh after moving/reconfiguring PostgreSQL.
init_config:

instances:
EOF
    for ((cred_i=0; cred_i<${#AGENT_PG_PORTS[@]}; cred_i++)); do
      port="${AGENT_PG_PORTS[$cred_i]}"
      cat >>"$dir/conf.yaml" <<EOF
  - dbm: true
    database_identifier:
      # 分隔符用 '-' 不用 ':'，同 gaussdb.d 的军规 5 登记。
      template: '\$resolved_hostname-\$port'
    service: postgres
    host: 127.0.0.1
    port: $port
    username: $(agent_yaml_quote "$username")
    password: $(agent_yaml_quote "${AGENT_PG_RENDER_PASSWORDS[$cred_i]}")
    # explain 函数走 dbdog 命名(2026-07-24 hard-cut；上游 check 默认值是 datadog.explain_statement)
    query_samples:
      explain_function: dbdog.explain_statement
    # 主连接库。其余采集开关一律用 check 默认值，模板不显式配置（避免部署漂移）。
    dbname: $(agent_yaml_quote "${DBDOG_POSTGRES_DBNAME:-postgres}")
    # 主连接库即 postgres，不能再 ignore 它；template 等默认库不入库。
    ignore_databases:
      - template0
      - template1
      - rdsadmin
      - azure_maintenance
      - cloudsqladmin
      - alloydbadmin
      - alloydbmetadata
    relations:
      - relation_regex: .*
    database_autodiscovery:
      enabled: true
      global_view_db: postgres
      include:
        - .*
      exclude:
        - template0
        - template1
    collect_column_statistics:
      enabled: true
      function_name: dbdog.column_statistics()
    collect_activity_metrics: true
    # 完成态(已结束语句)采集。check 默认 false，这里显式开启。
    # PG 没有服务端执行历史，来源只能是服务器日志：auto_explain(log_format=json) 为每条超过
    # auto_explain.log_min_duration 的执行写一条 plan 记录，本 job 直接 tail 该文件。
    # **必须与下面 logs stanza 的 exclude_at_match 同生共死**——两者读同一个文件，少了排除规则
    # 同一条慢 SQL 会既进 log 流又进 completion 流。
    query_completions:
      enabled: true
    tags:
      - $(agent_yaml_quote "env:$env_name")
      # dbdog 控制面用这两个内部 tag 把 schema 资产映射回本 check 的真实连接目标。
      - do_connection_host:127.0.0.1
      - do_connection_port:$port
EOF
    done
    printf '\nlogs:\n' >>"$dir/conf.yaml"
    for glob in ${AGENT_PG_LOG_GLOBS[@]+"${AGENT_PG_LOG_GLOBS[@]}"}; do
      cat >>"$dir/conf.yaml" <<EOF
  - type: file
    path: $(agent_yaml_quote "$glob")
    source: postgresql
    service: postgres
    tags:
      - $(agent_yaml_quote "env:$env_name")
      - dbm_source:postgres_logs
    log_processing_rules:
      - type: multi_line
        name: new_log_start_with_date
        pattern: '\\d{4}\\-(0?[1-9]|1[012])\\-(0?[1-9]|[12][0-9]|3[01])'
      # 上面 query_completions 把每条 auto_explain 记录报成 query_completion 事件，而它读的就是
      # 这个文件，所以不排掉的话同一条慢 SQL 会投递两次。pattern 与采集器的
      # LOG_PIPELINE_EXCLUDE_PATTERN 一字不差(dbdog-agent-core postgres/query_completions.py，
      # 那边有测试钉住二者)。
      # 注意本段不能出现反引号：这是 unquoted heredoc，反引号会被当命令替换执行掉。
      # 只排 auto_explain 写的 plan 记录：log_min_duration_statement 另写的
      # "duration: N ms  statement:" / "execute" 行永远不是 completion 来源(两条记录配不上对)，
      # 那批执行的唯一记录就是日志行，排掉即净丢数据。
      - type: exclude_at_match
        name: exclude_query_completions
        pattern: 'LOG:\\s+duration: [0-9.]+ ms\\s+plan:'
EOF
    done
  fi
}

agent_render_units() { # <目录>
  local out="$1"
  install -d -m 0755 "$out"
  cat >"$out/dbdog-agent-sysprobe.service" <<EOF
[Unit]
Description=dbdog private system-probe
Requires=sys-kernel-debug.mount
Before=dbdog-agent.service
After=network-online.target sys-kernel-debug.mount
PartOf=dbdog-agent.service

[Service]
Type=simple
PIDFile=$AGENT_RUN_DIR/system-probe.pid
ExecStart=$AGENT_RUNTIME_DIR/embedded/bin/system-probe run --config=$AGENT_CONFIG_DIR/system-probe.yaml --pid=$AGENT_RUN_DIR/system-probe.pid
Restart=on-failure
RestartSec=10
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  cat >"$out/dbdog-agent.service" <<EOF
[Unit]
Description=dbdog private Agent
After=network-online.target dbdog-agent-sysprobe.service
Wants=network-online.target
Requires=dbdog-agent-sysprobe.service

[Service]
Type=simple
User=root
# 这里刻意不声明 dbm-health 停摆开关（契约测试禁止它以任何取值复活，故此处不写其字面名）。
# 它曾是「server 没有 dbmhealth 端点」年代的停采补丁，server 0.1.12 起已落库采集配置快照，
# 理由消失；而它的失效是完全静默的（Python 层 return None，无日志、计数器为 0），
# 2026-08-07 黄区为此查了三轮。
# 定则：停发某类数据是产品决策，必须显式上升，不能由安装脚本默默决定。
ExecStartPre=/usr/bin/timeout 60 /bin/bash -c 'until test -S $AGENT_RUN_DIR/sysprobe.sock; do sleep 1; done'
ExecStart=$AGENT_RUNTIME_DIR/bin/agent/agent run -c $AGENT_CONFIG_DIR --sysprobecfgpath $AGENT_CONFIG_DIR
Restart=always
RestartSec=10
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  cat >"$out/dbdog-agent-trace.service" <<EOF
[Unit]
Description=dbdog private trace-agent and OpenLineage proxy
After=network-online.target dbdog-agent.service
Requires=dbdog-agent.service
PartOf=dbdog-agent.service

[Service]
Type=simple
User=root
ExecStart=$AGENT_RUNTIME_DIR/embedded/bin/trace-loader $AGENT_CONFIG_DIR/datadog.yaml $AGENT_RUNTIME_DIR/embedded/bin/trace-agent --config $AGENT_CONFIG_DIR/datadog.yaml --pidfile $AGENT_RUN_DIR/trace-agent.pid
Restart=always
RestartSec=10
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  cat >"$out/dbdog-agent-process.service" <<EOF
[Unit]
Description=dbdog private process-agent
After=network-online.target dbdog-agent.service dbdog-agent-sysprobe.service
Requires=dbdog-agent.service dbdog-agent-sysprobe.service
PartOf=dbdog-agent.service

[Service]
Type=simple
User=root
PIDFile=$AGENT_RUN_DIR/process-agent.pid
ExecStartPre=/usr/bin/timeout 60 /bin/bash -c 'until test -S $AGENT_RUN_DIR/sysprobe.sock; do sleep 1; done'
ExecStart=$AGENT_RUNTIME_DIR/embedded/bin/process-agent --cfgpath=$AGENT_CONFIG_DIR/datadog.yaml --sysprobe-config=$AGENT_CONFIG_DIR/system-probe.yaml --pid=$AGENT_RUN_DIR/process-agent.pid
Restart=on-failure
RestartSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}
