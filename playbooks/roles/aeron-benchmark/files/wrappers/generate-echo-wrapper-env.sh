#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG_FILE="${CONFIG_FILE:-./config/benchmark-config.env}"
OUT_FILE=""
MODE="${MODE:-}"
RATE="${RATE:-}"
RUNS_VALUE="${RUNS_VALUE:-}"
ITERATIONS_VALUE="${ITERATIONS_VALUE:-}"
WARMUPS_VALUE="${WARMUPS_VALUE:-}"
MESSAGE_LENGTH_VALUE="${MESSAGE_LENGTH_VALUE:-}"
WARMUP_RATE_VALUE="${WARMUP_RATE_VALUE:-}"
CONTEXT_VALUE="${CONTEXT_VALUE:-}"
BENCH_PROFILE_VALUE="${BENCH_PROFILE_VALUE:-}"
MTU_VALUE_VALUE="${MTU_VALUE_VALUE:-}"
INTERFACE_MODE="${INTERFACE_MODE:-config}"
INTERFACE_PREFIX="${INTERFACE_PREFIX:-}"
NAMED_INTERFACE="${NAMED_INTERFACE:-}"
CLIENT_ENDPOINT_HOST="${CLIENT_ENDPOINT_HOST:-}"
SERVER_ENDPOINT_HOST="${SERVER_ENDPOINT_HOST:-}"
VMA_LIB_PATH="${VMA_LIB_PATH:-}"
VMA_AS_ROOT="${VMA_AS_ROOT:-0}"
SHOW_CONFIG_ONLY_VALUE="${SHOW_CONFIG_ONLY_VALUE:-}"

usage() {
  cat <<'EOF'
Usage:
  ./generate-echo-wrapper-env.sh [options]

Options:
  --config FILE             Source benchmark config first (default: ./config/benchmark-config.env)
  --output FILE             Write env exports to FILE instead of stdout
  --mode MODE               java | c | java_vma | c_vma (default: c)
  --rate RATE               101K, 1001K, etc. (default: 101K)
  --runs N                  RUNS value (default: 5)
  --iterations N            ITERATIONS value (default: 30)
  --warmups N               WARMUP_ITERATIONS value (default: 10)
  --message-length N        MESSAGE_LENGTH value (default: 288)
  --warmup-rate RATE        WARMUP_MESSAGE_RATE value (default: 25K)
  --context NAME            CONTEXT passed to wrapper (default: manual-env)
  --bench-profile NAME      BENCH_PROFILE passed to wrapper (default: custom)
  --mtu VALUE               MTU_VALUE passed to wrapper (default: 8K)
  --interface-mode MODE     config | omit | prefix | named (default: config)
                           omit   => no |interface= in echo channels
                           prefix => |interface=<node-ip>/<prefix>
                           named  => |interface={ifname}
  --prefix N                Prefix for --interface-mode prefix (default: 24)
  --named-interface NAME    Interface name for --interface-mode named, e.g. ens300f0np0 or {ens300f0np0}
  --client-endpoint-host H  Override Aeron client endpoint host, e.g. RDMA IP 192.168.0.234
  --server-endpoint-host H  Override Aeron server endpoint host, e.g. RDMA IP 192.168.0.253
  --vma-lib PATH            libvma path (default from ONLOAD_COMMAND_VMA or /usr/lib/x86_64-linux-gnu/libvma.so.9)
  --vma-as-root             Use sudo -E env LD_PRELOAD=... for VMA modes
  --show-config-only        Generate SHOW_CONFIG_ONLY=1
  -h, --help                Show this help

Examples:
  ./generate-echo-wrapper-env.sh --mode java --rate 101K --interface-mode omit --output /tmp/echo-java-101K.env
  source /tmp/echo-java-101K.env
  ./wrapper-echo-unified.sh

  ./generate-echo-wrapper-env.sh --mode c_vma --rate 1001K --interface-mode omit --vma-as-root
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --output) OUT_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --runs) RUNS_VALUE="$2"; shift 2 ;;
    --iterations) ITERATIONS_VALUE="$2"; shift 2 ;;
    --warmups|--warmup-iterations) WARMUPS_VALUE="$2"; shift 2 ;;
    --message-length) MESSAGE_LENGTH_VALUE="$2"; shift 2 ;;
    --warmup-rate) WARMUP_RATE_VALUE="$2"; shift 2 ;;
    --context) CONTEXT_VALUE="$2"; shift 2 ;;
    --bench-profile) BENCH_PROFILE_VALUE="$2"; shift 2 ;;
    --mtu) MTU_VALUE_VALUE="$2"; shift 2 ;;
    --interface-mode) INTERFACE_MODE="$2"; shift 2 ;;
    --prefix) INTERFACE_PREFIX="$2"; shift 2 ;;
    --named-interface) NAMED_INTERFACE="$2"; shift 2 ;;
    --client-endpoint-host|--client-endpoint) CLIENT_ENDPOINT_HOST="$2"; shift 2 ;;
    --server-endpoint-host|--server-endpoint) SERVER_ENDPOINT_HOST="$2"; shift 2 ;;
    --vma-lib) VMA_LIB_PATH="$2"; shift 2 ;;
    --vma-as-root) VMA_AS_ROOT=1; shift ;;
    --show-config-only) SHOW_CONFIG_ONLY_VALUE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

