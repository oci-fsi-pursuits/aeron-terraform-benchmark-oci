# Unified Benchmark Wrappers

This is the simplified learning layout:

- 2 primary wrappers:
  - `/home/ubuntu/benchmarks/scripts/wrapper-echo-unified.sh`
  - `/home/ubuntu/benchmarks/scripts/wrapper-cluster-unified.sh`
- 1 shared config:
  - `/home/ubuntu/benchmarks/scripts/config/benchmark-config.env`
- 1 aggregate/compare tool:
  - `/home/ubuntu/benchmarks/scripts/aggregate-compare-results.sh`
- Optional runner for all driver modes:
  - `/home/ubuntu/benchmarks/scripts/run-driver-matrix.sh`
- Separated full echo/cluster runners:
  - `/home/ubuntu/benchmarks/scripts/run-echo-full-non-vma.sh`
  - `/home/ubuntu/benchmarks/scripts/run-echo-full-vma.sh`
  - `/home/ubuntu/benchmarks/scripts/run-cluster-full-non-vma.sh`
  - `/home/ubuntu/benchmarks/scripts/run-cluster-full-vma.sh`
  - `/home/ubuntu/benchmarks/scripts/run-c-vma-gcp-analog.sh`
  - `/home/ubuntu/benchmarks/scripts/enable-vma-on-nodes.sh`

Existing legacy wrappers remain in place for backward compatibility.

## Echo UDP channels (Quick Start Appendix A)

