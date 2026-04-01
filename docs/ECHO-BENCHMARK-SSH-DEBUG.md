# Echo benchmark SSH debug playbook

Use this on the **controller** after SSH. It is written so a human can follow it step-by-step and so an assistant can use your pasted output to suggest **Terraform/Ansible** changes.

**Paths (stack default)**

| What | Path |
|------|------|
| Benchmark scripts | `/opt/aeron/benchmarks-stack` → usually `/opt/aeron/benchmarks-dist/scripts` |
| Stack config (sourced by wrappers) | `/opt/aeron/scripts/config/benchmark-config.env` |
| Matrix copies config here | `/opt/aeron/benchmarks-dist/scripts/config/benchmark-config.env` |
| Matrix / apply logs | `~/benchmark-results/` (`STATUS.txt`, `run-driver-matrix-echo.log`) |
| Provisioner timeline | `~/benchmark-status.txt` |

If `benchmarks-dist` path differs, run: `ls -la /opt/aeron/benchmarks-dist/scripts` and adjust below.

---

## 1. Quick environment snapshot (paste to assistant)

Run on the controller and save the full output:

```bash
cd /opt/aeron/benchmarks-dist/scripts

echo "=== uname / host ==="
hostname
date -u

echo "=== config files ==="
ls -la ./config/benchmark-config.env /opt/aeron/scripts/config/benchmark-config.env 2>&1

echo "=== matrix uses this config ==="
head -80 ./config/benchmark-config.env 2>/dev/null || true
```

**Assistant use:** Confirms whether **named interface** vs **CIDR prefix** vs **no interface** is in effect; verifies `SSH_CLIENT_NODE`, `SSH_SERVER_NODE`, `ONLOAD_COMMAND`.

---

## 2. Automated debug script (preferred)

After deploy, this file should exist (from Ansible `echo-benchmark-debug.sh`):

```bash
cd /opt/aeron/benchmarks-dist/scripts
chmod +x ./echo-benchmark-debug.sh 2>/dev/null || true
./echo-benchmark-debug.sh ./config/benchmark-config.env 2>&1 | tee ~/echo-benchmark-debug.out
```

**If the script is missing:** copy it from the repo (`playbooks/roles/aeron-benchmark/files/wrappers/echo-benchmark-debug.sh`) or re-run the controller Ansible/Terraform provisioner.

**Assistant use:** Interfaces on controller + client + server, SSH reachability, `/dev/shm/aeron`, resolved channel URIs (`SHOW_CONFIG_ONLY`).

---

## 3. Wrapper trace (hangs inside `remote-echo-benchmarks`)

```bash
cd /opt/aeron/benchmarks-dist/scripts
set -a && source ./config/benchmark-config.env && set +a
WRAPPER_DEBUG=1 BENCH_PROFILE=smoke_288_101k ./wrapper-echo-unified.sh 2>&1 | tee ~/echo-wrapper-trace.log
```

**Assistant use:** Exact `remote-echo-benchmarks` argv and env; correlate with Aeron channel strings.

---

## 4. Symptom → likely cause → Ansible/Terraform lever