MODE="${MODE:-${CLIENT_MODE:-c}}"
RATE="${RATE:-${MESSAGE_RATE:-101K}}"
RUNS_VALUE="${RUNS_VALUE:-${RUNS:-5}}"
ITERATIONS_VALUE="${ITERATIONS_VALUE:-${ITERATIONS:-30}}"
WARMUPS_VALUE="${WARMUPS_VALUE:-${WARMUP_ITERATIONS:-10}}"
MESSAGE_LENGTH_VALUE="${MESSAGE_LENGTH_VALUE:-${MESSAGE_LENGTH:-288}}"
WARMUP_RATE_VALUE="${WARMUP_RATE_VALUE:-${WARMUP_MESSAGE_RATE:-25K}}"
CONTEXT_VALUE="${CONTEXT_VALUE:-${CONTEXT:-manual-env}}"
BENCH_PROFILE_VALUE="${BENCH_PROFILE_VALUE:-${BENCH_PROFILE:-custom}}"
MTU_VALUE_VALUE="${MTU_VALUE_VALUE:-${MTU_VALUE:-8K}}"
INTERFACE_PREFIX="${INTERFACE_PREFIX:-${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH:-24}}"
NAMED_INTERFACE="${NAMED_INTERFACE:-${AERON_ECHO_UDP_NAMED_INTERFACE:-}}"
SHOW_CONFIG_ONLY_VALUE="${SHOW_CONFIG_ONLY_VALUE:-${SHOW_CONFIG_ONLY:-0}}"

shell_quote() {
  printf '%q' "$1"
}

emit_export() {
  local key="$1"
  local value="${2:-}"
  printf 'export %s=%s\n' "$key" "$(shell_quote "$value")"
}

extract_ld_preload_path() {
  local s="${1:-}"
  if [[ "$s" =~ LD_PRELOAD=([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

normalize_named_interface() {
  local name="$1"
  [[ -z "$name" ]] && return 0
  if [[ "$name" == \{*\} ]]; then
    printf '%s' "$name"
  else
    printf '{%s}' "$name"
  fi
}

strip_interface_param() {
  local channel="$1"
  printf '%s' "$channel" | sed -E 's/\|interface=[^|]+//g'
}

replace_interface_param() {
  local channel="$1"
  local interface_value="$2"
  printf '%s|interface=%s' "$(strip_interface_param "$channel")" "$interface_value"
}

replace_endpoint_host() {
  local channel="$1"
  local host="$2"
  if [[ -z "$host" ]]; then
    printf '%s' "$channel"
    return
  fi
  printf '%s' "$channel" | sed -E "s#(endpoint=)[^:|]+(:[0-9]+)#\\1${host}\\2#"
}

extract_interface_host() {
  local channel="$1"
  local interface_value
  interface_value="$(printf '%s' "$channel" | sed -nE 's/.*\|interface=([^|]+).*/\1/p')"
  interface_value="${interface_value#\{}"
  interface_value="${interface_value%\}}"
  interface_value="${interface_value%%/*}"
  interface_value="${interface_value%%:*}"
  printf '%s' "$interface_value"
}

resolve_host_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1; exit}'
}

case "$MODE" in
  java|c|java_vma|c_vma|java-onload|c-onload) ;;
  *) echo "Unsupported mode: $MODE" >&2; exit 2 ;;
esac

case "$INTERFACE_MODE" in
  config|omit|prefix|named) ;;
  *) echo "Unsupported interface mode: $INTERFACE_MODE" >&2; exit 2 ;;
esac

