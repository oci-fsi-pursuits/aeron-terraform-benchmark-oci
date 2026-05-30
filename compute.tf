# =============================================================================
# Playbooks archive (single file upload avoids directory provisioner failures)
# =============================================================================
data "archive_file" "playbooks" {
  type        = "zip"
  source_dir  = "${path.module}/playbooks"
  output_path = "${path.module}/playbooks.zip"
}

# =============================================================================
# Controller Node (Public Subnet - Orchestrator)
# =============================================================================
resource "oci_core_instance" "controller" {
  availability_domain = local.controller_ad_effective
  compartment_id      = var.compartment_ocid
  shape               = var.controller_shape
  display_name        = "${local.cluster_name}-controller"

  dynamic "shape_config" {
    for_each = local.is_controller_flex_shape ? [1] : []
    content {
      ocpus         = var.controller_ocpus
      memory_in_gbs = var.controller_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.compute_image
    boot_volume_size_in_gbs = var.controller_boot_volume_size_gb
    boot_volume_vpus_per_gb = 10
  }

  launch_options {
    network_type = "VFIO"
  }

  create_vnic_details {
    subnet_id        = local.public_subnet_id
    assign_public_ip = !var.private_deployment
    hostname_label   = substr("${local.vnic_hostname_prefix_final}-controller", 0, 63)
  }

  metadata = {
    ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
    user_data = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
      ssh_username            = var.ssh_username
      hyperthreading          = true
      install_aeron           = var.install_aeron
      java_version            = var.java_version
      rdma_cloud_init_enabled = false
      rdma_use_oca_plugin     = false
      rdma_interface          = var.benchmark_cloud_init_rdma_interface
      rdma_configure_netplan  = false
      rdma_ipv4_prefix        = ""
      rdma_ipv4_prefix_length = var.benchmark_cloud_init_rdma_prefix_length
      rdma_mtu                = var.benchmark_cloud_init_rdma_mtu
      rdma_apt_packages       = var.benchmark_cloud_init_rdma_apt_packages
      rdma_extra_commands     = []
    }))
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
  }

  freeform_tags = {
    cluster_name = local.cluster_name
    role         = "controller"
    aeron        = "true"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      metadata,
    ]
  }
}

# =============================================================================
# Benchmark Nodes (Private Subnet - Client/Receiver)
# =============================================================================
resource "oci_core_instance" "benchmark" {
  count               = local.enable_benchmark_direct_instances ? local.benchmark_node_count_effective : 0
  depends_on          = [null_resource.benchmark_cpg_ready]
  availability_domain = local.benchmark_ad_effective
  compartment_id      = var.compartment_ocid
  shape               = var.benchmark_shape
  display_name        = "${local.cluster_name}-${count.index == 0 ? "client" : count.index == 1 ? "receiver" : format("node-%d", count.index + 1)}"

  compute_cluster_id         = local.benchmark_compute_cluster_id
  cluster_placement_group_id = local.benchmark_cluster_placement_group_id

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
    source_id               = local.compute_image
    boot_volume_size_in_gbs = var.benchmark_boot_volume_size_gb
    boot_volume_vpus_per_gb = 20
  }

  launch_options {
    network_type = "VFIO"
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    hostname_label = substr(
      "${local.vnic_hostname_prefix_final}-${
        count.index == 0 ? "client" : count.index == 1 ? "receiver" : format("node%d", count.index + 1)
      }",
      0,
      63
    )
    nsg_ids = [oci_core_network_security_group.aeron_benchmark.id]
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
    role         = count.index == 0 ? "client" : count.index == 1 ? "receiver" : format("cluster-node-%d", count.index - 1)
    node_index   = tostring(count.index + 1)
    aeron        = "true"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}

# =============================================================================
# Failover Node (Private Subnet - Different AD)
# =============================================================================
resource "terraform_data" "failover_shape_replacement" {
  count = var.enable_failover_node ? 1 : 0

  input = {
    shape     = var.failover_shape
    ocpus     = local.is_failover_flex_shape ? var.failover_ocpus : null
    memory_gb = local.is_failover_flex_shape ? var.failover_memory_gb : null
  }

  triggers_replace = [
    var.failover_shape,
    local.is_failover_flex_shape ? tostring(var.failover_ocpus) : "",
    local.is_failover_flex_shape ? tostring(var.failover_memory_gb) : "",
  ]
}

