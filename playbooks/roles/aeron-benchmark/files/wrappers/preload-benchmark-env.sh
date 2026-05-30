#!/usr/bin/env bash
_AERON_PRELOAD_OLD_SHELL_OPTS="$(set +o)"
set -euo pipefail

# Preload and validate the exact environment consumed by the Aeron benchmark
# wrappers. Source this file to export variables into the current shell, or run
# it directly with --show / --validate / --run.

_preload_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

_preload_restore_shell_opts() {
  if [[ -n "${_AERON_PRELOAD_OLD_SHELL_OPTS:-}" ]]; then
    eval "${_AERON_PRELOAD_OLD_SHELL_OPTS}"
  fi
}

_preload_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

usage() {
  cat <<'EOF'
Usage:
  source ./preload-benchmark-env.sh [options]
  ./preload-benchmark-env.sh --show [options]
  ./preload-benchmark-env.sh --validate [options]
  ./preload-benchmark-env.sh --run echo|cluster|both [options]

Defaults target the fixed 1001K OCPU-scaling test:
  modes=c,c_vma rate=1001000 length=288 runs=1 iterations=1 warmup=1 strict=0

Common options:
  --config FILE             Benchmark config env file (default ./config/benchmark-config.env)
  --modes LIST              Matrix modes, e.g. c,c_vma or java,c,java_vma,c_vma
  --rate RATE               MESSAGE_RATE, e.g. 1001000
  --length BYTES            MESSAGE_LENGTH, e.g. 288
  --runs N                  RUNS
  --iterations N            ITERATIONS
  --warmup N                WARMUP_ITERATIONS
  --warmup-rate RATE        WARMUP_MESSAGE_RATE
  --timeout SEC             MATRIX_MODE_TIMEOUT_SEC
  --strict 0|1              MATRIX_STRICT. 0 collects all modes; failures stay marked.
  --ssh-key FILE            Override SSH_KEY_FILE after benchmark-config.env is sourced
  --ssh-user USER           Override SSH_USER after benchmark-config.env is sourced
  --client HOST             Override echo client and cluster client host/IP
  --receiver HOST           Override echo server and cluster node0 host/IP
  --server HOST             Alias for --receiver
  --cluster-client HOST     Override only CLUSTER_SSH_CLIENT_NODE
  --cluster-node0 HOST      Override only CLUSTER_SSH_CLUSTER_NODE0
  --failover HOST           Force CLUSTER_SSH_BACKUP_NODE0 and CLUSTER_BACKUP_NODES=1
  --require-failover 0|1    Fail validation if cluster backup is not configured
  --expected-vcpus N        Optional validation guard, e.g. 32 for 16 OCPU with SMT
  --expected-isolated LIST  Optional validation guard, e.g. 6-31
  --affinity-range LIST     Inject wrapper CPU affinity vars, e.g. 6-31
  --no-affinity             Do not inject wrapper CPU affinity vars
  --vma-lib FILE            Set ONLOAD_COMMAND_VMA="env LD_PRELOAD=FILE"
  --onload-vma COMMAND      Override ONLOAD_COMMAND_VMA directly
  --results-root DIR        Result root (default /home/ubuntu/benchmark-results/runs)

Useful examples:
  source ./preload-benchmark-env.sh --expected-vcpus 32 --expected-isolated 6-31
  ./preload-benchmark-env.sh --show --expected-vcpus 32 --expected-isolated 6-31
  ./preload-benchmark-env.sh --validate --expected-vcpus 32 --expected-isolated 6-31
  ./preload-benchmark-env.sh --run echo --strict 0 --runs 1 --iterations 1 --warmup 1
  ./preload-benchmark-env.sh --run both --strict 0 --runs 3 --iterations 3 --warmup 3
EOF
}

die() {
  echo "preload-benchmark-env: ERROR: $*" >&2
  _preload_restore_shell_opts
  if _preload_sourced; then
    return 1
  fi
  exit 1
}

ACTION="source"
RUN_TARGET=""
SCRIPT_ROOT="$(_preload_dir)"

