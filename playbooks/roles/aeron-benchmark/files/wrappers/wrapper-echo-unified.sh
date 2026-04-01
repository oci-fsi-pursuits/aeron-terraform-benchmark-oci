#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Unified, config-first echo wrapper.
# Keeps existing workflow by invoking aeron/remote-echo-benchmarks.
# Default echo channels match Quick Start Appendix A; interface prefix is configurable (see AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH).
#
# Supported driver modes:
#   java | c | java_vma | c_vma | java-onload | c-onload | c-dpdk
#
# Usage examples:
#   ./wrapper-echo-unified.sh
#   BENCH_PROFILE=smoke_288_101k ./wrapper-echo-unified.sh
#   CLIENT_MODE=c SERVER_MODE=c ./wrapper-echo-unified.sh
#   Stack config uses stable names (e.g. aeron-benchmark-client / aeron-benchmark-receiver via /etc/hosts).
#   Or override: SSH_CLIENT_NODE=... SSH_SERVER_NODE=... ./wrapper-echo-unified.sh
#   SHOW_CONFIG_ONLY=1 ./wrapper-echo-unified.sh
#   WRAPPER_DEBUG=1 ./wrapper-echo-unified.sh   # bash -x before remote-echo-benchmarks

pick_default_key() {
  if [[ -f /home/ubuntu/.ssh/aeron-node-priv.key ]]; then
    echo "/home/ubuntu/.ssh/aeron-node-priv.key"
  elif [[ -f /opt/aeron/.ssh/deploy_key ]]; then
    echo "/opt/aeron/.ssh/deploy_key"
  elif [[ -f /home/ubuntu/.ssh/id_rsa ]]; then
    echo "/home/ubuntu/.ssh/id_rsa"
  else
    echo ""
  fi
}

ssh_reachable() {
  local user="$1"
  local key="$2"
  local host="$3"
  ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$user@$host" "echo ok" >/dev/null 2>&1
}

discover_nodes() {
  local user="$1"
  local key="$2"
  # Preferred order: no-SMT pair, then SMT pair.
  local pairs=(
    "172.16.5.76,172.16.5.130"
    "172.16.7.168,172.16.7.56"
  )
  for pair in "${pairs[@]}"; do
    local c="${pair%,*}"
    local s="${pair#*,}"
    if ssh_reachable "$user" "$key" "$c" && ssh_reachable "$user" "$key" "$s"; then
      echo "$c,$s"
      return
    fi
  done
  echo ","
}

map_driver_mode() {
  case "${1}" in
    java) echo "java" ;;
    c) echo "c" ;;
    java_vma|java-onload) echo "java-onload" ;;
    c_vma|c-onload) echo "c-onload" ;;
    c-dpdk|dpdk) echo "c-dpdk" ;;
    *)
      echo "Unsupported driver mode '${1}'" >&2
      exit 1
      ;;
  esac
}

profile_defaults() {
  case "${BENCH_PROFILE}" in
    latency_288_101k)
      RUNS="${RUNS:-5}"
      ITERATIONS="${ITERATIONS:-30}"
      WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-10}"
      MESSAGE_LENGTH="${MESSAGE_LENGTH:-288}"
      MESSAGE_RATE="${MESSAGE_RATE:-101K}"
      ;;
    smoke_288_101k)
      RUNS="${RUNS:-1}"
      ITERATIONS="${ITERATIONS:-5}"
      WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-3}"
      MESSAGE_LENGTH="${MESSAGE_LENGTH:-288}"
      MESSAGE_RATE="${MESSAGE_RATE:-101K}"
      ;;
    custom)
      RUNS="${RUNS:-1}"
      ITERATIONS="${ITERATIONS:-10}"
      WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-3}"
      MESSAGE_LENGTH="${MESSAGE_LENGTH:-288}"
      MESSAGE_RATE="${MESSAGE_RATE:-101K}"
      ;;
    *)
      echo "Unknown BENCH_PROFILE='${BENCH_PROFILE}' (use latency_288_101k|smoke_288_101k|custom)" >&2
      exit 1
      ;;
  esac
}

