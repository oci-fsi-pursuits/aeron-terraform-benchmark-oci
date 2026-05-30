#!/usr/bin/env bash
# Unified Aeron cluster benchmark runner.
#
# Usage:
#   ./run-cluster-benchmark.sh <driver> [rate] [options]
#
# Drivers: java | java_vma | c | c_vma
# Rates:   101K | 1001K  (default: 101K)
#
# Examples:
#   ./run-cluster-benchmark.sh java_vma 101K
#   ./run-cluster-benchmark.sh java 1001K --backup 1
#   DRIVER=c_vma RATE=101K RUNS=5 ./run-cluster-benchmark.sh
set -euo pipefail

CALL_NAME="$(basename "$0")"
case "${CALL_NAME}" in
  run-cluster-java-vma-1001k.sh)
    DEFAULT_DRIVER="java_vma"
    DEFAULT_RATE="1001K"
    ;;
  run-cluster-java-vma-101k.sh)
    DEFAULT_DRIVER="java_vma"
    DEFAULT_RATE="101K"
    ;;
  *)
    DEFAULT_DRIVER=""
    DEFAULT_RATE="101K"
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BENCH_SCRIPTS="${BENCH_SCRIPTS:-/opt/aeron/benchmarks-dist/scripts}"
if [[ -x "${SCRIPT_DIR}/wrapper-cluster-unified.sh" ]]; then
  BENCH_SCRIPTS="${SCRIPT_DIR}"
fi
cd "${BENCH_SCRIPTS}"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cluster_driver_uses_vma() {
  case "$1" in
    java_vma|java-onload|c_vma|c-onload) return 0 ;;
    *) return 1 ;;
  esac
}

cluster_driver_wrapper_ids() {
  case "$1" in
    java) echo "java java" ;;
    java_vma) echo "java_vma java_vma" ;;
    c) echo "c c" ;;
    c_vma) echo "c_vma c_vma" ;;
    *)
      echo "Unsupported driver '${1}'. Use: java | java_vma | c | c_vma" >&2
      return 1
      ;;
  esac
}

cluster_apply_driver_env() {
  local driver="$1" client_mode server_mode
  read -r client_mode server_mode <<< "$(cluster_driver_wrapper_ids "${driver}")"
  export CLUSTER_CLIENT_MODE="${client_mode}"
  export CLUSTER_SERVER_MODE="${server_mode}"

  if cluster_driver_uses_vma "${driver}"; then
    unset LD_PRELOAD || true
    export CLUSTER_BACKUP_ENABLE_VMA=1
    # Let benchmark-config.env provide the profile-specific VMA prefix.
    unset ONLOAD_COMMAND_PLAIN ONLOAD_COMMAND ONLOAD_COMMAND_VMA PLAIN_DRIVER_PREFIX VMA_DRIVER_PREFIX 2>/dev/null || true
  else
    export ONLOAD_COMMAND_PLAIN=env
    export ONLOAD_COMMAND=env
    export ONLOAD_COMMAND_VMA=env
    export PLAIN_DRIVER_PREFIX=env
    export VMA_DRIVER_PREFIX=env
    export CLUSTER_BACKUP_ENABLE_VMA=0
    env -u LD_PRELOAD true
  fi
}

cluster_deploy_media_driver_vma_fix() {
  local key="$1"
  shift
  local fixup="${BENCH_SCRIPTS}/aeron/aeron-vma-shm-fixup.sh"
  local md="${BENCH_SCRIPTS}/aeron/media-driver"
  local cmd="${BENCH_SCRIPTS}/aeron/c-media-driver"
  local remote_cluster="${BENCH_SCRIPTS}/aeron/remote-cluster-benchmarks"

  for host in "$@"; do
    scp -i "$key" -o StrictHostKeyChecking=no "${remote_cluster}" "ubuntu@${host}:${remote_cluster}" 2>/dev/null || true
    for f in "${fixup}" "${md}" "${cmd}"; do
      [[ -f "${f}" ]] || continue
      scp -i "$key" -o StrictHostKeyChecking=no "${f}" "ubuntu@${host}:${f}" 2>/dev/null || true
      ssh -i "$key" -o StrictHostKeyChecking=no "ubuntu@${host}" "chmod +x '${f}'" 2>/dev/null || true
    done
  done
}

cluster_prepare_nodes() {
  local driver="$1"
  local backup_nodes="$2"
  local key="${SSH_CLIENT_KEY_FILE:-${SSH_KEY_FILE:-/opt/aeron/.ssh/deploy_key}}"
  local -a hosts=(aeron-benchmark-client aeron-benchmark-receiver)

  if [[ "${backup_nodes}" != "0" ]]; then
    hosts+=(aeron-benchmark-failover)
  fi

  for host in "${hosts[@]}"; do
    ssh -i "$key" -o StrictHostKeyChecking=no "ubuntu@${host}" \
      'sudo setcap -r /opt/aeron/benchmarks-dist/scripts/aeron/aeronmd 2>/dev/null || true; ulimit -l unlimited 2>/dev/null || true' || true
  done

  if cluster_driver_uses_vma "${driver}"; then
    bash ./enable-vma-on-nodes.sh enable "${CONFIG_FILE}" > "${RUN_DIR}/enable-vma-state.log" 2>&1
    bash ./enable-vma-on-nodes.sh status "${CONFIG_FILE}" > "${RUN_DIR}/vma-status.log" 2>&1 || true
    cluster_deploy_media_driver_vma_fix "${key}" "${hosts[@]}"
  fi
}

