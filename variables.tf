# Core OCI Variables
variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID"
}

variable "region" {
  type        = string
  description = "OCI region"
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID where resources will be created"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for instance access"
}

# Cluster Configuration
variable "cluster_name" {
  type        = string
  description = "Name prefix for all resources"
  default     = "aeron"
}

variable "use_custom_name" {
  type        = bool
  description = "Use custom cluster name instead of auto-generated"
  default     = false
}

# =============================================================================
# Controller Node Configuration (Public Subnet - Orchestrator)
# =============================================================================
variable "controller_ad" {
  type        = string
  description = "Availability Domain for the controller node"
}

variable "controller_shape" {
  type        = string
  description = "Compute shape for the controller node"
  default     = "VM.Standard.E5.Flex"
}

variable "controller_ocpus" {
  type        = number
  description = "Number of OCPUs for the controller node (orchestrator only)"
  default     = 2
}

variable "controller_memory_gb" {
  type        = number
  description = "Memory in GB for the controller node"
  default     = 16
}

variable "controller_boot_volume_size_gb" {
  type        = number
  description = "Boot volume size in GB for the controller node"
  default     = 100
}

# =============================================================================
# Benchmark Nodes Configuration (Private Subnet - Client/Receiver)
# =============================================================================
variable "benchmark_ad" {
  type        = string
  description = "Availability Domain for benchmark nodes (client/receiver)"
}

variable "benchmark_node_count" {
  type        = number
  description = "Number of benchmark nodes to deploy (minimum 2 for client/receiver pair)"
  default     = 2
  validation {
    condition     = var.benchmark_node_count >= 2
    error_message = "At least 2 benchmark nodes are required (client and receiver)."
  }
}

variable "benchmark_shape" {
  type        = string
  description = "Compute shape for benchmark nodes"
  default     = "VM.Standard.E5.Flex"
}

variable "benchmark_ocpus" {
  type        = number
  description = "Number of OCPUs for each benchmark node (minimum 10 for Aeron performance)"
  default     = 10
  validation {
    condition     = var.benchmark_ocpus >= 10
    error_message = "Benchmark nodes require at least 10 OCPUs for optimal Aeron performance."
  }
}

variable "benchmark_memory_gb" {
  type        = number
  description = "Memory in GB for each benchmark node"
  default     = 64
}

variable "benchmark_boot_volume_size_gb" {
  type        = number
  description = "Boot volume size in GB for benchmark nodes"
  default     = 200
}

# =============================================================================
# Failover Node Configuration (Private Subnet - Different AD)
# =============================================================================
variable "enable_failover_node" {
  type        = bool
  description = "Enable a failover node in a separate Availability Domain"
  default     = false
}

variable "failover_ad" {
  type        = string
  description = "Availability Domain for the failover node (must be different from benchmark nodes)"
  default     = ""
}

variable "failover_shape" {
  type        = string
  description = "Compute shape for the failover node"
  default     = "VM.Standard.E5.Flex"
}

variable "failover_ocpus" {
  type        = number
  description = "Number of OCPUs for the failover node (minimum 10)"
  default     = 10
  validation {
    condition     = var.failover_ocpus >= 10
    error_message = "Failover node requires at least 10 OCPUs."
  }
}

variable "failover_memory_gb" {
  type        = number
  description = "Memory in GB for the failover node"
  default     = 64
}

variable "failover_boot_volume_size_gb" {
  type        = number
  description = "Boot volume size in GB for the failover node"
  default     = 200
}

# =============================================================================
# Performance Settings
# =============================================================================
variable "hyperthreading" {
  type        = bool
  description = "Enable hyperthreading (SMT). Disabled by default for optimal Aeron performance."
  default     = false
}

variable "benchmark_cluster_cpu_affinity" {
  type        = string
  description = "Cluster matrix CPU pinning: auto = SSH to receiver and parse numactl node 0 (recommended). static = derive 0..(OCPU×(HT?2:1)-1) from stack only."
  default     = "auto"

  validation {
    condition     = contains(["auto", "static"], var.benchmark_cluster_cpu_affinity)
    error_message = "benchmark_cluster_cpu_affinity must be auto or static."
  }
}

