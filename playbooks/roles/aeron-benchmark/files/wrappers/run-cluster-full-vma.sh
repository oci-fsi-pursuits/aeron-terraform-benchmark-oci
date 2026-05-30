#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_ROOT="$(pwd)"

CONFIG_FILE="${CONFIG_FILE:-./config/benchmark-config.env}"
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

vma_ld_preload_path_from_cmd() {
  local s="${1:-}" lib_path=""
  if [[ "${s}" =~ LD_PRELOAD=([^[:space:]]+) ]]; then
    lib_path="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${lib_path}"
}

RESULTS_ROOT="${RESULTS_ROOT:-${HOME}/benchmark-results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-cluster-vma-full}"
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/runs/${RUN_ID}}"
STATUS_FILE="${STATUS_FILE:-${RUN_DIR}/STATUS.txt}"
RUN_INDEX="${RUN_INDEX:-${RUN_DIR}/run-index.csv}"
FINAL_AGGREGATE="${FINAL_AGGREGATE:-${RUN_DIR}/cluster-full-vma-aggregate.csv}"

VMA_LIB_PATH="${VMA_LIB_PATH:-$(vma_ld_preload_path_from_cmd "${ONLOAD_COMMAND_VMA:-}")}"
VMA_LIB_PATH="${VMA_LIB_PATH:-/usr/lib/x86_64-linux-gnu/libvma.so.9}"
VMA_RUN_AS_ROOT="${VMA_RUN_AS_ROOT:-1}"
if [[ -n "${VMA_ONLOAD_COMMAND:-}" ]]; then
  VMA_EFFECTIVE_ONLOAD="${VMA_ONLOAD_COMMAND}"
elif [[ "${VMA_RUN_AS_ROOT}" == "1" ]]; then
  VMA_EFFECTIVE_ONLOAD="sudo -E env LD_PRELOAD=${VMA_LIB_PATH}"
else
  VMA_EFFECTIVE_ONLOAD="env LD_PRELOAD=${VMA_LIB_PATH}"
fi

FULL_BENCH_RATES="${FULL_BENCH_RATES:-101K,1001K}"
FULL_BENCH_MODES="${FULL_BENCH_MODES:-java_vma,c_vma}"
FULL_BENCH_RUNS="${FULL_BENCH_RUNS:-${RUNS:-5}}"
FULL_BENCH_ITERATIONS="${FULL_BENCH_ITERATIONS:-${ITERATIONS:-30}}"
FULL_BENCH_WARMUP_ITERATIONS="${FULL_BENCH_WARMUP_ITERATIONS:-${WARMUP_ITERATIONS:-10}}"
FULL_BENCH_MESSAGE_LENGTH="${FULL_BENCH_MESSAGE_LENGTH:-${MESSAGE_LENGTH:-288}}"
FULL_BENCH_WARMUP_RATE="${FULL_BENCH_WARMUP_RATE:-${WARMUP_MESSAGE_RATE:-25K}}"
FULL_BENCH_STRICT="${FULL_BENCH_STRICT:-0}"
FULL_BENCH_MODE_TIMEOUT_SEC="${FULL_BENCH_MODE_TIMEOUT_SEC:-2400}"

mkdir -p "${RUN_DIR}"
printf '%s\n' "${RUN_DIR}" > "${RESULTS_ROOT}/latest-run.txt"
printf 'rate,mode,status,archive,summary,log\n' > "${RUN_INDEX}"

status() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${STATUS_FILE}"
}

csv_to_array() {
  local csv="$1"
  local -n out="$2"
  IFS=',' read -r -a out <<< "${csv}"
}

archive_from_log() {
  local log="$1"
  local test_dir archive
  test_dir="$(sed -n 's/.*test_dir=\(aeron-[0-9A-Za-z-]*\).*/\1/p' "${log}" | tail -n 1 | tr -d '\r' || true)"
  if [[ -n "${test_dir}" ]]; then
    archive="./${test_dir}-client.tar.gz"
    [[ -f "${archive}" ]] && { printf '%s\n' "${archive}"; return 0; }
  fi
  ls -1t ./aeron-cluster-*-client.tar.gz 2>/dev/null | head -n 1 || true
}

copy_archive_to_run_dir() {
  local archive="$1"
  local dest="${RUN_DIR}/$(basename "${archive}")"
  cp -f "${archive}" "${dest}"
  printf '%s\n' "${dest}"
}

archives=()
run_failures=0
csv_to_array "${FULL_BENCH_RATES}" rates
csv_to_array "${FULL_BENCH_MODES}" modes

status "VMA full cluster benchmark started: ${RUN_DIR}"
status "rates=${FULL_BENCH_RATES} modes=${FULL_BENCH_MODES} runs=${FULL_BENCH_RUNS} iterations=${FULL_BENCH_ITERATIONS}"
status "VMA lib=${VMA_LIB_PATH}"
status "VMA onload='${VMA_EFFECTIVE_ONLOAD}'"

if [[ "${VMA_PREPARE_NODES:-1}" == "1" ]]; then
  status "enabling VMA benchmark state on cluster nodes"
  VMA_LIB_PATH="${VMA_LIB_PATH}" \
  VMA_REQUIRE_RDMA="${VMA_REQUIRE_RDMA:-1}" \
  VMA_APPLY_FILE_CAPS="${VMA_APPLY_FILE_CAPS:-0}" \
  bash ./enable-vma-on-nodes.sh enable "${CONFIG_FILE}" \
    > "${RUN_DIR}/enable-vma-state.log" 2>&1