cluster_apply_topology_env() {
  local driver="$1"
  local rate="$2"
  local backup="$3"
  local runs="${RUNS:-3}"
  local iterations="${ITERATIONS:-60}"
  local warmup="${WARMUP_ITERATIONS:-30}"

  export CONFIG_FILE="${CONFIG_FILE:-./config/benchmark-config.env}"
  export RUNS="${runs}"
  export ITERATIONS="${iterations}"
  export WARMUP_ITERATIONS="${warmup}"
  export WARMUP_MESSAGE_RATE="${WARMUP_MESSAGE_RATE:-25K}"
  export MESSAGE_LENGTH="${MESSAGE_LENGTH:-288}"
  export MESSAGE_RATE="${rate}"
  export MTU_VALUE="${MTU_VALUE:-8K}"

  export CLUSTER_SIZE="${CLUSTER_SIZE:-1}"
  export CLUSTER_BACKUP_NODES="${backup}"
  export CLUSTER_ID="${CLUSTER_ID:-42}"
  export CLUSTER_APPOINTED_LEADER_ID="${CLUSTER_APPOINTED_LEADER_ID:-0}"

  if cluster_driver_uses_vma "${driver}"; then
    export CLUSTER_SKIP_DROP_CACHES="${CLUSTER_SKIP_DROP_CACHES:-0}"
    export AERON_SHM_FIXUP_INTERVAL_SEC="${AERON_SHM_FIXUP_INTERVAL_SEC:-0.5}"
  else
    export CLUSTER_SKIP_DROP_CACHES="${CLUSTER_SKIP_DROP_CACHES:-1}"
  fi

  # BM RDMA validated defaults. benchmark-config.env may also set these; keep operator overrides honored.
  export CLUSTER_CPU_AFFINITY_MODE="${CLUSTER_CPU_AFFINITY_MODE:-static}"
  export CLUSTER_AERON_SSH_TASKSET_CPUS="${CLUSTER_AERON_SSH_TASKSET_CPUS:-20-31}"
  export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="${CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES:-20-31}"
  export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="${CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-20-31}"
  export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE:-24}"
  export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE:-25}"
  export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE:-26}"
  export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="${CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE:-27}"
  export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-24}"
  export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="${CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-25}"
  export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-26}"
  export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="${CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE:-27}"
  export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="${CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-28}"
  export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-29}"
  export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-30}"
  export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-31}"

  local backup_tag="no-backup"
  if [[ "${backup}" != "0" ]]; then
    backup_tag="1p-backup"
  fi
  export CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-cluster-${driver}-eth1-${rate}-r${runs}-i${iterations}-w${warmup}-${backup_tag}}"
}

DRIVER="${DRIVER:-${DEFAULT_DRIVER}}"
RATE="${RATE:-${DEFAULT_RATE}}"
BACKUP="${CLUSTER_BACKUP_NODES:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --driver) DRIVER="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --backup) BACKUP="$2"; shift 2 ;;
    --no-backup) BACKUP=0; shift ;;
    java|java_vma|c|c_vma)
      if [[ -z "${DRIVER}" ]]; then
        DRIVER="$1"
        shift
        continue
      fi
      echo "Unexpected driver argument: $1" >&2
      usage 1
      ;;
    101K|1001K) RATE="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${DRIVER}" ]] || { echo "Missing driver (java | java_vma | c | c_vma)" >&2; usage 1; }

RESULTS_ROOT="${RESULTS_ROOT:-${HOME}/benchmark-results}"
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/runs/$(date -u +%Y%m%dT%H%M%SZ)-cluster-${DRIVER}-${RATE}}"
mkdir -p "${RUN_DIR}"
mkdir -p "${RESULTS_ROOT}"
echo "${RUN_DIR}" > "${RESULTS_ROOT}/latest-run.txt"

cluster_apply_topology_env "${DRIVER}" "${RATE}" "${BACKUP}"
cluster_apply_driver_env "${DRIVER}"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) started cluster driver=${DRIVER} rate=${RATE} backup=${BACKUP} -> ${RUN_DIR}" | tee "${RUN_DIR}/STATUS.txt"

cluster_prepare_nodes "${DRIVER}" "${BACKUP}"

log="${RUN_DIR}/cluster-${DRIVER}-${RATE}.log"
if cluster_driver_uses_vma "${DRIVER}"; then
  env -u LD_PRELOAD bash ./wrapper-cluster-unified.sh "${CONFIG_FILE}" 2>&1 | tee "${log}"
else
  bash ./wrapper-cluster-unified.sh "${CONFIG_FILE}" 2>&1 | tee "${log}"
fi

latest="$(ls -t ./aeron-cluster-*-client.tar.gz 2>/dev/null | head -1 || true)"
if [[ -n "${latest}" ]]; then
  cp -f "${latest}" "${RUN_DIR}/"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) finished" | tee -a "${RUN_DIR}/STATUS.txt"
echo "RUN_DIR=${RUN_DIR}"