build_cpu_profile() {
  local host="$1"
  local user="$2"
  local key="$3"
  local cpus threads
  cpus="$(ssh -i "$key" -o StrictHostKeyChecking=no "$user@$host" 'getconf _NPROCESSORS_ONLN')"
  threads="$(ssh -i "$key" -o StrictHostKeyChecking=no "$user@$host" \
    "lscpu | awk -F: '/Thread\\(s\\) per core:/{gsub(/^[ \\t]+/,\"\",\$2); print \$2; exit}'")"

  if [[ "$threads" == "1" && "$cpus" -ge 16 ]]; then
    echo "taskset=0-3;nonisolated=0-15;conductor=4;sender=5;receiver=6;app=7;cpu_node=0"
  elif [[ "$threads" == "2" && "$cpus" -ge 20 ]]; then
    echo "taskset=0-3;nonisolated=0-3,4,6,8,10,12,14,16,18;conductor=4;sender=6;receiver=8;app=10;cpu_node=0"
  elif [[ "$threads" == "1" && "$cpus" -ge 10 ]]; then
    echo "taskset=0-1;nonisolated=0-9;conductor=2;sender=3;receiver=4;app=5;cpu_node=0"
  else
    echo "taskset=0-1;nonisolated=0-$((cpus-1));conductor=2;sender=3;receiver=4;app=5;cpu_node=0"
  fi
}

parse_profile_kv() {
  local input="$1"
  local key="$2"
  awk -F'[=;]' -v k="$key" '{for (i=1;i<=NF;i+=2) if ($i==k) {print $(i+1); exit}}' <<<"$input"
}

tune_socket_buffers_remote() {
  local user="$1"
  local key_file="$2"
  local host="$3"
  ssh -i "$key_file" -o StrictHostKeyChecking=no "$user@$host" \
    "sudo sysctl -w net.core.rmem_max=4194304 net.core.wmem_max=4194304 net.core.rmem_default=4194304 net.core.wmem_default=4194304 >/dev/null"
}

# Stale drivers + sticky /dev/shm: sudo-wipe default dir and the home AERON_DIR used when wrappers set it.
wipe_dev_shm_aeron_remote() {
  local user="$1"
  local key_file="$2"
  local host="$3"
  ssh -i "$key_file" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$user@$host" \
    "sudo rm -rf /dev/shm/aeron '/home/${user}/aeron-benchmark-shm'" 2>/dev/null || true
}

aeron_normalize_named_iface() {
  local n="${1:-}"
  [[ -z "$n" ]] && { echo ""; return; }
  if [[ "${n:0:1}" == "{" ]]; then
    echo "$n"
  else
    echo "{$n}"
  fi
}

check_numactl_bind_remote() {
  local user="$1"
  local key_file="$2"
  local host="$3"
  local cpus="$4"
  local label="$5"
  if ! ssh -i "$key_file" -o StrictHostKeyChecking=no "$user@$host" \
      "numactl --physcpubind='${cpus}' --show >/dev/null"; then
    echo "ERROR: ${label} NON_ISOLATED_CPU_CORES='${cpus}' is invalid for numactl on ${host}" >&2
    exit 1
  fi
}

# -------- Inputs / overrides --------
BENCH_PROFILE="${BENCH_PROFILE:-latency_288_101k}"
CONTEXT="${CONTEXT:-echo-unified}"
CLIENT_MODE="${CLIENT_MODE:-java}"
SERVER_MODE="${SERVER_MODE:-java}"
MTU_VALUE="${MTU_VALUE:-8K}"
ONLOAD_COMMAND="${ONLOAD_COMMAND:-env}"
SHOW_CONFIG_ONLY="${SHOW_CONFIG_ONLY:-0}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$(pick_default_key)}"
if [[ -z "${SSH_KEY_FILE}" ]]; then
  echo "ERROR: no SSH key found. Set SSH_KEY_FILE." >&2
  exit 1
