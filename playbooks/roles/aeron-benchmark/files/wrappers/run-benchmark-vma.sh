#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f ./benchmark-preloaded.env ]]; then
  # shellcheck source=/dev/null
  source ./benchmark-preloaded.env
fi

TARGET="${1:-${AERON_BENCHMARK_TARGET:-echo}}"
MODES="${AERON_VMA_MODES:-java_vma,c_vma}"
ONLOAD_COMMAND_VALUE="${AERON_VMA_ONLOAD_COMMAND:-sudo -E env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libvma.so.9}"

if [[ -z "${MODES// /}" ]]; then
  echo "run-benchmark-vma: AERON_VMA_MODES is empty" >&2
  exit 2
fi

echo "=== VMA Aeron benchmark ==="
echo "target=${TARGET} modes=${MODES} rate=${AERON_BENCHMARK_RATE:-101K}"
echo "onload=${ONLOAD_COMMAND_VALUE}"

exec ./preload-benchmark-env.sh \
  --run "${TARGET}" \
  --modes "${MODES}" \
  --rate "${AERON_BENCHMARK_RATE:-101K}" \
  --length "${AERON_BENCHMARK_LENGTH:-288}" \
  --runs "${AERON_BENCHMARK_RUNS:-1}" \
  --iterations "${AERON_BENCHMARK_ITERATIONS:-3}" \
  --warmup "${AERON_BENCHMARK_WARMUP:-3}" \
  --timeout "${AERON_BENCHMARK_TIMEOUT_SEC:-1800}" \
  --strict "${AERON_BENCHMARK_STRICT:-0}" \
  --expected-vcpus "${AERON_EXPECTED_VCPUS:-32}" \
  --expected-isolated "${AERON_EXPECTED_ISOLATED_CPUS:-6-31}" \
  --affinity-range "${AERON_AFFINITY_RANGE:-6-31}" \
  --onload-vma "${ONLOAD_COMMAND_VALUE}" \
  --results-root "${AERON_RESULTS_ROOT:-/home/ubuntu/benchmark-results/runs}"