AERON_PRELOAD_CONFIG_FILE="${AERON_PRELOAD_CONFIG_FILE:-${SCRIPT_ROOT}/config/benchmark-config.env}"
AERON_DRIVER_MODES="${AERON_DRIVER_MODES:-c,c_vma}"
AERON_TARGET_RATE="${AERON_TARGET_RATE:-1001000}"
AERON_MESSAGE_LENGTH="${AERON_MESSAGE_LENGTH:-288}"
AERON_RUNS="${AERON_RUNS:-1}"
AERON_ITERATIONS="${AERON_ITERATIONS:-1}"
AERON_WARMUP_ITERATIONS="${AERON_WARMUP_ITERATIONS:-1}"
AERON_WARMUP_RATE="${AERON_WARMUP_RATE:-}"
AERON_TIMEOUT_SEC="${AERON_TIMEOUT_SEC:-1800}"
AERON_MATRIX_STRICT="${AERON_MATRIX_STRICT:-0}"
AERON_SSH_KEY_FILE="${AERON_SSH_KEY_FILE:-}"
AERON_SSH_USER="${AERON_SSH_USER:-}"
AERON_CLIENT_NODE="${AERON_CLIENT_NODE:-}"
AERON_RECEIVER_NODE="${AERON_RECEIVER_NODE:-}"
AERON_CLUSTER_CLIENT_NODE="${AERON_CLUSTER_CLIENT_NODE:-}"
AERON_CLUSTER_NODE0="${AERON_CLUSTER_NODE0:-}"
AERON_FAILOVER_NODE="${AERON_FAILOVER_NODE:-}"
AERON_REQUIRE_FAILOVER="${AERON_REQUIRE_FAILOVER:-1}"
AERON_EXPECTED_VCPUS="${AERON_EXPECTED_VCPUS:-}"
AERON_EXPECTED_ISOLATED_CPUS="${AERON_EXPECTED_ISOLATED_CPUS:-}"
AERON_AFFINITY_RANGE="${AERON_AFFINITY_RANGE:-}"
AERON_APPLY_AFFINITY="${AERON_APPLY_AFFINITY:-1}"
AERON_NO_SMT_AFFINITY="${AERON_NO_SMT_AFFINITY:-1}"
AERON_VMA_LIB_PATH="${AERON_VMA_LIB_PATH:-}"
AERON_ONLOAD_VMA="${AERON_ONLOAD_VMA:-}"
AERON_RESULTS_ROOT="${AERON_RESULTS_ROOT:-/home/ubuntu/benchmark-results/runs}"
AERON_RUN_ID="${AERON_RUN_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      _preload_restore_shell_opts
      if _preload_sourced; then return 0; else exit 0; fi
      ;;
    --show)
      ACTION="show"
      shift
      ;;
    --validate)
      ACTION="validate"
      shift
      ;;
    --run)
      ACTION="run"
      RUN_TARGET="${2:-}"
      [[ -n "${RUN_TARGET}" ]] || die "--run requires echo|cluster|both"
      shift 2
      ;;
    --config)
      AERON_PRELOAD_CONFIG_FILE="$2"
      shift 2
      ;;
    --modes)
      AERON_DRIVER_MODES="$2"
      shift 2
      ;;
    --rate)
      AERON_TARGET_RATE="$2"
      shift 2
      ;;
    --length)
      AERON_MESSAGE_LENGTH="$2"
      shift 2
      ;;
    --runs)
      AERON_RUNS="$2"
      shift 2
      ;;
    --iterations)
      AERON_ITERATIONS="$2"
      shift 2
      ;;
    --warmup)
      AERON_WARMUP_ITERATIONS="$2"
      shift 2
      ;;
    --warmup-rate)
      AERON_WARMUP_RATE="$2"
      shift 2
      ;;
    --timeout)
      AERON_TIMEOUT_SEC="$2"
      shift 2
      ;;
    --strict)
      AERON_MATRIX_STRICT="$2"
      shift 2
      ;;
    --ssh-key)
      AERON_SSH_KEY_FILE="$2"
      shift 2
      ;;
    --ssh-user)
      AERON_SSH_USER="$2"
      shift 2
      ;;
    --client)
      AERON_CLIENT_NODE="$2"
      shift 2
      ;;
    --receiver|--server)
      AERON_RECEIVER_NODE="$2"
      shift 2
      ;;
    --cluster-client)
      AERON_CLUSTER_CLIENT_NODE="$2"
      shift 2
      ;;
    --cluster-node0)
      AERON_CLUSTER_NODE0="$2"
      shift 2
      ;;
    --failover)
      AERON_FAILOVER_NODE="$2"
      shift 2
      ;;
    --require-failover)
      AERON_REQUIRE_FAILOVER="$2"
      shift 2
      ;;
    --expected-vcpus)
      AERON_EXPECTED_VCPUS="$2"
      shift 2
      ;;
    --expected-isolated)
      AERON_EXPECTED_ISOLATED_CPUS="$2"
      shift 2
      ;;
    --affinity-range)
      AERON_AFFINITY_RANGE="$2"
      AERON_APPLY_AFFINITY=1
      shift 2
      ;;
    --no-affinity)
      AERON_APPLY_AFFINITY=0
      shift
      ;;
    --vma-lib)
      AERON_VMA_LIB_PATH="$2"
      shift 2
      ;;
    --onload-vma)
      AERON_ONLOAD_VMA="$2"
      shift 2
      ;;
    --results-root)
      AERON_RESULTS_ROOT="$2"
      shift 2
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -z "${AERON_AFFINITY_RANGE}" && -n "${AERON_EXPECTED_ISOLATED_CPUS}" ]]; then
  AERON_AFFINITY_RANGE="${AERON_EXPECTED_ISOLATED_CPUS}"
