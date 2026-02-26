#!/usr/bin/env pwsh
<#
Simple, robust test script for Elasticsearch archiving/retention (Camunda).
Supports: CheckConfig, ListIndices, CheckILM, UpdateRetention, SpeedUpPolling,
ResetPolling, ApplyFastSettings, ForceDelete.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CheckConfig','ListIndices','CheckILM','UpdateRetention','ForceDelete','SpeedUpPolling','ResetPolling','ApplyFastSettings')]
    [string]$Action,

    [string]$MinAge = '1m',
    [string]$ElasticsearchUrl = 'http://localhost:9200'
)

$ErrorActionPreference = 'Stop'

function Write-Header([string]$text){
    Write-Host "`n================ $text =================" -ForegroundColor Cyan
}

function Invoke-ESRequest {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [string]$Body = $null
    )

    $uri = "$ElasticsearchUrl$Path"
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -ContentType 'application/json' -Body $Body
        } else {
            return Invoke-RestMethod -Method $Method -Uri $uri
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $b = $r.ReadToEnd()
                Write-Host "HTTP response body:" -ForegroundColor Yellow
                Write-Host $b -ForegroundColor DarkGray
            } catch {
                # ignore
            }
        }
        throw
    }
}

function Action-CheckConfig {
    Write-Header 'Cluster settings and ILM policy'
    try {
        $cluster = Invoke-ESRequest -Path '/_cluster/settings?include_defaults=true&flat_settings=true'
        $poll = $cluster.defaults.'indices.lifecycle.poll_interval'
        Write-Host "ILM poll interval (defaults): $poll"
    } catch {
        Write-Host 'Failed reading cluster settings' -ForegroundColor Yellow
    }

    try {
        $policy = Invoke-ESRequest -Path '/_ilm/policy/camunda-retention-policy'
        Write-Host "Policy exists: yes" -ForegroundColor Green
        Write-Host ($policy | ConvertTo-Json -Depth 4)
    } catch {
        Write-Host 'Policy not present (will be created on rollout).' -ForegroundColor Yellow
    }
}

function Action-ListIndices {
    Write-Header 'Camunda indices (operate/tasklist)'
    try {
        $out = Invoke-ESRequest -Path '/_cat/indices/operate-*,tasklist-*?v&s=index&h=index,docs.count,store.size,health'
        Write-Host $out
    } catch {
        Write-Host 'Failed listing indices' -ForegroundColor Red
    }
}

