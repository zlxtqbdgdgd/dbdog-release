#!/usr/bin/env bash
# dbdog-agent 安装辅助：目标机事实探测与配置渲染。
# 本文件只定义函数，供 agent-install.sh 与契约测试 source。

AGENT_RUNTIME_DIR="${AGENT_RUNTIME_DIR:-/opt/dbdog-agent}"
AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-/etc/dbdog-agent}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/dbdog-agent}"
AGENT_RUN_DIR="${AGENT_RUN_DIR:-$AGENT_RUNTIME_DIR/run}"

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

agent_profile_literal() { # <用户 home> <KEY>；只解析静态 export，不执行 shell 文件
  local home="$1" key="$2" file value
  [ -n "$home" ] || return 1
  for file in "$home/.bash_profile" "$home/.bashrc" "$home/.profile"; do
    [ -r "$file" ] || continue
    value="$(awk -v key="$key" '
      {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        sub(/^export[[:space:]]+/, "", line)
        if (index(line, key "=") == 1) {
          print substr(line, length(key) + 2)
          exit
        }
      }
    ' "$file")"
    [ -n "$value" ] || continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    # 只接受字面量。包含 shell 展开/命令语法时宁可让调用方继续找其他事实源。
    case "$value" in *'$'* | *'`'* | *';'* | *'&'* | *'|'*) continue ;; esac
    [ -n "$value" ] || continue
    printf '%s\n' "$value"
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
    [ "$comm" = gaussdb ] || die "指定 PID $requested 不是 gaussdb（comm=$comm）"
    AGENT_GAUSS_PIDS+=("$requested")
    return
  fi
  for path in "$root"/[0-9]*/comm; do
    [ -r "$path" ] || continue
    comm="$(tr -d '\r\n' <"$path")"
    [ "$comm" = gaussdb ] || continue
    pid="${path%/comm}"; pid="${pid##*/}"
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
  local uid home owner exe map_index mapped old_conf="${AGENT_EXISTING_GAUSS_CONFIG:-}"
  AGENT_GAUSS_PORTS=()
  AGENT_GAUSS_LOG_GLOBS=()
  AGENT_GAUSS_PID_PORTS=()
  AGENT_GAUSS_PID_DATA_DIRS=()
  AGENT_GAUSS_PID_HOMES=()
  AGENT_GAUSS_PID_OWNERS=()
  agent_find_gauss_pids

  if [ "${#AGENT_GAUSS_PIDS[@]}" -eq 0 ]; then
    port="${DBDOG_GAUSSDB_PORT:-}"
    [ -n "$port" ] || port="$(agent_existing_gauss_scalar "$old_conf" port 2>/dev/null || true)"
    agent_valid_port "$port" || die "未发现运行中的 gaussdb 进程，也没有可复用/显式指定的端口"
    AGENT_GAUSS_PORTS+=("$port")
  fi

  for pid in ${AGENT_GAUSS_PIDS[@]+"${AGENT_GAUSS_PIDS[@]}"}; do
    home=""
    owner=""
    agent_cmdline_facts "$pid"
    data="$AGENT_CMD_DATA_DIR"
    port="$AGENT_CMD_PORT"
    env_port="$(agent_proc_env "$pid" PGPORT 2>/dev/null || true)"
    env_home="$(agent_proc_env "$pid" GAUSSHOME 2>/dev/null || true)"
    env_log="$(agent_proc_env "$pid" GAUSSLOG 2>/dev/null || true)"
    env_data="$(agent_proc_env "$pid" PGDATA 2>/dev/null || true)"

    if [ -r "$root/$pid/status" ]; then
      uid="$(awk '/^Uid:/ { print $2; exit }' "$root/$pid/status")"
      home="$(agent_owner_home "$uid" 2>/dev/null || true)"
      owner="$(agent_owner_name "$uid" 2>/dev/null || true)"
      [ -n "$env_port" ] || env_port="$(agent_profile_literal "$home" PGPORT 2>/dev/null || true)"
      [ -n "$env_home" ] || env_home="$(agent_profile_literal "$home" GAUSSHOME 2>/dev/null || true)"
      [ -n "$env_log" ] || env_log="$(agent_profile_literal "$home" GAUSSLOG 2>/dev/null || true)"
      [ -n "$env_data" ] || env_data="$(agent_profile_literal "$home" PGDATA 2>/dev/null || true)"
    fi
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

    if [ -z "$env_home" ] && [ -L "$root/$pid/exe" ]; then
      exe="$(readlink -f "$root/$pid/exe" 2>/dev/null || true)"
      case "$exe" in */bin/gaussdb) env_home="${exe%/bin/gaussdb}" ;; esac
    fi
    # GaussDB 可能让多个后端进程都使用 comm=gaussdb；安装事实按实际端口去重，
    # 不能把每个 backend 误当成一个数据库实例重复初始化。
    mapped=0
    for ((map_index=0; map_index<${#AGENT_GAUSS_PID_PORTS[@]}; map_index++)); do
      [ "${AGENT_GAUSS_PID_PORTS[$map_index]}" = "$port" ] || continue
      mapped=1
      [ -n "${AGENT_GAUSS_PID_DATA_DIRS[$map_index]}" ] || AGENT_GAUSS_PID_DATA_DIRS[map_index]="$data"
      [ -n "${AGENT_GAUSS_PID_HOMES[$map_index]}" ] || AGENT_GAUSS_PID_HOMES[map_index]="$env_home"
      [ -n "${AGENT_GAUSS_PID_OWNERS[$map_index]}" ] || AGENT_GAUSS_PID_OWNERS[map_index]="$owner"
      break
    done
    if [ "$mapped" -eq 0 ]; then
      AGENT_GAUSS_PID_PORTS+=("$port")
      AGENT_GAUSS_PID_DATA_DIRS+=("$data")
      AGENT_GAUSS_PID_HOMES+=("$env_home")
      AGENT_GAUSS_PID_OWNERS+=("$owner")
    fi

    [ -n "$env_log" ] && agent_add_unique AGENT_GAUSS_LOG_GLOBS "$env_log/gs_log/*/gaussdb-*.log"
  done

  if [ -n "${DBDOG_GAUSSDB_LOG_GLOB:-}" ]; then
    AGENT_GAUSS_LOG_GLOBS=("$DBDOG_GAUSSDB_LOG_GLOB")
  elif [ "${#AGENT_GAUSS_LOG_GLOBS[@]}" -eq 0 ]; then
    data="$(agent_existing_gauss_scalar "$old_conf" path 2>/dev/null || true)"
    [ -n "$data" ] && AGENT_GAUSS_LOG_GLOBS+=("$data")
  fi

  [ "${#AGENT_GAUSS_LOG_GLOBS[@]}" -gt 0 ] || \
    die "无法发现 GAUSSLOG；请只在首次安装时显式设置 DBDOG_GAUSSDB_LOG_GLOB"

  AGENT_GAUSS_DEPLOYMENT="${DBDOG_GAUSSDB_DEPLOYMENT:-}"
  if [ -z "$AGENT_GAUSS_DEPLOYMENT" ]; then
    if [ "${#AGENT_GAUSS_PORTS[@]}" -gt 1 ]; then
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
EOF
}

agent_render_checks() { # <conf.d> <db_password> <db_user> <db_name> <env>
  local confd="$1" password="$2" username="$3" dbname="$4" env_name="$5"
  local check dir port glob
  for check in cpu disk file_handle io load memory network system_core uptime; do
    dir="$confd/$check.d"
    install -d -m 0755 "$dir"
    printf 'init_config:\ninstances:\n  - {}\n' >"$dir/conf.yaml"
  done

  dir="$confd/process.d"
  install -d -m 0755 "$dir"
  cat >"$dir/conf.yaml" <<EOF
init_config:
instances:
  - name: gaussdb
    search_string: ['gaussdb']
    exact_match: false
    collect_children: true
    tags:
      - service:gaussdb
EOF

  dir="$confd/gaussdb.d"
  install -d -m 0755 "$dir"
  cat >"$dir/conf.yaml" <<EOF
# Generated from target-host facts; rerun agent-install.sh after moving/reconfiguring GaussDB.
init_config:

instances:
EOF
  for port in "${AGENT_GAUSS_PORTS[@]}"; do
    cat >>"$dir/conf.yaml" <<EOF
  - dbm: true
    database_identifier:
      template: '\$resolved_hostname:\$port'
    service: gaussdb
    host: 127.0.0.1
    port: $port
    username: $(agent_yaml_quote "$username")
    password: $(agent_yaml_quote "$password")
    dbname: $(agent_yaml_quote "$dbname")
    ignore_databases:
      - template0
      - template1
      - templatea
      - templatem
    relations:
      - relation_regex: .*
    collect_schemas:
      enabled: true
      collection_interval: 30
      max_tables: 300
      max_columns: 50
    collect_settings:
      enabled: true
      collection_interval: 30
    collect_database_size_metrics: true
    collect_activity_metrics: true
    data_observability:
      enabled: false
    tags:
      - $(agent_yaml_quote "env:$env_name")
      - $(agent_yaml_quote "gaussdb_deployment:$AGENT_GAUSS_DEPLOYMENT")
EOF
  done
  printf '\nlogs:\n' >>"$dir/conf.yaml"
  for glob in "${AGENT_GAUSS_LOG_GLOBS[@]}"; do
    cat >>"$dir/conf.yaml" <<EOF
  - type: file
    path: $(agent_yaml_quote "$glob")
    source: gaussdb
    service: gaussdb
    log_processing_rules:
      - type: multi_line
        name: new_log_start_with_date
        pattern: '\\d{4}\\-(0?[1-9]|1[012])\\-(0?[1-9]|[12][0-9]|3[01])'
EOF
  done
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
Environment=DBDOG_DISABLE_DBM_HEALTH=true
Environment=DBDOG_SCHEMA_RECOMMENDATION_FIELDS=true
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
