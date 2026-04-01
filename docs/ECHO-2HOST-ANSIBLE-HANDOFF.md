# 2-Host Echo Benchmark: Ansible Handoff

## Goal
Make 2-host Aeron echo benchmark run successfully on fresh provision/start by fixing:
- host firewall rules (UDP path),
- generated benchmark channel config (no malformed braces),
- interface selection.

## What failed and why
- **UDP blocked on hosts**: default host firewall had `INPUT` reject, so cross-host UDP traffic did not pass.
- **Malformed channel strings**: using shell default expansion with brace-form interface (e.g. `${VAR:-...|interface={enp0s9}}`) resulted in effective values like `{enp0s9}}`.
- **Wrong NIC name in generated config**: `ens3` was configured, but actual NIC is `enp0s9` on both benchmark nodes.

## Required Ansible updates

### 1) Allow benchmark UDP on both benchmark hosts
Apply on benchmark nodes (`benchmark-1`, `benchmark-2`):
- Allow inbound UDP `12000-65535` from benchmark CIDR (or VCN CIDR) for echo + cluster + ephemeral response ports.
- Persist rules across reboot (use your existing firewall role strategy).

Suggested rule intent:
- `INPUT` allow `udp` from `172.16.0.0/16` to `dport 12000:65535`

Note:
- We validated this range is enough for current echo channels (`13000`, `13100`).

### 2) Fix benchmark config template rendering
File:
- `playbooks/roles/aeron-benchmark/templates/benchmark-config.env.j2`

For named-interface mode:
- Do **not** use `${VAR:-...}` around channel strings containing `{ifname}`.
- Set explicit values (or guarded `if [[ -z "${VAR:-}" ]]; then export ...; fi`) so literal braces are preserved exactly.

Use these channel semantics for 2-host echo:
- `CLIENT_SOURCE_CHANNEL`: `client_ip:13100`
- `CLIENT_DESTINATION_CHANNEL`: `server_ip:13000`
- `SERVER_SOURCE_CHANNEL`: `client_ip:13100`
- `SERVER_DESTINATION_CHANNEL`: `server_ip:13000`

### 3) Ensure interface var is correct
Set/propagate:
- `aeron_echo_udp_named_interface=enp0s9`

Do not hardcode `ens3` unless host NICs actually use that name.

## Wrapper/default alignment
If wrapper defaults are used when vars are absent, keep them aligned with the same channel semantics above.

File:
- `playbooks/roles/aeron-benchmark/files/wrappers/wrapper-echo-unified.sh`

## Quick verification after apply

### Config renders correctly
On controller:
```bash
cd /opt/aeron/benchmarks-dist/scripts
set -a && source ./config/benchmark-config.env && set +a
echo "$CLIENT_SOURCE_CHANNEL"
echo "$CLIENT_DESTINATION_CHANNEL"
echo "$SERVER_SOURCE_CHANNEL"
echo "$SERVER_DESTINATION_CHANNEL"
```

Expected:
- No extra trailing `}` in any channel.
- Interface token appears as `{enp0s9}`.

### 2-host smoke run
```bash
cd /opt/aeron/benchmarks-dist/scripts
RUNS=1 ITERATIONS=1 WARMUP_ITERATIONS=1 BENCH_PROFILE=smoke_288_101k ./wrapper-echo-unified.sh
```

Expected:
- command exits `0`,
- client/server result archives are produced/downloaded (e.g. `aeron-echo-<timestamp>-client.tar.gz`, `...-server.tar.gz`).

---

## Stack implementation (this repo)

The following maps the handoff to committed Ansible/Terraform:

| Handoff item | Implementation |
|--------------|----------------|
| Host UDP firewall on benchmark nodes | `playbooks/roles/aeron-benchmark/tasks/host-firewall-udp.yml` (imported from `tasks/main.yml`); idempotent `iptables -C` / `-I` for UDP `12000:65535` from `aeron_benchmark_host_udp_source_cidr` (Terraform passes `local.aeron_benchmark_udp_ingress_cidr`). Runs only when `node_role` is `client` or `receiver`. |
| Terraform toggles | `aeron_benchmark_configure_host_firewall` (default `true`), `aeron_benchmark_host_firewall_persistent` (default `false`); wired in `compute.tf` ansible `-e`. |
| Malformed `{ifname}}` in channel strings | `benchmark-config.env.j2` named-interface branch: **plain** `export VAR="...|interface={{ _iface }}"` (no `${VAR:-...}`). `wrapper-echo-unified.sh`: **if `[[ -z "${CHANNEL:-}" ]]`** then assign — avoids bash closing `${...}` on `}` inside `{ifname}`. |
| Correct NIC name | `aeron_echo_udp_named_interface` must match `ip -br a` (e.g. `enp0s9`). Documented in `variables.tf` / `schema.yaml`; **not** hardcoded. |