| Symptom | Likely cause | What to change |
|--------|----------------|----------------|
| Connect / publication timeout; no UDP | OCI **security list** / **NSG** blocks benchmark **UDP** (echo ~12k–14k, **cluster ~20k+**, ephemeral responses) | VCN console: allow UDP **12000–65535** (or equivalent) from VCN/benchmark CIDR on private subnet SL **and** NSG **ingress**. NSGs are **stateless**: also allow matching **egress** UDP to the same CIDR (cluster `POLL_RESPONSE` / `egress.isConnected=false` if only ingress was opened). Optional: `aeron_benchmark_udp_ingress_cidr` in Terraform for NSG source/destination. |
| Timeout; SL/NSG allow UDP | **Host `iptables` INPUT** rejecting UDP (common on hardened images) | Ansible `host-firewall-udp.yml` inserts ACCEPT for UDP `12000:65535` from effective VCN CIDR when `aeron_benchmark_configure_host_firewall=true`. Verify: `sudo iptables -L INPUT -n -v` on benchmark nodes. |
| Channel shows `}}` after interface token | **`${VAR:-...}`** with **`{ifname}`** in default | Fixed in template + wrapper; re-deploy config. Verify with `echo "$CLIENT_SOURCE_CHANNEL"`. |
| Timeout; `echo-benchmark-debug` shows wrong/missing NIC | **`interface=`** does not match host (wrong `/24` vs `/16`, or wrong NIC name) | `aeron_echo_udp_interface_prefix_length` (e.g. `"16"`) **or** `aeron_echo_udp_named_interface` (e.g. `ens3` from `ip -br a`). Template: `playbooks/roles/aeron-benchmark/templates/benchmark-config.env.j2`. |
| `unknown interface` / Aeron driver error on interface | Named interface typo or VLAN name differs client vs server | Fix `aeron_echo_udp_named_interface` or override per-role `CLIENT_*_CHANNEL` / `SERVER_*_CHANNEL` in env. |
| Permission / cannot create driver dir | **`/dev/shm/aeron`** owned by root | On each benchmark node: `sudo rm -rf /dev/shm/aeron`. Matrix pre-step: `local.benchmark_dev_shm_cleanup` in `compute.tf`. |
| `onload: not found` | OpenOnload not installed | `ONLOAD_COMMAND=env` in `benchmark-config.env.j2` (default). Wrappers pass `--onload`; should be no-op. |
| SSH fails in debug script | Wrong key or security rules | `SSH_KEY_FILE` in config; controller → benchmark SSH on port 22; `tls_private_key` / deploy key sync in `compute.tf`. |
| Ansible failed earlier; partial install | `client_node_ip` missing on nodes | `compute.tf` `ansible-playbook -e` must include `client_node_ip`, `receiver_node_ip`, … for **all** roles (controller, benchmark, failover). |

---

## 5. Files in **this repo** an assistant will edit

| Area | Files |
|------|--------|
| Echo channel URIs / env | `playbooks/roles/aeron-benchmark/templates/benchmark-config.env.j2` |
| Wrapper logic / debug flags | `playbooks/roles/aeron-benchmark/files/wrappers/wrapper-echo-unified.sh`, `echo-benchmark-debug.sh` |
| Install debug script on controller | `playbooks/roles/aeron-benchmark/tasks/main.yml` (copy loop) |
| Ansible extra vars (IPs, interface vars) | `compute.tf` (`ansible-playbook -e ...`) |
| TF variables (prefix, named iface, UDP CIDR) | `variables.tf`, `local-test.tfvars` (local only), `local-test.tfvars.example` |
| NSG UDP range | `nsg.tf`, `locals.tf` |
| Post-apply matrix + `/dev/shm` | `compute.tf` `null_resource.run_driver_matrix`, `local.benchmark_dev_shm_cleanup` |

---

## 6. Paste block for the assistant

After you run sections **1–3**, paste:

```
--- ECHO DEBUG bundle ---
1) head of benchmark-config.env (section 1)
2) full echo-benchmark-debug.out OR say "script missing"
3) last 120 lines of echo-wrapper-trace.log OR say "not run"
--- end ---
```

---

## 7. Re-apply only Ansible on controller (optional)

If Terraform instances are unchanged but playbooks/templates were fixed:

```bash
# On controller, after uploading fresh playbooks zip or git pull to /opt/aeron/playbooks
cd /opt/aeron/playbooks
sudo ansible-playbook -i 'localhost,' -c local site.yml -e 'node_role=controller ...'
```

Use the same `-e` keys as in **`compute.tf`** for the controller (IPs, `aeron_echo_udp_*`, repos, etc.). Easiest path is often **`terraform apply`** so provisioners stay the source of truth.

---

## References

- [aeron-io/benchmarks](https://github.com/aeron-io/benchmarks) — remote echo / LoadTestRig, `scripts/aeron`.
- [aeron-io/aeron](https://github.com/aeron-io/aeron) — UDP `interface=` parsing (`NamedInterface` / `{ifname}` in recent drivers).