resource "oci_core_instance" "failover" {
  count               = var.enable_failover_node ? 1 : 0
  availability_domain = local.failover_ad_effective
  compartment_id      = var.compartment_ocid
  shape               = var.failover_shape
  display_name        = "${local.cluster_name}-failover"

  dynamic "shape_config" {
    for_each = local.is_failover_flex_shape ? [1] : []
    content {
      ocpus         = var.failover_ocpus
      memory_in_gbs = var.failover_memory_gb
    }
  }

  dynamic "platform_config" {
    for_each = !local.is_failover_bm_shape && (local.failover_platform_config_type != null || !var.hyperthreading) ? [1] : []
    content {
      type                                           = local.failover_platform_config_type != null ? local.failover_platform_config_type : local.is_failover_intel_vm_shape ? "INTEL_VM" : "AMD_VM"
      is_symmetric_multi_threading_enabled           = var.hyperthreading
      are_virtual_instructions_enabled               = false
      is_access_control_service_enabled              = false
      is_input_output_memory_management_unit_enabled = false
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.compute_image
    boot_volume_size_in_gbs = var.failover_boot_volume_size_gb
    boot_volume_vpus_per_gb = 20
  }

  launch_options {
    network_type = "VFIO"
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    hostname_label   = substr("${local.vnic_hostname_prefix_final}-failover", 0, 63)
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
    role         = "failover"
    aeron        = "true"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      metadata,
      launch_options,
    ]
    replace_triggered_by = [
      terraform_data.failover_shape_replacement[count.index],
    ]
  }
}

# =============================================================================
# Provisioner for Controller Node
# =============================================================================
resource "null_resource" "controller_provisioner" {
  depends_on = [
    oci_core_instance.controller,
    oci_core_instance.benchmark,
    oci_core_cluster_network.benchmark,
    oci_core_instance_pool.benchmark,
    data.oci_core_instance.benchmark_pool,
    oci_core_volume_attachment.benchmark_data,
  ]

  triggers = {
    instance_id                            = oci_core_instance.controller.id
    playbooks_bundle                       = data.archive_file.playbooks.id
    provisioner_rev                        = "2026-04-06-known-hosts-ubuntu-home"
    benchmark_ansible_resync               = local.benchmark_ansible_resync
    enable_cluster_raft_consensus          = tostring(var.enable_cluster_raft_consensus)
    benchmark_block_volume_enabled         = tostring(var.benchmark_block_volume_enabled)
    benchmark_block_volume_attachment_type = lower(trimspace(var.benchmark_block_volume_attachment_type))
    benchmark_block_volume_device          = trimspace(var.benchmark_block_volume_device)
    benchmark_block_volume_mount_path      = trimspace(var.benchmark_block_volume_mount_path)
  }

  connection {
    type        = "ssh"
    host        = local.controller_host
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait || true",
      "echo 'Controller node provisioning complete'",
    ]
  }

  provisioner "file" {
    source      = data.archive_file.playbooks.output_path
    destination = "/tmp/playbooks.zip"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      local.bootstrap_ansible_prereqs,
      "rm -rf /tmp/playbooks",
      "mkdir -p /tmp/playbooks",
      "unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks",
      "rm -f /tmp/playbooks.zip",
      "sudo mkdir -p /opt/aeron",
      "sudo rm -rf /opt/aeron/playbooks",
      "sudo mv /tmp/playbooks /opt/aeron/playbooks",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron/playbooks",
      "echo 'Playbooks deployed to /opt/aeron/playbooks'",
    ]
  }

  # Copy deploy key so controller can SSH to benchmark nodes (for benchmarks-dist deploy)
  provisioner "file" {
    content     = tls_private_key.ssh.private_key_pem
    destination = "/tmp/deploy_key.pem"
  }

  provisioner "file" {
    content     = tls_private_key.ssh.public_key_openssh
    destination = "/tmp/deploy_key.pub"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "mkdir -p /home/${var.ssh_username}/.ssh",
      "cp -f /tmp/deploy_key.pem /home/${var.ssh_username}/.ssh/aeron-node-priv.key",
      "cp -f /tmp/deploy_key.pub /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "touch /home/${var.ssh_username}/.ssh/authorized_keys",
      "grep -q -F -f /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub /home/${var.ssh_username}/.ssh/authorized_keys || cat /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub >> /home/${var.ssh_username}/.ssh/authorized_keys",
      "chmod 700 /home/${var.ssh_username}/.ssh",
      "chmod 600 /home/${var.ssh_username}/.ssh/aeron-node-priv.key /home/${var.ssh_username}/.ssh/authorized_keys",
      "chmod 644 /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "sudo mkdir -p /opt/aeron/.ssh",
      "sudo mv /tmp/deploy_key.pem /opt/aeron/.ssh/deploy_key",
      "sudo chmod 600 /opt/aeron/.ssh/deploy_key",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron/.ssh /home/${var.ssh_username}/.ssh",
    ]
  }

  provisioner "remote-exec" {
    inline = var.install_aeron ? [
      "set -e",
      "echo 'Running Ansible (Aeron, benchmarks repo, and wrapper setup)...'",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) controller-provisioner: ansible-start\" | tee -a /home/${var.ssh_username}/benchmark-status.txt",
      "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${local.aeron_echo_udp_interface_prefix_length_resolved} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=controller client_node_ip=${local.benchmark_private_ips[0]} receiver_node_ip=${local.benchmark_private_ips[1]} failover_node_ip=${var.enable_failover_node ? oci_core_instance.failover[0].private_ip : ""} benchmark_node_ips=${join(",", local.benchmark_private_ips)} ${local.ansible_benchmark_env_extra}' -v",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) controller-provisioner: ansible-complete\" | tee -a /home/${var.ssh_username}/benchmark-status.txt",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
      "echo 'Ansible complete. Check /opt/aeron/benchmarks-dist and /opt/aeron/scripts'",
      ] : [
      "echo 'Skipping Aeron installation (install_aeron=false)'",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
    ]
  }
}