fi

VMA_LIB_PATH="${VMA_LIB_PATH}" bash ./enable-vma-on-nodes.sh status "${CONFIG_FILE}" \
  > "${RUN_DIR}/vma-status-before.log" 2>&1 || true

unset LD_PRELOAD || true
export ONLOAD_COMMAND_PLAIN="env"
export ONLOAD_COMMAND_VMA="${VMA_EFFECTIVE_ONLOAD}"
export ONLOAD_COMMAND="${VMA_EFFECTIVE_ONLOAD}"
export CLUSTER_BACKUP_ENABLE_VMA=1

for rate_raw in "${rates[@]}"; do
  rate="$(echo "${rate_raw}" | xargs)"
  [[ -z "${rate}" ]] && continue
  for mode_raw in "${modes[@]}"; do
    mode="$(echo "${mode_raw}" | xargs)"
    [[ -z "${mode}" ]] && continue
    case "${mode}" in
      java_vma|c_vma|java-onload|c-onload) ;;
      *)
        status "skipping unsupported VMA cluster mode=${mode}"
        continue
        ;;
    esac

    log="${RUN_DIR}/cluster-${mode}-${rate}.log"
    summary="${RUN_DIR}/driver-matrix-cluster-${mode}-${rate}.csv"
    status "running VMA cluster mode=${mode} rate=${rate}"

    if env -u LD_PRELOAD \
      CONFIG_FILE="${CONFIG_FILE}" \
      MATRIX_MODES="${mode}" \
      MATRIX_STRICT="${FULL_BENCH_STRICT}" \
      MATRIX_MODE_TIMEOUT_SEC="${FULL_BENCH_MODE_TIMEOUT_SEC}" \
      BENCH_PROFILE="custom" \
      RUNS="${FULL_BENCH_RUNS}" \
      ITERATIONS="${FULL_BENCH_ITERATIONS}" \
      WARMUP_ITERATIONS="${FULL_BENCH_WARMUP_ITERATIONS}" \
      MESSAGE_LENGTH="${FULL_BENCH_MESSAGE_LENGTH}" \
      MESSAGE_RATE="${rate}" \
      WARMUP_MESSAGE_RATE="${FULL_BENCH_WARMUP_RATE}" \
      ONLOAD_COMMAND_PLAIN="env" \
      ONLOAD_COMMAND_VMA="${VMA_EFFECTIVE_ONLOAD}" \
      ONLOAD_COMMAND="${VMA_EFFECTIVE_ONLOAD}" \
      CLUSTER_BACKUP_ENABLE_VMA=1 \
      BENCHMARK_SKIP_C_VMA_ON_NO_IB="${BENCHMARK_SKIP_C_VMA_ON_NO_IB:-0}" \
      STATUS_FILE="${STATUS_FILE}" \
      SUMMARY_FILE="${summary}" \
      ./run-driver-matrix.sh cluster > "${log}" 2>&1; then
      run_status="ok"
    else
      rc=$?
      run_status="failed:${rc}"
      run_failures=$((run_failures + 1))
      status "cluster mode=${mode} rate=${rate} failed rc=${rc}; see ${log}"
      if [[ "${FULL_BENCH_STRICT}" == "1" ]]; then
        printf '%s,%s,%s,,%s,%s\n' "${rate}" "${mode}" "${run_status}" "${summary}" "${log}" >> "${RUN_INDEX}"
        exit "${rc}"
      fi
    fi

    archive="$(archive_from_log "${log}")"
    if [[ -n "${archive}" && -f "${archive}" ]]; then
      copied="$(copy_archive_to_run_dir "${archive}")"
      archives+=("${copied}")
      printf '%s,%s,%s,%s,%s,%s\n' "${rate}" "${mode}" "${run_status}" "${copied}" "${summary}" "${log}" >> "${RUN_INDEX}"
      status "captured cluster archive mode=${mode} rate=${rate}: ${copied}"
    else
      printf '%s,%s,%s,,%s,%s\n' "${rate}" "${mode}" "${run_status}:no-archive" "${summary}" "${log}" >> "${RUN_INDEX}"
      status "WARNING: no cluster client archive found for mode=${mode} rate=${rate}"
    fi
  done
done

VMA_LIB_PATH="${VMA_LIB_PATH}" bash ./enable-vma-on-nodes.sh status "${CONFIG_FILE}" \
  > "${RUN_DIR}/vma-status-after.log" 2>&1 || true

if [[ "${#archives[@]}" -gt 0 ]]; then
  status "aggregating ${#archives[@]} VMA cluster archive(s)"
  bash ./aggregate-compare-results.sh "${archives[@]}" | tee "${FINAL_AGGREGATE}"
else
  status "ERROR: no cluster archives captured; aggregate not produced"
  exit 1
fi

if [[ "${run_failures}" -gt 0 ]]; then
  status "VMA full cluster benchmark completed with ${run_failures} failed run(s)"
  exit 1
fi

status "VMA full cluster benchmark completed successfully"
status "aggregate=${FINAL_AGGREGATE}"
