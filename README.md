
# Camunda 8 Infrastructure — Kind Cluster

> **Camunda 8.8.11** on a local **Kind** Kubernetes cluster with a full **Elasticsearch archival / retention / deletion** pipeline.
> The MongoDB exporter has been removed from the default configuration; exporter-related build artifacts are optional.

---

## Note: MongoDB exporter removed

- **What changed:** The MongoDB exporter configuration and the related `ZEEBE_BROKER_EXPORTERS_MONGODB_*` environment variables were removed from `camunda-values.yaml`.
- **When:** 2026-02-26
- **Why:** Removed per recent configuration change; the Elasticsearch exporter and archival/retention pipeline remain active.
- **To re-enable:** Re-add the exporter block and env vars to [camunda-values.yaml](camunda-values.yaml) and ensure the exporter JAR/image is available.

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Data Flow — Sequence](#data-flow--sequence)
3. [Repository Layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Step-by-Step Deployment](#step-by-step-deployment)
6. [Timeline — Archival & Deletion (Authoritative)](#timeline--archival--deletion-authoritative)
7. [Elasticsearch Archival, Retention & Deletion](#elasticsearch-archival-retention--deletion)
8. [End-to-End Verification](#end-to-end-verification)
9. [Common Issues & Fixes](#common-issues--fixes)
10. [Rollbacks and Cleanup](#rollbacks-and-cleanup)

---

## Architecture Overview
```
┌──────────────────────────────────────────────────────────────────────────────┐
│                             Kind Kubernetes Cluster                          │
│                           Namespace: camunda                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ camunda-platform-zeebe-0 (Unified Orchestration Pod)                   │  │
│  │  Profiles: broker, identity, operate, tasklist, consolidated-auth      │  │
│  │                                                                        │  │
│  │  ┌──────────────┐   ┌───────────────────────┐                         │  │
│  │  │ Zeebe Broker │   │ CamundaExporter       │                         │  │
│  │  │ + Gateway    │   │ (built-in → ES + ILM) │                         │  │
│  │  └─────┬────────┘   └───────────┬──────────┘                         │  │
│  │        │                        │                                     │  │
│  │        │                        │                                     │  │
│  │        ▼                        ▼                                     │  │
│  │  Elasticsearch (runtime + archives)                                     │  │
│  │                                                                        │  │
│  │  Operate module (webapp+archiver), Tasklist module                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Elasticsearch master (9200)  ◄── Archival + ILM retention policies          │
│                                                                              │
│  Identity + Keycloak (OIDC), Optimize, Connectors, Console, Web Modeler      │
└──────────────────────────────────────────────────────────────────────────────┘

             ▼
           Elasticsearch (external / managed)
```

---

## Data Flow — Sequence
```
Client → Zeebe Broker → (1) emit records → CamundaExporter → Elasticsearch

On PROCESS completion:
- Variables are accumulated per processInstanceKey.
- A rich document is built on ELEMENT_COMPLETED (PROCESS) and forwarded to the archival pipeline (Elasticsearch indices and ILM policies).
```

---

## Repository Layout
```
camunda-8-infrastructure/
├── camunda-values.yaml            # Helm values (exporter removed; archival, retention, ES tuning)
├── deploy-camunda.ps1             # One-click deploy script (Terraform + Helm)
├── build-zeebe-mongodb.ps1        # OPTIONAL: build Zeebe image with MongoDB exporter (deprecated)
├── port-forward-camunda.ps1       # Port-forward all services to localhost
├── Dockerfile.zeebe-mongodb       # OPTIONAL: Dockerfile including MongoDB exporter JAR (deprecated)
├── Dockerfile.zeebe-mongodb-local # OPTIONAL: Local build variant (deprecated)
├── test-archiving.ps1             # Script to test archival/retention pipeline
├── test-archiving-api.ps1         # API-level archival test script
├── main.tf                        # Terraform Helm release resource
├── variables.tf                   # Terraform variables
├── provider.tf                    # Kubernetes / Helm providers
├── versions.tf                    # Required provider versions
├── outputs.tf                     # Terraform outputs
└── diagrams/                      # PlantUML diagrams (architecture + sequence)
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
| Java | 21 | Optional — only needed to build the MongoDB exporter from source |
| Maven | 3.9+ | Optional — only needed to build the MongoDB exporter from source |

---

## Step-by-Step Deployment

### Step 1 — Build the Custom Zeebe Image
```powershell
# From the camunda-8-infrastructure directory
.\build-zeebe-mongodb.ps1 -ImageName "zeebe-mongodb-exporter" -Tag "8.8.11-mongodb-v2"
```

### Step 2 — Deploy Camunda
```powershell
.\deploy-camunda.ps1 -ValuesFile '.\camunda-values.yaml' -AutoApprove -RecreateNamespace -ForceHelmInstall
```

### Step 3 — Port-Forward Services
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


