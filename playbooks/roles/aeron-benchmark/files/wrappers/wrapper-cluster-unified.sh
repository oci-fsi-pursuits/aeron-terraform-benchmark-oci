#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG_FILE="${1:-./config/benchmark-config.env}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

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

discover_cluster_nodes() {
  local user="$1"
  local key="$2"
  local client="${CLUSTER_SSH_CLIENT_NODE:-}"
  local node0="${CLUSTER_SSH_CLUSTER_NODE0:-}"
  local backup="${CLUSTER_SSH_BACKUP_NODE0:-}"

  if [[ -z "${client}" ]]; then
    for cand in 172.16.5.76 172.16.7.168; do
      if ssh_reachable "$user" "$key" "$cand"; then
        client="$cand"
        break
      fi
    done
  fi

  if [[ -z "${node0}" ]]; then
    for cand in 172.16.5.130 172.16.7.56; do
      if ssh_reachable "$user" "$key" "$cand"; then
        node0="$cand"
        break
      fi
    done
  fi

  if [[ -z "${backup}" ]]; then
    for cand in 172.16.5.178; do
      if ssh_reachable "$user" "$key" "$cand"; then
        backup="$cand"
        break
      fi
    done
  fi

  echo "${client},${node0},${backup}"
}

aeron_cluster_cpu_min() {
  local a=$1 b=$2
  if (( a <= b )); then echo "$a"; else echo "$b"; fi
}

aeron_cluster_apply_cpu_last() {
  local _last=$1
  export CLUSTER_AERON_SSH_TASKSET_CPUS="0-${_last}"
  export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="0-${_last}"
  export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="0-${_last}"
  export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="$(aeron_cluster_cpu_min 4 "${_last}")"
  export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="$(aeron_cluster_cpu_min 5 "${_last}")"
  export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="$(aeron_cluster_cpu_min 6 "${_last}")"
  export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="$(aeron_cluster_cpu_min 7 "${_last}")"
  export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="$(aeron_cluster_cpu_min 4 "${_last}")"
  export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="$(aeron_cluster_cpu_min 5 "${_last}")"
  export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="$(aeron_cluster_cpu_min 6 "${_last}")"
  export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="$(aeron_cluster_cpu_min 7 "${_last}")"
  export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="$(aeron_cluster_cpu_min 8 "${_last}")"
  export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="$(aeron_cluster_cpu_min 9 "${_last}")"
  export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="$(aeron_cluster_cpu_min 10 "${_last}")"
  export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="$(aeron_cluster_cpu_min 11 "${_last}")"
}

# Last logical CPU index on NUMA node 0 (matches numactl --cpunodebind=0 --physcpubind=... on cloud VMs).
cluster_probe_receiver_numa_node0_last_cpu() {
  local user="$1" key="$2" host="$3"
  [[ -z "$host" ]] && return 1
  local raw
  raw="$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
    "${user}@${host}" 'n=$(numactl --hardware 2>/dev/null | sed -n "s/^node 0 cpus: //p" | head -1); if [ -n "${n// /}" ]; then last=""; for x in $n; do last=$x; done; printf "%s" "$last"; else printf "%s" "$(($(nproc)-1))"; fi' 2>/dev/null || true)"
  raw="${raw//$'\r'/}"
  raw="${raw// /}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$raw"
}

CLIENT_MODE="${CLUSTER_CLIENT_MODE:-java}"
SERVER_MODE="${CLUSTER_SERVER_MODE:-java}"
CLIENT_DRIVER_ID="$(map_driver_mode "${CLIENT_MODE}")"
SERVER_DRIVER_ID="$(map_driver_mode "${SERVER_MODE}")"
SHOW_CONFIG_ONLY="${SHOW_CONFIG_ONLY:-0}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$(pick_default_key)}"
if [[ -z "${SSH_KEY_FILE}" ]]; then
  echo "ERROR: no SSH key found. Set SSH_KEY_FILE." >&2
  exit 1
fi

