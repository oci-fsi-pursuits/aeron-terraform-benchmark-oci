# Cross-variable rules (variable validation may only reference the same variable).
check "failover_ad_distinct_from_benchmark" {
  assert {
    condition     = !var.enable_failover_node || local.failover_ad_effective != local.benchmark_ad_effective
    error_message = "When enable_failover_node is true, the effective failover AD must not match the effective benchmark AD."
  }
}

check "rdma_compute_cluster_shape_hint" {
  assert {
    condition     = !var.enable_rdma_compute_cluster || length(regexall("^BM\\.", var.benchmark_shape)) > 0
    error_message = "enable_rdma_compute_cluster=true is intended for RDMA-capable bare-metal shapes (for example BM.Optimized3.36)."
  }
}

check "benchmark_pooled_launch_mode" {
  assert {
    condition     = !(var.enable_benchmark_cluster_network && var.enable_benchmark_instance_pool)
    error_message = "Choose only one pooled benchmark launch mode: enable_benchmark_cluster_network or enable_benchmark_instance_pool."
  }
}

check "benchmark_cluster_network_shape_hint" {
  assert {
    condition     = !var.enable_benchmark_cluster_network || length(regexall("^BM\\.", var.benchmark_shape)) > 0
    error_message = "enable_benchmark_cluster_network=true is intended for cluster-network-capable bare-metal shapes (for example BM.Optimized3.36)."
  }
}

check "benchmark_no_smt" {
  assert {
    condition     = !var.hyperthreading
    error_message = "Benchmark profiles require hyperthreading=false so BM and VM runs use no SMT."
  }
}

check "bm_rdma_profile_requires_rdma" {
  assert {
    condition     = var.benchmark_tuning_profile != "bm_rdma" || var.benchmark_cloud_init_rdma
    error_message = "benchmark_tuning_profile=bm_rdma requires benchmark_cloud_init_rdma=true so eth1/RDMA addressing and BM VMA tuning are applied together."
  }
}

check "cloud_init_rdma_netplan_prefix" {
  assert {
    condition = !(
      var.benchmark_cloud_init_rdma
      && var.benchmark_cloud_init_rdma_configure_netplan
      && length(trimspace(var.benchmark_cloud_init_rdma_ipv4_prefix)) == 0
    )
    error_message = "benchmark_cloud_init_rdma_ipv4_prefix is required when benchmark_cloud_init_rdma and benchmark_cloud_init_rdma_configure_netplan are true, for example 10.34.100."
  }
}
