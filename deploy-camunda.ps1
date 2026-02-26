param(
    [string] $KubeconfigPath = "$env:USERPROFILE\.kube\config",
    [string] $ValuesFile = "",
    [string] $Namespace = "camunda",
    [switch] $AutoApprove,
    [switch] $RecreateNamespace,
    [switch] $ForceTerraformReplace,
    [switch] $ForceHelmInstall
)

function Fail([string]$msg) {
    Write-Error $msg
    exit 1
}

Write-Host "Script directory: $PSScriptRoot"
Set-Location -Path $PSScriptRoot

# Basic checks
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Fail 'Terraform CLI not found in PATH.'
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Fail 'kubectl not found in PATH.'
}

# Set kubeconfig if present
if (Test-Path $KubeconfigPath) {
    $env:KUBECONFIG = (Resolve-Path $KubeconfigPath).Path
    Write-Host "Using kubeconfig: $env:KUBECONFIG"
} else {
    Write-Warning "Kubeconfig not found at $KubeconfigPath. Using default kubeconfig discovery."
}

try { kubectl config current-context } catch { Write-Warning "Unable to read kubectl context." }

# Optionally delete namespace
if ($RecreateNamespace) {
    Write-Host "RecreateNamespace requested: checking for existing namespace '$Namespace'..."
    $nsName = kubectl get namespace $Namespace -o name --ignore-not-found
    if ($nsName) {
        Write-Host "Namespace exists. Deleting $Namespace..."
        kubectl delete namespace $Namespace --wait --timeout=120s
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Namespace delete returned non-zero. Continuing."
        } else {
            Write-Host "Waiting for namespace to be removed..."
            $start = Get-Date
            while ((kubectl get namespace $Namespace -o name --ignore-not-found) -and ((Get-Date) - $start).TotalSeconds -lt 180) {
                Start-Sleep -Seconds 3
            }
        }
    } else {
        Write-Host "Namespace '$Namespace' not present."
    }
}

# Resolve values file (if provided) and compute module-relative path for Terraform
$relative = ''
if ($ValuesFile -ne '') {
    $resolved = Resolve-Path $ValuesFile -ErrorAction SilentlyContinue
    if (-not $resolved) {
        $resolved = Resolve-Path (Join-Path $PSScriptRoot $ValuesFile) -ErrorAction SilentlyContinue
    }
    if (-not $resolved) { Fail "Values file not found: $ValuesFile" }

    $modulePath = (Resolve-Path $PSScriptRoot).Path
    $moduleUri = New-Object System.Uri($modulePath + '\')
    $fileUri = New-Object System.Uri($resolved.Path)
    $relative = $moduleUri.MakeRelativeUri($fileUri).ToString().Replace('/','\\')
    Write-Host "Resolved values file to: $($resolved.Path) -> module-relative: $relative"
}

# Terraform init
Write-Host "Running: terraform init"
terraform init
if ($LASTEXITCODE -ne 0) { Fail 'terraform init failed.' }

# Terraform plan
$planArgs = @('plan','-out=tfplan')
if ($relative -ne '') {
    $planArgs += '-var'
    $planArgs += "values_file=$relative"
}

Write-Host "Running: terraform $($planArgs -join ' ')"
terraform @planArgs
if ($LASTEXITCODE -ne 0) { Fail 'terraform plan failed.' }

# Terraform apply (optionally force replace of null_resource)
if ($ForceTerraformReplace) {
    Write-Host "Applying with -replace for null_resource.camunda_helm_cli"
    if ($AutoApprove) {
        terraform apply -replace="null_resource.camunda_helm_cli" -auto-approve
    } else {
        terraform apply -replace="null_resource.camunda_helm_cli"
    }
} else {
    if ($AutoApprove) {
        terraform apply -auto-approve tfplan
    } else {
        terraform apply tfplan
    }
}
if ($LASTEXITCODE -ne 0) { Fail 'terraform apply failed.' }

# Check pods
Write-Host "Checking pods in namespace '$Namespace'..."
$pods = kubectl get pods -n $Namespace --no-headers --ignore-not-found 2>$null | Out-String

# If no pods or forced, run Helm CLI
if ($ForceHelmInstall -or -not $pods.Trim()) {
    Write-Host "Running Helm CLI install/upgrade..."
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { Fail 'Helm CLI not found in PATH.' }

    # Determine values path for helm (absolute)
    if ($relative -ne '') {
        $valuesPath = Join-Path $PSScriptRoot $relative
    } else {
        $valuesPath = Join-Path $PSScriptRoot 'camunda-values.yaml'
    }

    $useValues = Test-Path $valuesPath
    $releaseName = 'camunda-platform'

    helm repo add camunda https://helm.camunda.io 2>$null | Out-Null
    helm repo update

    if ($useValues) {
        $args = @('upgrade','--install',$releaseName,'camunda/camunda-platform','-n',$Namespace,'--create-namespace','-f',$valuesPath)
    } else {
        $args = @('upgrade','--install',$releaseName,'camunda/camunda-platform','-n',$Namespace,'--create-namespace')
    }

    Write-Host "Running: helm $($args -join ' ')"
    $proc = Start-Process -FilePath helm -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Fail 'Helm CLI install failed.' }

    Write-Host "Waiting for pods (timeout 10m)..."
    try {
        kubectl wait --for=condition=Ready pod --all -n $Namespace --timeout=10m
    } catch {
        Write-Warning "kubectl wait returned non-zero or timed out after Helm CLI run."
    }
}

Write-Host "Pods in namespace '$Namespace':"
kubectl get pods -n $Namespace
Write-Host "Services in namespace '$Namespace':"
kubectl get svc -n $Namespace

Write-Host "Deployment finished."
