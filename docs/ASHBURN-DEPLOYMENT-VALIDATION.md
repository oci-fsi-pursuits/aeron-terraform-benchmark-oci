# Ashburn Deployment Validation

This runbook tracks fresh `us-ashburn-1` validation for the Aeron benchmark Terraform/Ansible deployment. The goal is to prove that VM and BM deployments work from clean Terraform inputs, render the right benchmark profile automatically, and produce usable smoke benchmark output without manual patching.

Profile date: 2026-05-20

## Goals

- Validate Terraform and Ansible from a fresh deployment in Ashburn.
- Confirm VM deployments use the VM-safe profile.
- Confirm BM RDMA deployments configure `eth1`, VMA, CPU isolation, static cluster pins, and wrappers automatically.
- Capture Terraform plan/apply/output logs for each deployment.
- Capture benchmark smoke output and profile evidence from the controller.
- Record any manual intervention. Passing runs should require none.

## Test Matrix

| Status | Run | Purpose | Shape | Tuning profile | Cluster mode |
|---|---|---|---|---|---|
| [x] | `ash-vm16-smoke` | VM baseline | `VM.Standard.E6.Flex`, 16 OCPU | `vm_stable` | echo only |
| [x] | `ash-vm32-smoke` | VM scale check | `VM.Standard.E6.Flex`, 32 OCPU | `vm_stable` | echo only |
| [x] | `ash-vm16-cluster-backup` | VM cluster + backup wrapper path | `VM.Standard.E6.Flex`, 16 OCPU + failover | `vm_stable` | `CLUSTER_SIZE=1`, backup=1 |
| [ ] | `ash-bm-rdma-vma` | BM RDMA/VMA validated profile | `BM.Optimized3.36` | `bm_rdma` | `CLUSTER_SIZE=1`, backup=1 |
| [ ] | `ash-bm-raft3` | Optional 3-member Raft switch | `BM.Optimized3.36` | `bm_rdma` | `CLUSTER_SIZE=3`, backup=0 |

## Repository Working Directory

Run commands from:

```powershell
C:\Users\ncusato\Documents\customers\aeron\aeron-deploy\aeron-terraform-oci
```

Create a local validation directory. It should not be required by Terraform, but it keeps logs together:

```powershell
New-Item -ItemType Directory -Force ".\validation" | Out-Null
```

## Standard Terraform Capture Process

For each run, replace `$run` with the matrix name and use its matching `local-test-$run.tfvars`.

```powershell
$run = "ash-vm16-smoke"
New-Item -ItemType Directory -Force ".\validation\$run" | Out-Null

terraform init 2>&1 |
  Tee-Object ".\validation\$run\00-init.log"

terraform workspace select $run 2>&1 |
  Tee-Object ".\validation\$run\00-workspace-select.log"

if ($LASTEXITCODE -ne 0) {
  terraform workspace new $run 2>&1 |
    Tee-Object ".\validation\$run\00-workspace-new.log"
}

terraform plan `
  -var-file="local-test-$run.tfvars" `
  -out="tfplan-$run" 2>&1 |
  Tee-Object ".\validation\$run\01-plan.log"

terraform apply -auto-approve "tfplan-$run" 2>&1 |
  Tee-Object ".\validation\$run\02-apply.log"

terraform output 2>&1 |
  Tee-Object ".\validation\$run\03-output.txt"

terraform output -json 2>&1 |
  Tee-Object ".\validation\$run\03-output.json"

terraform output -raw controller_ssh_command 2>&1 |
  Tee-Object ".\validation\$run\04-ssh-command.txt"
```

## Controller Evidence Capture

After `terraform apply`, SSH to the controller using the command from `04-ssh-command.txt`.

On the controller:

```bash
mkdir -p ~/validation-capture

{
  echo "===== date ====="
  date -u
  echo
  echo "===== benchmark status ====="
  cat ~/benchmark-results/STATUS.txt 2>/dev/null || true
  echo
  echo "===== benchmark results listing ====="
  find ~/benchmark-results -maxdepth 3 -type f | sort 2>/dev/null || true
  echo
  echo "===== echo summary ====="
  cat ~/benchmark-results/driver-matrix-echo-summary.csv 2>/dev/null || true
  echo
  echo "===== cluster summary ====="
  cat ~/benchmark-results/driver-matrix-cluster-summary.csv 2>/dev/null || true
  echo
  echo "===== terraform matrix summary ====="
  cat ~/benchmark-results/terraform-matrix-summary.json 2>/dev/null || true
} | tee ~/validation-capture/smoke-results.txt
```

Copy `~/validation-capture/smoke-results.txt` back into:

```text
validation/<run>/05-smoke-results.txt
```

## Profile Evidence Commands

Run these on the controller for every deployment.

```bash
CFG=/opt/aeron/benchmarks-dist/scripts/config/benchmark-config.env

echo "===== rendered benchmark profile ====="
grep -E 'BENCHMARK_TUNING_PROFILE|AERON_RDMA|AERON_ECHO_UDP_NAMED_INTERFACE|_AERON_IFACE_DEFAULT|ONLOAD_COMMAND_VMA|VMA_DRIVER_PREFIX|AERON_SOCKET_SO|AERON_RCV_INITIAL_WINDOW|AERON_NETWORK_PUBLICATION|AERON_.*IO_VECTOR|CLUSTER_SIZE|CLUSTER_BACKUP_NODES|CLUSTER_AERON_SSH_TASKSET_CPUS|CLUSTER_SKIP_DROP_CACHES' "$CFG" || true

echo "===== wrapper syntax / presence ====="
ls -lah /opt/aeron/benchmarks-dist/scripts/wrapper-cluster-unified.sh \
        /opt/aeron/benchmarks-dist/scripts/run-driver-matrix.sh \
        /home/ubuntu/run-cluster-benchmark.sh 2>/dev/null || true
```

For BM RDMA/VMA runs, also check:

```bash
echo "===== BM RDMA / VMA evidence ====="
for h in aeron-benchmark-client aeron-benchmark-receiver aeron-benchmark-failover; do
  echo "--- $h ---"
  ssh -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no ubuntu@"$h" '
    hostname
    ip -br addr show eth1 || true
    rdma link show 2>/dev/null || true
    test -e /usr/lib/x86_64-linux-gnu/libvma.so.9 && echo "FOUND libvma" || echo "MISSING libvma"
    getcap /opt/aeron/benchmarks-dist/scripts/aeron/aeronmd 2>/dev/null || true
    cat /proc/cmdline
  '
done

echo "===== java-onload patch evidence ====="
grep -A5 "drivers\['java-onload'\]" /opt/aeron/benchmarks-dist/scripts/aeron/remote-cluster-benchmarks
```

## Pass Criteria

### All Runs

- `terraform plan` succeeds.
- `terraform apply` succeeds.
- Terraform output includes controller and benchmark node connection details.
- Ansible completes and creates `/opt/aeron/.aeron-ready`.
- Smoke matrix completes or fails with a clear benchmark-level error, not missing scripts, missing config, missing SSH keys, or missing dependencies.
- No manual post-deploy patching is required.

### VM Runs

- `BENCHMARK_TUNING_PROFILE="vm_stable"`.
- Aeron socket/window values are `2m`.
- Aeron batching/iovec values are `1`.
- `benchmark_cloud_init_rdma=false`.
- No dependency on `eth1`.
- `hyperthreading=false`.

### BM RDMA/VMA Run