SSH_USER_VALUE="${SSH_USER:-ubuntu}"
SSH_KEY_FILE_VALUE="${SSH_KEY_FILE:-/opt/aeron/.ssh/deploy_key}"
CLIENT_NODE="${SSH_CLIENT_NODE:-aeron-benchmark-client}"
SERVER_NODE="${SSH_SERVER_NODE:-aeron-benchmark-receiver}"
CLIENT_BENCHMARKS_PATH_VALUE="${CLIENT_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
SERVER_BENCHMARKS_PATH_VALUE="${SERVER_BENCHMARKS_PATH:-/home/ubuntu/benchmarks-dist}"
CLIENT_JAVA_HOME_VALUE="${CLIENT_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
SERVER_JAVA_HOME_VALUE="${SERVER_JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
JVM_OPTS_VALUE="${JVM_OPTS:---add-opens java.base/jdk.internal.misc=ALL-UNNAMED --add-opens java.base/sun.nio.ch=ALL-UNNAMED}"

case "$MODE" in
  java|java_vma|java-onload) CLIENT_MODE_VALUE="$MODE"; SERVER_MODE_VALUE="$MODE" ;;
  c|c_vma|c-onload) CLIENT_MODE_VALUE="$MODE"; SERVER_MODE_VALUE="$MODE" ;;
esac

if [[ -z "$VMA_LIB_PATH" ]]; then
  VMA_LIB_PATH="$(extract_ld_preload_path "${ONLOAD_COMMAND_VMA:-}")"
fi
VMA_LIB_PATH="${VMA_LIB_PATH:-/usr/lib/x86_64-linux-gnu/libvma.so.9}"

ONLOAD_COMMAND_PLAIN_VALUE="${ONLOAD_COMMAND_PLAIN:-env}"
if [[ "$VMA_AS_ROOT" == "1" ]]; then
  ONLOAD_COMMAND_VMA_VALUE="sudo -E env LD_PRELOAD=${VMA_LIB_PATH}"
else
  ONLOAD_COMMAND_VMA_VALUE="env LD_PRELOAD=${VMA_LIB_PATH}"
fi

case "$MODE" in
  *vma*|*-onload) ONLOAD_COMMAND_VALUE="$ONLOAD_COMMAND_VMA_VALUE" ;;
  *) ONLOAD_COMMAND_VALUE="$ONLOAD_COMMAND_PLAIN_VALUE" ;;
esac

CLIENT_SOURCE_VALUE="${CLIENT_SOURCE_CHANNEL:-aeron:udp?endpoint=${CLIENT_NODE}:13100}"
CLIENT_DEST_VALUE="${CLIENT_DESTINATION_CHANNEL:-aeron:udp?endpoint=${SERVER_NODE}:13000}"
SERVER_SOURCE_VALUE="${SERVER_SOURCE_CHANNEL:-aeron:udp?endpoint=${CLIENT_NODE}:13100}"
SERVER_DEST_VALUE="${SERVER_DESTINATION_CHANNEL:-aeron:udp?endpoint=${SERVER_NODE}:13000}"
CLIENT_SOURCE_VALUE="$(replace_endpoint_host "$CLIENT_SOURCE_VALUE" "$CLIENT_ENDPOINT_HOST")"
SERVER_SOURCE_VALUE="$(replace_endpoint_host "$SERVER_SOURCE_VALUE" "$CLIENT_ENDPOINT_HOST")"
CLIENT_DEST_VALUE="$(replace_endpoint_host "$CLIENT_DEST_VALUE" "$SERVER_ENDPOINT_HOST")"
SERVER_DEST_VALUE="$(replace_endpoint_host "$SERVER_DEST_VALUE" "$SERVER_ENDPOINT_HOST")"
NAMED_INTERFACE_VALUE="${AERON_ECHO_UDP_NAMED_INTERFACE:-}"
PREFIX_VALUE="${AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH:-}"
CLIENT_INTERFACE_HOST="$(extract_interface_host "$CLIENT_SOURCE_VALUE")"
SERVER_INTERFACE_HOST="$(extract_interface_host "$SERVER_SOURCE_VALUE")"
CLIENT_INTERFACE_HOST="${CLIENT_INTERFACE_HOST:-$(resolve_host_ipv4 "$CLIENT_NODE")}"
SERVER_INTERFACE_HOST="${SERVER_INTERFACE_HOST:-$(resolve_host_ipv4 "$SERVER_NODE")}"
CLIENT_INTERFACE_HOST="${CLIENT_INTERFACE_HOST:-$CLIENT_NODE}"
SERVER_INTERFACE_HOST="${SERVER_INTERFACE_HOST:-$SERVER_NODE}"
AERON_DIR_VALUE="${AERON_DIR:-/home/${SSH_USER_VALUE}/aeron-benchmark-shm}"
AERON_TERM_BUFFER_SPARSE_FILE_VALUE="${AERON_TERM_BUFFER_SPARSE_FILE:-false}"
AERON_PRE_TOUCH_MAPPED_MEMORY_VALUE="${AERON_PRE_TOUCH_MAPPED_MEMORY:-true}"
AERON_SOCKET_SO_SNDBUF_VALUE="${AERON_SOCKET_SO_SNDBUF:-2m}"
AERON_SOCKET_SO_RCVBUF_VALUE="${AERON_SOCKET_SO_RCVBUF:-2m}"
AERON_RCV_INITIAL_WINDOW_LENGTH_VALUE="${AERON_RCV_INITIAL_WINDOW_LENGTH:-2m}"
AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND_VALUE="${AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND:-1}"
AERON_RECEIVER_IO_VECTOR_CAPACITY_VALUE="${AERON_RECEIVER_IO_VECTOR_CAPACITY:-1}"
AERON_SENDER_IO_VECTOR_CAPACITY_VALUE="${AERON_SENDER_IO_VECTOR_CAPACITY:-1}"
CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS_VALUE="${CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS:-}"
CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS_VALUE="${CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS:-}"
SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS_VALUE="${SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS:-}"
SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS_VALUE="${SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS:-}"

