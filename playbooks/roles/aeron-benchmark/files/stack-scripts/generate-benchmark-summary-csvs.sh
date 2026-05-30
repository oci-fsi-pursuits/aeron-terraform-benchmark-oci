#!/usr/bin/env bash
# Merge one or more run-driver-matrix SUMMARY_FILE outputs into *-all.csv and *-best-of-all.csv.
# Env:
#   SUMMARY_FILES   — comma-separated basenames under BENCHMARK_RESULTS_DIR, or absolute paths
#   OUTPUT_PREFIX   — basename prefix for outputs (writes PREFIX-all.csv and PREFIX-best-of-all.csv)
#   BENCHMARK_RESULTS_DIR — default ~/benchmark-results
set -euo pipefail

: "${SUMMARY_FILES:?set SUMMARY_FILES (comma-separated summary paths or basenames)}"
: "${OUTPUT_PREFIX:?set OUTPUT_PREFIX}"

RES="${BENCHMARK_RESULTS_DIR:-${HOME}/benchmark-results}"
mkdir -p "${RES}"

paths=()
IFS=',' read -ra PARTS <<< "${SUMMARY_FILES}"
for raw in "${PARTS[@]}"; do
  f="$(echo "${raw}" | xargs)"
  [[ -z "${f}" ]] && continue
  if [[ "${f}" == /* ]]; then
    paths+=("${f}")
  else
    paths+=("${RES}/${f}")
  fi
done

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "generate-benchmark-summary-csvs: no paths after parsing SUMMARY_FILES=${SUMMARY_FILES}" >&2
  exit 1
fi

exec python3 /opt/aeron/scripts/consolidate-benchmark-histograms.py \
  --output-dir "${RES}" \
  --output-prefix "${OUTPUT_PREFIX}" \
  "${paths[@]}"