- `BENCHMARK_TUNING_PROFILE="bm_rdma"`.
- `eth1` exists on client, receiver, and failover.
- RDMA addresses use the configured RDMA prefix, for example `10.34.100.x/24`.
- `_AERON_IFACE_DEFAULT='{eth1}'`.
- `AERON_ECHO_UDP_NAMED_INTERFACE='{eth1}'`.
- VMA library exists at `/usr/lib/x86_64-linux-gnu/libvma.so.9`.
- `aeronmd` has no file capabilities before VMA run.
- `java-onload` in `remote-cluster-benchmarks` uses `c-media-driver`.
- `CLUSTER_AERON_SSH_TASKSET_CPUS=20-31`.
- `CLUSTER_SKIP_DROP_CACHES=0` for VMA cluster runs.

### Optional Raft Run

- `enable_cluster_raft_consensus=true`.
- Rendered config has `CLUSTER_RAFT_CONSENSUS=1`.
- Rendered config has `CLUSTER_SIZE=3`.
- Rendered config has `CLUSTER_BACKUP_NODES=0`.
- Terraform provisions enough benchmark nodes for client + node0 + node1 + node2.

## BM Manual Proof Commands

After `ash-bm-rdma-vma` passes Terraform smoke, run these on the controller:

```bash
/home/ubuntu/run-cluster-benchmark.sh java_vma 101K
/home/ubuntu/run-cluster-benchmark.sh java_vma 1001K
```

Expected:

- `101K` stays in low tens of microseconds or better.
- `1001K` does not regress to the broken Java MediaDriver + VMA multi-ms P50 path.
- Run directories appear under `~/benchmark-results/runs`.
- `enable-vma-state.log` and `vma-status.log` are present.

## Result Log

### ash-vm16-smoke

```text
Run: ash-vm16-smoke
Date: 2026-05-20
Tfvars: local-test-ash-vm16-smoke.tfvars
Terraform plan: PASS
Terraform apply: PASS
Smoke matrix: PASS
Cluster matrix: N/A
Profile rendered: BENCHMARK_TUNING_PROFILE="vm_stable"; no named eth1 dependency
SMT disabled: yes, Terraform output hyperthreading=false
RDMA eth1 configured: N/A for VM
VMA lib path: /usr/lib/x86_64-linux-gnu/libvma.so.9 rendered, VMA runtime disabled for this VM smoke
Manual patching required: none after YAML indentation fix was committed locally before rerun
Result directory: /home/ubuntu/benchmark-results/runs/20260520T092101Z-510
Evidence:
  - validation/ash-vm16-smoke/08-plan-rerun2.log
  - validation/ash-vm16-smoke/09-apply-rerun2.log
  - validation/ash-vm16-smoke/11-controller-evidence.log
  - validation/ash-vm16-smoke/12-repeat-smoke.log
Smoke summary:
  - java: ok, wrapper-run-success; p50 27.535 us, p99 34.111 us
  - c: ok, wrapper-run-success; p50 27.679 us, p99 35.007 us
Repeat sanity smoke:
  - directory: /home/ubuntu/benchmark-results/runs/vm16-repeat-smoke-20260520T092728Z
  - java: 3 valid runs; median p50 27.263 us, p99 32.207 us, p999 51.647 us, max 127.615 us
  - c: 3 valid runs; median p50 27.759 us, p99 33.567 us, p999 53.375 us, max 238.335 us
Notes:
  - Initial cloud-init package install had transient DNS failures; rerun succeeded once DNS was healthy.
  - The Ansible YAML parse error in benchmarks-build/tasks/main.yml was fixed before the passing rerun.
  - Controller and benchmark nodes still report historical cloud-init status=error from the first transient failure, but Ansible provisioning and smoke completed successfully.
  - Repeat smoke validates the one-shot Terraform smoke numbers as reasonable for VM E6 16 OCPU, non-VMA, 288-byte messages at 100001 msg/s.
```

Fill one block per remaining run.

### ash-vm32-smoke

