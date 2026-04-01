output "cluster_name" {
  description = "Cluster name"
  value       = local.cluster_name
}

# =============================================================================
# Controller Node Outputs
# =============================================================================
output "controller_instance_id" {
  description = "OCID of the controller instance"
  value       = oci_core_instance.controller.id
}

output "controller_public_ip" {
  description = "Public IP of the controller instance (in public subnet)"
  value       = var.private_deployment ? null : oci_core_instance.controller.public_ip
}

output "controller_private_ip" {
  description = "Private IP of the controller instance"
  value       = oci_core_instance.controller.private_ip
}

output "controller_ssh_command" {
  description = "SSH command to connect to controller node"
  value       = var.private_deployment ? "ssh -i <your-key> ${var.ssh_username}@${oci_core_instance.controller.private_ip}" : "ssh -i <your-key> ${var.ssh_username}@${oci_core_instance.controller.public_ip}"
}

# =============================================================================
# Benchmark Nodes Outputs
# =============================================================================
output "benchmark_instance_ids" {
  description = "OCIDs of the benchmark instances"
  value       = oci_core_instance.benchmark[*].id
}

output "benchmark_private_ips" {
  description = "Private IPs of the benchmark instances (in private subnet)"
  value       = oci_core_instance.benchmark[*].private_ip
}

output "benchmark_ssh_commands" {
  description = "SSH commands to connect to benchmark nodes (via controller bastion)"
  value = [
    for idx, ip in oci_core_instance.benchmark[*].private_ip :
    "ssh -i <your-key> -J ${var.ssh_username}@${var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip} ${var.ssh_username}@${ip}"
  ]
}

output "client_node_ip" {
  description = "Private IP of the client node (benchmark-1)"
  value       = oci_core_instance.benchmark[0].private_ip
}

output "receiver_node_ip" {
  description = "Private IP of the receiver node (benchmark-2)"
  value       = var.benchmark_node_count >= 2 ? oci_core_instance.benchmark[1].private_ip : null
}

# =============================================================================
# Failover Node Outputs
# =============================================================================
output "failover_instance_id" {
  description = "OCID of the failover instance"
  value       = var.enable_failover_node ? oci_core_instance.failover[0].id : null
}

output "failover_private_ip" {
  description = "Private IP of the failover instance (in private subnet)"
  value       = var.enable_failover_node ? oci_core_instance.failover[0].private_ip : null
}

output "failover_ssh_command" {
  description = "SSH command to connect to failover node (via controller bastion)"
  value       = var.enable_failover_node ? "ssh -i <your-key> -J ${var.ssh_username}@${var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip} ${var.ssh_username}@${oci_core_instance.failover[0].private_ip}" : null
}

# =============================================================================
# Network Outputs
# =============================================================================
output "vcn_id" {
  description = "VCN OCID"
  value       = local.vcn_id
}

output "public_subnet_id" {
  description = "Public Subnet OCID (controller)"
  value       = local.public_subnet_id
}

output "private_subnet_id" {
  description = "Private Subnet OCID (benchmark/failover nodes)"
  value       = local.private_subnet_id
}

