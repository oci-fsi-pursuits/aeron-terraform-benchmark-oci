#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG_FILE="${1:-./config/benchmark-config.env}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

_wrapper_preserve_affinity() {
  [[ "${AERON_PRELOAD_KEEP_AFFINITY:-0}" == "1" ]] || return 0
  _AERON_KEEP_CLUSTER_AERON_SSH_TASKSET_CPUS="${CLUSTER_AERON_SSH_TASKSET_CPUS:-}"
  _AERON_KEEP_CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="${CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES:-}"
  _AERON_KEEP_CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="${CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-}"
  _AERON_KEEP_CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="${CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="${CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="${CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="${CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-}"
  _AERON_KEEP_CLUSTER_CPU_AFFINITY_MODE="${CLUSTER_CPU_AFFINITY_MODE:-}"
  _AERON_KEEP_CLUSTER_CPU_AFFINITY_ALLOW_NARROWING="${CLUSTER_CPU_AFFINITY_ALLOW_NARROWING:-}"
  _AERON_KEEP_CLUSTER_CPU_AFFINITY_FALLBACK_LAST="${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-}"
}

_wrapper_restore_affinity() {
  [[ "${AERON_PRELOAD_KEEP_AFFINITY:-0}" == "1" ]] || return 0
  [[ -n "${_AERON_KEEP_CLUSTER_AERON_SSH_TASKSET_CPUS:-}" ]] && export CLUSTER_AERON_SSH_TASKSET_CPUS="${_AERON_KEEP_CLUSTER_AERON_SSH_TASKSET_CPUS}"
  [[ -n "${_AERON_KEEP_CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES:-}" ]] && export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="${_AERON_KEEP_CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-}" ]] && export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="${_AERON_KEEP_CLUSTER_NODE0_NON_ISOLATED_CPU_CORES}"
  [[ -n "${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE:-}" ]] && export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE:-}" ]] && export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE:-}" ]] && export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="${_AERON_KEEP_CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE:-}" ]] && export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="${_AERON_KEEP_CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-}" ]] && export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-}" ]] && export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-}" ]] && export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE:-}" ]] && export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-}" ]] && export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-}" ]] && export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-}" ]] && export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-}" ]] && export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${_AERON_KEEP_CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE}"
  [[ -n "${_AERON_KEEP_CLUSTER_CPU_AFFINITY_MODE:-}" ]] && export CLUSTER_CPU_AFFINITY_MODE="${_AERON_KEEP_CLUSTER_CPU_AFFINITY_MODE}"
  [[ -n "${_AERON_KEEP_CLUSTER_CPU_AFFINITY_ALLOW_NARROWING:-}" ]] && export CLUSTER_CPU_AFFINITY_ALLOW_NARROWING="${_AERON_KEEP_CLUSTER_CPU_AFFINITY_ALLOW_NARROWING}"
  [[ -n "${_AERON_KEEP_CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-}" ]] && export CLUSTER_CPU_AFFINITY_FALLBACK_LAST="${_AERON_KEEP_CLUSTER_CPU_AFFINITY_FALLBACK_LAST}"
}

_wrapper_preserve_affinity
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
_wrapper_restore_affinity

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
  local _start=0
  local _step=1
  if (( _last >= 23 )); then
    _start=8
    _step=2
  elif (( _last >= 15 )); then
    _start=6
  elif (( _last >= 9 )); then
    _start=4
  fi

  _cluster_cpu_at() {
    local offset=$1
    aeron_cluster_cpu_min "$((_start + (offset * _step)))" "${_last}"
  }

  export CLUSTER_AERON_SSH_TASKSET_CPUS="${_start}-${_last}"
  export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="${_start}-${_last}"
  export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="${_start}-${_last}"
  export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="$(_cluster_cpu_at 0)"
  export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="$(_cluster_cpu_at 1)"
  export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="$(_cluster_cpu_at 2)"
  export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="$(_cluster_cpu_at 3)"
  export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="$(_cluster_cpu_at 0)"
  export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="$(_cluster_cpu_at 1)"
  export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="$(_cluster_cpu_at 2)"
  export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="$(_cluster_cpu_at 3)"
  export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="$(_cluster_cpu_at 4)"
  export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="$(_cluster_cpu_at 5)"
  export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="$(_cluster_cpu_at 6)"
  export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="$(_cluster_cpu_at 7)"
}

