# Benchmark node optimization handoff (for ops / tuning agent)

This document is for an agent or engineer with **SSH access** to the Aeron benchmark stack on **Oracle Cloud Infrastructure (OCI)**. Goal: **tune client and receiver VMs** for minimum echo (and optionally cluster) latency, then **return concrete changes** so the Terraform/Ansible maintainer can codify them in `aeron-terraform-oci`.

## Context

- **Stack:** `aeron-terraform-oci` — Terraform provisions instances; **Ansible** (via provisioners) configures Aeron, aeron-io/benchmarks, sysctl, optional host firewall, `/etc/hosts`, wrapper scripts, and `benchmark-config.env`.
- **Benchmarks:** Remote echo and cluster matrices run from the **controller** (`run_driver_matrix` → `run-driver-matrix.sh`), pushing results under `~/benchmark-results/` on the controller.
- **Reference target (internal):** Ethernet echo **P50 ~30–36 µs** (Java / C / C+VMA) on **E6-class**, **8 OCPU (16 vCPU)**, **96 GB**, **placement group**, same AD — profile and driver path must be **apples-to-apples** when comparing.
- **Important:** Ansible does **not** sit in the datapath during benchmarks; it **sets** kernel, firewall, and config. Latency gaps vs reference are usually **shape + placement + sysctl + NIC + benchmark profile + pinning**, not “Ansible overhead.”

## Current deployment snapshot (fill if different)

Use this as the baseline the tuning agent should record and preserve.

| Role | Host access | Private IP | OCPUs (Terraform) | Notes |
|------|-------------|------------|-------------------|--------|
| Controller | `ssh ubuntu@<controller_public_ip>` | e.g. `172.16.0.117` | 2 | Runs matrix; not echo datapath |
| Client (benchmark-1) | `ssh -J ubuntu@<controller_public_ip> ubuntu@172.16.6.116` | `172.16.6.116` | 10 | Echo/cluster client |
| Receiver (benchmark-2) | `ssh -J ... ubuntu@172.16.5.23` | `172.16.5.23` | 10 | Echo/cluster receiver |
| Failover | `ssh -J ... ubuntu@172.16.4.23` | `172.16.4.23` | 10 | Cluster backup path only |

From last apply output (example):

- **Placement:** user confirms **same AD** as reference (e.g. AD-2); **placement group** should be verified in OCI API/console (not only AD).
- **`hyperthreading`** (Terraform / Ansible): `false` → **10 OCPU = 10 vCPU** (no SMT doubling). Reference slide used **8 OCPU / 16 vCPU** — document whether SMT was on there; **mismatch affects pinning and `numactl` ranges**.
- **VCN / subnets:** benchmark nodes on private subnet; UDP **12000–65535** NSG ingress+egress + security lists + optional **iptables** `INPUT` ACCEPT for same range from VCN CIDR.

## Phase 1 — Inventory (run on client and receiver)

Run and **save outputs** to files (e.g. `/tmp/inventory-client.txt`, `/tmp/inventory-receiver.txt`).

### 1.1 Instance metadata (shape, region, AD)

```bash
# OCI instance metadata (path may vary slightly by image)
sudo curl -sS -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq '.' || true
```

Capture: `shape`, `shapeConfig.ocpus`, `shapeConfig.memoryInGBs`, `availabilityDomain`, `region`, `compartmentId`, `id`.

### 1.2 CPU / NUMA / isolation

```bash
lscpu
lscpu -e
grep -E . /sys/devices/system/cpu/cpu*/topology/thread_siblings_list 2>/dev/null | head -20
numactl --hardware 2>/dev/null || true
```

Note: with **`hyperthreading=false`** in this stack, expect **1 thread per core**; pinning in wrappers must stay within **0–(vCPU-1)**.

### 1.3 Kernel / governor / power (read-only first)

```bash
uname -a
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
cpupower frequency-info 2>/dev/null || true
```

### 1.4 Networking

```bash
ip -br a
ip route
ethtool -i $(ip route get 172.16.5.23 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') 2>/dev/null
ethtool -k $(ip route get 172.16.5.23 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') 2>/dev/null | head -100
```

(Run `ip route get` toward the **peer** private IP from each node.)

### 1.5 Sysctl (current effective values)

```bash
sysctl -a 2>/dev/null | grep -E '^(net\.|vm\.|kernel\.)' | sort > /tmp/sysctl.snapshot.txt
# Also print Aeron-relevant subset:
sysctl net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
  net.core.netdev_max_backlog net.ipv4.udp_mem net.ipv4.ip_local_port_range \
  vm.swappiness vm.zone_reclaim_mode kernel.numa_balancing 2>/dev/null
```

