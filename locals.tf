locals {
  cluster_name = var.use_custom_name ? var.cluster_name : "${var.cluster_name}-${random_pet.name.id}"

  vcn_compartment = var.vcn_compartment_ocid != "" ? var.vcn_compartment_ocid : var.compartment_ocid

  vcn_id = var.use_existing_vcn ? var.existing_vcn_id : oci_core_vcn.aeron_vcn[0].id
  
  # Controller goes in public subnet, benchmark/failover nodes in private subnet
  public_subnet_id  = var.use_existing_vcn ? var.existing_public_subnet_id : oci_core_subnet.public_subnet[0].id
  private_subnet_id = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.private_subnet[0].id

  # Flex shape detection
  is_controller_flex_shape = length(regexall(".*Flex$", var.controller_shape)) > 0
  is_benchmark_flex_shape  = length(regexall(".*Flex$", var.benchmark_shape)) > 0
  is_failover_flex_shape   = length(regexall(".*Flex$", var.failover_shape)) > 0

  # Host IPs for SSH connections
  controller_host = var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip

  # aeron-io/benchmarks two-node echo uses UDP destination ports in this range (e.g. 13000, 13100).
  aeron_benchmark_udp_ingress_cidr = trimspace(var.aeron_benchmark_udp_ingress_cidr) != "" ? trimspace(var.aeron_benchmark_udp_ingress_cidr) : (
    var.use_existing_vcn ? data.oci_core_vcn.existing[0].cidr_blocks[0] : var.vcn_cidr_block
  )

  # run_driver_matrix remote-exec: clear root-owned /dev/shm/aeron on each benchmark VM (MediaDriver needs to recreate it).
  benchmark_dev_shm_cleanup = join(" && ", [
    for ip in oci_core_instance.benchmark[*].private_ip :
    "ssh -i /opt/aeron/.ssh/deploy_key -o StrictHostKeyChecking=no -o BatchMode=yes ${var.ssh_username}@${ip} 'sudo rm -rf /dev/shm/aeron'"
  ])

  # Image selection: default Ubuntu 24.04 Minimal > marketplace selection > custom OCID
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
