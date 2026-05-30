#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_ROOT="$(pwd)"

# Runs echo or cluster across driver modes and compares results.
# Usage:
#   ./run-driver-matrix.sh [echo|cluster]
# Env:
#   MATRIX_MODES="java,c,java_vma,c_vma"
#   CONFIG_FILE="./config/benchmark-config.env"
#   MATRIX_STRICT=1 (default) — exit 1 if any mode fails or logs contain timeout/exception signatures (Terraform apply fails).
#   MATRIX_STRICT=0 — run all modes and compare partial archives even when some modes failed (legacy).
#   MATRIX_ALLOW_STALE_ARCHIVE=1 — allow fallback to newest old client archive when a wrapper does not print test_dir.
#   BENCHMARK_SKIP_KERNEL_PARITY=1 — skip uname/cmdline parity check across SSH benchmark hosts.
#   BENCHMARK_SKIP_VMA_PREFLIGHT=1 — skip VMA / OpenOnload preflight (not recommended).
#   BENCHMARK_SKIP_C_VMA_ON_NO_IB=1 — skip c_vma when Mellanox VMA loads but no IB/RDMA device is present.
#   BENCHMARK_QUIET_MODE=1 — stop/runtime-mask apt-daily, unattended-upgrades, snap on benchmark hosts (SSH).
#   BENCHMARK_QUIET_RESTORE=1 (default) — unmask/start those units on script exit when quiet was applied.
#   BENCHMARK_DEEP_QUIET=1 — also stop OCI agent/monitoring processes on disposable benchmark hosts.
#   MATRIX_CLEANUP_AGGRESSIVE=1 (default) — kill stale Aeron processes and wipe transient Aeron dirs before/after each mode.
#   MATRIX_CLEANUP_COOLDOWN_SEC=10 — quiet period after cleanup before starting the next mode.
#   MATRIX_CLEANUP_VERIFY_SEC=20 — wait up to this long for stale Aeron processes to disappear.

