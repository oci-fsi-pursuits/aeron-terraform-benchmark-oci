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

RESULTS_ROOT="${RESULTS_ROOT:-${HOME}/benchmark-results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-echo-non-vma-full}"
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/runs/${RUN_ID}}"
STATUS_FILE="${STATUS_FILE:-${RUN_DIR}/STATUS.txt}"
RUN_INDEX="${RUN_INDEX:-${RUN_DIR}/run-index.csv}"
FINAL_AGGREGATE="${FINAL_AGGREGATE:-${RUN_DIR}/echo-full-non-vma-aggregate.csv}"

FULL_BENCH_RATES="${FULL_BENCH_RATES:-101K,1001K}"
FULL_BENCH_MODES="${FULL_BENCH_MODES:-java,c}"
FULL_BENCH_RUNS="${FULL_BENCH_RUNS:-${RUNS:-5}}"
FULL_BENCH_ITERATIONS="${FULL_BENCH_ITERATIONS:-${ITERATIONS:-30}}"
FULL_BENCH_WARMUP_ITERATIONS="${FULL_BENCH_WARMUP_ITERATIONS:-${WARMUP_ITERATIONS:-10}}"
FULL_BENCH_MESSAGE_LENGTH="${FULL_BENCH_MESSAGE_LENGTH:-${MESSAGE_LENGTH:-288}}"
FULL_BENCH_WARMUP_RATE="${FULL_BENCH_WARMUP_RATE:-${WARMUP_MESSAGE_RATE:-25K}}"
FULL_BENCH_STRICT="${FULL_BENCH_STRICT:-0}"
FULL_BENCH_MODE_TIMEOUT_SEC="${FULL_BENCH_MODE_TIMEOUT_SEC:-1800}"

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
  ls -1t ./aeron-echo-*-client.tar.gz 2>/dev/null | head -n 1 || true
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

status "non-VMA full echo benchmark started: ${RUN_DIR}"
status "rates=${FULL_BENCH_RATES} modes=${FULL_BENCH_MODES} runs=${FULL_BENCH_RUNS} iterations=${FULL_BENCH_ITERATIONS}"

if [[ "${NON_VMA_DISABLE_VMA_STATE:-1}" == "1" ]]; then
  status "disabling VMA benchmark state on nodes before non-VMA run"
  VMA_REQUIRE_RDMA=0 bash ./enable-vma-on-nodes.sh disable "${CONFIG_FILE}" \
    > "${RUN_DIR}/disable-vma-state.log" 2>&1 || {
      status "WARNING: disable-vma-state failed; see ${RUN_DIR}/disable-vma-state.log"
    }
fi

unset LD_PRELOAD || true
export ONLOAD_COMMAND_PLAIN="env"
export ONLOAD_COMMAND="env"
export ONLOAD_COMMAND_VMA="env"

for rate_raw in "${rates[@]}"; do
  rate="$(echo "${rate_raw}" | xargs)"
  [[ -z "${rate}" ]] && continue
  for mode_raw in "${modes[@]}"; do
    mode="$(echo "${mode_raw}" | xargs)"
    [[ -z "${mode}" ]] && continue
    case "${mode}" in
      java|c) ;;
      *)
        status "skipping unsupported non-VMA mode=${mode}"
        continue
        ;;
    esac

    log="${RUN_DIR}/echo-${mode}-${rate}.log"
    summary="${RUN_DIR}/driver-matrix-echo-${mode}-${rate}.csv"
    status "running non-VMA echo mode=${mode} rate=${rate}"

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
      ONLOAD_COMMAND="env" \
      ONLOAD_COMMAND_VMA="env" \
      STATUS_FILE="${STATUS_FILE}" \
      SUMMARY_FILE="${summary}" \
      ./run-driver-matrix.sh echo > "${log}" 2>&1; then
      run_status="ok"
    else
      rc=$?
      run_status="failed:${rc}"
      run_failures=$((run_failures + 1))
      status "mode=${mode} rate=${rate} failed rc=${rc}; see ${log}"
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
      status "captured archive mode=${mode} rate=${rate}: ${copied}"
    else
      printf '%s,%s,%s,,%s,%s\n' "${rate}" "${mode}" "${run_status}:no-archive" "${summary}" "${log}" >> "${RUN_INDEX}"
      status "WARNING: no client archive found for mode=${mode} rate=${rate}"
    fi
  done
done

if [[ "${#archives[@]}" -gt 0 ]]; then
  status "aggregating ${#archives[@]} non-VMA archive(s)"
  bash ./aggregate-compare-results.sh "${archives[@]}" | tee "${FINAL_AGGREGATE}"
else
  status "ERROR: no archives captured; aggregate not produced"
  exit 1
fi

if [[ "${run_failures}" -gt 0 ]]; then
  status "non-VMA full echo benchmark completed with ${run_failures} failed run(s)"
  exit 1
fi

status "non-VMA full echo benchmark completed successfully"
status "aggregate=${FINAL_AGGREGATE}"