fi

if [[ -z "${SSH_CLIENT_NODE:-}" || -z "${SSH_SERVER_NODE:-}" ]]; then
  discovered="$(discover_nodes "${SSH_USER}" "${SSH_KEY_FILE}")"
  d_client="${discovered%,*}"
  d_server="${discovered#*,}"
  SSH_CLIENT_NODE="${SSH_CLIENT_NODE:-$d_client}"
  SSH_SERVER_NODE="${SSH_SERVER_NODE:-$d_server}"
fi

if [[ -z "${SSH_CLIENT_NODE}" || -z "${SSH_SERVER_NODE}" ]]; then
  echo "ERROR: unable to auto-discover nodes. Set SSH_CLIENT_NODE and SSH_SERVER_NODE." >&2
  exit 1
fi

profile_defaults

client_auto="$(build_cpu_profile "${SSH_CLIENT_NODE}" "${SSH_USER}" "${SSH_KEY_FILE}")"
server_auto="$(build_cpu_profile "${SSH_SERVER_NODE}" "${SSH_USER}" "${SSH_KEY_FILE}")"

CLIENT_TASKSET="${CLIENT_TASKSET:-$(parse_profile_kv "$client_auto" taskset)}"
SERVER_TASKSET="${SERVER_TASKSET:-$(parse_profile_kv "$server_auto" taskset)}"
if [[ "${CLIENT_TASKSET}" != "${SERVER_TASKSET}" ]]; then
  # Keep orchestration taskset consistent with client by default.
  AERON_SSH_TASKSET_CPUS="${AERON_SSH_TASKSET_CPUS:-$CLIENT_TASKSET}"
else
  AERON_SSH_TASKSET_CPUS="${AERON_SSH_TASKSET_CPUS:-$CLIENT_TASKSET}"
fi

CLIENT_NON_ISOLATED_CPU_CORES="${CLIENT_NON_ISOLATED_CPU_CORES:-$(parse_profile_kv "$client_auto" nonisolated)}"
CLIENT_DRIVER_CONDUCTOR_CPU_CORE="${CLIENT_DRIVER_CONDUCTOR_CPU_CORE:-$(parse_profile_kv "$client_auto" conductor)}"
CLIENT_DRIVER_SENDER_CPU_CORE="${CLIENT_DRIVER_SENDER_CPU_CORE:-$(parse_profile_kv "$client_auto" sender)}"
CLIENT_DRIVER_RECEIVER_CPU_CORE="${CLIENT_DRIVER_RECEIVER_CPU_CORE:-$(parse_profile_kv "$client_auto" receiver)}"
CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="${CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE:-$(parse_profile_kv "$client_auto" app)}"
CLIENT_CPU_NODE="${CLIENT_CPU_NODE:-$(parse_profile_kv "$client_auto" cpu_node)}"

SERVER_NON_ISOLATED_CPU_CORES="${SERVER_NON_ISOLATED_CPU_CORES:-$(parse_profile_kv "$server_auto" nonisolated)}"
SERVER_DRIVER_CONDUCTOR_CPU_CORE="${SERVER_DRIVER_CONDUCTOR_CPU_CORE:-$(parse_profile_kv "$server_auto" conductor)}"
SERVER_DRIVER_SENDER_CPU_CORE="${SERVER_DRIVER_SENDER_CPU_CORE:-$(parse_profile_kv "$server_auto" sender)}"
SERVER_DRIVER_RECEIVER_CPU_CORE="${SERVER_DRIVER_RECEIVER_CPU_CORE:-$(parse_profile_kv "$server_auto" receiver)}"
SERVER_ECHO_CPU_CORE="${SERVER_ECHO_CPU_CORE:-$(parse_profile_kv "$server_auto" app)}"
SERVER_CPU_NODE="${SERVER_CPU_NODE:-$(parse_profile_kv "$server_auto" cpu_node)}"

