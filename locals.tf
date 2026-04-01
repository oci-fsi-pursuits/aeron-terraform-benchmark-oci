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
  vnic_hostname_prefix = substr(trim(local.vnic_label_slug_collapse, "-"), 0, 44)
  vnic_hostname_prefix_final = length(local.vnic_hostname_prefix) > 0 ? local.vnic_hostname_prefix : substr(md5(local.cluster_name), 0, 8)

  vcn_compartment = var.vcn_compartment_ocid != "" ? var.vcn_compartment_ocid : var.compartment_ocid

  vcn_id = var.use_existing_vcn ? var.existing_vcn_id : oci_core_vcn.aeron_vcn[0].id

  # Controller goes in public subnet, benchmark/failover nodes in private subnet
  public_subnet_id  = var.use_existing_vcn ? var.existing_public_subnet_id : oci_core_subnet.public_subnet[0].id
  private_subnet_id = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.private_subnet[0].id

  enable_benchmark_cluster_placement_group = (
    var.benchmark_cluster_placement_group == "on" ||
    (var.benchmark_cluster_placement_group == "auto" && !var.use_existing_vcn)
  )

  # Flex shape detection
  is_controller_flex_shape = length(regexall(".*Flex$", var.controller_shape)) > 0
  is_benchmark_flex_shape  = length(regexall(".*Flex$", var.benchmark_shape)) > 0
  is_failover_flex_shape   = length(regexall(".*Flex$", var.failover_shape)) > 0

  # Host IPs for SSH connections
  controller_host = var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip

  # aeron-io/benchmarks: echo (~13000/13100), cluster (~20000+), dynamic response ports — NSG/iptables use a wide UDP range.
  aeron_benchmark_udp_ingress_cidr = trimspace(var.aeron_benchmark_udp_ingress_cidr) != "" ? trimspace(var.aeron_benchmark_udp_ingress_cidr) : (
    var.use_existing_vcn ? data.oci_core_vcn.existing[0].cidr_blocks[0] : var.vcn_cidr_block
  )

  # run_driver_matrix remote-exec: stop stale drivers, then sudo rm driver dirs (/dev/shm sticky EPERM + home AERON_DIR from wrappers).
  benchmark_dev_shm_cleanup = join(" && ", [
    for ip in oci_core_instance.benchmark[*].private_ip :
    "ssh -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no -o BatchMode=yes ${var.ssh_username}@${ip} 'sudo pkill -f io.aeron.driver.MediaDriver 2>/dev/null || true; sudo pkill -f io.aeron.benchmarks.LoadTestRig 2>/dev/null || true; sudo pkill -f aeronmd 2>/dev/null || true; sleep 3; sudo rm -rf /dev/shm/aeron /home/${var.ssh_username}/aeron-benchmark-shm'"
  ])

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
    "benchmark_cluster_cpu_affinity=${var.benchmark_cluster_cpu_affinity}",
  ])

  # Re-run Ansible on controller/benchmark/failover when matrix or echo tuning changes (not only playbooks.zip).
  benchmark_ansible_resync = sha256(join("|", [
    tostring(var.run_benchmarks),
    var.run_benchmarks_matrix_modes,
    tostring(var.benchmark_echo_runs),
    tostring(var.benchmark_echo_iterations),
    tostring(var.benchmark_echo_warmup_iterations),
    var.benchmark_echo_warmup_message_rate,
    tostring(var.benchmark_message_length),
    var.benchmark_message_rate,
    tostring(var.benchmark_build_native_aeronmd),
    tostring(var.benchmark_ocpus),
    var.benchmark_cluster_cpu_affinity,
  ]))

  # Driver matrix weighting: defaults (1/1/1) are a fast smoke pass for CI/Terraform; not comparable to docs/CHECKLIST.md full baselines.
  benchmark_driver_matrix_profile = (
    var.benchmark_echo_runs <= 1 && var.benchmark_echo_iterations <= 1 && var.benchmark_echo_warmup_iterations <= 1
    ) ? "smoke" : "extended"

  benchmark_driver_matrix_explanation = trimspace(<<-EOT
    Automated driver matrix (${local.benchmark_driver_matrix_profile}): uses benchmark_echo_runs × benchmark_echo_iterations × benchmark_echo_warmup_iterations from Terraform/Ansible.
    Smoke (typically 1/1/1): validates java/java_vma/c/c_vma end-to-end quickly; summary CSV valid_runs is the number of successful aggregated runs per mode — often 1, so medians are a single-sample snapshot, not a stable baseline.
    Extended (higher runs/iterations): medians become more representative; p99/p999 usually stabilize more than p50. Three outer RUNS (e.g. 3/1/1) still use one measurement iteration per run but give three independent snapshots — typically same order of magnitude as 1/1/1 if the stack is healthy, with slightly more confidence against single-run noise.
    For CHECKLIST.md / BENCHMARK-NODE-OPTIMIZATION-NOTES.md style numbers, use many runs and iterations (e.g. latency_288_101k profile: runs=5, iterations=30, warmup=10) — not the Terraform defaults.
  EOT
  )

  # Image selection: default Ubuntu 24.04 Minimal > marketplace selection > custom OCID
  compute_image = var.use_default_image ? data.oci_core_images.ubuntu_minimal.images[0].id : (var.custom_image_ocid != "" ? var.custom_image_ocid : data.oci_core_images.marketplace_image.images[0].id)

  # Platform config types for bare metal shapes
  benchmark_platform_config_type = contains(["BM.Standard.E4.128", "BM.Standard.E5.192", "BM.DenseIO.E4.128", "BM.DenseIO.E5.128"], var.benchmark_shape) ? "AMD_MILAN_BM" : contains(["BM.Standard.E3.128", "BM.DenseIO.E3.128"], var.benchmark_shape) ? "AMD_ROME_BM" : null

  failover_platform_config_type = contains(["BM.Standard.E4.128", "BM.Standard.E5.192", "BM.DenseIO.E4.128", "BM.DenseIO.E5.128"], var.failover_shape) ? "AMD_MILAN_BM" : contains(["BM.Standard.E3.128", "BM.DenseIO.E3.128"], var.failover_shape) ? "AMD_ROME_BM" : null

  # Pulled by null_resource.benchmark_matrix_summary_pull after matrix (see matrix_summary.tf). try() if file missing during plan.
  terraform_matrix_summary_json = try(jsondecode(file(abspath("${path.module}/.terraform-matrix-summary.json"))), null)
}

resource "random_pet" "name" {
  length = 2
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