discovered="$(discover_cluster_nodes "${SSH_USER}" "${SSH_KEY_FILE}")"
d_client="${discovered%%,*}"
rest="${discovered#*,}"
d_node0="${rest%%,*}"
d_backup="${rest#*,}"

CLUSTER_CLIENT_NODE="${CLUSTER_SSH_CLIENT_NODE:-$d_client}"
CLUSTER_NODE0="${CLUSTER_SSH_CLUSTER_NODE0:-$d_node0}"
CLUSTER_BACKUP_NODE="${CLUSTER_SSH_BACKUP_NODE0:-$d_backup}"

if [[ -z "${CLUSTER_CLIENT_NODE}" || -z "${CLUSTER_NODE0}" ]]; then
  echo "ERROR: unable to discover cluster client/node0. Set CLUSTER_SSH_CLIENT_NODE and CLUSTER_SSH_CLUSTER_NODE0." >&2
  exit 1
fi

export SSH_CLIENT_USER="${CLUSTER_SSH_CLIENT_USER:-$SSH_USER}"
export SSH_CLIENT_KEY_FILE="${CLUSTER_SSH_CLIENT_KEY_FILE:-$SSH_KEY_FILE}"
export SSH_CLIENT_NODE="${CLUSTER_CLIENT_NODE}"
export SSH_SERVER_NODE="${CLUSTER_SSH_SERVER_NODE:-$CLUSTER_CLIENT_NODE}"
export SSH_SERVER_USER="${CLUSTER_SSH_SERVER_USER:-$SSH_USER}"
export SSH_SERVER_KEY_FILE="${CLUSTER_SSH_SERVER_KEY_FILE:-$SSH_KEY_FILE}"

export SSH_CLUSTER_USER0="${CLUSTER_SSH_CLUSTER_USER0:-$SSH_USER}"
export SSH_CLUSTER_KEY_FILE0="${CLUSTER_SSH_CLUSTER_KEY_FILE0:-$SSH_KEY_FILE}"
export SSH_CLUSTER_NODE0="${CLUSTER_NODE0}"

export SSH_CLUSTER_BACKUP_USER0="${CLUSTER_SSH_BACKUP_USER0:-$SSH_USER}"
export SSH_CLUSTER_BACKUP_KEY_FILE0="${CLUSTER_SSH_BACKUP_KEY_FILE0:-$SSH_KEY_FILE}"
export SSH_CLUSTER_BACKUP_NODE0="${CLUSTER_BACKUP_NODE:-}"

if [[ "${CLUSTER_CPU_AFFINITY_MODE:-auto}" == "auto" ]]; then
  _probe_last="$(cluster_probe_receiver_numa_node0_last_cpu "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" || true)"
  if [[ "${_probe_last}" =~ ^[0-9]+$ ]]; then
    echo "wrapper-cluster-unified: CLUSTER_CPU_AFFINITY_MODE=auto NUMA-node0 last_CPU=${_probe_last} (host ${SSH_CLUSTER_NODE0})" >&2
    aeron_cluster_apply_cpu_last "${_probe_last}"
  else
    _fb="${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-}"
    if [[ "${_fb}" =~ ^[0-9]+$ ]]; then
      echo "wrapper-cluster-unified: CLUSTER_CPU_AFFINITY_MODE=auto SSH probe failed; using CLUSTER_CPU_AFFINITY_FALLBACK_LAST=${_fb}" >&2
      aeron_cluster_apply_cpu_last "${_fb}"
    else
      echo "wrapper-cluster-unified: WARNING auto affinity probe failed and no CLUSTER_CPU_AFFINITY_FALLBACK_LAST; numactl may fail on small NUMA node0" >&2
    fi
  fi
fi

export CLUSTER_SIZE="${CLUSTER_SIZE:-1}"
export CLUSTER_ID="${CLUSTER_ID:-42}"
if [[ -n "${SSH_CLUSTER_BACKUP_NODE0}" ]]; then
  export CLUSTER_BACKUP_NODES="${CLUSTER_BACKUP_NODES:-1}"
else
  export CLUSTER_BACKUP_NODES=0