# -------- Export expected environment --------
# Legacy bad benchmark-config.env (or bash/Jinja nesting) could leave "/24}" in URIs or "24}" in prefix → AsciiNumberFormatException.
_pf_leg="${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH-}"
if [[ -n "${_pf_leg}" ]] && [[ "${_pf_leg}" =~ [^0-9] ]]; then
  _pfx_digits="${_pf_leg//[^0-9]/}"
  [[ -n "${_pfx_digits}" ]] && export AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH="${_pfx_digits}"
fi

# Echo UDP: Aeron 1.50+ |interface={ifname} (see aeron-io/aeron NamedInterface), or |interface=IP/prefix (Quickstart), or omit.
if [[ -z "${AERON_ECHO_UDP_NAMED_INTERFACE:-}" ]] && [[ ! -v AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH ]]; then
  export AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=24
fi

_named_iface="$(aeron_normalize_named_iface "${AERON_ECHO_UDP_NAMED_INTERFACE:-}")"

export SSH_CLIENT_USER="${SSH_USER}"
export SSH_CLIENT_KEY_FILE="${SSH_KEY_FILE}"
export SSH_CLIENT_NODE
export SSH_SERVER_USER="${SSH_USER}"
export SSH_SERVER_KEY_FILE="${SSH_KEY_FILE}"
export SSH_SERVER_NODE
export AERON_SSH_TASKSET_CPUS

export CLIENT_BENCHMARKS_PATH="${CLIENT_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
export CLIENT_JAVA_HOME="${CLIENT_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export CLIENT_DRIVER_CONDUCTOR_CPU_CORE
export CLIENT_DRIVER_SENDER_CPU_CORE
export CLIENT_DRIVER_RECEIVER_CPU_CORE
export CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE
export CLIENT_NON_ISOLATED_CPU_CORES
export CLIENT_CPU_NODE
export CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS="${CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS:-}"
export CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS="${CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS:-}"
if [[ -n "${_named_iface}" ]]; then
  export AERON_ECHO_UDP_NAMED_INTERFACE="${_named_iface}"
  # Avoid ${VAR:-...|interface=${_named_iface}} — literal '}' in {ifname} closes the expansion early (malformed channel).
  if [[ -z "${CLIENT_SOURCE_CHANNEL:-}" ]]; then
    export CLIENT_SOURCE_CHANNEL="aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100|interface=${_named_iface}"
  fi
  if [[ -z "${CLIENT_DESTINATION_CHANNEL:-}" ]]; then
    export CLIENT_DESTINATION_CHANNEL="aeron:udp?endpoint=${SSH_SERVER_NODE}:13000|interface=${_named_iface}"
  fi
elif [[ -n "${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}" ]]; then
  # Do not use ${VAR:-...${OTHER}} here: the trailing }} closes both expansions and leaves '}' in the URI (AsciiNumberFormatException: 24}).
  if [[ -z "${CLIENT_SOURCE_CHANNEL:-}" ]]; then
    export CLIENT_SOURCE_CHANNEL="aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100|interface=${SSH_CLIENT_NODE}/${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}"
  fi
  if [[ -z "${CLIENT_DESTINATION_CHANNEL:-}" ]]; then
    export CLIENT_DESTINATION_CHANNEL="aeron:udp?endpoint=${SSH_SERVER_NODE}:13000|interface=${SSH_CLIENT_NODE}/${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}"
  fi
else
  export CLIENT_SOURCE_CHANNEL="${CLIENT_SOURCE_CHANNEL:-aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100}"
  export CLIENT_DESTINATION_CHANNEL="${CLIENT_DESTINATION_CHANNEL:-aeron:udp?endpoint=${SSH_SERVER_NODE}:13000}"
fi

