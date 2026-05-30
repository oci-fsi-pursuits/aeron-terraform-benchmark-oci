# Inconsistencies: Quickstart Guide vs Stack / README / Ansible

This document lists mismatches between **aeron-benchmark-quickstart-vm-3** (source of truth) and the current **aeron-terraform-oci** stack (README, Ansible, variables). Resolving these will align the stack with the [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks) workflow and the quickstart.

---

## 1. Benchmark source and build

| Quickstart (source of truth) | Current stack | Inconsistency |
|------------------------------|---------------|----------------|
| Uses **[aeron-io/benchmarks](https://github.com/aeron-io/benchmarks)**: clone, `./gradlew clean deployTar`, extract to `~/benchmarks-dist` | Uses **real-logic/aeron** only: clone, Gradle `assemble`, run Ping/Pong from aeron-samples | **Different benchmark source.** Quickstart uses the official benchmarks repo (LoadTestRig, echo/cluster scenarios, HDR histograms). Stack uses ad‑hoc Ping/Pong scripts. |
| Build product: `build/distributions/benchmarks.tar` → unpack to `benchmarks-dist` on each node | Build product: JARs under `aeron-src/.../build/libs` copied to `lib/`; no `benchmarks.tar` or `benchmarks-dist` | **No benchmarks-dist.** Stack never builds or deploys the benchmarks repo tarball. |
| Run from controller: `~/benchmarks/scripts/` with wrapper scripts (e.g. `wrapper-echo-java-two-nodes.sh`) | Run from controller: `/opt/aeron/run-benchmark.sh` (single-node Ping/Pong only) | **Different run model.** Quickstart: SSH wrappers, 2-node echo, cluster; stack: single-node only, no SSH wrappers. |

---

## 2. Paths and layout

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| Controller: `~/benchmarks` (clone), `~/benchmarks-dist` (optional extract for local run) | Controller: `/opt/aeron`, `/opt/aeron/playbooks` | **Install path.** Quickstart uses home dir; stack uses `/opt/aeron`. |
| Deploy to nodes: `tar -C ~ -xzf` → `~/benchmarks-dist` on each node | Deploy to nodes: playbooks + Ansible run; no `benchmarks-dist` tarball | **No benchmarks-dist on nodes.** Nodes get Ansible roles (aeron from git, custom scripts), not the benchmarks repo distribution. |
| Wrapper scripts live in `~/benchmarks/scripts/` (e.g. `aeron/remote-echo-benchmarks`, wrapper-echo-java-two-nodes.sh) | No wrapper scripts in repo; only `run-benchmark.sh` (Ping/Pong) under `/opt/aeron/benchmark/` | **Missing wrappers.** No `wrapper-echo-*`, `wrapper-cluster-*`, or config‑driven wrappers (e.g. wrapper-echo-unified.sh, benchmark-config.env). |

---

## 3. Node roles and naming

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| Roles: Controller, **Echo Client**, **Echo Server**, Cluster Node0/1/2, **Cluster Backup** | Roles: **Controller**, **Benchmark-1 (client)**, **Benchmark-2 (receiver)**, optional **Failover** | **Naming.** Quickstart: “Echo Client/Server”; stack: “benchmark-1/2 (client/receiver)”. Functionally similar but docs/README should use one convention. |
| Echo = 2 nodes (client + server); Cluster = 3 nodes + backup | Benchmark nodes = 2+ (client + receiver); Failover = 1 in different AD | **Cluster.** Quickstart describes 3-node cluster + backup; stack has no cluster benchmark, only echo-style client/receiver. |

---

## 4. Ansible and automation

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| Pipeline: prepare-nodes → validate-nodes (reboot) → tune-nic → **deploy-artifacts** (benchmarks-dist) → run-benchmarks → aggregate-results | Single playbook: aeron-install (real-logic/aeron + scripts) + aeron-benchmark (run-benchmark.sh, config) | **No benchmarks deploy step.** Stack doesn’t build benchmarks.tar or deploy benchmarks-dist. No prepare/validate/tune/aggregate playbooks. |
| Group vars: `benchmark_nodes` with `java_home`, `housekeeping_cpus`, `isolated_cpus`, `socket_buf`, `message_length`, `message_rate`, Aeron tuning | Group vars: `all` with `aeron_dir`, `aeron_git_repo` (real-logic/aeron), `socket_buf`, `message_length`, `message_rate`, etc. | **No `benchmarks_repo` / `benchmarks_dist_path`.** No vars for aeron-io/benchmarks URL or deploy path. |
| Optional: GRUB CPU isolation drop-in, then **reboot**; validate isolated CPUs | Optional: GRUB drop-in when `grub_dynamic_cpu_isolation` (default true); **no reboot or validate** in playbook | **No post-reboot validation.** Quickstart has validate-nodes after reboot; stack doesn’t. |

---

## 5. Wrapper scripts and config

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| Wrappers: `wrapper-echo-java-two-nodes.sh`, `wrapper-echo-c-two-nodes.sh`, `wrapper-echo-cluster-three-nodes.sh`; invoke `aeron/remote-echo-benchmarks` etc. from **benchmarks repo scripts/** | No wrappers; only custom `run-benchmark.sh` (Ping/Pong) | **Wrappers missing.** Stack doesn’t ship or generate quickstart-style wrappers or the config‑driven ones (e.g. from scripts.zip). |
| Config: SSH_*_NODE, CLIENT_*_BENCHMARKS_PATH, CLIENT_*_CPU_CORE, MESSAGE_LENGTH=288, MESSAGE_RATE=101K, Aeron socket/tuning env vars | Config: `benchmark-config.yml` (YAML) and Ansible vars; no wrapper env file (e.g. benchmark-config.env) | **No benchmark-config.env.** scripts.zip has config-driven wrappers and `config/benchmark-config.env`; stack doesn’t include or template it. |
| Wrapper preflight: tune socket buffers on remote nodes, CPU overlap checks, numactl bind checks | run-benchmark.sh: tune_socket_buffers (local only) | **Preflight.** Quickstart wrappers do remote sysctl and validation; stack script is local-only. |

---

## 6. Results and aggregation

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| Results: HDR histograms (`.hdr`); archives like `aeron-echo-*-client.tar.gz` under `~/benchmarks/scripts/` | Results: plain text under `/opt/aeron/results/` (no HDR) | **Output format.** Quickstart uses LoadTestRig HDR + archives; stack uses custom script output. |
| Aggregate: `~/benchmarks/scripts/aggregate-results` (from benchmarks repo); extract percentiles from `*-report.hgrm` | No aggregation; no aggregate-results script | **No aggregation.** Stack has no HDR aggregation or percentile report. |

---

## 7. Java and JVM

| Quickstart | Current stack | Inconsistency |
|------------|---------------|----------------|
| JDK 17; wrapper env may set JVM_OPTS / JAVA_OPTS | JDK 17; `aeron_java_opts` in group_vars include `--add-opens` for Java 17+ | **Runtime.** Stack has add-opens in vars; if benchmark run uses a different code path (e.g. benchmarks repo’s scripts), those scripts must receive the same JVM options or they can error (e.g. IllegalAccessError). |

---

## 8. README vs quickstart

| Quickstart | Current README | Inconsistency |
|------------|----------------|---------------|
| Sections: Overview, Prerequisites, Network Topology, Base System Setup, CPU Isolation, (optional) RDMA/VMA, Building and Deploying, **Running Benchmarks** (wrappers), **Aggregating Results**, Reference Results, Troubleshooting, **Ansible Automation** | Sections: Overview, Node Roles, How the Benchmark Works, Quick Start, Configuration, Running Benchmarks, Understanding Results, Tuning, Security | **Content.** README doesn’t describe aeron-io/benchmarks, deployTar, benchmarks-dist, wrapper scripts, or HDR aggregation. It describes Ping/Pong and run-benchmark.sh. |
| Clear “Fast path” and “Recommended Ansible pipeline order” | No pipeline or fast path; single “Quick Start” | **Workflow.** README should mirror quickstart flow (build → deploy → run wrappers → aggregate). |
| Reference results table (P50/P99/P999/MAX for Java echo, C echo, etc.) | Generic “Understanding Results” (P50/P99/P999/MAX meaning) | **Reference numbers.** README could add quickstart-style reference table. |

---

## 9. scripts.zip vs stack

| scripts.zip (wrapper set) | Current stack | Inconsistency |
|---------------------------|---------------|----------------|
| `wrapper-echo-unified.sh`, `wrapper-cluster-unified.sh`; `config/benchmark-config.env`; `aggregate-compare-results.sh`, `run-driver-matrix.sh` | None of these in repo or playbooks | **Wrapper set not integrated.** scripts.zip provides config-driven echo/cluster wrappers and aggregation; stack doesn’t include or deploy them. |
| Paths in wrappers: `/home/ubuntu/benchmarks/scripts`, `/home/ubuntu/benchmarks-dist` | Stack uses `/opt/aeron` | **Path.** If we add these wrappers, they (or the config) must be templated to use stack paths (e.g. `/opt/aeron/benchmarks-dist` or keep home and align deploy path). |

---

## Summary: what to change

1. **Default to [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks):** Add variable (e.g. `benchmarks_repo_url`), default `https://github.com/aeron-io/benchmarks`. Build with `./gradlew clean deployTar` on controller; deploy `benchmarks.tar` to nodes as `benchmarks-dist`.
2. **Paths:** Either (a) keep quickstart convention and deploy to `~/benchmarks-dist` and run from `~/benchmarks/scripts`, or (b) keep `/opt/aeron` and deploy `benchmarks-dist` under `/opt/aeron/benchmarks-dist`, with wrappers under `/opt/aeron/scripts` and config templated accordingly.
3. **Include wrapper files:** Add wrapper-echo-unified.sh, wrapper-cluster-unified.sh, config/benchmark-config.env (and optionally aggregate-compare-results.sh, run-driver-matrix.sh) to the repo or playbooks; template IPs/paths and SSH key path from Terraform/Ansible.
4. **README:** Align with quickstart as source of truth: document benchmarks repo, deployTar, benchmarks-dist, wrapper-based runs, and aggregation; add reference results and Ansible pipeline order.
5. **Ansible:** Add role (or tasks) to clone benchmarks repo on controller, build deployTar, deploy benchmarks-dist to benchmark nodes; add role/tasks to install wrapper scripts and config; ensure any Java invocations (stack or benchmarks repo) get `--add-opens` so the benchmark doesn’t error.
6. **Optional:** Add prepare-nodes / validate-nodes / aggregate-results playbooks or steps to match quickstart pipeline; document when to reboot after CPU isolation.
