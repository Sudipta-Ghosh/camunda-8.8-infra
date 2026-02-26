variable "kubeconfig_path" {
  description = "Path to kubeconfig file (defaults to user's kubeconfig)."
  type        = string
  default     = "~/.kube/config"
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}
