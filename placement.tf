# Cluster placement group for benchmark nodes in benchmark_ad (low-latency proximity).
# Failover uses a different AD and cannot share this group.

resource "oci_cluster_placement_groups_cluster_placement_group" "benchmark" {
  count = local.enable_benchmark_cluster_placement_group ? 1 : 0

  compartment_id               = var.compartment_ocid
  availability_domain          = var.benchmark_ad
  name                         = substr("${local.cluster_name}-bench-cpg", 0, 255)
  description                  = "Benchmark client/receiver placement for ${local.cluster_name}"
  cluster_placement_group_type = "STANDARD"

  freeform_tags = {
    cluster_name = local.cluster_name
    aeron        = "true"
  }
}
