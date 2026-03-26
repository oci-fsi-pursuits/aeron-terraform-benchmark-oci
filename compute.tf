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
    network_type = var.use_sriov_networking ? "VFIO" : "PARAVIRTUALIZED"
  }

  create_vnic_details {
    subnet_id        = local.public_subnet_id
    assign_public_ip = !var.private_deployment
    hostname_label   = "controller"
  }

  metadata = {
    ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
    user_data           = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
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
  display_name        = "${local.cluster_name}-benchmark-${count.index + 1}"

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
    network_type = var.use_sriov_networking ? "VFIO" : "PARAVIRTUALIZED"
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    hostname_label   = "benchmark-${count.index + 1}"
    nsg_ids          = [oci_core_network_security_group.aeron_benchmark.id]
  }

  metadata = {
    ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
    user_data           = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
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
    network_type = var.use_sriov_networking ? "VFIO" : "PARAVIRTUALIZED"
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    hostname_label   = "failover"
    nsg_ids          = [oci_core_network_security_group.aeron_benchmark.id]
  }

  metadata = {
    ssh_authorized_keys = "${var.ssh_public_key}\n${tls_private_key.ssh.public_key_openssh}"
    user_data           = base64encode(templatefile("${path.module}/scripts/cloud-init.yaml", {
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
    instance_id      = oci_core_instance.controller.id
    playbooks_bundle = data.archive_file.playbooks.id
    provisioner_rev  = "2026-03-25-controller-ssh-readme"
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
      "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=true java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} benchmarks_repo_url=${var.benchmarks_repo_url} benchmarks_git_branch=${var.benchmarks_git_branch} run_benchmarks_matrix_modes=${var.run_benchmarks_matrix_modes} node_role=controller client_node_ip=${oci_core_instance.benchmark[0].private_ip} receiver_node_ip=${oci_core_instance.benchmark[1].private_ip} failover_node_ip=${var.enable_failover_node ? oci_core_instance.failover[0].private_ip : ""} benchmark_node_ips=${join(",", oci_core_instance.benchmark[*].private_ip)}' -v",
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
    instance_id      = oci_core_instance.benchmark[count.index].id
    playbooks_bundle = data.archive_file.playbooks.id
    provisioner_rev  = "2026-03-25-node-ssh-keysync-dedicated-key"
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
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} node_role=${count.index == 0 ? "client" : "receiver"}'" : "echo 'Skipping Aeron installation'",
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
    instance_id      = oci_core_instance.failover[0].id
    playbooks_bundle = data.archive_file.playbooks.id
    provisioner_rev  = "2026-03-25-node-ssh-keysync-dedicated-key"
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
      var.install_aeron ? "cd /opt/aeron/playbooks && ansible-playbook -i 'localhost,' -c local site.yml -e 'hyperthreading=${var.hyperthreading} java_version=${var.java_version} ssh_username=${var.ssh_username} aeron_git_repo=${var.aeron_git_repo} aeron_git_branch=${var.aeron_git_branch} node_role=failover'" : "echo 'Skipping Aeron installation'",
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
    matrix_exec_rev        = "dev-shm-precleanup-v2"
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
      "RESULTS_DIR=\"/home/${var.ssh_username}/benchmark-results\"",
      "STATUS_FILE=\"$RESULTS_DIR/STATUS.txt\"",
      "mkdir -p \"$RESULTS_DIR\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: started\" | tee -a \"$STATUS_FILE\"",
      "cd /opt/aeron/benchmarks-dist/scripts",
      "mkdir -p ./config",
      "cp -f /opt/aeron/scripts/config/benchmark-config.env ./config/benchmark-config.env",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: config-ready\" | tee -a \"$STATUS_FILE\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: sudo rm /dev/shm/aeron on benchmark nodes (root-owned dir breaks MediaDriver)\" | tee -a \"$STATUS_FILE\"",
      "${local.benchmark_dev_shm_cleanup}",
      "chmod +x ./wrapper-echo-unified.sh ./wrapper-cluster-unified.sh ./aggregate-compare-results.sh ./run-driver-matrix.sh || true",
      "export CONFIG_FILE=./config/benchmark-config.env",
      "export MATRIX_MODES=\"${var.run_benchmarks_matrix_modes}\"",
      "export STATUS_FILE=\"$STATUS_FILE\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: running ECHO modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"",
      "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-echo-summary.csv\"",
      "./run-driver-matrix.sh echo | tee \"$RESULTS_DIR/run-driver-matrix-echo.log\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: echo-finished\" | tee -a \"$STATUS_FILE\"",
      "cp -f ./aeron-echo-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
      var.enable_failover_node ? "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: failover detected, running CLUSTER modes=$MATRIX_MODES\" | tee -a \"$STATUS_FILE\"" : "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: failover not enabled, skipping cluster matrix\" | tee -a \"$STATUS_FILE\"",
      var.enable_failover_node ? "export SUMMARY_FILE=\"$RESULTS_DIR/driver-matrix-cluster-summary.csv\"; ./run-driver-matrix.sh cluster | tee \"$RESULTS_DIR/run-driver-matrix-cluster.log\"" : "true",
      var.enable_failover_node ? "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: cluster-finished\" | tee -a \"$STATUS_FILE\"" : "true",
      "cp -f ./aeron-cluster-*.tar.gz \"$RESULTS_DIR/\" 2>/dev/null || true",
      "cp -f ./*-report.hgrm \"$RESULTS_DIR/\" 2>/dev/null || true",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: artifacts-copied\" | tee -a \"$STATUS_FILE\"",
      "ls -la \"$RESULTS_DIR\"",
      "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) run-driver-matrix: completed\" | tee -a \"$STATUS_FILE\"",
      "echo \"Benchmark matrix complete. Results available in $RESULTS_DIR\""
    ]
  }
}
