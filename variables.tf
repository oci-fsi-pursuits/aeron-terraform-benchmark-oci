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

variable "instance_hostname_prefix" {
  type        = string
  description = "Optional DNS-safe prefix for OCI VNIC hostname labels (unique per subnet). Use when sharing subnets across stacks with the same cluster_name. Empty: derived from cluster_name; if use_custom_name=true, random_pet is appended automatically. Example: myproj-phx-a."
  default     = ""
}

# =============================================================================
# Controller Node Configuration (Public Subnet - Orchestrator)
# =============================================================================
variable "controller_ad" {
  type        = string
  description = "Availability Domain for the controller node. Empty string selects the first AD returned by OCI for the region."
  default     = ""
}

variable "controller_shape" {
  type        = string
  description = "Compute shape for the controller node"
  default     = "VM.Standard.E6.Flex"
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
  description = "Availability Domain for benchmark nodes (client/receiver). Empty string selects the first AD returned by OCI for the region."
  default     = ""
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

variable "enable_cluster_raft_consensus" {
  type        = bool
  description = "Enable a 3-member Aeron Cluster/Raft topology for cluster benchmarks. When true, Terraform provisions enough benchmark instances for client + node0/node1/node2 and Ansible renders CLUSTER_SIZE=3 with CLUSTER_BACKUP_NODES=0."
  default     = false
}

variable "benchmark_cluster_udp_fabric" {
  type        = string
  description = "UDP fabric for Aeron cluster benchmark channels. auto follows RDMA when configured; vcn forces primary private-subnet IPs for cross-AD cluster benchmarks; rdma forces the configured RDMA/RoCE fabric."
  default     = "auto"

  validation {
    condition     = contains(["auto", "vcn", "rdma"], lower(trimspace(var.benchmark_cluster_udp_fabric)))
    error_message = "benchmark_cluster_udp_fabric must be auto, vcn, or rdma."
  }
}

variable "benchmark_tuning_profile" {
  type        = string
  description = "Benchmark runtime tuning profile. auto selects bm_rdma when benchmark_cloud_init_rdma=true, otherwise vm_stable. bm_rdma enables validated BM RDMA/VMA launch, native c-media-driver for cluster java_vma, /dev/shm fixup, eth1 NUMA pins, and Aeron high-rate values; vm_stable keeps conservative VM-safe Aeron values."
  default     = "auto"
  validation {
    condition     = contains(["auto", "bm_rdma", "vm_stable"], var.benchmark_tuning_profile)
    error_message = "benchmark_tuning_profile must be auto, bm_rdma, or vm_stable."
  }
}

variable "benchmark_shape" {
  type        = string
  description = "Compute shape for benchmark nodes"
  default     = "VM.Standard.E6.Flex"
}

variable "benchmark_ocpus" {
  type        = number
  description = "Number of OCPUs for each benchmark node on Flex shapes. For bare-metal shapes this is not sent to OCI, but is still passed to Ansible as a fallback CPU-affinity hint."
  default     = 16
  validation {
    condition     = var.benchmark_ocpus >= 1
    error_message = "Benchmark node OCPUs must be at least 1."
  }
}

variable "benchmark_memory_gb" {
  type        = number
  description = "Memory in GB for each benchmark node on Flex shapes. Ignored by OCI for bare-metal shapes."
  default     = 124
}

variable "benchmark_boot_volume_size_gb" {
  type        = number
  description = "Boot volume size in GB for benchmark nodes"
  default     = 200
}

variable "benchmark_block_volume_enabled" {
  type        = bool
  description = "Attach and mount a dedicated block volume on each benchmark node for Aeron cluster/archive data. This is additive and is intended for BM/RDMA cluster benchmarks where cluster log storage should not live on the boot volume."
  default     = false
}

variable "benchmark_block_volume_size_gb" {
  type        = number
  description = "Size in GB for each benchmark node data block volume."
  default     = 256

  validation {
    condition     = var.benchmark_block_volume_size_gb >= 50
    error_message = "benchmark_block_volume_size_gb must be at least 50."
  }
}

variable "benchmark_block_volume_vpus_per_gb" {
  type        = number
  description = "OCI block volume VPUs/GB for benchmark data volumes."
  default     = 20

  validation {
    condition     = var.benchmark_block_volume_vpus_per_gb >= 0 && var.benchmark_block_volume_vpus_per_gb <= 120
    error_message = "benchmark_block_volume_vpus_per_gb must be between 0 and 120."
  }
}

variable "benchmark_block_volume_device" {
  type        = string
  description = "Guest device path for attached benchmark data volumes, or \"auto\" to let Ansible pick an unformatted non-root disk. Paravirtualized attachments request this path from OCI; iSCSI attachments ignore it at attach time."
  default     = "/dev/oracleoci/oraclevdb"
}

variable "benchmark_block_volume_attachment_type" {
  type        = string
  description = "OCI attachment type for benchmark data volumes. Use iscsi for bare metal shapes and paravirtualized for VM shapes."
  default     = "paravirtualized"

  validation {
    condition     = contains(["iscsi", "paravirtualized"], lower(trimspace(var.benchmark_block_volume_attachment_type)))
    error_message = "benchmark_block_volume_attachment_type must be iscsi or paravirtualized."
  }
}

variable "benchmark_block_volume_mount_path" {
  type        = string
  description = "Mount path for benchmark node data volumes. Cluster/archive directories are rendered below this path when benchmark_block_volume_enabled=true."
  default     = "/mnt/aeron-cluster"
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
  description = "Availability Domain for the failover node (must be different from benchmark nodes). Empty string selects the second AD returned by OCI for the region."
  default     = ""
}

variable "failover_shape" {
  type        = string
  description = "Compute shape for the failover node"
  default     = "VM.Standard.E6.Flex"
}

variable "failover_ocpus" {
  type        = number
  description = "Number of OCPUs for the failover node on Flex shapes. For bare-metal shapes this is not sent to OCI, but is still passed to Ansible as a fallback CPU-affinity hint."
  default     = 16
  validation {
    condition     = var.failover_ocpus >= 1
    error_message = "Failover node OCPUs must be at least 1."
  }
}

variable "failover_memory_gb" {
  type        = number
  description = "Memory in GB for the failover node on Flex shapes. Ignored by OCI for bare-metal shapes."
  default     = 124
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

variable "grub_dynamic_cpu_isolation" {
  type        = bool
  description = "On benchmark/failover nodes, write GRUB isolcpus/nohz_full/rcu_nocbs/irqaffinity from live logical CPU count. Housekeeping = min(N, min(cap, max(floor, ceil(N*fraction)))); single drop-in 51-aeron-cpu-isolation.cfg (legacy 99-aeron disabled); strips duplicate tokens from 50-cloudimg-settings.cfg. aeron-benchmark-bootstrap.service uncaps init/sshd affinity, applies IRQ mask, and persists benchmark-subnet iptables. Requires reboot for kernel args."
  default     = true
}

variable "grub_housekeeping_fraction" {
  type        = number
  description = "Housekeeping count uses ceil(N × fraction) lower-bounded by grub_housekeeping_floor and upper-bounded by grub_housekeeping_cpus_max (unless max is 0). Default 0.17 matches updated remediation (~8 CPUs at 48 OCPU)."
  default     = 0.17

  validation {
    condition     = var.grub_housekeeping_fraction > 0 && var.grub_housekeeping_fraction <= 0.5
    error_message = "grub_housekeeping_fraction must be in (0, 0.5]."
  }
}

variable "grub_housekeeping_floor" {
  type        = number
  description = "Minimum housekeeping logical CPUs when N allows (still clamped to N). Default 2 per remediation handoff."
  default     = 2

  validation {
    condition     = var.grub_housekeeping_floor >= 1 && var.grub_housekeeping_floor <= 64
    error_message = "grub_housekeeping_floor must be between 1 and 64."
  }
}

variable "grub_housekeeping_cpus_max" {
  type        = number
  description = "Maximum housekeeping logical CPUs (default 8 per handoff). Set 0 to disable the upper cap (only floor + fraction + min(N) apply)."
  default     = 8

  validation {
    condition     = var.grub_housekeeping_cpus_max >= 0
    error_message = "grub_housekeeping_cpus_max must be >= 0 (0 disables the cap)."
  }
}

variable "benchmark_cpu_profile" {
  type        = string
  description = "Benchmark CPU isolation/pinning profile. auto keeps dynamic behavior but applies the validated OCI 16 CPU SMT-off VM profile when detected. contiguous_low keeps legacy low-CPU housekeeping. oci_vm_16_smt_off forces housekeeping=6-8 and isolated=0-5,9-15."
  default     = "auto"

  validation {
    condition     = contains(["auto", "contiguous_low", "oci_vm_16_smt_off"], var.benchmark_cpu_profile)
    error_message = "benchmark_cpu_profile must be auto, contiguous_low, or oci_vm_16_smt_off."
  }
}

variable "benchmark_housekeeping_cpus_override" {
  type        = string
  description = "Optional explicit housekeeping CPU list/range for benchmark/failover nodes, e.g. 6-8. Overrides benchmark_cpu_profile when non-empty."
  default     = ""
}

variable "benchmark_isolated_cpus_override" {
  type        = string
  description = "Optional explicit isolated CPU list/range for benchmark/failover nodes, e.g. 0-5,9-15. Overrides benchmark_cpu_profile when non-empty."
  default     = ""
}

variable "benchmark_irq_affinity_override" {
  type        = string
  description = "Optional explicit irqaffinity CPU list/range for benchmark/failover nodes. Defaults to housekeeping CPU list."
  default     = ""
}

variable "benchmark_echo_client_pins" {
  type        = string
  description = "Optional explicit echo client hot-core pins as conductor,sender,receiver,load-test-rig, e.g. 1,2,3,4."
  default     = ""
}

variable "benchmark_echo_server_pins" {
  type        = string
  description = "Optional explicit echo server hot-core pins as conductor,sender,receiver,echo, e.g. 1,2,3,4."
  default     = ""
}

# =============================================================================
# Network Configuration
# =============================================================================
variable "use_existing_vcn" {
  type        = bool
  description = "Use an existing VCN instead of creating a new one"
  default     = false
}

variable "create_benchmark_cluster_placement_group" {
  type        = bool
  description = "Create a cluster placement group in benchmark_ad for benchmark VMs (physical proximity). Ignored when enable_rdma_compute_cluster is true."
  default     = true
}

variable "enable_benchmark_cluster_network" {
  type        = bool
  description = "Launch primary benchmark nodes through an OCI cluster network with per-node instance pools and instance configurations. Intended for OCI shapes that support cluster networks, such as BM.Optimized3.36."
  default     = false
}

variable "enable_benchmark_instance_pool" {
  type        = bool
  description = "Launch primary benchmark nodes through a regular OCI instance pool backed by an instance configuration. Use this for VM shapes that support instance pools and CPGs but are rejected by OCI cluster networks."
  default     = false
}

variable "benchmark_cluster_placement_group_token" {
  type        = string
  description = "Optional OCI-provided placement instruction token for benchmark cluster placement group creation. Required for shapes/regions that reject compute/general CPGs at instance launch."
  default     = ""
  sensitive   = true
}

variable "benchmark_cluster_placement_group_capability_service" {
  type        = string
  description = "CPG capability service used when no benchmark_cluster_placement_group_token is provided."
  default     = "compute"
}

variable "benchmark_cluster_placement_group_capability_name" {
  type        = string
  description = "CPG capability name used when no benchmark_cluster_placement_group_token is provided."
  default     = "general"
}

variable "enable_rdma_compute_cluster" {
  type        = bool
  description = "Enable OCI compute cluster placement for benchmark nodes (RDMA-ready topology). When true, benchmark instances are launched into a compute cluster and standard benchmark placement group is disabled."
  default     = false
}

variable "rdma_existing_compute_cluster_id" {
  type        = string
  description = "Optional existing OCI compute cluster OCID to use for benchmark nodes when enable_rdma_compute_cluster is true. Empty creates a new compute cluster in benchmark_ad."
  default     = ""
}

variable "rdma_enable_hpc_plugins" {
  type        = bool
  description = "Enable OCI instance-agent RDMA plugins (Compute HPC RDMA Authentication and Auto-Configuration) on benchmark nodes."
  default     = true
}

variable "benchmark_cloud_init_rdma" {
  type        = bool
  description = "Configure benchmark nodes for RDMA from cloud-init instead of relying on Oracle Cloud Agent HPC RDMA plugins. Intended for Ubuntu cluster-network tests."
  default     = false
}

variable "benchmark_cloud_init_rdma_interface" {
  type        = string
  description = "RDMA interface name passed to the benchmark cloud-init RDMA bootstrap."
  default     = "eth1"
}

variable "benchmark_cloud_init_rdma_configure_netplan" {
  type        = bool
  description = "When benchmark_cloud_init_rdma is true, create a Netplan file for the first non-primary RDMA/RoCE port and rename/configure it as benchmark_cloud_init_rdma_interface."
  default     = true
}

variable "benchmark_cloud_init_rdma_ipv4_prefix" {
  type        = string
  description = "IPv4 prefix for the RDMA fabric interface, excluding the host octet. Example: 10.34.100 makes a node with primary IP 10.34.1.234 use 10.34.100.234. Empty skips RDMA Netplan IP configuration."
  default     = ""
}

variable "benchmark_cloud_init_rdma_prefix_length" {
  type        = number
  description = "IPv4 prefix length for the cloud-init configured RDMA fabric interface."
  default     = 24

  validation {
    condition     = var.benchmark_cloud_init_rdma_prefix_length >= 1 && var.benchmark_cloud_init_rdma_prefix_length <= 32
    error_message = "benchmark_cloud_init_rdma_prefix_length must be between 1 and 32."
  }
}

variable "benchmark_cloud_init_rdma_mtu" {
  type        = number
  description = "MTU applied to the cloud-init configured RDMA fabric interface. OCI BM.Optimized3 working Ubuntu bring-up used 4220."
  default     = 4220
}

variable "benchmark_cloud_init_rdma_apt_packages" {
  type        = string
  description = "Space-separated Ubuntu packages installed by cloud-init before RDMA/VMA checks."
  default     = "rdma-core ibverbs-providers infiniband-diags ibverbs-utils librdmacm1 rdmacm-utils perftest ethtool pciutils"
}

variable "benchmark_cloud_init_rdma_extra_commands" {
  type        = list(string)
  description = "Extra shell commands appended to the benchmark cloud-init RDMA bootstrap. Use for OCI-specific RDMA registration/configuration commands."
  default     = []
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
  description = "CIDR block for the private subnet (new VCN) or the exact CIDR of the existing private subnet. Must match the real subnet mask (e.g. 172.16.4.0/22) so aeron_echo_udp_interface_prefix_length=auto sets echo |interface=IP/prefix correctly; a wrong mask (e.g. /24 when the subnet is /22) can break UDP bind/routing."
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
  description = "On benchmark and failover nodes, insert iptables ACCEPT for all traffic from aeron_benchmark_udp_ingress_cidr (subnet-wide east-west), plus UDP 12000-65535 rules on client/receiver. Fixes host-level INPUT reject despite OCI NSG/SL."
  default     = true
}

variable "aeron_benchmark_host_firewall_persistent" {
  type        = bool
  description = "When true, install iptables-persistent and run netfilter-persistent save after adding the benchmark UDP rule."
  default     = false
}

# Echo LoadTestRig channel URIs use |interface=local_ip/prefix. Default "auto" matches private_subnet_cidr mask.
variable "aeron_echo_udp_interface_prefix_length" {
  type        = string
  description = <<-EOT
    Prefix length for Aeron echo UDP |interface=LOCAL/prefix. Use "auto" (default) to derive the mask from Terraform private_subnet_cidr so it stays aligned with the provisioned benchmark subnet (e.g. /24 → 24).
    Set an explicit value such as "16" or "24" to override. Set "" to omit |interface= (diagnostics only). Ignored if aeron_echo_udp_named_interface is set.
  EOT
  default     = "auto"

  validation {
    condition = (
      trimspace(var.aeron_echo_udp_named_interface) != "" ||
      trimspace(var.aeron_echo_udp_interface_prefix_length) == "" ||
      lower(trimspace(var.aeron_echo_udp_interface_prefix_length)) == "auto" ||
      (
        can(tonumber(trimspace(var.aeron_echo_udp_interface_prefix_length))) &&
        tonumber(trimspace(var.aeron_echo_udp_interface_prefix_length)) >= 1 &&
        tonumber(trimspace(var.aeron_echo_udp_interface_prefix_length)) <= 32
      )
    )
    error_message = "aeron_echo_udp_interface_prefix_length must be \"auto\", empty (omit interface), or a decimal prefix length 1–32 (unless aeron_echo_udp_named_interface is set)."
  }
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
  description = "Use default regular Ubuntu 24.04 image. Minimal images are not used because they lack bootstrap tools such as unzip."
  default     = true
}

variable "default_image_name" {
  type        = string
  description = "Default image for Aeron benchmarking"
  default     = "Canonical-Ubuntu-24.04"
}

variable "marketplace_image" {
  type        = string
  description = "Alternative marketplace image"
  default     = "Canonical-Ubuntu-24.04"
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

variable "install_oci_cn_auth" {
  type        = bool
  description = "Install and enable oci-cn-auth on benchmark/failover nodes during bootstrap (intended for RDMA-capable Oracle Linux images)."
  default     = false
}

variable "run_smoke_test" {
  type        = bool
  description = "After deployment, run a fast driver-matrix echo pass (and optional cluster matrix) with RUNS=1, ITERATIONS=1, WARMUP_ITERATIONS=1 to validate wiring and driver modes. Independent of run_full_benchmark."
  default     = true
}

variable "run_full_benchmark" {
  type        = bool
  description = "After deployment, run a longer driver-matrix echo pass (and optional cluster matrix) for baseline-style HDR sampling. When run_smoke_test is also true, smoke runs first; summaries for Terraform output use the full pass. Uses full_benchmark_* tuning and a longer per-mode timeout."
  default     = false
}

variable "full_benchmark_echo_runs" {
  type        = number
  description = "Outer RUNS for the automated full benchmark matrix (when run_full_benchmark=true)."
  default     = 5
}

variable "full_benchmark_echo_iterations" {
  type        = number
  description = "ITERATIONS per run for the automated full benchmark matrix."
  default     = 30
}

variable "full_benchmark_echo_warmup_iterations" {
  type        = number
  description = "WARMUP_ITERATIONS for the automated full benchmark matrix."
  default     = 10
}

variable "full_benchmark_warmup_message_rate" {
  type        = string
  description = "WARMUP_MESSAGE_RATE label for the automated full benchmark matrix (e.g. 25K)."
  default     = "25K"
}

variable "full_benchmark_message_length" {
  type        = number
  description = "MESSAGE_LENGTH (bytes) for the automated full benchmark matrix."
  default     = 288
}

variable "full_benchmark_message_rate" {
  type        = string
  description = "MESSAGE_RATE for the automated full benchmark matrix (e.g. 101K)."
  default     = "101K"
}

variable "full_benchmark_bench_profile" {
  type        = string
  description = "BENCH_PROFILE for the automated full benchmark matrix (e.g. custom)."
  default     = "custom"
}

variable "full_benchmark_matrix_mode_timeout_sec" {
  type        = number
  description = "Per-mode wall timeout (seconds) for run-driver-matrix during the full benchmark pass. Smoke uses a shorter fixed timeout."
  default     = 7200
}

variable "run_benchmarks_matrix_modes" {
  type        = string
  description = "Driver matrix modes for automated benchmark run (comma-separated). Default java,c avoids VMA. For java_vma,c_vma use Mellanox VMA (LD_PRELOAD libvma on nodes); preflight checks the library on each host. OpenOnload `onload` CLI is optional if ONLOAD_COMMAND_VMA uses LD_PRELOAD only."
  default     = "java,c"
}

variable "run_benchmarks_cluster_matrix" {
  type        = bool
  description = "When enable_failover_node is true, also run the cluster driver matrix after the echo matrix (strict; failures fail apply). Disable for echo-only validation."
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

variable "benchmark_vma_apply_setcap" {
  type        = bool
  description = "On benchmark/failover nodes, run setcap cap_net_raw+ep on Java and aeronmd (recommended for Mellanox VMA / LD_PRELOAD benchmarks)."
  default     = false
}

variable "benchmark_vma_lib_path" {
  type        = string
  description = "Path to libvma.so for ONLOAD_COMMAND_VMA (env LD_PRELOAD=...). Use /usr/lib64/libvma.so.9 on Oracle Linux/RHEL; /usr/lib/x86_64-linux-gnu/libvma.so.9 on Ubuntu."
  default     = "/usr/lib/x86_64-linux-gnu/libvma.so.9"
}

variable "benchmark_onload_command_vma" {
  type        = string
  description = "Optional full ONLOAD_COMMAND_VMA override. Leave empty to derive from benchmark_tuning_profile and benchmark_vma_lib_path."
  default     = ""
}

variable "benchmark_aeron_socket_so_sndbuf" {
  type        = string
  description = "Optional AERON_SOCKET_SO_SNDBUF override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_aeron_socket_so_rcvbuf" {
  type        = string
  description = "Optional AERON_SOCKET_SO_RCVBUF override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_aeron_rcv_initial_window_length" {
  type        = string
  description = "Optional AERON_RCV_INITIAL_WINDOW_LENGTH override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_aeron_max_messages_per_send" {
  type        = string
  description = "Optional AERON_NETWORK_PUBLICATION_MAX_MESSAGES_PER_SEND override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_aeron_receiver_io_vector_capacity" {
  type        = string
  description = "Optional AERON_RECEIVER_IO_VECTOR_CAPACITY override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_aeron_sender_io_vector_capacity" {
  type        = string
  description = "Optional AERON_SENDER_IO_VECTOR_CAPACITY override. Leave empty to derive from benchmark_tuning_profile."
  default     = ""
}

variable "benchmark_install_vma_runtime" {
  type        = bool
  description = "Ansible: apt/dnf install libvma on benchmark workload nodes (client/receiver/failover) so java_vma/c_vma matrix preflight passes."
  default     = false
}

variable "benchmark_vma_build_from_source" {
  type        = bool
  description = "Ansible: compile libvma from github.com/Mellanox/libvma (requires RDMA dev packages: libibverbs, librdmacm, libmlx5). Pin benchmark_vma_git_ref for reproducible builds."
  default     = false
}

variable "benchmark_vma_git_ref" {
  type        = string
  description = "Git tag, branch, or commit for libvma source build when benchmark_vma_build_from_source is true."
  default     = "master"
}

# =============================================================================
# Instance Principal for API access
# =============================================================================
variable "use_instance_principal" {
  type        = bool
  description = "Use instance principal for OCI API authentication"
  default     = true
}