# =============================================================================
# Network Configuration
# =============================================================================
variable "use_existing_vcn" {
  type        = bool
  description = "Use an existing VCN instead of creating a new one"
  default     = false
}

variable "vcn_compartment_ocid" {
  type        = string
  description = "Compartment OCID where the VCN exists or will be created"
  default     = ""
}

variable "existing_vcn_id" {
  type        = string
  description = "OCID of existing VCN to use (when use_existing_vcn is true)"
  default     = ""
}

variable "existing_public_subnet_id" {
  type        = string
  description = "OCID of existing public subnet for controller (when use_existing_vcn is true)"
  default     = ""
}

variable "existing_private_subnet_id" {
  type        = string
  description = "OCID of existing private subnet for benchmark/failover nodes (when use_existing_vcn is true)"
  default     = ""
}

variable "vcn_cidr_block" {
  type        = string
  description = "CIDR block for new VCN"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR block for public subnet"
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR block for private subnet"
  default     = "10.0.1.0/24"
}

# When empty, uses VCN primary CIDR (existing VCN from data source, or vcn_cidr_block for new VCN).
variable "aeron_benchmark_udp_ingress_cidr" {
  type        = string
  description = "Source CIDR for UDP ingress to benchmark nodes (echo ~12k–14k, cluster ~20k–24k, ephemeral responses up to 65535 in managed NSG/iptables). Set explicitly if benchmarks fail with existing VCN/security lists."
  default     = ""
}

variable "aeron_benchmark_configure_host_firewall" {
  type        = bool
  description = "On benchmark nodes (client/receiver), insert iptables ACCEPT for UDP 12000-65535 from the effective VCN CIDR (same as aeron_benchmark_udp_ingress_cidr when resolved). Fixes host-level INPUT reject despite OCI NSG/SL."
  default     = true
}

variable "aeron_benchmark_host_firewall_persistent" {
  type        = bool
  description = "When true, install iptables-persistent and run netfilter-persistent save after adding the benchmark UDP rule."
  default     = false
}

# Echo LoadTestRig channel URIs use |interface=local_ip/prefix. Quickstart uses /24; many OCI subnets are /16.
variable "aeron_echo_udp_interface_prefix_length" {
  type        = string
  description = "Prefix length for Aeron echo UDP |interface=LOCAL/prefix (default 24). Set \"16\" if benchmark nodes sit on a /16 subnet. Set \"\" to omit |interface= (diagnostics only). Ignored if aeron_echo_udp_named_interface is set."
  default     = "24"
}

# Aeron 1.50+ driver: interface={ifname} binds via NetworkInterface.getByName — see aeron-io/aeron NamedInterface.java
variable "aeron_echo_udp_named_interface" {
  type        = string
  description = "Optional NIC name for echo |interface={name} (Aeron 1.50+). Use ip -br a on a benchmark node (e.g. enp0s9 on many OCI shapes; do not assume ens3). Overrides CIDR-style interface when non-empty."
  default     = ""
}

variable "private_deployment" {
  type        = bool
  description = "Deploy controller without public IP (requires VPN/FastConnect access)"
  default     = false
}

# =============================================================================
# Image Configuration
# =============================================================================
variable "use_default_image" {
  type        = bool
  description = "Use default Ubuntu 24.04 Minimal image (recommended for Aeron benchmarking)"
  default     = true
}

variable "default_image_name" {
  type        = string
  description = "Default image for Aeron benchmarking"
  default     = "Canonical-Ubuntu-24.04-Minimal-2025.01.31-0"
}

variable "marketplace_image" {
  type        = string
  description = "Alternative marketplace image"
  default     = "Canonical-Ubuntu-24.04-Minimal-2025.01.31-0"
}

variable "custom_image_ocid" {
  type        = string
  description = "Custom image OCID (only used when not using default or marketplace)"
  default     = ""
}