# =============================================================================
# Provisioner for Benchmark Nodes (via Controller bastion)
# =============================================================================
resource "null_resource" "benchmark_provisioner" {
  count = local.benchmark_node_count_effective
  depends_on = [
    oci_core_instance.benchmark,
    oci_core_cluster_network.benchmark,
    oci_core_instance_pool.benchmark,
    data.oci_core_instance.benchmark_pool,
    null_resource.controller_provisioner,
    oci_core_volume_attachment.benchmark_data,
    null_resource.benchmark_iscsi_login,
  ]

  triggers = {
    instance_id                            = local.benchmark_instance_ids[count.index]
    benchmark_ocpus                        = tostring(var.benchmark_ocpus)
    benchmark_memory_gb                    = tostring(var.benchmark_memory_gb)
    playbooks_bundle                       = data.archive_file.playbooks.id
    provisioner_rev                        = "2026-04-06-known-hosts-ubuntu-home"
    benchmark_ansible_resync               = local.benchmark_ansible_resync
    enable_cluster_raft_consensus          = tostring(var.enable_cluster_raft_consensus)
    benchmark_block_volume_enabled         = tostring(var.benchmark_block_volume_enabled)
    benchmark_block_volume_attachment_type = lower(trimspace(var.benchmark_block_volume_attachment_type))
    benchmark_block_volume_device          = trimspace(var.benchmark_block_volume_device)
    benchmark_block_volume_mount_path      = trimspace(var.benchmark_block_volume_mount_path)
    benchmark_data_attachment_id           = var.benchmark_block_volume_enabled ? oci_core_volume_attachment.benchmark_data[count.index].id : ""
  }

  connection {
    type        = "ssh"
    host        = local.benchmark_private_ips[count.index]
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "15m"

    bastion_host        = local.controller_host
    bastion_user        = var.ssh_username
    bastion_private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait || true",
      "echo 'Benchmark node ${count.index + 1} provisioning complete'",
    ]
  }

  provisioner "file" {
    source      = data.archive_file.playbooks.output_path
    destination = "/tmp/playbooks.zip"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      local.bootstrap_ansible_prereqs,
      "rm -rf /tmp/playbooks",
      "mkdir -p /tmp/playbooks",
      "unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks",
      "rm -f /tmp/playbooks.zip",
      "sudo mkdir -p /opt/aeron",
      "sudo rm -rf /opt/aeron/playbooks",
      "sudo mv /tmp/playbooks /opt/aeron/playbooks",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${local.aeron_echo_udp_interface_prefix_length_resolved} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=${count.index == 0 ? "client" : count.index == 1 ? "receiver" : format("node%d", count.index - 1)} client_node_ip=${local.benchmark_private_ips[0]} receiver_node_ip=${local.benchmark_private_ips[1]} failover_node_ip=${var.enable_failover_node ? oci_core_instance.failover[0].private_ip : ""} benchmark_node_ips=${join(",", local.benchmark_private_ips)} ${local.ansible_benchmark_env_extra}'" : "echo 'Skipping Aeron installation'",
    ]
  }

  # Distribute same SSH key so nodes can SSH between each other passwordlessly.
  provisioner "file" {
    content     = tls_private_key.ssh.private_key_pem
    destination = "/tmp/deploy_key.pem"
  }

  provisioner "file" {
    content     = tls_private_key.ssh.public_key_openssh
    destination = "/tmp/deploy_key.pub"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "mkdir -p /home/${var.ssh_username}/.ssh",
      "mv /tmp/deploy_key.pem /home/${var.ssh_username}/.ssh/aeron-node-priv.key",
      "mv /tmp/deploy_key.pub /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "chmod 700 /home/${var.ssh_username}/.ssh",
      "chmod 600 /home/${var.ssh_username}/.ssh/aeron-node-priv.key",
      "chmod 644 /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "touch /home/${var.ssh_username}/.ssh/authorized_keys",
      "grep -q -F -f /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub /home/${var.ssh_username}/.ssh/authorized_keys || cat /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub >> /home/${var.ssh_username}/.ssh/authorized_keys",
      "chmod 600 /home/${var.ssh_username}/.ssh/authorized_keys",
      "sudo mkdir -p /opt/aeron/.ssh",
      "sudo cp /home/${var.ssh_username}/.ssh/aeron-node-priv.key /opt/aeron/.ssh/deploy_key",
      "sudo chmod 600 /opt/aeron/.ssh/deploy_key",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron/.ssh /home/${var.ssh_username}/.ssh",
    ]
  }
}