fi
export CLUSTER_APPOINTED_LEADER_ID="${CLUSTER_APPOINTED_LEADER_ID:-0}"
export DATA_DIR="${CLUSTER_DATA_DIR:-/home/ubuntu/cluster}"
export AERON_SSH_TASKSET_CPUS="${CLUSTER_AERON_SSH_TASKSET_CPUS:-0-${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-9}}"
export BACKUP_ENABLE_VMA="${CLUSTER_BACKUP_ENABLE_VMA:-0}"

export CLIENT_BENCHMARKS_PATH="${CLUSTER_CLIENT_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
export CLIENT_JAVA_HOME="${CLUSTER_CLIENT_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export CLIENT_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE:-4}"
export CLIENT_DRIVER_SENDER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE:-5}"
export CLIENT_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE:-6}"
export CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="${CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE:-7}"
export CLIENT_NON_ISOLATED_CPU_CORES="${CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES:-0-${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-9}}"
export CLIENT_CPU_NODE="${CLUSTER_CLIENT_CPU_NODE:-0}"
export CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS=
export CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS=

export NODE0_BENCHMARKS_PATH="${CLUSTER_NODE0_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
export NODE0_JAVA_HOME="${CLUSTER_NODE0_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export NODE0_CPU_NODE="${CLUSTER_NODE0_CPU_NODE:-0}"
export NODE0_NON_ISOLATED_CPU_CORES="${CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-0-${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-9}}"
export NODE0_AERON_DPDK_GATEWAY_IPV4_ADDRESS=
export NODE0_AERON_DPDK_LOCAL_IPV4_ADDRESS=
export NODE0_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-4}"
export NODE0_DRIVER_SENDER_CPU_CORE="${CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-5}"
export NODE0_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-6}"
export NODE0_CONSENSUS_MODULE_CPU_CORE="${CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE:-7}"
export NODE0_CLUSTERED_SERVICE_CPU_CORE="${CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-8}"
export NODE0_ARCHIVE_RECORDER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-9}"
export NODE0_ARCHIVE_REPLAYER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-10}"
export NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-11}"

NODE0_BASE="${CLUSTER_NODE0_BASE_PORT:-20000}"
BACKUP_BASE="${CLUSTER_BACKUP_BASE_PORT:-23000}"
NODE0_INGRESS_PORT=$((NODE0_BASE + 0))
NODE0_CONSENSUS_PORT=$((NODE0_BASE + 1))
NODE0_LOG_PORT=$((NODE0_BASE + 2))
NODE0_CATCHUP_PORT=$((NODE0_BASE + 3))
NODE0_ARCHIVE_PORT=$((NODE0_BASE + 4))

NODE0_IP="${SSH_CLUSTER_NODE0}"
export CLUSTER_MEMBERS="0,${NODE0_IP}:${NODE0_INGRESS_PORT},${NODE0_IP}:${NODE0_CONSENSUS_PORT},${NODE0_IP}:${NODE0_LOG_PORT},${NODE0_IP}:${NODE0_CATCHUP_PORT},${NODE0_IP}:${NODE0_ARCHIVE_PORT}"
export CLUSTER_CONSENSUS_ENDPOINTS="0=${NODE0_IP}:${NODE0_CONSENSUS_PORT}"
export NODE0_CLUSTER_DIR="${DATA_DIR}/node0/cluster"
export NODE0_ARCHIVE_DIR="${DATA_DIR}/node0/archive"
# Optional overrides from benchmark-config.env (node0 channels: |interface= for OCI; ingress must stay bare aeron:udp; client egress must not use client |interface= — leader reuses that URI).
export NODE0_CLUSTER_CONSENSUS_CHANNEL="${CLUSTER_NODE0_CLUSTER_CONSENSUS_CHANNEL:-aeron:udp?term-length=64k}"
export NODE0_CLUSTER_INGRESS_CHANNEL="${CLUSTER_NODE0_CLUSTER_INGRESS_CHANNEL:-aeron:udp}"
export NODE0_CLUSTER_LOG_CHANNEL="${CLUSTER_NODE0_CLUSTER_LOG_CHANNEL:-aeron:udp?term-length=64m|controlmode=manual|control=${NODE0_IP}:${NODE0_LOG_PORT}}"
export NODE0_CLUSTER_REPLICATION_CHANNEL="${CLUSTER_NODE0_CLUSTER_REPLICATION_CHANNEL:-aeron:udp?endpoint=${NODE0_IP}:20022}"
export NODE0_ARCHIVE_CONTROL_CHANNEL="${CLUSTER_NODE0_ARCHIVE_CONTROL_CHANNEL:-aeron:udp?endpoint=${NODE0_IP}:${NODE0_ARCHIVE_PORT}}"
export NODE0_ARCHIVE_REPLICATION_CHANNEL="${CLUSTER_NODE0_ARCHIVE_REPLICATION_CHANNEL:-aeron:udp?endpoint=${NODE0_IP}:20044}"
export CLIENT_INGRESS_CHANNEL="${CLUSTER_CLIENT_INGRESS_CHANNEL:-aeron:udp}"
export CLIENT_INGRESS_ENDPOINTS="0=${NODE0_IP}:${NODE0_INGRESS_PORT}"
export CLIENT_EGRESS_CHANNEL="${CLUSTER_CLIENT_EGRESS_CHANNEL:-aeron:udp?endpoint=${SSH_CLIENT_NODE}:0}"