fi
if [[ -z "${AERON_WARMUP_RATE}" ]]; then
  AERON_WARMUP_RATE="${AERON_TARGET_RATE}"
fi

preload_range_bounds() {
  local range="$1" first last
  case "${range}" in
    *-*)
      first="${range%%-*}"
      last="${range##*-}"
      ;;
    *)
      first="${range}"
      last="${range}"
      ;;
  esac
  [[ "${first}" =~ ^[0-9]+$ && "${last}" =~ ^[0-9]+$ && "${first}" -le "${last}" ]] || return 1
  printf '%s %s\n' "${first}" "${last}"
}

preload_cpu_at() {
  local first="$1" last="$2" offset="$3" candidate
  if [[ "${AERON_NO_SMT_AFFINITY:-1}" == "1" ]]; then
    candidate=$((first + (offset * 2)))
  else
    candidate=$((first + offset))
  fi
  if (( candidate > last )); then
    candidate="${last}"
  fi
  printf '%s\n' "${candidate}"
}

preload_cpu_list() {
  local first="$1" last="$2" cpu step sep=""
  step=1
  if [[ "${AERON_NO_SMT_AFFINITY:-1}" == "1" ]]; then
    step=2
  fi
  for ((cpu = first; cpu <= last; cpu += step)); do
    printf '%s%s' "${sep}" "${cpu}"
    sep=","
  done
  printf '\n'
}

preload_apply_topology_overrides() {
  if [[ -n "${AERON_SSH_USER}" ]]; then
    export SSH_USER="${AERON_SSH_USER}"
  fi
  if [[ -n "${AERON_SSH_KEY_FILE}" ]]; then
    export SSH_KEY_FILE="${AERON_SSH_KEY_FILE}"
  fi
  if [[ -n "${AERON_CLIENT_NODE}" ]]; then
    export SSH_CLIENT_NODE="${AERON_CLIENT_NODE}"
    if [[ -z "${AERON_CLUSTER_CLIENT_NODE}" ]]; then
      export CLUSTER_SSH_CLIENT_NODE="${AERON_CLIENT_NODE}"
    fi
  fi
  if [[ -n "${AERON_RECEIVER_NODE}" ]]; then
    export SSH_SERVER_NODE="${AERON_RECEIVER_NODE}"
    if [[ -z "${AERON_CLUSTER_NODE0}" ]]; then
      export CLUSTER_SSH_CLUSTER_NODE0="${AERON_RECEIVER_NODE}"
    fi
  fi
  if [[ -n "${AERON_CLUSTER_CLIENT_NODE}" ]]; then
    export CLUSTER_SSH_CLIENT_NODE="${AERON_CLUSTER_CLIENT_NODE}"
  fi
  if [[ -n "${AERON_CLUSTER_NODE0}" ]]; then
    export CLUSTER_SSH_CLUSTER_NODE0="${AERON_CLUSTER_NODE0}"
  fi
  if [[ -n "${AERON_FAILOVER_NODE}" ]]; then
    export CLUSTER_SSH_BACKUP_NODE0="${AERON_FAILOVER_NODE}"
    export CLUSTER_BACKUP_NODES=1
  fi
}

