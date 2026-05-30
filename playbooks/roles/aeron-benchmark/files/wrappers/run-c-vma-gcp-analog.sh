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
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-c-vma-gcp-analog}"
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/runs/${RUN_ID}}"
STATUS_FILE="${STATUS_FILE:-${RUN_DIR}/STATUS.txt}"
RUN_INDEX="${RUN_INDEX:-${RUN_DIR}/run-index.csv}"
FINAL_AGGREGATE="${FINAL_AGGREGATE:-${RUN_DIR}/c-vma-gcp-analog-aggregate.csv}"
VMA_VALIDATION="${VMA_VALIDATION:-${RUN_DIR}/vma-validation.csv}"

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

ANALOG_TARGETS="${ANALOG_TARGETS:-echo,cluster}"
ANALOG_RATES="${ANALOG_RATES:-101K,1001K}"
ANALOG_MODES="${ANALOG_MODES:-c,c_vma}"
ANALOG_RUNS="${ANALOG_RUNS:-${RUNS:-5}}"
ANALOG_ITERATIONS="${ANALOG_ITERATIONS:-${ITERATIONS:-30}}"
ANALOG_WARMUP_ITERATIONS="${ANALOG_WARMUP_ITERATIONS:-${WARMUP_ITERATIONS:-10}}"
ANALOG_MESSAGE_LENGTH="${ANALOG_MESSAGE_LENGTH:-${MESSAGE_LENGTH:-288}}"
ANALOG_WARMUP_RATE="${ANALOG_WARMUP_RATE:-${WARMUP_MESSAGE_RATE:-25K}}"
ANALOG_STRICT="${ANALOG_STRICT:-0}"
ANALOG_MODE_TIMEOUT_SEC="${ANALOG_MODE_TIMEOUT_SEC:-2400}"

mkdir -p "${RUN_DIR}"
printf '%s\n' "${RUN_DIR}" > "${RESULTS_ROOT}/latest-run.txt"
printf 'target,rate,modes,status,archive,summary,log\n' > "${RUN_INDEX}"

status() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${STATUS_FILE}"
}

csv_to_array() {
  local csv="$1"
  local -n out="$2"
  IFS=',' read -r -a out <<< "${csv}"
}

archive_from_log() {
  local target="$1"
  local log="$2"
  local test_dir archive pattern
  test_dir="$(sed -n 's/.*test_dir=\(aeron-[0-9A-Za-z-]*\).*/\1/p' "${log}" | tail -n 1 | tr -d '\r' || true)"
  if [[ -n "${test_dir}" ]]; then
    archive="./${test_dir}-client.tar.gz"
    [[ -f "${archive}" ]] && { printf '%s\n' "${archive}"; return 0; }
  fi
  if [[ "${target}" == "echo" ]]; then
    pattern="./aeron-echo-*-client.tar.gz"
  else
    pattern="./aeron-cluster-*-client.tar.gz"
  fi
  ls -1t ${pattern} 2>/dev/null | head -n 1 || true
}

copy_archive_to_run_dir() {
  local target="$1"
  local rate="$2"
  local archive="$3"
  local base dest
  base="$(basename "${archive}")"
  dest="${RUN_DIR}/${target}-${rate}-${base}"
  cp -f "${archive}" "${dest}"
  printf '%s\n' "${dest}"
}

validate_vma_archives() {
  local archive tmp vma_hits not_offloaded ib_missing preload_ignored
  printf 'archive,VMA_VERSION_hits,not_offloaded_hits,ib_missing_hits,preload_ignored_hits\n' > "${VMA_VALIDATION}"
  for archive in "$@"; do
    tmp="$(mktemp -d)"
    if tar -xzf "${archive}" -C "${tmp}" >/dev/null 2>&1; then
      vma_hits="$(grep -Rhs 'VMA_VERSION' "${tmp}" 2>/dev/null | wc -l | tr -d ' ')"
      not_offloaded="$(grep -Rhs 'will not be offloaded' "${tmp}" 2>/dev/null | wc -l | tr -d ' ')"
      ib_missing="$(grep -Rhs 'VMA does not detect IB capable devices' "${tmp}" 2>/dev/null | wc -l | tr -d ' ')"
      preload_ignored="$(grep -Rhs 'LD_PRELOAD.*ignored' "${tmp}" 2>/dev/null | wc -l | tr -d ' ')"
    else
      vma_hits=0
      not_offloaded=0
      ib_missing=0
      preload_ignored=0
    fi
    rm -rf "${tmp}"
    printf '%s,%s,%s,%s,%s\n' "$(basename "${archive}")" "${vma_hits}" "${not_offloaded}" "${ib_missing}" "${preload_ignored}" >> "${VMA_VALIDATION}"
  done
}

archives=()
run_failures=0
csv_to_array "${ANALOG_TARGETS}" targets
csv_to_array "${ANALOG_RATES}" rates

status "C/VMA GCP-analog benchmark started: ${RUN_DIR}"
status "targets=${ANALOG_TARGETS} rates=${ANALOG_RATES} modes=${ANALOG_MODES} runs=${ANALOG_RUNS} iterations=${ANALOG_ITERATIONS}"
status "VMA lib=${VMA_LIB_PATH}"
status "VMA onload='${VMA_EFFECTIVE_ONLOAD}'"