# =============================================================================
# Provisioner for Failover Node (via Controller bastion)
# =============================================================================
resource "null_resource" "failover_provisioner" {
  count      = var.enable_failover_node ? 1 : 0
  depends_on = [oci_core_instance.failover, null_resource.controller_provisioner]

  triggers = {
    instance_id              = oci_core_instance.failover[0].id
    failover_ocpus           = tostring(var.failover_ocpus)
    failover_memory_gb       = tostring(var.failover_memory_gb)
    playbooks_bundle         = data.archive_file.playbooks.id
    provisioner_rev          = "2026-04-06-known-hosts-ubuntu-home"
    benchmark_ansible_resync = local.benchmark_ansible_resync
  }

  connection {
    type        = "ssh"
    host        = oci_core_instance.failover[0].private_ip
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "15m"

    bastion_host        = local.controller_host
    bastion_user        = var.ssh_username
    bastion_private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait || true",
      "echo 'Failover node provisioning complete'",
    ]
  }

  provisioner "file" {
    source      = data.archive_file.playbooks.output_path
    destination = "/tmp/playbooks.zip"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      local.bootstrap_ansible_prereqs,
      "rm -rf /tmp/playbooks",
      "mkdir -p /tmp/playbooks",
      "unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks",
      "rm -f /tmp/playbooks.zip",
      "sudo mkdir -p /opt/aeron",
      "sudo rm -rf /opt/aeron/playbooks",
      "sudo mv /tmp/playbooks /opt/aeron/playbooks",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${local.aeron_echo_udp_interface_prefix_length_resolved} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=failover client_node_ip=${local.benchmark_private_ips[0]} receiver_node_ip=${local.benchmark_private_ips[1]} failover_node_ip=${oci_core_instance.failover[0].private_ip} benchmark_node_ips=${join(",", local.benchmark_private_ips)} ${local.ansible_benchmark_env_extra}'" : "echo 'Skipping Aeron installation'",
    ]
  }

  # Distribute same SSH key so nodes can SSH between each other passwordlessly.
  provisioner "file" {
    content     = tls_private_key.ssh.private_key_pem
    destination = "/tmp/deploy_key.pem"
  }

  provisioner "file" {
    content     = tls_private_key.ssh.public_key_openssh
    destination = "/tmp/deploy_key.pub"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "mkdir -p /home/${var.ssh_username}/.ssh",
      "mv /tmp/deploy_key.pem /home/${var.ssh_username}/.ssh/aeron-node-priv.key",
      "mv /tmp/deploy_key.pub /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "chmod 700 /home/${var.ssh_username}/.ssh",
      "chmod 600 /home/${var.ssh_username}/.ssh/aeron-node-priv.key",
      "chmod 644 /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub",
      "touch /home/${var.ssh_username}/.ssh/authorized_keys",
      "grep -q -F -f /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub /home/${var.ssh_username}/.ssh/authorized_keys || cat /home/${var.ssh_username}/.ssh/aeron-node-priv.key.pub >> /home/${var.ssh_username}/.ssh/authorized_keys",
      "chmod 600 /home/${var.ssh_username}/.ssh/authorized_keys",
      "sudo mkdir -p /opt/aeron/.ssh",
      "sudo cp /home/${var.ssh_username}/.ssh/aeron-node-priv.key /opt/aeron/.ssh/deploy_key",
      "sudo chmod 600 /opt/aeron/.ssh/deploy_key",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron/.ssh /home/${var.ssh_username}/.ssh",
    ]
  }
}

