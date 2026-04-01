# Benchmark Node Handoff Checklist

## Baseline Source

- [ ] Use baseline settings from `docs/BENCHMARK-NODE-OPTIMIZATION-NOTES.md` in this repo (locked profile section), or a copy on the node such as `/home/ubuntu/BENCHMARK-NODE-OPTIMIZATION-NOTES.md`.

## Network and MTU

- [ ] Keep NIC MTU at `9000`.
- [ ] Keep Aeron MTU at `8K` (do not use Aeron `9K`).

## Sysctl (both benchmark nodes)

- [ ] `net.core.netdev_max_backlog=100000`
- [ ] `net.core.busy_poll=50`
- [ ] `net.core.busy_read=50`
- [ ] `net.core.rps_sock_flow_entries=0`

## NIC Settings (both benchmark nodes)

- [ ] Coalescing: adaptive on, `rx/tx-usecs=8`, `rx/tx-frames=128`
- [ ] Ring sizes: `rx=1024`, `tx=1024`

## Firewall (both benchmark nodes)

- [ ] Ensure peer benchmark node IPs are explicitly allowed in `INPUT`.

## Echo Benchmark Runtime Profile

- [ ] `CLIENT_MODE=c`
- [ ] `SERVER_MODE=c`
- [ ] `MESSAGE_LENGTH=288`
- [ ] `MESSAGE_RATE=101K`
- [ ] `CLIENT_NON_ISOLATED_CPU_CORES=1-9`
- [ ] `SERVER_NON_ISOLATED_CPU_CORES=1-9`
- [ ] `CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE=8`
- [ ] `SERVER_ECHO_CPU_CORE=9`

## Validation Run

- [ ] Run 10 full runs with `wrapper-echo-unified.sh`.
- [ ] Confirm envelope:
  - [ ] p50 in `164.7-166.3`
  - [ ] p99 in `174.3-179.1`
  - [ ] p999 in `188.5-202.1`

## If Out Of Range

- [ ] Check reboot/firewall reset state first.
- [ ] Check `/dev/shm` stale ownership/log artifacts.
- [ ] Check for NIC/sysctl drift from baseline.