# =============================================================================
# Username Configuration
# =============================================================================
variable "ssh_username" {
  type        = string
  description = "Default SSH username (ubuntu for Ubuntu images)"
  default     = "ubuntu"
}

# =============================================================================
# Aeron Configuration
# =============================================================================
variable "aeron_git_repo" {
  type        = string
  description = "Aeron (real-logic) Git repository URL for Media Driver and samples"
  default     = "https://github.com/real-logic/aeron.git"
}

variable "aeron_git_branch" {
  type        = string
  description = "Aeron Git branch or tag (leave empty for latest master)"
  default     = ""
}

variable "benchmarks_repo_url" {
  type        = string
  description = "Benchmarks repo URL (official aeron-io/benchmarks for LoadTestRig, echo/cluster scenarios)"
  default     = "https://github.com/aeron-io/benchmarks"
}

variable "benchmarks_git_branch" {
  type        = string
  description = "Benchmarks repo branch or tag (leave empty for master)"
  default     = ""
}

variable "java_version" {
  type        = string
  description = "Java version (Temurin/Adoptium) - 17 recommended for Aeron"
  default     = "17"
}

variable "install_aeron" {
  type        = bool
  description = "Install Aeron and dependencies"
  default     = true
}

variable "run_benchmarks" {
  type        = bool
  description = "Run Aeron benchmarks after installation"
  default     = false
}

variable "run_benchmarks_matrix_modes" {
  type        = string
  description = "Driver matrix modes for automated benchmark run (comma-separated): java,java_vma,c,c_vma"
  default     = "java,java_vma,c,c_vma"
}

variable "run_benchmarks_cluster_matrix" {
  type        = bool
  description = "When enable_failover_node is true, also run the cluster driver matrix after the echo matrix (strict; failures fail apply). Disable for echo-only validation."
  default     = true
}

variable "pull_matrix_summary_for_terraform_output" {
  type        = bool
  description = "After run_driver_matrix, SSH from the Terraform machine to the controller and write .terraform-matrix-summary.json so outputs include median latencies. Requires OpenSSH + python3 on the machine running terraform. Set false if apply should not depend on local SSH (e.g. some CI)."
  default     = true
}

variable "benchmark_echo_runs" {
  type        = number
  description = "Echo benchmark RUNS (outer repetitions inside one remote-echo-benchmarks invocation; result paths often show run-1, run-2, …). Default 1 is smoke-style (fast matrix). Use 3+ for a bit more sampling; use 5+ with higher iterations for CHECKLIST-style baselines."
  default     = 1
}

variable "benchmark_echo_iterations" {
  type        = number
  description = "Echo benchmark ITERATIONS (LoadTestRig measurement iterations per run; not the same as RUNS or total message count). Default 1 is smoke-style."
  default     = 1
}

variable "benchmark_echo_warmup_iterations" {
  type        = number
  description = "Echo benchmark WARMUP_ITERATIONS before measurement. Default 1 is smoke-style."
  default     = 1
}

variable "benchmark_echo_warmup_message_rate" {
  type        = string
  description = "Warmup message rate label (e.g. 25K) — throughput during warmup, not a message cap."
  default     = "25K"
}

variable "benchmark_message_length" {
  type        = number
  description = "Echo MESSAGE_LENGTH in bytes (e.g. 288)."
  default     = 288
}

variable "benchmark_message_rate" {
  type        = string
  description = "Echo MESSAGE_RATE (numeric msg/s e.g. 100001, or shorthand like 101K). Target throughput for LoadTestRig, not an exact total message count."
  default     = "100001"
}

variable "benchmark_build_native_aeronmd" {
  type        = bool
  description = "Build Aeron C media driver (aeronmd) on the controller and include it in benchmarks-dist (required for echo matrix modes c and c_vma)."
  default     = true
}

# =============================================================================
# Instance Principal for API access
# =============================================================================
variable "use_instance_principal" {
  type        = bool
  description = "Use instance principal for OCI API authentication"
  default     = true
}
