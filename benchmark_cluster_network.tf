# =============================================================================
# Optional benchmark pooled launch paths
#
# The normal deployment launches benchmark nodes directly with oci_core_instance.
# These modes launch nodes from a shared instance configuration through either a
# regular instance pool or, for supported shapes, an OCI cluster network.
# =============================================================================

resource "oci_core_instance_configuration" "benchmark_pool" {
  count = local.enable_benchmark_pooled_instances ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = "${local.cluster_name}-benchmark-pool-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      availability_domain        = local.benchmark_ad_effective
      compartment_id             = var.compartment_ocid
      shape                      = var.benchmark_shape
      cluster_placement_group_id = local.enable_benchmark_cluster_network ? null : local.benchmark_cluster_placement_group_id
      display_name               = "${local.cluster_name}-benchmark"

      dynamic "shape_config" {
        for_each = local.is_benchmark_flex_shape ? [1] : []
        content {
          ocpus         = var.benchmark_ocpus
          memory_in_gbs = var.benchmark_memory_gb
        }
      }

      dynamic "platform_config" {
        for_each = !local.is_benchmark_bm_shape && (local.benchmark_platform_config_type != null || !var.hyperthreading) ? [1] : []
        content {
          type                                           = local.benchmark_platform_config_type != null ? local.benchmark_platform_config_type : local.is_benchmark_intel_vm_shape ? "INTEL_VM" : "AMD_VM"
          is_symmetric_multi_threading_enabled           = var.hyperthreading
          are_virtual_instructions_enabled               = false
          is_access_control_service_enabled              = false
          is_input_output_memory_management_unit_enabled = false
        }
      }

      source_details {
        source_type             = "image"
        image_id                = local.compute_image
        boot_volume_size_in_gbs = tostring(var.benchmark_boot_volume_size_gb)
        boot_volume_vpus_per_gb = "20"
      }

      launch_options {
        network_type = "VFIO"
      }

      create_vnic_details {
        assign_public_ip = false
        nsg_ids          = [oci_core_network_security_group.aeron_benchmark.id]
      }

      metadata = {
        ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
        user_data = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
          ssh_username            = var.ssh_username
          hyperthreading          = var.hyperthreading
          install_aeron           = var.install_aeron
          java_version            = var.java_version
          rdma_cloud_init_enabled = var.benchmark_cloud_init_rdma
          rdma_use_oca_plugin     = var.rdma_enable_hpc_plugins
          rdma_interface          = var.benchmark_cloud_init_rdma_interface
          rdma_configure_netplan  = var.benchmark_cloud_init_rdma_configure_netplan
          rdma_ipv4_prefix        = var.benchmark_cloud_init_rdma_ipv4_prefix
          rdma_ipv4_prefix_length = var.benchmark_cloud_init_rdma_prefix_length
          rdma_mtu                = var.benchmark_cloud_init_rdma_mtu
          rdma_apt_packages       = var.benchmark_cloud_init_rdma_apt_packages
          rdma_extra_commands     = var.benchmark_cloud_init_rdma_extra_commands
        }))
      }

      agent_config {
        is_management_disabled = false
        is_monitoring_disabled = false
        plugins_config {
          desired_state = "ENABLED"
          name          = "Compute Instance Monitoring"
        }
        dynamic "plugins_config" {
          for_each = var.benchmark_block_volume_enabled && lower(trimspace(var.benchmark_block_volume_attachment_type)) == "iscsi" ? [1] : []
          content {
            desired_state = "ENABLED"
            name          = "Block Volume Management"
          }
        }
        dynamic "plugins_config" {
          for_each = var.benchmark_cloud_init_rdma || var.enable_rdma_compute_cluster ? [1] : []
          content {
            desired_state = var.rdma_enable_hpc_plugins ? "ENABLED" : "DISABLED"
            name          = "Compute HPC RDMA Authentication"
          }
        }
        dynamic "plugins_config" {
          for_each = var.benchmark_cloud_init_rdma || var.enable_rdma_compute_cluster ? [1] : []
          content {
            desired_state = var.rdma_enable_hpc_plugins ? "ENABLED" : "DISABLED"
            name          = "Compute HPC RDMA Auto-Configuration"
          }
        }
      }

      freeform_tags = {
        cluster_name = local.cluster_name
        role         = "benchmark"
        aeron        = "true"
      }
    }
  }

  lifecycle {
    create_before_destroy = true

    ignore_changes = [
      instance_details[0].launch_details[0].source_details[0].image_id,
      instance_details[0].launch_details[0].metadata,
    ]
  }
}

resource "oci_core_cluster_network" "benchmark" {
  count      = local.enable_benchmark_cluster_network ? 1 : 0
  depends_on = [null_resource.benchmark_cpg_ready]

  compartment_id = var.compartment_ocid
  display_name   = "${local.cluster_name}-benchmark-cn"

  placement_configuration {
    availability_domain = local.benchmark_ad_effective
    primary_subnet_id   = local.private_subnet_id
  }

  instance_pools {
    instance_configuration_id = oci_core_instance_configuration.benchmark_pool[0].id
    size                      = local.benchmark_node_count_effective
    display_name              = "${local.cluster_name}-benchmark-pool"
  }

  freeform_tags = {
    cluster_name = local.cluster_name
    role         = "benchmark-cluster-network"
    aeron        = "true"
  }
}

resource "oci_core_instance_pool" "benchmark" {
  count      = local.enable_benchmark_instance_pool ? 1 : 0
  depends_on = [null_resource.benchmark_cpg_ready]

  compartment_id            = var.compartment_ocid
  display_name              = "${local.cluster_name}-benchmark-pool"
  instance_configuration_id = oci_core_instance_configuration.benchmark_pool[0].id
  size                      = local.benchmark_node_count_effective

  placement_configurations {
    availability_domain = local.benchmark_ad_effective
    primary_subnet_id   = local.private_subnet_id
  }

  freeform_tags = {
    cluster_name = local.cluster_name
    role         = "benchmark-instance-pool"
    aeron        = "true"
  }

  timeouts {
    create = "3h"
    update = "3h"
    delete = "1h"
  }
}

data "oci_core_instance_pool_instances" "benchmark" {
  count = local.enable_benchmark_pooled_instances ? 1 : 0

  compartment_id   = var.compartment_ocid
  instance_pool_id = local.benchmark_instance_pool_id

  depends_on = [
    oci_core_cluster_network.benchmark,
    oci_core_instance_pool.benchmark,
  ]
}

data "oci_core_instance" "benchmark_pool" {
  count = local.enable_benchmark_pooled_instances ? local.benchmark_node_count_effective : 0

  instance_id = data.oci_core_instance_pool_instances.benchmark[0].instances[count.index].id

  depends_on = [data.oci_core_instance_pool_instances.benchmark]
}
