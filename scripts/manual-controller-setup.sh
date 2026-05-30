#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  manual-controller-setup.sh --key PATH --client-ip IP --receiver-ip IP [options]

Required:
  --key PATH             Private key on the controller used to SSH to benchmark nodes
  --client-ip IP         Benchmark client private IP
  --receiver-ip IP       Benchmark receiver private IP

Options:
  --failover-ip IP       Failover/backup node private IP for cluster benchmarks
  --user USER            SSH user on all nodes (default: ubuntu)
  --playbooks-zip PATH   Playbooks zip on controller (default: /tmp/aeron-manual/playbooks.zip)
  --modes LIST           Matrix modes (default: java,c,java_vma,c_vma)
  --rate RATE            Message rate for config/env (default: 1001000)
  --length BYTES         Message length (default: 288)
  --runs N               Manual config benchmark_echo_runs (default: 5)
  --iterations N         Manual config benchmark_echo_iterations (default: 30)
  --warmup N             Manual config benchmark_echo_warmup_iterations (default: 10)
  --warmup-rate RATE     Warmup rate label (default: 25K)
  --prefix N             Aeron UDP interface prefix length (default: 24)
  --no-cluster           Do not run cluster matrix
  --setup-only           Only run setup/provisioning; do not run benchmark matrix
  --smoke                Run smoke-sized matrix overrides (1/1/1)
  --help                 Show this help

Examples:
  ./manual-controller-setup.sh --key /opt/aeron/.ssh/deploy_key \
    --client-ip 10.0.1.10 --receiver-ip 10.0.1.11 --failover-ip 10.0.1.12

  ./manual-controller-setup.sh --key /home/ubuntu/aeron-priv-2-openssh \
    --client-ip 10.0.1.10 --receiver-ip 10.0.1.11 --setup-only
EOF
}

USER_NAME="ubuntu"
PLAYBOOKS_ZIP="/tmp/aeron-manual/playbooks.zip"
KEY_PATH=""
CLIENT_IP=""
RECEIVER_IP=""
FAILOVER_IP=""
MATRIX_MODES="java,c,java_vma,c_vma"
MESSAGE_RATE="1001000"
MESSAGE_LENGTH="288"
RUNS="5"
ITERATIONS="30"
WARMUP_ITERATIONS="10"
WARMUP_RATE="25K"
PREFIX_LENGTH="24"
RUN_CLUSTER="true"
SETUP_ONLY="false"
SMOKE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY_PATH="${2:-}"; shift 2 ;;
    --client-ip) CLIENT_IP="${2:-}"; shift 2 ;;
    --receiver-ip) RECEIVER_IP="${2:-}"; shift 2 ;;
    --failover-ip) FAILOVER_IP="${2:-}"; shift 2 ;;
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --playbooks-zip) PLAYBOOKS_ZIP="${2:-}"; shift 2 ;;
    --modes) MATRIX_MODES="${2:-}"; shift 2 ;;
    --rate) MESSAGE_RATE="${2:-}"; shift 2 ;;
    --length) MESSAGE_LENGTH="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --iterations) ITERATIONS="${2:-}"; shift 2 ;;
    --warmup) WARMUP_ITERATIONS="${2:-}"; shift 2 ;;
    --warmup-rate) WARMUP_RATE="${2:-}"; shift 2 ;;
    --prefix) PREFIX_LENGTH="${2:-}"; shift 2 ;;
    --no-cluster) RUN_CLUSTER="false"; shift ;;
    --setup-only) SETUP_ONLY="true"; shift ;;
    --smoke) SMOKE="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$KEY_PATH" || -z "$CLIENT_IP" || -z "$RECEIVER_IP" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Key not found on controller: $KEY_PATH" >&2
  exit 1
fi

if [[ ! -f "$PLAYBOOKS_ZIP" ]]; then
  echo "Playbooks zip not found on controller: $PLAYBOOKS_ZIP" >&2
  exit 1
fi

sudo mkdir -p /opt/aeron/.ssh /opt/aeron/playbooks /home/"$USER_NAME"/benchmark-results
sudo install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$KEY_PATH" /opt/aeron/.ssh/deploy_key
sudo chown -R "$USER_NAME:$USER_NAME" /opt/aeron /home/"$USER_NAME"/benchmark-results

