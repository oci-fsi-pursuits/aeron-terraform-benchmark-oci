resource "oci_core_compute_cluster" "benchmark_rdma" {
  count = var.enable_rdma_compute_cluster && trimspace(var.rdma_existing_compute_cluster_id) == "" ? 1 : 0

  availability_domain = local.benchmark_ad_effective
  compartment_id      = var.compartment_ocid
  display_name        = "${local.cluster_name}-rdma-cc"

  freeform_tags = {
    cluster_name = local.cluster_name
    aeron        = "true"
    role         = "benchmark-rdma-compute-cluster"
  }
}