if [[ "${CLUSTER_BACKUP_NODES}" == "1" ]]; then
  BACKUP_IP="${SSH_CLUSTER_BACKUP_NODE0}"
  BACKUP_CATCHUP_PORT=$((BACKUP_BASE + 3))
  BACKUP_ARCHIVE_CONTROL_PORT=$((BACKUP_BASE + 4))
  BACKUP_ARCHIVE_RESPONSE_PORT=$((BACKUP_BASE + 5))
  BACKUP_ARCHIVE_REPLICATION_PORT=$((BACKUP_BASE + 6))
  export BACKUP_NODE0_BENCHMARKS_PATH="${CLUSTER_NODE0_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
  export BACKUP_NODE0_JAVA_HOME="${CLUSTER_NODE0_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
  export BACKUP_NODE0_CPU_NODE="${CLUSTER_NODE0_CPU_NODE:-0}"
  export BACKUP_NODE0_NON_ISOLATED_CPU_CORES="${CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-0-${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-9}}"
  export BACKUP_NODE0_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-4}"
  export BACKUP_NODE0_DRIVER_SENDER_CPU_CORE="${CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-5}"
  export BACKUP_NODE0_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-6}"
  export BACKUP_NODE0_ARCHIVE_RECORDER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-9}"
  export BACKUP_NODE0_ARCHIVE_REPLAYER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-10}"
  export BACKUP_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-11}"
  export BACKUP_NODE0_CLUSTER_BACKUP_CPU_CORE="${CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-8}"
  export BACKUP_NODE0_AERON_DPDK_GATEWAY_IPV4_ADDRESS=
  export BACKUP_NODE0_AERON_DPDK_LOCAL_IPV4_ADDRESS=
  export BACKUP_NODE0_CLUSTER_DIR="${DATA_DIR}/backup/cluster"
  export BACKUP_NODE0_ARCHIVE_DIR="${DATA_DIR}/backup/archive"
  export BACKUP_NODE0_CLUSTER_CONSENSUS_CHANNEL="${CLUSTER_BACKUP_NODE0_CLUSTER_CONSENSUS_CHANNEL:-aeron:udp?term-length=64k|control-mode=manual}"
  export BACKUP_NODE0_CLUSTER_BACKUP_CATCHUP_CHANNEL="${CLUSTER_BACKUP_NODE0_CLUSTER_BACKUP_CATCHUP_CHANNEL:-aeron:udp?endpoint=${BACKUP_IP}:${BACKUP_CATCHUP_PORT}}"
  export BACKUP_NODE0_CLUSTER_BACKUP_CATCHUP_ENDPOINT="${BACKUP_IP}:${BACKUP_CATCHUP_PORT}"
  export BACKUP_NODE0_ARCHIVE_CONTROL_CHANNEL="${CLUSTER_BACKUP_NODE0_ARCHIVE_CONTROL_CHANNEL:-aeron:udp?endpoint=${BACKUP_IP}:${BACKUP_ARCHIVE_CONTROL_PORT}}"
  export BACKUP_NODE0_ARCHIVE_CONTROL_RESPONSE_CHANNEL="${CLUSTER_BACKUP_NODE0_ARCHIVE_CONTROL_RESPONSE_CHANNEL:-aeron:udp?endpoint=${BACKUP_IP}:${BACKUP_ARCHIVE_RESPONSE_PORT}}"
  export BACKUP_NODE0_ARCHIVE_REPLICATION_CHANNEL="${CLUSTER_BACKUP_NODE0_ARCHIVE_REPLICATION_CHANNEL:-aeron:udp?endpoint=${BACKUP_IP}:${BACKUP_ARCHIVE_REPLICATION_PORT}}"
