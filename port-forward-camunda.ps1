<#
Portable helper to start/stop a set of kubectl port-forwards for Camunda services.

Features:
- Start port-forward sessions in separate PowerShell windows with descriptive titles.
- Auto-detects service names from a candidate list (handles both `camunda-platform-*` and shorter names).
- Stop any running `kubectl port-forward` processes started previously.

<#
Portable helper to start/stop a set of kubectl port-forwards for Camunda services.

Features:
- Start port-forward sessions in separate PowerShell windows with descriptive titles.
- Auto-detects service names from a candidate list (handles both `camunda-platform-*` and shorter names).
- Stop any running `kubectl port-forward` processes started previously.

Usage:
  Start (default):
    .\port-forward-camunda.ps1

  Stop running port-forwards:
    .\port-forward-camunda.ps1 -Action stop

  Override namespace or specific service names:
    .\port-forward-camunda.ps1 -Namespace camunda -KeycloakSvc camunda-platform-keycloak
#>

param(
    [ValidateSet('start','stop')]
    [string]$Action = 'start',
    [string]$Namespace = 'camunda'
)

function Stop-PortForwards {
    $pf = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'kubectl port-forward' }
    if (-not $pf) { Write-Host 'No kubectl port-forward processes found.'; return }
    foreach ($p in $pf) {
        Write-Host "Stopping PID $($p.ProcessId): $($p.CommandLine)"
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host 'Stopped.' }
        catch { Write-Warning "Failed to stop PID $($p.ProcessId): $_" }
    }
}

function Find-Service([string[]]$candidates) {
    foreach ($name in $candidates) {
        $exists = kubectl -n $Namespace get svc $name -o jsonpath='{.metadata.name}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exists) { return $name }
    }
    return $null
}

# Collect tab commands and launch them in a single Windows Terminal window (wt.exe).
# If wt.exe is not available, fall back to opening separate PowerShell windows.
$script:tabCommands = @()

# Prepare log directory for per-tab logs
$logDir = Join-Path $PSScriptRoot 'port-forward-logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

function Add-Tab([string]$title, [string]$command) {
    $safe = ($title -replace '[^a-zA-Z0-9\-_.]','_')
    $logPath = Join-Path $logDir ("$safe.log")
    # Create a helper script file and invoke it with -File to avoid nested quoting issues
    $scriptPath = Join-Path $logDir ("$safe.ps1")
    $scriptContent = @()
    $scriptContent += "[Console]::Title='$title'"
    $scriptContent += "try { & { $command 2>&1 | Tee-Object -FilePath '$logPath' } } catch { \$_ | Out-File -FilePath '$logPath' -Append }"
    $scriptContent -join "`n" | Out-File -FilePath $scriptPath -Encoding UTF8
    $script:tabCommands += 'new-tab powershell -NoExit -File "' + $scriptPath + '"'
}

function Launch-TabsOrWindows {
    if ($tabCommands.Count -eq 0) { return }
    $wtCmd = $tabCommands -join ' ; '
    Write-Host 'Launching wt.exe with arguments:' -ForegroundColor Cyan
    Write-Host $wtCmd
    try {
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtCmd -ErrorAction Stop
        Write-Host 'Opened tabs in Windows Terminal (wt.exe).' -ForegroundColor Green
    }
    catch {
        Write-Warning 'Windows Terminal (wt.exe) not found or failed to start. Falling back to separate PowerShell windows.'
        foreach ($t in $tabCommands) {
            # each $t looks like: new-tab powershell -NoExit -Command "[Console]::Title='Title'; cmd"
            # Extract the -Command ... portion to run in a powershell.exe window
            if ($t -match '-Command \"(?<cmd>.*)\"$') {
                $cmd = $Matches['cmd']
                Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit','-Command',$cmd
            }
        }
    }
}

if ($Action -eq 'stop') {
    Stop-PortForwards
    return
}

# Candidate names (tries the platform-prefixed name first, then a shorter name)
$svcCandidates = @{
    Keycloak = @('camunda-platform-keycloak','camunda-keycloak')
    Identity = @('camunda-platform-identity','camunda-identity')
    Optimize = @('camunda-platform-optimize','camunda-optimize')
    WebModeler = @('camunda-platform-web-modeler-webapp','camunda-web-modeler-webapp')
    Console = @('camunda-platform-console','camunda-console')
    Zeebe = @('camunda-platform-zeebe-gateway','camunda-zeebe-gateway')
    Connectors = @('camunda-platform-connectors','camunda-connectors')
}

# Resolve services to actual existing names
$svc = @{}
foreach ($k in $svcCandidates.Keys) {
    $found = Find-Service -candidates $svcCandidates[$k]
    if ($found) { $svc[$k] = $found } else { Write-Warning "No service found for $k (checked: $($svcCandidates[$k] -join ', '))" }
}

Write-Host 'Resolved services:' -ForegroundColor Cyan
if ($svc.Count -eq 0) { Write-Host '<none>' } else { $svc.GetEnumerator() | ForEach-Object { Write-Host " - $($_.Name) => $($_.Value)" } }

# Build commands only for found services
if ($svc.ContainsKey('Keycloak')) { Add-Tab 'Keycloak (auth)' "kubectl -n $Namespace port-forward svc/$($svc['Keycloak']) 18080:80" }
if ($svc.ContainsKey('Identity')) { Add-Tab 'Identity (auth)' "kubectl -n $Namespace port-forward svc/$($svc['Identity']) 18081:80" }
if ($svc.ContainsKey('Optimize')) { Add-Tab 'Optimize (web)' "kubectl -n $Namespace port-forward svc/$($svc['Optimize']) 8083:80" }
if ($svc.ContainsKey('WebModeler')) { Add-Tab 'Web Modeler (web)' "kubectl -n $Namespace port-forward svc/$($svc['WebModeler']) 8070:80" }
if ($svc.ContainsKey('Console')) { Add-Tab 'Console (web)' "kubectl -n $Namespace port-forward svc/$($svc['Console']) 8087:80" }
if ($svc.ContainsKey('Zeebe')) { Add-Tab 'Zeebe Gateway (26500)' "kubectl -n $Namespace port-forward svc/$($svc['Zeebe']) 26500:26500"; Add-Tab 'Zeebe Gateway (8080)' "kubectl -n $Namespace port-forward svc/$($svc['Zeebe']) 8080:8080" }
if ($svc.ContainsKey('Connectors')) { Add-Tab 'Connectors' "kubectl -n $Namespace port-forward svc/$($svc['Connectors']) 8085:8080" }

# Explicit Elasticsearch master pod forward (local 9200 -> pod 9200)
$esPod = 'camunda-platform-elasticsearch-master-0'
$esExists = kubectl -n $Namespace get pod $esPod -o jsonpath='{.metadata.name}' 2>$null
if ($LASTEXITCODE -eq 0 -and $esExists) {
    Add-Tab 'Elasticsearch (master)' "kubectl -n $Namespace port-forward pod/$esPod 9200:9200"
} else {
    Write-Warning "Elasticsearch pod '$esPod' not found in namespace '$Namespace'. Skipping port-forward."
}

# Launch all tabs (or fall back to windows)
Write-Host "Prepared $($script:tabCommands.Count) tab command(s)." -ForegroundColor Yellow
if ($script:tabCommands.Count -eq 0) { Write-Warning 'No tab commands prepared; nothing to launch.' }
Launch-TabsOrWindows

Write-Host 'Port-forward windows started (or warnings shown for missing services).' -ForegroundColor Green


