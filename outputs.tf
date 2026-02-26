output "release_name" {
  description = "Helm release name (chart name used for install)"
  value       = var.chart_name
}

output "namespace" {
  description = "Kubernetes namespace where Camunda was installed"
  value       = var.namespace
}

output "helm_cli_install_trigger" {
  description = "Trigger value (sha256 of values file) used to detect changes for CLI install"
  value       = null_resource.camunda_helm_cli.triggers.values_hash
  depends_on  = [null_resource.camunda_helm_cli]
}