# =============================================================================
# SSH Key Outputs
# =============================================================================
output "generated_ssh_private_key" {
  description = "Generated SSH private key (for provisioning)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

# =============================================================================
# Aeron Information
# =============================================================================
output "aeron_info" {
  description = "Aeron deployment information"
  value = {
    git_repo             = var.aeron_git_repo
    git_branch           = var.aeron_git_branch != "" ? var.aeron_git_branch : "master (latest)"
    java_version         = var.java_version
    hyperthreading       = var.hyperthreading
    controller_ocpus     = var.controller_ocpus
    benchmark_node_count = var.benchmark_node_count
    benchmark_ocpus      = var.benchmark_ocpus
    failover_enabled     = var.enable_failover_node
    failover_ocpus       = var.enable_failover_node ? var.failover_ocpus : null
  }
}

output "benchmark_command" {
  description = "Command to run Aeron benchmarks from controller"
  value       = "ssh ${var.ssh_username}@${var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip} 'cd /opt/aeron && ./run-benchmark.sh'"
}

# =============================================================================
# Node Summary
# =============================================================================
output "node_summary" {
  description = "Summary of all deployed nodes"
  value = {
    controller = {
      hostname   = "controller"
      public_ip  = var.private_deployment ? null : oci_core_instance.controller.public_ip
      private_ip = oci_core_instance.controller.private_ip
      ocpus      = var.controller_ocpus
      role       = "orchestrator"
    }
    benchmark_nodes = [
      for idx, instance in oci_core_instance.benchmark : {
        hostname   = "benchmark-${idx + 1}"
        private_ip = instance.private_ip
        ocpus      = var.benchmark_ocpus
        role       = idx == 0 ? "client" : "receiver"
      }
    ]
    failover = var.enable_failover_node ? {
      hostname   = "failover"
      private_ip = oci_core_instance.failover[0].private_ip
      ocpus      = var.failover_ocpus
      role       = "failover"
    } : null
  }
}

# =============================================================================
# Driver matrix (smoke vs extended + optional pulled latencies)
# =============================================================================
output "benchmark_driver_matrix" {
  description = "How the post-apply driver matrix is configured and how to interpret it vs full baselines."
  value = {
    profile_label = local.benchmark_driver_matrix_profile
    explanation   = local.benchmark_driver_matrix_explanation
    echo_configuration = {
      benchmark_echo_runs                = var.benchmark_echo_runs
      benchmark_echo_iterations          = var.benchmark_echo_iterations
      benchmark_echo_warmup_iterations   = var.benchmark_echo_warmup_iterations
      benchmark_message_length           = var.benchmark_message_length
      benchmark_message_rate             = var.benchmark_message_rate
      run_benchmarks_matrix_modes        = var.run_benchmarks_matrix_modes
      run_benchmarks_cluster_matrix      = var.run_benchmarks_cluster_matrix && var.enable_failover_node
    }
    results_on_controller = "/home/${var.ssh_username}/benchmark-results"
    pull_enabled          = var.pull_matrix_summary_for_terraform_output
  }
}

output "benchmark_driver_matrix_summary" {
  description = "Full JSON from the last matrix pull: echo_mode_status / cluster_mode_status (per-driver ok|failed), echo_modes / cluster_modes (latency medians per scenario), matrix_profile, and benchmark_echo_* counts. When pull_matrix_summary_for_terraform_output=true and SSH+python pull succeeded; otherwise null or stub with _pull_failed. Same apply ordering as benchmark_driver_matrix_smoke."
  depends_on = [
    null_resource.run_driver_matrix,
    null_resource.benchmark_matrix_summary_pull,
  ]
  value = local.terraform_matrix_summary_json
}

output "benchmark_driver_matrix_smoke" {
  description = "Convenience view of smoke/extended matrix results for terraform output: per-mode matrix status (java/c/java_vma/c_vma) and aggregated latency rows. Null keys when .terraform-matrix-summary.json is missing or pull failed (_pull_failed in full summary)."
  depends_on = [
    null_resource.run_driver_matrix,
    null_resource.benchmark_matrix_summary_pull,
  ]
  value = local.terraform_matrix_summary_json == null ? null : {
    pull_failed = try(local.terraform_matrix_summary_json["_pull_failed"], false)
    errors      = try(local.terraform_matrix_summary_json["errors"], null)
    matrix_profile = try(local.terraform_matrix_summary_json["matrix_profile"], null)
    echo_mode_status    = try(local.terraform_matrix_summary_json["echo_mode_status"], [])
    echo_latencies      = try(local.terraform_matrix_summary_json["echo_modes"], [])
    cluster_mode_status = try(local.terraform_matrix_summary_json["cluster_mode_status"], [])
    cluster_latencies   = try(local.terraform_matrix_summary_json["cluster_modes"], [])
  }
}
