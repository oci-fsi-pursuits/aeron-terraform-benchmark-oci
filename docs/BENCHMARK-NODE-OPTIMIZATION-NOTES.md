# Benchmark node optimization notes (live)

Date: 2026-03-31
Scope: Echo optimization first (cluster follows after echo baseline is healthy)

## Inventory snapshot (client + receiver)

- Shape: `VM.Standard.E5.Flex`
- AD/region: `PHX-AD-2` / `phx`
- CPU topology: `10 vCPU`, `Thread(s) per core = 1`, `NUMA node(s) = 1`, valid CPU IDs `0-9`
- NIC/path: `enp0s9` on both nodes
- Baseline kernel knobs observed:
  - `net.core.rmem_max=4194304`
  - `net.core.wmem_max=4194304`
  - `net.core.netdev_max_backlog=30000`
  - `kernel.numa_balancing=0`
  - firewall policy was already permissive for benchmark path

Inventory files:
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/inventory-client.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/inventory-receiver.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/interrupts-client.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/interrupts-receiver.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/irq-affinity-client-before.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/irq-affinity-receiver-before.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/irq-affinity-client-exp14.txt`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/irq-affinity-receiver-exp14.txt`

## Phase 2 observations (IRQ/RPS)

- NIC appears as `mlx5` with queues `mlx5_comp0..9` and interrupts already spread across CPUs.
- Queue settings before tuning:
  - `rps_cpus` all `000` (disabled)
  - `rps_sock_flow_entries=0`
  - `rps_flow_cnt` all `0`
  - `xps_cpus` already one-CPU-per-tx-queue (`001`, `002`, ... `200`)
- Controlled A/B showed enabling RPS/RFS increased tail latency for this echo workload.

## Echo canonical test used for A/B

- Script: `wrapper-echo-unified.sh`
- Canonical load case for comparisons: `MESSAGE_LENGTH=288`, `MESSAGE_RATE=101K`, `RUNS=1`, `ITERATIONS=10`, `WARMUP_ITERATIONS=3`
- Percentiles below are from the Hdr histogram in each run log (`p50/p99/p999`).

## Experiment log

