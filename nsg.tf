# Extra UDP path for aeron-io/benchmarks echo + cluster (echo ~13000/13100; cluster node0 ~20000–20044,
# backup ~23000+, and dynamic client response ports). Subnet security lists must also allow this; NSG is on the VNIC.
resource "oci_core_network_security_group" "aeron_benchmark" {
  compartment_id = var.compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-aeron-benchmark-udp"

  freeform_tags = {
    cluster_name = local.cluster_name
  }
}

resource "oci_core_network_security_group_security_rule" "aeron_benchmark_udp_ingress" {
  network_security_group_id = oci_core_network_security_group.aeron_benchmark.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = local.aeron_benchmark_udp_ingress_cidr
  source_type               = "CIDR_BLOCK"
  description               = "aeron-io benchmarks echo + cluster UDP (echo 12k-14k, cluster 20k-24k, ephemeral responses)"

  udp_options {
    destination_port_range {
      min = 12000
      max = 65535
    }
  }
}

# Stateless NSG: ingress alone does not permit return UDP. Cluster egress (node0 → client ephemeral response
# ports, e.g. 55xxx) must match an explicit egress rule or POLL_RESPONSE stalls with egress.isConnected=false.
resource "oci_core_network_security_group_security_rule" "aeron_benchmark_udp_egress" {
  network_security_group_id = oci_core_network_security_group.aeron_benchmark.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = local.aeron_benchmark_udp_ingress_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "aeron-io benchmarks UDP to VCN (cluster responses to client, echo replies)"

  udp_options {
    destination_port_range {
      min = 12000
      max = 65535
    }
  }
}
