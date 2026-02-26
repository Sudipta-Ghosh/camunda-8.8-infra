# Test Archiving and Retention
# This script monitors the archiving lifecycle

Write-Host "`n=== Camunda Archiving Test ===" -ForegroundColor Cyan
Write-Host "Config: Archive after 30s | Delete after 3m | Check every 1m`n" -ForegroundColor Yellow

# Step 1: Check current Elasticsearch indices
Write-Host "[Step 1] Current Elasticsearch indices:" -ForegroundColor Green
try {
    $indices = curl -s http://localhost:9200/_cat/indices?v 2>$null | Select-String "operate"
    if ($indices) {
        $indices
    } else {
        Write-Host "Note: Elasticsearch port-forward may not be running. Run: kubectl port-forward -n camunda svc/camunda-platform-elasticsearch 9200:9200" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Cannot connect to Elasticsearch. Make sure port-forwarding is active." -ForegroundColor Red
}

Write-Host "`n[Step 2] Deploy and complete a test process:" -ForegroundColor Green
Write-Host "  1. Open Modeler: http://localhost:8070" -ForegroundColor White
Write-Host "  2. Create simple BPMN (Start -> End)" -ForegroundColor White
Write-Host "  3. Deploy the process" -ForegroundColor White
Write-Host "  4. Start an instance from Operate: http://localhost:8080" -ForegroundColor White
Write-Host "`nPress Enter after completing the process instance..." -ForegroundColor Cyan
Read-Host

$startTime = Get-Date
Write-Host "`n[Step 3] Monitoring archiving cycle (started at $($startTime.ToString('HH:mm:ss')))" -ForegroundColor Green
Write-Host "Timeline:" -ForegroundColor Yellow
Write-Host "  T+30s  : Archiving should occur" -ForegroundColor White
Write-Host "  T+1m   : First retention check" -ForegroundColor White
Write-Host "  T+2m   : Second retention check" -ForegroundColor White
Write-Host "  T+3m+  : Deletion should occur" -ForegroundColor White

# Monitor for 6 minutes (enough to see archiving + deletion)
$duration = 6
$checkInterval = 20

for ($i = 1; $i -le ($duration * 60 / $checkInterval); $i++) {
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
    Write-Host "`n--- Check $i (Elapsed: ${elapsed}s / $(Get-Date -Format 'HH:mm:ss')) ---" -ForegroundColor Cyan
    
    # Check archiver logs
    Write-Host "Archiver activity (last 20 lines):" -ForegroundColor Yellow
    $archiverLogs = kubectl logs camunda-platform-zeebe-0 -n camunda --tail=50 --since=30s 2>$null | 
        Select-String "archiv|retention|Archiving process|Moving documents" -CaseSensitive:$false | 
        Select-Object -Last 5
    
    if ($archiverLogs) {
        $archiverLogs | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } else {
        Write-Host "  (No archiver activity in last 30s)" -ForegroundColor DarkGray
    }
    
    # Check Elasticsearch indices
    Write-Host "`nElasticsearch indices:" -ForegroundColor Yellow
    try {
        $esIndices = curl -s http://localhost:9200/_cat/indices?v 2>$null | 
            Select-String "operate-process-instance" |
            ForEach-Object { $_ -replace '\s+', ' ' }
        
        if ($esIndices) {
            $esIndices | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else {
            Write-Host "  (Elasticsearch not accessible via localhost:9200)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  (Cannot query Elasticsearch)" -ForegroundColor DarkGray
    }
    
    if ($i -lt ($duration * 60 / $checkInterval)) {
        Write-Host "`nWaiting ${checkInterval}s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $checkInterval
    }
}

Write-Host "`n=== Test Complete ===" -ForegroundColor Cyan
Write-Host "Check the logs above for:" -ForegroundColor Yellow
Write-Host "  - 'Archiving process instances' around 30s mark" -ForegroundColor White
Write-Host "  - 'Moving documents' or 'archived' messages" -ForegroundColor White
Write-Host "  - 'retention' or 'Deleting' messages after 3+ minutes" -ForegroundColor White
Write-Host "  - Elasticsearch index changes (archived indices created/deleted)" -ForegroundColor White