| Experiment | Key change(s) | p50 (us) | p99 (us) | p999 (us) | Result |
|---|---|---:|---:|---:|---|
| baseline-java-101k-288 | `java vs java` | 634.879 | 1020.415 | 1041.919 | Baseline |
| exp1-cc-101k-288 | `c vs c` | 633.855 | 926.207 | 969.727 | Tail improved, median unchanged |
| exp2-cc-namediface-101k-288 | attempted named iface | 646.143 | 975.871 | 1015.807 | No benefit (channels still IP/prefix) |
| exp3-cvma-101k-288 | `c_vma vs c_vma` | 637.439 | 918.527 | 965.119 | Tail improved, median unchanged |
| exp4-cvma-25k-288 | reduced rate to 25K | 166.527 | 175.743 | 187.775 | Large improvement, but different load |
| exp5-cvma-25k-32 | reduced payload to 32B | 1453.055 | 2744.319 | 2750.463 | Rejected (severe regression) |
| exp6-cvma-101k-288-sysctl50 | sysctl A/B + `c_vma` at same 101K | 165.119 | 177.535 | 189.311 | **Major win at canonical load** |
| exp7-cvma-101k-288-busy200 | busy knobs 200/200 vs 50/50 | 166.271 | 177.791 | 191.103 | Slightly worse than exp6 |
| exp8-cvma-101k-288-sysctl50-confirm | confirmation rerun at busy 50 | 167.935 | 185.087 | 209.279 | Win reproduced (with run-to-run variance) |
| exp9-cvma-101k-288-rps-on | enabled RPS/RFS on all rx queues | 169.471 | 185.215 | 218.495 | Rejected (worse tails) |
| exp10-cvma-101k-288-pin-6789 | moved app pins to cores 6/7/8/9 | 165.503 | 181.887 | 204.927 | Similar p50, worse tails vs exp6 |
| exp11-cvma-101k-288-coalesce0 | NIC coalesce low-latency (`rx/tx-usecs=0`, adaptive off) | 165.887 | 180.095 | 202.111 | No clear win vs exp6 |
| exp12-cvma-101k-288-mtu1408 | MTU reduced from 8K to 1408 | 164.479 | 176.127 | 188.799 | Best single run (small margin) |
| exp13-cvma-101k-288-mtu1408-confirm | MTU 1408 confirm rerun | 166.399 | 179.327 | 191.615 | Improvement not stable enough to call clear win |
| exp14-cvma-101k-288-irqseg-pin6789 | IRQs pinned to 0-3, app pins on 6-9, taskset 4-9 | 166.143 | 177.919 | 189.439 | Near-best tails, no clear p50 gain |
| exp15-cvma-101k-288-mtu1408-buf256k | reduced socket/window buffers to 256k | 167.423 | 179.967 | 196.991 | Rejected |
| exp16-cvma-101k-288-mtu1408-noiface | endpoint-only channels (omit `|interface=`) | 165.247 | 179.711 | 198.527 | Mixed, no clear win |
| exp17-cvma-101k-288-mtu1408-buf4m | increased socket/window buffers to 4m | 166.015 | 186.367 | 222.591 | Rejected |
| exp18-cvma-101k-288-mtu1408-busy0 | `busy_poll/read=0` | 631.807 | 962.047 | 1000.959 | Strong regression (critical) |
| exp19-cvma-101k-288-mtu1408-busy25 | `busy_poll/read=25` | 166.655 | 177.919 | 191.487 | Slightly worse than 50 |
| exp20-cc-101k-288-mtu1408-busy50 | `c vs c` with tuned kernel/mtu | 168.575 | 180.607 | 194.047 | Slightly worse than tuned `c_vma` profile |
| exp21-cefvi-101k-288-mtu1408 | attempted `c-ef-vi` mode | n/a | n/a | n/a | Wrapper does not support this mode string |
| exp22-cdpdk-101k-288-mtu1408 | attempted `c-dpdk` mode | n/a | n/a | n/a | Did not complete cleanly; transport not production-ready here |
| exp23-cvma-xlio-real-8k | first true XLIO preload attempt (`LD_PRELOAD=/lib/libxlio.so`) | n/a | n/a | n/a | Stalled in onload path; no usable histogram |
| exp24-cvma-xlio-appwrap-8k | XLIO preload applied to app process path | n/a | n/a | n/a | Server-start flow still hung; no completed output |
| exp25-cc-control-8k-short | short control `c vs c` @ 8K (`ITERATIONS=2`) | 167.167 | 186.111 | 218.367 | Control check only (short run) |
| exp26-cvma-env-8k-short | short control `c_vma` with no-op env wrapper | 167.679 | 188.031 | 220.671 | Control check only (short run) |
| exp27-cvma-xlio-8k-short | short XLIO preload attempt before pinning fix | n/a | n/a | n/a | Hung during thread pin wait in onload mode |
| exp28-cvma-xlio-8k-short-pinfix | short XLIO preload with onload-thread-pin skip | n/a | n/a | n/a | Completed wrapper flow, but no client HDR produced |
| exp29-cvma-env-101k-288-8k | canonical full run `c_vma` no-op env @ 8K | 168.191 | 188.159 | 211.455 | Valid 8K baseline for current c_vma path |
| exp30-cc-101k-288-8k | canonical full run `c vs c` @ 8K | 165.247 | 177.535 | 197.503 | Best 8K result in latest matrix |
| exp31-java-java-101k-288-8k | canonical full run `java vs java` @ 8K | 165.375 | 183.935 | 212.479 | Competitive median, weaker tails than c/c |
| exp32-cc-101k-288-8k-maxmsg4 | `c vs c` @ 8K with `AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND=4` | 168.191 | 180.735 | 193.791 | Rejected (median/tails worse than exp30) |
| exp33-cc-101k-288-8k-tryclaim-false | `c vs c` @ 8K with `USE_TRY_CLAIM=false` | 168.063 | 181.375 | 202.495 | Rejected (worse than exp30) |
| exp34-cvma-vma9-8k-short | legacy VMA preload (`LD_PRELOAD=/lib/x86_64-linux-gnu/libvma.so.9`) | n/a | n/a | n/a | Timed out (wrapper exit 124) |
| exp35-cvma-vma9-debug-8k-short | legacy VMA preload + debug logs (`VMA_TRACELEVEL=4`) | n/a | n/a | n/a | Timed out; VMA logs show offload denied under unprivileged Java |
| exp36-cvma-vma9-filecap-8k-short | set file capability (`setcap cap_net_raw+ep` on java) + VMA preload | 165.375 | 180.991 | 220.671 | Completed, but likely invalid offload signal (secure-exec likely strips LD_PRELOAD on file-cap binary) |
| exp37-cvma-vma9-sudoenv-8k-short | VMA preload via `sudo -E env ...` to force privileged launch | n/a | n/a | n/a | Timed out (wrapper exit 124), Java processes remained hung |
| exp38-cvma-vma9-sudoenv-prlimit-8k-short | `sudo -E prlimit --memlock=unlimited:unlimited -- env ...` | n/a | n/a | n/a | Timed out (wrapper exit 124), no benchmark completion |
| exp39-cc-8k-control-short | short control `c vs c` @ 8K (`ITERATIONS=2`) | n/a | n/a | n/a | Timed out while stale root-owned `/dev/shm/*-gc.log` blocked Java startup |
| exp39b-cc-8k-control-short | retry control after partial cleanup | n/a | n/a | n/a | Timed out for same reason (`Permission denied` writing GC log in `/dev/shm`) |
| exp39c-cc-8k-control-short | recovered short control after `/dev/shm` ownership cleanup | 165.503 | 179.455 | 197.759 | Recovered baseline path; still slower tails than exp30 |
| exp40-cc-8k-noiface-short | attempted unset of `AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH` | 165.503 | 181.375 | 210.815 | Rejected (tails regressed; channel still resolved with explicit interface values) |
| exp41-cc-8k-50k-short | reduced rate to `50K` (screening run) | 165.759 | 184.959 | 235.519 | Rejected (tails worse despite lower load) |
| exp42-cc-8k-1m-bufs-short | reduced socket/window buffers to `1m` | 167.295 | 183.807 | 224.127 | Rejected (median/tails worse) |
| exp43-cc-8k-maxmsg2-short | `AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND=2` | 165.887 | 178.687 | 199.167 | Rejected (near baseline but no improvement vs exp30) |
| exp44-cc-8k-10k-short | reduced rate to `10K` (floor probe) | 167.295 | 180.607 | 193.279 | Rejected (did not lower median; double-digit target not approached) |
| exp45-cc-8k-full-confirm1 | canonical full run `c vs c` @ 8K confirm pass 1 | 165.503 | 177.791 | 193.663 | Near-best tails; still same ~165us median floor |
| exp46-cc-8k-full-confirm2 | canonical full run `c vs c` @ 8K confirm pass 2 | 165.503 | 178.815 | 194.815 | Slightly weaker tails than exp45/exp30 |
| exp47-cc-8k-full-confirm3 | canonical full run `c vs c` @ 8K confirm pass 3 | 165.759 | 180.607 | 201.087 | Rejected (tail regression) |
| exp48-cc-8k-full-coalesce0 | canonical full run with `adaptive off`, `rx/tx-usecs=0`, `rx/tx-frames=1` | 166.399 | 183.551 | 198.143 | Rejected (worse median/tails) |
| exp49-cc-8k-full-busy100 | canonical full run with `net.core.busy_poll/read=100` | 166.271 | 181.247 | 196.863 | Rejected (worse than best at busy=50) |
| exp50-cc-8k-full-busy50-recheck | canonical full run after restoring `busy_poll/read=50` | 164.863 | 177.279 | 191.743 | Best single run in this batch (not yet stable) |
| exp51-cc-8k-full-busy50-recheck2 | second immediate repeat at `busy_poll/read=50` | 166.015 | 184.831 | 211.711 | Rejected (large tail variance vs exp50) |
| exp52-cc-8k-full-irq03-app69 | IRQ split (`mlx5*` on cores `0-3`) + app cores `6-9` + pins `8/9` | 168.575 | 185.983 | 210.431 | Rejected (significant regression) |
| exp53-cc-8k-full-irq03-app69-repeat | repeat of IRQ/app-core split profile | 166.655 | 180.479 | 198.655 | Still worse than baseline best |
| exp54-cc-8k-full-ring256 | NIC ring depth reduced (`rx=256`, `tx=256`) | 166.143 | 180.863 | 199.551 | Mixed, not a stable improvement |
| exp55-cc-8k-full-ring256-repeat | repeat with ring depth `256` | 165.247 | 176.895 | 189.439 | Strong single run (best p999 so far) |
| exp56-cc-8k-full-ring256-confirm | third ring-depth `256` confirmation | 169.727 | 185.727 | 210.815 | Rejected (severe regression; unstable) |
| exp57-cc-8k-full-busy25 | canonical full run with `busy_poll/read=25` | 165.503 | 177.919 | 192.895 | Close, but no clear win over stable `busy=50` envelope |
| exp58-cc-8k-full-ring512 | NIC ring depth reduced (`rx=512`, `tx=512`) | 167.935 | 183.295 | 200.831 | Rejected (median/tails regressed) |
| exp59-cc-8k-full-ring512-repeat | repeat with ring depth `512` | 166.015 | 178.815 | 192.639 | Competitive but not better than best `busy=50` runs |
| exp80-cc-9k-short | short probe with `MTU_VALUE=9K` (`aeron.mtu.length=9216`) | 165.887 | 185.983 | 222.847 | Rejected (tails clearly worse than 8K profile) |
| exp81-cc-8k-full-core1to9 | full run with app cpuset `1-9` (reserve CPU0) | 165.247 | 178.431 | 194.815 | Competitive but not better than best post-reboot baseline |

