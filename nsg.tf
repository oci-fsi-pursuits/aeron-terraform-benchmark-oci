# Extra UDP path for aeron-io/benchmarks echo/cluster (default channels use ~13000/13100).
# Subnet security lists must also allow this traffic; NSG adds an explicit allow on the VNIC.
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
  description               = "aeron-io benchmarks echo/cluster UDP (default ports in 12k-14k)"

  udp_options {
    destination_port_range {
      min = 12000
      max = 14000
    }
  }
}
