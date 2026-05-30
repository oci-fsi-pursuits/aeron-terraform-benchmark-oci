# Aeron Deployment for Oracle Cloud Infrastructure

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/oci-fsi-pursuits/aeron-terraform-benchmark-oci/releases/latest/download/AeronMessagingTerraform.zip)

Deploy [Aeron](https://github.com/real-logic/aeron) on OCI for high-performance messaging benchmarks. The stack uses the official **[aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)** repo (LoadTestRig, echo/cluster scenarios, HDR histograms) by default and includes wrapper scripts for two-node echo testing. This README aligns with the [quickstart guide](docs/INCONSISTENCIES-QUICKSTART-VS-STACK.md) as the source of truth for node roles, Ansible pipeline, and benchmark workflow.

---

## Table of Contents

1. [Overview](#overview)
2. [Node Roles and Architecture](#node-roles-and-architecture)
3. [How the Benchmark Works](#how-the-benchmark-works)
4. [Quick Start](#quick-start)
5. [Configuration Options](#configuration-options)
6. [Running Benchmarks](#running-benchmarks)
7. [Consolidating matrix summaries](#consolidating-matrix-summaries)
8. [Understanding Results](#understanding-results)
9. [Performance Tuning](#performance-tuning)
10. [Security and Cleanup](#security-and-cleanup)

---

## Overview

This stack deploys:

- **One controller** (orchestrator) in a **public subnet** — default **VM.Standard.E6.Flex**, **2 OCPU / 16 GB**; SSH bastion and Ansible.
- **Two or more benchmark nodes** (client/receiver) in a **private subnet** — default **VM.Standard.E6.Flex**, **16 OCPU / 124 GB** each (minimum **10** OCPU is enforced in Terraform).
- **Optional failover node** in the same private subnet but a **different Availability Domain** — default **16 OCPU / 124 GB**, same shape family as benchmark nodes.

- **Aeron** (real-logic/aeron) is built on each node for the Media Driver and samples.
- **Benchmarks repo** ([aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)) is cloned and built on the controller with `./gradlew deployTar`; the resulting `benchmarks-dist` is deployed to all benchmark nodes. Ansible applies socket buffer tuning, optional CPU isolation, and a fixed profile (288B @ 101K msg/s). Wrapper scripts for two-node echo (and optional cluster) live in `benchmarks-dist/scripts/` and are driven by a stack-generated config so the benchmark runs without Java 17 module errors (JVM `--add-opens`).

---

## Node Roles and Architecture

### What Each Node Does

| Role | Subnet | Default size | Purpose |
|------|--------|--------------|---------|
| **Controller** | Public | E6.Flex, 2 OCPU / 16 GB | Orchestrator: SSH bastion, Ansible, results. Not the heavy benchmark workload. |
| **Benchmark nodes** | Private | E6.Flex, 16 OCPU / 124 GB | **Client** (first) and **Receiver** (second). Media Driver, echo/cluster workloads. |
| **Failover** (optional) | Private (different AD) | E6.Flex, 16 OCPU / 124 GB | HA standby; **failover AD must differ from benchmark AD** (enforced at plan). |

### Network Layout

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    OCI Region / VCN                       │
                    │                                                           │
  Internet          │  ┌─────────────────────┐     ┌─────────────────────┐    │
  ───────►          │  │   PUBLIC SUBNET      │     │   PRIVATE SUBNET    │    │
  SSH only          │  │                     │     │                     │    │
                    │  │  ┌───────────────┐  │     │  ┌───────────────┐  │    │
                    │  │  │  CONTROLLER   │  │     │  │  CLIENT        │  │    │
                    │  │  │  (orchestrator)│  │     │  │  (benchmark)   │  │    │
                    │  │  │  2 OCPU       │  │     │  │  16 OCPU       │  │    │
                    │  │  └───────┬───────┘  │     │  └───────┬───────┘  │    │
                    │  │          │          │     │          │          │    │
                    │  │          │ SSH      │     │          │ UDP      │    │
                    │  │          │ bastion  │     │          │ Aeron    │    │
                    │  │          ▼          │     │  ┌───────▼───────┐  │    │
                    │  └─────────────────────┘     │  │  RECEIVER      │  │    │
                    │                              │  │  (benchmark)   │  │    │
                    │                              │  │  16 OCPU       │  │    │
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

- **Socket buffers** — high-rate profile (`rmem/wmem_max=33554432`, defaults `8388608`) so Aeron/VMA runs are not clamped by small kernel limits.
- **Reference profile** — 288 bytes, 101K messages/sec, for comparable baselines.
- **Latency-first tuning** — `AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND=1`, `AERON_*_IO_VECTOR_CAPACITY=1`, and socket options `AERON_SOCKET_SO_SNDBUF/RCVBUF=2m` to reduce batching jitter.
- **GRUB CPU isolation (default on)** — On benchmark/failover nodes, `grub_dynamic_cpu_isolation` writes `isolcpus` / `nohz_full` / `rcu_nocbs` from live logical CPU count. When `hyperthreading=false`, it also writes `nosmt`; BM.Optimized3.36 uses housekeeping `0-3` and isolated `4-35` in the RDMA profile. **Reboot** required for kernel changes.
- **Cloud-init RDMA networking (optional)** — For Ubuntu BM.Optimized3 cluster-network tests, `benchmark_cloud_init_rdma=true` installs RDMA tooling, loads mlx5/verbs modules, renames the working 100G RoCE port to `eth1`, and assigns `10.x.100.<host-octet>/24` by netplan.

---

## Quick Start

### Deploy via OCI Resource Manager

1. Use **Deploy to Oracle Cloud** (badge above).
2. Set **compartment**, **region**, **SSH public key**, and **Availability Domains** for controller and benchmark nodes.
3. Defaults are **E6.Flex** with **16 OCPU / 124 GB** on benchmark and failover; controller stays **2 / 16**.
4. **Network:** new VCN or existing; optional **Create benchmark cluster placement group** (checkbox, default on) only when **not** using an existing VCN.
5. **Aeron:** install toggle, optional automated benchmark run and matrix options; advanced git/Java/echo tuning is hidden and uses Terraform defaults.

### Deploy via Terraform CLI

```bash
git clone https://github.com/oci-fsi-pursuits/aeron-terraform-benchmark-oci.git
cd aeron-terraform-benchmark-oci
terraform init
cp local-test.tfvars.example local-test.tfvars   # edit OCIDs, ADs, key
terraform plan  -var-file=local-test.tfvars
terraform apply -var-file=local-test.tfvars
```

After apply, use stack **outputs** for controller public IP and benchmark private IPs.

---

## Configuration Options

**Default sizing:** benchmark and failover **VM.Standard.E6.Flex**, **16 OCPU**, **124 GB** RAM; controller **E6.Flex**, **2 OCPU**, **16 GB**. Terraform still enforces **≥ 10 OCPU** on benchmark/failover flex shapes.

### Terraform defaults (selected)

| Area | Variable | Default | Notes |
|------|----------|---------|--------|
| Controller | `controller_shape` / `controller_ocpus` / `controller_memory_gb` | `VM.Standard.E6.Flex` / `2` / `16` | |
| Benchmark | `benchmark_shape` / `benchmark_ocpus` / `benchmark_memory_gb` | `VM.Standard.E6.Flex` / `16` / `124` | `benchmark_node_count` default `2`. |
| Failover | `failover_shape` / `failover_ocpus` / `failover_memory_gb` | `VM.Standard.E6.Flex` / `16` / `124` | `enable_failover_node` default `false`. |
| Network | `use_existing_vcn` | `false` | Subnet OCIDs required when `true`. |
| Echo UDP | `aeron_echo_udp_interface_prefix_length` | `auto` | Derives `|interface=IP/prefix` mask from **`private_subnet_cidr`** (benchmark private subnet). Override with e.g. `"24"` or `"16"` if needed. |
| Placement | `create_benchmark_cluster_placement_group` | `true` | VM placement-group path. Keep false for the BM.Optimized3 cluster-network RDMA path. |
| Cluster network | `enable_benchmark_cluster_network` | `false` | Launch benchmark nodes through OCI cluster network/instance pool. Use for BM.Optimized3.36 RDMA tests. |
| RDMA cloud-init | `benchmark_cloud_init_rdma` / `benchmark_cloud_init_rdma_ipv4_prefix` | `false` / `""` | Ubuntu RDMA path: disable OCI HPC plugins, configure `eth1`, MTU `4220`, and RDMA IPs such as `10.34.100.x/24`. |
| RDMA compute cluster | `enable_rdma_compute_cluster` / `rdma_existing_compute_cluster_id` / `rdma_enable_hpc_plugins` | `false` / `""` / `true` | Direct-instance compute-cluster path for RDMA-capable bare-metal images that use OCI RDMA agent plugins. |
| Image | `use_default_image` | `true` | Ubuntu 24.04 Minimal. |
| Isolation | `grub_dynamic_cpu_isolation` | `true` | GRUB `isolcpus` on benchmark/failover from live CPU count; **reboot** to apply. |
| Aeron | `install_aeron` / `run_smoke_test` / `run_full_benchmark` | `true` / `true` / `false` | Post-apply matrix: **smoke** (fast 1/1/1) and **full** (long HDR-style) are separate. Modes default `java,c`; add `java_vma,c_vma` after VMA is installed. |
| Bootstrap | `install_oci_cn_auth` | `false` | RDMA mode helper for RedHat/Oracle Linux images. Keep false for the working Ubuntu cloud-init RDMA path. |

Full definitions: `variables.tf`. Example overrides: `local-test.tfvars.example` (copy to `local-test.tfvars`, gitignored).

For a ready-made Ubuntu BM profile on `BM.Optimized3.36`, cluster network, `eth1`, `10.x.100.x/24`, 3-node Raft, VCN UDP cluster channels, and 120 VPU block volumes at `/mnt/aeron-cluster`, use `local-test-rdma-bm-optimized3.tfvars.example`.

### Resource Manager (`schema.yaml`)

The console shows **grouped** variables. **Hidden** (not in the wizard; stack uses Terraform defaults): tenancy/region/SSH username/instance principal/default image name, **cluster CPU affinity**, **`grub_dynamic_cpu_isolation`**, **Aeron/benchmarks git URLs and branches**, **Java version**, **echo smoke tuning** (runs/iterations/warmup/rates/message size), and **echo UDP interface** (`prefix length` defaults to **auto** from private subnet CIDR / optional named interface). **Visible** groups include: Basic, Controller, Benchmark, Failover, Performance (**hyperthreading** only), Network (including cluster network and cloud-init RDMA controls), Image, and Aeron (**install**, **run smoke test**, **run full benchmark**, matrix modes, cluster matrix, pull summary for output, **build native aeronmd**).

### Terraform CLI (`local-test.tfvars.example`)

**Required in practice:** `tenancy_ocid`, `region`, `compartment_ocid`, `ssh_public_key`, `controller_ad`, `benchmark_ad`, and either new-VCN fields or `use_existing_vcn` plus VCN/subnet OCIDs. **Optional:** sizing, `enable_failover_node` + `failover_ad` (≠ `benchmark_ad`), `hyperthreading`, image choice, Aeron/benchmark/git/echo variables commented in the example. Requires **Terraform ≥ 1.5** (check blocks).

**Hostnames:** display names use **client** / **receiver**. VNIC labels use `{prefix}-controller|client|receiver|failover` (prefix from `cluster_name` / pet / `instance_hostname_prefix`; max 63 chars) so shared subnets do not collide.

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
- **`/opt/aeron/scripts`** — Stack scripts: `config/benchmark-config.env` (client/server/failover IPs, paths, JVM opts), `run-echo-benchmark.sh` (launcher that sources config and runs the echo wrapper), `generate-benchmark-summary-csvs.sh` and `consolidate-benchmark-histograms.py` (merge several `run-driver-matrix` summary CSVs into histogram-style outputs).
- **`/opt/aeron/.aeron-ready`** — Present if Ansible completed successfully.

On **client / receiver / failover** nodes, the **`aeron-benchmark`** role installs **`numactl`** (if missing) and runs **`numactl --show`** so wrapper smoke/matrix fails in **Ansible** before Terraform’s post-apply matrix, not mid-`run-driver-matrix.sh`.

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

- **Benchmark tuning profiles** (`benchmark_tuning_profile`): `auto` selects `bm_rdma` when RDMA cloud-init is enabled and `vm_stable` otherwise. `bm_rdma` renders the validated Ubuntu BM.Optimized3 VMA launch (`sudo -E env AERON_SHM_USER=ubuntu AERON_DIR=/dev/shm/aeron VMA_SPEC=latency VMA_RX_POLL=-1 ... LD_PRELOAD=<libvma>`), routes cluster `java_vma` through native `c-media-driver`, enables the `/dev/shm/aeron` ownership fixup, sets cluster pins to `20-31` / `24-31`, and uses 16 MiB / 32 Aeron high-rate values. `vm_stable` keeps the VM-safe 2 MiB / 1 Aeron values and a plain `env LD_PRELOAD=<libvma>` VMA command.
- **VMA modes** (`java_vma`, `c_vma`): wrappers use plain `env` for `java`/`c` and `ONLOAD_COMMAND_VMA` only for `*_vma` modes. The VMA library path comes from `benchmark_vma_lib_path` / role default. Keep `benchmark_vma_apply_setcap=false` for the BM RDMA profile because file capabilities block `LD_PRELOAD` on `aeronmd`; `enable-vma-on-nodes.sh` removes stale capabilities before VMA runs.
- **BM cluster runner**: the controller installs `/home/ubuntu/run-cluster-benchmark.sh`, `/home/ubuntu/run-cluster-java-vma-101k.sh`, and `/home/ubuntu/run-cluster-java-vma-1001k.sh`. These call `wrapper-cluster-unified.sh`; do not call `remote-cluster-benchmarks` directly.
- **Echo vs samples Ping/Pong**: these wrappers drive **LoadTestRig / EchoNode**, not `/opt/aeron/bin/ping.sh` — that is a separate single-node sanity path.
- **Terraform post-apply automation**: use **`run_smoke_test`** (default **true**) for a fast validation matrix and **`run_full_benchmark`** (default **false**) for a long baseline-style matrix. Those passes apply **`MATRIX_OVERRIDE_*`** inside `run-driver-matrix.sh` after sourcing `benchmark-config.env` (they do not depend on `benchmark_echo_*` in tfvars). For **manual** runs only, tune `benchmark_echo_*` / `message_*` in tfvars so Ansible writes the profile you want into `benchmark-config.env`.

### Automated matrix run (smoke test vs full benchmark)

When **`run_smoke_test`** and/or **`run_full_benchmark`** is **true** (and `install_aeron=true`), the stack runs **`run-driver-matrix.sh`** on the controller **after** provisioning:

| Toggle | Default | What runs |
|--------|---------|-----------|
| **`run_smoke_test`** | **true** | Echo matrix (and cluster if failover + `run_benchmarks_cluster_matrix`) with fixed **RUNS=1, ITERATIONS=1, WARMUP_ITERATIONS=1** and a **900s** per-mode timeout. |
| **`run_full_benchmark`** | **false** | Same driver set again with **`full_benchmark_*`** defaults (e.g. **5 / 30 / 10** warmup, **101K** rate) and **`full_benchmark_matrix_mode_timeout_sec`** (default **7200s**) per mode. **Apply time can be many hours** if enabled. |

If **both** are true, **smoke runs first**, then **full**. **`driver-matrix-echo-summary.csv`** / **`driver-matrix-cluster-summary.csv`** (and `terraform-matrix-summary.json`) reflect the **full** pass when `run_full_benchmark` is true; otherwise they reflect smoke. With both enabled, smoke summaries are also written as **`driver-matrix-echo-summary-smoke.csv`** / **`driver-matrix-cluster-summary-smoke.csv`**.

Driver set comes from **`run_benchmarks_matrix_modes`** (default: `java,c`; add `java_vma,c_vma` when libvma is installed on benchmark nodes — preflight checks `LD_PRELOAD` path).

**Rename note:** the old single variable **`run_benchmarks`** is replaced by **`run_smoke_test`** + **`run_full_benchmark`**. Former `run_benchmarks = true` → set **`run_smoke_test = true`** (and **`run_full_benchmark = true`** only if you want the long pass during apply).

**numactl / `NON_ISOLATED_CPU_CORES`:** `benchmark-config.env` may suggest a range from Terraform **`benchmark_ocpus`**. **`wrapper-echo-unified.sh`** tries **`numactl --physcpubind`** on each node in order: that value, the auto profile from **`getconf`/`lscpu`**, then **`0-7`**, **`0-3`**, **`0-1`**, **`0`** so tight **cgroup / isolcpus / housekeeping-only** SSH sessions still get a valid bind; pin variables adjust for **`0`** / **`0-1`**. Keep **`benchmark_ocpus`** aligned with the flex shape you provision when possible.

Results and progress under the controller home:

```bash
~/benchmark-results/
  STATUS.txt
  run-driver-matrix-echo.log              # smoke only, or full only (single pass)
  run-driver-matrix-echo-smoke.log        # when both smoke and full
  run-driver-matrix-echo-full.log         # when both smoke and full
  run-driver-matrix-cluster.log           # cluster: same naming pattern
  run-driver-matrix-cluster-smoke.log
  run-driver-matrix-cluster-full.log
  driver-matrix-echo-summary.csv
  driver-matrix-echo-summary-smoke.csv    # when both smoke and full
  driver-matrix-cluster-summary.csv
  driver-matrix-cluster-summary-smoke.csv
  aeron-echo-*.tar.gz
  aeron-cluster-*.tar.gz
```

`driver-matrix-*-summary.csv` includes:

1. A **matrix status** table (`mode,status,notes`) — one row per driver mode (`java`, `java_vma`, …).
2. **Aggregated latency CSV** (`archive,scenario,valid_runs,median_p50_us,…`) from `aggregate-compare-results.sh`.

**After apply**, matrix summaries stay on the **controller** under `~/benchmark-results` (including `terraform-matrix-summary.json` produced there). Use `terraform output benchmark_driver_matrix` for configuration context and `terraform output controller_ssh_command` (or similar) to SSH in and `cat` that file. Optional: from a machine that can SSH to the controller, run `python scripts/matrix_summary_pull.py` with `TF_SSH_KEY`, `TF_MATRIX_CONTROLLER_HOST`, `TF_MATRIX_SSH_USER`, and `TF_MATRIX_OUT` set to copy JSON locally (not wired into `terraform apply`).

---

## Consolidating matrix summaries

After **full** echo and cluster matrix runs (custom `STATUS_FILE` / `SUMMARY_FILE` paths under `~/benchmark-results`, as in a long-run recipe), you can merge the per-matrix summary CSVs into compact histogram tables:

- **`patterns,p50,p99,p999,p9999,max`** — `p9999` is filled when HDR `.hgrm` reports include a ~99.99th percentile line; otherwise it may be blank.
- **`*-all.csv`** — every valid row (`valid_runs > 0`) from all listed summaries.
- **`*-best-of-all.csv`** — per scenario (pattern), the single row with the lowest **p99** (then p999, then max) across inputs.

On the **controller**:

```bash
export SUMMARY_FILES="driver-matrix-echo-summary-full-20260327-120000.csv,driver-matrix-cluster-summary-full-20260327-120000.csv"
export OUTPUT_PREFIX="full-20260327-120000-histograms"
# Optional: default is ~/benchmark-results
# export BENCHMARK_RESULTS_DIR="$HOME/benchmark-results"

/opt/aeron/scripts/generate-benchmark-summary-csvs.sh
# Writes: $BENCHMARK_RESULTS_DIR/${OUTPUT_PREFIX}-all.csv
#         $BENCHMARK_RESULTS_DIR/${OUTPUT_PREFIX}-best-of-all.csv
```

**Troubleshooting:** If echo rows are missing from consolidated output, open the echo summary and check **`valid_runs`**. If **`valid_runs=0`**, inspect client archives for **`*.hdr.FAIL`** — the offered rate may be unsustainable; reduce `MESSAGE_RATE`, fix CPU affinity (`CLIENT_NON_ISOLATED_CPU_CORES` / `SERVER_*` on isolated kernels), and rerun. See [docs/BENCHMARK-NODE-OPTIMIZATION-NOTES.md](docs/BENCHMARK-NODE-OPTIMIZATION-NOTES.md) and kernel/GRUB notes in [Performance tuning](#performance-tuning).

### Two-node manual (Media Driver + Pong/Ping)

1. On **receiver** (second benchmark node, display name `*-receiver`): start Media Driver and Pong (channel/endpoint so client can reach it).
2. On **client** (first benchmark node, `*-client`): start Media Driver and Ping with the receiver’s channel (e.g. `aeron:udp?endpoint=<receiver-ip>:20121`).
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

- **Socket buffers** — Already set by Ansible (`rmem/wmem_max=33554432`, Aeron defaults still override per run). Avoid lowering.
- **CPU isolation** — `grub_dynamic_cpu_isolation` (Terraform, default **true**) writes **`/etc/default/grub.d/51-aeron-cpu-isolation.cfg`** (not the main `/etc/default/grub` file, which may still show only `quiet splash`). Confirm with `grep isolcpus /boot/grub/grub.cfg` after `update-grub`. **Live** `/proc/cmdline` only changes after **reboot**. If `grub.d` was not sourced on a minimal image, the playbook appends a small `grub.d` source block to `/etc/default/grub`.
- **Hyperthreading** — Disabled by default on benchmark/failover nodes for more stable P99.
- **NUMA** — On multi-socket machines, pin processes to one NUMA node:  
  `numactl --cpunodebind=0 --membind=0 /opt/aeron/bin/media-driver.sh`

---

## Security and Cleanup

- Aeron UDP (40000–40100) is allowed only within the VCN on **Terraform-managed** subnets.
- **aeron-io/benchmarks** echo uses UDP **~12000–14000** (e.g. 13000/13100); **cluster** uses **~20000+** and **dynamic response ports**. The stack attaches an **NSG** with matching **ingress and egress** UDP **12000–65535** to/from the effective benchmark CIDR on benchmark/failover VNICs (NSGs are **stateless**—egress is required for cluster responses to the client). With an **existing VCN**, the **private subnet security list must also allow** that UDP range (or all traffic) from the VCN CIDR—OCI requires both NSG and security list to permit the flow. Override the source CIDR with Terraform variable `aeron_benchmark_udp_ingress_cidr` if needed.
- **Host firewall:** on benchmark nodes (client/receiver), Ansible inserts an **iptables** ACCEPT for UDP **12000–65535** from the same effective CIDR when **`aeron_benchmark_configure_host_firewall`** is **true** (default). Set **`aeron_benchmark_host_firewall_persistent`** to save rules across reboot. See [ECHO-2HOST-ANSIBLE-HANDOFF.md](docs/ECHO-2HOST-ANSIBLE-HANDOFF.md).
- Echo UDP channels follow **[aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)** remote echo conventions. Either **`|interface=<local-ip>/PREFIX`** (Terraform **`aeron_echo_udp_interface_prefix_length`**, default **`auto`**: prefix is taken from **`private_subnet_cidr`**, e.g. `10.0.1.0/24` → **24**) or **Aeron 1.50+** **`|interface={ifname}`** via **`aeron_echo_udp_named_interface`** (use **`ip -br a`** on the node, e.g. **`enp0s9`** on many OCI shapes). Named mode overrides prefix mode. **`SHOW_CONFIG_ONLY=1 ./wrapper-echo-unified.sh`** (after sourcing config) prints URIs.
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
