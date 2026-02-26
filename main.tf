resource "null_resource" "camunda_helm_cli" {
  # Re-run when values file content changes
  triggers = {
    values_hash = filesha256("${path.module}/${var.values_file}")
  }

  provisioner "local-exec" {
    command = <<EOT
helm repo add camunda ${var.chart_repository} 2>nul || echo repository exists
helm repo update
helm upgrade --install ${var.chart_name} camunda/${var.chart_name} -n ${var.namespace} --create-namespace -f "${path.module}/${var.values_file}"
EOT
  }
}
