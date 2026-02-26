variable "namespace" {
  description = "Kubernetes namespace to install Camunda into"
  type        = string
  default     = "camunda"
}

variable "chart_repository" {
  description = "Helm chart repository URL for Camunda"
  type        = string
  default     = "https://helm.camunda.io"
}

variable "chart_name" {
  description = "Chart name to install"
  type        = string
  default     = "camunda-platform"
}

variable "values_file" {
  description = "Relative path (from this module) to the Helm values YAML file"
  type        = string
  default     = "../camunda-8-infrastructure/camunda-values.yaml"
}
