#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_ROOT="$(pwd)"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./enable-vma-on-nodes.sh [enable|disable|status] [config-file]

Defaults:
  action      enable
  config-file ./config/benchmark-config.env

Environment:
  VMA_LIB_PATH          libvma soname path; default parsed from ONLOAD_COMMAND_VMA
  VMA_REQUIRE_RDMA      fail enable when no IB/RDMA device is visible; default 1
  VMA_APPLY_FILE_CAPS   apply cap_net_raw+ep to Java; default 0

This script prepares benchmark nodes for a VMA-only run. It intentionally does
not put LD_PRELOAD in a global OS profile; the VMA benchmark wrapper owns that.
EOF
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

vma_ld_preload_path_from_cmd() {
  local s="${1:-}" lib_path=""
  if [[ "${s}" =~ LD_PRELOAD=([^[:space:]]+) ]]; then
    lib_path="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${lib_path}"
}

ACTION="${1:-enable}"
case "${ACTION}" in
  enable|disable|status)
    shift || true
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    usage
    exit 1
    ;;
esac

CONFIG_FILE="${1:-${CONFIG_FILE:-./config/benchmark-config.env}}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ -f "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh"
fi

set -a
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
set +a

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$(pick_default_key)}"
if [[ -z "${SSH_KEY_FILE}" || ! -f "${SSH_KEY_FILE}" ]]; then
  echo "ERROR: SSH_KEY_FILE missing or not readable. Set SSH_KEY_FILE." >&2
  exit 1
fi

VMA_LIB_PATH="${VMA_LIB_PATH:-$(vma_ld_preload_path_from_cmd "${ONLOAD_COMMAND_VMA:-}")}"
VMA_LIB_PATH="${VMA_LIB_PATH:-/usr/lib/x86_64-linux-gnu/libvma.so.9}"
VMA_REQUIRE_RDMA="${VMA_REQUIRE_RDMA:-1}"
VMA_APPLY_FILE_CAPS="${VMA_APPLY_FILE_CAPS:-0}"
BENCHMARKS_PATH="${CLIENT_BENCHMARKS_PATH:-${CLUSTER_CLIENT_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}}"

declare -A seen_hosts=()
hosts=()
add_host() {
  local h="${1:-}"
  [[ -z "${h}" ]] && return 0
  if [[ -z "${seen_hosts[$h]+x}" ]]; then
    hosts+=("${h}")
    seen_hosts["${h}"]=1
  fi
}

add_host "${SSH_CLIENT_NODE:-}"
add_host "${SSH_SERVER_NODE:-}"
add_host "${CLUSTER_SSH_CLIENT_NODE:-}"
add_host "${CLUSTER_SSH_CLUSTER_NODE0:-}"
add_host "${CLUSTER_SSH_CLUSTER_NODE1:-}"
add_host "${CLUSTER_SSH_CLUSTER_NODE2:-}"
if [[ "${CLUSTER_BACKUP_NODES:-0}" == "1" ]]; then
  add_host "${CLUSTER_SSH_BACKUP_NODE0:-}"
fi

if [[ "${#hosts[@]}" -eq 0 ]]; then
  echo "ERROR: no benchmark hosts found in ${CONFIG_FILE}" >&2
  exit 1
fi

printf 'VMA action=%s hosts=%s lib=%s apply_caps=%s require_rdma=%s\n' \
  "${ACTION}" "${hosts[*]}" "${VMA_LIB_PATH}" "${VMA_APPLY_FILE_CAPS}" "${VMA_REQUIRE_RDMA}"