if [[ "$INTERFACE_MODE" == "omit" ]]; then
  NAMED_INTERFACE_VALUE=""
  PREFIX_VALUE=""
  CLIENT_SOURCE_VALUE="$(strip_interface_param "$CLIENT_SOURCE_VALUE")"
  CLIENT_DEST_VALUE="$(strip_interface_param "$CLIENT_DEST_VALUE")"
  SERVER_SOURCE_VALUE="$(strip_interface_param "$SERVER_SOURCE_VALUE")"
  SERVER_DEST_VALUE="$(strip_interface_param "$SERVER_DEST_VALUE")"
elif [[ "$INTERFACE_MODE" == "prefix" ]]; then
  NAMED_INTERFACE_VALUE=""
  PREFIX_VALUE="$INTERFACE_PREFIX"
  CLIENT_SOURCE_VALUE="$(replace_interface_param "$CLIENT_SOURCE_VALUE" "${CLIENT_INTERFACE_HOST}/${PREFIX_VALUE}")"
  CLIENT_DEST_VALUE="$(replace_interface_param "$CLIENT_DEST_VALUE" "${CLIENT_INTERFACE_HOST}/${PREFIX_VALUE}")"
  SERVER_SOURCE_VALUE="$(replace_interface_param "$SERVER_SOURCE_VALUE" "${SERVER_INTERFACE_HOST}/${PREFIX_VALUE}")"
  SERVER_DEST_VALUE="$(replace_interface_param "$SERVER_DEST_VALUE" "${SERVER_INTERFACE_HOST}/${PREFIX_VALUE}")"
elif [[ "$INTERFACE_MODE" == "named" ]]; then
  NAMED_INTERFACE_VALUE="$(normalize_named_interface "$NAMED_INTERFACE")"
  if [[ -z "$NAMED_INTERFACE_VALUE" ]]; then
    echo "--named-interface is required when --interface-mode named" >&2
    exit 2
  fi
  PREFIX_VALUE=""
  CLIENT_SOURCE_VALUE="$(replace_interface_param "$CLIENT_SOURCE_VALUE" "$NAMED_INTERFACE_VALUE")"
  CLIENT_DEST_VALUE="$(replace_interface_param "$CLIENT_DEST_VALUE" "$NAMED_INTERFACE_VALUE")"
  SERVER_SOURCE_VALUE="$(replace_interface_param "$SERVER_SOURCE_VALUE" "$NAMED_INTERFACE_VALUE")"
  SERVER_DEST_VALUE="$(replace_interface_param "$SERVER_DEST_VALUE" "$NAMED_INTERFACE_VALUE")"
fi

