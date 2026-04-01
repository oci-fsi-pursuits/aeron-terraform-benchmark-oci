# Optional: pull terraform-matrix-summary.json from controller so terraform outputs can show median latencies.
resource "null_resource" "benchmark_matrix_summary_pull" {
  count = var.install_aeron && var.run_benchmarks && var.pull_matrix_summary_for_terraform_output ? 1 : 0

  depends_on = [null_resource.run_driver_matrix[0]]

  triggers = {
    matrix_id = null_resource.run_driver_matrix[0].id
  }

  provisioner "local-exec" {
    # Avoid embedding path.module in quoted command on Windows (backslashes + \" break the path).
    working_dir = path.module
    environment = {
      TF_SSH_KEY                = tls_private_key.ssh.private_key_pem
      TF_MATRIX_CONTROLLER_HOST = local.controller_host
      TF_MATRIX_SSH_USER        = var.ssh_username
      TF_MATRIX_OUT             = abspath("${path.module}/.terraform-matrix-summary.json")
    }
    command = "python scripts/matrix_summary_pull.py"
  }
}