cluster_read_remote_marker() {
  local user="$1" key="$2" host="$3" path="$4"
  [[ -z "$host" ]] && return 1
  local raw
  raw="$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${user}@${host}" "cat '${path}' 2>/dev/null || true" 2>/dev/null || true)"
  raw="${raw//$'\r'/}"
  raw="${raw//[[:space:]]/}"
  printf '%s' "$raw"
}

cluster_remote_threads_per_core() {
  local user="$1" key="$2" host="$3"
  [[ -z "$host" ]] && return 1
  local raw
  raw="$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${user}@${host}" "lscpu | awk -F: '/Thread\\(s\\) per core:/{gsub(/^[ \\t]+/,\"\",\$2); print \$2; exit}'" 2>/dev/null || true)"
  raw="${raw//$'\r'/}"
  raw="${raw//[[:space:]]/}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$raw"
}

cluster_should_use_vm16_smt_off_profile() {
  local profile="${BENCHMARK_CPU_PROFILE:-}"
  local hk="${BENCHMARK_HOUSEKEEPING_CPUS:-}"
  local isolated="${BENCHMARK_ISOLATED_CPUS:-}"
  if [[ "$profile" == "oci_vm_16_smt_off" || "$hk" == "6-8" || "$isolated" == "0-5,9-15" ]]; then
    return 0
  fi

  profile="$(cluster_read_remote_marker "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" /opt/aeron/benchmark-cpu-profile)"
  hk="$(cluster_read_remote_marker "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" /opt/aeron/housekeeping-cpus)"
  isolated="$(cluster_read_remote_marker "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" /opt/aeron/isolated-cpus)"
  local last_cpu threads
  last_cpu="$(cluster_remote_last_visible_cpu "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" 2>/dev/null || true)"
  threads="$(cluster_remote_threads_per_core "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" 2>/dev/null || true)"
  if [[ "$threads" == "1" && "$last_cpu" == "15" && ( "$profile" == "oci_vm_16_smt_off" || "$profile" == "auto" || "$hk" == "6-8" || "$isolated" == "0-5,9-15" ) ]]; then
    return 0
  fi
  return 1
}

cluster_apply_vm16_smt_off_profile() {
  export CLUSTER_CPU_AFFINITY_MODE="static"
  export CLUSTER_CPU_AFFINITY_ALLOW_NARROWING="0"
  export CLUSTER_AERON_SSH_TASKSET_CPUS="6,7,8"

  export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="6,7,8"
  export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="6,7,8"
  export CLUSTER_BACKUP_NODE0_NON_ISOLATED_CPU_CORES="6,7,8"

  export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="1"
  export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="2"
  export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="3"
  export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="4"

  export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="1"
  export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="2"
  export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="3"
  export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="4"
  export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="5"
  export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="9"
  export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="10"
  export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="11"

  export CLUSTER_BACKUP_NODE0_DRIVER_CONDUCTOR_CPU_CORE="1"
  export CLUSTER_BACKUP_NODE0_DRIVER_SENDER_CPU_CORE="2"
  export CLUSTER_BACKUP_NODE0_DRIVER_RECEIVER_CPU_CORE="3"
  export CLUSTER_BACKUP_NODE0_ARCHIVE_RECORDER_CPU_CORE="9"
  export CLUSTER_BACKUP_NODE0_ARCHIVE_REPLAYER_CPU_CORE="10"
  export CLUSTER_BACKUP_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="11"
  export CLUSTER_BACKUP_NODE0_CLUSTER_BACKUP_CPU_CORE="5"
}