Run logs:
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-baseline-java.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp1-cc.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp2-cc-namediface.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp3-cvma.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp4-cvma-25k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp5-cvma-32b-25k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp6-cvma-sysctl.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp7-cvma-sysctl-busy200.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp8-cvma-sysctl50-confirm.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp9-cvma-rps-on.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp10-cvma-pin-6789.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp11-cvma-coalesce0.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp12-cvma-mtu1408.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp13-cvma-mtu1408-confirm.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp14-cvma-irqseg-pin6789.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp15-cvma-mtu1408-buf256k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp16-cvma-mtu1408-noiface.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp17-cvma-mtu1408-buf4m.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp18-cvma-mtu1408-busy0.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp19-cvma-mtu1408-busy25.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp20-cc-mtu1408-busy50.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp21-cefvi-mtu1408.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp22-cdpdk-mtu1408.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp23-cvma-xlio-real-8k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp24-cvma-xlio-appwrap-8k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp25-cc-control-8k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp26-cvma-env-8k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp27-cvma-xlio-8k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp28-cvma-xlio-8k-short-pinfix.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp29-cvma-env-8k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp30-cc-8k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp31-jj-8k.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp32-cc-8k-maxmsg4.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp33-cc-8k-tryclaim-false.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp34-cvma-vma9-8k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp35-cvma-vma9-debug.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp36-cvma-vma9-capnetraw.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp37-cvma-vma9-sudoenv.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp38-cvma-vma9-sudoenv-prlimit.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp39-cc-8k-control-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp39b-cc-8k-control-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp39c-cc-8k-control-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp40-cc-8k-noiface-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp41-cc-8k-50k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp42-cc-8k-1m-bufs-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp43-cc-8k-maxmsg2-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp44-cc-8k-10k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp45-cc-8k-full-confirm1.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp46-cc-8k-full-confirm2.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp47-cc-8k-full-confirm3.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp48-cc-8k-full-coalesce0.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp49-cc-8k-full-busy100.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp50-cc-8k-full-busy50-recheck.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp51-cc-8k-full-busy50-recheck2.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp52-cc-8k-full-irq03-app69.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp53-cc-8k-full-irq03-app69-repeat.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp54-cc-8k-full-ring256.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp55-cc-8k-full-ring256-repeat.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp56-cc-8k-full-ring256-confirm.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp57-cc-8k-full-busy25.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp58-cc-8k-full-ring512.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp59-cc-8k-full-ring512-repeat.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp80-cc-9k-short.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp81-cc-8k-full-core1to9.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp82-cc-8k-full-locksweep-core1to9.log` ... `echo-exp91-cc-8k-full-locksweep-core1to9.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp60-cc-8k-full-sweep-pre-reboot.log` ... `echo-exp69-cc-8k-full-sweep-pre-reboot.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp70r-cc-8k-full-post-reboot-baseline.log` ... `echo-exp74r-cc-8k-full-post-reboot-baseline.log`
- `/home/ubuntu/benchmark-results/optimization-2026-03-29/echo-exp75r-cc-8k-full-post-reboot-core2to9.log` ... `echo-exp79r-cc-8k-full-post-reboot-core2to9.log`

## What worked

1. **Kernel poll/backlog tuning plus C+VMA path** produced the biggest gain at the same 101K/288 load.
   - Best observed at canonical load: `p50 ~165us`, `p99 ~178us`, `p999 ~189us`.
2. Busy poll/read beyond that (`200`) did not improve over the lower setting tested (`50`).
3. Keeping RPS/RFS disabled (`rps_cpus=000`, `rps_sock_flow_entries=0`) outperformed enabling them for this workload.
4. NIC coalescing override (`adaptive off`, `usecs=0`) did not beat baseline tails consistently; default coalescing remains safer.
5. `busy_poll/read` are high impact:
   - disabling (`0`) causes a major regression back to ~baseline latency.
   - `25` is slightly worse than `50`.
6. In this environment, `c_vma` currently behaves as `c-onload` wrapper mode **without** actual Onload binary on hosts, so the expected hardware-accelerated path is not active.
7. In the refreshed `8K` full-run matrix, `c/c` is currently the best reproducible profile:
   - `exp30`: `p50=165.247us`, `p99=177.535us`, `p999=197.503us`.
8. VMA debug runs produced a concrete gate condition:
   - Under unprivileged Java, VMA logs show `QP creation failed ... Operation not permitted` and `will not be offloaded`.
   - This is a real, reproducible blocker for the legacy VMA offload path on the current launch model.
9. Recovery guardrail after VMA privilege tests:
   - stale root-owned `/dev/shm/*-gc.log` and `/dev/shm/*-crash.log` can silently break non-VMA runs with JVM startup `Permission denied`;
   - cleanup restored non-VMA run health (`exp39c` completed normally).
10. Non-VMA 8K short-screening after recovery did not beat existing best (`exp30`):
   - interface-prefix unset attempt, lower socket buffers, lower message rates, and `max_messages_per_send=2` were all non-improving.
11. Full canonical `c/c` re-confirmation remains in the same latency band:
   - `exp45-47` stayed around `p50 ~165-166us`, with best observed tails at `exp45 (p99=177.791us, p999=193.663us)`;
   - this confirms a persistent floor around mid-100us in current non-VMA environment.
12. Additional non-VMA full-run A/B (coalescing and busy-poll) outcomes:
   - forcing aggressive coalescing (`usecs=0`, adaptive off) regressed (`exp48`);
   - increasing busy poll/read from `50` to `100` regressed (`exp49`);
   - a single strong run appeared at restored `busy=50` (`exp50`), but immediate repeat (`exp51`) reverted with large tail variance, so it is not yet a stable new baseline.
13. Further contention and ring-depth probes:
   - IRQ-on-low-cores plus app-on-high-cores profile (`exp52/53`) did not help in `c/c` 8K;
   - reduced ring depth (`256`) produced one excellent outlier (`exp55`) but failed to reproduce (`exp54`, `exp56`);
   - `busy_poll/read=25` (`exp57`) remained close but did not consistently beat the best `busy=50` outcomes.
14. Ring-depth midpoint check (`512`) also did not produce a stable gain:
   - `exp58` regressed noticeably; `exp59` recovered to competitive but still not better-than-best.

## Reboot + stability sweep checkpoint (echo, 8K, non-VMA)

Verification that workload is still **echo** (not cluster):
- Run artifacts and class names continue to show echo path:
  - `Histogram [aeron-echo_...]`
  - `io.aeron.benchmarks.LoadTestRig`
  - `io.aeron.benchmarks.aeron.EchoNode`

Post-reboot incident and fix:
- Immediately after reboot, runs timed out with:
  - `Failed to connect within timeout of 60000000000ns`
- Root cause: host firewall reverted to default reject chain (`INPUT ... REJECT`) and blocked peer benchmark traffic.
- Fix applied on both nodes:
  - inserted peer allow rules for `172.16.5.23` and `172.16.6.116` at top of `INPUT`.

Sweep groups and outcomes:
- Pre-reboot baseline sweep (`exp60`-`exp69`, 10 full runs):
  - `p50`: min `165.503`, median `166.143`, max `167.935`
  - `p99`: min `178.175`, median `178.879`, max `183.551`
  - `p999`: min `191.231`, median `198.207`, max `207.615`
- Post-reboot baseline sweep (`exp70r`-`exp74r`, 5 full runs):
  - `p50`: min `164.991`, median `164.991`, max `166.655`
  - `p99`: min `177.023`, median `177.407`, max `181.247`
  - `p999`: min `187.135`, median `190.975`, max `197.503`
- Post-reboot reduced core-set sweep (`exp75r`-`exp79r`, app cpuset `2-9`, pins `8/9`):
  - `p50`: min `165.119`, median `165.631`, max `166.399`
  - `p99`: min `175.615`, median `179.327`, max `181.631`
  - `p999`: min `188.415`, median `191.487`, max `207.359`

Interpretation:
- Reboot + firewall correction improved baseline stability envelope vs pre-reboot.
- Reducing cpuset width to `2-9` can produce occasional better tails (`p99`), but stability is weaker (`p999` outlier to `207.359`).
- Best current reproducible direction remains baseline post-reboot profile with `busy_poll/read=50`, default ring/coalescing, and firewall peer allows present.

## AWS guide cross-check highlights (relevant to current drift)

- The guide states that for jumbo NIC MTU (~9000), Aeron MTU should be set to **8KB** (not higher), because some channels/term-buffer configurations are incompatible above 8KB.
- The guide also emphasizes boot-time CPU isolation (`isolcpus`, `nohz_full`) and dedicated core sets as a prerequisite for low jitter.
- In this environment, `MTU_VALUE=9K` mapped to `aeron.mtu.length=9216` and did not help (`exp80` tails regressed).

## Locked profile sweep (recommended baseline candidate)

Profile under test:
- `MTU_VALUE=8K` (NIC MTU remains `9000`)
- `CLIENT_MODE=c`, `SERVER_MODE=c`
- `net.core.busy_poll=50`, `net.core.busy_read=50`
- NIC coalescing default-adaptive (`rx/tx-usecs=8`, `rx/tx-frames=128`)
- NIC rings `rx=1024`, `tx=1024`
- app cpuset `1-9` (leave CPU0 for housekeeping), pin main app threads to `8/9`
- host firewall includes explicit peer allow rules for benchmark nodes

Runs:
- `exp82` ... `exp91` (10 full runs, canonical 101K/288)

Per-run metrics:
- `exp82`: `p50=165.119`, `p99=177.023`, `p999=188.671`
- `exp83`: `p50=166.271`, `p99=178.687`, `p999=191.871`
- `exp84`: `p50=164.735`, `p99=174.335`, `p999=189.951`
- `exp85`: `p50=165.247`, `p99=178.431`, `p999=194.431`
- `exp86`: `p50=165.503`, `p99=179.071`, `p999=202.111`
- `exp87`: `p50=165.375`, `p99=177.151`, `p999=188.543`
- `exp88`: `p50=165.247`, `p99=178.303`, `p999=193.279`
- `exp89`: `p50=165.887`, `p99=178.431`, `p999=191.615`
- `exp90`: `p50=165.247`, `p99=177.791`, `p999=191.615`
- `exp91`: `p50=165.119`, `p99=176.255`, `p999=189.311`

Stability summary for `exp82-91`:
- `p50`: min `164.735`, median `165.247`, max `166.271`
- `p99`: min `174.335`, median `178.047`, max `179.071`
- `p999`: min `188.543`, median `191.615`, max `202.111`

Recommendation:
- Use this locked profile as the current non-VMA baseline for Terraform/Ansible encoding.
- Keep `8K` Aeron MTU for jumbo NICs; do not promote `9K` Aeron MTU.

## What did not work / caveats

1. Forcing "named interface" via env var alone did not change effective channels in this run because explicit channel env values were already populated from config.
2. Smaller payload (`32B`) under this setup regressed sharply; do not encode that profile for latency targetting.
3. Cluster wrapper still needs CPU-range safety (`0-9` here). A previous cluster run failed when defaults assumed `0-15`.
4. Alternate app pinning (`6/7/8/9`) did not beat the original tail latencies.
5. MTU `1408` showed one slightly better run but did not consistently hold advantage over `8K`; treat as inconclusive for now.
6. Buffer extremes (`256k` or `4m`) both worsened tails versus current settings.
7. Alternative transport paths are not currently usable:
   - `c-ef-vi` not wired through wrapper mode mapping.
   - `c-dpdk` path did not complete cleanly in this image/config.
8. True XLIO preload path is partially wired but not benchmark-valid yet:
   - host packages are installed (`libxlio`, `libxlio-utils`, `sockperf`);
   - onload-mode thread pin waits needed to be bypassed in wrapper flow;
   - XLIO-preloaded runs still fail to produce client HDR results reliably (no stable p50/p99/p999 yet).
9. Legacy VMA path is still not benchmark-valid in current wrapper flow:
   - unprivileged preload path: offload denied by capability gate;
   - file-capability workaround (`setcap cap_net_raw+ep` on `java`) can make runs complete, but is likely not a valid offload configuration because Linux secure-exec may sanitize `LD_PRELOAD`;
   - privileged launch attempts (`sudo -E env ...`, with/without `prlimit --memlock=unlimited`) still hang in this Aeron flow.
10. Post-privileged-run state contamination caveat:
   - after sudo-based launch attempts, `/dev/shm` log files can become root-owned;
   - later non-sudo Java starts may fail with:
     - `Could not rename log file '/dev/shm/echo-*-gc.log' ... Operation not permitted`
     - `Error opening log file '/dev/shm/echo-*-gc.log': Permission denied`
   - this can look like benchmark "stalling" unless `/dev/shm` ownership/log cleanup is performed first.

## Candidate changes to encode in Ansible/Terraform next

### 1) Sysctl defaults for benchmark nodes (client + receiver)

Tested effective knobs associated with improvements:
- `net.core.netdev_max_backlog=100000`
- `net.core.busy_poll=50`
- `net.core.busy_read=50`

Notes:
- Keep these benchmark-node scoped first (not controller by default).
- Apply with persistent `sysctl.d` drop-in + `sysctl --system` for idempotency.
- Re-test with/without `busy_poll/busy_read` in one extra confirm run before finalizing.

### 2) Driver mode defaults for latency profile

- For low-latency profile runs, prefer `CLIENT_MODE=c_vma` and `SERVER_MODE=c_vma` (or at least `c/c`) over `java/java`.
- Keep profile-specific mapping (do not force all matrices yet).

### 3) RPS/RFS policy

- Keep RPS/RFS off for this benchmark path unless a future run proves otherwise:
  - `net.core.rps_sock_flow_entries=0`
  - `/sys/class/net/enp0s9/queues/rx-*/rps_flow_cnt=0`
  - `/sys/class/net/enp0s9/queues/rx-*/rps_cpus=000`
- IRQ and queue distribution is already spread across CPUs on `mlx5_comp0..9`, so software fanout added overhead.

### 4) CPU mask safety in wrappers/templates

- Any generated/default CPU set must validate against detected vCPU count.
- In this environment valid mask is `0-9`; avoid hardcoded `0-15` for cluster path.

### 5) Channel rendering cleanup

- If using named interface `{enp0s9}`, ensure wrapper does not silently keep old explicit channel vars.
- Option: in named-interface mode, rebuild channels unless user explicitly overrides in command line.

## Placement / topology evidence

- Client and receiver metadata confirm parity on:
  - `availabilityDomain = pILZ:PHX-AD-2`
  - `faultDomain = FAULT-DOMAIN-3`
  - `shape = VM.Standard.E5.Flex`
  - `ocpus = 10`, `memoryInGBs = 64`
- Explicit cluster placement group membership is still **not verified** from controller because OCI CLI is unavailable (`oci: command not found`).

## Current temporary runtime state

Current sysctl values observed after A/B runs:
- `net.core.netdev_max_backlog=100000`
- `net.core.busy_poll=50`
- `net.core.busy_read=50`
- `net.core.rps_sock_flow_entries=0`

I increased to 200 only for A/B (exp7), then reverted to 50 and confirmed the improvement again (exp8).

Current NIC coalescing state (both nodes):
- `Adaptive RX/TX: on`
- `rx-usecs=8`, `rx-frames=128`
- `tx-usecs=8`, `tx-frames=128`

Current IRQ affinity state (both nodes):
- `mlx5_comp0..9` mapped one queue per CPU (`0..9`)
- `mlx5_async0` mapped to `0-9`
- Java binary file capabilities:
  - `cap_net_raw` was tested temporarily on `/usr/lib/jvm/java-17-openjdk-amd64/bin/java` for experiment `exp36`.
  - capability was removed after test (`setcap -r`) to avoid persistent secure-exec side effects on preload behavior.

## Next optimization passes (recommended)

1. Lock in sysctl at `busy_{poll,read}=50` and rerun 3x to confirm stability (same canonical case).
2. Validate placement group membership in OCI API/console (AD/FD are confirmed; placement group still pending API evidence).
3. Once echo is stable, run cluster tuning passes (archive/fsync/backup) using only proven echo sysctl knobs.
4. Enable a real accelerated userspace NIC path (Onload or validated DPDK/EF_VI image) before expecting double-digit microseconds on this shape.
5. Finish XLIO path bring-up by validating client-side output generation under `LD_PRELOAD=/lib/libxlio.so` and then rerun canonical 8K matrix.
6. For legacy VMA viability, run one dedicated launch-model fix pass:
   - make preload path explicit in wrapper scripts (avoid helper command contamination),
   - gather definitive in-flight evidence (`/proc/<java_pid>/maps` contains `libvma.so` + VMA debug line showing offload-capable interface count),
   - only then compare VMA-on vs c/c in canonical 8K run.

## Cluster validation checkpoint

- Short cluster run completed successfully with corrected CPU masks:
  - log: `/home/ubuntu/benchmark-results/optimization-2026-03-29/cluster-exp1-short.log`
  - launch settings included `CLUSTER_AERON_SSH_TASKSET_CPUS=0-9` and nonisolated `0-9`.
- This confirms the previous cluster startup failure was tied to invalid CPU mask defaults (`0-15`) on 10-vCPU nodes.