render() {
  cat <<EOF
# Generated by generate-echo-wrapper-env.sh
# Usage:
#   source this-file.env
#   ./wrapper-echo-unified.sh
#
# To inspect wrapper-resolved CPU pins without running:
#   SHOW_CONFIG_ONLY=1 ./wrapper-echo-unified.sh
#
# Interface mode: ${INTERFACE_MODE}
# endpoint= is the remote Aeron host:port from benchmark-config.env.
# interface= is the local NIC selector; omit mode leaves routing/VMA to choose the RDMA netdev.
EOF

  emit_export CONFIG_FILE "$CONFIG_FILE"
  emit_export SSH_USER "$SSH_USER_VALUE"
  emit_export SSH_KEY_FILE "$SSH_KEY_FILE_VALUE"
  emit_export SSH_CLIENT_NODE "$CLIENT_NODE"
  emit_export SSH_SERVER_NODE "$SERVER_NODE"
  emit_export CLIENT_BENCHMARKS_PATH "$CLIENT_BENCHMARKS_PATH_VALUE"
  emit_export SERVER_BENCHMARKS_PATH "$SERVER_BENCHMARKS_PATH_VALUE"
  emit_export CLIENT_JAVA_HOME "$CLIENT_JAVA_HOME_VALUE"
  emit_export SERVER_JAVA_HOME "$SERVER_JAVA_HOME_VALUE"
  emit_export JVM_OPTS "$JVM_OPTS_VALUE"

  emit_export CLIENT_MODE "$CLIENT_MODE_VALUE"
  emit_export SERVER_MODE "$SERVER_MODE_VALUE"
  emit_export BENCH_PROFILE "$BENCH_PROFILE_VALUE"
  emit_export CONTEXT "$CONTEXT_VALUE"
  emit_export MTU_VALUE "$MTU_VALUE_VALUE"

  emit_export RUNS "$RUNS_VALUE"
  emit_export ITERATIONS "$ITERATIONS_VALUE"
  emit_export WARMUP_ITERATIONS "$WARMUPS_VALUE"
  emit_export MESSAGE_RATE "$RATE"
  emit_export MESSAGE_LENGTH "$MESSAGE_LENGTH_VALUE"
  emit_export WARMUP_MESSAGE_RATE "$WARMUP_RATE_VALUE"

  emit_export ONLOAD_COMMAND_PLAIN "$ONLOAD_COMMAND_PLAIN_VALUE"
  emit_export ONLOAD_COMMAND_VMA "$ONLOAD_COMMAND_VMA_VALUE"
  emit_export ONLOAD_COMMAND "$ONLOAD_COMMAND_VALUE"
  emit_export VMA_LIB_PATH "$VMA_LIB_PATH"

  emit_export AERON_ECHO_UDP_NAMED_INTERFACE "$NAMED_INTERFACE_VALUE"
  emit_export AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH "$PREFIX_VALUE"
  emit_export CLIENT_SOURCE_CHANNEL "$CLIENT_SOURCE_VALUE"
  emit_export CLIENT_DESTINATION_CHANNEL "$CLIENT_DEST_VALUE"
  emit_export SERVER_SOURCE_CHANNEL "$SERVER_SOURCE_VALUE"
  emit_export SERVER_DESTINATION_CHANNEL "$SERVER_DEST_VALUE"

  emit_export AERON_DIR "$AERON_DIR_VALUE"
  emit_export AERON_TERM_BUFFER_SPARSE_FILE "$AERON_TERM_BUFFER_SPARSE_FILE_VALUE"
  emit_export AERON_PRE_TOUCH_MAPPED_MEMORY "$AERON_PRE_TOUCH_MAPPED_MEMORY_VALUE"
  emit_export AERON_SOCKET_SO_SNDBUF "$AERON_SOCKET_SO_SNDBUF_VALUE"
  emit_export AERON_SOCKET_SO_RCVBUF "$AERON_SOCKET_SO_RCVBUF_VALUE"
  emit_export AERON_RCV_INITIAL_WINDOW_LENGTH "$AERON_RCV_INITIAL_WINDOW_LENGTH_VALUE"
  emit_export AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND "$AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND_VALUE"
  emit_export AERON_RECEIVER_IO_VECTOR_CAPACITY "$AERON_RECEIVER_IO_VECTOR_CAPACITY_VALUE"
  emit_export AERON_SENDER_IO_VECTOR_CAPACITY "$AERON_SENDER_IO_VECTOR_CAPACITY_VALUE"
  emit_export CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS "$CLIENT_AERON_DPDK_GATEWAY_IPV4_ADDRESS_VALUE"
  emit_export CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS "$CLIENT_AERON_DPDK_LOCAL_IPV4_ADDRESS_VALUE"
  emit_export SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS "$SERVER_AERON_DPDK_GATEWAY_IPV4_ADDRESS_VALUE"
  emit_export SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS "$SERVER_AERON_DPDK_LOCAL_IPV4_ADDRESS_VALUE"

  emit_export SHOW_CONFIG_ONLY "$SHOW_CONFIG_ONLY_VALUE"
}

if [[ -n "$OUT_FILE" ]]; then
  render > "$OUT_FILE"
  echo "Wrote $OUT_FILE"
else
  render
fi