# =============================================================================
# Controller-managed benchmark isolation reboot
# =============================================================================
resource "null_resource" "benchmark_isolation_reboot" {
  count = var.install_aeron ? 1 : 0

  depends_on = [
    null_resource.controller_provisioner,
    null_resource.benchmark_provisioner,
    null_resource.failover_provisioner
  ]

  triggers = {
    controller_instance_id    = oci_core_instance.controller.id
    benchmark_instance_ids    = join(",", local.benchmark_instance_ids)
    failover_instance_id      = var.enable_failover_node ? oci_core_instance.failover[0].id : ""
    benchmark_ansible_resync  = local.benchmark_ansible_resync
    hyperthreading            = tostring(var.hyperthreading)
    isolation_reboot_exec_rev = "2026-05-20-controller-managed-isolation-reboot-v1"
  }

  connection {
    type        = "ssh"
    host        = local.controller_host
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "30m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "KEY=\"/opt/aeron/.ssh/deploy_key\"",
      "MARKER=\"/var/run/aeron-isolation-reboot-required\"",
      "NODE_IPS=\"${join(" ", local.benchmark_private_ips)}${var.enable_failover_node ? " ${oci_core_instance.failover[0].private_ip}" : ""}\"",
      "SSH_OPTS=\"-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10\"",
      "required=\"\"",
      "for ip in $NODE_IPS; do if ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"sudo test -f '$MARKER'\" >/dev/null 2>&1; then required=\"$required $ip\"; fi; done",
      "if [ -z \"$(echo \"$required\" | xargs)\" ]; then echo 'No benchmark isolation reboot markers found'; exit 0; fi",
      "echo \"Controller-managed isolation reboot required for:$required\"",
      "for ip in $required; do echo \"Requesting reboot on $ip\"; ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"sudo rm -f '$MARKER'; sudo systemctl reboot --no-block\" >/dev/null 2>&1 || true; done",
      "for ip in $required; do echo \"Waiting for SSH to drop on $ip\"; down=0; for attempt in $(seq 1 60); do if ! ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"true\" >/dev/null 2>&1; then down=1; break; fi; sleep 2; done; if [ \"$down\" -ne 1 ]; then echo \"WARNING: SSH did not drop on $ip before reconnect wait\"; fi; done",
      "for ip in $required; do echo \"Waiting for SSH/cloud-init after reboot on $ip\"; ready=0; for attempt in $(seq 1 180); do if ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"cloud-init status --wait >/dev/null 2>&1 || true\" >/dev/null 2>&1; then ready=1; break; fi; sleep 5; done; if [ \"$ready\" -ne 1 ]; then echo \"ERROR: SSH did not recover on $ip after isolation reboot\" >&2; exit 1; fi; done",
      "for ip in $required; do echo \"Validating isolation cmdline on $ip\"; cmdline=\"$(ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"cat /proc/cmdline\")\"; echo \"$cmdline\" | grep -q 'isolcpus=managed_irq,domain,'; echo \"$cmdline\" | grep -q 'nohz_full='; echo \"$cmdline\" | grep -q 'rcu_nocbs='; if [ \"${var.hyperthreading}\" = \"false\" ]; then echo \"$cmdline\" | grep -q 'nosmt'; smt=\"$(ssh $SSH_OPTS \"${var.ssh_username}@$ip\" \"cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo 0\")\"; test \"$(echo \"$smt\" | tr -d '[:space:]')\" = \"0\"; fi; done",
      "echo 'Controller-managed isolation reboot complete'",
    ]
  }
}

