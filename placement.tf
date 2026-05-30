# Cluster placement group for benchmark nodes in benchmark_ad (low-latency proximity).
# Failover uses a different AD and cannot share this group.

resource "oci_cluster_placement_groups_cluster_placement_group" "benchmark" {
  count = local.enable_benchmark_cluster_placement_group ? 1 : 0

  compartment_id               = var.compartment_ocid
  availability_domain          = local.benchmark_ad_effective
  name                         = substr("${local.cluster_name}-bench-cpg", 0, 255)
  description                  = "Benchmark placement group"
  cluster_placement_group_type = "STANDARD"

  dynamic "capabilities" {
    for_each = trimspace(var.benchmark_cluster_placement_group_token) == "" ? [1] : []
    content {
      items {
        service = var.benchmark_cluster_placement_group_capability_service
        name    = var.benchmark_cluster_placement_group_capability_name
      }
    }
  }

  dynamic "placement_instruction" {
    for_each = trimspace(var.benchmark_cluster_placement_group_token) != "" ? [1] : []
    content {
      type  = "TOKEN"
      value = trimspace(var.benchmark_cluster_placement_group_token)
    }
  }

  freeform_tags = {
    cluster_name = local.cluster_name
    aeron        = "true"
  }
}

resource "null_resource" "benchmark_cpg_ready" {
  count = local.enable_benchmark_cluster_placement_group ? 1 : 0

  triggers = {
    cpg_id = oci_cluster_placement_groups_cluster_placement_group.benchmark[0].id
  }

  provisioner "local-exec" {
    interpreter = ["powershell.exe", "-NoProfile", "-Command"]
    command     = "Start-Sleep -Seconds 90"
  }
}