if [[ "${VMA_PREPARE_NODES:-1}" == "1" ]]; then
  status "enabling VMA benchmark state on nodes"
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
export CLUSTER_BACKUP_ENABLE_VMA="${CLUSTER_BACKUP_ENABLE_VMA:-1}"

for target_raw in "${targets[@]}"; do
  target="$(echo "${target_raw}" | xargs)"
  [[ -z "${target}" ]] && continue
  case "${target}" in
    echo|cluster) ;;
    *)
      status "skipping unsupported target=${target}"
      continue
      ;;
  esac

  for rate_raw in "${rates[@]}"; do
    rate="$(echo "${rate_raw}" | xargs)"
    [[ -z "${rate}" ]] && continue

    log="${RUN_DIR}/${target}-c-vs-c_vma-${rate}.log"
    summary="${RUN_DIR}/driver-matrix-${target}-c-vs-c_vma-${rate}.csv"
    status "running target=${target} rate=${rate} modes=${ANALOG_MODES}"

    if env -u LD_PRELOAD \
      CONFIG_FILE="${CONFIG_FILE}" \
      MATRIX_MODES="${ANALOG_MODES}" \
      MATRIX_STRICT="${ANALOG_STRICT}" \
      MATRIX_MODE_TIMEOUT_SEC="${ANALOG_MODE_TIMEOUT_SEC}" \
      BENCH_PROFILE="custom" \
      RUNS="${ANALOG_RUNS}" \
      ITERATIONS="${ANALOG_ITERATIONS}" \
      WARMUP_ITERATIONS="${ANALOG_WARMUP_ITERATIONS}" \
      MESSAGE_LENGTH="${ANALOG_MESSAGE_LENGTH}" \
      MESSAGE_RATE="${rate}" \
      WARMUP_MESSAGE_RATE="${ANALOG_WARMUP_RATE}" \
      ONLOAD_COMMAND_PLAIN="env" \
      ONLOAD_COMMAND_VMA="${VMA_EFFECTIVE_ONLOAD}" \
      ONLOAD_COMMAND="${VMA_EFFECTIVE_ONLOAD}" \
      CLUSTER_BACKUP_ENABLE_VMA="${CLUSTER_BACKUP_ENABLE_VMA}" \
      BENCHMARK_SKIP_C_VMA_ON_NO_IB="${BENCHMARK_SKIP_C_VMA_ON_NO_IB:-0}" \
      STATUS_FILE="${STATUS_FILE}" \
      SUMMARY_FILE="${summary}" \
      ./run-driver-matrix.sh "${target}" > "${log}" 2>&1; then
      run_status="ok"
    else
      rc=$?
      run_status="failed:${rc}"
      run_failures=$((run_failures + 1))
      status "target=${target} rate=${rate} failed rc=${rc}; see ${log}"
      if [[ "${ANALOG_STRICT}" == "1" ]]; then
        printf '%s,%s,%s,%s,,%s,%s\n' "${target}" "${rate}" "${ANALOG_MODES}" "${run_status}" "${summary}" "${log}" >> "${RUN_INDEX}"
        exit "${rc}"
      fi
    fi

    archive="$(archive_from_log "${target}" "${log}")"
    if [[ -n "${archive}" && -f "${archive}" ]]; then
      copied="$(copy_archive_to_run_dir "${target}" "${rate}" "${archive}")"
      archives+=("${copied}")
      printf '%s,%s,%s,%s,%s,%s,%s\n' "${target}" "${rate}" "${ANALOG_MODES}" "${run_status}" "${copied}" "${summary}" "${log}" >> "${RUN_INDEX}"
      status "captured archive target=${target} rate=${rate}: ${copied}"
    else
      printf '%s,%s,%s,%s,,%s,%s\n' "${target}" "${rate}" "${ANALOG_MODES}" "${run_status}:no-archive" "${summary}" "${log}" >> "${RUN_INDEX}"
      status "WARNING: no client archive found for target=${target} rate=${rate}"
    fi
  done
done

VMA_LIB_PATH="${VMA_LIB_PATH}" bash ./enable-vma-on-nodes.sh status "${CONFIG_FILE}" \
  > "${RUN_DIR}/vma-status-after.log" 2>&1 || true

if [[ "${#archives[@]}" -gt 0 ]]; then
  status "validating VMA proof in captured archives"
  validate_vma_archives "${archives[@]}"
  if awk -F, 'NR > 1 && ($2 == 0 || $3 > 0 || $4 > 0 || $5 > 0) { bad=1 } END { exit bad ? 0 : 1 }' "${VMA_VALIDATION}"; then
    status "WARNING: VMA validation found missing proof or offload failure; see ${VMA_VALIDATION}"
    if [[ "${ANALOG_REQUIRE_VMA_PROOF:-1}" == "1" ]]; then
      exit 1
    fi
  fi
fi

if [[ "${#archives[@]}" -gt 0 ]]; then
  status "aggregating ${#archives[@]} archive(s)"
  bash ./aggregate-compare-results.sh "${archives[@]}" | tee "${FINAL_AGGREGATE}"
else
  status "ERROR: no archives captured; aggregate not produced"
  exit 1
fi

if [[ "${run_failures}" -gt 0 ]]; then
  status "C/VMA GCP-analog benchmark completed with ${run_failures} failed run(s)"
  exit 1
fi

status "C/VMA GCP-analog benchmark completed successfully"
status "aggregate=${FINAL_AGGREGATE}"
