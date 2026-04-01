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
  availability_domain = var.controller_ad
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
      ssh_username   = var.ssh_username
      hyperthreading = true
      install_aeron  = var.install_aeron
      java_version   = var.java_version
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
    ]
  }
}

# =============================================================================
# Benchmark Nodes (Private Subnet - Client/Receiver)
# =============================================================================
resource "oci_core_instance" "benchmark" {
  count               = var.benchmark_node_count
  availability_domain = var.benchmark_ad
  compartment_id      = var.compartment_ocid
  shape               = var.benchmark_shape
  display_name        = "${local.cluster_name}-${count.index == 0 ? "client" : count.index == 1 ? "receiver" : format("node-%d", count.index + 1)}"

  dynamic "shape_config" {
    for_each = local.is_benchmark_flex_shape ? [1] : []
    content {
      ocpus         = var.benchmark_ocpus
      memory_in_gbs = var.benchmark_memory_gb
    }
  }

  dynamic "platform_config" {
    for_each = local.benchmark_platform_config_type != null || !var.hyperthreading ? [1] : []
    content {
      type                                           = local.benchmark_platform_config_type != null ? local.benchmark_platform_config_type : "AMD_VM"
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
    hostname_label   = "benchmark-${count.index + 1}"
    nsg_ids          = [oci_core_network_security_group.aeron_benchmark.id]
  }

  metadata = {
    ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
    user_data = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
      ssh_username   = var.ssh_username
      hyperthreading = var.hyperthreading
      install_aeron  = var.install_aeron
      java_version   = var.java_version
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
    role         = count.index == 0 ? "client" : "receiver"
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
resource "oci_core_instance" "failover" {
  count               = var.enable_failover_node ? 1 : 0
  availability_domain = var.failover_ad
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
    for_each = local.failover_platform_config_type != null || !var.hyperthreading ? [1] : []
    content {
      type                                           = local.failover_platform_config_type != null ? local.failover_platform_config_type : "AMD_VM"
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
      ssh_username   = var.ssh_username
      hyperthreading = var.hyperthreading
      install_aeron  = var.install_aeron
      java_version   = var.java_version
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
    role         = "failover"
    aeron        = "true"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}

# =============================================================================
# Provisioner for Controller Node
# =============================================================================
resource "null_resource" "controller_provisioner" {
  depends_on = [oci_core_instance.controller, oci_core_instance.benchmark]

  triggers = {
    instance_id              = oci_core_instance.controller.id
    playbooks_bundle         = data.archive_file.playbooks.id
    provisioner_rev          = "2026-03-27-benchmark-env-from-tf"
    benchmark_ansible_resync = local.benchmark_ansible_resync
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
      "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${var.aeron_echo_udp_interface_prefix_length} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=controller client_node_ip=${oci_core_instance.benchmark[0].private_ip} receiver_node_ip=${oci_core_instance.benchmark[1].private_ip} failover_node_ip=${var.enable_failover_node ? oci_core_instance.failover[0].private_ip : ""} benchmark_node_ips=${join(",", oci_core_instance.benchmark[*].private_ip)} ${local.ansible_benchmark_env_extra}' -v",
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
  count      = var.benchmark_node_count
  depends_on = [oci_core_instance.benchmark, null_resource.controller_provisioner]

  triggers = {
    instance_id              = oci_core_instance.benchmark[count.index].id
    playbooks_bundle         = data.archive_file.playbooks.id
    provisioner_rev          = "2026-03-27-benchmark-env-from-tf"
    benchmark_ansible_resync = local.benchmark_ansible_resync
  }

  connection {
    type        = "ssh"
    host        = oci_core_instance.benchmark[count.index].private_ip
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
      "rm -rf /tmp/playbooks",
      "mkdir -p /tmp/playbooks",
      "unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks",
      "rm -f /tmp/playbooks.zip",
      "sudo mkdir -p /opt/aeron",
      "sudo rm -rf /opt/aeron/playbooks",
      "sudo mv /tmp/playbooks /opt/aeron/playbooks",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${var.aeron_echo_udp_interface_prefix_length} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=${count.index == 0 ? "client" : "receiver"} client_node_ip=${oci_core_instance.benchmark[0].private_ip} receiver_node_ip=${oci_core_instance.benchmark[1].private_ip} failover_node_ip=${var.enable_failover_node ? oci_core_instance.failover[0].private_ip : ""} benchmark_node_ips=${join(",", oci_core_instance.benchmark[*].private_ip)} ${local.ansible_benchmark_env_extra}'" : "echo 'Skipping Aeron installation'",
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
    playbooks_bundle         = data.archive_file.playbooks.id
    provisioner_rev          = "2026-03-27-benchmark-env-from-tf"
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
      "rm -rf /tmp/playbooks",
      "mkdir -p /tmp/playbooks",
      "unzip -q -o /tmp/playbooks.zip -d /tmp/playbooks",
      "rm -f /tmp/playbooks.zip",
      "sudo mkdir -p /opt/aeron",
      "sudo rm -rf /opt/aeron/playbooks",
      "sudo mv /tmp/playbooks /opt/aeron/playbooks",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/aeron",
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} aeron_echo_udp_interface_prefix_length=${var.aeron_echo_udp_interface_prefix_length} aeron_echo_udp_named_interface=${var.aeron_echo_udp_named_interface} aeron_benchmark_configure_host_firewall=${var.aeron_benchmark_configure_host_firewall} aeron_benchmark_host_firewall_persistent=${var.aeron_benchmark_host_firewall_persistent} aeron_benchmark_host_udp_source_cidr=${local.aeron_benchmark_udp_ingress_cidr} node_role=failover client_node_ip=${oci_core_instance.benchmark[0].private_ip} receiver_node_ip=${oci_core_instance.benchmark[1].private_ip} failover_node_ip=${oci_core_instance.failover[0].private_ip} benchmark_node_ips=${join(",", oci_core_instance.benchmark[*].private_ip)} ${local.ansible_benchmark_env_extra}'" : "echo 'Skipping Aeron installation'",
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
# Optional benchmark matrix run (controller) after all node configuration
# =============================================================================
resource "null_resource" "run_driver_matrix" {
  count = var.install_aeron && var.run_benchmarks ? 1 : 0

  depends_on = [
    null_resource.controller_provisioner,
    null_resource.benchmark_provisioner,
    null_resource.failover_provisioner
  ]

  triggers = {
    controller_instance_id = oci_core_instance.controller.id
    benchmark_instance_ids = join(",", oci_core_instance.benchmark[*].id)
    run_benchmarks         = tostring(var.run_benchmarks)
    matrix_modes           = var.run_benchmarks_matrix_modes
    # Bump when changing remote-exec steps (e.g. benchmark preflight) so apply re-runs the matrix.
    matrix_exec_rev               = "aeron-dir-home-aeron-benchmark-shm-v1"
    benchmark_echo_tune           = "${var.benchmark_echo_runs}-${var.benchmark_echo_iterations}-${var.benchmark_message_length}-${var.benchmark_message_rate}-${var.benchmark_echo_warmup_iterations}-${var.benchmark_echo_warmup_message_rate}"
    benchmark_ansible_resync      = local.benchmark_ansible_resync
    run_benchmarks_cluster_matrix = tostring(var.run_benchmarks_cluster_matrix)
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
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "RESULTS_DIR=\"/home/${var.ssh_username}/benchmark-results\"",
      "STATUS_FILE=\"$RESULTS_DIR/STATUS.txt\"",
      "mkdir -p \"$RESULTS_DIR\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: started\" | tee -a \"$STATUS_FILE\"",
      "# Periodic output so long runs do not hit silent SSH idle disconnect (Terraform \"no exit status\").",
      "( while true; do echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: ssh-keepalive\" | tee -a \"$STATUS_FILE\"; sleep 90; done ) &",
      "_MATRIX_HB_PID=$!",
      "trap 'kill $${_MATRIX_HB_PID} 2>/dev/null || true; wait $${_MATRIX_HB_PID} 2>/dev/null || true' EXIT",
      "cd /opt/aeron/benchmarks-dist/scripts",
      "mkdir -p ./config",
      "cp -f /opt/aeron/scripts/config/benchmark-config.env ./config/benchmark-config.env",
      "# Sanitize benchmark-config.env inline (avoid CRLF in zipped sanitize-benchmark-config-env.sh from Windows breaking dash).",
      "sed -i -E 's#/([0-9]+)\\}+#/\\1#g' ./config/benchmark-config.env || true",
      "sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=\")([0-9]+)\\}\"/\\1\\2\"/g' ./config/benchmark-config.env || true",
      "sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=)([0-9]+)\\}/\\1\\2/g' ./config/benchmark-config.env || true",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: config-ready\" | tee -a \"$STATUS_FILE\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: sudo rm /dev/shm/aeron + ~/aeron-benchmark-shm on benchmark nodes\" | tee -a \"$STATUS_FILE\"",
      "${local.benchmark_dev_shm_cleanup}",
      "chmod +x ./wrapper-echo-unified.sh ./wrapper-cluster-unified.sh ./aggregate-compare-results.sh ./run-driver-matrix.sh ./sanitize-benchmark-config-env.sh 2>/dev/null || true",
      "export CONFIG_FILE=./config/benchmark-config.env",
      "export MATRIX_MODES=\"${var.run_benchmarks_matrix_modes}\"",
      "export STATUS_FILE=\"$STATUS_FILE\"",
      "# Fail apply if matrix exits non-zero (pipefail): timeouts, Java exceptions, or any failed mode when MATRIX_STRICT=1",
      "export MATRIX_STRICT=1",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: running ECHO modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
      "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-echo-summary.csv\"",
      "# PIPESTATUS: capture matrix exit after tee (use $$ in .tf so bash vars are not parsed as HCL)",
      "./run-driver-matrix.sh echo 2>&1 | tee \"$RESULTS_DIR/run-driver-matrix-echo.log\"; matrix_ec=$${PIPESTATUS[0]}",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: echo-finished exit=$${matrix_ec}\" | tee -a \"$STATUS_FILE\"",
      "if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi",
      "cp -f ./aeron-echo-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
      var.enable_failover_node && var.run_benchmarks_cluster_matrix ? "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: failover + cluster matrix enabled, running CLUSTER modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"" : "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: skipping cluster matrix (failover=${var.enable_failover_node}, run_benchmarks_cluster_matrix=${var.run_benchmarks_cluster_matrix})\" | tee -a \"$STATUS_FILE\"",
      var.enable_failover_node && var.run_benchmarks_cluster_matrix ? "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-cluster-summary.csv\"; export MATRIX_STRICT=1; export MATRIX_MODE_TIMEOUT_SEC=\"$${MATRIX_MODE_TIMEOUT_SEC:-1800}\"; ./run-driver-matrix.sh cluster 2>&1 | tee \"$RESULTS_DIR/run-driver-matrix-cluster.log\"; matrix_ec=$${PIPESTATUS[0]}; if [[ \"$${matrix_ec}\" -ne 0 ]]; then exit \"$${matrix_ec}\"; fi" : "true",
      var.enable_failover_node && var.run_benchmarks_cluster_matrix ? "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: cluster-finished\" | tee -a \"$STATUS_FILE\"" : "true",
      "cp -f ./aeron-cluster-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
      "cp -f ./*-report.hgrm \"$RESULTS_DIR/\" 2>/dev/null || true",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: writing terraform-matrix-summary.json\" | tee -a \"$STATUS_FILE\"",
      "python3 /opt/aeron/playbooks/scripts/terraform-matrix-summary.py \"$RESULTS_DIR\" ${local.benchmark_driver_matrix_profile} ${var.benchmark_echo_runs} ${var.benchmark_echo_iterations} ${var.benchmark_echo_warmup_iterations} 2>/dev/null || echo \"terraform-matrix-summary.py skipped (no python3?)\" | tee -a \"$STATUS_FILE\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: artifacts-copied\" | tee -a \"$STATUS_FILE\"",
      "ls -la \"$RESULTS_DIR\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: completed\" | tee -a \"$STATUS_FILE\"",
      "echo \"Benchmark matrix complete. Results available in $RESULTS_DIR\""
    ]
  }
}
