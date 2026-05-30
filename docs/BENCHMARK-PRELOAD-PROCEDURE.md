# Benchmark Preload Procedure

Use this procedure for OCPU scaling tests at a fixed target rate. Do not change
message rate between OCPU sizes unless the test objective changes.

## Objective

- Fixed target rate: `1001000` messages/second.
- Message size: `288` bytes.
- Current 16 OCPU Optimized3 expectation with SMT: `32` vCPUs.
- Current 16 OCPU isolation expectation: housekeeping `0-5`, isolated `6-31`.
- The preload step injects `6-31` into the wrapper CPU affinity variables so
  the wrappers do not fall back to older generic ranges such as `8-31`.
- Valid runs must produce `.hdr` files. `.hdr.FAIL` means the target rate was not
  sustained and must not be interpreted as latency success.

## Controller Setup

Run from the controller:

```bash
cd /opt/aeron/benchmarks-dist/scripts
```

Show the exact variables that will be injected into the wrappers:

```bash
./preload-benchmark-env.sh \
  --show \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 1 \
  --iterations 1 \
  --warmup 1 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31
```

Validate topology, failover, CPU isolation, and VMA/RDMA readiness:

```bash
./preload-benchmark-env.sh \
  --validate \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 1 \
  --iterations 1 \
  --warmup 1 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31
```

## Smoke Gate

Run the shortest fixed-rate echo gate first. This answers only: can this OCPU
size sustain the target rate and produce valid HDR output?

```bash
./preload-benchmark-env.sh \
  --run echo \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 1 \
  --iterations 1 \
  --warmup 1 \
  --strict 0 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31
```

Read the generated `driver-matrix-echo-preloaded.csv`.

- `valid_runs > 0` and mode `ok`: usable latency data.
- `hdr-fail-target-rate-not-met`: target rate was not sustained.
- `valid_runs=0`: no usable latency data for that mode.

## Extended Gate

Only after the smoke gate produces valid `.hdr` data:

```bash
./preload-benchmark-env.sh \
  --run both \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 3 \
  --iterations 3 \
  --warmup 3 \
  --strict 0 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31
```

Use `--strict 1` only for a qualification run where the first failed mode should
abort the matrix.

## Manual Wrapper Mode

To preload variables into the current shell and run a wrapper manually:

```bash
source ./preload-benchmark-env.sh \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 1 \
  --iterations 1 \
  --warmup 1 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31

CLIENT_MODE=c_vma SERVER_MODE=c_vma ./wrapper-echo-unified.sh
CLUSTER_CLIENT_MODE=c_vma CLUSTER_SERVER_MODE=c_vma ./wrapper-cluster-unified.sh ./config/benchmark-config.env
```

## Manual Node Override

If the controller config is stale, keep the same fixed test and inject the
topology explicitly:

```bash
./preload-benchmark-env.sh \
  --show \
  --ssh-key /opt/aeron/.ssh/deploy_key \
  --client 10.36.1.243 \
  --receiver 10.36.1.140 \
  --failover 10.36.1.63 \
  --modes c,c_vma \
  --rate 1001000 \
  --length 288 \
  --runs 1 \
  --iterations 1 \
  --warmup 1 \
  --expected-vcpus 32 \
  --expected-isolated 6-31 \
  --affinity-range 6-31
```

Use `--validate` with the same arguments before any `--run`.
