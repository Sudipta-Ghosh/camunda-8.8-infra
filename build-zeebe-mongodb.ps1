# Build custom Zeebe image with exporter

param(
    [string]$ImageName = "zeebe-mongodb-exporter",
    [string]$Tag = "8.8.11-demo"
)

Write-Host "Building mongodb Zeebe image: ${ImageName}:${Tag}" -ForegroundColor Cyan

# Check if Dockerfile exists
if (-not (Test-Path "Dockerfile.zeebe-mongodb")) {
    Write-Host "ERROR: Dockerfile.zeebe-mongodb not found!" -ForegroundColor Red
    exit 1
}

# Build the Docker image
Write-Host "Running docker build..." -ForegroundColor Yellow
docker build -f Dockerfile.zeebe-mongodb -t "${ImageName}:${Tag}" .

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker build failed" -ForegroundColor Red
    exit 1
}

Write-Host "Image built successfully: ${ImageName}:${Tag}" -ForegroundColor Green

# For Kind cluster, load the image
Write-Host "`nLoading image into Kind cluster..." -ForegroundColor Yellow

# Check if kind is available
$kindExists = Get-Command kind -ErrorAction SilentlyContinue
if ($null -eq $kindExists) {
    Write-Host "WARNING: 'kind' command not found in PATH" -ForegroundColor Yellow
    Write-Host "Manually load the image with: kind load docker-image ${ImageName}:${Tag}" -ForegroundColor Yellow
    Write-Host "Or add kind to your PATH and rerun this script" -ForegroundColor Yellow
} else {
    kind load docker-image "${ImageName}:${Tag}"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to load image into Kind cluster" -ForegroundColor Red
        exit 1
    }
    Write-Host "Image loaded into Kind cluster" -ForegroundColor Green
}

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Deploy Camunda: .\deploy-camunda.ps1 -ValuesFile '.\camunda-values.yaml' -AutoApprove -RecreateNamespace -ForceHelmInstall" -ForegroundColor White
Write-Host "  2. Verify exporter: kubectl exec -n camunda -it camunda-platform-zeebe-0 -- ls -la /usr/local/zeebe/exporters/" -ForegroundColor White