preload_apply_onload_overrides() {
  if [[ -n "${AERON_VMA_LIB_PATH}" ]]; then
    export ONLOAD_COMMAND_VMA="env LD_PRELOAD=${AERON_VMA_LIB_PATH}"
  fi
  if [[ -n "${AERON_ONLOAD_VMA}" ]]; then
    export ONLOAD_COMMAND_VMA="${AERON_ONLOAD_VMA}"
  fi
}

preload_apply_affinity() {
  [[ "${AERON_APPLY_AFFINITY}" == "1" && -n "${AERON_AFFINITY_RANGE}" ]] || return 0

  local bounds first last affinity_cpus
  bounds="$(preload_range_bounds "${AERON_AFFINITY_RANGE}")" || {
    die "invalid --affinity-range: ${AERON_AFFINITY_RANGE}"
    return 1
  }
  first="${bounds% *}"
  last="${bounds#* }"
  affinity_cpus="$(preload_cpu_list "${first}" "${last}")"

  export AERON_AFFINITY_RANGE
  export AERON_NO_SMT_AFFINITY
  export AERON_PRELOAD_KEEP_AFFINITY=1
  export AERON_SSH_TASKSET_CPUS="${affinity_cpus}"
  export CLIENT_TASKSET="${affinity_cpus}"
  export SERVER_TASKSET="${affinity_cpus}"

  export CLIENT_NON_ISOLATED_CPU_CORES="${affinity_cpus}"
  export SERVER_NON_ISOLATED_CPU_CORES="${affinity_cpus}"
  # Echo wrapper may narrow this range after live numactl/cgroup validation
  # (for example 6-31 -> 8-31). Leave per-thread pins unset so it chooses
  # conductor/sender/receiver/app cores inside the resolved usable range.
  unset CLIENT_DRIVER_CONDUCTOR_CPU_CORE
  unset CLIENT_DRIVER_SENDER_CPU_CORE
  unset CLIENT_DRIVER_RECEIVER_CPU_CORE
  unset CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE
  unset CLIENT_CPU_NODE
  unset SERVER_DRIVER_CONDUCTOR_CPU_CORE
  unset SERVER_DRIVER_SENDER_CPU_CORE
  unset SERVER_DRIVER_RECEIVER_CPU_CORE
  unset SERVER_ECHO_CPU_CORE
  unset SERVER_CPU_NODE

  if [[ "${AERON_NO_SMT_AFFINITY:-1}" == "1" ]]; then
    export CLUSTER_CPU_AFFINITY_MODE="static"
    export CLUSTER_CPU_AFFINITY_ALLOW_NARROWING="0"
  else
    export CLUSTER_CPU_AFFINITY_MODE="${CLUSTER_CPU_AFFINITY_MODE:-auto}"
  fi
  export CLUSTER_CPU_AFFINITY_FALLBACK_LAST="${last}"
  export CLUSTER_AERON_SSH_TASKSET_CPUS="${affinity_cpus}"
  export CLUSTER_CLIENT_NON_ISOLATED_CPU_CORES="${affinity_cpus}"
  export CLUSTER_NODE0_NON_ISOLATED_CPU_CORES="${affinity_cpus}"
  export CLUSTER_CLIENT_DRIVER_CONDUCTOR_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 0)"
  export CLUSTER_CLIENT_DRIVER_SENDER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 1)"
  export CLUSTER_CLIENT_DRIVER_RECEIVER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 2)"
  export CLUSTER_CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 3)"
  export CLUSTER_NODE0_DRIVER_CONDUCTOR_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 0)"
  export CLUSTER_NODE0_DRIVER_SENDER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 1)"
  export CLUSTER_NODE0_DRIVER_RECEIVER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 2)"
  export CLUSTER_NODE0_CONSENSUS_MODULE_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 3)"
  export CLUSTER_NODE0_CLUSTERED_SERVICE_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 4)"
  export CLUSTER_NODE0_ARCHIVE_RECORDER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 5)"
  export CLUSTER_NODE0_ARCHIVE_REPLAYER_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 6)"
  export CLUSTER_NODE0_ARCHIVE_CONDUCTOR_CPU_CORE="$(preload_cpu_at "${first}" "${last}" 7)"
}

