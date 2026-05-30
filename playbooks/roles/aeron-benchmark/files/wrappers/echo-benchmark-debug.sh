#!/usr/bin/env bash
# Run on the controller from benchmarks-dist/scripts (or pass path to benchmark-config.env).
# Collects facts for echo timeouts: interfaces, sourced channels, SSH to client/server, SHOW_CONFIG_ONLY.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

CONFIG_FILE="${1:-./config/benchmark-config.env}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Usage: $0 [path/to/benchmark-config.env]" >&2
  echo "Missing: ${CONFIG_FILE}" >&2
  exit 1
fi

echo "==================== echo-benchmark-debug ===================="
echo "config: ${CONFIG_FILE}"
echo "cwd: ${SCRIPT_DIR}"
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

_clear="$(dirname "${CONFIG_FILE}")/clear-benchmark-affinity-env.sh"
if [[ -f "${_clear}" ]]; then
  # shellcheck source=/dev/null
  source "${_clear}"
elif [[ -f "${SCRIPT_DIR}/clear-benchmark-affinity-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/clear-benchmark-affinity-env.sh"
fi

set -a
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
set +a

echo "--- Controller (this host) ---"
hostname || true
ip -br a 2>/dev/null || true
echo "--- routes ---"
ip route 2>/dev/null | head -20 || true
echo

echo "--- Env: SSH + echo channels (sorted) ---"
env | grep -E '^(SSH_|CLIENT_[A-Z_]*CHANNEL|SERVER_[A-Z_]*CHANNEL|AERON_ECHO|ONLOAD_COMMAND|CLIENT_BENCHMARKS|SERVER_BENCHMARKS|JVM_OPTS)=' | sort || true
echo

KEY="${SSH_KEY_FILE:-}"
USER_NAME="${SSH_USER:-ubuntu}"
if [[ -z "${KEY}" || ! -f "${KEY}" ]]; then
  echo "WARN: SSH_KEY_FILE missing or not a file; skipping remote checks" >&2
else
  echo "--- Remote: client ${SSH_CLIENT_NODE:-?} ---"
  ssh -i "${KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${USER_NAME}@${SSH_CLIENT_NODE}" 'hostname; ip -br a; ss -Huln | grep -E ":(13000|13100)\b" || true; ls -la /dev/shm/aeron 2>&1 || true' \
    && echo "client SSH: OK" || echo "client SSH: FAIL"
  echo
  echo "--- Remote: server ${SSH_SERVER_NODE:-?} ---"
  ssh -i "${KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${USER_NAME}@${SSH_SERVER_NODE}" 'hostname; ip -br a; ss -Huln | grep -E ":(13000|13100)\b" || true; ls -la /dev/shm/aeron 2>&1 || true' \
    && echo "server SSH: OK" || echo "server SSH: FAIL"
fi
echo

echo "--- Subprocess: SHOW_CONFIG_ONLY + smoke profile (no benchmark run) ---"
if [[ -f ./wrapper-echo-unified.sh ]]; then
  BENCH_PROFILE="${BENCH_PROFILE:-smoke_288_101k}" SHOW_CONFIG_ONLY=1 bash ./wrapper-echo-unified.sh
else
  echo "wrapper-echo-unified.sh not in ${SCRIPT_DIR}" >&2
fi
echo

echo "--- Next steps if UDP/Aeron still times out ---"
echo "1) On client/server confirm NIC name matches AERON_ECHO_UDP_NAMED_INTERFACE (e.g. ens3 not eth0)."
echo "2) Try prefix mode: unset AERON_ECHO_UDP_NAMED_INTERFACE; export AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=16"
echo "3) OCI: private subnet security list + NSG must allow benchmark UDP (echo ~12k-14k, cluster ~20k+, ephemeral; stack uses 12000-65535 on NSG)."
echo "4) Full trace: WRAPPER_DEBUG=1 BENCH_PROFILE=smoke_288_101k ./wrapper-echo-unified.sh 2>&1 | tee /tmp/echo-trace.log"
echo "================================================================"