# Last logical CPU index on NUMA node 0, capped by live visible CPUs (cgroup / flex quota can hide CPUs
# that still appear in numactl --hardware).
cluster_probe_receiver_numa_node0_last_cpu() {
  local user="$1" key="$2" host="$3"
  [[ -z "$host" ]] && return 1
  local raw
  raw="$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
    "${user}@${host}" 'cap=$(($(nproc)-1)); n=$(numactl --hardware 2>/dev/null | sed -n "s/^node 0 cpus: //p" | head -1); if [ -n "${n// /}" ]; then last=""; for x in $n; do last=$x; done; else last=$cap; fi; if [ "$last" -gt "$cap" ]; then last=$cap; fi; printf "%s" "$last"' 2>/dev/null || true)"
  raw="${raw//$'\r'/}"
  raw="${raw// /}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$raw"
}

cluster_remote_last_visible_cpu() {
  local user="$1" key="$2" host="$3"
  [[ -z "$host" ]] && return 1
  local raw
  raw="$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
    "${user}@${host}" 'echo $(($(nproc)-1))' 2>/dev/null || true)"
  raw="${raw//$'\r'/}"
  raw="${raw// /}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$raw"
}

numactl_bind_valid_remote() {
  local user="$1" key="$2" host="$3" cpus="$4"
  [[ -z "${cpus}" || -z "$host" ]] && return 1
  ssh -i "$key" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 "${user}@${host}" \
    "numactl --physcpubind='${cpus}' --show >/dev/null 2>&1"
}

cluster_numactl_range_ok_all_hosts() {
  local range="$1"
  numactl_bind_valid_remote "${SSH_CLIENT_USER}" "${SSH_CLIENT_KEY_FILE}" "${SSH_CLIENT_NODE}" "${range}" || return 1
  numactl_bind_valid_remote "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" "${range}" || return 1
  if [[ -n "${SSH_CLUSTER_BACKUP_NODE0:-}" ]]; then
    numactl_bind_valid_remote "${SSH_CLUSTER_BACKUP_USER0}" "${SSH_CLUSTER_BACKUP_KEY_FILE0}" "${SSH_CLUSTER_BACKUP_NODE0}" "${range}" || return 1
  fi
  return 0
}

cluster_physcpubind_range_to_last() {
  case "$1" in
    0) echo 0 ;;
    *-*) echo "${1##*-}" ;;
    *) return 1 ;;
  esac
}

# After nproc / NUMA math, still validate numactl (isolcpus, cgroup cpuset over SSH).
cluster_ensure_common_physcpubind() {
  local cur="${CLUSTER_AERON_SSH_TASKSET_CPUS:-}"
  local fb="${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-}"
  local candidates=() c seen=() s dup
  if [[ "${cur}" =~ ^[0-9]+-[0-9]+$ ]]; then candidates+=("${cur}"); fi
  if [[ "${fb}" =~ ^[0-9]+$ ]]; then
    if (( fb >= 8 )); then candidates+=("8-${fb}"); fi
    if (( fb >= 6 )); then candidates+=("6-${fb}"); fi
    if (( fb >= 4 )); then candidates+=("4-${fb}"); fi
    candidates+=("0-${fb}")
  fi
  candidates+=("0-7" "0-3" "0-1" "0")
  for c in "${candidates[@]}"; do
    [[ -z "$c" ]] && continue
    dup=0
    for s in "${seen[@]}"; do
      if [[ "$s" == "$c" ]]; then dup=1; break; fi
    done
    (( dup )) && continue
    seen+=("$c")
    if cluster_numactl_range_ok_all_hosts "$c"; then
      local new_last
      new_last="$(cluster_physcpubind_range_to_last "$c")" || return 1
      if [[ "${c}" != "${cur}" ]]; then
        echo "wrapper-cluster-unified: numactl accepted ${c} common across cluster hosts (was ${cur:-unset})" >&2
        aeron_cluster_apply_cpu_last "${new_last}"
      fi
      return 0
    fi
  done
  echo "wrapper-cluster-unified: ERROR no common numactl --physcpubind across client/node0/backup (install numactl?)" >&2
  exit 1
}