preload_apply_env() {
  [[ -f "${AERON_PRELOAD_CONFIG_FILE}" ]] || {
    die "config file not found: ${AERON_PRELOAD_CONFIG_FILE}"
    return 1
  }

  if [[ -f "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_ROOT}/clear-benchmark-affinity-env.sh"
  fi

  # Export before sourcing config because benchmark-config.env uses ${VAR:-default}.
  export BENCH_PROFILE=custom
  export RUNS="${AERON_RUNS}"
  export ITERATIONS="${AERON_ITERATIONS}"
  export WARMUP_ITERATIONS="${AERON_WARMUP_ITERATIONS}"
  export WARMUP_MESSAGE_RATE="${AERON_WARMUP_RATE}"
  export MESSAGE_LENGTH="${AERON_MESSAGE_LENGTH}"
  export MESSAGE_RATE="${AERON_TARGET_RATE}"
  export MATRIX_MODES="${AERON_DRIVER_MODES}"
  export MATRIX_STRICT="${AERON_MATRIX_STRICT}"
  export MATRIX_MODE_TIMEOUT_SEC="${AERON_TIMEOUT_SEC}"
  export MATRIX_ALLOW_STALE_ARCHIVE=0
  export BENCHMARK_SKIP_KERNEL_PARITY=0
  export BENCHMARK_SKIP_VMA_PREFLIGHT=0
  export BENCHMARK_QUIET_MODE="${BENCHMARK_QUIET_MODE:-1}"
  export BENCHMARK_QUIET_RESTORE="${BENCHMARK_QUIET_RESTORE:-1}"

  set -a
  # shellcheck source=/dev/null
  source "${AERON_PRELOAD_CONFIG_FILE}"
  set +a

  # Re-assert fixed-test values after config sourcing.
  export BENCH_PROFILE=custom
  export RUNS="${AERON_RUNS}"
  export ITERATIONS="${AERON_ITERATIONS}"
  export WARMUP_ITERATIONS="${AERON_WARMUP_ITERATIONS}"
  export WARMUP_MESSAGE_RATE="${AERON_WARMUP_RATE}"
  export MESSAGE_LENGTH="${AERON_MESSAGE_LENGTH}"
  export MESSAGE_RATE="${AERON_TARGET_RATE}"
  export MATRIX_MODES="${AERON_DRIVER_MODES}"
  export MATRIX_STRICT="${AERON_MATRIX_STRICT}"
  export MATRIX_MODE_TIMEOUT_SEC="${AERON_TIMEOUT_SEC}"
  export MATRIX_ALLOW_STALE_ARCHIVE=0

  preload_apply_topology_overrides
  preload_apply_onload_overrides
  preload_apply_affinity || return 1

  if [[ "${CLUSTER_BACKUP_NODES:-0}" == "1" && -z "${CLUSTER_SSH_BACKUP_NODE0:-}" ]]; then
    die "CLUSTER_BACKUP_NODES=1 but CLUSTER_SSH_BACKUP_NODE0 is empty"
    return 1
  fi
}

_remote() {
  local host="$1"
  shift
  ssh -n -i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
    "${SSH_USER:-ubuntu}@${host}" "$@"
}

_has_vma_mode() {
  [[ ",${MATRIX_MODES}," == *",java_vma,"* || ",${MATRIX_MODES}," == *",c_vma,"* ]]
}

preload_hosts() {
  printf '%s\n' "${SSH_CLIENT_NODE:-}" "${SSH_SERVER_NODE:-}" "${CLUSTER_SSH_CLIENT_NODE:-}" "${CLUSTER_SSH_CLUSTER_NODE0:-}"
  if [[ "${CLUSTER_BACKUP_NODES:-0}" == "1" ]]; then
    printf '%s\n' "${CLUSTER_SSH_BACKUP_NODE0:-}"
  fi
}

preload_validate() {
  [[ -n "${SSH_KEY_FILE:-}" && -f "${SSH_KEY_FILE}" ]] || die "SSH_KEY_FILE missing/not found: ${SSH_KEY_FILE:-}"
  [[ -n "${SSH_CLIENT_NODE:-}" ]] || die "SSH_CLIENT_NODE is empty"
  [[ -n "${SSH_SERVER_NODE:-}" ]] || die "SSH_SERVER_NODE is empty"
  [[ -n "${CLUSTER_SSH_CLIENT_NODE:-}" ]] || die "CLUSTER_SSH_CLIENT_NODE is empty"
  [[ -n "${CLUSTER_SSH_CLUSTER_NODE0:-}" ]] || die "CLUSTER_SSH_CLUSTER_NODE0 is empty"

  if [[ "${AERON_REQUIRE_FAILOVER}" == "1" ]]; then
    [[ "${CLUSTER_BACKUP_NODES:-0}" == "1" ]] || die "failover required but CLUSTER_BACKUP_NODES=${CLUSTER_BACKUP_NODES:-unset}"
    [[ -n "${CLUSTER_SSH_BACKUP_NODE0:-}" ]] || die "failover required but CLUSTER_SSH_BACKUP_NODE0 is empty"
  fi

  local seen=" " host nproc cmdline vma_missing=0
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    [[ "${seen}" == *" ${host} "* ]] && continue
    seen="${seen}${host} "

    nproc="$(_remote "${host}" 'getconf _NPROCESSORS_ONLN')"
    cmdline="$(_remote "${host}" 'tr -s " " < /proc/cmdline')"
    printf 'host=%s nproc=%s cmdline_isolation=%s\n' \
      "${host}" "${nproc}" "$(grep -oE 'isolcpus=[^ ]+|nohz_full=[^ ]+|rcu_nocbs=[^ ]+|irqaffinity=[^ ]+' <<<"${cmdline}" | xargs)"

    if [[ -n "${AERON_EXPECTED_VCPUS}" && "${nproc}" != "${AERON_EXPECTED_VCPUS}" ]]; then
      die "${host}: expected ${AERON_EXPECTED_VCPUS} vCPUs, saw ${nproc}"
    fi
    if [[ -n "${AERON_EXPECTED_ISOLATED_CPUS}" ]]; then
      [[ "${cmdline}" == *"isolcpus=managed_irq,domain,${AERON_EXPECTED_ISOLATED_CPUS}"* ]] || \
        die "${host}: expected isolcpus=${AERON_EXPECTED_ISOLATED_CPUS}"
      [[ "${cmdline}" == *"nohz_full=${AERON_EXPECTED_ISOLATED_CPUS}"* ]] || \
        die "${host}: expected nohz_full=${AERON_EXPECTED_ISOLATED_CPUS}"
      [[ "${cmdline}" == *"rcu_nocbs=${AERON_EXPECTED_ISOLATED_CPUS}"* ]] || \
        die "${host}: expected rcu_nocbs=${AERON_EXPECTED_ISOLATED_CPUS}"
    fi

    if _has_vma_mode; then
      local vma_lib="/usr/lib/x86_64-linux-gnu/libvma.so.9"
      if [[ "${ONLOAD_COMMAND_VMA:-}" =~ LD_PRELOAD=([^[:space:]]+) ]]; then
        vma_lib="${BASH_REMATCH[1]}"
      fi
      local q_vma_lib
      printf -v q_vma_lib '%q' "${vma_lib}"
      if ! _remote "${host}" "test -e ${q_vma_lib} && test -d /sys/class/infiniband && find /sys/class/infiniband -mindepth 1 -maxdepth 1 -print -quit | grep -q ."; then
        echo "preload-benchmark-env: VMA/RDMA preflight failed on ${host}" >&2
        vma_missing=1
      fi
    fi
  done < <(preload_hosts)

  [[ "${vma_missing}" == "0" ]] || die "VMA requested but one or more hosts failed VMA/RDMA preflight"
}

preload_show() {
  cat <<EOF
CONFIG_FILE=${AERON_PRELOAD_CONFIG_FILE}
MATRIX_MODES=${MATRIX_MODES}
MATRIX_STRICT=${MATRIX_STRICT}
MATRIX_MODE_TIMEOUT_SEC=${MATRIX_MODE_TIMEOUT_SEC}
RUNS=${RUNS}
ITERATIONS=${ITERATIONS}
WARMUP_ITERATIONS=${WARMUP_ITERATIONS}
WARMUP_MESSAGE_RATE=${WARMUP_MESSAGE_RATE}
MESSAGE_LENGTH=${MESSAGE_LENGTH}
MESSAGE_RATE=${MESSAGE_RATE}
AFFINITY_RANGE=${AERON_AFFINITY_RANGE:-}
AERON_SSH_TASKSET_CPUS=${AERON_SSH_TASKSET_CPUS:-}
CLIENT_NON_ISOLATED_CPU_CORES=${CLIENT_NON_ISOLATED_CPU_CORES:-}
SERVER_NON_ISOLATED_CPU_CORES=${SERVER_NON_ISOLATED_CPU_CORES:-}
CLUSTER_AERON_SSH_TASKSET_CPUS=${CLUSTER_AERON_SSH_TASKSET_CPUS:-}
SSH_CLIENT_NODE=${SSH_CLIENT_NODE:-}
SSH_SERVER_NODE=${SSH_SERVER_NODE:-}
CLUSTER_SSH_CLIENT_NODE=${CLUSTER_SSH_CLIENT_NODE:-}
CLUSTER_SSH_CLUSTER_NODE0=${CLUSTER_SSH_CLUSTER_NODE0:-}
CLUSTER_BACKUP_NODES=${CLUSTER_BACKUP_NODES:-0}
CLUSTER_SSH_BACKUP_NODE0=${CLUSTER_SSH_BACKUP_NODE0:-}
SSH_KEY_FILE=${SSH_KEY_FILE:-}
EOF
}

preload_run_one() {
  local target="$1"
  local run_id="${AERON_RUN_ID}"
  if [[ -z "${run_id}" ]]; then
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-${target}-${MESSAGE_RATE}-${MATRIX_MODES//,/}-preloaded"
  fi
  local results_dir="${AERON_RESULTS_ROOT}/${run_id}"
  mkdir -p "${results_dir}"
  export STATUS_FILE="${results_dir}/STATUS.txt"
  export SUMMARY_FILE="${results_dir}/driver-matrix-${target}-preloaded.csv"
  export CONFIG_FILE="${AERON_PRELOAD_CONFIG_FILE}"
  export AERON_PRELOAD_KEEP_AFFINITY=1

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) preloaded ${target} start results_dir=${results_dir}" | tee -a "${STATUS_FILE}"
  ( cd "${SCRIPT_ROOT}" && ./run-driver-matrix.sh "${target}" )
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) preloaded ${target} complete" | tee -a "${STATUS_FILE}"
  echo "${results_dir}"
}

preload_run() {
  preload_validate
  case "${RUN_TARGET}" in
    echo|cluster)
      preload_run_one "${RUN_TARGET}"
      ;;
    both)
      AERON_RUN_ID="${AERON_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-both-${MESSAGE_RATE}-${MATRIX_MODES//,/}-preloaded}"
      preload_run_one echo
      preload_run_one cluster
      ;;
    *)
      die "--run target must be echo, cluster, or both"
      ;;
  esac
}

preload_apply_env

case "${ACTION}" in
  source)
    if ! _preload_sourced; then
      preload_show
      echo
      echo "Run with --show, --validate, or --run echo|cluster|both. To export into your shell: source $0"
    fi
    ;;
  show)
    preload_show
    ;;
  validate)
    preload_show
    preload_validate
    ;;
  run)
    preload_show
    preload_run
    ;;
esac

_preload_restore_shell_opts