```text
Run: ash-vm32-smoke
Date: 2026-05-20
Tfvars: local-test-ash-vm32-smoke.tfvars
Terraform plan: PASS
Terraform apply: PASS
Smoke matrix: PASS
Cluster matrix: N/A
Profile rendered: BENCHMARK_TUNING_PROFILE="vm_stable"; no named eth1 dependency
SMT disabled: yes, Terraform output hyperthreading=false
RDMA eth1 configured: N/A for VM
VMA lib path: /usr/lib/x86_64-linux-gnu/libvma.so.9 rendered, VMA runtime disabled for this VM smoke
Manual patching required: none
Result directory: /home/ubuntu/benchmark-results/runs/20260520T095511Z-1633
Evidence:
  - validation/ash-vm32-smoke/08-plan-rerun3.log
  - validation/ash-vm32-smoke/09-apply-rerun3.log
  - validation/ash-vm32-smoke/10-output.log
  - validation/ash-vm32-smoke/11-controller-evidence.log
  - validation/ash-vm32-smoke/12-repeat-smoke.log
Smoke summary:
  - java: ok, wrapper-run-success; p50 22.335 us, p99 27.487 us
  - c: ok, wrapper-run-success; p50 21.999 us, p99 29.855 us
Repeat sanity smoke:
  - directory: /home/ubuntu/benchmark-results/runs/20260520T131835Z-1886
  - java: 3 valid runs; median p50 21.823 us, p99 27.039 us, p999 35.743 us, max 165.887 us
  - c: 3 valid runs; median p50 22.591 us, p99 27.599 us, p999 37.599 us, max 180.991 us
Notes:
  - VM32 scaled in the expected direction versus VM16: P50/P99 improved from the VM16 repeat sanity baseline.
  - Rendered profile kept VM-safe Aeron values: socket/window 2m and batching/iovec 1.
  - Terraform smoke and repeat smoke completed successfully. The local SSH capture command returned exit code 1 because Windows PowerShell treated remote cleanup stderr as a native-command error; the matrix summary itself reported success for all modes.
  - Passing rerun included robustness fixes for DNS/package bootstrap, apt/dpkg lock waiting, and retrying source clones.
```

### ash-vm16-cluster-backup

```text
Run: ash-vm16-cluster-backup
Date: 2026-05-20
Tfvars: local-test-ash-vm16-cluster-backup.tfvars
Terraform plan: PASS
Terraform apply: PASS
Smoke matrix: PASS
Cluster matrix: PASS
Profile rendered: VM-safe non-VMA smoke; run_benchmarks_matrix_modes="java,c"; run_benchmarks_cluster_matrix=true
SMT disabled: yes, Terraform output hyperthreading=false
RDMA eth1 configured: N/A for VM
VMA lib path: /usr/lib/x86_64-linux-gnu/libvma.so.9 rendered, VMA runtime disabled for this VM smoke
Manual patching required: none after local automation patches were applied before rerun6
Result directory: /home/ubuntu/benchmark-results/runs/20260520T144232Z-7841
Evidence:
  - validation/ash-vm16-cluster-backup/19-plan-rerun6.log
  - validation/ash-vm16-cluster-backup/20-apply-rerun6.log
  - validation/ash-vm16-cluster-backup/21-output-rerun6.log
  - validation/ash-vm16-cluster-backup/22-controller-evidence-rerun6.log
Smoke echo summary:
  - java: ok, wrapper-run-success; p50 27.663 us, p99 32.591 us, p999 55.871 us, max 301.567 us
  - c: ok, wrapper-run-success; p50 28.927 us, p99 34.783 us, p999 85.183 us, max 227.711 us
Cluster backup summary:
  - java: ok, wrapper-run-success; p50 30.031 us, p99 35.839 us, p999 74.239 us, max 381.183 us
  - c: ok, wrapper-run-success; p50 30.367 us, p99 36.767 us, p999 105.663 us, max 364.543 us
Notes:
  - Topology matched the intended VM cluster-backup path: client + receiver + failover, CLUSTER_SIZE=1, backup=1, raft_consensus=false.
  - Rerun5 proved echo and manual cluster health but Terraform remote-exec exited before cluster summary post-processing; rerun6 added a 30-second Terraform heartbeat and explicit cluster exit logging.
  - Rerun6 completed the full automated Terraform apply path and wrote echo summary, cluster summary, and terraform-matrix-summary.json.
  - VM cluster-backup smoke numbers are consistent with VM16/VM32 non-VMA expectations: echo ~28-29 us P50 and cluster ~30 us P50.
```