# Same 0-N is exported for client, node0, and backup; use min(nproc-1) across those hosts so the tightest
# cgroup / shape wins (static Terraform OCPU or NUMA list can overshoot on any one VM).
cluster_clamp_affinity_to_visible_cpus() {
  local live_min="" v
  v="$(cluster_remote_last_visible_cpu "${SSH_CLIENT_USER}" "${SSH_CLIENT_KEY_FILE}" "${SSH_CLIENT_NODE}" || true)"
  [[ "${v}" =~ ^[0-9]+$ ]] && live_min="$v"
  v="$(cluster_remote_last_visible_cpu "${SSH_CLUSTER_USER0}" "${SSH_CLUSTER_KEY_FILE0}" "${SSH_CLUSTER_NODE0}" || true)"
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    if [[ -z "${live_min}" ]] || (( v < live_min )); then live_min="$v"; fi
  fi
  if [[ -n "${SSH_CLUSTER_BACKUP_NODE0:-}" ]]; then
    v="$(cluster_remote_last_visible_cpu "${SSH_CLUSTER_BACKUP_USER0}" "${SSH_CLUSTER_BACKUP_KEY_FILE0}" "${SSH_CLUSTER_BACKUP_NODE0}" || true)"
    if [[ "${v}" =~ ^[0-9]+$ ]]; then
      if [[ -z "${live_min}" ]] || (( v < live_min )); then live_min="$v"; fi
    fi
  fi
  [[ "${live_min}" =~ ^[0-9]+$ ]] || return 0
  local cur_last="" cur="${CLUSTER_AERON_SSH_TASKSET_CPUS:-}"
  if [[ "${cur}" =~ ^[0-9]+-[0-9]+$ ]]; then
    cur_last="${cur##*-}"
  elif [[ "${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-}" =~ ^[0-9]+$ ]]; then
    cur_last="${CLUSTER_CPU_AFFINITY_FALLBACK_LAST}"
  else
    return 0
  fi
  if (( live_min < cur_last )); then
    echo "wrapper-cluster-unified: clamping affinity to min visible CPUs last=${live_min} (config had last=${cur_last})" >&2
    aeron_cluster_apply_cpu_last "${live_min}"
  fi
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

if [[ "${CLUSTER_BACKUP_NODES:-0}" == "0" ]]; then
  d_backup=""
fi

CLUSTER_CLIENT_NODE="${CLUSTER_SSH_CLIENT_NODE:-$d_client}"
CLUSTER_NODE0="${CLUSTER_SSH_CLUSTER_NODE0:-$d_node0}"
CLUSTER_BACKUP_NODE="${CLUSTER_SSH_BACKUP_NODE0:-$d_backup}"
if [[ "${CLUSTER_BACKUP_NODES:-0}" == "0" ]]; then
  CLUSTER_BACKUP_NODE=""
fi

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
export SSH_CLUSTER_USER1="${CLUSTER_SSH_CLUSTER_USER1:-$SSH_USER}"
export SSH_CLUSTER_KEY_FILE1="${CLUSTER_SSH_CLUSTER_KEY_FILE1:-$SSH_KEY_FILE}"
export SSH_CLUSTER_NODE1="${CLUSTER_SSH_CLUSTER_NODE1:-}"
export SSH_CLUSTER_USER2="${CLUSTER_SSH_CLUSTER_USER2:-$SSH_USER}"
export SSH_CLUSTER_KEY_FILE2="${CLUSTER_SSH_CLUSTER_KEY_FILE2:-$SSH_KEY_FILE}"
export SSH_CLUSTER_NODE2="${CLUSTER_SSH_CLUSTER_NODE2:-}"

export SSH_CLUSTER_BACKUP_USER0="${CLUSTER_SSH_BACKUP_USER0:-$SSH_USER}"
export SSH_CLUSTER_BACKUP_KEY_FILE0="${CLUSTER_SSH_BACKUP_KEY_FILE0:-$SSH_KEY_FILE}"
export SSH_CLUSTER_BACKUP_NODE0="${CLUSTER_BACKUP_NODE:-}"

_cluster_vm16_profile_applied=0
if cluster_should_use_vm16_smt_off_profile; then
  echo "wrapper-cluster-unified: applying validated OCI VM 16 CPU SMT-off profile (housekeeping=6,7,8 hot=1-5,9-11)" >&2
  cluster_apply_vm16_smt_off_profile
  _cluster_vm16_profile_applied=1
fi

# Narrowing (clamp to nproc / numactl fallback chain) can collapse explicit high-core static pins — skip when static or disabled.
_cluster_narrow_ok=1
if [[ "${CLUSTER_CPU_AFFINITY_MODE:-auto}" == "static" ]]; then
  _cluster_narrow_ok=0
fi
if [[ "${CLUSTER_CPU_AFFINITY_ALLOW_NARROWING:-1}" == "0" ]]; then
  _cluster_narrow_ok=0
fi
if [[ "${_cluster_vm16_profile_applied}" == "1" ]]; then
  _cluster_narrow_ok=0
fi

_auto_probe=1
if [[ "${CLUSTER_CPU_AFFINITY_MODE:-auto}" == "static" ]]; then
  _auto_probe=0
fi
if [[ "${_cluster_vm16_profile_applied}" == "1" ]]; then
  _auto_probe=0
fi
# Honor pre-set taskset range in auto mode unless operator forces probe (e.g. hand-edited benchmark-config.env).
if [[ "${CLUSTER_CPU_AFFINITY_MODE:-auto}" == "auto" ]] && [[ -n "${CLUSTER_AERON_SSH_TASKSET_CPUS:-}" ]] && [[ "${CLUSTER_CPU_AFFINITY_FORCE_PROBE:-0}" != "1" ]]; then
  _auto_probe=0
  echo "wrapper-cluster-unified: auto mode with CLUSTER_AERON_SSH_TASKSET_CPUS set — skipping NUMA probe (CLUSTER_CPU_AFFINITY_FORCE_PROBE=1 to override)" >&2
fi

if [[ "${_auto_probe}" == "1" ]]; then
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

if [[ "${CLUSTER_CPU_AFFINITY_MODE:-auto}" == "static" ]] && [[ -n "${CLUSTER_AERON_SSH_TASKSET_CPUS:-}" ]]; then
  echo "wrapper-cluster-unified: honoring explicit static affinity ${CLUSTER_AERON_SSH_TASKSET_CPUS}" >&2
fi

if [[ "${_cluster_narrow_ok}" == "1" ]]; then
  cluster_clamp_affinity_to_visible_cpus
  cluster_ensure_common_physcpubind
fi

if [[ "${CLUSTER_RAFT_CONSENSUS:-0}" == "1" ]]; then
  export CLUSTER_SIZE="${CLUSTER_SIZE:-3}"
  export CLUSTER_BACKUP_NODES=0
else
  export CLUSTER_SIZE="${CLUSTER_SIZE:-1}"
fi
if (( CLUSTER_SIZE > 1 )); then
  for _cluster_i in $(seq 0 $((CLUSTER_SIZE - 1))); do
    _cluster_node_var="SSH_CLUSTER_NODE${_cluster_i}"
    if [[ -z "${!_cluster_node_var:-}" ]]; then
      echo "ERROR: CLUSTER_SIZE=${CLUSTER_SIZE} requires ${_cluster_node_var}. For Raft consensus set enable_cluster_raft_consensus=true so Terraform provisions client + node0/node1/node2." >&2
      exit 1
    fi
  done
fi
export CLUSTER_ID="${CLUSTER_ID:-42}"
if [[ "${CLUSTER_RAFT_CONSENSUS:-0}" == "1" ]]; then
  export CLUSTER_BACKUP_NODES=0
  SSH_CLUSTER_BACKUP_NODE0=""
elif [[ -n "${SSH_CLUSTER_BACKUP_NODE0}" ]]; then
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

cluster_export_node_default() {
  local idx="$1"
  local suffix="$2"
  local fallback="$3"
  local src_var="CLUSTER_NODE${idx}_${suffix}"
  export "NODE${idx}_${suffix}=${!src_var:-$fallback}"
}

for _cluster_i in 1 2; do
  cluster_export_node_default "${_cluster_i}" "BENCHMARKS_PATH" "${NODE0_BENCHMARKS_PATH}"
  cluster_export_node_default "${_cluster_i}" "JAVA_HOME" "${NODE0_JAVA_HOME}"
  cluster_export_node_default "${_cluster_i}" "CPU_NODE" "${NODE0_CPU_NODE}"
  cluster_export_node_default "${_cluster_i}" "NON_ISOLATED_CPU_CORES" "${NODE0_NON_ISOLATED_CPU_CORES}"
  export "NODE${_cluster_i}_AERON_DPDK_GATEWAY_IPV4_ADDRESS="
  export "NODE${_cluster_i}_AERON_DPDK_LOCAL_IPV4_ADDRESS="
  cluster_export_node_default "${_cluster_i}" "DRIVER_CONDUCTOR_CPU_CORE" "${NODE0_DRIVER_CONDUCTOR_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "DRIVER_SENDER_CPU_CORE" "${NODE0_DRIVER_SENDER_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "DRIVER_RECEIVER_CPU_CORE" "${NODE0_DRIVER_RECEIVER_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "CONSENSUS_MODULE_CPU_CORE" "${NODE0_CONSENSUS_MODULE_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "CLUSTERED_SERVICE_CPU_CORE" "${NODE0_CLUSTERED_SERVICE_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "ARCHIVE_RECORDER_CPU_CORE" "${NODE0_ARCHIVE_RECORDER_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "ARCHIVE_REPLAYER_CPU_CORE" "${NODE0_ARCHIVE_REPLAYER_CPU_CORE}"
  cluster_export_node_default "${_cluster_i}" "ARCHIVE_CONDUCTOR_CPU_CORE" "${NODE0_ARCHIVE_CONDUCTOR_CPU_CORE}"
done

NODE0_BASE="${CLUSTER_NODE0_BASE_PORT:-20000}"
BACKUP_BASE="${CLUSTER_BACKUP_BASE_PORT:-23000}"
NODE0_INGRESS_PORT=$((NODE0_BASE + 0))
NODE0_CONSENSUS_PORT=$((NODE0_BASE + 1))
NODE0_LOG_PORT=$((NODE0_BASE + 2))
NODE0_CATCHUP_PORT=$((NODE0_BASE + 3))
NODE0_ARCHIVE_PORT=$((NODE0_BASE + 4))

NODE0_IP="${CLUSTER_NODE0_ENDPOINT_HOST:-${SSH_CLUSTER_NODE0}}"
export CLUSTER_MEMBERS="0,${NODE0_IP}:${NODE0_INGRESS_PORT},${NODE0_IP}:${NODE0_CONSENSUS_PORT},${NODE0_IP}:${NODE0_LOG_PORT},${NODE0_IP}:${NODE0_CATCHUP_PORT},${NODE0_IP}:${NODE0_ARCHIVE_PORT}"
export CLUSTER_CONSENSUS_ENDPOINTS="0=${NODE0_IP}:${NODE0_CONSENSUS_PORT}"
export CLUSTER_BACKUP_CONSENSUS_ENDPOINTS="${CLUSTER_BACKUP_CONSENSUS_ENDPOINTS:-${NODE0_IP}:${NODE0_CONSENSUS_PORT}}"
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

if (( CLUSTER_SIZE > 1 )); then
  _cluster_members=""
  _cluster_consensus_endpoints=""
  _cluster_ingress_endpoints=""
  for _cluster_i in $(seq 0 $((CLUSTER_SIZE - 1))); do
    _node_var="SSH_CLUSTER_NODE${_cluster_i}"
    _endpoint_var="CLUSTER_NODE${_cluster_i}_ENDPOINT_HOST"
    _node_ip="${!_endpoint_var:-${!_node_var}}"
    _base_var="CLUSTER_NODE${_cluster_i}_BASE_PORT"
    _base="${!_base_var:-$((20000 + (_cluster_i * 1000)))}"
    _ingress=$((_base + 0))
    _consensus=$((_base + 1))
    _log=$((_base + 2))
    _catchup=$((_base + 3))
    _archive=$((_base + 4))
    _repl=$((_base + 22))
    _archive_repl=$((_base + 44))

    if [[ -n "${_cluster_members}" ]]; then
    _cluster_members+="|"
    _cluster_consensus_endpoints+=","
      _cluster_ingress_endpoints+=","
  fi
  _cluster_members+="${_cluster_i},${_node_ip}:${_ingress},${_node_ip}:${_consensus},${_node_ip}:${_log},${_node_ip}:${_catchup},${_node_ip}:${_archive}"
  _cluster_consensus_endpoints+="${_cluster_i}=${_node_ip}:${_consensus}"
  _cluster_ingress_endpoints+="${_cluster_i}=${_node_ip}:${_ingress}"

    export "NODE${_cluster_i}_CLUSTER_DIR=${DATA_DIR}/node${_cluster_i}/cluster"
    export "NODE${_cluster_i}_ARCHIVE_DIR=${DATA_DIR}/node${_cluster_i}/archive"
    _consensus_chan_var="CLUSTER_NODE${_cluster_i}_CLUSTER_CONSENSUS_CHANNEL"
    _ingress_chan_var="CLUSTER_NODE${_cluster_i}_CLUSTER_INGRESS_CHANNEL"
    _log_chan_var="CLUSTER_NODE${_cluster_i}_CLUSTER_LOG_CHANNEL"
    _repl_chan_var="CLUSTER_NODE${_cluster_i}_CLUSTER_REPLICATION_CHANNEL"
    _archive_ctl_var="CLUSTER_NODE${_cluster_i}_ARCHIVE_CONTROL_CHANNEL"
    _archive_repl_var="CLUSTER_NODE${_cluster_i}_ARCHIVE_REPLICATION_CHANNEL"
    export "NODE${_cluster_i}_CLUSTER_CONSENSUS_CHANNEL=${!_consensus_chan_var:-aeron:udp?term-length=64k}"
    export "NODE${_cluster_i}_CLUSTER_INGRESS_CHANNEL=${!_ingress_chan_var:-aeron:udp}"
    export "NODE${_cluster_i}_CLUSTER_LOG_CHANNEL=${!_log_chan_var:-aeron:udp?term-length=64m|controlmode=manual|control=${_node_ip}:${_log}}"
    export "NODE${_cluster_i}_CLUSTER_REPLICATION_CHANNEL=${!_repl_chan_var:-aeron:udp?endpoint=${_node_ip}:${_repl}}"
    export "NODE${_cluster_i}_ARCHIVE_CONTROL_CHANNEL=${!_archive_ctl_var:-aeron:udp?endpoint=${_node_ip}:${_archive}}"
    export "NODE${_cluster_i}_ARCHIVE_REPLICATION_CHANNEL=${!_archive_repl_var:-aeron:udp?endpoint=${_node_ip}:${_archive_repl}}"
  done
  export CLUSTER_MEMBERS="${_cluster_members}"
  export CLUSTER_CONSENSUS_ENDPOINTS="${_cluster_consensus_endpoints}"
  export CLUSTER_BACKUP_CONSENSUS_ENDPOINTS="${_cluster_consensus_endpoints}"
  export CLIENT_INGRESS_ENDPOINTS="${CLUSTER_CLIENT_INGRESS_ENDPOINTS:-${_cluster_ingress_endpoints}}"
fi

if [[ "${CLUSTER_BACKUP_NODES}" == "1" ]]; then
  BACKUP_IP="${SSH_CLUSTER_BACKUP_NODE0}"
  BACKUP_CATCHUP_PORT=$((BACKUP_BASE + 3))
  BACKUP_ARCHIVE_CONTROL_PORT=$((BACKUP_BASE + 4))
  BACKUP_ARCHIVE_RESPONSE_PORT=$((BACKUP_BASE + 5))
  BACKUP_ARCHIVE_REPLICATION_PORT=$((BACKUP_BASE + 6))
  export BACKUP_NODE0_BENCHMARKS_PATH="${CLUSTER_NODE0_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
  export BACKUP_NODE0_JAVA_HOME="${CLUSTER_NODE0_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
  export BACKUP_NODE0_CPU_NODE="${CLUSTER_NODE0_CPU_NODE:-0}"
  export BACKUP_NODE0_NON_ISOLATED_CPU_CORES="${CLUSTER_BACKUP_NODE0_NON_ISOLATED_CPU_CORES:-${CLUSTER_NODE0_NON_ISOLATED_CPU_CORES:-0-${CLUSTER_CPU_AFFINITY_FALLBACK_LAST:-9}}}"
  export BACKUP_NODE0_DRIVER_CONDUCTOR_CPU_CORE="${CLUSTER_BACKUP_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-${CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE:-4}}"
  export BACKUP_NODE0_DRIVER_SENDER_CPU_CORE="${CLUSTER_BACKUP_NODE0_DRIVER_SENDER_CPU_CORE:-${CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE:-5}}"
  export BACKUP_NODE0_DRIVER_RECEIVER_CPU_CORE="${CLUSTER_BACKUP_NODE0_DRIVER_RECEIVER_CPU_CORE:-${CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE:-6}}"
  export BACKUP_NODE0_ARCHIVE_RECORDER_CPU_CORE="${CLUSTER_BACKUP_NODE0_ARCHIVE_RECORDER_CPU_CORE:-${CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE:-9}}"
  export BACKUP_NODE0_ARCHIVE_REPLAYER_CPU_CORE="${CLUSTER_BACKUP_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-${CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE:-10}}"
  export BACKUP_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="${CLUSTER_BACKUP_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-${CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE:-11}}"
  export BACKUP_NODE0_CLUSTER_BACKUP_CPU_CORE="${CLUSTER_BACKUP_NODE0_CLUSTER_BACKUP_CPU_CORE:-${CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE:-8}}"
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

_wrapper_cluster_pick_onload_command() {
  local need=0
  case "${CLIENT_MODE}" in *vma*|*-onload) need=1;; esac
  case "${SERVER_MODE}" in *vma*|*-onload) need=1;; esac
  if [[ "${need}" == "1" ]]; then
    ONLOAD_COMMAND="${ONLOAD_COMMAND_VMA:-${ONLOAD_COMMAND:-env}}"
  else
    ONLOAD_COMMAND="${ONLOAD_COMMAND_PLAIN:-env}"
  fi
  export ONLOAD_COMMAND
}
_wrapper_cluster_pick_onload_command

"aeron/remote-cluster-benchmarks" \
  --client-drivers "${CLIENT_DRIVER_ID}" \
  --server-drivers "${SERVER_DRIVER_ID}" \
  --onload "${ONLOAD_COMMAND}" \
  --file-sync-level "${CLUSTER_FILE_SYNC_LEVEL:-0}" \
  --mtu "${MTU_VALUE}" \
  --context "${CLUSTER_CONTEXT:-cluster-unified}"
