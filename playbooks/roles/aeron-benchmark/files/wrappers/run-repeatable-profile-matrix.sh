#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")" || exit 1

STAMP="${AERON_PROFILE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
ROOT="${AERON_PROFILE_ROOT:-/home/ubuntu/benchmark-results/profile-matrix-${STAMP}}"
REPEATS="${AERON_PROFILE_REPEATS:-3}"
TARGETS="${AERON_PROFILE_TARGETS-echo,cluster}"
RATES="${AERON_PROFILE_RATES-101K,1001000}"
NONVMA_MODES="${AERON_PROFILE_NONVMA_MODES-java,c}"
VMA_MODES="${AERON_PROFILE_VMA_MODES-java_vma,c_vma}"

mkdir -p "${ROOT}/logs" "${ROOT}/runs"
MASTER_LOG="${ROOT}/profile-matrix.log"
exec > >(tee -a "${MASTER_LOG}") 2>&1

echo "profile_matrix_root=${ROOT}"
echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "repeats=${REPEATS}"
echo "targets=${TARGETS}"
echo "rates=${RATES}"
echo "procedure=one driver mode per wrapper invocation, aggressive cleanup before and after each mode"

COMMON_ARGS=(
  --length "${AERON_PROFILE_LENGTH:-288}"
  --runs "${AERON_PROFILE_RUNS:-1}"
  --iterations "${AERON_PROFILE_ITERATIONS:-3}"
  --warmup "${AERON_PROFILE_WARMUP:-3}"
  --strict "${AERON_PROFILE_STRICT:-0}"
  --expected-vcpus "${AERON_PROFILE_EXPECTED_VCPUS:-32}"
  --expected-isolated "${AERON_PROFILE_EXPECTED_ISOLATED:-6-31}"
  --affinity-range "${AERON_PROFILE_AFFINITY_RANGE:-6-31}"
  --results-root "${ROOT}/runs"
)

case_rcs=()

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

record_rcs() {
  {
    echo "phase,target,mode,rate,repeat,rc,log"
    printf '%s\n' "${case_rcs[@]}"
  } > "${ROOT}/CASE-RCS.csv"
}

collect_aggregates() {
  local out="${ROOT}/ALL-AGGREGATES.txt"
  {
    echo "profile_matrix_root=${ROOT}"
    echo "collected_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    find "${ROOT}/runs" -type f -name 'driver-matrix-*-preloaded.csv' | sort | while IFS= read -r f; do
      echo "===== ${f} ====="
      cat "${f}"
      echo
    done
  } > "${out}"
  echo "aggregate_output=${out}"
}

run_profile() {
  local phase="$1" target="$2" mode="$3" rate="$4" rep="$5"
  local run_id log rc
  run_id="${STAMP}-${phase}-${target}-$(safe_name "${rate}")-$(safe_name "${mode}")-r${rep}"
  log="${ROOT}/logs/${run_id}.log"

  echo
  echo "===== CASE START phase=${phase} target=${target} mode=${mode} rate=${rate} repeat=${rep} run_id=${run_id} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  AERON_RUN_ID="${run_id}" \
  MATRIX_CLEANUP_AGGRESSIVE="${MATRIX_CLEANUP_AGGRESSIVE:-1}" \
  MATRIX_CLEANUP_COOLDOWN_SEC="${MATRIX_CLEANUP_COOLDOWN_SEC:-10}" \
  MATRIX_CLEANUP_VERIFY_SEC="${MATRIX_CLEANUP_VERIFY_SEC:-20}" \
  BENCHMARK_QUIET_MODE="${BENCHMARK_QUIET_MODE:-1}" \
  BENCHMARK_QUIET_RESTORE="${BENCHMARK_QUIET_RESTORE:-0}" \
  BENCHMARK_DEEP_QUIET="${BENCHMARK_DEEP_QUIET:-1}" \
  ./preload-benchmark-env.sh \
    --run "${target}" \
    --modes "${mode}" \
    --rate "${rate}" \
    "${COMMON_ARGS[@]}" 2>&1 | tee "${log}"
  rc="${PIPESTATUS[0]}"
  echo "===== CASE END phase=${phase} target=${target} mode=${mode} rate=${rate} repeat=${rep} rc=${rc} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) log=${log} ====="
  case_rcs+=("${phase},${target},${mode},${rate},${rep},${rc},${log}")
  record_rcs
  collect_aggregates
  return 0
}

IFS=',' read -r -a target_list <<< "${TARGETS}"
IFS=',' read -r -a rate_list <<< "${RATES}"
IFS=',' read -r -a nonvma_list <<< "${NONVMA_MODES}"
IFS=',' read -r -a vma_list <<< "${VMA_MODES}"

for rep in $(seq 1 "${REPEATS}"); do
  for rate in "${rate_list[@]}"; do
    rate="$(echo "${rate}" | xargs)"
    for target in "${target_list[@]}"; do
      target="$(echo "${target}" | xargs)"
      for mode in "${nonvma_list[@]}"; do
        mode="$(echo "${mode}" | xargs)"
        [[ -n "${mode}" ]] || continue
        run_profile nonvma "${target}" "${mode}" "${rate}" "${rep}"
      done
      for mode in "${vma_list[@]}"; do
        mode="$(echo "${mode}" | xargs)"
        [[ -n "${mode}" ]] || continue
        run_profile vma "${target}" "${mode}" "${rate}" "${rep}"
      done
    done
  done
done

record_rcs
collect_aggregates
echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