if ! command -v unzip >/dev/null 2>&1 || ! command -v ansible-playbook >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/apt.conf.d
    printf '%s\n' 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y --fix-missing unzip ansible
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y unzip ansible-core
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y unzip ansible-core
  fi
fi

rm -rf /tmp/aeron-manual/playbooks
mkdir -p /tmp/aeron-manual/playbooks
unzip -q -o "$PLAYBOOKS_ZIP" -d /tmp/aeron-manual/playbooks
sudo rm -rf /opt/aeron/playbooks
sudo mv /tmp/aeron-manual/playbooks /opt/aeron/playbooks
sudo chown -R "$USER_NAME:$USER_NAME" /opt/aeron/playbooks

BENCHMARK_NODE_IPS="$CLIENT_IP,$RECEIVER_IP"
COMMON_EXTRA=(
  "hyperthreading=false"
  "java_version=17"
  "ssh_username=$USER_NAME"
  "run_benchmarks_matrix_modes=$MATRIX_MODES"
  "aeron_echo_udp_interface_prefix_length=$PREFIX_LENGTH"
  "aeron_benchmark_configure_host_firewall=true"
  "aeron_benchmark_host_firewall_persistent=true"
  "aeron_benchmark_host_udp_source_cidr="
  "client_node_ip=$CLIENT_IP"
  "receiver_node_ip=$RECEIVER_IP"
  "failover_node_ip=$FAILOVER_IP"
  "benchmark_node_ips=$BENCHMARK_NODE_IPS"
  "benchmark_echo_runs=$RUNS"
  "benchmark_echo_iterations=$ITERATIONS"
  "benchmark_echo_warmup_iterations=$WARMUP_ITERATIONS"
  "benchmark_echo_warmup_message_rate=$WARMUP_RATE"
  "message_length=$MESSAGE_LENGTH"
  "message_rate=$MESSAGE_RATE"
  "benchmark_build_native_aeronmd=true"
  "benchmark_ocpus=10"
  "benchmark_cluster_cpu_affinity=auto"
  "grub_dynamic_cpu_isolation=true"
  "grub_housekeeping_fraction=0.17"
  "grub_housekeeping_floor=2"
  "grub_housekeeping_cpus_max=8"
  "install_oci_cn_auth=false"
  "enable_rdma_compute_cluster=false"
  "benchmark_vma_apply_setcap=false"
  "benchmark_vma_lib_path=/usr/lib/x86_64-linux-gnu/libvma.so.9"
  "benchmark_install_vma_runtime=true"
  "benchmark_vma_build_from_source=true"
  "benchmark_vma_git_ref=master"
)

join_extra() {
  local role="$1"
  printf '%s ' "${COMMON_EXTRA[@]}" "node_role=$role"
}

run_local_playbook() {
  local role="$1"
  echo "==> Running local Ansible role=$role on $(hostname)"
  cd /opt/aeron/playbooks
  ansible-playbook -i 'localhost,' -c local site.yml -e "$(join_extra "$role")" -v
}

run_remote_node() {
  local ip="$1"
  local role="$2"
  [[ -z "$ip" ]] && return 0
  echo "==> Preparing node $role at $ip"
  scp -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$PLAYBOOKS_ZIP" "$USER_NAME@$ip:/tmp/playbooks.zip"
  ssh -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER_NAME@$ip" \
    "set -e
     if ! command -v unzip >/dev/null 2>&1 || ! command -v ansible-playbook >/dev/null 2>&1; then
       if command -v apt-get >/dev/null 2>&1; then
         sudo mkdir -p /etc/apt/apt.conf.d
         printf '%s\n' 'Acquire::ForceIPv4 \"true\";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null
         sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true update -y
         sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y --fix-missing unzip ansible
       elif command -v dnf >/dev/null 2>&1; then
         sudo dnf install -y unzip ansible-core
       elif command -v yum >/dev/null 2>&1; then
         sudo yum install -y unzip ansible-core
       fi
     fi
     rm -rf /tmp/playbooks /opt/aeron/playbooks
     mkdir -p /tmp/playbooks
     unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks
     sudo mkdir -p /opt/aeron
     sudo mv /tmp/playbooks /opt/aeron/playbooks
     sudo chown -R $USER_NAME:$USER_NAME /opt/aeron
     cd /opt/aeron/playbooks
     ansible-playbook -i 'localhost,' -c local site.yml -e '$(join_extra "$role")' -v"
}