### ash-bm-rdma-vma

```text
Run: ash-bm-rdma-vma
Date: 2026-05-20
Workspace: ash-bm-rdma-vma
Tfvars: local-test-ash-bm-rdma-vma.tfvars
Shape/profile: BM.Optimized3.36, bm_rdma
Topology: client + receiver + failover, CLUSTER_SIZE=1, CLUSTER_BACKUP_NODES=1
Terraform plan/apply status: IN PROGRESS / BLOCKED
Smoke matrix: not yet completed
Cluster matrix: not yet completed
VMA smoke: not yet completed
Manual patching required: none on target nodes; fixes are in Terraform/Ansible
Current controller public IP: 129.213.26.86
Current benchmark private IPs: 10.44.1.181, 10.44.1.114
Current failover private IP: 10.44.1.75
Evidence:
  - validation/ash-bm-rdma-vma/14-plan-fresh-bm-fix.log
  - validation/ash-bm-rdma-vma/15-apply-fresh-bm-fix.log
  - validation/ash-bm-rdma-vma/16-plan-isolation-reboot-fix.log
  - validation/ash-bm-rdma-vma/17-apply-isolation-reboot-fix.log
  - validation/ash-bm-rdma-vma/18-plan-no-daemon-reexec.log
  - validation/ash-bm-rdma-vma/19-apply-no-daemon-reexec.log
  - validation/ash-bm-rdma-vma/20-plan-recovered-controller.log was not created because the next Terraform approval was rejected
Findings so far:
  - Fresh BM replacement with fixed cloud-init reached Ansible, and cloud-init status on BM/failover nodes reported done.
  - Initial BM failure root cause was invalid RDMA cloud-init YAML plus RDMA/HPC plugin state not being enabled when cloud-init RDMA was active.
  - Terraform/Ansible now enables the OCI HPC RDMA authentication/autoconfiguration plugins through rdma_enable_hpc_plugins while still rendering eth1 netplan.
  - Ansible reboot handling needed to be controller-managed. The local Ansible reboot module cannot be used under `ansible-playbook -c local`.
  - A live `systemd daemon_reexec` during benchmark-node provisioning can drop the Terraform SSH session; benchmark roles now skip that reexec and rely on the isolation reboot.
  - Controller SSH became unreachable after the failed retry; OCI `RESET` in us-ashburn-1 recovered TCP/22.
Next run:
  - Re-run pinned workspace plan/apply after controller recovery.
  - Confirm the controller-managed isolation reboot step marks/reboots benchmark and failover nodes.
  - Validate `/proc/cmdline` includes isolcpus/nohz_full/rcu_nocbs/nosmt and `/sys/devices/system/cpu/smt/active` is 0.
  - Capture BM RDMA/VMA evidence and smoke numbers, including java_vma and c_vma.
```

```text
Run:
Date:
Tfvars:
Terraform plan: PASS/FAIL
Terraform apply: PASS/FAIL
Smoke matrix: PASS/FAIL
Cluster matrix: PASS/FAIL/N/A
Profile rendered:
SMT disabled:
RDMA eth1 configured:
VMA lib path:
Manual patching required:
Result directory:
Notes:
```

## Cleanup

Destroy each run after evidence is captured unless the environment is needed for debugging.

```powershell
$run = "ash-vm16-smoke"

terraform workspace select $run

terraform destroy -auto-approve `
  -var-file="local-test-$run.tfvars" 2>&1 |
  Tee-Object ".\validation\$run\99-destroy.log"
```
