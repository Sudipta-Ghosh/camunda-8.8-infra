
# Camunda 8 Infrastructure — Kind Cluster

> **Camunda 8.8.11** on a local  Kubernetes cluster .

## Table of Contents
1. [Repository Layout](#repository-layout)
2. [Prerequisites](#prerequisites)
3. [Step-by-Step Deployment](#step-by-step-deployment)
4. [Available URLs](#available-urls)


## Repository Layout
```
camunda-8-infrastructure/
├── camunda-values.yaml            # Helm values (exporter removed; archival, retention, ES tuning)
├── deploy-camunda.ps1             # One-click deploy script (Terraform + Helm)
├── build-zeebe-mongodb.ps1        # OPTIONAL: build Zeebe image with MongoDB exporter (deprecated)
├── port-forward-camunda.ps1       # Port-forward all services to localhost
├── main.tf                        # Terraform Helm release resource
├── variables.tf                   # Terraform variables
├── provider.tf                    # Kubernetes / Helm providers
├── versions.tf                    # Required provider versions
├── outputs.tf                     # Terraform outputs

```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Docker Desktop | Latest | Container runtime |
| Kind | v0.20+ | Local Kubernetes cluster |
| kubectl | v1.27+ | Kubernetes CLI |
| Helm | v3.12+ | Chart management |
| Terraform | ≥ 1.3.0 | Infrastructure-as-code (optional) |
| PowerShell | 5.1+ | Deployment scripts (Windows) |
---

## Step-by-Step Deployment
### Pre-deployment Verification

Run these quick checks before deploying to ensure your local environment is ready.

```powershell
# Docker running
docker info

# kubectl connectivity
kubectl cluster-info
kubectl get nodes -o wide

# CLI versions
helm version
kubectl version --client

# Terraform CLI
terraform version

# Ensure values file exists
Test-Path .\camunda-values.yaml


```

### Step 1 — Deploy Camunda
```powershell
.\deploy-camunda.ps1 -ValuesFile '.\camunda-values.yaml' -AutoApprove -RecreateNamespace -ForceHelmInstall
```

### Step 2 — Port-Forward Services
```powershell
.\port-forward-camunda.ps1
```

| Service | Local Port | Purpose |
|---|---|---|
| Zeebe Gateway (gRPC) | 26500 | Deploy processes, start instances |
| Zeebe Gateway (REST) | 8080 | REST API |
| Identity (auth) | 18080 | OIDC / Keycloak |
| Operate | 8081 | Process monitoring |
| Optimize | 8083 | Analytics |
| Console | 8087 | Cluster management |
| Web Modeler | 8070 | BPMN modelling |
| Connectors | 8085 | Integration connectors |
| Elasticsearch | 9200 | ES REST API (diagnostics) |

---

## Available URLs

Once port-forwarding is active, access the UIs in your browser:

| Component | URL | Description |
|---|---|---|
| Zeebe Gateway (gRPC) | http://localhost:26500 | Process deployment and execution |
| Zeebe Gateway (HTTP) | http://localhost:8080/ | Zeebe REST API |
| Operate | http://localhost:8080/operate | Monitor process instances |
| Tasklist | http://localhost:8080/tasklist | Complete user tasks |
| Web Modeler | http://localhost:8070 | Design and deploy processes |
| Console | http://localhost:8087 | Manage clusters and APIs |
| Identity | http://localhost:8088/identity | User and permission management for the orchestration cluster |
| Management Identity | http://localhost:18081 | User and permission management |
| Keycloak | http://localhost:18080 | Authentication server |
| Optimize | http://localhost:8083 | Process analytics |
| Connectors | http://localhost:8085 | External system integrations in table format |


---

## Post-deployment Verification

After deployment and port-forwarding, verify pods and retrieve the initial identity user password:

```powershell
kubectl -n camunda get pods
kubectl get secret camunda-credentials -n camunda -o jsonpath='{.data.identity-firstuser-password}' | base64 -d
```


