locals {
  cluster_name = var.use_custom_name ? var.cluster_name : "${var.cluster_name}-${random_pet.name.id}"

  # OCI VNIC hostname_label must be unique per subnet. Fixed labels (controller, benchmark-1) collide when
  # multiple stacks share the same subnets. Prefix is DNS-sanitized; use_custom_name stacks append random_pet.
  hostname_pet = random_pet.name.id
  vnic_label_root_raw = length(trimspace(var.instance_hostname_prefix)) > 0 ? trimspace(var.instance_hostname_prefix) : (
    var.use_custom_name ? "${var.cluster_name}-${local.hostname_pet}" : local.cluster_name
  )
  # DNS hostname label chars (no regexreplace: stays compatible with older Terraform CLI).
  vnic_label_slug_low = lower(
    replace(
      replace(
        replace(
          replace(
            replace(
              replace(replace(local.vnic_label_root_raw, " ", "-"), "_", "-"),
              ".", "-"
            ),
            "/", "-"
          ),
          "\\", "-"
        ),
        "@", "-"
      ),
      ":", "-"
    )
  )
  vnic_label_slug_collapse = replace(
    replace(
      replace(replace(local.vnic_label_slug_low, "--", "-"), "--", "-"),
      "--", "-"
    ),
    "--", "-"
  )
  vnic_hostname_prefix       = substr(trim(local.vnic_label_slug_collapse, "-"), 0, 44)
  vnic_hostname_prefix_final = length(local.vnic_hostname_prefix) > 0 ? local.vnic_hostname_prefix : substr(md5(local.cluster_name), 0, 8)

  ad_names                = data.oci_identity_availability_domains.ads.availability_domains[*].name
  controller_ad_effective = trimspace(var.controller_ad) != "" ? trimspace(var.controller_ad) : local.ad_names[0]
  benchmark_ad_effective  = trimspace(var.benchmark_ad) != "" ? trimspace(var.benchmark_ad) : local.ad_names[0]
  failover_ad_effective   = trimspace(var.failover_ad) != "" ? trimspace(var.failover_ad) : element(local.ad_names, 1)

  vcn_compartment = var.vcn_compartment_ocid != "" ? var.vcn_compartment_ocid : var.compartment_ocid

  vcn_id = var.use_existing_vcn ? var.existing_vcn_id : oci_core_vcn.aeron_vcn[0].id

  # Controller goes in public subnet, benchmark/failover nodes in private subnet
  public_subnet_id  = var.use_existing_vcn ? var.existing_public_subnet_id : oci_core_subnet.public_subnet[0].id
  private_subnet_id = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.private_subnet[0].id

  enable_benchmark_cluster_network         = var.enable_benchmark_cluster_network
  enable_benchmark_instance_pool           = var.enable_benchmark_instance_pool
  enable_benchmark_pooled_instances        = local.enable_benchmark_cluster_network || local.enable_benchmark_instance_pool
  enable_benchmark_direct_instances        = !local.enable_benchmark_pooled_instances
  benchmark_node_count_effective           = var.enable_cluster_raft_consensus ? max(var.benchmark_node_count, 4) : var.benchmark_node_count
  enable_benchmark_cluster_placement_group = var.create_benchmark_cluster_placement_group && !var.enable_rdma_compute_cluster
  benchmark_compute_cluster_id             = var.enable_rdma_compute_cluster ? (trimspace(var.rdma_existing_compute_cluster_id) != "" ? trimspace(var.rdma_existing_compute_cluster_id) : oci_core_compute_cluster.benchmark_rdma[0].id) : null
  benchmark_cluster_placement_group_id     = lookup({ for k, v in oci_cluster_placement_groups_cluster_placement_group.benchmark : k => v.id }, 0, null)

  # Flex shape detection
  is_controller_flex_shape    = length(regexall(".*Flex$", var.controller_shape)) > 0
  is_benchmark_flex_shape     = length(regexall(".*Flex$", var.benchmark_shape)) > 0
  is_failover_flex_shape      = length(regexall(".*Flex$", var.failover_shape)) > 0
  is_benchmark_bm_shape       = length(regexall("^BM\\.", var.benchmark_shape)) > 0
  is_failover_bm_shape        = length(regexall("^BM\\.", var.failover_shape)) > 0
  is_benchmark_intel_vm_shape = length(regexall("^VM\\.(Optimized3|Standard3)\\.", var.benchmark_shape)) > 0
  is_failover_intel_vm_shape  = length(regexall("^VM\\.(Optimized3|Standard3)\\.", var.failover_shape)) > 0

  # Host IPs for SSH connections
  controller_host = var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip

  benchmark_direct_instance_ids = oci_core_instance.benchmark[*].id
  benchmark_direct_private_ips  = oci_core_instance.benchmark[*].private_ip
  benchmark_pool_instance_ids   = data.oci_core_instance.benchmark_pool[*].id
  benchmark_pool_private_ips    = data.oci_core_instance.benchmark_pool[*].private_ip
  benchmark_instance_pool_id    = local.enable_benchmark_cluster_network ? oci_core_cluster_network.benchmark[0].instance_pools[0].id : (local.enable_benchmark_instance_pool ? oci_core_instance_pool.benchmark[0].id : null)
  benchmark_instance_ids        = local.enable_benchmark_pooled_instances ? local.benchmark_pool_instance_ids : local.benchmark_direct_instance_ids
  benchmark_private_ips         = local.enable_benchmark_pooled_instances ? local.benchmark_pool_private_ips : local.benchmark_direct_private_ips

  # aeron-io/benchmarks: echo (~13000/13100), cluster (~20000+), dynamic response ports — NSG/iptables use a wide UDP range.
  aeron_benchmark_udp_ingress_cidr = trimspace(var.aeron_benchmark_udp_ingress_cidr) != "" ? trimspace(var.aeron_benchmark_udp_ingress_cidr) : (
    var.use_existing_vcn ? data.oci_core_vcn.existing[0].cidr_blocks[0] : var.vcn_cidr_block
  )

  # Echo |interface=IP/prefix: default "auto" uses the private subnet mask from Terraform (same CIDR as benchmark nodes).
  _echo_udp_prefix_in      = trimspace(var.aeron_echo_udp_interface_prefix_length)
  private_subnet_mask_bits = element(split("/", var.private_subnet_cidr), 1)
  aeron_echo_udp_interface_prefix_length_resolved = (
    local._echo_udp_prefix_in == "" ? "" : (
      lower(local._echo_udp_prefix_in) == "auto" ? local.private_subnet_mask_bits : local._echo_udp_prefix_in
    )
  )

  # run_driver_matrix remote-exec: stop stale drivers, then sudo rm driver dirs (/dev/shm sticky EPERM + home AERON_DIR from wrappers).
  benchmark_dev_shm_cleanup = join(" && ", [
    for ip in local.benchmark_private_ips :
    "ssh -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no -o BatchMode=yes ${var.ssh_username}@${ip} 'sudo pkill -f io.aeron.driver.MediaDriver 2>/dev/null || true; sudo pkill -f io.aeron.benchmarks.LoadTestRig 2>/dev/null || true; sudo pkill -f aeronmd 2>/dev/null || true; sleep 3; sudo rm -rf /dev/shm/aeron /home/${var.ssh_username}/aeron-benchmark-shm'"
  ])

  bootstrap_ansible_prereqs = <<-EOT
    set -e
    if ! command -v unzip >/dev/null 2>&1 || ! command -v ansible-playbook >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        sudo mkdir -p /etc/apt/apt.conf.d
        printf '%s\n' 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null
        dns_ok=0
        for attempt in $(seq 1 120); do
          if getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1 && getent ahostsv4 security.ubuntu.com >/dev/null 2>&1; then
            dns_ok=1
            break
          fi
          echo "Waiting for DNS before apt bootstrap (attempt $attempt/120)..."
          sleep 10
        done
        if [ "$dns_ok" -ne 1 ]; then
          echo "ERROR: DNS did not become ready for apt bootstrap" >&2
          exit 1
        fi
        apt_ok=0
        for attempt in $(seq 1 30); do
          if sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true update -y \
            && apt-cache policy ansible | awk '/Candidate:/ {print $2}' | grep -vq '^(none)$' \
            && sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y --fix-missing unzip ansible; then
            apt_ok=1
            break
          fi
          echo "apt bootstrap failed (attempt $attempt/30); retrying..."
          sleep 20
        done
        if [ "$apt_ok" -ne 1 ]; then
          echo "ERROR: unable to install unzip and ansible after retries" >&2
          exit 1
        fi
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y unzip ansible-core
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y unzip ansible-core
      fi
    fi
    command -v unzip >/dev/null 2>&1
    command -v ansible-playbook >/dev/null 2>&1
  EOT

  # Extra Ansible -e for aeron-benchmark role (echo LoadTestRig env written to benchmark-config.env).
  ansible_benchmark_env_extra = join(" ", [
    "benchmark_echo_runs=${var.benchmark_echo_runs}",
    "benchmark_echo_iterations=${var.benchmark_echo_iterations}",
    "benchmark_echo_warmup_iterations=${var.benchmark_echo_warmup_iterations}",
    "benchmark_echo_warmup_message_rate=${var.benchmark_echo_warmup_message_rate}",
    "message_length=${var.benchmark_message_length}",
    "message_rate=${var.benchmark_message_rate}",
    "benchmark_build_native_aeronmd=${var.benchmark_build_native_aeronmd}",
    "benchmark_ocpus=${var.benchmark_ocpus}",
    "benchmark_tuning_profile=${var.benchmark_tuning_profile}",
    "benchmark_cluster_udp_fabric=${var.benchmark_cluster_udp_fabric}",
    "benchmark_cluster_cpu_affinity=${var.benchmark_cluster_cpu_affinity}",
    "grub_dynamic_cpu_isolation=${var.grub_dynamic_cpu_isolation}",
    "grub_housekeeping_fraction=${var.grub_housekeeping_fraction}",
    "grub_housekeeping_floor=${var.grub_housekeeping_floor}",
    "grub_housekeeping_cpus_max=${var.grub_housekeeping_cpus_max}",
    "benchmark_cpu_profile=${var.benchmark_cpu_profile}",
    "benchmark_housekeeping_cpus_override=${var.benchmark_housekeeping_cpus_override}",
    "benchmark_isolated_cpus_override=${var.benchmark_isolated_cpus_override}",
    "benchmark_irq_affinity_override=${var.benchmark_irq_affinity_override}",
    "benchmark_echo_client_pins=${var.benchmark_echo_client_pins}",
    "benchmark_echo_server_pins=${var.benchmark_echo_server_pins}",
    "install_oci_cn_auth=${var.install_oci_cn_auth}",
    "enable_rdma_compute_cluster=${var.enable_rdma_compute_cluster}",
    "benchmark_cloud_init_rdma=${var.benchmark_cloud_init_rdma}",
    "benchmark_cloud_init_rdma_interface=${var.benchmark_cloud_init_rdma_interface}",
    "benchmark_cloud_init_rdma_configure_netplan=${var.benchmark_cloud_init_rdma_configure_netplan}",
    "benchmark_cloud_init_rdma_ipv4_prefix=${var.benchmark_cloud_init_rdma_ipv4_prefix}",
    "benchmark_cloud_init_rdma_prefix_length=${var.benchmark_cloud_init_rdma_prefix_length}",
    "benchmark_cloud_init_rdma_mtu=${var.benchmark_cloud_init_rdma_mtu}",
    "benchmark_vma_apply_setcap=${var.benchmark_vma_apply_setcap}",
    "benchmark_vma_lib_path=${var.benchmark_vma_lib_path}",
    var.benchmark_onload_command_vma == "" ? "benchmark_onload_command_vma=" : "benchmark_onload_command_vma=\"${var.benchmark_onload_command_vma}\"",
    "benchmark_aeron_socket_so_sndbuf=${var.benchmark_aeron_socket_so_sndbuf}",
    "benchmark_aeron_socket_so_rcvbuf=${var.benchmark_aeron_socket_so_rcvbuf}",
    "benchmark_aeron_rcv_initial_window_length=${var.benchmark_aeron_rcv_initial_window_length}",
    "benchmark_aeron_max_messages_per_send=${var.benchmark_aeron_max_messages_per_send}",
    "benchmark_aeron_receiver_io_vector_capacity=${var.benchmark_aeron_receiver_io_vector_capacity}",
    "benchmark_aeron_sender_io_vector_capacity=${var.benchmark_aeron_sender_io_vector_capacity}",
    "benchmark_install_vma_runtime=${var.benchmark_install_vma_runtime}",
    "benchmark_vma_build_from_source=${var.benchmark_vma_build_from_source}",
    "benchmark_vma_git_ref=${var.benchmark_vma_git_ref}",
    "enable_cluster_raft_consensus=${var.enable_cluster_raft_consensus}",
    "benchmark_block_volume_enabled=${var.benchmark_block_volume_enabled}",
    "benchmark_block_volume_size_gb=${var.benchmark_block_volume_size_gb}",
    "benchmark_block_volume_device=${var.benchmark_block_volume_device}",
    "benchmark_block_volume_attachment_type=${var.benchmark_block_volume_attachment_type}",
    "benchmark_block_volume_mount_path=${var.benchmark_block_volume_mount_path}",
  ])

  # Re-run Ansible on controller/benchmark/failover when matrix or echo tuning changes (not only playbooks.zip).
  benchmark_ansible_resync = sha256(join("|", [
    tostring(var.run_smoke_test),
    tostring(var.run_full_benchmark),
    var.run_benchmarks_matrix_modes,
    tostring(var.benchmark_echo_runs),
    tostring(var.benchmark_echo_iterations),
    tostring(var.benchmark_echo_warmup_iterations),
    var.benchmark_echo_warmup_message_rate,
    var.benchmark_tuning_profile,
    var.benchmark_cluster_udp_fabric,
    tostring(var.benchmark_message_length),
    var.benchmark_message_rate,
    tostring(var.benchmark_build_native_aeronmd),
    tostring(var.benchmark_ocpus),
    var.benchmark_cluster_cpu_affinity,
    tostring(var.grub_dynamic_cpu_isolation),
    tostring(var.grub_housekeeping_fraction),
    tostring(var.grub_housekeeping_floor),
    tostring(var.grub_housekeeping_cpus_max),
    var.benchmark_cpu_profile,
    var.benchmark_housekeeping_cpus_override,
    var.benchmark_isolated_cpus_override,
    var.benchmark_irq_affinity_override,
    var.benchmark_echo_client_pins,
    var.benchmark_echo_server_pins,
    tostring(var.enable_failover_node),
    local.failover_ad_effective,
    var.failover_shape,
    tostring(var.failover_ocpus),
    tostring(var.failover_memory_gb),
    tostring(var.install_oci_cn_auth),
    tostring(var.enable_rdma_compute_cluster),
    tostring(var.benchmark_cloud_init_rdma),
    var.benchmark_cloud_init_rdma_interface,
    tostring(var.benchmark_cloud_init_rdma_configure_netplan),
    var.benchmark_cloud_init_rdma_ipv4_prefix,
    tostring(var.benchmark_cloud_init_rdma_prefix_length),
    tostring(var.benchmark_cloud_init_rdma_mtu),
    tostring(var.enable_benchmark_cluster_network),
    tostring(var.enable_benchmark_instance_pool),
    tostring(var.benchmark_vma_apply_setcap),
    var.benchmark_vma_lib_path,
    var.benchmark_onload_command_vma,
    var.benchmark_aeron_socket_so_sndbuf,
    var.benchmark_aeron_socket_so_rcvbuf,
    var.benchmark_aeron_rcv_initial_window_length,
    var.benchmark_aeron_max_messages_per_send,
    var.benchmark_aeron_receiver_io_vector_capacity,
    var.benchmark_aeron_sender_io_vector_capacity,
    tostring(var.benchmark_install_vma_runtime),
    tostring(var.benchmark_vma_build_from_source),
    var.benchmark_vma_git_ref,
    tostring(var.enable_cluster_raft_consensus),
    tostring(local.benchmark_node_count_effective),
    tostring(var.benchmark_block_volume_enabled),
    tostring(var.benchmark_block_volume_size_gb),
    tostring(var.benchmark_block_volume_vpus_per_gb),
    var.benchmark_block_volume_device,
    var.benchmark_block_volume_attachment_type,
    var.benchmark_block_volume_mount_path,
    var.private_subnet_cidr,
    var.aeron_echo_udp_interface_prefix_length,
    var.aeron_echo_udp_named_interface,
  ]))

  # Driver matrix weighting: defaults (1/1/1) are a fast smoke pass for CI/Terraform; not comparable to docs/CHECKLIST.md full baselines.
  benchmark_driver_matrix_profile = (
    var.benchmark_echo_runs <= 1 && var.benchmark_echo_iterations <= 1 && var.benchmark_echo_warmup_iterations <= 1
  ) ? "smoke" : "extended"

  benchmark_driver_matrix_explanation = trimspace(<<-EOT
    Post-apply automation: run_smoke_test (default true) runs driver-matrix with fixed 1/1/1 overrides; run_full_benchmark (default false) runs a separate pass with full_benchmark_echo_* overrides. Aggregated JSON (terraform-matrix-summary.json) and CSVs are written on the controller under ~/benchmark-results, not in terraform output.
    Ansible-written benchmark-config.env still uses benchmark_echo_runs × benchmark_echo_iterations × benchmark_echo_warmup_iterations for manual runs; automated passes override those via MATRIX_OVERRIDE_* in run-driver-matrix.sh.
    Smoke (1/1/1): validates java/java_vma/c/c_vma end-to-end quickly; summary valid_runs is often a single-sample snapshot, not a stable baseline.
    Extended / full_automated: higher runs/iterations for HDR-style medians. For CHECKLIST.md style numbers you can also run manually with README recipes.
  EOT
  )

  # --- Post-apply driver matrix (remote-exec on controller; see null_resource.run_driver_matrix) ---
  post_deploy_matrix_enabled = var.run_smoke_test || var.run_full_benchmark

  matrix_echo_summary_smoke_filename = (var.run_smoke_test && var.run_full_benchmark) ? "driver-matrix-echo-summary-smoke.csv" : "driver-matrix-echo-summary.csv"

  matrix_cluster_summary_smoke_filename = (var.run_smoke_test && var.run_full_benchmark) ? "driver-matrix-cluster-summary-smoke.csv" : "driver-matrix-cluster-summary.csv"

  matrix_echo_smoke_log_basename = (var.run_smoke_test && var.run_full_benchmark) ? "run-driver-matrix-echo-smoke.log" : "run-driver-matrix-echo.log"

  matrix_cluster_smoke_log_basename = (var.run_smoke_test && var.run_full_benchmark) ? "run-driver-matrix-cluster-smoke.log" : "run-driver-matrix-cluster.log"

  matrix_echo_full_log_basename = (var.run_smoke_test && var.run_full_benchmark) ? "run-driver-matrix-echo-full.log" : "run-driver-matrix-echo.log"

  matrix_cluster_full_log_basename = (var.run_smoke_test && var.run_full_benchmark) ? "run-driver-matrix-cluster-full.log" : "run-driver-matrix-cluster.log"

  matrix_summary_tf_runs = var.run_full_benchmark ? var.full_benchmark_echo_runs : var.benchmark_echo_runs

  matrix_summary_tf_iters = var.run_full_benchmark ? var.full_benchmark_echo_iterations : var.benchmark_echo_iterations

  matrix_summary_tf_warm = var.run_full_benchmark ? var.full_benchmark_echo_warmup_iterations : var.benchmark_echo_warmup_iterations

  matrix_summary_tf_profile = var.run_full_benchmark ? "full_automated" : local.benchmark_driver_matrix_profile

  matrix_remote_exec_echo_smoke = [
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: smoke echo (MATRIX_OVERRIDE 1/1/1) modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
    "unset MATRIX_OVERRIDE_RUNS MATRIX_OVERRIDE_ITERATIONS MATRIX_OVERRIDE_WARMUP_ITERATIONS MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE MATRIX_OVERRIDE_MESSAGE_LENGTH MATRIX_OVERRIDE_MESSAGE_RATE MATRIX_OVERRIDE_MTU_VALUE MATRIX_OVERRIDE_BENCH_PROFILE 2>/dev/null || true",
    "export MATRIX_OVERRIDE_RUNS=1",
    "export MATRIX_OVERRIDE_ITERATIONS=1",
    "export MATRIX_OVERRIDE_WARMUP_ITERATIONS=1",
    "export MATRIX_MODE_TIMEOUT_SEC=900",
    "export SUMMARY_FILE=\"$RESULTS_DIR/${local.matrix_echo_summary_smoke_filename}\"",
    "set +e; ./run-driver-matrix.sh echo > \"$RESULTS_DIR/${local.matrix_echo_smoke_log_basename}\" 2>&1; matrix_ec=$?; set -e; tail -120 \"$RESULTS_DIR/${local.matrix_echo_smoke_log_basename}\" || true",
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: smoke echo finished exit=$${matrix_ec}\" | tee -a \"$STATUS_FILE\"",
    "if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi",
    "cp -f ./aeron-echo-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
  ]

  matrix_remote_exec_echo_full = [
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: full benchmark echo (MATRIX_OVERRIDE ${var.full_benchmark_echo_runs}/${var.full_benchmark_echo_iterations}/${var.full_benchmark_echo_warmup_iterations}) modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
    "unset MATRIX_OVERRIDE_RUNS MATRIX_OVERRIDE_ITERATIONS MATRIX_OVERRIDE_WARMUP_ITERATIONS MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE MATRIX_OVERRIDE_MESSAGE_LENGTH MATRIX_OVERRIDE_MESSAGE_RATE MATRIX_OVERRIDE_MTU_VALUE MATRIX_OVERRIDE_BENCH_PROFILE 2>/dev/null || true",
    "export MATRIX_OVERRIDE_RUNS=${var.full_benchmark_echo_runs}",
    "export MATRIX_OVERRIDE_ITERATIONS=${var.full_benchmark_echo_iterations}",
    "export MATRIX_OVERRIDE_WARMUP_ITERATIONS=${var.full_benchmark_echo_warmup_iterations}",
    "export MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE=${var.full_benchmark_warmup_message_rate}",
    "export MATRIX_OVERRIDE_MESSAGE_LENGTH=${var.full_benchmark_message_length}",
    "export MATRIX_OVERRIDE_MESSAGE_RATE=${var.full_benchmark_message_rate}",
    "export MATRIX_OVERRIDE_BENCH_PROFILE=${var.full_benchmark_bench_profile}",
    "export MATRIX_MODE_TIMEOUT_SEC=${var.full_benchmark_matrix_mode_timeout_sec}",
    "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-echo-summary.csv\"",
    "set +e; ./run-driver-matrix.sh echo > \"$RESULTS_DIR/${local.matrix_echo_full_log_basename}\" 2>&1; matrix_ec=$?; set -e; tail -120 \"$RESULTS_DIR/${local.matrix_echo_full_log_basename}\" || true",
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: full echo finished exit=$${matrix_ec}\" | tee -a \"$STATUS_FILE\"",
    "if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi",
    "cp -f ./aeron-echo-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
  ]

  matrix_remote_exec_cluster_smoke = [
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: smoke cluster (MATRIX_OVERRIDE 1/1/1) modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
    "unset MATRIX_OVERRIDE_RUNS MATRIX_OVERRIDE_ITERATIONS MATRIX_OVERRIDE_WARMUP_ITERATIONS MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE MATRIX_OVERRIDE_MESSAGE_LENGTH MATRIX_OVERRIDE_MESSAGE_RATE MATRIX_OVERRIDE_MTU_VALUE MATRIX_OVERRIDE_BENCH_PROFILE 2>/dev/null || true",
    "export MATRIX_OVERRIDE_RUNS=1",
    "export MATRIX_OVERRIDE_ITERATIONS=1",
    "export MATRIX_OVERRIDE_WARMUP_ITERATIONS=1",
    "export MATRIX_MODE_TIMEOUT_SEC=900",
    "export SUMMARY_FILE=\"$RESULTS_DIR/${local.matrix_cluster_summary_smoke_filename}\"",
    "export MATRIX_STRICT=1",
    "set +e; ./run-driver-matrix.sh cluster > \"$RESULTS_DIR/${local.matrix_cluster_smoke_log_basename}\" 2>&1; matrix_ec=$?; set -e; tail -120 \"$RESULTS_DIR/${local.matrix_cluster_smoke_log_basename}\" || true",
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: smoke cluster finished exit=$${matrix_ec}\" | tee -a \"$STATUS_FILE\"",
    "if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi",
    "cp -f ./aeron-cluster-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
  ]

  matrix_remote_exec_cluster_full = [
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: full benchmark cluster modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
    "unset MATRIX_OVERRIDE_RUNS MATRIX_OVERRIDE_ITERATIONS MATRIX_OVERRIDE_WARMUP_ITERATIONS MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE MATRIX_OVERRIDE_MESSAGE_LENGTH MATRIX_OVERRIDE_MESSAGE_RATE MATRIX_OVERRIDE_MTU_VALUE MATRIX_OVERRIDE_BENCH_PROFILE 2>/dev/null || true",
    "export MATRIX_OVERRIDE_RUNS=${var.full_benchmark_echo_runs}",
    "export MATRIX_OVERRIDE_ITERATIONS=${var.full_benchmark_echo_iterations}",
    "export MATRIX_OVERRIDE_WARMUP_ITERATIONS=${var.full_benchmark_echo_warmup_iterations}",
    "export MATRIX_OVERRIDE_WARMUP_MESSAGE_RATE=${var.full_benchmark_warmup_message_rate}",
    "export MATRIX_OVERRIDE_MESSAGE_LENGTH=${var.full_benchmark_message_length}",
    "export MATRIX_OVERRIDE_MESSAGE_RATE=${var.full_benchmark_message_rate}",
    "export MATRIX_OVERRIDE_BENCH_PROFILE=${var.full_benchmark_bench_profile}",
    "export MATRIX_MODE_TIMEOUT_SEC=${var.full_benchmark_matrix_mode_timeout_sec}",
    "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-cluster-summary.csv\"",
    "export MATRIX_STRICT=1",
    "set +e; ./run-driver-matrix.sh cluster > \"$RESULTS_DIR/${local.matrix_cluster_full_log_basename}\" 2>&1; matrix_ec=$?; set -e; tail -120 \"$RESULTS_DIR/${local.matrix_cluster_full_log_basename}\" || true",
    "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: full cluster finished exit=$${matrix_ec}\" | tee -a \"$STATUS_FILE\"",
    "if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi",
    "cp -f ./aeron-cluster-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
  ]

  # Image selection: default regular Ubuntu 24.04 > marketplace selection > custom OCID
  compute_image = var.use_default_image ? data.oci_core_images.ubuntu_minimal.images[0].id : (var.custom_image_ocid != "" ? var.custom_image_ocid : data.oci_core_images.marketplace_image.images[0].id)

  # Platform config types for bare metal shapes
  benchmark_platform_config_type = contains(["BM.Standard.E4.128", "BM.Standard.E5.192", "BM.DenseIO.E4.128", "BM.DenseIO.E5.128"], var.benchmark_shape) ? "AMD_MILAN_BM" : contains(["BM.Standard.E3.128", "BM.DenseIO.E3.128"], var.benchmark_shape) ? "AMD_ROME_BM" : null

  failover_platform_config_type = contains(["BM.Standard.E4.128", "BM.Standard.E5.192", "BM.DenseIO.E4.128", "BM.DenseIO.E5.128"], var.failover_shape) ? "AMD_MILAN_BM" : contains(["BM.Standard.E3.128", "BM.DenseIO.E3.128"], var.failover_shape) ? "AMD_ROME_BM" : null

}

resource "random_pet" "name" {
  length = 2
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