fi

export RUNS="${RUNS:-5}"
export ITERATIONS="${ITERATIONS:-30}"
export WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-10}"
export WARMUP_MESSAGE_RATE="${WARMUP_MESSAGE_RATE:-25K}"
export MESSAGE_LENGTH="${MESSAGE_LENGTH:-288}"
export MESSAGE_RATE="${MESSAGE_RATE:-101K}"
export MTU_VALUE="${MTU_VALUE:-8K}"
export CLUSTER_READY_WAIT_SECONDS="${CLUSTER_READY_WAIT_SECONDS:-120}"
export AERON_TERM_BUFFER_SPARSE_FILE="${AERON_TERM_BUFFER_SPARSE_FILE:-false}"
export AERON_PRE_TOUCH_MAPPED_MEMORY="${AERON_PRE_TOUCH_MAPPED_MEMORY:-true}"
export AERON_SOCKET_SO_SNDBUF="${AERON_SOCKET_SO_SNDBUF:-2m}"
export AERON_SOCKET_SO_RCVBUF="${AERON_SOCKET_SO_RCVBUF:-2m}"
export AERON_RCV_INITIAL_WINDOW_LENGTH="${AERON_RCV_INITIAL_WINDOW_LENGTH:-2m}"
export AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND="${AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND:-1}"
export AERON_RECEIVER_IO_VECTOR_CAPACITY="${AERON_RECEIVER_IO_VECTOR_CAPACITY:-1}"
export AERON_SENDER_IO_VECTOR_CAPACITY="${AERON_SENDER_IO_VECTOR_CAPACITY:-1}"
export AERON_DIR="${AERON_DIR:-/home/${SSH_USER}/aeron-benchmark-shm}"

echo "=== Unified Cluster Wrapper ==="
echo "client=${SSH_CLIENT_NODE} node0=${SSH_CLUSTER_NODE0} backup=${SSH_CLUSTER_BACKUP_NODE0:-none}"
echo "drivers=${CLIENT_DRIVER_ID} vs ${SERVER_DRIVER_ID}"
echo "runs=${RUNS} iterations=${ITERATIONS} warmup=${WARMUP_ITERATIONS} size/rate=${MESSAGE_LENGTH}/${MESSAGE_RATE}"
echo "cluster_id=${CLUSTER_ID} cluster_size=${CLUSTER_SIZE} backup_nodes=${CLUSTER_BACKUP_NODES}"
echo "show-config-only=${SHOW_CONFIG_ONLY}"

if [[ "${SHOW_CONFIG_ONLY}" == "1" ]]; then
  echo "Configuration rendered successfully. Exiting without running benchmark."
  exit 0
fi

"aeron/remote-cluster-benchmarks" \
  --client-drivers "${CLIENT_DRIVER_ID}" \
  --server-drivers "${SERVER_DRIVER_ID}" \
  --onload "${ONLOAD_COMMAND:-env}" \
  --file-sync-level "${CLUSTER_FILE_SYNC_LEVEL:-0}" \
  --mtu "${MTU_VALUE}" \
  --context "${CLUSTER_CONTEXT:-cluster-unified}"
