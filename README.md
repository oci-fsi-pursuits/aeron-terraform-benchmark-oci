# Aeron Deployment for Oracle Cloud Infrastructure

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ncusato/aeron-terraform-oci/releases/latest/download/AeronMessagingTerraform.zip)

Deploy [Aeron](https://github.com/real-logic/aeron) on OCI for high-performance messaging benchmarks. The stack uses the official **[aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)** repo (LoadTestRig, echo/cluster scenarios, HDR histograms) by default and includes wrapper scripts for two-node echo testing. This README aligns with the [quickstart guide](docs/INCONSISTENCIES-QUICKSTART-VS-STACK.md) as the source of truth for node roles, Ansible pipeline, and benchmark workflow.

---

## Table of Contents

1. [Overview](#overview)
2. [Node Roles and Architecture](#node-roles-and-architecture)
3. [How the Benchmark Works](#how-the-benchmark-works)
4. [Quick Start](#quick-start)
5. [Configuration Options](#configuration-options)
6. [Running Benchmarks](#running-benchmarks)
7. [Understanding Results](#understanding-results)
8. [Performance Tuning](#performance-tuning)
9. [Security and Cleanup](#security-and-cleanup)

---

## Overview

This stack deploys:

- **One controller** (orchestrator) in a **public subnet** — small footprint, used for SSH access and running playbooks.
- **Two or more benchmark nodes** (client/receiver) in a **private subnet** — each with at least 10 OCPUs, used for the actual latency and throughput tests.
- **Optional failover node** in the same private subnet but a **different Availability Domain** — same 10 OCPU minimum, for high availability.

- **Aeron** (real-logic/aeron) is built on each node for the Media Driver and samples.
- **Benchmarks repo** ([aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)) is cloned and built on the controller with `./gradlew deployTar`; the resulting `benchmarks-dist` is deployed to all benchmark nodes. Ansible applies socket buffer tuning, optional CPU isolation, and a fixed profile (288B @ 101K msg/s). Wrapper scripts for two-node echo (and optional cluster) live in `benchmarks-dist/scripts/` and are driven by a stack-generated config so the benchmark runs without Java 17 module errors (JVM `--add-opens`).

---

## Node Roles and Architecture

### What Each Node Does

| Role | Subnet | Default size | Purpose |
|------|--------|--------------|---------|
| **Controller** | Public | 2 OCPUs | Orchestrator only: SSH bastion, runs Ansible, collects results. Does not run the heavy benchmark workload. |
| **Benchmark nodes** | Private | 10+ OCPUs each | **Client** (first node) and **Receiver** (second node). Run the Media Driver, Pong (echo server), and Ping (client) for latency/throughput tests. |
| **Failover** (optional) | Private (different AD) | 10+ OCPUs | Standby node in another Availability Domain for HA. Same Aeron setup as benchmark nodes. |

### Network Layout

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    OCI Region / VCN                       │
                    │                                                           │
  Internet          │  ┌─────────────────────┐     ┌─────────────────────┐    │
  ───────►          │  │   PUBLIC SUBNET      │     │   PRIVATE SUBNET    │    │
  SSH only          │  │                     │     │                     │    │
                    │  │  ┌───────────────┐  │     │  ┌───────────────┐  │    │
                    │  │  │  CONTROLLER   │  │     │  │  BENCHMARK-1   │  │    │
                    │  │  │  (orchestrator)│  │     │  │  (client)     │  │    │
                    │  │  │  2 OCPU       │  │     │  │  10+ OCPU      │  │    │
                    │  │  └───────┬───────┘  │     │  └───────┬───────┘  │    │
                    │  │          │          │     │          │          │    │
                    │  │          │ SSH      │     │          │ UDP      │    │
                    │  │          │ bastion  │     │          │ Aeron    │    │
                    │  │          ▼          │     │  ┌───────▼───────┐  │    │
                    │  └─────────────────────┘     │  │  BENCHMARK-2   │  │    │
                    │                              │  │  (receiver)    │  │    │
                    │                              │  │  10+ OCPU      │  │    │
                    │                              │  └────────────────┘  │    │
                    │                              │  ┌─────────────────┐  │    │
                    │                              │  │  FAILOVER (opt)  │  │    │
                    │                              │  │  different AD    │  │    │
                    │                              │  └─────────────────┘  │    │
                    │                              └─────────────────────┘    │
                    └─────────────────────────────────────────────────────────┘
```

- You SSH to the **controller** (public IP). From there you can SSH to benchmark and failover nodes (private IPs) for multi-node tests.
- Benchmark nodes talk over the **private subnet** (UDP, Aeron ports 40000–40100).

---

## How the Benchmark Works

### Concepts

1. **Media Driver** — Aeron’s low-latency component that handles shared-memory and network I/O. One instance per machine (or per role) that runs the client or server.
2. **Pong** — Echo server: receives messages and sends them back.
3. **Ping** — Client: sends messages to Pong and measures round-trip latency.

So a **latency benchmark** is: start Media Driver + Pong on the receiver, start Media Driver + Ping on the client; Ping reports percentiles (P50, P99, P999, MAX).

### Single-Node Benchmark (what `run-benchmark.sh` does)

On **one** node (e.g. a benchmark node or the controller):

1. **Preflight** — Apply socket buffer sysctl (so Aeron doesn’t warn about small buffers).
2. **Start Media Driver** — Background process that owns the Aeron channels.
3. **Start Pong** — Echo responder, connected to the same Media Driver.
4. **Run Ping** — Client sends messages to Pong; Ping prints latency percentiles.
5. The script runs a **reference run** (288B @ 101K) then a **sweep** over message sizes (32, 64, 128, … bytes).
6. Results are written under `/opt/aeron/results/`.

This is the simplest way to validate the stack and see typical latency numbers on that machine.

### Two-Node (Client–Receiver) Benchmark

For a more realistic test:

- **Receiver node**: start Media Driver + Pong (server).
- **Client node**: start Media Driver + Ping, pointing at the receiver’s IP/channel.

You run these via SSH from the controller to each private IP. The quickstart guide’s wrapper scripts (e.g. `wrapper-echo-java-two-nodes.sh`) follow this pattern with CPU pinning and tuning.

### Key Metrics

| Metric | Meaning |
|--------|--------|
| **P50** | Median latency (50th percentile). |
| **P99** | 99th percentile — tail latency. |
| **P999** | 99.9th percentile — extreme tail. |
| **MAX** | Maximum observed latency. |

All are typically reported in **microseconds (µs)**. Good tuning keeps P50/P99 low and stable; P999 and MAX can spike due to OS or hypervisor.

### Configuration Applied by Ansible

- **Socket buffers** — 4 MiB (`net.core.rmem/wmem_*`) so Aeron gets the buffer sizes it requests.
- **Reference profile** — 288 bytes, 101K messages/sec, for comparable baselines.
- **Latency-first tuning** — `AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND=1`, `AERON_*_IO_VECTOR_CAPACITY=1`, and socket options `AERON_SOCKET_SO_SNDBUF/RCVBUF=2m` to reduce batching jitter.
- **Optional** — GRUB-based CPU isolation (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`) when `apply_cpu_isolation_grub` is enabled (requires reboot).

---

## Quick Start

### Deploy via OCI Resource Manager

1. Click **Deploy to Oracle Cloud** at the top.
2. Sign in and select compartment and region.
3. Set **Controller** AD and shape (default 2 OCPU is fine).
4. Set **Benchmark nodes** AD, count (minimum 2), and shape (10+ OCPUs).
5. Optionally enable **Failover** and choose another AD.
6. Configure or select VCN/subnets, then **Apply**.

### Deploy via Terraform CLI

```bash
git clone https://github.com/ncusato/aeron-terraform-oci.git
cd aeron-terraform-oci
terraform init
# Create terraform.tfvars with compartment_ocid, ssh_public_key, controller_ad, benchmark_ad, etc.
terraform plan
terraform apply
```

After apply, note the **controller public IP** and **benchmark private IPs** from the stack outputs.

---

## Configuration Options

### Controller (orchestrator)

| Variable | Default | Description |
|----------|---------|-------------|
| `controller_ad` | — | Availability Domain for controller. |
| `controller_shape` | `VM.Standard.E5.Flex` | Shape (flex allowed). |
| `controller_ocpus` | `2` | OCPUs (no minimum; orchestrator only). |
| `controller_memory_gb` | `16` | Memory in GB. |

### Benchmark nodes (client/receiver)

| Variable | Default | Description |
|----------|---------|-------------|
| `benchmark_ad` | — | Availability Domain for all benchmark nodes. |
| `benchmark_node_count` | `2` | Number of nodes (minimum 2). |
| `benchmark_shape` | `VM.Standard.E5.Flex` | Shape. |
| `benchmark_ocpus` | `10` | OCPUs per node (minimum 10). |
| `benchmark_memory_gb` | `64` | Memory per node. |

### Failover (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_failover_node` | `false` | Create failover node. |
| `failover_ad` | — | AD (should differ from benchmark_ad). |
| `failover_ocpus` | `10` | OCPUs (minimum 10). |

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `use_existing_vcn` | `false` | Use existing VCN. |
| `existing_public_subnet_id` | — | Public subnet for controller. |
| `existing_private_subnet_id` | — | Private subnet for benchmark/failover. |
| `private_deployment` | `false` | Controller without public IP (VPN/FastConnect). |

### Aeron, benchmarks repo, and image

| Variable | Default | Description |
|----------|---------|-------------|
| `install_aeron` | `true` | Install Aeron and build benchmarks repo. |
| `aeron_git_repo` | `https://github.com/real-logic/aeron.git` | Aeron (Media Driver/samples) repo. |
| `aeron_git_branch` | `""` | Branch/tag (empty = master). |
| `benchmarks_repo_url` | `https://github.com/aeron-io/benchmarks` | Official benchmarks repo (LoadTestRig, echo/cluster). |
| `benchmarks_git_branch` | `""` | Branch/tag (empty = master). |
| `java_version` | `17` | OpenJDK version (17 recommended; JVM opts include `--add-opens` for Agrona). |
| `run_benchmarks` | `false` | Automatically run benchmark matrix after provisioning completes. |
| `run_benchmarks_matrix_modes` | `java,java_vma,c,c_vma` | Driver modes to test in matrix run (comma-separated). |
| `hyperthreading` | `false` | SMT on benchmark/failover (off for latency). |
| `use_default_image` | `true` | Ubuntu 24.04 Minimal image. |

---

## Running Benchmarks

### SSH access

- **Controller**:  
  `ssh -i <your-key> ubuntu@<controller-public-ip>`
- **Benchmark/failover** (via controller):  
  `ssh -i <your-key> -J ubuntu@<controller-public-ip> ubuntu@<benchmark-private-ip>`

### Verify installation on the controller

After the stack apply completes, SSH to the controller and check:

- **`/opt/aeron/playbooks`** — Ansible playbooks (deployed by Terraform).
- **`/opt/aeron/benchmark`** — Single-node scripts (`run-benchmark.sh`, `benchmark-config.yml`). Created by Ansible.
- **`/opt/aeron/benchmarks-dist`** — aeron-io/benchmarks distribution (built with `gradlew deployTar`). Contains `scripts/` with `aeron/remote-echo-benchmarks` and wrapper scripts.
- **`/opt/aeron/scripts`** — Stack scripts: `config/benchmark-config.env` (client/server/failover IPs, paths, JVM opts), `run-echo-benchmark.sh` (launcher that sources config and runs the echo wrapper).
- **`/opt/aeron/.aeron-ready`** — Present if Ansible completed successfully.

If `benchmarks-dist` or `.aeron-ready` is missing, Ansible may have failed; check apply logs and re-run if needed.

**Echo benchmark log shows `c-media-driver` / `aeronmd: No such file or directory`:** `deployTar` can merge a C driver bundle that replaces `scripts/aeron/media-driver` with the native launcher, but `aeronmd` is not present unless that bundle is built. The Ansible `benchmarks-build` role restores the **Java** `media-driver` and `run-java` from `benchmarks-src` after each extract. To fix a live controller by hand: copy those two files from `/opt/aeron/benchmarks-src/scripts/` into `/opt/aeron/benchmarks-dist/scripts/` (see role `benchmarks-build`), then re-sync `benchmarks-dist` to benchmark nodes.

### Single-node: automated script

On the controller or any benchmark node:

```bash
cd /opt/aeron
./run-benchmark.sh
# or from the benchmark directory:
cd /opt/aeron/benchmark && ./run-benchmark.sh
```

This runs the reference profile (288B @ 101K) and a sweep. Results go to `/opt/aeron/results/`.

### Manual single-node (three terminals)

```bash
# Terminal 1: Media Driver
/opt/aeron/bin/media-driver.sh

# Terminal 2: Pong (echo server)
/opt/aeron/bin/pong.sh

# Terminal 3: Ping (client) — 288 bytes, 101K messages
/opt/aeron/bin/ping.sh 288 101000
```

### Two-node echo (aeron-io/benchmarks wrappers)

From the **controller**, run the echo benchmark using the official benchmarks repo and wrapper (client = first benchmark node, server = second). The launcher sources the stack config (IPs, paths, JVM `--add-opens` for Java 17) so the run does not error:

```bash
/opt/aeron/scripts/run-echo-benchmark.sh
```

Or manually:

```bash
source /opt/aeron/scripts/config/benchmark-config.env
cd /opt/aeron/benchmarks-dist/scripts
./wrapper-echo-unified.sh
```

Results (HDR archives) are produced under the scripts directory (e.g. `aeron-echo-*-client.tar.gz`). Use `aggregate-compare-results.sh` in the same directory to aggregate and compare runs. See [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks) and the quickstart for full options (driver modes, cluster, aggregation).

### Full baseline benchmarks (echo and cluster, all driver modes)

The post-apply **driver matrix** uses **smoke-style** Terraform defaults (`benchmark_echo_runs` / `iterations` / `warmup` often `1`) to finish quickly. For **publication-style** numbers (closer to the [Aeron AWS performance testing guide](https://aeron.io) and `BENCH_PROFILE=latency_288_101k`), run **manually from the controller** with enough **RUNS**, **ITERATIONS**, and **WARMUP** so HDR histograms stabilize.

**Prerequisites (controller):**

```bash
cd /opt/aeron/benchmarks-dist/scripts
set -a && source /opt/aeron/scripts/config/benchmark-config.env && set +a
```

**Shared parameters** (288 B @ ~101 K msg/s, 5 outer runs, 30 measurement iterations, 10 warmup — adjust as needed):

```bash
export RUNS=5
export ITERATIONS=30
export WARMUP_ITERATIONS=10
export WARMUP_MESSAGE_RATE=25K
export MESSAGE_LENGTH=288
export MESSAGE_RATE=101K
export BENCH_PROFILE=custom
```

**Echo** (`wrapper-echo-unified.sh`): same workload as [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks) `remote-echo-benchmarks` (LoadTestRig ↔ EchoNode). Run each pair **client and server same mode**:

```bash
# Java / Java
CLIENT_MODE=java SERVER_MODE=java CONTEXT=full-echo-java-java ./wrapper-echo-unified.sh

# Java + OpenOnload-style prefix (maps to java-onload upstream; on OCI without Solarflare, ONLOAD_COMMAND=env is typical)
CLIENT_MODE=java_vma SERVER_MODE=java_vma CONTEXT=full-echo-java_vma-java_vma ./wrapper-echo-unified.sh

# C media driver / aeronmd
CLIENT_MODE=c SERVER_MODE=c CONTEXT=full-echo-c-c ./wrapper-echo-unified.sh

CLIENT_MODE=c_vma SERVER_MODE=c_vma CONTEXT=full-echo-c_vma-c_vma ./wrapper-echo-unified.sh
```

**Cluster** (`wrapper-cluster-unified.sh`): requires **failover** topology in config (third node). Uses `CLUSTER_CLIENT_MODE` / `CLUSTER_SERVER_MODE` (same naming as echo: `java`, `java_vma`, `c`, `c_vma`). Config path is required as the first argument:

```bash
export CLUSTER_CONTEXT=full-cluster-java-java
export CLUSTER_CLIENT_MODE=java
export CLUSTER_SERVER_MODE=java
bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

```bash
export CLUSTER_CONTEXT=full-cluster-java_vma-java_vma
export CLUSTER_CLIENT_MODE=java_vma
export CLUSTER_SERVER_MODE=java_vma
bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

```bash
export CLUSTER_CONTEXT=full-cluster-c-c
export CLUSTER_CLIENT_MODE=c
export CLUSTER_SERVER_MODE=c
bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

```bash
export CLUSTER_CONTEXT=full-cluster-c_vma-c_vma
export CLUSTER_CLIENT_MODE=c_vma
export CLUSTER_SERVER_MODE=c_vma
bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

**Notes:**

- **VMA modes** (`java_vma`, `c_vma`): the stack sets `ONLOAD_COMMAND=env` by default so benchmarks run without Solarflare OpenOnload; for real onload, set `ONLOAD_COMMAND='onload --profile=latency'` in `benchmark-config.env` or export it before the wrapper.
- **Echo vs samples Ping/Pong**: these wrappers drive **LoadTestRig / EchoNode**, not `/opt/aeron/bin/ping.sh` — that is a separate single-node sanity path.
- **Terraform**: raise `benchmark_echo_*` and `message_*` in tfvars if you want the **automated matrix** itself to use these counts (apply time will increase).

### Automated matrix run (Run Benchmarks in stack)

When **Run Benchmarks After Deployment** (`run_benchmarks=true`) is enabled, the stack runs matrix benchmarks automatically **after all node provisioning and configuration is complete**:

- **Echo matrix** always runs (`run-driver-matrix.sh echo`).
- **Cluster matrix** runs automatically when `enable_failover_node=true` (`run-driver-matrix.sh cluster`).
- Driver set comes from `run_benchmarks_matrix_modes` (default: `java,java_vma,c,c_vma`).

Results and progress are published in controller home:

```bash
~/benchmark-results/
  STATUS.txt
  run-driver-matrix-echo.log
  run-driver-matrix-cluster.log            # when failover enabled
  driver-matrix-echo-summary.csv
  driver-matrix-cluster-summary.csv        # when failover enabled
  aeron-echo-*.tar.gz
  aeron-cluster-*.tar.gz                   # when failover enabled
```

`driver-matrix-*-summary.csv` includes:

1. A **matrix status** table (`mode,status,notes`) — one row per driver mode (`java`, `java_vma`, …).
2. **Aggregated latency CSV** (`archive,scenario,valid_runs,median_p50_us,…`) from `aggregate-compare-results.sh`.

**Terraform outputs** (after apply, when `pull_matrix_summary_for_terraform_output=true` and the machine running Terraform can SSH to the controller with Python available):

- `terraform output benchmark_driver_matrix_smoke` — shortcut object: `echo_mode_status` / `cluster_mode_status`, `echo_latencies` / `cluster_latencies`, `pull_failed`, `matrix_profile`.
- `terraform output benchmark_driver_matrix_summary` — full pulled JSON (same file as `.terraform-matrix-summary.json` on the Terraform host).

Set `pull_matrix_summary_for_terraform_output=false` if apply must not depend on local SSH (e.g. some CI). On **Windows**, the pull uses `working_dir` + `python scripts/matrix_summary_pull.py` so paths stay valid.

### Two-node manual (Media Driver + Pong/Ping)

1. On **receiver** (e.g. benchmark-2): start Media Driver and Pong (channel/endpoint so client can reach it).
2. On **client** (e.g. benchmark-1): start Media Driver and Ping with the receiver’s channel (e.g. `aeron:udp?endpoint=<receiver-ip>:20121`).
3. Use the controller as jump host to SSH to both private IPs.

### Throughput (single-node)

```bash
/opt/aeron/bin/media-driver.sh   # in one terminal
/opt/aeron/bin/throughput.sh 1024 100000000   # 1KB, 100M messages
```

---

## Understanding Results

- **P50 (median)** — Typical latency; use for baseline comparison.
- **P99** — Tail latency; target for SLAs.
- **P999 / MAX** — Can spike due to GC, OS, or hypervisor; focus on consistency across runs.

Results are in **microseconds**. Example line:

```text
P50: 37.695 us, P99: 42.655 us, P999: 66.303 us, MAX: 9404.415 us
```

For reproducible baselines, keep the same profile (288B @ 101K), same socket buffer and latency-first tuning, and optionally same CPU isolation across runs.

---

## Performance Tuning

- **Socket buffers** — Already set by Ansible (4 MiB sysctl, 2m for Aeron). Avoid lowering.
- **CPU isolation** — For stricter latency, set `apply_cpu_isolation_grub: true` in Ansible vars, then reboot and use `taskset`/`numactl` to pin Media Driver and Ping/Pong to isolated cores.
- **Hyperthreading** — Disabled by default on benchmark/failover nodes for more stable P99.
- **NUMA** — On multi-socket machines, pin processes to one NUMA node:  
  `numactl --cpunodebind=0 --membind=0 /opt/aeron/bin/media-driver.sh`

---

## Security and Cleanup

- Aeron UDP (40000–40100) is allowed only within the VCN on **Terraform-managed** subnets.
- **aeron-io/benchmarks** echo uses UDP **~12000–14000** (e.g. 13000/13100); **cluster** uses **~20000+** and **dynamic response ports**. The stack attaches an **NSG** with matching **ingress and egress** UDP **12000–65535** to/from the effective benchmark CIDR on benchmark/failover VNICs (NSGs are **stateless**—egress is required for cluster responses to the client). With an **existing VCN**, the **private subnet security list must also allow** that UDP range (or all traffic) from the VCN CIDR—OCI requires both NSG and security list to permit the flow. Override the source CIDR with Terraform variable `aeron_benchmark_udp_ingress_cidr` if needed.
- **Host firewall:** on benchmark nodes (client/receiver), Ansible inserts an **iptables** ACCEPT for UDP **12000–65535** from the same effective CIDR when **`aeron_benchmark_configure_host_firewall`** is **true** (default). Set **`aeron_benchmark_host_firewall_persistent`** to save rules across reboot. See [ECHO-2HOST-ANSIBLE-HANDOFF.md](docs/ECHO-2HOST-ANSIBLE-HANDOFF.md).
- Echo UDP channels follow **[aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)** remote echo conventions. Either **`|interface=<local-ip>/PREFIX`** (default prefix **24**, Terraform **`aeron_echo_udp_interface_prefix_length`**) or **Aeron 1.50+** **`|interface={ifname}`** via **`aeron_echo_udp_named_interface`** (use **`ip -br a`** on the node, e.g. **`enp0s9`** on many OCI shapes). Named mode overrides prefix mode. **`SHOW_CONFIG_ONLY=1 ./wrapper-echo-unified.sh`** (after sourcing config) prints URIs.
- Restrict SSH (e.g. security list or VPN) as needed.
- Use `private_deployment = true` if the controller should have no public IP.

**Destroy stack**

- **Resource Manager**: run a Destroy job on the stack.
- **CLI**: `terraform destroy`

---

## Requirements and References

- OCI tenancy with IAM policies for VCN, instances, and subnets.
- For failover: a second Availability Domain in the region.

**References**

- [Aeron GitHub](https://github.com/real-logic/aeron)
- [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks) — official latency benchmarks, wrappers, aggregation
- [Quickstart vs stack alignment](docs/INCONSISTENCIES-QUICKSTART-VS-STACK.md) — source of truth and inconsistency list
- [Echo benchmark SSH debug playbook](docs/ECHO-BENCHMARK-SSH-DEBUG.md) — commands to run on the controller and how they map to Ansible/Terraform fixes
- [OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/home.htm)
- [OCI HPC Quick Start](https://github.com/oracle-quickstart/oci-hpc)

**License** — Universal Permissive License (UPL) v1.0.