export SERVER_BENCHMARKS_PATH="${SERVER_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
export SERVER_JAVA_HOME="${SERVER_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export SERVER_DRIVER_CONDUCTOR_CPU_CORE
export SERVER_DRIVER_SENDER_CPU_CORE
export SERVER_DRIVER_RECEIVER_CPU_CORE
export SERVER_ECHO_CPU_CORE
export SERVER_NON_ISOLATED_CPU_CORES
export SERVER_CPU_NODE
export SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS="${SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS:-}"
export SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS="${SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS:-}"
if [[ -n "${_named_iface}" ]]; then
  if [[ -z "${SERVER_SOURCE_CHANNEL:-}" ]]; then
    export SERVER_SOURCE_CHANNEL="aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100|interface=${_named_iface}"
  fi
  if [[ -z "${SERVER_DESTINATION_CHANNEL:-}" ]]; then
    export SERVER_DESTINATION_CHANNEL="aeron:udp?endpoint=${SSH_SERVER_NODE}:13000|interface=${_named_iface}"
  fi
elif [[ -n "${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}" ]]; then
  if [[ -z "${SERVER_SOURCE_CHANNEL:-}" ]]; then
    export SERVER_SOURCE_CHANNEL="aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100|interface=${SSH_SERVER_NODE}/${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}"
  fi
  if [[ -z "${SERVER_DESTINATION_CHANNEL:-}" ]]; then
    export SERVER_DESTINATION_CHANNEL="aeron:udp?endpoint=${SSH_SERVER_NODE}:13000|interface=${SSH_SERVER_NODE}/${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}"
  fi
else
  export SERVER_SOURCE_CHANNEL="${SERVER_SOURCE_CHANNEL:-aeron:udp?endpoint=${SSH_CLIENT_NODE}:13100}"
  export SERVER_DESTINATION_CHANNEL="${SERVER_DESTINATION_CHANNEL:-aeron:udp?endpoint=${SSH_SERVER_NODE}:13000}"
fi

# Fix /24} → /24 in channel URIs. Do not use export "VAR=$uri" — URIs contain '=' and bash can mangle the assignment.
for _ch_var in CLIENT_SOURCE_CHANNEL CLIENT_DESTINATION_CHANNEL SERVER_SOURCE_CHANNEL SERVER_DESTINATION_CHANNEL; do
  _ch_val="${!_ch_var-}"
  [[ -z "${_ch_val}" ]] && continue
  _ch_fixed="$(printf '%s' "${_ch_val}" | sed -E 's#/([0-9]+)\}+#/\1#g')"
  if [[ "${_ch_fixed}" != "${_ch_val}" ]]; then
    printf -v "${_ch_var}" '%s' "${_ch_fixed}"
    export "${_ch_var}"
  fi
done

export AERON_TERM_BUFFER_SPARSE_FILE="${AERON_TERM_BUFFER_SPARSE_FILE:-false}"
export AERON_PRE_TOUCH_MAPPED_MEMORY="${AERON_PRE_TOUCH_MAPPED_MEMORY:-true}"
export AERON_SOCKET_SO_SNDBUF="${AERON_SOCKET_SO_SNDBUF:-2m}"
export AERON_SOCKET_SO_RCVBUF="${AERON_SOCKET_SO_RCVBUF:-2m}"
export AERON_RCV_INITIAL_WINDOW_LENGTH="${AERON_RCV_INITIAL_WINDOW_LENGTH:-2m}"
export AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND="${AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND:-1}"
export AERON_RECEIVER_IO_VECTOR_CAPACITY="${AERON_RECEIVER_IO_VECTOR_CAPACITY:-1}"
export AERON_SENDER_IO_VECTOR_CAPACITY="${AERON_SENDER_IO_VECTOR_CAPACITY:-1}"
# Avoid /dev/shm/aeron (sticky shm + root-owned files → EPERM). remote-echo expands ${AERON_DIR} into benchmark.properties and patched helper rm.
export AERON_DIR="${AERON_DIR:-/home/${SSH_USER}/aeron-benchmark-shm}"

export RUNS ITERATIONS WARMUP_ITERATIONS MESSAGE_LENGTH MESSAGE_RATE
export WARMUP_MESSAGE_RATE="${WARMUP_MESSAGE_RATE:-25K}"

