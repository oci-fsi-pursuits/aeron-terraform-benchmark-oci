# VCN Creation (when not using existing)
resource "oci_core_vcn" "aeron_vcn" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  cidr_blocks    = [var.vcn_cidr_block]
  display_name   = "${local.cluster_name}-vcn"
  dns_label      = "aeronvcn"
}

# Internet Gateway
resource "oci_core_internet_gateway" "internet_gateway" {
  count          = var.use_existing_vcn || var.private_deployment ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-igw"
  enabled        = true
}

# NAT Gateway
resource "oci_core_nat_gateway" "nat_gateway" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-natgw"
}

# Service Gateway
resource "oci_core_service_gateway" "service_gateway" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-sgw"

  services {
    service_id = data.oci_core_services.all_services.services[0].id
  }
}

# Public Route Table
resource "oci_core_route_table" "public_route_table" {
  count          = var.use_existing_vcn || var.private_deployment ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.internet_gateway[0].id
  }
}

# Private Route Table
resource "oci_core_route_table" "private_route_table" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway[0].id
  }

  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.service_gateway[0].id
  }
}

# Public Security List
resource "oci_core_security_list" "public_security_list" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-public-sl"

  # Allow all traffic within VCN
  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_block
  }

  # SSH access
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Aeron samples-style ports (Media Driver)
  ingress_security_rules {
    protocol = "17"
    source   = var.vcn_cidr_block
    udp_options {
      min = 40000
      max = 40100
    }
  }

  # aeron-io/benchmarks echo (~13000/13100) + cluster (~20000+) + dynamic UDP response ports
  ingress_security_rules {
    protocol = "17"
    source   = var.vcn_cidr_block
    udp_options {
      min = 12000
      max = 65535
    }
  }

  # ICMP
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = var.vcn_cidr_block
    icmp_options {
      type = 3
    }
  }

  # Allow all egress
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Private Security List
resource "oci_core_security_list" "private_security_list" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-private-sl"

  # Allow all traffic within VCN
  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_block
  }

  # ICMP
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Allow all egress
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# DHCP Options
resource "oci_core_dhcp_options" "dhcp_options" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = local.vcn_compartment
  vcn_id         = local.vcn_id
  display_name   = "${local.cluster_name}-dhcp"

  options {
    type        = "DomainNameServer"
    server_type = "VcnLocalPlusInternet"
  }

  options {
    type                = "SearchDomain"
    search_domain_names = ["aeronvcn.oraclevcn.com"]
  }
}

# Public Subnet
resource "oci_core_subnet" "public_subnet" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = local.vcn_compartment
  vcn_id                     = local.vcn_id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${local.cluster_name}-public-subnet"
  dns_label                  = "public"
  security_list_ids          = [oci_core_security_list.public_security_list[0].id]
  route_table_id             = var.private_deployment ? oci_core_route_table.private_route_table[0].id : oci_core_route_table.public_route_table[0].id
  dhcp_options_id            = oci_core_dhcp_options.dhcp_options[0].id
  prohibit_public_ip_on_vnic = var.private_deployment
}

# Private Subnet
resource "oci_core_subnet" "private_subnet" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = local.vcn_compartment
  vcn_id                     = local.vcn_id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${local.cluster_name}-private-subnet"
  dns_label                  = "private"
  security_list_ids          = [oci_core_security_list.private_security_list[0].id]
  route_table_id             = oci_core_route_table.private_route_table[0].id
  dhcp_options_id            = oci_core_dhcp_options.dhcp_options[0].id
  prohibit_public_ip_on_vnic = true
}