### 1.6 Firewall

```bash
sudo iptables -L INPUT -n -v
sudo nft list ruleset 2>/dev/null | head -80 || true
```

### 1.7 Huge pages / limits (if used)

```bash
grep -E 'Huge|MemAvailable' /proc/meminfo
ulimit -a
```

## Phase 2 — During a short echo (methodology check)

Coordinate a **single** echo run (same driver as reference, e.g. **C** or **C+VMA**), fixed **message length / rate / MTU / iterations** matching the reference doc (not necessarily the full CI matrix).

While the benchmark is running, on **both** client and receiver:

### 2.1 Process pinning

```bash
pgrep -a aeronmd || true
pgrep -af MediaDriver || true
pgrep -af LoadTestRig || true
pgrep -af EchoNode || true
# For each hot PID:
# sudo taskset -cp <pid>
```

Compare to **wrapper / remote-benchmarks** expectations (cores documented in matrix logs).

### 2.2 Soft interrupts / drops (quick sample)

```bash
grep -E 'CPU|net:' /proc/softirqs | head -5
ip -s link
```

## Phase 3 — Controlled experiments (document each A/B)

Change **one class at a time**; re-run the **same** short echo scenario; record **P50 / P99 / p999** (from Hdr output or summary CSV).

Suggested experiment matrix (enable only what is allowed on your tenancy / image):

1. **Sysctl:** socket buffers, `udp_mem`, `netdev_max_backlog`, `busy_read`/`busy_poll` (if applicable to UDP path — validate before enabling).
2. **IRQ / RPS** (if multi-queue and workload benefits — measure; UDP benchmarks can be sensitive).
3. **Application:** JVM flags (GC, huge pages) **only** for Java path; compare **C vs Java** with identical benchmark params.
4. **OCI:** confirm **cluster placement group** membership and **same physical fault domain** as reference slide (console + API).
5. **Hyperthreading / OCPU:** if reference used **16 vCPU from 8 OCPU**, consider a **Terraform** experiment: `hyperthreading=true` with **updated pinning** (Ansible/wrapper) — do **not** only toggle in OS without widening valid CPU ranges.

## Deliverable back to Ansible / Terraform maintainer

Please return a **single markdown or structured report** with:

1. **Summary table:** before vs after **P50/P99/P999** for one canonical echo scenario (driver, length, rate, MTU, runs/iterations).
2. **OCI facts:** shape, OCPU, memory, AD, **placement group OCID/name**, confirmed same group for both benchmark nodes.
3. **Diffs:**
   - `sysctl`: list **full keys and final values** to apply on **client** and **receiver** (note if controller/failover need them too).
   - **iptables/nft:** only if changes beyond current “ACCEPT UDP 12000–65535 from VCN CIDR.”
   - **ethtool:** any stable `ethtool -K` / ring changes (document NIC driver; some are lost on reboot — say if **systemd unit** or **udev** is needed).
   - **GRUB / kernel cmdline / isolcpus / nohz_full** — only with **reboot steps** and **pinning map** for Aeron threads.
4. **Ansible mapping:** for each change, specify:
   - **Role / file** if known: e.g. `playbooks/roles/aeron-install/tasks/main.yml` (sysctl), `aeron-benchmark` (firewall), `variables.tf` / `group_vars` (hyperthreading, `benchmark_ocpus`).
   - **Idempotency** notes (e.g. `sysctl.d` drop-in vs `sysctl -w`).
5. **Out of scope / rejected:** things tried that **hurt** latency or broke benchmarks (so we don’t encode them).

## Files in repo the maintainer will likely edit

- `playbooks/roles/aeron-install/` — sysctl, limits, optional GRUB/isolation.
- `playbooks/roles/aeron-benchmark/` — host firewall, `benchmark-config.env.j2`, wrappers.
- `variables.tf`, `locals.tf`, `compute.tf` — OCPU, `hyperthreading`, `benchmark_ocpus`, matrix env.
- `docs/ECHO-2HOST-ANSIBLE-HANDOFF.md`, `docs/ECHO-BENCHMARK-SSH-DEBUG.md` — operational context.

## Constraints

- Do **not** weaken **security lists / NSG** without documenting risk; prefer **least change** that preserves echo/cluster UDP paths.
- Any **reboot-required** tuning must be called out explicitly for Terraform **instance replace** or runbook steps.
- **Cluster** latency is **not** comparable to echo P50; optimize echo first, then cluster-specific (fsync, archive, backup topology).

---

*Generated for handoff between node-tuning agent and `aeron-terraform-oci` Ansible maintainer.*