# =============================================================================
# Optional benchmark matrix run (controller) after all node configuration
# =============================================================================
resource "null_resource" "run_driver_matrix" {
  count = var.install_aeron && local.post_deploy_matrix_enabled ? 1 : 0

  depends_on = [
    null_resource.controller_provisioner,
    null_resource.benchmark_provisioner,
    null_resource.failover_provisioner,
    null_resource.benchmark_isolation_reboot
  ]

  triggers = {
    controller_instance_id        = oci_core_instance.controller.id
    benchmark_instance_ids        = join(",", local.benchmark_instance_ids)
    benchmark_ocpus               = tostring(var.benchmark_ocpus)
    failover_ocpus                = tostring(var.failover_ocpus)
    run_smoke_test                = tostring(var.run_smoke_test)
    run_full_benchmark            = tostring(var.run_full_benchmark)
    matrix_modes                  = var.run_benchmarks_matrix_modes
    matrix_exec_rev               = "matrix-patch-shell-v6-cluster-heartbeat"
    benchmark_echo_tune           = "${var.benchmark_echo_runs}-${var.benchmark_echo_iterations}-${var.benchmark_message_length}-${var.benchmark_message_rate}-${var.benchmark_echo_warmup_iterations}-${var.benchmark_echo_warmup_message_rate}"
    benchmark_ansible_resync      = local.benchmark_ansible_resync
    run_benchmarks_cluster_matrix = tostring(var.run_benchmarks_cluster_matrix)
    full_benchmark_matrix_tune    = "${var.full_benchmark_echo_runs}-${var.full_benchmark_echo_iterations}-${var.full_benchmark_echo_warmup_iterations}-${var.full_benchmark_message_length}-${var.full_benchmark_message_rate}-${var.full_benchmark_matrix_mode_timeout_sec}"
  }

  connection {
    type        = "ssh"
    host        = local.controller_host
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    # Echo + cluster matrix can run many hours; allow slow OCI/Ansible reconnect during handshake.
    timeout = "480m"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "#!/bin/bash",
        "set -euo pipefail",
        "RESULTS_ROOT=\"/home/${var.ssh_username}/benchmark-results\"",
        "RUN_ID=\"$(date -u +%Y%m%dT%H%M%SZ)-$${RANDOM}\"",
        "RESULTS_DIR=\"$RESULTS_ROOT/runs/$RUN_ID\"",
        "STATUS_FILE=\"$RESULTS_DIR/STATUS.txt\"",
        "mkdir -p \"$RESULTS_DIR\" \"$RESULTS_ROOT\"",
        "printf '%s\n' \"$RESULTS_DIR\" > \"$RESULTS_ROOT/latest-run.txt\"",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: started (run_smoke_test=${var.run_smoke_test} run_full_benchmark=${var.run_full_benchmark})\" | tee -a \"$STATUS_FILE\"",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: results_dir=$RESULTS_DIR\" | tee -a \"$STATUS_FILE\"",
        "# Periodic output so long runs do not hit silent SSH idle disconnect (Terraform \"no exit status\").",
        "( while true; do echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: ssh-keepalive\" | tee -a \"$STATUS_FILE\"; sleep 30; done ) &",
        "_MATRIX_HB_PID=$!",
        "trap 'kill $${_MATRIX_HB_PID} 2>/dev/null || true; wait $${_MATRIX_HB_PID} 2>/dev/null || true' EXIT",
        "cd /opt/aeron/benchmarks-dist/scripts",
        "# Remove previous matrix artifacts from the working directory so this apply cannot summarize stale archives.",
        "rm -f ./aeron-echo-*.tar.gz ./aeron-cluster-*.tar.gz ./driver-matrix-*.csv ./*-report.hgrm /tmp/echo-matrix-*.log /tmp/cluster-matrix-*.log 2>/dev/null || true",
        "mkdir -p ./config",
        "cp -f /opt/aeron/scripts/config/benchmark-config.env ./config/benchmark-config.env",
        "cp -f /opt/aeron/scripts/config/clear-benchmark-affinity-env.sh ./config/clear-benchmark-affinity-env.sh 2>/dev/null || cp -f ./clear-benchmark-affinity-env.sh ./config/clear-benchmark-affinity-env.sh 2>/dev/null || true",
        "# Sanitize benchmark-config.env inline (avoid CRLF in zipped sanitize-benchmark-config-env.sh from Windows breaking dash).",
        "sed -i -E 's#/([0-9]+)\\}+#/\\1#g' ./config/benchmark-config.env || true",
        "sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=\")([0-9]+)\\}\"/\\1\\2\"/g' ./config/benchmark-config.env || true",
        "sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=)([0-9]+)\\}/\\1\\2/g' ./config/benchmark-config.env || true",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: config-ready\" | tee -a \"$STATUS_FILE\"",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: sudo rm /dev/shm/aeron + ~/aeron-benchmark-shm on benchmark nodes\" | tee -a \"$STATUS_FILE\"",
        "${local.benchmark_dev_shm_cleanup}",
        "chmod +x ./wrapper-echo-unified.sh ./wrapper-cluster-unified.sh ./aggregate-compare-results.sh ./run-driver-matrix.sh ./run-c-vma-gcp-analog.sh ./sanitize-benchmark-config-env.sh ./clear-benchmark-affinity-env.sh 2>/dev/null || true",
        "# Strip CRLF if playbooks were zipped on Windows (bash \"source\" fails with $'\\r': command not found).",
        "sed -i 's/\\r$//' ./clear-benchmark-affinity-env.sh ./config/clear-benchmark-affinity-env.sh ./run-driver-matrix.sh 2>/dev/null || true",
        "export CONFIG_FILE=./config/benchmark-config.env",
        "export MATRIX_MODES=\"${var.run_benchmarks_matrix_modes}\"",
        "export STATUS_FILE=\"$STATUS_FILE\"",
        "export MATRIX_ALLOW_STALE_ARCHIVE=0",
        "# Fail apply if matrix exits non-zero (pipefail): timeouts, Java exceptions, or any failed mode when MATRIX_STRICT=1",
        "export MATRIX_STRICT=1",
      ],
      var.run_smoke_test ? local.matrix_remote_exec_echo_smoke : ["echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: skipping smoke echo (run_smoke_test=false)\" | tee -a \"$STATUS_FILE\""],
      var.run_full_benchmark ? local.matrix_remote_exec_echo_full : ["echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: skipping full benchmark echo (run_full_benchmark=false)\" | tee -a \"$STATUS_FILE\""],
      var.enable_failover_node && var.run_benchmarks_cluster_matrix ? concat(
        var.run_smoke_test ? local.matrix_remote_exec_cluster_smoke : [],
        var.run_full_benchmark ? local.matrix_remote_exec_cluster_full : [],
        ) : [
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: skipping cluster matrix (failover=${var.enable_failover_node}, run_benchmarks_cluster_matrix=${var.run_benchmarks_cluster_matrix})\" | tee -a \"$STATUS_FILE\"",
      ],
      [
        "cp -f ./*-report.hgrm \"$RESULTS_DIR/\" 2>/dev/null || true",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: writing terraform-matrix-summary.json\" | tee -a \"$STATUS_FILE\"",
        "python3 /opt/aeron/playbooks/scripts/terraform-matrix-summary.py \"$RESULTS_DIR\" ${local.matrix_summary_tf_profile} ${local.matrix_summary_tf_runs} ${local.matrix_summary_tf_iters} ${local.matrix_summary_tf_warm} 2>/dev/null || echo \"terraform-matrix-summary.py skipped (no python3?)\" | tee -a \"$STATUS_FILE\"",
        "cp -f \"$RESULTS_DIR\"/driver-matrix-*-summary*.csv \"$RESULTS_ROOT\"/ 2>/dev/null || true",
        "cp -f \"$RESULTS_DIR\"/run-driver-matrix-*.log \"$RESULTS_ROOT\"/ 2>/dev/null || true",
        "cp -f \"$RESULTS_DIR\"/terraform-matrix-summary.json \"$RESULTS_ROOT\"/ 2>/dev/null || true",
        "cp -f \"$STATUS_FILE\" \"$RESULTS_ROOT/STATUS.txt\" 2>/dev/null || true",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: artifacts-copied\" | tee -a \"$STATUS_FILE\"",
        "ls -la \"$RESULTS_DIR\"",
        "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: completed\" | tee -a \"$STATUS_FILE\"",
        "echo \"Driver matrix complete (smoke and/or full). Results in $RESULTS_DIR\"",
      ],
    )
  }
}