run_local_playbook controller
run_remote_node "$CLIENT_IP" client
run_remote_node "$RECEIVER_IP" receiver
run_remote_node "$FAILOVER_IP" failover

if [[ "$SETUP_ONLY" == "true" ]]; then
  echo "Setup complete. Skipping benchmark matrix."
  exit 0
fi

RESULTS_ROOT="/home/$USER_NAME/benchmark-results"
RUN_ID="manual-$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$RESULTS_ROOT/$RUN_ID"
STATUS_FILE="$RESULTS_ROOT/STATUS-$RUN_ID.txt"
mkdir -p "$RESULTS_DIR"
echo "$RUN_ID" > "$RESULTS_ROOT/latest-manual-run.txt"

cd /opt/aeron/benchmarks-dist/scripts
chmod +x ./wrapper-echo-unified.sh ./wrapper-cluster-unified.sh ./aggregate-compare-results.sh ./run-driver-matrix.sh ./sanitize-benchmark-config-env.sh ./clear-benchmark-affinity-env.sh 2>/dev/null || true
sed -i 's/\r$//' ./clear-benchmark-affinity-env.sh ./config/clear-benchmark-affinity-env.sh ./run-driver-matrix.sh 2>/dev/null || true
./sanitize-benchmark-config-env.sh ./config/benchmark-config.env 2>/dev/null || true

export CONFIG_FILE="./config/benchmark-config.env"
export MATRIX_MODES="$MATRIX_MODES"
export SUMMARY_FILE="$RESULTS_DIR/driver-matrix-echo-summary.csv"
export BENCHMARK_QUIET_MODE=1

if [[ "$SMOKE" == "true" ]]; then
  export MATRIX_OVERRIDE_RUNS=1
  export MATRIX_OVERRIDE_ITERATIONS=1
  export MATRIX_OVERRIDE_WARMUP_ITERATIONS=1
else
  export MATRIX_OVERRIDE_RUNS="$RUNS"
  export MATRIX_OVERRIDE_ITERATIONS="$ITERATIONS"
  export MATRIX_OVERRIDE_WARMUP_ITERATIONS="$WARMUP_ITERATIONS"
  export MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE="$WARMUP_RATE"
  export MATRIX_OVERRIDE_MESSAGE_LENGTH="$MESSAGE_LENGTH"
  export MATRIX_OVERRIDE_MESSAGE_RATE="$MESSAGE_RATE"
  export MATRIX_OVERRIDE_BENCH_PROFILE="manual"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) manual echo matrix start" | tee -a "$STATUS_FILE"
./run-driver-matrix.sh echo 2>&1 | tee "$RESULTS_DIR/run-driver-matrix-echo.log"
cp -f ./aeron-echo-*.tar.gz "$RESULTS_DIR/" 2>/dev/null || true

if [[ "$RUN_CLUSTER" == "true" && -n "$FAILOVER_IP" ]]; then
  export SUMMARY_FILE="$RESULTS_DIR/driver-matrix-cluster-summary.csv"
  export MATRIX_STRICT=1
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) manual cluster matrix start" | tee -a "$STATUS_FILE"
  ./run-driver-matrix.sh cluster 2>&1 | tee "$RESULTS_DIR/run-driver-matrix-cluster.log"
  cp -f ./aeron-cluster-*.tar.gz "$RESULTS_DIR/" 2>/dev/null || true
else
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) manual cluster matrix skipped" | tee -a "$STATUS_FILE"
fi

cp -f "$RESULTS_DIR"/driver-matrix-*.csv "$RESULTS_ROOT/" 2>/dev/null || true
cp -f "$RESULTS_DIR"/run-driver-matrix-*.log "$RESULTS_ROOT/" 2>/dev/null || true
echo "Manual benchmark complete: $RESULTS_DIR"