check_numactl_bind_remote "${SSH_CLIENT_USER}" "${SSH_CLIENT_KEY_FILE}" "${SSH_CLIENT_NODE}" "${CLIENT_NON_ISOLATED_CPU_CORES}" "client"
check_numactl_bind_remote "${SSH_SERVER_USER}" "${SSH_SERVER_KEY_FILE}" "${SSH_SERVER_NODE}" "${SERVER_NON_ISOLATED_CPU_CORES}" "server"
wipe_dev_shm_aeron_remote "${SSH_CLIENT_USER}" "${SSH_CLIENT_KEY_FILE}" "${SSH_CLIENT_NODE}"
wipe_dev_shm_aeron_remote "${SSH_SERVER_USER}" "${SSH_SERVER_KEY_FILE}" "${SSH_SERVER_NODE}"
tune_socket_buffers_remote "${SSH_CLIENT_USER}" "${SSH_CLIENT_KEY_FILE}" "${SSH_CLIENT_NODE}"
tune_socket_buffers_remote "${SSH_SERVER_USER}" "${SSH_SERVER_KEY_FILE}" "${SSH_SERVER_NODE}"

client_driver="$(map_driver_mode "${CLIENT_MODE}")"
server_driver="$(map_driver_mode "${SERVER_MODE}")"

echo "=== Unified Echo Wrapper ==="
echo "client=${SSH_CLIENT_NODE} server=${SSH_SERVER_NODE}"
echo "drivers=${client_driver} vs ${server_driver}"
echo "profile=${BENCH_PROFILE} runs=${RUNS} iterations=${ITERATIONS} warmup=${WARMUP_ITERATIONS}"
echo "size/rate=${MESSAGE_LENGTH}/${MESSAGE_RATE} mtu=${MTU_VALUE} context=${CONTEXT}"
echo "client cores: nonisolated=${CLIENT_NON_ISOLATED_CPU_CORES} pins=${CLIENT_DRIVER_CONDUCTOR_CPU_CORE},${CLIENT_DRIVER_SENDER_CPU_CORE},${CLIENT_DRIVER_RECEIVER_CPU_CORE},${CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE}"
echo "server cores: nonisolated=${SERVER_NON_ISOLATED_CPU_CORES} pins=${SERVER_DRIVER_CONDUCTOR_CPU_CORE},${SERVER_DRIVER_SENDER_CPU_CORE},${SERVER_DRIVER_RECEIVER_CPU_CORE},${SERVER_ECHO_CPU_CORE}"
echo "show-config-only=${SHOW_CONFIG_ONLY}"
echo "AERON_ECHO_UDP_NAMED_INTERFACE='${AERON_ECHO_UDP_NAMED_INTERFACE:-}' (Aeron 1.50+ {ifname} when set)"
echo "AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH='${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH}' (empty => omit |interface=)"
echo "CLIENT_SOURCE_CHANNEL=${CLIENT_SOURCE_CHANNEL}"
echo "CLIENT_DESTINATION_CHANNEL=${CLIENT_DESTINATION_CHANNEL}"
echo "SERVER_SOURCE_CHANNEL=${SERVER_SOURCE_CHANNEL}"
echo "SERVER_DESTINATION_CHANNEL=${SERVER_DESTINATION_CHANNEL}"
echo "AERON_DIR=${AERON_DIR}"

if [[ "${SHOW_CONFIG_ONLY}" == "1" ]]; then
  echo "Configuration rendered successfully. Exiting without running benchmark."
  exit 0
fi

if [[ "${WRAPPER_DEBUG:-}" == "1" ]]; then
  echo "WRAPPER_DEBUG=1: enabling set -x for remote-echo-benchmarks invocation" >&2
  set -x
fi

"aeron/remote-echo-benchmarks" \
  --client-drivers "${client_driver}" \
  --server-drivers "${server_driver}" \
  --onload "${ONLOAD_COMMAND}" \
  --mtu "${MTU_VALUE}" \
  --context "${CONTEXT}"