remote_action() {
  local host="$1"
  echo "=== ${ACTION}: ${host} ==="
  ssh -i "${SSH_KEY_FILE}" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=20 \
    "${SSH_USER}@${host}" \
    "bash -s -- $(printf '%q' "${ACTION}") $(printf '%q' "${VMA_LIB_PATH}") $(printf '%q' "${BENCHMARKS_PATH}") $(printf '%q' "${SSH_USER}") $(printf '%q' "${VMA_REQUIRE_RDMA}") $(printf '%q' "${VMA_APPLY_FILE_CAPS}")" <<'EOS'
set -euo pipefail

action="$1"
lib_path="$2"
benchmarks_path="$3"
ssh_user="$4"
require_rdma="$5"
apply_caps="$6"

find_java() {
  local j
  for j in \
    "${JAVA_HOME:-}/bin/java" \
    /usr/lib/jvm/java-21-openjdk-amd64/bin/java \
    /usr/lib/jvm/java-17-openjdk-amd64/bin/java \
    /usr/lib/jvm/java-21-openjdk/bin/java \
    /usr/lib/jvm/java-17-openjdk/bin/java; do
    [[ -n "${j}" && -x "${j}" ]] && { printf '%s\n' "${j}"; return 0; }
  done
  command -v java 2>/dev/null || true
}

native_bins() {
  local p
  for p in \
    "${benchmarks_path}/scripts/aeron/aeronmd" \
    "${benchmarks_path}/scripts/aeron/c-media-driver" \
    "${benchmarks_path}/scripts/aeron/c-aeronmd"; do
    [[ -e "${p}" ]] && printf '%s\n' "${p}"
  done
}

rdma_ok() {
  if command -v ibv_devices >/dev/null 2>&1; then
    ibv_devices 2>/dev/null | awk 'NR > 2 && NF { found=1 } END { exit found ? 0 : 1 }'
    return $?
  fi
  [[ -d /sys/class/infiniband ]] && compgen -G "/sys/class/infiniband/*" >/dev/null
}

print_rdma() {
  echo "-- rdma devices --"
  (command -v ibv_devices >/dev/null 2>&1 && ibv_devices) || true
  ls -la /sys/class/infiniband 2>/dev/null || true
  (command -v rdma >/dev/null 2>&1 && rdma link) || true
  ip -br link 2>/dev/null || true
}

print_caps() {
  echo "-- capabilities --"
  if command -v getcap >/dev/null 2>&1; then
    local java_path
    java_path="$(find_java || true)"
    [[ -n "${java_path}" ]] && getcap "${java_path}" 2>/dev/null || true
    while IFS= read -r b; do
      getcap "${b}" 2>/dev/null || true
    done < <(native_bins)
  else
    echo "getcap not installed"
  fi
}

cleanup_benchmark_processes() {
  sudo pkill -f 'io[.]aeron[.]driver[.]MediaDriver' 2>/dev/null || true
  sudo pkill -f 'io[.]aeron[.]benchmarks[.]LoadTestRig' 2>/dev/null || true
  sudo pkill -f 'io[.]aeron[.]benchmarks[.]aeron[.]ClusterNode' 2>/dev/null || true
  sudo pkill -x c-media-driver 2>/dev/null || true
  sudo pkill -x aeronmd 2>/dev/null || true
  sudo pkill -f low-latency-driver.properties 2>/dev/null || true
  sleep 2
  sudo rm -rf /dev/shm/aeron "/home/${ssh_user}/aeron-benchmark-shm"
}

remove_file_caps() {
  local java_path
  java_path="$(find_java || true)"
  [[ -n "${java_path}" ]] && sudo setcap -r "${java_path}" 2>/dev/null || true
  while IFS= read -r b; do
    sudo setcap -r "${b}" 2>/dev/null || true
  done < <(native_bins)
}

case "${action}" in
  status)
    hostname -f 2>/dev/null || hostname
    [[ -e "${lib_path}" ]] && echo "libvma: ${lib_path}" || echo "libvma missing: ${lib_path}"
    print_rdma
    print_caps
    if command -v dpkg >/dev/null 2>&1; then
      dpkg -l 2>/dev/null | grep -Ei 'doca|ofed|xlio|vma|ibverbs|rdma-core' || true
    elif command -v rpm >/dev/null 2>&1; then
      rpm -qa 2>/dev/null | grep -Ei 'doca|ofed|xlio|vma|ibverbs|rdma-core' || true
    fi
    ;;
  disable)
    cleanup_benchmark_processes
    remove_file_caps
    sudo rm -f /opt/aeron/vma.env
    echo "VMA benchmark state disabled; file capabilities removed and stale drivers cleaned."
    print_caps
    ;;
  enable)
    cleanup_benchmark_processes
    if [[ ! -e "${lib_path}" ]]; then
      echo "ERROR: libvma not found at ${lib_path}" >&2
      exit 1
    fi
    if ! rdma_ok; then
      print_rdma
      if [[ "${require_rdma}" == "1" ]]; then
        echo "ERROR: no IB/RDMA device visible; refusing VMA benchmark prep." >&2
        exit 1
      fi
      echo "WARNING: no IB/RDMA device visible; continuing because VMA_REQUIRE_RDMA=0" >&2
    fi
    remove_file_caps
    if [[ "${apply_caps}" == "1" ]]; then
      java_path="$(find_java || true)"
      if [[ -z "${java_path}" ]]; then
        echo "ERROR: java binary not found for setcap" >&2
        exit 1
      fi
      sudo setcap cap_net_raw+ep "${java_path}"
      echo "Applied cap_net_raw+ep to Java only: ${java_path}"
    else
      echo "File capabilities left disabled; VMA wrapper should run with sudo/root onload prefix."
    fi
    sudo mkdir -p /opt/aeron
    printf 'export LD_PRELOAD=%s\n' "${lib_path}" | sudo tee /opt/aeron/vma.env >/dev/null
    print_rdma
    print_caps
    ;;
esac
EOS
}

for h in "${hosts[@]}"; do
  remote_action "${h}"
done