TARGET="${1:-echo}"
MATRIX_MODES="${MATRIX_MODES:-java,c}"
CONFIG_FILE="${CONFIG_FILE:-./config/benchmark-config.env}"
STATUS_FILE="${STATUS_FILE:-}"
SUMMARY_FILE="${SUMMARY_FILE:-./driver-matrix-summary.csv}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# Drop stale CPU/affinity exports from the controller shell so benchmark-config.env ${VAR:-...} pins apply.
# The preload wrapper intentionally exports a validated affinity profile; preserve it for those runs.
if [[ "${AERON_PRELOAD_KEEP_AFFINITY:-0}" != "1" && -f "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh"
fi

_matrix_preserve_affinity() {
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

_matrix_restore_affinity() {
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

# Export all config values so wrappers can consume them.
_matrix_preserve_affinity
set -a
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
set +a
_matrix_restore_affinity

# After benchmark-config.env, optional MATRIX_OVERRIDE_* (set by Terraform) for post-deploy smoke vs full passes.
_matrix_apply_config_overrides() {
  set +u
  local k u
  for k in RUNS ITERATIONS WARMUP_ITERATIONS WARMUP_MESSAGE_RATE MESSAGE_LENGTH MESSAGE_RATE MTU_VALUE BENCH_PROFILE; do
    u="MATRIX_OVERRIDE_${k}"
    if [[ -n "${!u-}" ]]; then
      export "${k}=${!u}"
    fi
  done
  set -u
}
_matrix_apply_config_overrides

# Legacy or broken benchmark-config.env lines can leave |interface=.../24} (extra '}') → AsciiNumberFormatException.
# Sanitize here so even an old file on disk cannot poison the matrix (wrapper also sanitizes).
_pf="${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH-}"
if [[ -n "${_pf}" ]] && [[ "${_pf}" =~ [^0-9] ]]; then
  _pd="${_pf//[^0-9]/}"
  if [[ -n "${_pd}" ]]; then
    AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH="${_pd}"
    export AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH
  fi
fi
for _cv in CLIENT_SOURCE_CHANNEL CLIENT_DESTINATION_CHANNEL SERVER_SOURCE_CHANNEL SERVER_DESTINATION_CHANNEL; do
  _cur="${!_cv-}"
  [[ -z "${_cur}" ]] && continue
  _fix="$(printf '%s' "${_cur}" | sed -E 's#/([0-9]+)\}+#/\1#g')"
  if [[ "${_fix}" != "${_cur}" ]]; then
    printf -v "${_cv}" '%s' "${_fix}"
    export "${_cv}"
  fi
done

wrapper=""
if [[ "${TARGET}" == "echo" ]]; then
  wrapper="./wrapper-echo-unified.sh"
elif [[ "${TARGET}" == "cluster" ]]; then
  wrapper="./wrapper-cluster-unified.sh"
else
  echo "Target must be 'echo' or 'cluster'" >&2
  exit 1
fi

IFS=',' read -r -a modes <<< "${MATRIX_MODES}"
archives=()
summary_tmp="$(mktemp)"
run_failures=0
vma_ib_capable=unknown

# If 1 (default), exit 1 when any mode fails or logs match fatal signatures (so Terraform apply fails loudly).
MATRIX_STRICT="${MATRIX_STRICT:-1}"
MATRIX_ALLOW_STALE_ARCHIVE="${MATRIX_ALLOW_STALE_ARCHIVE:-0}"
# Per-mode wall-clock cap so Terraform SSH does not hang until connection timeout (coreutils `timeout`, exit 124).
MATRIX_MODE_TIMEOUT_SEC="${MATRIX_MODE_TIMEOUT_SEC:-900}"
MATRIX_CLEANUP_AGGRESSIVE="${MATRIX_CLEANUP_AGGRESSIVE:-1}"
MATRIX_CLEANUP_COOLDOWN_SEC="${MATRIX_CLEANUP_COOLDOWN_SEC:-10}"
MATRIX_CLEANUP_VERIFY_SEC="${MATRIX_CLEANUP_VERIFY_SEC:-20}"

# Scan wrapper log for outcomes that often still yield a non-zero wrapper exit, or for hung/timeout cases.
# Extend the alternation as new failure modes show up in CI/terraform logs.
log_has_benchmark_failure_signature() {
  local log="$1"
  [[ -f "${log}" && -s "${log}" ]] || return 1
  # Only match real JVM/driver failures. Do not grep for "Timeout:" / "load-test-rig" — remote-echo-benchmarks
  # runs with set -x and embeds those strings in traced script text (false positives after a good run).
  grep -Eiq \
    'RegistrationException|AsciiNumberFormatException|Exception in thread[[:space:]]+"main"|error parsing int:' \
    "${log}"
}

status() {
  local msg="$1"
  echo "${msg}"
  if [[ -n "${STATUS_FILE}" ]]; then
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${msg}" >> "${STATUS_FILE}"
  fi
}

echo "mode,status,notes" > "${summary_tmp}"

# After a failed/interrupted echo mode, MediaDriver / LoadTestRig / aeronmd can survive on client+receiver and block the next mode (IllegalStateException: Failed to connect within timeout).
matrix_cleanup_hosts() {
  local key="${SSH_KEY_FILE:-/opt/aeron/.ssh/deploy_key}"
  local user="${SSH_USER:-ubuntu}"
  local h
  local cluster_wipe="${1:-0}"
  [[ "${MATRIX_CLEANUP_AGGRESSIVE}" == "1" ]] || return 0
  [[ -f "${key}" ]] || return 0

  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    status "cleanup: ${h} cluster_wipe=${cluster_wipe}"
    ssh -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" "bash -s -- ${cluster_wipe} ${MATRIX_CLEANUP_VERIFY_SEC} ${user}" <<'EOS' || true
set -u
cluster_wipe="${1:-0}"
verify_sec="${2:-20}"
bench_user="${3:-ubuntu}"

patterns=(
  'io[.]aeron[.]driver[.]MediaDriver'
  'io[.]aeron[.]benchmarks[.]LoadTestRig'
  'io[.]aeron[.]benchmarks[.]aeron[.]ClusterNode'
  'io[.]aeron[.]cluster'
  'io[.]aeron[.]archive'
  '[/]aeronmd .*benchmark[.]properties'
  'low-latency-driver.properties'
)
names=(c-media-driver aeronmd)

kill_matching_pids() {
  local sig="$1" mode="$2" pattern="$3" pid pids
  if [[ "${mode}" == "name" ]]; then
    pids="$(pgrep -x "$pattern" 2>/dev/null || true)"
  else
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
  fi
  for pid in ${pids:-}; do
    [[ "${pid}" == "$$" || "${pid}" == "${PPID}" ]] && continue
    sudo kill "-${sig}" "${pid}" 2>/dev/null || true
  done
}

for p in "${patterns[@]}"; do kill_matching_pids TERM pattern "$p"; done
for n in "${names[@]}"; do kill_matching_pids TERM name "$n"; done

end=$((SECONDS + verify_sec))
while (( SECONDS < end )); do
  alive=0
  for p in "${patterns[@]}"; do
    if pgrep -f "$p" >/dev/null 2>&1; then alive=1; fi
  done
  for n in "${names[@]}"; do
    if pgrep -x "$n" >/dev/null 2>&1; then alive=1; fi
  done
  (( alive == 0 )) && break
  sleep 1
done

for p in "${patterns[@]}"; do kill_matching_pids KILL pattern "$p"; done
for n in "${names[@]}"; do kill_matching_pids KILL name "$n"; done

sudo rm -rf /dev/shm/aeron /run/shm/aeron "/home/${bench_user}/aeron-benchmark-shm" /tmp/aeron 2>/dev/null || true
if [[ "${cluster_wipe}" == "1" ]]; then
  sudo rm -rf "/home/${bench_user}/cluster" "/home/${bench_user}/aeron-cluster" /tmp/aeron-cluster 2>/dev/null || true
fi

remaining="$( (pgrep -af 'io[.]aeron|aeronmd|c-media-driver|low-latency-driver.properties' || true) | sed -n '1,8p')"
if [[ -n "${remaining}" ]]; then
  echo "cleanup-warning: remaining Aeron-looking processes:" >&2
  echo "${remaining}" >&2
fi
EOS
  done < <(_matrix_hosts_for_preflight "${TARGET}")

  if [[ "${MATRIX_CLEANUP_COOLDOWN_SEC}" =~ ^[0-9]+$ && "${MATRIX_CLEANUP_COOLDOWN_SEC}" -gt 0 ]]; then
    status "cleanup: cooldown ${MATRIX_CLEANUP_COOLDOWN_SEC}s"
    sleep "${MATRIX_CLEANUP_COOLDOWN_SEC}"
  fi
}

matrix_echo_cleanup_remotes() {
  [[ "${TARGET}" == "echo" ]] || return 0
  matrix_cleanup_hosts 0
}

matrix_cluster_cleanup_remotes() {
  [[ "${TARGET}" == "cluster" ]] || return 0
  matrix_cleanup_hosts 1
}

matrix_export_onload_for_mode() {
  local raw
  raw="$(echo "${1}" | xargs | tr '[:upper:]' '[:lower:]')"
  if [[ "${raw}" == *vma* ]] || [[ "${raw}" == *-onload ]]; then
    export ONLOAD_COMMAND="${ONLOAD_COMMAND_VMA:-${ONLOAD_COMMAND:-env}}"
  else
    export ONLOAD_COMMAND="${ONLOAD_COMMAND_PLAIN:-env}"
  fi
}

# Unique benchmark hostnames for this matrix target (echo vs cluster).
_matrix_hosts_for_preflight() {
  local t="$1"
  declare -A seen=()
  local h
  _mark() {
    [[ -z "$1" ]] && return
    [[ -n "${seen[$1]+x}" ]] && return
    seen[$1]=1
    printf '%s\n' "$1"
  }
  if [[ "${t}" == "echo" ]]; then
    _mark "${SSH_CLIENT_NODE:-}"
    _mark "${SSH_SERVER_NODE:-}"
  else
    _mark "${CLUSTER_SSH_CLIENT_NODE:-}"
    _mark "${CLUSTER_SSH_CLUSTER_NODE0:-}"
    _mark "${CLUSTER_SSH_CLUSTER_NODE1:-}"
    _mark "${CLUSTER_SSH_CLUSTER_NODE2:-}"
    if [[ "${CLUSTER_BACKUP_NODES:-0}" == "1" ]]; then
      _mark "${CLUSTER_SSH_BACKUP_NODE0:-}"
    fi
  fi
}

matrix_preflight_kernel_parity() {
  [[ "${BENCHMARK_SKIP_KERNEL_PARITY:-0}" == "1" ]] && return 0
  local key="${SSH_KEY_FILE:-}"
  local user="${SSH_USER:-ubuntu}"
  local first="" line h any=0
  while IFS= read -r h && [[ -n "${h}" ]]; do
    any=1
    break
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  [[ "${any}" == "0" ]] && return 0
  [[ -n "${key}" && -f "${key}" ]] || {
    status "kernel parity: benchmark hosts configured but SSH_KEY_FILE missing or not a file"
    return 1
  }
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    line="$(ssh -n -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" 'printf "%s|%s\n" "$(uname -r)" "$(tr -s " " < /proc/cmdline)"' 2>/dev/null)" || {
      status "kernel parity: failed to read uname/cmdline from ${h}"
      return 1
    }
    if [[ -z "${first}" ]]; then
      first="${line}"
      status "kernel parity: reference ${h} -> ${line}"
    elif [[ "${line}" != "${first}" ]]; then
      status "kernel parity mismatch: ${h} -> ${line} (expected ${first})"
      return 1
    fi
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  return 0
}

matrix_modes_need_onload() {
  local m raw
  IFS=',' read -r -a _mm <<< "${MATRIX_MODES:-}"
  for raw in "${_mm[@]}"; do
    m="$(echo "${raw}" | xargs | tr '[:upper:]' '[:lower:]')"
    [[ "${m}" == *vma* ]] && return 0
    [[ "${m}" == *-onload ]] && return 0
  done
  return 1
}

_onload_command_first_token() {
  local s="${1:-env}"
  read -r w _ <<< "${s}"
  printf '%s' "${w}"
}

# Extract LD_PRELOAD path from an --onload prefix string (Mellanox VMA).
_vma_ld_preload_path_from_cmd() {
  local s="$1" lib_path=""
  if [[ "${s}" =~ LD_PRELOAD=([^[:space:]]+) ]]; then
    lib_path="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${lib_path}"
}

matrix_preflight_vma() {
  [[ "${BENCHMARK_SKIP_VMA_PREFLIGHT:-0}" == "1" ]] && return 0
  matrix_modes_need_onload || return 0
  local key="${SSH_KEY_FILE:-}"
  local user="${SSH_USER:-ubuntu}"
  [[ -n "${key}" && -f "${key}" ]] || {
    status "vma preflight: SSH_KEY_FILE missing or not a file"
    return 1
  }
  local vma_line="${ONLOAD_COMMAND_VMA:-}"
  [[ -z "${vma_line}" ]] && vma_line="${ONLOAD_COMMAND:-}"
  local lib_path
  lib_path="$(_vma_ld_preload_path_from_cmd "${vma_line}")"
  local h nhosts=0
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    nhosts=$((nhosts + 1))
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  if [[ "${nhosts}" -eq 0 ]]; then
    status "vma preflight: no benchmark SSH hosts for target=${TARGET}"
    return 1
  fi

  if [[ -n "${lib_path}" ]]; then
    while IFS= read -r h; do
      [[ -z "${h}" ]] && continue
      if ! ssh -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
        "${user}@${h}" "bash -s -- $(printf '%q' "${lib_path}")" <<'EOS'
path="$1"
test -f "$path" || test -e "$path"
EOS
      then
        status "vma preflight: LD_PRELOAD library missing on ${h} (${lib_path})"
        return 1
      fi
    done < <(_matrix_hosts_for_preflight "${TARGET}")
    status "vma preflight: LD_PRELOAD library present on all matrix hosts (${lib_path})"
    if matrix_preflight_ib_capable; then
      vma_ib_capable=yes
      status "vma preflight: IB/RDMA-capable device detected on all matrix hosts"
    else
      vma_ib_capable=no
      status "vma preflight: no IB/RDMA-capable device detected on one or more matrix hosts; c_vma will be skipped unless BENCHMARK_SKIP_C_VMA_ON_NO_IB=0"
    fi
    return 0
  fi

  local first
  first="$(_onload_command_first_token "${vma_line}")"
  if [[ "${first}" == "env" ]] || [[ -z "${first}" ]]; then
    status "Preflight: vma modes need ONLOAD_COMMAND_VMA with LD_PRELOAD=/path/to/libvma.so (or a real OpenOnload binary in PATH). Current: '${vma_line}'"
    return 1
  fi
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    if ! ssh -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" "bash -s -- $(printf '%q' "${first}")" <<'EOS'
first="$1"
if [[ "$first" == /* ]]; then
  test -x "$first"
else
  command -v "$first" >/dev/null 2>&1
fi
EOS
    then
      status "vma preflight: first token '${first}' not found/executable on ${h}"
      return 1
    fi
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  status "vma preflight: '${first}' present on all matrix hosts (OpenOnload-style)"
  return 0
}

matrix_preflight_ib_capable() {
  local key="${SSH_KEY_FILE:-}"
  local user="${SSH_USER:-ubuntu}"
  [[ -n "${key}" && -f "${key}" ]] || return 1
  local h
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    if ! ssh -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" 'bash -s' <<'EOS'
set -euo pipefail
if command -v ibv_devices >/dev/null 2>&1; then
  ibv_devices 2>/dev/null | awk 'NR > 2 && NF { found=1 } END { exit found ? 0 : 1 }'
elif [[ -d /sys/class/infiniband ]]; then
  find /sys/class/infiniband -mindepth 1 -maxdepth 1 -type l -print -quit | grep -q .
else
  exit 1
fi
EOS
    then
      return 1
    fi
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  return 0
}

matrix_mode_should_skip() {
  local raw
  raw="$(echo "${1}" | xargs | tr '[:upper:]' '[:lower:]')"
  [[ "${BENCHMARK_SKIP_C_VMA_ON_NO_IB:-1}" == "1" ]] || return 1
  [[ "${vma_ib_capable}" == "no" ]] || return 1
  [[ "${raw}" == "c_vma" || "${raw}" == "c-onload" ]] || return 1
  return 0
}

BENCHMARK_QUIET_MODE="${BENCHMARK_QUIET_MODE:-1}"
BENCHMARK_QUIET_RESTORE="${BENCHMARK_QUIET_RESTORE:-0}"
BENCHMARK_DEEP_QUIET="${BENCHMARK_DEEP_QUIET:-1}"
_matrix_quiet_applied=0

matrix_quiet_apply() {
  [[ "${BENCHMARK_QUIET_MODE}" == "1" ]] || return 0
  local key="${SSH_KEY_FILE:-}"
  local user="${SSH_USER:-ubuntu}"
  [[ -n "${key}" && -f "${key}" ]] || return 0
  local h
  status "benchmark quiet: stop/runtime-mask apt-daily, unattended-upgrades, snap on hosts"
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    ssh -n -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" \
      "sudo BENCHMARK_DEEP_QUIET=${BENCHMARK_DEEP_QUIET} bash -s" <<'EOS' \
      || true
set -u
base_units=(
  apt-daily.timer
  apt-daily-upgrade.timer
  unattended-upgrades.service
  snapd.socket
  snapd.service
)
deep_units=(
  snap.oracle-cloud-agent.oracle-cloud-agent.service
  snap.oracle-cloud-agent.oracle-cloud-agent-updater.service
  unified-monitoring-agent.service
  unified-monitoring-agent_config_downloader.service
  unified-monitoring-agent_restarter.service
  unified-monitoring-agent_restarter.path
  ModemManager.service
  cron.service
  fwupd-refresh.timer
  fstrim.timer
  logrotate.timer
  man-db.timer
  motd-news.timer
  ua-timer.timer
)
units=("${base_units[@]}")
if [[ "${BENCHMARK_DEEP_QUIET:-1}" == "1" ]]; then
  units+=("${deep_units[@]}")
fi
for u in "${units[@]}"; do systemctl stop "$u" 2>/dev/null || true; done
for u in "${units[@]}"; do systemctl mask --runtime "$u" 2>/dev/null || true; done
if [[ "${BENCHMARK_DEEP_QUIET:-1}" == "1" ]]; then
  pkill -TERM -f '/snap/oracle-cloud-agent/' 2>/dev/null || true
  pkill -TERM -f '/opt/unified-monitoring-agent/' 2>/dev/null || true
  pkill -TERM -f '/opt/wlp-agent/' 2>/dev/null || true
  sleep 2
  pkill -KILL -f '/snap/oracle-cloud-agent/' 2>/dev/null || true
  pkill -KILL -f '/opt/unified-monitoring-agent/' 2>/dev/null || true
  pkill -KILL -f '/opt/wlp-agent/' 2>/dev/null || true
fi
EOS
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  _matrix_quiet_applied=1
}

matrix_quiet_restore() {
  [[ "${_matrix_quiet_applied}" == "1" ]] || return 0
  [[ "${BENCHMARK_QUIET_RESTORE}" == "1" ]] || return 0
  local key="${SSH_KEY_FILE:-}"
  local user="${SSH_USER:-ubuntu}"
  [[ -n "${key}" && -f "${key}" ]] || return 0
  local h
  status "benchmark quiet: unmask/start apt/snap units on hosts"
  while IFS= read -r h; do
    [[ -z "${h}" ]] && continue
    ssh -n -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" \
      'sudo bash -ec "for u in apt-daily.timer apt-daily-upgrade.timer snapd.socket snapd.service; do systemctl unmask --runtime \"\$u\" 2>/dev/null || true; done; for u in apt-daily.timer apt-daily-upgrade.timer snapd.socket snapd.service; do systemctl start \"\$u\" 2>/dev/null || true; done"' \
      || true
  done < <(_matrix_hosts_for_preflight "${TARGET}")
  _matrix_quiet_applied=0
}

if ! matrix_preflight_kernel_parity; then
  exit 1
fi
if ! matrix_preflight_vma; then
  exit 1
fi
matrix_quiet_apply
trap 'matrix_quiet_restore 2>/dev/null || true' EXIT

for mode in "${modes[@]}"; do
  mode="$(echo "${mode}" | xargs)"
  context="${TARGET}-matrix-${mode}"
  log="/tmp/${context}.log"

  if matrix_mode_should_skip "${mode}"; then
    echo "${mode},skipped,no-ib-rdma-device-for-vma-native-driver" >> "${summary_tmp}"
    status "Skipping ${TARGET} mode=${mode}: Mellanox VMA native C driver requires an IB/RDMA-capable device on this host class."
    continue
  fi

  status "=== Running ${TARGET} mode=${mode} context=${context} ==="

  if [[ "${TARGET}" == "echo" ]]; then
    matrix_echo_cleanup_remotes
    matrix_export_onload_for_mode "${mode}"
    if CLIENT_MODE="${mode}" SERVER_MODE="${mode}" CONTEXT="${context}" \
      timeout "${MATRIX_MODE_TIMEOUT_SEC}" bash "${wrapper}" 2>&1 | tee "${log}"; then
      if log_has_benchmark_failure_signature "${log}"; then
        run_failures=$((run_failures + 1))
        echo "${mode},failed,log-signature-benchmark-timeout-or-exception" >> "${summary_tmp}"
        status "FATAL: mode ${mode} log matches benchmark failure signature (e.g. load-test-rig timeout); see ${log}"
        if [[ "${MATRIX_STRICT}" == "1" ]]; then
          cp -f "${summary_tmp}" "${SUMMARY_FILE}"
          status "MATRIX_STRICT=1: aborting matrix after first fatal log signature."
          exit 1
        fi
        status "Mode ${mode} treated as failed; continuing with next mode."
        continue
      fi
      echo "${mode},ok,wrapper-run-success" >> "${summary_tmp}"
    else
      run_failures=$((run_failures + 1))
      echo "${mode},failed,wrapper-run-failed-see-${log}" >> "${summary_tmp}"
      status "Mode ${mode} failed (wrapper/timeout exit non-zero, often 124=timeout); continuing with next mode."
      if log_has_benchmark_failure_signature "${log}"; then
        status "FATAL: ${log} also contains benchmark failure signature (timeout/exception)."
        if [[ "${MATRIX_STRICT}" == "1" ]]; then
          cp -f "${summary_tmp}" "${SUMMARY_FILE}"
          exit 1
        fi
      fi
      continue
    fi
    matrix_echo_cleanup_remotes
  else
    matrix_cluster_cleanup_remotes
    matrix_export_onload_for_mode "${mode}"
    if CLUSTER_CLIENT_MODE="${mode}" CLUSTER_SERVER_MODE="${mode}" CLUSTER_CONTEXT="${context}" \
      timeout "${MATRIX_MODE_TIMEOUT_SEC}" bash "${wrapper}" "${CONFIG_FILE}" 2>&1 | tee "${log}"; then
      if log_has_benchmark_failure_signature "${log}"; then
        run_failures=$((run_failures + 1))
        echo "${mode},failed,log-signature-benchmark-timeout-or-exception" >> "${summary_tmp}"
        status "FATAL: mode ${mode} log matches benchmark failure signature; see ${log}"
        if [[ "${MATRIX_STRICT}" == "1" ]]; then
          cp -f "${summary_tmp}" "${SUMMARY_FILE}"
          status "MATRIX_STRICT=1: aborting matrix after first fatal log signature."
          exit 1
        fi
        status "Mode ${mode} treated as failed; continuing with next mode."
        continue
      fi
      echo "${mode},ok,wrapper-run-success" >> "${summary_tmp}"
    else
      run_failures=$((run_failures + 1))
      echo "${mode},failed,wrapper-run-failed-see-${log}" >> "${summary_tmp}"
      status "Mode ${mode} failed (wrapper exit non-zero); continuing with next mode."
      if log_has_benchmark_failure_signature "${log}"; then
        status "FATAL: ${log} also contains benchmark failure signature (timeout/exception)."
        if [[ "${MATRIX_STRICT}" == "1" ]]; then
          cp -f "${summary_tmp}" "${SUMMARY_FILE}"
          exit 1
        fi
      fi
      continue
    fi
    matrix_cluster_cleanup_remotes
  fi

  test_dir="$(sed -n 's/.*test_dir=\(aeron-[0-9A-Za-z-]*\).*/\1/p' "${log}" | head -n 1 | tr -d '\r' || true)"
  if [[ -n "${test_dir}" ]]; then
    client_tar="./${test_dir}-client.tar.gz"
    if [[ -f "${client_tar}" ]]; then
      archives+=("${client_tar}")
      archive_listing="$(mktemp)"
      tar -tzf "${client_tar}" > "${archive_listing}"
      if grep -q '\.hdr\.FAIL$' "${archive_listing}"; then
        run_failures=$((run_failures + 1))
        sed -i "s#^${mode},ok,wrapper-run-success#${mode},failed,hdr-fail-target-rate-not-met#" "${summary_tmp}" || true
        status "FATAL: mode ${mode} produced .hdr.FAIL artifacts in ${client_tar}; target rate was not sustained."
        if [[ "${MATRIX_STRICT}" == "1" ]]; then
          cp -f "${summary_tmp}" "${SUMMARY_FILE}"
          status "MATRIX_STRICT=1: aborting matrix after .hdr.FAIL."
          exit 1
        fi
      fi
      rm -f "${archive_listing}"
    fi
  fi

  if [[ "${#archives[@]}" -eq 0 && "${MATRIX_ALLOW_STALE_ARCHIVE}" == "1" ]]; then
    latest_client="$(ls -1t ./aeron-${TARGET}-*-client.tar.gz 2>/dev/null | head -n 1 || true)"
    if [[ -n "${latest_client}" && -f "${latest_client}" ]]; then
      status "WARNING: using fallback client archive because wrapper did not emit test_dir: ${latest_client}"
      archives+=("${latest_client}")
    fi
  fi
done

if [[ "${#archives[@]}" -eq 0 ]]; then
  status "No client archives found to compare."
  cp -f "${summary_tmp}" "${SUMMARY_FILE}"
  exit 1
fi

status "=== Comparison output ==="
bash ./aggregate-compare-results.sh "${archives[@]}" | tee -a "${summary_tmp}"
# Keep mode,status,notes lines and aggregate CSV in one file (terraform-matrix-summary.py + human-readable smoke summary).
cp -f "${summary_tmp}" "${SUMMARY_FILE}"

if [[ "${run_failures}" -gt 0 ]]; then
  status "FATAL: matrix finished with ${run_failures} failed mode(s); summary -> ${SUMMARY_FILE}"
  if [[ "${MATRIX_STRICT}" == "1" ]]; then
    exit 1
  fi
else
  status "Matrix completed successfully for all modes."
fi
