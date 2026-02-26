
# Camunda 8 Infrastructure — Kind Cluster with MongoDB Exporter

> **Camunda 8.8.11** on a local **Kind** Kubernetes cluster with a custom **MongoDB Exporter** and full **Elasticsearch archival / retention / deletion** pipeline.

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Data Flow — Sequence](#data-flow--sequence)
3. [Repository Layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Step-by-Step Deployment](#step-by-step-deployment)
6. [MongoDB Exporter — How It Works](#mongodb-exporter--how-it-works)
7. [Timeline — Archival & Deletion (Authoritative)](#timeline--archival--deletion-authoritative)
8. [Elasticsearch Archival, Retention & Deletion](#elasticsearch-archival-retention--deletion)
9. [End-to-End Verification](#end-to-end-verification)
10. [Common Issues & Fixes](#common-issues--fixes)
11. [Rollbacks and Cleanup](#rollbacks-and-cleanup)

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
│  │  MongoDB Exporter (custom JAR)  Elasticsearch (runtime + archives)     │  │
│  │                                                                        │  │
│  │  Operate module (webapp+archiver), Tasklist module                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Elasticsearch master (9200)  ◄── Archival + ILM retention policies          │
│                                                                              │
│  Identity + Keycloak (OIDC), Optimize, Connectors, Console, Web Modeler      │
└──────────────────────────────────────────────────────────────────────────────┘

           ▼
       MongoDB Atlas (Cloud)
       Database: camunda_zeebe
       Collection: zeebe_records_* (completed process instances)
```

---

## Data Flow — Sequence
```
Client → Zeebe Broker → (1) emit records → CamundaExporter → Elasticsearch
                         (2) same stream → MongoDB Exporter → MongoDB Atlas

On PROCESS completion:
- Variables are accumulated per processInstanceKey.
- A rich document is built on ELEMENT_COMPLETED (PROCESS) and upserted to MongoDB in batches.
- In ES, completed runtime docs become eligible for archival; rollover creates date-suffixed indices; ILM deletes them after minimumAge.
```

---

## Repository Layout
```
camunda-8-infrastructure/
├── camunda-values.yaml            # Helm values (MongoDB exporter, archival, retention, ES tuning)
├── deploy-camunda.ps1             # One-click deploy script (Terraform + Helm)
├── build-zeebe-mongodb.ps1        # Build custom Zeebe Docker image with MongoDB exporter JAR
├── port-forward-camunda.ps1       # Port-forward all services to localhost
├── Dockerfile.zeebe-mongodb       # Dockerfile: camunda/camunda:8.8.11 + MongoDB exporter JAR
├── Dockerfile.zeebe-mongodb-local # Local build variant
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
| Java | 21 | Build MongoDB exporter (if building from source) |
| Maven | 3.9+ | Build MongoDB exporter (if building from source) |

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

## MongoDB Exporter — How It Works
- Accepts **all** record types (required to advance the Zeebe export position).
- **Writes** to MongoDB only when the top-level `PROCESS` element receives `ELEMENT_COMPLETED`.
- Accumulates variables in memory keyed by `processInstanceKey`.
- Uses batch `BulkWrite` with `ReplaceOneModel(..., upsert: true)` — idempotent and duplicate-safe.

**Document example (simplified):**
```json
{
  "processInstanceKey": 2251799813685270,
  "bpmnProcessId": "order-process",
  "processVersion": 1,
  "processDefinitionKey": 2251799813685255,
  "state": "COMPLETED",
  "startTime": "2026-02-17T10:30:00.000Z",
  "endTime": "2026-02-17T10:30:45.678Z",
  "durationMs": 45678,
  "partitionId": 1,
  "tenantId": "<default>",
  "variables": {
    "orderId": "ORD-12345",
    "amount": 99.99,
    "approved": true
  }
}
```

**Key env vars (set via `orchestration.env` in `camunda-values.yaml`):**
- `ZEEBE_BROKER_EXPORTERS_MONGODB_CLASSNAME = io.github.camunda8.mongodb.exporter.MongoDBExporter`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_JARPATH = /usr/local/zeebe/exporters/camunda8-mongodb-exporter-1.0-SNAPSHOT.jar`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_ARGS_CONNECTIONURI = <your MongoDB connection string>`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_ARGS_DATABASE = camunda_zeebe`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_ARGS_COLLECTION = zeebe_records`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_ARGS_BATCHSIZE = 100`
- `ZEEBE_BROKER_EXPORTERS_MONGODB_ARGS_FLUSHINTERVAL = 1000`

---

## Timeline — Archival & Deletion (Authoritative)

> Values reflect your `camunda-values.yaml`: `waitPeriodBeforeArchiving=5m`, `rolloverInterval=1h`, history `minimumAge=5m`, zeebe-records `minimumAge=3m`, ES ILM poll `10s`, MongoDB flush `1000ms` / `batchSize=100`.

| **Time from process completion** | **Action** | **Affected indices / store** | **Who/Where** | **Config key(s)** | **Effective value(s)** | **Notes** |
|---|---|---|---|---|---|---|
| **T + 0s** | Process instance **completes**; Zeebe appends ordered records and exporters consume the stream | Zeebe log | Zeebe Broker + Exporters | — | — | Triggers both ES and MongoDB paths.
| **T + ~1s** | Batch **flush to MongoDB** of completed instance document (upsert) | `camunda_zeebe.zeebe_records…` (MongoDB) | MongoDB Exporter | `…MONGODB_ARGS_BATCHSIZE`, `…MONGODB_ARGS_FLUSHINTERVAL` | `100`, `1000ms` | Flushes on size or timer; writes only on process **COMPLETE**.
| **T + 5m** | **Eligible for archival** after wait period | Live runtime indices like `operate-*`, `tasklist-*` | CamundaExporter / Archiver | `orchestration.history.waitPeriodBeforeArchiving` | `5m` | Eligibility window opens; rollover waits for next tick.
| **T + 5m → T + 65m** | **Rollover / Archival** runs on **next tick**; data moved to **date‑suffixed** archived indices | `operate-*-<date>`, `tasklist-*-<date>` | CamundaExporter / Archiver | `orchestration.history.rolloverInterval`, `…elsRolloverDateFormat` | `1h`, `date` | With 1h interval, rollover may occur immediately after eligibility or up to ~1h later.
| **Immediately after rollover + every ~10s** | **ILM policy attached & evaluated** frequently | Archived indices (`operate-*_<date>`, `tasklist-*_<date>`) | Elasticsearch ILM | `orchestration.history.retention.policyName`, ES `indices.lifecycle.poll_interval` | `camunda-history-retention-policy`, `10s` | Fast ILM polling accelerates delete-phase evaluation.
| **When archived index age ≥ 5m (plus ILM check)** | **Archived index deletion** (history) | Archived `operate-*_<date>`, `tasklist-*_<date>` | Elasticsearch ILM | `orchestration.history.retention.minimumAge` | `5m` | Delete follows the next ILM poll; shard-history lease may add short delay.
| **T + 3m** | **Zeebe record indices deletion** (runtime logs) | `zeebe-record-*` | Elasticsearch ILM | `orchestration.retention.minimumAge`, `…policyName` | `3m`, `zeebe-record-retention-policy` | Applies only if ES exporter is enabled (true in this setup).
| **As generated** | **Usage metrics retention** (long) | `camunda-usage-metrics-*` | Elasticsearch ILM | `orchestration.history.retention.usageMetricsMinimumAge`, `…usageMetricsPolicyName` | `730d`, `camunda-usage-metrics-retention-policy` | Metrics retained for ~2 years (demo default).

**At a glance:** Earliest history deletion ≈ `rollover_time + 5m`. With `rolloverInterval=1h`, wall‑clock is **T+5m to T+65m for rollover**, then **+5m** for delete.

---

## Elasticsearch Archival, Retention & Deletion

### Archival (Rollover) Phase
- `waitPeriodBeforeArchiving` = **5m** — time after completion before archival eligibility.
- `rolloverInterval` = **1h** — frequency of rollover cycles.
- Affected indices: `operate-list-view-*`, `operate-variable-*`, `operate-flownode-instance-*`, `operate-sequence-flow-*`, `tasklist-task-*`.
- Archived indices are date-suffixed per `elsRolloverDateFormat` (set to `date`).

### Retention (ILM Delete) Phase
- History policy: `camunda-history-retention-policy`, `minimumAge=5m` (Helm value).
- Zeebe runtime policy: `zeebe-record-retention-policy`, `minimumAge=3m`.
- Usage metrics policy: `camunda-usage-metrics-retention-policy`, `minimumAge=730d`.
- ILM evaluation tuned via `indices.lifecycle.poll_interval=10s` for fast demo cycles.

### Elasticsearch Tuning (for fast delete in demos)
- `indices.lifecycle.poll_interval: 10s` (already configured in values).
- Optionally reduce `index.soft_deletes.retention_lease.period` per-index if immediate deletion is required for testing (use sparingly; defaults are appropriate for production).

### Duration Format Rules (Critical)
- Short-form for `waitPeriodBeforeArchiving`, `minimumAge`, `rolloverInterval`: examples `30s`, `3m`, `2h`, `1d`.
- ISO‑8601 is used only where explicitly required (e.g., `applyPolicyJobInterval = PT2M`).

---

## End-to-End Verification
1. Check pods: `kubectl -n camunda get pods` (all Ready).
2. Verify MongoDB exporter logs: `kubectl -n camunda logs camunda-platform-zeebe-0 | Select-String "MongoDBExporter"`.
3. Verify archival config in logs: `Select-String "CamundaExporter|archiv|retention|rollover"`.
4. Deploy a BPMN, run instances, complete them.
5. Check ES indices: `/_cat/indices?v&s=index` and look for date-suffixed `*_YYYY-MM-DD`.
6. Check ILM policy: `/_ilm/policy/camunda-history-retention-policy` and `/_ilm/explain` on an archived index.
7. Verify deletion after `minimumAge` + shard lease period.
8. Verify Mongo data in Atlas: `db.zeebe_records_completed_process_instances.find().sort({ endTime: -1 }).limit(5)`.

---

## Common Issues & Fixes
- **Duration format error** at broker startup → use short form like `3m`; reserve ISO‑8601 for specific fields.
- **Archived indices not deleting** → lower `index.soft_deletes.retention_lease.period` (for tests) or wait for ILM.
- **ILM policy not found** → it’s created during rollover; wait for the rollover cycle to run once.
- **Elasticsearch OOMKilled** → ensure heap via `ELASTICSEARCH_HEAP_SIZE` is < container memory.
- **MongoDB exporter not writing** → check JAR path, exporter logs, and Atlas network access.

---

## Rollbacks and Cleanup
```powershell
# Uninstall the Helm release
helm uninstall camunda-platform -n camunda

# Delete the namespace
kubectl delete namespace camunda

# Remove the custom Docker image
docker rmi zeebe-mongodb-exporter:8.8.11-mongodb-v2
```
