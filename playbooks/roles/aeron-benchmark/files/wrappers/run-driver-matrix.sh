#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Runs echo or cluster across driver modes and compares results.
# Usage:
#   ./run-driver-matrix.sh [echo|cluster]
# Env:
#   MATRIX_MODES="java,c,java_vma,c_vma"
#   CONFIG_FILE="./config/benchmark-config.env"
#   MATRIX_STRICT=1 (default) — exit 1 if any mode fails or logs contain timeout/exception signatures (Terraform apply fails).
#   MATRIX_STRICT=0 — run all modes and compare partial archives even when some modes failed (legacy).

TARGET="${1:-echo}"
MATRIX_MODES="${MATRIX_MODES:-java,java_vma,c,c_vma}"
CONFIG_FILE="${CONFIG_FILE:-./config/benchmark-config.env}"
STATUS_FILE="${STATUS_FILE:-}"
SUMMARY_FILE="${SUMMARY_FILE:-./driver-matrix-summary.csv}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# Export all config values so wrappers can consume them.
set -a
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
set +a

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

# If 1 (default), exit 1 when any mode fails or logs match fatal signatures (so Terraform apply fails loudly).
MATRIX_STRICT="${MATRIX_STRICT:-1}"
# Per-mode wall-clock cap so Terraform SSH does not hang until connection timeout (coreutils `timeout`, exit 124).
MATRIX_MODE_TIMEOUT_SEC="${MATRIX_MODE_TIMEOUT_SEC:-900}"

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
matrix_echo_cleanup_remotes() {
  [[ "${TARGET}" == "echo" ]] || return 0
  local key="${SSH_KEY_FILE:-/opt/aeron/.ssh/deploy_key}"
  local user="${SSH_USER:-ubuntu}"
  local h
  for h in "${SSH_CLIENT_NODE:-}" "${SSH_SERVER_NODE:-}"; do
    [[ -z "${h}" ]] && continue
    [[ ! -f "${key}" ]] && continue
    ssh -i "${key}" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      "${user}@${h}" \
      "sudo pkill -f io.aeron.driver.MediaDriver 2>/dev/null || true; sudo pkill -f io.aeron.benchmarks.LoadTestRig 2>/dev/null || true; sudo pkill -f aeronmd 2>/dev/null || true; sleep 3; sudo rm -rf /dev/shm/aeron /home/${user}/aeron-benchmark-shm" \
      || true
  done
}

for mode in "${modes[@]}"; do
  mode="$(echo "${mode}" | xargs)"
  context="${TARGET}-matrix-${mode}"
  log="/tmp/${context}.log"
  status "=== Running ${TARGET} mode=${mode} context=${context} ==="

  if [[ "${TARGET}" == "echo" ]]; then
    matrix_echo_cleanup_remotes
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
  else
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
  fi

  test_dir="$(sed -n 's/.*test_dir=\(aeron-[0-9A-Za-z-]*\).*/\1/p' "${log}" | head -n 1 | tr -d '\r' || true)"
  if [[ -n "${test_dir}" ]]; then
    client_tar="./${test_dir}-client.tar.gz"
    if [[ -f "${client_tar}" ]]; then
      archives+=("${client_tar}")
    fi
  fi

  if [[ "${#archives[@]}" -eq 0 ]]; then
    latest_client="$(ls -1t ./aeron-${TARGET}-*-client.tar.gz 2>/dev/null | head -n 1 || true)"
    if [[ -n "${latest_client}" && -f "${latest_client}" ]]; then
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