`benchmark-config.env` and `wrapper-echo-unified.sh` follow **Aeron Benchmarks** [remote echo](https://github.com/aeron-io/benchmarks) layout: four **`aeron:udp?endpoint=…|interface=…`** URIs.

- **CIDR style** (Quick Start Appendix A): **`|interface=LOCAL_IP/PREFIX`** — Terraform default **`auto`** sets prefix from **`private_subnet_cidr`**; override with **`aeron_echo_udp_interface_prefix_length`** (e.g. **16**), or **`AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH`** before sourcing.
- **Named interface (Aeron 1.50+ driver):** **`|interface={ifname}`** — set Terraform **`aeron_echo_udp_named_interface`** to the NIC carrying the private IP (e.g. **`ens3`**), or **`export AERON_ECHO_UDP_NAMED_INTERFACE=ens3`** before the wrapper. The driver parses this as **`NamedInterface`** in [aeron-io/aeron](https://github.com/aeron-io/aeron) (`{name}` or `{name}:port`). When set, it **overrides** the prefix-length mode.
- **Omit `interface`:** **`AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=""`** and no named interface (diagnostics).

Override fully with **`CLIENT_*_CHANNEL`** / **`SERVER_*_CHANNEL`** if client and server use different NIC names.

## Debugging echo timeouts (on controller)

From **`/opt/aeron/benchmarks-dist/scripts`** (after sourcing or with default config path):

```bash
./echo-benchmark-debug.sh ./config/benchmark-config.env
```

Prints local/remote interfaces, channel env, SSH checks, and runs **`SHOW_CONFIG_ONLY`** with a smoke profile.

For a full shell trace of the **`remote-echo-benchmarks`** launch:

```bash
set -a && source ./config/benchmark-config.env && set +a
WRAPPER_DEBUG=1 BENCH_PROFILE=smoke_288_101k ./wrapper-echo-unified.sh 2>&1 | tee /tmp/echo-trace.log
```

## OpenOnload (`ONLOAD_COMMAND`)

Benchmark scripts pass `--onload` to `remote-echo-benchmarks`. Cloud VMs (e.g. OCI) usually **do not** have the `onload` binary; the default is **`env`**, which runs Java/media-driver with no extra prefix. For Solarflare NICs and `java_vma` / `c_vma`, set:

`export ONLOAD_COMMAND='onload --profile=latency'` (in `config/benchmark-config.env` or the shell).

## Driver modes

Set `CLIENT_MODE`/`SERVER_MODE` (echo) or `CLUSTER_CLIENT_MODE`/`CLUSTER_SERVER_MODE` (cluster):

- `java`
- `c`
- `java_vma` (mapped to `java-onload`)
- `c_vma` (mapped to `c-onload`)
- `c-dpdk`

## Echo wrapper (combined)

Default run:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./wrapper-echo-unified.sh
```

Smoke run:

```bash
BENCH_PROFILE=smoke_288_101k \
CLIENT_MODE=java \
SERVER_MODE=java \
CONTEXT=echo-smoke \
bash ./wrapper-echo-unified.sh
```

Preview config only:

```bash
SHOW_CONFIG_ONLY=1 bash ./wrapper-echo-unified.sh
```

## Cluster wrapper (separate)

Default run:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

Config preview only:

```bash
SHOW_CONFIG_ONLY=1 bash ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

## Run all driver modes and compare

Echo matrix:

```bash
cd /home/ubuntu/benchmarks/scripts
MATRIX_MODES="java,c,java_vma,c_vma" \
bash ./run-driver-matrix.sh echo
```

Cluster matrix:

```bash
cd /home/ubuntu/benchmarks/scripts
MATRIX_MODES="java,c" \
bash ./run-driver-matrix.sh cluster
```

## C/VMA GCP-Analog Lane

Use this to mirror the GCP `c-dpdk` comparison axis without DPDK: it runs `c` vs `c_vma` for echo and cluster, at `101K` and `1001K` by default, and stores status, logs, archives, and an aggregate CSV under `~/benchmark-results/runs/<run-id>/`.

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./run-c-vma-gcp-analog.sh
```

Common quick variants:

```bash
# Echo-only smoke pass
ANALOG_TARGETS=echo ANALOG_RATES=101K ANALOG_RUNS=1 ANALOG_ITERATIONS=3 bash ./run-c-vma-gcp-analog.sh

# Cluster-only publishable-style pass
ANALOG_TARGETS=cluster ANALOG_RATES=101K,1001K ANALOG_RUNS=5 ANALOG_ITERATIONS=30 bash ./run-c-vma-gcp-analog.sh
```

## Run separated full benchmarks

Use these when comparing VMA against non-VMA. They run `101K` and `1001K` by default and keep VMA and non-VMA state in separate wrapper processes.

Echo, non-VMA only:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./run-echo-full-non-vma.sh
```

Echo, VMA only:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./run-echo-full-vma.sh
```

Cluster, non-VMA only:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./run-cluster-full-non-vma.sh
```

Cluster, VMA only:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./run-cluster-full-vma.sh
```

The VMA prep script can also be run directly:

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./enable-vma-on-nodes.sh status
bash ./enable-vma-on-nodes.sh enable
bash ./enable-vma-on-nodes.sh disable
```

Useful overrides:

```bash
FULL_BENCH_RATES="101K,1001K" \
FULL_BENCH_MODES="java,c" \
FULL_BENCH_RUNS=5 \
FULL_BENCH_ITERATIONS=30 \
bash ./run-echo-full-non-vma.sh

VMA_RUN_AS_ROOT=1 \
FULL_BENCH_MODES="java_vma,c_vma" \
bash ./run-echo-full-vma.sh

CLUSTER_BACKUP_ENABLE_VMA=1 \
VMA_RUN_AS_ROOT=1 \
bash ./run-cluster-full-vma.sh
```

Results are written under `~/benchmark-results/runs/<run-id>/`; `~/benchmark-results/latest-run.txt` points at the newest separated run. The VMA wrappers default to `sudo -E env LD_PRELOAD=<libvma>` and remove file capabilities from native Aeron binaries so `LD_PRELOAD` is not silently ignored by Linux secure-exec. The cluster VMA wrapper also defaults `CLUSTER_BACKUP_ENABLE_VMA=1` so the failover/backup path is prepared with the same VMA intent.

## Aggregate and compare archives directly

```bash
cd /home/ubuntu/benchmarks/scripts
bash ./aggregate-compare-results.sh \
  ./aeron-echo-YYYY-MM-DD-HH-MM-SS-client.tar.gz \
  ./aeron-echo-YYYY-MM-DD-HH-MM-SS-client.tar.gz
```

Output columns:

- archive
- scenario
- valid_runs
- median_p50_us
- median_p99_us
- median_p999_us
- median_max_us
