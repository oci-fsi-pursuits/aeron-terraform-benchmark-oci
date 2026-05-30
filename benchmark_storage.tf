# =============================================================================
# Optional benchmark data volumes
#
# Used by BM/RDMA cluster benchmarks so Aeron cluster/archive directories do not
# live on the boot volume. These resources are additive: enabling the flag
# creates one block volume per benchmark node and attaches it to the existing
# direct instance or cluster-network / instance-pool instance.
# =============================================================================

resource "oci_core_volume" "benchmark_data" {
  count = var.benchmark_block_volume_enabled ? local.benchmark_node_count_effective : 0

  availability_domain = local.benchmark_ad_effective
  compartment_id      = var.compartment_ocid
  display_name        = "${local.cluster_name}-benchmark-${count.index + 1}-data"
  size_in_gbs         = var.benchmark_block_volume_size_gb
  vpus_per_gb         = var.benchmark_block_volume_vpus_per_gb

  freeform_tags = {
    cluster_name = local.cluster_name
    role         = count.index == 0 ? "client-data" : count.index == 1 ? "cluster-node0-data" : format("cluster-node-%d-data", count.index - 1)
    aeron        = "true"
  }
}

resource "oci_core_volume_attachment" "benchmark_data" {
  count = var.benchmark_block_volume_enabled ? local.benchmark_node_count_effective : 0

  attachment_type                   = lower(trimspace(var.benchmark_block_volume_attachment_type))
  display_name                      = "${local.cluster_name}-benchmark-${count.index + 1}-data-attachment"
  instance_id                       = local.benchmark_instance_ids[count.index]
  volume_id                         = oci_core_volume.benchmark_data[count.index].id
  device                            = trimspace(var.benchmark_block_volume_device) != "" && lower(trimspace(var.benchmark_block_volume_device)) != "auto" ? trimspace(var.benchmark_block_volume_device) : null
  is_agent_auto_iscsi_login_enabled = lower(trimspace(var.benchmark_block_volume_attachment_type)) == "iscsi" ? false : null
  is_read_only                      = false
  is_shareable                      = false

  depends_on = [
    oci_core_instance.benchmark,
    oci_core_cluster_network.benchmark,
    oci_core_instance_pool.benchmark,
    data.oci_core_instance.benchmark_pool,
  ]
}

resource "null_resource" "benchmark_iscsi_login" {
  count = var.benchmark_block_volume_enabled && lower(trimspace(var.benchmark_block_volume_attachment_type)) == "iscsi" ? local.benchmark_node_count_effective : 0

  depends_on = [oci_core_volume_attachment.benchmark_data]

  triggers = {
    instance_id   = local.benchmark_instance_ids[count.index]
    attachment_id = oci_core_volume_attachment.benchmark_data[count.index].id
    iqn           = oci_core_volume_attachment.benchmark_data[count.index].iqn
    ipv4          = oci_core_volume_attachment.benchmark_data[count.index].ipv4
    port          = tostring(oci_core_volume_attachment.benchmark_data[count.index].port)
    multipath_ipv4 = join(",", [
      for d in oci_core_volume_attachment.benchmark_data[count.index].multipath_devices : d.ipv4
    ])
  }

  connection {
    type        = "ssh"
    host        = local.benchmark_private_ips[count.index]
    user        = var.ssh_username
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "15m"

    bastion_host        = local.controller_host
    bastion_user        = var.ssh_username
    bastion_private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -e",
      "if command -v apt-get >/dev/null 2>&1; then sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y open-iscsi multipath-tools; elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y iscsi-initiator-utils device-mapper-multipath; elif command -v yum >/dev/null 2>&1; then sudo yum install -y iscsi-initiator-utils device-mapper-multipath; fi",
      "sudo systemctl enable --now iscsid 2>/dev/null || sudo systemctl enable --now iscsid.service 2>/dev/null || true",
      "sudo systemctl enable --now multipathd 2>/dev/null || true",
      "for portal in ${join(" ", concat([oci_core_volume_attachment.benchmark_data[count.index].ipv4], [for d in oci_core_volume_attachment.benchmark_data[count.index].multipath_devices : d.ipv4]))}; do sudo iscsiadm -m node -o new -T '${oci_core_volume_attachment.benchmark_data[count.index].iqn}' -p \"$${portal}:${oci_core_volume_attachment.benchmark_data[count.index].port}\" 2>/dev/null || true; sudo iscsiadm -m node -T '${oci_core_volume_attachment.benchmark_data[count.index].iqn}' -p \"$${portal}:${oci_core_volume_attachment.benchmark_data[count.index].port}\" -o update -n node.startup -v automatic; sudo iscsiadm -m node -T '${oci_core_volume_attachment.benchmark_data[count.index].iqn}' -p \"$${portal}:${oci_core_volume_attachment.benchmark_data[count.index].port}\" --login 2>/dev/null || true; done",
      "sudo udevadm settle || true",
      "sudo multipath -r 2>/dev/null || true",
      "for i in $(seq 1 60); do lsblk -bprno NAME,TYPE | awk '$2==\"mpath\" || $2==\"disk\" {print $1}' | grep -q . && exit 0; sleep 2; done",
    ]
  }
}
