# Java Echo Benchmark Tuning Procedure

Date: 2026-05-11

## Scope

This procedure tunes the Java echo benchmark without changing the C benchmark path.
The validated controller was `158.101.16.139`, using VM.Optimized3.Flex benchmark nodes with 32 vCPUs, one NUMA node, and kernel isolation:

```text
isolcpus=managed_irq,domain,6-31 nohz_full=6-31 rcu_nocbs=6-31 irqaffinity=0-5
```

## Finding

The Java tail-latency issue was not primarily a JVM profile problem. The echo wrapper was auto-pinning the four hot Java threads to adjacent vCPUs:

```text
old pins: 8,9,10,11
```

On the VM.Optimized3.Flex nodes, adjacent vCPUs are SMT siblings:

```text
8/9  = same physical core
10/11 = same physical core
```

That packed the media-driver and application hot threads onto two physical cores. The fixed pattern spreads them across physical cores:

```text
new pins: 8,10,12,14
process cpuset: 8-31
```

## Code Change

`playbooks/roles/aeron-benchmark/files/wrappers/wrapper-echo-unified.sh`

The `build_cpu_profile` function now checks for SMT before the broad `cpus >= 24` case. On 32-vCPU / 2-thread-per-core nodes it chooses:

```text
conductor=8
sender=10
receiver=12
app=14
```

This keeps housekeeping CPUs `0-5` away from the benchmark and avoids pinning hot Java threads to sibling vCPUs.

## Controller Verification

Run this from the controller to confirm the wrapper renders the expected pins:

```bash
cd /opt/aeron/benchmarks-dist/scripts
AERON_NONVMA_MODES=java \
AERON_BENCHMARK_RATE=101K \
AERON_BENCHMARK_RUNS=1 \
AERON_BENCHMARK_ITERATIONS=1 \
AERON_BENCHMARK_WARMUP=1 \
SHOW_CONFIG_ONLY=1 \
./run-benchmark-non-vma.sh echo
```

Expected rendered lines:

```text
client cores: nonisolated=8-31 pins=8,10,12,14
server cores: nonisolated=8-31 pins=8,10,12,14
```

The config-only command may exit non-zero because no archive is produced. That is acceptable for this check.

## Repeatable Java Echo Run

Before each Java tuning run, remove `java-options.env` from controller, client, and receiver. This keeps Java on the default benchmark JVM profile and prevents Java-only experiments from leaking into later C runs.

```bash
for h in localhost aeron-benchmark-client aeron-benchmark-receiver; do
  if [[ "$h" == localhost ]]; then
    sudo rm -f /opt/aeron/benchmarks-dist/scripts/java-options.env
  else
    ssh -i /opt/aeron/.ssh/deploy_key ubuntu@$h \
      'sudo rm -f /opt/aeron/benchmarks-dist/scripts/java-options.env'
  fi
done
```

Run Java echo 101K:

```bash
cd /opt/aeron/benchmarks-dist/scripts
AERON_NONVMA_MODES=java \
AERON_BENCHMARK_TARGET=echo \
AERON_BENCHMARK_RATE=101K \
AERON_BENCHMARK_RUNS=1 \
AERON_BENCHMARK_ITERATIONS=3 \
AERON_BENCHMARK_WARMUP=6 \
BENCHMARK_QUIET_RESTORE=0 \
BENCHMARK_DEEP_QUIET=1 \
MATRIX_CLEANUP_COOLDOWN_SEC=45 \
./run-benchmark-non-vma.sh echo
```

Run Java echo 1001K:

```bash
cd /opt/aeron/benchmarks-dist/scripts
AERON_NONVMA_MODES=java \
AERON_BENCHMARK_TARGET=echo \
AERON_BENCHMARK_RATE=1001000 \
AERON_BENCHMARK_RUNS=1 \
AERON_BENCHMARK_ITERATIONS=3 \
AERON_BENCHMARK_WARMUP=6 \
BENCHMARK_QUIET_RESTORE=0 \
BENCHMARK_DEEP_QUIET=1 \
MATRIX_CLEANUP_COOLDOWN_SEC=45 \
./run-benchmark-non-vma.sh echo
```

Treat `valid_runs=0` or `.hdr.FAIL` as a failed run, not latency data.

## Results

### Java Echo 101K, Spread Pins, 5 Repeats

Result root:

```text
/home/ubuntu/benchmark-results/java-default-repeat-20260511T-java-echo-101k-spreadpins-5x
```

| rep | p50 us | p99 us | p99.9 us | p99.99 us | max us |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 51.263 | 55.519 | 62.335 | 118.527 | 202.751 |
| 2 | 51.327 | 55.455 | 62.111 | 123.903 | 361.727 |
| 3 | 51.359 | 58.911 | 65.311 | 115.263 | 188.031 |
| 4 | 51.423 | 57.087 | 62.751 | 89.215 | 141.311 |
| 5 | 51.295 | 57.055 | 64.255 | 86.783 | 144.127 |

Recommended Java 101K pattern:

```text
default JVM options, no java-options.env, echo spread pins 8/10/12/14, warmup=6, iterations=3, cooldown=45s
```

### Java Echo 1001K, Spread Pins

Result root:

```text
/home/ubuntu/benchmark-results/java-default-repeat-20260511T-java-echo-1001k-spreadpins-3x
```

| rep | valid | p50 us | p99 us | p99.9 us | p99.99 us | max us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 57.887 | 69.951 | 90.495 | 114.111 | 184.447 |
| 2 | 1 | 57.503 | 70.719 | 92.031 | 110.079 | 200.447 |
| 3 | 1 | 60.287 | 88.063 | 1754.111 | 3024.895 | 3254.271 |

Strict profile with longer warmup/iterations/cooldown:

```text
/home/ubuntu/benchmark-results/java-default-repeat-20260511T-java-echo-1001k-spreadpins-w10-i5-c120-3x
```

| rep | valid | p50 us | p99 us | p99.9 us | p99.99 us | max us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0 | | | | | |
| 2 | 1 | 57.087 | 72.383 | 110.143 | 177.919 | 372.223 |
| 3 | 1 | 57.823 | 69.823 | 91.071 | 174.847 | 211.583 |

Recommendation for 1001K: use the same spread-pin pattern, but require at least three valid repeats and discard `.hdr.FAIL` runs. Two of three normal runs and two of two valid strict runs were in the expected sub-200 us p99.9 band, but the high-rate Java case still shows occasional non-repeatable tail events.

## Failed JVM Profiles

The following Java-only overrides were tested at 101K and were worse than the default JVM profile:

| profile | p50 us | p99 us | p99.9 us | max us |
| --- | ---: | ---: | ---: | ---: |
| parallel_nogclog | 53.791 | 1844.223 | 3026.943 | 3504.127 |
| epsilon | 53.599 | 1560.575 | 2996.223 | 3446.783 |
| zgc | 53.727 | 386.815 | 2897.919 | 3895.295 |

Keep the default Java options unless a future test isolates a JVM flag with repeatable benefit. C is unaffected by these Java-only files and options.
