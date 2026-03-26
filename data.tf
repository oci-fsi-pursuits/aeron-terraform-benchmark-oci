data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Default image: Ubuntu 24.04 Minimal (best for Aeron benchmarking)
data "oci_core_images" "ubuntu_minimal" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04 Minimal"
  shape                    = var.benchmark_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-24\\.04-Minimal-.*$"]
    regex  = true
  }
}

# Alternative marketplace images
data "oci_core_images" "marketplace_image" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  shape                    = var.benchmark_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = [var.marketplace_image]
    regex  = false
  }
}

data "oci_core_vcns" "existing_vcns" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  state          = "AVAILABLE"
}

# Primary CIDR for NSG rules (aeron-io/benchmarks echo uses UDP ~13000/13100; must match your VCN).
data "oci_core_vcn" "existing" {
  count  = var.use_existing_vcn ? 1 : 0
  vcn_id = var.existing_vcn_id
}