function Action-CheckILM {
    Write-Header 'ILM explain for archived indices'
    try {
        $indices = Invoke-ESRequest -Path '/_cat/indices/*_*?h=index' -ErrorAction SilentlyContinue
        if (-not $indices) { Write-Host 'No indices'; return }
        $names = $indices -split "`n" | Where-Object { $_ -match '_\d{4}-\d{2}-\d{2}' -and $_ -match '^(operate|tasklist)' } | ForEach-Object { $_.Trim() }
        if (-not $names) { Write-Host 'No archived operate/tasklist indices'; return }
        foreach ($n in $names) {
            try {
                $ex = Invoke-ESRequest -Path "/$n/_ilm/explain"
                Write-Host "Index: $n" -ForegroundColor Cyan
                Write-Host ($ex.indices.$n | ConvertTo-Json -Depth 5)
            } catch {
                Write-Host "Failed explain for $n" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host 'Failed to retrieve indices' -ForegroundColor Red
    }
}

function Action-UpdateRetention {
    Write-Header "Update ILM policy min_age -> $MinAge"
    $body = @{ policy = @{ phases = @{ delete = @{ min_age = $MinAge; actions = @{ delete = @{ } } } } } } | ConvertTo-Json -Depth 10
    Write-Host 'Request JSON:' -ForegroundColor Gray
    Write-Host $body -ForegroundColor DarkGray
    try {
        $res = Invoke-ESRequest -Method PUT -Path '/_ilm/policy/camunda-retention-policy' -Body $body
        Write-Host 'Response:' -ForegroundColor Gray
        Write-Host ($res | ConvertTo-Json -Depth 4) -ForegroundColor DarkGray
        if ($res.acknowledged) { Write-Host 'Policy updated' -ForegroundColor Green }
    } catch {
        Write-Host 'Failed to update ILM policy' -ForegroundColor Red
    }
}

function Action-SpeedUpPolling {
    Write-Header 'Set indices.lifecycle.poll_interval -> 5s'
    $body = @{ persistent = @{ 'indices.lifecycle.poll_interval' = '5s' } } | ConvertTo-Json -Depth 5
    try {
        $res = Invoke-ESRequest -Method PUT -Path '/_cluster/settings' -Body $body
        if ($res.acknowledged) { Write-Host 'Poll interval updated' -ForegroundColor Green }
    } catch { Write-Host 'Failed to update cluster settings' -ForegroundColor Red }
}

function Action-ResetPolling {
    Write-Header 'Reset indices.lifecycle.poll_interval to default (remove persistent)'
    $body = @{ persistent = @{ 'indices.lifecycle.poll_interval' = $null } } | ConvertTo-Json -Depth 5
    try { $res = Invoke-ESRequest -Method PUT -Path '/_cluster/settings' -Body $body; Write-Host 'Reset acknowledged' -ForegroundColor Green } catch { Write-Host 'Failed' -ForegroundColor Red }
}

function Action-ApplyFastSettings {
    Write-Header 'Apply fast testing settings (5s poll + ILM min_age=30s + retention_lease on indices)'
    Action-SpeedUpPolling

    # update policy to 30s
    $policy = @{ policy = @{ phases = @{ delete = @{ min_age = '30s'; actions = @{ delete = @{} } } } } } | ConvertTo-Json -Depth 10
    try { $r = Invoke-ESRequest -Method PUT -Path '/_ilm/policy/camunda-retention-policy' -Body $policy; Write-Host 'Policy updated' -ForegroundColor Green } catch { Write-Host 'Policy update failed' -ForegroundColor Yellow }

    # apply retention lease to existing archived indices
    try {
        $indices = Invoke-ESRequest -Path '/_cat/indices/*_*?h=index' -ErrorAction SilentlyContinue
        $names = $indices -split "`n" | Where-Object { $_ -match '_\d{4}-\d{2}-\d{2}' -and $_ -match '^(operate|tasklist)' } | ForEach-Object { $_.Trim() }
        foreach ($n in $names) {
            if (-not $n) { continue }
            $sbody = "{\"index.soft_deletes.retention_lease.period\":\"30s\"}"
            try { Invoke-ESRequest -Method PUT -Path "/$n/_settings" -Body $sbody; Write-Host "Applied lease -> $n" -ForegroundColor White } catch { Write-Host "Failed lease -> $n" -ForegroundColor Yellow }
        }
    } catch { Write-Host 'No archived indices or failed to list' -ForegroundColor Yellow }
}

function Action-ForceDelete {
    Write-Header 'Force delete archived indices (testing only)'
    $confirm = Read-Host "Type DELETE to confirm"
    if ($confirm -ne 'DELETE') { Write-Host 'Cancelled'; return }
    try {
        $indices = Invoke-ESRequest -Path '/_cat/indices/*_*?h=index' -ErrorAction SilentlyContinue
        $names = $indices -split "`n" | Where-Object { $_ -match '_\d{4}-\d{2}-\d{2}' -and $_ -match '^(operate|tasklist)' } | ForEach-Object { $_.Trim() }
        foreach ($n in $names) {
            if (-not $n) { continue }
            try { Invoke-ESRequest -Method DELETE -Path "/$n"; Write-Host "Deleted $n" -ForegroundColor Green } catch { Write-Host "Failed delete $n" -ForegroundColor Red }
        }
    } catch { Write-Host 'No archived indices or failed to list' -ForegroundColor Yellow }
}

# main
try {
    $info = Invoke-ESRequest -Path '/'
    Write-Host "Connected to cluster: $($info.cluster_name) (v$($info.version.number))" -ForegroundColor Gray
} catch {
    Write-Host 'Cannot connect to Elasticsearch. Ensure port-forward is running.' -ForegroundColor Red
    exit 1
}

switch ($Action) {
    'CheckConfig' { Action-CheckConfig }
    'ListIndices' { Action-ListIndices }
    'CheckILM' { Action-CheckILM }
    'UpdateRetention' { Action-UpdateRetention }
    'SpeedUpPolling' { Action-SpeedUpPolling }
    'ResetPolling' { Action-ResetPolling }
    'ApplyFastSettings' { Action-ApplyFastSettings }
    'ForceDelete' { Action-ForceDelete }
}

Write-Host 'Done.' -ForegroundColor Green
