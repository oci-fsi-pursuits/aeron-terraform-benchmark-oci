output "cluster_name" {
  description = "Cluster name"
  value       = local.cluster_name
}

output "vnic_hostname_prefix" {
  description = "DNS prefix used for OCI VNIC hostname labels (controller/client/receiver/failover suffixes). Unique per stack when use_custom_name appends random_pet, or set instance_hostname_prefix explicitly."
  value       = local.vnic_hostname_prefix_final
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
  value       = local.benchmark_instance_ids
}

output "benchmark_private_ips" {
  description = "Private IPs of the benchmark instances (in private subnet)"
  value       = local.benchmark_private_ips
}

output "benchmark_ssh_commands" {
  description = "SSH commands to connect to benchmark nodes (via controller bastion)"
  value = [
    for idx, ip in local.benchmark_private_ips :
    "ssh -i <your-key> -J ${var.ssh_username}@${var.private_deployment ? oci_core_instance.controller.private_ip : oci_core_instance.controller.public_ip} ${var.ssh_username}@${ip}"
  ]
}

output "client_node_ip" {
  description = "Private IP of the client node (first benchmark instance; display name *-client)"
  value       = local.benchmark_private_ips[0]
}

output "receiver_node_ip" {
  description = "Private IP of the receiver node (second benchmark instance; display name *-receiver)"
  value       = local.benchmark_node_count_effective >= 2 ? local.benchmark_private_ips[1] : null
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

output "benchmark_compute_cluster_id" {
  description = "OCI compute cluster OCID used by benchmark nodes when RDMA compute cluster mode is enabled"
  value       = local.benchmark_compute_cluster_id
}

output "benchmark_cluster_network_id" {
  description = "OCI cluster network OCID used by benchmark nodes when enable_benchmark_cluster_network is true"
  value       = local.enable_benchmark_cluster_network ? oci_core_cluster_network.benchmark[0].id : null
}

output "benchmark_instance_pool_id" {
  description = "OCI instance pool OCID used by benchmark nodes when either pooled benchmark mode is enabled"
  value       = local.enable_benchmark_pooled_instances ? local.benchmark_instance_pool_id : null
}

output "benchmark_cluster_placement_group_id" {
  description = "OCI cluster placement group OCID used by primary benchmark nodes"
  value       = local.benchmark_cluster_placement_group_id
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
    benchmark_node_count = local.benchmark_node_count_effective
    raft_consensus       = var.enable_cluster_raft_consensus
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
      hostname   = substr("${local.vnic_hostname_prefix_final}-controller", 0, 63)
      public_ip  = var.private_deployment ? null : oci_core_instance.controller.public_ip
      private_ip = oci_core_instance.controller.private_ip
      ocpus      = var.controller_ocpus
      role       = "orchestrator"
    }
    benchmark_nodes = [
      for idx, ip in local.benchmark_private_ips : {
        hostname = substr(
          "${local.vnic_hostname_prefix_final}-${
            idx == 0 ? "client" : idx == 1 ? "receiver" : format("node%d", idx + 1)
          }",
          0,
          63
        )
        private_ip = ip
        ocpus      = var.benchmark_ocpus
        role       = idx == 0 ? "client" : idx == 1 ? "receiver" : "node-${idx + 1}"
      }
    ]
    failover = var.enable_failover_node ? {
      hostname   = substr("${local.vnic_hostname_prefix_final}-failover", 0, 63)
      private_ip = oci_core_instance.failover[0].private_ip
      ocpus      = var.failover_ocpus
      role       = "failover"
    } : null
  }
}

# =============================================================================
# Driver matrix (smoke vs extended; summaries live on the controller)
# =============================================================================
output "benchmark_driver_matrix" {
  description = "How the post-apply driver matrix is configured (run_smoke_test vs run_full_benchmark) and how to interpret results vs manual baselines. JSON/CSV artifacts are under results_on_controller (not pulled into terraform output)."
  value = {
    profile_label = local.benchmark_driver_matrix_profile
    explanation   = local.benchmark_driver_matrix_explanation
    echo_configuration = {
      benchmark_echo_runs              = var.benchmark_echo_runs
      benchmark_echo_iterations        = var.benchmark_echo_iterations
      benchmark_echo_warmup_iterations = var.benchmark_echo_warmup_iterations
      benchmark_message_length         = var.benchmark_message_length
      benchmark_message_rate           = var.benchmark_message_rate
      run_smoke_test                   = var.run_smoke_test
      run_full_benchmark               = var.run_full_benchmark
      run_benchmarks_matrix_modes      = var.run_benchmarks_matrix_modes
      run_benchmarks_cluster_matrix    = var.run_benchmarks_cluster_matrix && var.enable_failover_node
      benchmark_vma_apply_setcap       = var.benchmark_vma_apply_setcap
      benchmark_vma_lib_path           = var.benchmark_vma_lib_path
      benchmark_install_vma_runtime    = var.benchmark_install_vma_runtime
      benchmark_vma_build_from_source  = var.benchmark_vma_build_from_source
      benchmark_vma_git_ref            = var.benchmark_vma_git_ref
    }
    results_on_controller = "/home/${var.ssh_username}/benchmark-results"
  }
}
